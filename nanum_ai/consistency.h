// Translation consistency shared by the live translator and the full
// pre-translation: byte-token repair of model output, speech style presets,
// the per-film glossary and the thread-safe settings that carry both.
// Header-only, no dependencies beyond the standard library.
#pragma once

#include <algorithm>
#include <cctype>
#include <cstdint>
#include <cstdlib>
#include <cstdio>
#include <memory>
#include <mutex>
#include <string>
#include <utility>
#include <vector>

#include "textclean.h"

namespace nanum {

using Glossary = std::vector<std::pair<std::string, std::string>>;

constexpr size_t MAX_GLOSSARY = 150;        // entries kept per film
constexpr size_t MAX_PROMPT_GLOSSARY = 40;  // entries put into one live prompt

// ------------------------------------------------------- byte-token repair

namespace detail {

inline int hex_value(char c)
{
    if (c >= '0' && c <= '9')
        return c - '0';
    if (c >= 'a' && c <= 'f')
        return c - 'a' + 10;
    if (c >= 'A' && c <= 'F')
        return c - 'A' + 10;
    return -1;
}

// "<0xHH>" at s[i].
inline bool byte_token_at(const std::string &s, size_t i, unsigned char &b)
{
    if (i + 6 > s.size() || s[i] != '<' || s[i + 1] != '0' || (s[i + 2] != 'x' && s[i + 2] != 'X') ||
        s[i + 5] != '>')
        return false;
    int h = hex_value(s[i + 3]), l = hex_value(s[i + 4]);
    if (h < 0 || l < 0)
        return false;
    b = (unsigned char)(h * 16 + l);
    return true;
}

// Strict UTF-8: no overlong forms, surrogates, values above U+10FFFF or NUL.
inline bool valid_utf8(const std::string &s)
{
    for (size_t i = 0; i < s.size();) {
        unsigned char c = (unsigned char)s[i];
        if (c == 0)
            return false;
        if (c < 0x80) {
            i++;
            continue;
        }
        size_t len;
        uint32_t cp, min;
        if (c >= 0xC2 && c <= 0xDF) { len = 2; cp = c & 0x1F; min = 0x80; }
        else if (c >= 0xE0 && c <= 0xEF) { len = 3; cp = c & 0x0F; min = 0x800; }
        else if (c >= 0xF0 && c <= 0xF4) { len = 4; cp = c & 0x07; min = 0x10000; }
        else return false;
        if (i + len > s.size())
            return false;
        for (size_t k = 1; k < len; k++) {
            unsigned char n = (unsigned char)s[i + k];
            if ((n & 0xC0) != 0x80)
                return false;
            cp = (cp << 6) | (n & 0x3F);
        }
        if (cp < min || cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF))
            return false;
        i += len;
    }
    return true;
}

} // namespace detail

// Some local models (e.g. Ollama gemma4) emit byte-fallback tokens as literal
// text: "<0xEC><0xB1><0x98>" for "챘". Every run of such tokens is decoded as
// UTF-8. Returns false (out unspecified) when a run is not valid UTF-8 or the text holds a
// replacement character U+FFFD (the model's own broken bytes), i.e. the line cannot be
// repaired and must count as failed.
inline bool repair_byte_tokens(const std::string &in, std::string &out)
{
    if (in.find("\xEF\xBF\xBD") != std::string::npos)
        return false;
    if (in.find("<0x") == std::string::npos && in.find("<0X") == std::string::npos) {
        out = in;
        return true;
    }
    std::string res;
    res.reserve(in.size());
    for (size_t i = 0; i < in.size();) {
        unsigned char b;
        if (!detail::byte_token_at(in, i, b)) {
            res += in[i++];
            continue;
        }
        std::string run;
        while (detail::byte_token_at(in, i, b)) {
            run += (char)b;
            i += 6;
        }
        if (!detail::valid_utf8(run))
            return false;
        res += run;
    }
    out = std::move(res);
    return true;
}

// ------------------------------------------------------------------ style

inline std::string ascii_lower(std::string s)
{
    for (char &c : s)
        c = (char)std::tolower((unsigned char)c);
    return s;
}

// "natural" | "polite" | "casual" | "literal" | "custom"; anything else is natural.
inline std::string normalize_style(const std::string &style)
{
    std::string s = ascii_lower(trim_ws(style));
    for (const char *k : {"polite", "casual", "literal", "custom"})
        if (s == k)
            return s;
    return "natural";
}

inline std::string fnv_hex(const std::string &s)
{
    uint64_t h = 1469598103934665603ull;
    for (unsigned char c : s) {
        h ^= c;
        h *= 1099511628211ull;
    }
    char buf[17];
    std::snprintf(buf, sizeof(buf), "%016llx", (unsigned long long)h);
    return buf;
}

// The user's custom instruction as one bounded line.
inline std::string clean_style_text(const std::string &text)
{
    std::string t = text;
    for (char &c : t)
        if (c == '\n' || c == '\r' || c == '\t')
            c = ' ';
    t = trim_ws(t);
    constexpr size_t MAX = 600;
    if (t.size() > MAX) {
        size_t cut = MAX;
        while (cut > 0 && ((unsigned char)t[cut] & 0xC0) == 0x80)
            cut--;
        t.erase(cut);
    }
    return t;
}

// Style part of the translation cache key: "natural" or "polite" etc.;
// "custom:<hash of the text>"; a custom style without text is natural.
inline std::string style_key(const std::string &style, const std::string &text)
{
    std::string s = normalize_style(style);
    if (s != "custom")
        return s;
    std::string t = clean_style_text(text);
    return t.empty() ? "natural" : "custom:" + fnv_hex(t);
}

inline bool is_korean(const std::string &language)
{
    std::string l = ascii_lower(language);
    return l.find("korean") != std::string::npos || l.find("\xED\x95\x9C\xEA\xB5\xAD") != std::string::npos ||
           l == "ko" || l == "kor";
}

// The sentence added to a translation prompt for the style; "" for natural
// (the prompts already ask for natural, conversational speech).
inline std::string style_instruction(const std::string &style, const std::string &text,
                                     const std::string &target_language)
{
    std::string s = normalize_style(style);
    bool ko = is_korean(target_language);
    if (s == "polite")
        return "Use polite, respectful speech for every character in every line, whatever "
               "their relationship." +
               std::string(ko ? " In Korean use \xEC\xA1\xB4\xEB\x8C\x93\xEB\xA7\x90 "
                                "(\xED\x95\xB4\xEC\x9A\x94\xEC\xB2\xB4/\xED\x95\xA9\xEC\x87\xBC\xEC\xB2\xB4, "
                                "endings such as -\xEC\x9A\x94 and -\xEC\x8A\xB5\xEB\x8B\x88\xEB\x8B\xA4) "
                                "throughout and never \xEB\xB0\x98\xEB\xA7\x90."
                              : "");
    if (s == "casual")
        return "Use casual, informal everyday speech for every character in every line, "
               "whatever their relationship." +
               std::string(ko ? " In Korean use \xEB\xB0\x98\xEB\xA7\x90 (endings such as "
                                "-\xEC\x96\xB4/-\xEC\x95\xBC/-\xEB\x8B\xA4/-\xEC\xA7\x80) throughout and "
                                "never \xEC\xA1\xB4\xEB\x8C\x93\xEB\xA7\x90 (-\xEC\x9A\x94, "
                                "-\xEC\x8A\xB5\xEB\x8B\x88\xEB\x8B\xA4)."
                              : "");
    if (s == "literal")
        return "Stay close to the wording and sentence structure of the original: do not "
               "paraphrase, embellish or freely localise idioms, but keep the result grammatical.";
    if (s == "custom") {
        std::string t = clean_style_text(text);
        return t.empty() ? "" : "Follow this style instruction from the user: " + t;
    }
    return "";
}

// --------------------------------------------------------------- glossary

inline void merge_glossary(Glossary &into, const Glossary &add, size_t max_entries = MAX_GLOSSARY)
{
    for (auto &e : add) {
        if (into.size() >= max_entries)
            return;
        std::string k = ascii_lower(e.first);
        bool dup = false;
        for (auto &x : into)
            dup |= ascii_lower(x.first) == k;
        if (!dup)
            into.push_back(e);
    }
}

// Lines "source => target".
inline std::string format_glossary(const Glossary &g)
{
    std::string s;
    for (auto &e : g) {
        if (!s.empty())
            s += '\n';
        s += e.first + " => " + e.second;
    }
    return s;
}

// Order-independent identity of a glossary for the translation cache; "" when empty.
inline std::string glossary_hash(const Glossary &g)
{
    if (g.empty())
        return "";
    std::vector<std::string> rows;
    for (auto &e : g)
        rows.push_back(e.first + '\x1f' + e.second);
    std::sort(rows.begin(), rows.end());
    std::string all;
    for (auto &r : rows)
        all += r + '\n';
    return fnv_hex(all);
}

namespace detail {

inline bool ascii_alnum(char c)
{
    return std::isalnum((unsigned char)c) != 0 && (unsigned char)c < 0x80;
}

// Case-insensitive (ASCII) occurrence of key in hay. Where the key starts/ends
// with a letter or digit the match must not continue into one ("Al" is not in "Also").
inline bool mentions(const std::string &hay_lower, const std::string &key_lower)
{
    if (key_lower.empty())
        return false;
    for (size_t p = hay_lower.find(key_lower); p != std::string::npos;
         p = hay_lower.find(key_lower, p + 1)) {
        bool before = p > 0 && ascii_alnum(hay_lower[p - 1]) && ascii_alnum(key_lower.front());
        size_t e = p + key_lower.size();
        bool after = e < hay_lower.size() && ascii_alnum(hay_lower[e]) && ascii_alnum(key_lower.back());
        if (!before && !after)
            return true;
    }
    return false;
}

} // namespace detail

// Entries whose key occurs in one of the texts, in glossary order, at most max.
inline Glossary relevant_glossary(const Glossary &g, const std::vector<std::string> &texts,
                                  size_t max = MAX_PROMPT_GLOSSARY)
{
    Glossary r;
    if (g.empty())
        return r;
    std::string hay;
    for (auto &t : texts)
        hay += ascii_lower(t) + '\n';
    for (auto &e : g) {
        if (r.size() >= max)
            break;
        if (detail::mentions(hay, ascii_lower(e.first)))
            r.push_back(e);
    }
    return r;
}

// ------------------------------------------------------- name consistency

namespace detail {

inline std::vector<uint32_t> codepoints(const std::string &s)
{
    std::vector<uint32_t> cps;
    for (size_t i = 0; i < s.size();) {
        unsigned char c = (unsigned char)s[i];
        size_t len = c < 0x80 ? 1 : c >= 0xF0 ? 4 : c >= 0xE0 ? 3 : c >= 0xC0 ? 2 : 1;
        uint32_t cp = len == 1 ? c : c & (0xFF >> (len + 1));
        for (size_t k = 1; k < len && i + k < s.size(); k++)
            cp = (cp << 6) | ((unsigned char)s[i + k] & 0x3F);
        cps.push_back(cp);
        i += len;
    }
    return cps;
}

// Number of distinct characters of a that also occur in b.
inline int shared_characters(const std::string &a, const std::string &b)
{
    std::vector<uint32_t> ca = codepoints(a), cb = codepoints(b);
    std::sort(ca.begin(), ca.end());
    ca.erase(std::unique(ca.begin(), ca.end()), ca.end());
    int n = 0;
    for (uint32_t c : ca)
        n += c != ' ' && std::find(cb.begin(), cb.end(), c) != cb.end();
    return n;
}

// part is a leading or trailing piece of full (case-insensitive; between Latin letters
// the cut must fall on a word boundary); rest is what remains.
inline bool name_part(const std::string &full, const std::string &part, std::string &rest)
{
    if (part.empty() || part.size() >= full.size())
        return false;
    std::string f = ascii_lower(full), p = ascii_lower(part);
    auto cut_ok = [&](size_t at) { return !(ascii_alnum(f[at - 1]) && ascii_alnum(f[at])); };
    if (f.compare(0, p.size(), p) == 0 && cut_ok(p.size())) {
        rest = trim_ws(full.substr(p.size()));
        return !rest.empty();
    }
    size_t at = f.size() - p.size();
    if (f.compare(at, p.size(), p) == 0 && cut_ok(at)) {
        rest = trim_ws(full.substr(0, at));
        return !rest.empty();
    }
    return false;
}

// A derived name part must look like a name: not a particle remainder ("の部室") nor a
// lowercase word.
inline bool plausible_name_part(const std::string &s)
{
    if (s.empty() || s.size() > 60 || (s[0] >= 'a' && s[0] <= 'z') || s.compare(0, 3, "\xE3\x81\xAE") == 0 ||
        s.compare(0, 3, "\xE3\x83\x8E") == 0 || (!s.empty() && std::ispunct((unsigned char)s[0])))
        return false;
    for (unsigned char c : s)
        if (std::isalnum(c) || c >= 0x80)
            return true;
    return false;
}

inline std::vector<std::string> split_words(const std::string &s)
{
    std::vector<std::string> words;
    std::string w;
    for (char c : s + ' ') {
        if (c == ' ') {
            if (!w.empty())
                words.push_back(w);
            w.clear();
        } else {
            w += c;
        }
    }
    return words;
}

// Rough consonant skeleton of a romanised word ("Suzumiya" -> "SSM", "Itsuki" -> "SG"),
// comparable with hangul_skeleton(): similar-sounding consonants share a class letter.
inline std::string latin_skeleton(const std::string &word)
{
    std::string w = ascii_lower(word), sk;
    for (size_t i = 0; i < w.size(); i++) {
        char c = w[i], prev = i ? w[i - 1] : ' ', next = i + 1 < w.size() ? w[i + 1] : ' ';
        switch (c) {
        case 'b': case 'p': case 'f': case 'v': sk += 'B'; break;
        case 'd': sk += 'D'; break;
        case 't': if (next != 's') sk += 'D'; break;        // "ts" is one sound
        case 'g': case 'k': case 'q': case 'x': sk += 'G'; break;
        case 'c': sk += next == 'h' ? 'S' : 'G'; break;
        case 'j': case 'z': case 's': sk += 'S'; break;
        case 'm': sk += 'M'; break;
        case 'n': sk += 'N'; break;
        case 'r': case 'l': sk += 'R'; break;
        case 'h': if (prev != 'c' && prev != 's' && prev != 't') sk += 'H'; break;
        default: break;                                     // vowels, y, w, punctuation
        }
    }
    return sk;
}

// The same classes for hangul syllables (initial and final consonants).
inline std::string hangul_skeleton(const std::string &s)
{
    static const char initial[] = "GGNDDRMBBSS-SSSGDBH";                 // 19 initials
    static const char final_[] = "-GGGNNNDRRRRRRRRMBBSSNSSGDB-";        // 28 finals
    static_assert(sizeof(initial) == 20 && sizeof(final_) == 29, "jamo tables");
    std::string sk;
    for (uint32_t cp : codepoints(s)) {
        if (cp < 0xAC00 || cp > 0xD7A3)
            continue;
        uint32_t idx = cp - 0xAC00;
        char l = initial[idx / 588], t = final_[idx % 28];
        if (l != '-')
            sk += l;
        if (t != '-')
            sk += t;
    }
    return sk;
}

inline int edit_distance(const std::string &a, const std::string &b)
{
    std::vector<int> row(b.size() + 1);
    for (size_t j = 0; j <= b.size(); j++)
        row[j] = (int)j;
    for (size_t i = 1; i <= a.size(); i++) {
        int diag = row[0];
        row[0] = (int)i;
        for (size_t j = 1; j <= b.size(); j++) {
            int up = row[j];
            row[j] = std::min({row[j] + 1, row[j - 1] + 1, diag + (a[i - 1] != b[j - 1])});
            diag = up;
        }
    }
    return row[b.size()];
}

// A romanised full name "w0 w1" rendered as two hangul words "t0 t1": 1 when w0 belongs to
// t0, 2 when it belongs to t1, 0 when the sounds do not decide.
inline int pair_by_sound(const std::string &w0, const std::string &w1, const std::string &t0,
                         const std::string &t1)
{
    std::string a = latin_skeleton(w0), b = latin_skeleton(w1);
    std::string x = hangul_skeleton(t0), y = hangul_skeleton(t1);
    if (x.empty() || y.empty() || a.empty() || b.empty())
        return 0;
    int same = edit_distance(a, x) + edit_distance(b, y);
    int swapped = edit_distance(a, y) + edit_distance(b, x);
    return same < swapped ? 1 : swapped < same ? 2 : 0;
}

} // namespace detail

// Family name, given name and full name must be rendered alike. For every entry whose
// value has exactly two words (a full name like "스즈미야 하루히") the entries for its
// parts ("Suzumiya", "Haruhi", "涼宮") are made consistent with it:
//  - when a part entry exists, the one that matches one of the two words best fixes that
//    word and the other part gets the other word (added when missing, corrected when it
//    differs);
//  - otherwise, for a romanised two-word key listed in both orders (people are) and hangul
//    words, the words are paired by sound ("Suzumiya" ~ 스즈미야) and both parts are added.
// Anything the entries and the sounds do not decide is left alone. The first `locked`
// entries (the user's) are never changed; entries set here are not touched again by a
// later full name.
inline void harmonize_names(Glossary &g, size_t locked = 0, size_t max_entries = MAX_GLOSSARY)
{
    size_t n = g.size();
    std::vector<bool> fixed(n, false);
    for (size_t i = 0; i < std::min(locked, n); i++)
        fixed[i] = true;
    auto find = [&](const std::string &key) {
        std::string k = ascii_lower(key);
        for (size_t i = 0; i < g.size(); i++)
            if (ascii_lower(g[i].first) == k)
                return i;
        return std::string::npos;
    };
    // Part entry key => value: added when missing, corrected unless it is fixed already.
    auto set_part = [&](const std::string &key, const std::string &value) {
        size_t r = find(key);
        if (r == std::string::npos) {
            if (detail::plausible_name_part(key) && g.size() < max_entries) {
                g.push_back({key, value});
                fixed.push_back(true);
            }
        } else if (!fixed[r]) {
            g[r].second = value;
            fixed[r] = true;
        }
    };
    for (size_t i = 0; i < n; i++) {
        std::vector<std::string> words = detail::split_words(g[i].second);
        if (words.size() != 2 || words[0] == words[1])
            continue;
        const std::string full = g[i].first;
        size_t anchor = std::string::npos;
        int best = 0;
        std::string anchor_rest;
        bool first_word = false;
        for (size_t j = 0; j < n; j++) {
            std::string rest;
            if (j == i || !detail::name_part(full, g[j].first, rest))
                continue;
            const std::string &v = g[j].second;
            int a = v == words[0] ? 1000 : detail::shared_characters(v, words[0]);
            int b = v == words[1] ? 1000 : detail::shared_characters(v, words[1]);
            int margin = std::abs(a - b) + (fixed[j] ? 10000 : 0);
            if (a != b && margin > best) {
                best = margin;
                anchor = j;
                anchor_rest = rest;
                first_word = a > b;
            }
        }
        if (anchor != std::string::npos) {
            set_part(g[anchor].first, words[first_word ? 0 : 1]);
            set_part(anchor_rest, words[first_word ? 1 : 0]);
            continue;
        }
        // Sound pairing only for people: they are listed in both name orders, titles and
        // phrases ("Time Loop") are not, and their words must not become glossary entries.
        std::vector<std::string> latin = detail::split_words(full);
        if (latin.size() != 2 || !detail::ascii_alnum(latin[0][0]) || !detail::ascii_alnum(latin[1][0]))
            continue;
        size_t reversed = find(latin[1] + " " + latin[0]);
        if (reversed == std::string::npos || g[reversed].second != g[i].second)
            continue;
        int pairing = detail::pair_by_sound(latin[0], latin[1], words[0], words[1]);
        if (pairing) {
            set_part(latin[0], words[pairing == 1 ? 0 : 1]);
            set_part(latin[1], words[pairing == 1 ? 1 : 0]);
        }
    }
}

// ------------------------------------------------------ entry validation

namespace detail {

inline bool is_kana_or_han(uint32_t cp)
{
    return (cp >= 0x3040 && cp <= 0x30FF) || (cp >= 0x3400 && cp <= 0x9FFF) || (cp >= 0xFF66 && cp <= 0xFF9F);
}

inline bool is_hangul(uint32_t cp)
{
    return (cp >= 0xAC00 && cp <= 0xD7A3) || (cp >= 0x1100 && cp <= 0x11FF) || (cp >= 0x3130 && cp <= 0x318F);
}

// Opening punctuation or an apostrophe: what is left of "Kyon's Sister" after a bad cut.
inline bool starts_with_punctuation(const std::string &s)
{
    if (s.empty())
        return true;
    unsigned char c = (unsigned char)s[0];
    if (c < 0x80)
        return std::ispunct(c) != 0;
    return s.compare(0, 3, "\xE2\x80\x99") == 0 || s.compare(0, 3, "\xE2\x80\x98") == 0 ||     // ’ ‘
           s.compare(0, 3, "\xE2\x80\x9C") == 0 || s.compare(0, 3, "\xE2\x80\x9D") == 0 ||     // “ ”
           s.compare(0, 3, "\xE3\x80\x81") == 0 || s.compare(0, 3, "\xE3\x80\x82") == 0;       // 、。
}

inline bool ends_with(const std::string &s, const char *suffix)
{
    size_t n = std::char_traits<char>::length(suffix);
    return s.size() >= n && s.compare(s.size() - n, n, suffix) == 0;
}

} // namespace detail

// A glossary entry written by a model: plausible or dropped (never repaired). The key must
// not start with punctuation. For a Korean target the value must be Hangul (with digits and
// upper-case acronyms such as "SOS단"): no kana or Chinese characters, no Latin letters inside
// a Hangul word, no notes in parentheses, and no particle glued to the end of a name
// ("키온의"). The user's own lines are not checked.
inline bool entry_valid(const std::string &key, const std::string &value, const std::string &target_language)
{
    if (detail::starts_with_punctuation(key))
        return false;
    if (!is_korean(target_language))
        return true;
    if (value.find('(') != std::string::npos || value.find(')') != std::string::npos)
        return false;
    for (const char *particle : {"\xEC\x9D\x98", "\xEC\x97\x90\xEA\xB2\x8C", "\xEC\x97\x90\xEC\x84\x9C",
                                 "\xED\x95\x9C\xED\x85\x8C", "\xEA\xBB\x98\xEC\x84\x9C", "\xEC\x9C\xBC\xEB\xA1\x9C"})
        if (detail::ends_with(value, particle))     // 의 에게 에서 한테 께서 으로
            return false;
    for (const std::string &word : detail::split_words(value)) {
        bool hangul = false, lower = false;
        size_t upper = 0;
        for (uint32_t cp : detail::codepoints(word)) {
            if (detail::is_kana_or_han(cp))
                return false;
            hangul |= detail::is_hangul(cp);
            lower |= cp >= 'a' && cp <= 'z';
            upper += cp >= 'A' && cp <= 'Z';
        }
        if (hangul && (lower || upper == 1))
            return false;       // Latin inside a Korean word, except an acronym
    }
    return true;
}

// The main characters for a compact prompt line: people the glossary lists as full names
// in both orders ("Haruhi Suzumiya" and "Suzumiya Haruhi" => one rendering), then
// capitalised one-word names that are not part of those. At most max entries (key, value).
inline Glossary main_characters(const Glossary &g, size_t max = 12)
{
    auto find = [&](const std::string &key) {
        std::string k = ascii_lower(key);
        for (auto &e : g)
            if (ascii_lower(e.first) == k)
                return &e;
        return static_cast<const std::pair<std::string, std::string> *>(nullptr);
    };
    auto latin_name = [](const std::vector<std::string> &words) {
        for (auto &w : words) {
            if (w.empty() || !(w[0] >= 'A' && w[0] <= 'Z'))
                return false;
            for (unsigned char c : w)
                if (!(std::isalpha(c) && c < 0x80) && c != '-' && c != '\'')
                    return false;
        }
        return true;
    };
    Glossary out;
    auto listed = [&](const std::string &value) {
        for (auto &o : out)
            if (o.second == value)
                return true;
        return false;
    };
    std::vector<std::string> parts;        // lower-cased words of the chosen full names
    for (auto &e : g) {
        std::vector<std::string> w = detail::split_words(e.first);
        if (out.size() >= max)
            return out;
        if (w.size() != 2 || !latin_name(w) || listed(e.second))
            continue;
        auto rev = find(w[1] + " " + w[0]);
        if (!rev || rev->second != e.second)
            continue;
        out.push_back(e);
        parts.push_back(ascii_lower(w[0]));
        parts.push_back(ascii_lower(w[1]));
    }
    for (auto &e : g) {
        if (out.size() >= max)
            break;
        std::vector<std::string> w = detail::split_words(e.first);
        if (w.size() != 1 || !latin_name(w) || listed(e.second) ||
            std::find(parts.begin(), parts.end(), ascii_lower(w[0])) != parts.end())
            continue;
        out.push_back(e);
    }
    return out;
}

// main_characters() as prompt text: "Itsuki Koizumi = 코이즈미 이츠키 (Koizumi = 코이즈미, Itsuki = 이츠키); ...".
// The names are the speaker-facing spellings: with the family and given name forms spelled
// out where the glossary has them, a garbled "Koizumi" can be matched to its part.
inline std::string main_characters_text(const Glossary &g)
{
    auto value_of = [&](const std::string &key) {
        std::string k = ascii_lower(key);
        for (auto &e : g)
            if (ascii_lower(e.first) == k)
                return e.second;
        return std::string();
    };
    std::string text;
    for (auto &e : main_characters(g)) {
        if (!text.empty())
            text += "; ";
        text += e.first + " = " + e.second;
        std::vector<std::string> w = detail::split_words(e.first);
        if (w.size() == 2) {
            std::string a = value_of(w[0]), b = value_of(w[1]);
            if (!a.empty() && !b.empty())
                text += " (" + w[0] + " = " + a + ", " + w[1] + " = " + b + ")";
        }
    }
    return text;
}

struct NameHint {
    std::string word, key, value;       // "Korsumi" is probably "Koizumi" => 코이즈미
};

// Capitalised words of the texts that look like a speech-recognition garbling of a glossary
// name (a one-word Latin key): same consonant skeleton within one edit (so "Koizumi" ~
// "Korsumi" ~ "Cozamy"), the same first letter class and the same last letter ("y" ~ "i").
// A hint for the model, not a replacement. At most max hints.
inline std::vector<NameHint> garbled_name_hints(const Glossary &g, const std::vector<std::string> &texts,
                                                size_t max = 6)
{
    auto last_class = [](const std::string &w) {
        char c = (char)std::tolower((unsigned char)w.back());
        return c == 'y' ? 'i' : c;
    };
    auto first_class = [](const std::string &w) { return detail::latin_skeleton(w).substr(0, 1); };
    std::vector<NameHint> hints;
    for (auto &text : texts) {
        for (size_t i = 0; i < text.size();) {
            if (!detail::ascii_alnum(text[i]) || std::isdigit((unsigned char)text[i])) {
                i++;
                continue;
            }
            size_t j = i;
            while (j < text.size() && detail::ascii_alnum(text[j]))
                j++;
            std::string word = text.substr(i, j - i);
            i = j;
            if (word.size() < 4 || !(word[0] >= 'A' && word[0] <= 'Z'))
                continue;
            std::string ws = detail::latin_skeleton(word), wl = ascii_lower(word);
            bool known = false;
            for (auto &e : g)
                known |= ascii_lower(e.first) == wl;
            if (known || ws.size() < 3 || hints.size() >= max)
                continue;
            for (auto &e : g) {
                std::vector<std::string> w = detail::split_words(e.first);
                if (w.size() != 1 || e.first.size() < 4 || !(e.first[0] >= 'A' && e.first[0] <= 'Z'))
                    continue;
                std::string ks = detail::latin_skeleton(e.first);
                if (ks.size() >= 3 && detail::edit_distance(ws, ks) <= 1 && last_class(word) == last_class(e.first) &&
                    first_class(word) == first_class(e.first)) {
                    bool dup = false;
                    for (auto &h : hints)
                        dup |= h.word == word;
                    if (!dup)
                        hints.push_back({word, e.first, e.second});
                    break;
                }
            }
        }
    }
    return hints;
}

// ----------------------------------------------------------------- settings

// Style and glossary of one engine, changed from any thread while the
// translator thread reads a consistent snapshot per batch.
class Settings {
public:
    struct Snapshot {
        std::string style = "natural", style_text;
        Glossary glossary;
        std::string glossary_hash;      // "" for an empty glossary
    };

    void set_style(const std::string &style, const std::string &text)
    {
        std::lock_guard<std::mutex> lk(m_);
        s_.style = normalize_style(style);
        s_.style_text = clean_style_text(text);
    }

    // Case-insensitive duplicate keys: the first entry wins.
    void set_glossary(const Glossary &g)
    {
        Glossary unique;
        nanum::merge_glossary(unique, g);
        std::lock_guard<std::mutex> lk(m_);
        s_.glossary = std::move(unique);
        s_.glossary_hash = nanum::glossary_hash(s_.glossary);
    }

    // Appends entries whose key is not present yet.
    void merge_glossary(const Glossary &add)
    {
        std::lock_guard<std::mutex> lk(m_);
        nanum::merge_glossary(s_.glossary, add);
        s_.glossary_hash = nanum::glossary_hash(s_.glossary);
    }

    Snapshot snapshot() const
    {
        std::lock_guard<std::mutex> lk(m_);
        return s_;
    }

private:
    mutable std::mutex m_;
    Snapshot s_;
};

} // namespace nanum
