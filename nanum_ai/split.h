// Splits one recognised utterance into subtitle-sized pieces.
//
// Whisper returns whole speech segments (up to 15 s, several sentences). A
// subtitle should be one or two short sentences, so long segments are cut at
// sentence ends and the segment's time span is shared by character count.
#pragma once

#include <algorithm>
#include <cctype>
#include <cstdint>
#include <string>
#include <vector>

namespace nanum {

struct Piece {
    double t0, t1;
    std::string text;
};

constexpr size_t SPLIT_MAX_CHARS = 84;      // one subtitle: ~2 lines of Latin text
constexpr size_t SPLIT_MAX_UNITS = SPLIT_MAX_CHARS * 2;     // ... as detail::text_units()
constexpr double SPLIT_MAX_DUR = 6.0;
constexpr double SPLIT_MIN_PIECE_DUR = 0.8;

namespace detail {

// Code point at s[i] (U+FFFD for malformed bytes); len = its length in bytes.
inline uint32_t codepoint_at(const std::string &s, size_t i, size_t &len)
{
    unsigned char c = (unsigned char)s[i];
    len = c < 0x80 ? 1 : c >= 0xF0 ? 4 : c >= 0xE0 ? 3 : c >= 0xC0 ? 2 : 1;
    if (len == 1 || i + len > s.size())
        return c < 0x80 ? c : 0xFFFD;
    uint32_t cp = c & (0xFF >> (len + 1));
    for (size_t k = 1; k < len; k++)
        cp = (cp << 6) | ((unsigned char)s[i + k] & 0x3F);
    return cp;
}

// Characters that are one full-width glyph: kana, ideographs, hangul, CJK punctuation and
// full-width forms.
inline bool is_wide(uint32_t cp)
{
    return (cp >= 0x2E80 && cp <= 0x9FFF) || (cp >= 0xAC00 && cp <= 0xD7A3) ||
           (cp >= 0xF900 && cp <= 0xFAFF) || (cp >= 0xFF00 && cp <= 0xFF60);
}

// Display length: a Latin character counts 2, a wide one 5, so SPLIT_MAX_UNITS (2 x the 84
// Latin characters of one subtitle) is 33 CJK characters.
inline size_t text_units(const std::string &s)
{
    size_t u = 0;
    for (size_t i = 0; i < s.size();) {
        size_t len;
        u += is_wide(codepoint_at(s, i, len)) ? 5 : 2;
        i += len;
    }
    return u;
}

// More than half of the non-blank characters are wide.
inline bool mostly_wide(const std::string &s)
{
    size_t wide = 0, all = 0;
    for (size_t i = 0; i < s.size();) {
        size_t len;
        uint32_t cp = codepoint_at(s, i, len);
        i += len;
        if (cp == ' ' || cp == '\t' || cp == '\n')
            continue;
        all++;
        wide += is_wide(cp);
    }
    return wide * 2 > all;
}

// Joins two pieces: with a space, except where a wide character is at the seam.
inline std::string join(const std::string &a, const std::string &b)
{
    if (a.empty() || b.empty())
        return a + b;
    size_t first = 0, len;
    uint32_t b0 = codepoint_at(b, 0, first);
    size_t at = a.size() - 1;
    while (at > 0 && ((unsigned char)a[at] & 0xC0) == 0x80)
        at--;
    uint32_t a1 = codepoint_at(a, at, len);
    return is_wide(a1) || is_wide(b0) ? a + b : a + " " + b;
}

// Well-formed UTF-8 (every multi-byte sequence complete).
inline bool valid_utf8_text(const std::string &s)
{
    for (size_t i = 0; i < s.size();) {
        size_t len;
        uint32_t cp = codepoint_at(s, i, len);
        if (cp == 0xFFFD && !(s.compare(i, 3, "\xEF\xBF\xBD") == 0))
            return false;
        i += len;
    }
    return true;
}

inline std::string lower_letters(const std::string &s)
{
    std::string r;
    for (unsigned char c : s)
        if (std::isalpha(c))
            r += (char)std::tolower(c);
    return r;
}

// True if the '.' at s[i] ends a sentence (not an abbreviation or initial).
inline bool period_ends_sentence(const std::string &s, size_t i)
{
    size_t b = i;
    while (b > 0 && !std::isspace((unsigned char)s[b - 1]))
        b--;
    std::string word = lower_letters(s.substr(b, i - b));
    if (word.size() == 1)
        return false;                       // initial: "J. Smith"
    static const char *abbr[] = {"mr", "mrs", "ms", "dr", "st", "jr", "sr", "vs",
                                 "prof", "mt", "etc", "inc", "ltd", "no"};
    for (const char *a : abbr)
        if (word == a)
            return false;
    return true;
}

// Byte offsets just after each sentence end, in order.
inline std::vector<size_t> sentence_ends(const std::string &s)
{
    std::vector<size_t> ends;
    for (size_t i = 0; i < s.size(); i++) {
        bool dots = false;
        size_t len = 1;
        bool cjk_end = false;
        if (s[i] == '.' || s[i] == '?' || s[i] == '!') {
            dots = true;
        } else if (s.compare(i, 3, "\xE2\x80\xA6") == 0) {     // ellipsis char
            dots = true;
            len = 3;
        } else if (s.compare(i, 3, "\xE3\x80\x82") == 0 ||      // 。
                   s.compare(i, 3, "\xEF\xBC\x81") == 0 ||      // ！
                   s.compare(i, 3, "\xEF\xBC\x9F") == 0) {      // ？
            dots = cjk_end = true;
            len = 3;
        }
        if (!dots)
            continue;
        size_t j = i + len;
        while (j < s.size()) {
            if (s[j] == '.' || s[j] == '?' || s[j] == '!' || s[j] == '"' || s[j] == '\'')
                j++;
            else if (s.compare(j, 3, "\xE3\x80\x82") == 0 || s.compare(j, 3, "\xEF\xBC\x81") == 0 ||
                     s.compare(j, 3, "\xEF\xBC\x9F") == 0 || s.compare(j, 3, "\xE3\x80\x8D") == 0 ||
                     s.compare(j, 3, "\xE3\x80\x8F") == 0 || s.compare(j, 3, "\xEF\xBC\x89") == 0)
                j += 3;                         // 。！？ and closing 」』）
            else
                break;
        }
        if (j >= s.size()) {
            ends.push_back(s.size());
            break;
        }
        // CJK text has no spaces: the mark itself ends the sentence, also an ASCII one
        // directly before a wide character.
        size_t nl = 0;
        bool next_wide = is_wide(codepoint_at(s, j, nl));
        if (cjk_end || next_wide) {
            ends.push_back(j);
            i = j - 1;
            continue;
        }
        if (!std::isspace((unsigned char)s[j])) {
            i = j - 1;
            continue;                       // "3.5", "e.g." inside a word
        }
        size_t k = j;
        while (k < s.size() && std::isspace((unsigned char)s[k]))
            k++;
        bool lower_next = k < s.size() && std::islower((unsigned char)s[k]);
        bool period = s[i] == '.' && len == 1 && j == i + 1;
        if (lower_next || (period && !period_ends_sentence(s, i))) {
            i = j - 1;
            continue;                       // "...and so", "Mr. Smith"
        }
        ends.push_back(j);
        i = j - 1;
    }
    return ends;
}

inline std::string strip(const std::string &s)
{
    size_t a = 0, b = s.size();
    while (a < b && std::isspace((unsigned char)s[a]))
        a++;
    while (b > a && std::isspace((unsigned char)s[b - 1]))
        b--;
    return s.substr(a, b - a);
}

// Byte offsets just after each break inside s that may end a subtitle piece when a
// sentence is too long: ", " and the CJK commas.
inline std::vector<size_t> comma_breaks(const std::string &s)
{
    std::vector<size_t> cuts;
    for (size_t i = 0; i < s.size(); i++) {
        if (s[i] == ',' && i + 1 < s.size() && s[i + 1] == ' ')
            cuts.push_back(i + 1);
        else if (s.compare(i, 3, "\xE3\x80\x81") == 0 || s.compare(i, 3, "\xEF\xBC\x8C") == 0)
            cuts.push_back(i + 3);
    }
    return cuts;
}

// Smaller than the whole and not empty on either side.
inline bool inner_cut(const std::string &s, size_t at)
{
    return at > 0 && at < s.size() && !strip(s.substr(0, at)).empty() && !strip(s.substr(at)).empty();
}

// Appends s to out as pieces that fit one subtitle where it can: the comma nearest to the
// middle; for CJK text (no spaces, often no punctuation at all) repeatedly, and as the
// last resort at the character boundary nearest to the middle. Latin text is cut once and
// only at a comma.
inline void cut_long(const std::string &s, std::vector<std::string> &out)
{
    const bool wide = mostly_wide(s);
    const size_t limit = wide ? SPLIT_MAX_UNITS : SPLIT_MAX_UNITS * 3 / 2;
    size_t total = text_units(s);
    if (total <= limit) {
        out.push_back(s);
        return;
    }
    auto distance = [&](size_t at) {
        size_t u = text_units(s.substr(0, at)), mid = total / 2;
        return u > mid ? u - mid : mid - u;
    };
    size_t best = std::string::npos;
    for (size_t c : comma_breaks(s))
        if (inner_cut(s, c) && (best == std::string::npos || distance(c) < distance(best)))
            best = c;
    if (best == std::string::npos && wide) {
        for (size_t i = 0; i < s.size(); i++)
            if (((unsigned char)s[i] & 0xC0) != 0x80 && inner_cut(s, i) &&
                (best == std::string::npos || distance(i) < distance(best)))
                best = i;
    }
    if (best == std::string::npos) {
        out.push_back(s);
        return;
    }
    std::string a = strip(s.substr(0, best)), b = strip(s.substr(best));
    if (wide) {
        cut_long(a, out);
        cut_long(b, out);
    } else {
        out.push_back(a);
        out.push_back(b);
    }
}

} // namespace detail

// Phrases from the recogniser's own timestamps: one that would be shown for less than the
// minimum is joined with the following (the last: the previous) when the result still fits
// one subtitle.
inline void merge_short_pieces(std::vector<Piece> &pieces)
{
    auto fits = [](const Piece &a, const Piece &b) {
        return detail::text_units(a.text) + 2 + detail::text_units(b.text) <= SPLIT_MAX_UNITS &&
               b.t1 - a.t0 <= SPLIT_MAX_DUR;
    };
    std::vector<Piece> out;
    for (auto &p : pieces) {
        if (!out.empty() && (out.back().t1 - out.back().t0 < SPLIT_MIN_PIECE_DUR ||
                             p.t1 - p.t0 < SPLIT_MIN_PIECE_DUR) &&
            fits(out.back(), p)) {
            out.back().text = detail::join(out.back().text, p.text);
            out.back().t1 = p.t1;
        } else {
            out.push_back(p);
        }
    }
    pieces = std::move(out);
}

inline std::vector<Piece> split_utterance(const std::string &text, double t0, double dur)
{
    std::vector<Piece> one{{t0, t0 + dur, detail::strip(text)}};
    if (detail::text_units(one[0].text) <= SPLIT_MAX_UNITS && dur <= SPLIT_MAX_DUR)
        return one;

    // 1. sentences
    std::vector<std::string> parts;
    size_t from = 0;
    for (size_t e : detail::sentence_ends(text)) {
        std::string p = detail::strip(text.substr(from, e - from));
        if (!p.empty())
            parts.push_back(p);
        from = e;
    }
    if (from < text.size()) {
        std::string p = detail::strip(text.substr(from));
        if (!p.empty())
            parts.push_back(p);
    }

    // 2. merge short neighbours up to one subtitle
    std::vector<std::string> merged;
    for (auto &p : parts) {
        if (!merged.empty() &&
            detail::text_units(merged.back()) + 2 + detail::text_units(p) <= SPLIT_MAX_UNITS)
            merged.back() = detail::join(merged.back(), p);
        else
            merged.push_back(p);
    }

    // 3. an over-long sentence: cut at the comma nearest to the middle
    std::vector<std::string> pieces;
    for (auto &p : merged)
        detail::cut_long(p, pieces);
    if (pieces.size() <= 1)
        return one;

    // 4. share the time span by length. A piece that would be shown
    //    for less than the minimum is joined with its neighbour instead.
    size_t total = 0;
    for (auto &p : pieces)
        total += detail::text_units(p);
    std::vector<Piece> out;
    std::string carry;
    double carry_t0 = t0, t = t0;
    for (size_t i = 0; i < pieces.size(); i++) {
        double d = dur * (double)detail::text_units(pieces[i]) / (double)total;
        std::string text = carry.empty() ? pieces[i] : detail::join(carry, pieces[i]);
        double start = carry.empty() ? t : carry_t0;
        bool last = i + 1 == pieces.size();
        if (t + d - start < SPLIT_MIN_PIECE_DUR && !last) {
            carry = text;               // too short on its own: continue into the next
            carry_t0 = start;
            t += d;
            continue;
        }
        carry.clear();
        if (last && t + d - start < SPLIT_MIN_PIECE_DUR && !out.empty()) {
            out.back().text = detail::join(out.back().text, text);      // short tail: join the previous
            out.back().t1 = t + d;
        } else {
            out.push_back({start, t + d, text});
        }
        t += d;
    }
    out.back().t1 = t0 + dur;
    return out;
}

} // namespace nanum
