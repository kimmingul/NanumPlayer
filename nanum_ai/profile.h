// The one-off "what is this film" queries behind nanum_ai_profile(): identification
// (prompt, JSON schema, defensive parsing) and the names of the identified work, plus the
// JSON handed to the player.
#pragma once

#include <string>

#include "fulltranslate.h"
#include "third_party/json.hpp"

namespace nanum {

struct Profile {
    std::string work;               // identified work, "" if unknown
    std::string original_language;  // ISO 639-1, "" unless the model is confident
    Glossary glossary;
};

// Format constraint for Ollama's "format" field (identification step).
inline const char *profile_schema()
{
    return R"({"type":"object","properties":{"work":{"type":"string"},)"
           R"("original_language":{"type":"string"}},)"
           R"("required":["work","original_language"]})";
}

// Step 1: which work is this and in which language was it made.
inline std::string profile_prompt(const std::string &title, const std::string &audio_languages,
                                  const std::string &target_language)
{
    std::string s =
        "You are an expert on films, TV series, anime and games and on their official " +
        target_language + " localisations.\n"
        "The title below names a disc, file or video. It may contain underscores, release tags, "
        "resolution or codec markers, region codes or a season/episode number: ignore those.\n"
        "Title: " + title + "\n";
    if (!audio_languages.empty())
        s += "Audio languages of the file (ISO codes): " + audio_languages + "\n";
    s += "\nTasks:\n"
         "1. \"work\": the work this is, as its usual title. If you are not reasonably sure, "
         "leave it empty; never invent a work.\n"
         "2. \"original_language\": the ISO 639-1 code (two letters) of the language the work was "
         "originally made in (\"ja\" for a Japanese anime). Leave it empty unless you are confident.";
    if (!audio_languages.empty())
        s += " When the work was originally made in one of the audio languages above, answer "
             "with exactly that language's code.";
    s += "\n\nReply with a JSON object only: {\"work\": string, \"original_language\": string}";
    return s;
}

// Step 2: the names of the identified work, answered in glossary_format_instructions().
inline std::string profile_glossary_prompt(const std::string &work, const std::string &title,
                                           const std::string &original_language,
                                           const std::string &target_language)
{
    std::string s = "You are an expert on the work \"" + work + "\" (file title: \"" + title + "\")";
    if (!original_language.empty())
        s += ", originally made in the language with ISO 639-1 code \"" + original_language + "\"";
    s += " and on its official " + target_language + " localisation.\n"
         "List the names a viewer hears in its dialogue: the main characters (at most 10 people), "
         "important places, organisations and invented terms. Include only names you are certain "
         "belong to this work; skip anything you are unsure of and never invent names. In every "
         + target_language + " form use the official or established " + target_language +
         " rendering, otherwise a natural transliteration, always written in " + target_language +
         ".\n" + glossary_format_instructions(target_language) +
         "Use the script of the original language for the original-script fields (e.g. kanji and "
         "kana for Japanese). Also add a few `=>` lines for spellings that speech recognition "
         "plausibly produces for a main name, mapped to the same " + target_language +
         " form. At most 60 lines; every line different, never repeat a line.";
    return s;
}

// The first n lines of a model answer: the prompt asks for a bounded list, a model that
// ignores that drifts into common words after it.
inline std::string first_lines(const std::string &text, size_t n)
{
    std::string out;
    std::vector<std::string> lines = detail::split_lines(text);
    for (size_t i = 0; i < std::min(n, lines.size()); i++)
        out += lines[i] + '\n';
    return out;
}

// A model that loops writes the same lines again and again.
inline bool looping_answer(const std::string &text)
{
    std::vector<std::string> lines, all = detail::split_lines(text);
    for (auto &l : all)
        if (!trim_ws(l).empty())
            lines.push_back(trim_ws(l));
    std::sort(lines.begin(), lines.end());
    size_t distinct = (size_t)(std::unique(lines.begin(), lines.end()) - lines.begin());
    return lines.size() >= 8 && distinct * 2 < lines.size();
}

namespace detail {

// "ja", "JA", "ja-JP", "jpn" -> "ja"; anything unrecognised -> "".
inline std::string iso_639_1(const std::string &code)
{
    std::string c = ascii_lower(trim_ws(code));
    size_t cut = c.find_first_of("-_");
    if (cut != std::string::npos)
        c.erase(cut);
    static const std::pair<const char *, const char *> three[] = {
        {"eng", "en"}, {"jpn", "ja"}, {"kor", "ko"}, {"zho", "zh"}, {"chi", "zh"}, {"fra", "fr"},
        {"fre", "fr"}, {"deu", "de"}, {"ger", "de"}, {"spa", "es"}, {"ita", "it"}, {"rus", "ru"},
        {"por", "pt"}};
    for (auto &t : three)
        if (c == t.first)
            return t.second;
    if (c.size() == 2 && std::isalpha((unsigned char)c[0]) && std::isalpha((unsigned char)c[1]))
        return c;
    return "";
}

// One line of bounded length from a model-provided string; "" when its byte tokens
// cannot be decoded.
inline std::string profile_text(const std::string &raw, size_t max)
{
    std::string fixed;
    if (!repair_byte_tokens(raw, fixed))
        return "";
    for (char &c : fixed)
        if (c == '\n' || c == '\r' || c == '\t')
            c = ' ';
    fixed = trim_ws(fixed);
    if (fixed.size() > max) {
        size_t cut = max;
        while (cut > 0 && ((unsigned char)fixed[cut] & 0xC0) == 0x80)
            cut--;
        fixed.erase(cut);
    }
    return fixed;
}

// Glossary entries as the model may spell them: array of "a => b" strings, one string
// with lines, an object {"a": "b"}, or an array of {source,target} objects / pairs.
inline std::string glossary_lines(const nlohmann::json &g)
{
    std::string lines;
    auto add = [&](const std::string &k, const std::string &v) { lines += k + " => " + v + "\n"; };
    if (g.is_string()) {
        lines = g.get<std::string>();
    } else if (g.is_object()) {
        for (auto it = g.begin(); it != g.end(); ++it)
            if (it.value().is_string())
                add(it.key(), it.value().get<std::string>());
    } else if (g.is_array()) {
        for (auto &e : g) {
            if (e.is_string()) {
                lines += e.get<std::string>() + "\n";
            } else if (e.is_array() && e.size() == 2 && e[0].is_string() && e[1].is_string()) {
                add(e[0].get<std::string>(), e[1].get<std::string>());
            } else if (e.is_object()) {
                std::string k, v;
                for (const char *n : {"source", "name", "key", "original"})
                    if (e.contains(n) && e[n].is_string() && k.empty())
                        k = e[n].get<std::string>();
                for (const char *n : {"target", "translation", "value", "korean"})
                    if (e.contains(n) && e[n].is_string() && v.empty())
                        v = e[n].get<std::string>();
                if (!k.empty() && !v.empty())
                    add(k, v);
            }
        }
    }
    return lines;
}

} // namespace detail

// false when the answer holds no JSON object. Byte tokens are repaired in every
// string; an unrepairable work/glossary entry is dropped, never shown as garbage.
inline bool parse_profile(const std::string &raw, Profile &out, const std::string &target_language = "")
{
    std::string text = detail::strip_think(raw);
    size_t a = text.find('{'), b = text.rfind('}');
    if (a == std::string::npos || b == std::string::npos || b < a)
        return false;
    nlohmann::json j = nlohmann::json::parse(text.substr(a, b - a + 1), nullptr, false);
    if (j.is_discarded() || !j.is_object())
        return false;
    Profile p;
    if (j.contains("work") && j["work"].is_string())
        p.work = detail::profile_text(j["work"].get<std::string>(), 200);
    if (j.contains("original_language") && j["original_language"].is_string())
        p.original_language = detail::iso_639_1(j["original_language"].get<std::string>());
    if (j.contains("glossary"))
        p.glossary = parse_glossary_answer(detail::glossary_lines(j["glossary"]), target_language);
    out = std::move(p);
    return true;
}

// The JSON written by nanum_ai_profile().
inline std::string profile_json(const Profile &p)
{
    nlohmann::json j = {{"work", p.work},
                        {"original_language", p.original_language},
                        {"glossary", format_glossary(p.glossary)}};
    return j.dump(-1, ' ', false, nlohmann::json::error_handler_t::replace);
}

} // namespace nanum
