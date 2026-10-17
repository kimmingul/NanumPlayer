// Full pre-translation of a complete transcript: glossary pass, windows with
// overlap, strict numbered parsing, retry, per-line fallback. The engine
// (Ollama endpoint or the omp CLI) is abstracted as "prompt in, text out".
#pragma once

#include <algorithm>
#include <atomic>
#include <cctype>
#include <cstdio>
#include <functional>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "consistency.h"
#include "textclean.h"
#include "translator.h"

namespace nanum {

struct FullLine {
    double pts = 0, dur = 0;
    std::string src;
    std::string tr;         // filled by translate_full(); "" = failed
};

struct FullParams {
    std::string source_language;    // human readable, e.g. "English"
    std::string target_language;    // e.g. "Korean"
    size_t window = 60;             // lines per request (approximate)
    size_t overlap = 5;             // translated lines shown as context
    std::string style = "natural";  // see style_instruction()
    std::string style_text;         // instruction of the "custom" style
};

// ---------------------------------------------------------------- engines

class Engine {
public:
    virtual ~Engine() = default;
    // Blocking. false + err on failure (also after cancel()).
    virtual bool run(const std::string &prompt, std::string &out, std::string &err) = 0;
    // Any thread; aborts a running run() and fails every later one.
    virtual void cancel() = 0;
};

// Uses the Ollama-compatible endpoint/model of cfg (cache disabled).
std::unique_ptr<Engine> make_ollama_engine(TranslatorConfig cfg);
// omp -p ... --model <model> @promptfile, hidden window, killed on timeout.
std::unique_ptr<Engine> make_omp_engine(const std::string &command, const std::string &model,
                                        int timeout_s);

// Returns "" on success (all lines have tr set; "" only where a line failed twice),
// "cancelled" when cancel is set, else an error message. `glossary` is the seed
// (entries the extraction pass must not override) and receives the merged result.
// progress(p) is called with p in [0,1] after the glossary and after each window.
std::string translate_full(Engine &engine, std::vector<FullLine> &lines, const FullParams &params,
                           Glossary &glossary, const std::atomic<bool> &cancel,
                           const std::function<void(double)> &progress);

// ---------------------------------------------------------- pure helpers

// Window boundaries [begin,end) of about `window` lines, evenly sized (no tiny tail).
inline std::vector<std::pair<size_t, size_t>> make_windows(size_t n, size_t window)
{
    std::vector<std::pair<size_t, size_t>> w;
    if (!n)
        return w;
    if (window < 1)
        window = 1;
    size_t count = (n + window - 1) / window;
    size_t size = (n + count - 1) / count;
    for (size_t b = 0; b < n; b += size)
        w.push_back({b, std::min(n, b + size)});
    return w;
}

namespace detail {

// "12. text" / "12) text" / "12: text" -> number + text.
inline bool split_number(const std::string &line, size_t &num, std::string &text)
{
    size_t i = 0;
    while (i < line.size() && (line[i] == ' ' || line[i] == '\t' || line[i] == '*'))
        i++;
    size_t d = i;
    size_t v = 0;
    while (i < line.size() && std::isdigit((unsigned char)line[i]) && i - d < 6)
        v = v * 10 + (line[i++] - '0');
    if (i == d || i >= line.size() || (line[i] != '.' && line[i] != ')' && line[i] != ':'))
        return false;
    i++;
    while (i < line.size() && (line[i] == '*' || line[i] == ' ' || line[i] == '\t'))
        i++;
    num = v;
    text = trim_ws(line.substr(i));
    return true;
}

inline std::string strip_think(std::string t)
{
    // Some providers prefill <think> outside the returned text. Its closing
    // delimiter still separates discarded drafts from the actual answer.
    size_t close = t.find("</think>");
    size_t open = t.find("<think>");
    if (close != std::string::npos && (open == std::string::npos || close < open))
        t.erase(0, close + 8);
    for (size_t a; (a = t.find("<think>")) != std::string::npos;) {
        size_t b = t.find("</think>", a);
        if (b == std::string::npos) {
            t.erase(a);
            break;
        }
        t.erase(a, b + 8 - a);
    }
    return t;
}

inline std::vector<std::string> split_lines(const std::string &s)
{
    std::vector<std::string> v;
    size_t p = 0;
    while (p <= s.size()) {
        size_t e = s.find('\n', p);
        std::string l = s.substr(p, e == std::string::npos ? std::string::npos : e - p);
        if (!l.empty() && l.back() == '\r')
            l.pop_back();
        v.push_back(l);
        if (e == std::string::npos)
            break;
        p = e + 1;
    }
    return v;
}

inline std::string unquote(std::string s)
{
    s = trim_ws(s);
    if (s.size() >= 2 && ((s.front() == '"' && s.back() == '"') ||
                          (s.front() == '\'' && s.back() == '\'')))
        s = trim_ws(s.substr(1, s.size() - 2));
    return s;
}

} // namespace detail

// Strict: after dropping ``` fences, blank lines and <think> blocks, the output
// must be exactly n lines numbered 1..n in order, each with non-empty text.
// A single requested line may also come back without its number.
inline bool parse_numbered(const std::string &raw, size_t n, std::vector<std::string> &out)
{
    std::vector<std::string> body;
    for (auto &l : detail::split_lines(detail::strip_think(raw))) {
        std::string t = trim_ws(l);
        if (t.empty() || t.compare(0, 3, "```") == 0)
            continue;
        body.push_back(l);
    }
    std::vector<std::string> res;
    bool ok = body.size() == n;
    for (size_t i = 0; ok && i < body.size(); i++) {
        size_t num;
        std::string text;
        if (!detail::split_number(body[i], num, text) || num != i + 1) {
            ok = false;
            break;
        }
        text = detail::unquote(text);
        if (!repair_byte_tokens(text, text)) {
            ok = false;
            break;
        }
        if (text.empty()) {
            ok = false;
            break;
        }
        res.push_back(text);
    }
    if (!ok && n == 1 && body.size() == 1) {
        size_t num;
        std::string text;
        if (!detail::split_number(body[0], num, text)) {
            std::string t = detail::unquote(body[0]);
            if (!repair_byte_tokens(t, t))
                t.clear();
            if (!t.empty()) {
                res.assign(1, t);
                ok = true;
            }
        }
    }
    if (!ok)
        return false;
    out = std::move(res);
    return true;
}

// Lines "Name => Form" (also "->", "→"), with bullets/numbers in front. names_only
// (model output) drops entries that look like common words or fail entry_valid() for the
// target language; the user's own lines (names_only == false) keep them.
inline Glossary parse_glossary(const std::string &raw, bool names_only = true,
                               const std::string &target_language = "")
{
    Glossary g;
    for (auto &line : detail::split_lines(detail::strip_think(raw))) {
        std::string l;
        if (!repair_byte_tokens(line, l))
            continue;       // undecodable byte tokens: drop the entry
        std::string t = trim_ws(l);
        size_t arrow = std::string::npos, alen = 0;
        for (const char *a : {"=>", "->", "\xE2\x86\x92"}) {
            size_t p = t.find(a);
            if (p != std::string::npos && p < arrow) {
                arrow = p;
                alen = std::char_traits<char>::length(a);
            }
        }
        if (arrow == std::string::npos)
            continue;
        std::string k = t.substr(0, arrow), v = t.substr(arrow + alen);
        size_t num;
        std::string rest;
        if (detail::split_number(k, num, rest))
            k = rest;
        size_t b = 0;
        while (b < k.size() && (k[b] == '-' || k[b] == '*' || k[b] == ' ' || k[b] == '\t' ||
                                (unsigned char)k[b] == 0xE2))
            b = (unsigned char)k[b] == 0xE2 ? b + 3 : b + 1;     // "•"
        k = detail::unquote(trim_ws(k.substr(std::min(b, k.size()))));
        v = detail::unquote(v);
        while (!v.empty() && (v.back() == '*'))
            v.pop_back();
        while (!k.empty() && (k.back() == '*'))
            k.pop_back();
        if (k.empty() || v.empty() || k == v || k.size() > 60 || v.size() > 80 ||
            (names_only && ((k[0] >= 'a' && k[0] <= 'z') ||       // common words, not names
                            detail::codepoints(k).size() < 2 ||   // a lone "人" is not a name
                            !entry_valid(k, v, target_language))))
            continue;
        g.push_back({k, v});
    }
    return g;
}

// The glossary a model answered with glossary_format_instructions(): `=>` lines (names
// only, byte tokens repaired, undecodable lines dropped), duplicates merged first-wins and
// family/given/full names made consistent.
inline Glossary parse_glossary_answer(const std::string &raw, const std::string &target_language = "")
{
    Glossary g;
    merge_glossary(g, parse_glossary(raw, true, target_language));
    harmonize_names(g);
    return g;
}

// Transcript pieces for the glossary pass: at most max_chunks chunks of about
// max_chars characters, sampled evenly over the whole transcript.
inline std::vector<std::string> glossary_chunks(const std::vector<FullLine> &lines,
                                                size_t max_chars = 12000, size_t max_chunks = 8)
{
    std::vector<std::string> all;
    std::string cur;
    for (auto &l : lines) {
        if (!cur.empty() && cur.size() + l.src.size() + 1 > max_chars) {
            all.push_back(std::move(cur));
            cur.clear();
        }
        cur += l.src;
        cur += '\n';
    }
    if (!cur.empty())
        all.push_back(std::move(cur));
    if (all.size() <= max_chunks)
        return all;
    std::vector<std::string> sampled;
    for (size_t i = 0; i < max_chunks; i++)
        sampled.push_back(std::move(all[i * all.size() / max_chunks]));
    return sampled;
}

// Instructions for the glossary answer shared by the full-run extraction and the profile
// query: `Name => form` lines, with family name, given name and full name of a person
// rendered alike (harmonize_names() repairs what the model still gets wrong).
inline std::string glossary_format_instructions(const std::string &target)
{
    std::string s =
        "Output only lines of the form `Name => " + target + " form`, nothing else.\n"
        "A person with a family name and a given name is called by either or both, so make "
        "ONE " + target + " rendering of the full name (in the order of the original language: "
        "family name first for Japanese, Chinese and Korean names) and write separate lines for "
        "the full name in the original script, the full name in both romanised orders, the "
        "family name alone and the given name alone (each in the original script and "
        "romanised). The lines for the family name and the given name carry exactly the "
        "matching word of that rendering. Nicknames and titles used as names, places, "
        "organisations and invented terms are lines of their own.\n";
    if (is_korean(target))
        s += "Example (another work):\n"
             "桐ヶ谷和人 => 키리가야 가즈토\nKirigaya Kazuto => 키리가야 가즈토\n"
             "Kazuto Kirigaya => 키리가야 가즈토\n桐ヶ谷 => 키리가야\nKirigaya => 키리가야\n"
             "和人 => 가즈토\nKazuto => 가즈토\nKirito => 키리토\n";
    return s;
}

inline std::string glossary_prompt(const FullParams &p, const std::string &chunk)
{
    return "Below are subtitle lines from a film or video, in " + p.source_language +
           ". Some come from speech recognition, so names may be misspelled.\n"
           "List ONLY proper nouns and invented terms: names of characters, places, ships, "
           "organisations, titles of address that are part of a name, made-up words. Do NOT "
           "list common words, phrases or sentences. For each give the form to use in " +
           p.target_language +
           " subtitles (established translation or transliteration). If a name is spelled "
           "in several ways, list the correct spelling once.\n" +
           glossary_format_instructions(p.target_language) +
           "At most 40 lines. If there are none, output nothing.\n\n"
           "Subtitle lines:\n" + chunk;
}

// lines[ctx_begin..begin) are context (shown with their translations),
// lines[begin..end) are to be translated.
inline std::string window_prompt(const FullParams &p, const Glossary &glossary,
                                 const std::vector<FullLine> &lines, size_t ctx_begin,
                                 size_t begin, size_t end)
{
    size_t n = end - begin;
    std::string s =
        "You are a professional subtitle translator. Translate the numbered subtitle lines "
        "from " + p.source_language + " into natural, conversational " + p.target_language +
        ", the way people actually speak in a film.\n";
    std::string style = style_instruction(p.style, p.style_text, p.target_language);
    if (!style.empty())
        s += "Style: " + style + "\n";
    s +=
        "Rules:\n"
        "- Output exactly " + std::to_string(n) + " line" + (n == 1 ? "" : "s") +
        ", numbered 1 to " + std::to_string(n) +
        " in the form `1. translation`, one line each, in the same order. Output nothing else: "
        "no notes, no blank lines, no original text.\n"
        "- Each input line is one subtitle. Translate every line, including interjections. "
        "Never merge or split lines, and never leave a line in " + p.source_language +
        " (names excepted).\n"
        "- The source may come from speech recognition and contain errors (misheard words, "
        "wrong names, missing punctuation). Silently fix obvious errors using the context and "
        "the glossary, and translate what was meant.\n"
        "- Keep names and terms consistent with the glossary and the previous lines. A word "
        "that sounds like a name in the glossary is that name, however speech recognition "
        "spelled it: write the glossary rendering.\n";
    if (!glossary.empty()) {
        s += "\nGlossary (use exactly these renderings; a character may be called by family name, "
             "given name or full name, so use the matching entry for each form):\n";
        for (auto &g : glossary)
            s += "- " + g.first + " => " + g.second + "\n";
    }
    if (ctx_begin < begin) {
        s += "\nPrevious lines, already translated. Context only, do NOT output them:\n";
        for (size_t i = ctx_begin; i < begin; i++) {
            s += "Source: " + lines[i].src + "\n";
            if (!lines[i].tr.empty())
                s += "Translation: " + lines[i].tr + "\n";
        }
    }
    s += "\nSubtitle lines to translate:\n";
    for (size_t i = begin; i < end; i++)
        s += std::to_string(i - begin + 1) + ". " + lines[i].src + "\n";
    return s;
}

} // namespace nanum
