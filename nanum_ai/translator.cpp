#include "translator.h"

#include <windows.h>
#include <winhttp.h>

#include <cstdio>
#include <fstream>

#include "third_party/json.hpp"

using nlohmann::json;

namespace {

std::wstring widen(const std::string &s)
{
    if (s.empty())
        return L"";
    int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), nullptr, 0);
    std::wstring w(n, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), w.data(), n);
    return w;
}

std::string trim(const std::string &s)
{
    size_t a = s.find_first_not_of(" \t\r\n");
    if (a == std::string::npos)
        return "";
    size_t b = s.find_last_not_of(" \t\r\n");
    return s.substr(a, b - a + 1);
}

// One subtitle = one visual unit: no line breaks, no wrapping quotes.
std::string clean(std::string s)
{
    for (char &c : s)
        if (c == '\n' || c == '\r')
            c = ' ';
    s = trim(s);
    if (s.size() >= 2 && s.front() == '"' && s.back() == '"')
        s = trim(s.substr(1, s.size() - 2));
    return s;
}

// Models sometimes wrap the JSON in ``` fences or add a sentence around it.
bool parse_lines(const std::string &text, std::vector<std::string> &lines)
{
    size_t a = text.find_first_of("{[");
    size_t b = text.find_last_of("}]");
    if (a == std::string::npos || b == std::string::npos || b < a)
        return false;
    json j = json::parse(text.substr(a, b - a + 1), nullptr, false);
    if (j.is_discarded())
        return false;
    if (j.is_object() && j.contains("lines"))
        j = j["lines"];
    if (!j.is_array())
        return false;
    lines.clear();
    for (auto &e : j) {
        std::string s;
        if (!e.is_string() || !nanum::repair_byte_tokens(e.get<std::string>(), s))
            return false;       // unrepairable byte tokens: the translation failed
        lines.push_back(clean(s));
    }
    return true;
}

} // namespace

Translator::Translator(const TranslatorConfig &cfg)
    : cfg_(cfg), settings_(cfg.settings ? cfg.settings : std::make_shared<nanum::Settings>())
{
    if (cfg_.context_lines < 0)
        cfg_.context_lines = 0;
    if (cfg_.cache_path.empty())
        return;
    std::ifstream f(cfg_.cache_path);
    std::string line;
    auto text_field = [](const json &j, const char *name) {
        auto it = j.find(name);
        return it != j.end() && it->is_string() ? it->get<std::string>() : std::string();
    };
    while (std::getline(f, line)) {
        json j = json::parse(line, nullptr, false);
        if (j.is_discarded() || !j.is_object())
            continue;
        if (j.value("m", "") != cfg_.model || j.value("l", "") != cfg_.target_language)
            continue;
        std::string s = j.value("s", ""), k;
        // Models used to leave byte-fallback tokens in lines; undecodable rows are dropped.
        if (s.empty() || !nanum::repair_byte_tokens(j.value("k", ""), k) || k.empty())
            continue;
        // Rows from before ABI 6 have neither field: natural style, empty glossary.
        std::string style = text_field(j, "t");
        cache_[make_key(cfg_.model, cfg_.target_language, style.empty() ? "natural" : style,
                        text_field(j, "g"), s)] = k;
    }
}

std::string Translator::make_key(const std::string &model, const std::string &target,
                                 const std::string &style, const std::string &ghash,
                                 const std::string &src)
{
    return model + '\x1f' + target + '\x1f' + style + '\x1f' + ghash + '\x1f' + src;
}

std::string Translator::key(const std::string &src) const
{
    return make_key(cfg_.model, cfg_.target_language, style_key_, cur_.glossary_hash, src);
}

void Translator::remember(const std::string &src, const std::string &ko)
{
    cache_[key(src)] = ko;
    if (cfg_.cache_path.empty())
        return;
    json j = {{"m", cfg_.model}, {"l", cfg_.target_language}, {"s", src}, {"k", ko}};
    if (style_key_ != "natural")
        j["t"] = style_key_;
    if (!cur_.glossary_hash.empty())
        j["g"] = cur_.glossary_hash;
    std::ofstream f(cfg_.cache_path, std::ios::app | std::ios::binary);
    f << j.dump(-1, ' ', false, json::error_handler_t::replace) << '\n';
}

bool Translator::post(const std::string &body, std::string &response, int timeout_ms)
{
    std::wstring wurl = widen(cfg_.endpoint);
    URL_COMPONENTS uc = {};
    uc.dwStructSize = sizeof(uc);
    wchar_t host[256];
    uc.lpszHostName = host;
    uc.dwHostNameLength = 256;
    if (!WinHttpCrackUrl(wurl.c_str(), 0, 0, &uc))
        return false;
    if (aborted_)
        return false;

    HINTERNET s = WinHttpOpen(L"nanum_ai/1.0", WINHTTP_ACCESS_TYPE_NO_PROXY,
                              WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
    if (!s)
        return false;
    // The first request may have to load the model; later ones must be quick.
    int timeout = timeout_ms > 0 ? timeout_ms
                : first_request_ ? std::max(cfg_.timeout_ms, 120000) : cfg_.timeout_ms;
    WinHttpSetTimeouts(s, timeout, timeout, timeout, timeout);
    bool ok = false;
    HINTERNET c = WinHttpConnect(s, host, uc.nPort, 0);
    HINTERNET r = c ? WinHttpOpenRequest(c, L"POST", L"/api/generate", nullptr,
                                         WINHTTP_NO_REFERER,
                                         WINHTTP_DEFAULT_ACCEPT_TYPES,
                                         uc.nScheme == INTERNET_SCHEME_HTTPS ? WINHTTP_FLAG_SECURE : 0)
                    : nullptr;
    cur_req_.store(r);
    if (aborted_ && r && cur_req_.exchange(nullptr) == r) {
        WinHttpCloseHandle(r);      // abort() ran before the handle was published
        r = nullptr;
    }
    if (r &&
        WinHttpSendRequest(r, L"Content-Type: application/json", (DWORD)-1,
                           (LPVOID)body.data(), (DWORD)body.size(),
                           (DWORD)body.size(), 0) &&
        WinHttpReceiveResponse(r, nullptr)) {
        DWORD status = 0, sz = sizeof(status);
        WinHttpQueryHeaders(r, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
                            WINHTTP_HEADER_NAME_BY_INDEX, &status, &sz,
                            WINHTTP_NO_HEADER_INDEX);
        response.clear();
        for (;;) {
            DWORD avail = 0;
            if (!WinHttpQueryDataAvailable(r, &avail) || !avail)
                break;
            size_t old = response.size();
            response.resize(old + avail);
            DWORD got = 0;
            if (!WinHttpReadData(r, &response[old], avail, &got))
                break;
            response.resize(old + got);
        }
        ok = status == 200;
        if (ok)
            first_request_ = false;
        if (!ok && status == 400 && send_think_)
            send_think_ = false;    // model has no "think" switch: retry without
    }
    // abort() may already have closed the request from another thread.
    if (r && cur_req_.exchange(nullptr) == r)
        WinHttpCloseHandle(r);
    if (c)
        WinHttpCloseHandle(c);
    WinHttpCloseHandle(s);
    return ok;
}

// One request for all lines.
Translator::Result Translator::request_lines(const std::vector<std::string> &src,
                                             std::vector<std::string> &out, double temperature,
                                             bool names)
{
    std::string prompt = "You translate movie subtitles from " + cfg_.source_language +
                         " into natural, conversational " + cfg_.target_language +
                         ". Keep names consistent, add no notes, translate every line "
                         "and keep the order.\n";
    if (!style_instruction_.empty())
        prompt += "Style: " + style_instruction_ + "\n";
    std::vector<std::string> mentioned(recent_.begin(), recent_.end());
    mentioned.insert(mentioned.end(), src.begin(), src.end());
    nanum::Glossary known = names ? nanum::relevant_glossary(cur_.glossary, mentioned) : nanum::Glossary();
    std::string cast = names ? nanum::main_characters_text(cur_.glossary) : std::string();
    if (!known.empty()) {
        prompt += "Glossary of names and terms (use exactly these renderings). The lines come "
                  "from speech recognition and may misspell names: also apply an entry when a "
                  "name only sounds like or is spelled similarly to its source form. A character "
                  "may be called by family name, given name or full name: use the matching entry "
                  "for each form.\n";
        for (auto &e : known)
            prompt += "- " + e.first + " => " + e.second + "\n";
    }
    if (!recent_.empty()) {
        prompt += "Preceding lines, for context only (do not translate them):\n";
        for (auto &c : recent_)
            prompt += "- " + c + "\n";
    }
    if (!cast.empty()) {
        prompt += "\nMain characters of this film: " + cast + ".\n"
                  "Speech recognition often garbles names. If a word in the lines below is not an "
                  "ordinary word and sounds like one of these names, or like only the family name "
                  "or the given name, it IS that character: write exactly the " +
                  cfg_.target_language + " form from this list, never a spelling of the garbled "
                  "word.\n";
        for (auto &h : nanum::garbled_name_hints(cur_.glossary, src))
            prompt += "Probably garbled name: \"" + h.word + "\" is \"" + h.key + "\" => " + h.value + "\n";
    }
    prompt += "\nLines to translate:\n";
    for (size_t i = 0; i < src.size(); i++)
        prompt += std::to_string(i + 1) + ". " + src[i] + "\n";
    prompt += "\nReturn exactly " + std::to_string(src.size()) +
              " strings in the \"lines\" array.";

    // A second attempt only happens when the first one taught us the model
    // has no "think" switch.
    for (int attempt = 0; attempt < 2; attempt++) {
        json req = {
            {"model", cfg_.model},
            {"prompt", prompt},
            {"stream", false},
            {"options", {{"temperature", temperature}}},
            {"format", {{"type", "object"},
                        {"properties", {{"lines", {{"type", "array"},
                                                    {"items", {{"type", "string"}}}}}}},
                        {"required", {"lines"}}}},
        };
        bool had_think = send_think_;
        if (had_think)
            req["think"] = false;

        requests_++;
        std::string resp;
        if (!post(req.dump(-1, ' ', false, json::error_handler_t::replace), resp)) {
            if (had_think && !send_think_)
                continue;
            return Result::Transport;
        }
        json j = json::parse(resp, nullptr, false);
        if (j.is_discarded() || !j.contains("response") || !j["response"].is_string())
            return Result::Transport;
        std::vector<std::string> lines;
        const std::string answer = j["response"].get<std::string>();
        bool usable = parse_lines(answer, lines) && lines.size() == src.size() &&
                      std::none_of(lines.begin(), lines.end(), [](const std::string &l) { return l.empty(); });
        if (!usable) {
            if (std::getenv("NANUM_AI_DEBUG"))
                std::fprintf(stderr, "tr: unusable answer for %zu line(s): %s\n", src.size(), answer.c_str());
            return Result::Malformed;
        }
        out = std::move(lines);
        return Result::Ok;
    }
    return Result::Transport;
}

bool Translator::complete(const std::string &prompt, std::string &text, std::string &error,
                          const CompleteOptions &opt)
{
    for (int attempt = 0; attempt < 2; attempt++) {
        json req = {
            {"model", cfg_.model},
            {"prompt", prompt},
            {"stream", false},
            {"options", {{"temperature", opt.temperature}, {"num_ctx", opt.num_ctx}}},
        };
        if (opt.max_tokens > 0)
            req["options"]["num_predict"] = opt.max_tokens;
        if (opt.repeat_penalty > 0)
            req["options"]["repeat_penalty"] = opt.repeat_penalty;
        if (!opt.format_schema.empty())
            req["format"] = json::parse(opt.format_schema);
        bool had_think = send_think_;
        if (had_think)
            req["think"] = false;

        requests_++;
        std::string resp;
        if (!post(req.dump(-1, ' ', false, json::error_handler_t::replace), resp, opt.timeout_ms)) {
            if (had_think && !send_think_)
                continue;       // the model has no "think" switch: retry without
            error = aborted_ ? "cancelled" : "translation endpoint request failed";
            return false;
        }
        json j = json::parse(resp, nullptr, false);
        if (j.is_discarded() || !j.contains("response") || !j["response"].is_string()) {
            error = "unexpected response from the translation endpoint";
            return false;
        }
        text = j["response"].get<std::string>();
        return true;
    }
    error = "translation endpoint request failed";
    return false;
}

void Translator::abort()
{
    aborted_ = true;
    HINTERNET h = (HINTERNET)cur_req_.exchange(nullptr);
    if (h)
        WinHttpCloseHandle(h);      // makes a blocked request return at once
}

void Translator::commit_context(const std::vector<std::string> &src)
{
    for (auto &s : src) {
        recent_.push_back(s);
        while ((int)recent_.size() > cfg_.context_lines)
            recent_.pop_front();
    }
}

void Translator::translate(const std::vector<std::string> &src,
                           std::vector<std::string> &out)
{
    static const bool dbg = std::getenv("NANUM_AI_DEBUG") != nullptr;
    cur_ = settings_->snapshot();
    style_key_ = nanum::style_key(cur_.style, cur_.style_text);
    style_instruction_ = nanum::style_instruction(cur_.style, cur_.style_text, cfg_.target_language);
    out.assign(src.size(), "");
    transport_failed_ = false;
    std::vector<size_t> miss;
    for (size_t i = 0; i < src.size(); i++) {
        auto it = cache_.find(key(src[i]));
        if (it != cache_.end())
            out[i] = it->second;
        else
            miss.push_back(i);
    }
    if (miss.empty() || !enabled() || aborted_)
        return;

    // After a transport failure the endpoint is skipped briefly so a dead
    // server cannot stall every batch for the full timeout.
    if (std::chrono::steady_clock::now() < down_until_) {
        transport_failed_ = true;
        return;
    }

    auto t0 = std::chrono::steady_clock::now();
    std::vector<std::string> msrc, mout;
    for (size_t i : miss)
        msrc.push_back(src[i]);
    Result r = request_lines(msrc, mout);
    if (r == Result::Ok) {
        for (size_t k = 0; k < miss.size(); k++) {
            out[miss[k]] = mout[k];
            remember(src[miss[k]], mout[k]);
        }
    } else if (r == Result::Malformed && miss.size() > 1) {
        // Batch came back malformed or short: fall back to single lines.
        for (size_t i : miss) {
            std::vector<std::string> one{src[i]}, res;
            Result r1 = request_lines(one, res);
            // A deterministic model repeats a broken answer: vary the temperature once, then
            // drop the names (a rare syllable in a glossary form can derail the model).
            if (r1 == Result::Malformed)
                r1 = request_lines(one, res, 0.7);
            if (r1 == Result::Malformed)
                r1 = request_lines(one, res, 0.2, false);
            if (r1 == Result::Ok) {
                out[i] = res[0];
                remember(src[i], res[0]);
            } else if (r1 == Result::Transport) {
                r = r1;
                break;
            }
        }
    }
    if (r == Result::Transport) {
        transport_failed_ = true;
        down_until_ = std::chrono::steady_clock::now() + std::chrono::seconds(4);
    }
    if (dbg)
        std::fprintf(stderr, "tr: %zu lines in %.2fs -> %s\n", miss.size(),
                     std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count(),
                     r == Result::Ok ? "ok" : r == Result::Malformed ? "malformed" : "transport error");
}
