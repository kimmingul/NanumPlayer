// Cleaning of text-subtitle lines (SRT/ASS/WebVTT payloads) into plain
// single-line source text for translation. Header-only, no dependencies.
#pragma once

#include <cctype>
#include <utility>
#include <string>
#include <vector>

namespace nanum {

inline std::string trim_ws(const std::string &s)
{
    size_t a = s.find_first_not_of(" \t\r\n");
    if (a == std::string::npos)
        return "";
    size_t b = s.find_last_not_of(" \t\r\n");
    return s.substr(a, b - a + 1);
}

// "[BLANK_AUDIO]", "(music)", "*sigh*", "♪ ♪": not something to translate.
inline bool is_non_speech(const std::string &s)
{
    if (s.empty())
        return true;
    char first = s.front(), last = s.back();
    if ((first == '[' && last == ']') || (first == '(' && last == ')') ||
        (first == '*' && last == '*'))
        return true;
    // Music notes alone are not speech, lyrics between notes still are.
    std::string t = s;
    for (const char *sym : {"\xE2\x99\xAA", "\xE2\x99\xAB"})
        for (size_t p; (p = t.find(sym)) != std::string::npos;)
            t.erase(p, 3);
    bool any_alnum = false;
    for (unsigned char c : t)
        any_alnum |= std::isalnum(c) || c >= 0x80;
    return !any_alnum;
}

// "0.3." / "0.8" / "3": what speech recognition writes for music or a tone. At most 4
// characters, digits and punctuation only, at least one digit.
inline bool is_number_noise(const std::string &s)
{
    std::string t = trim_ws(s);
    if (t.empty() || t.size() > 4)
        return false;
    bool digit = false;
    for (unsigned char c : t) {
        if (std::isdigit(c))
            digit = true;
        else if (!std::ispunct(c) && c != ' ')
            return false;
    }
    return digit;
}

namespace detail {

// A line of "Dialogue: layer,start,end,style,name,ml,mr,mv,effect,text".
inline std::string strip_ass_dialogue(const std::string &s)
{
    if (s.compare(0, 9, "Dialogue:") != 0)
        return s;
    size_t p = 9;
    for (int commas = 0; commas < 9; commas++) {
        p = s.find(',', p);
        if (p == std::string::npos)
            return s;
        p++;
    }
    return s.substr(p);
}

inline bool html_tag_at(const std::string &s, size_t i, size_t &end)
{
    // <i> </i> <font color="#fff"> <b>; "<3" or "a < b" are not tags.
    if (s[i] != '<' || i + 2 >= s.size())
        return false;
    size_t j = i + 1;
    if (s[j] == '/')
        j++;
    if (j >= s.size() || !std::isalpha((unsigned char)s[j]))
        return false;
    size_t e = s.find('>', j);
    if (e == std::string::npos || e - i > 200)
        return false;
    end = e + 1;
    return true;
}

inline void replace_all(std::string &s, const char *from, const char *to)
{
    size_t n = std::char_traits<char>::length(from);
    for (size_t p = 0; (p = s.find(from, p)) != std::string::npos;) {
        s.replace(p, n, to);
        p += std::char_traits<char>::length(to);
    }
}

} // namespace detail

// Returns "" if the text is empty or only sound descriptions / music notes.
// Line breaks (real, "\N", "\n") become separators between visual lines;
// sound-only lines are dropped, the others are joined with a space.
inline std::string clean_subtitle_text(const std::string &raw)
{
    std::string s = detail::strip_ass_dialogue(raw);

    // Tags: ASS overrides {...}, HTML <i>...</i>.
    std::string t;
    t.reserve(s.size());
    for (size_t i = 0; i < s.size();) {
        char c = s[i];
        if (c == '{') {
            size_t e = s.find('}', i);
            if (e != std::string::npos) {
                i = e + 1;
                continue;
            }
        }
        size_t e;
        if (c == '<' && detail::html_tag_at(s, i, e)) {
            i = e;
            continue;
        }
        if (c == '\\' && i + 1 < s.size()) {
            char n = s[i + 1];
            if (n == 'N' || n == 'n') {
                t += '\n';
                i += 2;
                continue;
            }
            if (n == 'h') {
                t += ' ';
                i += 2;
                continue;
            }
        }
        t += c;
        i++;
    }
    for (auto &r : {std::pair<const char *, const char *>{"&amp;", "&"},
                    {"&lt;", "<"}, {"&gt;", ">"}, {"&quot;", "\""},
                    {"&nbsp;", " "}, {"&#39;", "'"}})
        detail::replace_all(t, r.first, r.second);
    detail::replace_all(t, "\xC2\xA0", " ");        // no-break space

    std::string out;
    size_t start = 0;
    while (start <= t.size()) {
        size_t nl = t.find_first_of("\r\n", start);
        std::string line = trim_ws(t.substr(start, nl == std::string::npos ? std::string::npos
                                                                            : nl - start));
        // Collapse runs of blanks.
        std::string c;
        for (char ch : line) {
            if ((ch == ' ' || ch == '\t') && !c.empty() && c.back() == ' ')
                continue;
            c += ch == '\t' ? ' ' : ch;
        }
        if (!is_non_speech(c)) {
            if (!out.empty())
                out += ' ';
            out += c;
        }
        if (nl == std::string::npos)
            break;
        start = nl + 1;
    }
    return is_non_speech(out) ? "" : out;
}

} // namespace nanum
