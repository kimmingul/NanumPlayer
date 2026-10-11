// Feeds a 16 kHz mono 16-bit WAV into nanum_ai at a given start pts and prints
// the events.
// Usage: nanum_ai_test <stt.bin> <vad.bin> <file.wav> [start_pts] [lang] [cache.jsonl]
//        nanum_ai_test --selftest
//        nanum_ai_test --full-srt <file.srt> [options]   text track -> transcript -> translate_all
//        nanum_ai_test --full-wav <file.wav> [options]   STT (scan_only) -> translate_all
//        nanum_ai_test --live-srt <file.srt> <playhead> [options]  live text path with set_playhead
//        nanum_ai_test --profile <title> <audio langs, e.g. en,ja> [options]   nanum_ai_profile()
//        nanum_ai_test --ocr <image.png|bmp|jpg> [lang]   nanum_ai_ocr() with Windows.Media.Ocr
//   options: --engine ollama|omp  --model <ollama model>  --omp-model <selector>  --omp-command <exe>
//            --stt <path> --vad <path> --lang <code>  --target <language>
// Env:   NANUM_AI_TR_ENDPOINT (default http://127.0.0.1:11434, "off" disables)
//        NANUM_AI_TR_MODEL    (default gemma4:latest; also the --profile default)
//   all modes except --profile: NANUM_AI_TR_STYLE (natural|polite|casual|literal|custom), NANUM_AI_TR_STYLE_TEXT,
//                  NANUM_AI_TR_GLOSSARY (lines "source => target")
#include "fulltranslate.h"
#include "nanum_ai.h"
#include "profile.h"
#include "split.h"
#include "textclean.h"
#include "translator.h"

#include <windows.h>
#include <wincodec.h>

#include <atomic>
#include <chrono>
#include <thread>
#include <condition_variable>
#include <filesystem>
#include <fstream>
#include <mutex>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

static std::vector<float> read_wav(const char *path)
{
    std::vector<float> out;
    FILE *f = std::fopen(path, "rb");
    if (!f)
        return out;
    char hdr[12];
    if (std::fread(hdr, 1, 12, f) != 12 || std::memcmp(hdr, "RIFF", 4)) {
        std::fclose(f);
        return out;
    }
    for (;;) {
        char id[4];
        uint32_t sz;
        if (std::fread(id, 1, 4, f) != 4 || std::fread(&sz, 4, 1, f) != 1)
            break;
        if (!std::memcmp(id, "data", 4)) {
            std::vector<int16_t> pcm(sz / 2);
            size_t n = std::fread(pcm.data(), 2, pcm.size(), f);
            out.resize(n);
            for (size_t i = 0; i < n; i++)
                out[i] = pcm[i] / 32768.0f;
            break;
        }
        std::fseek(f, (long)sz, SEEK_CUR);
    }
    std::fclose(f);
    return out;
}

static std::chrono::steady_clock::time_point t_start;
static int n_events, n_translated;

static void on_event(void *, double pts, double dur, const char *src, const char *ko)
{
    double el = std::chrono::duration<double>(std::chrono::steady_clock::now() - t_start).count();
    n_events++;
    n_translated += ko != nullptr;
    std::printf("[%8.2f -> %8.2f] (+%6.2fs) %s\n", pts, pts + dur, el, src);
    std::printf("%*s=> %s\n", 33, "", ko ? ko : "(no translation)");
}

// Behaviour of the subtitle splitter on the cases that go wrong in practice.
static int selftest()
{
    int bad = 0;
    std::setvbuf(stdout, nullptr, _IONBF, 0);       // a crash must not swallow the lines before it
    auto check = [&](bool ok, const char *what) {
        std::printf("  %s %s\n", ok ? "ok  " : "FAIL", what);
        bad += !ok;
    };

    auto a = nanum::split_utterance("It was so cold.", 10.0, 1.5);
    check(a.size() == 1 && a[0].t0 == 10.0 && a[0].t1 == 11.5, "short text stays one piece");

    std::string t = "Mr. Smith went to Washington last spring to see his old friend Dr. Jones. "
                    "They talked for hours about the plan, the budget, and the schedule. "
                    "Then he went home.";
    auto b = nanum::split_utterance(t, 100.0, 12.0);
    bool abbr_ok = true;
    for (auto &p : b)
        abbr_ok &= p.text.rfind("Smith", 0) != 0 && p.text.rfind("Jones", 0) != 0;
    check(b.size() >= 2, "long text is split");
    check(abbr_ok, "no split after Mr./Dr.");
    bool contiguous = b.front().t0 == 100.0 && std::abs(b.back().t1 - 112.0) < 1e-9;
    for (size_t i = 1; i < b.size(); i++)
        contiguous &= std::abs(b[i].t0 - b[i - 1].t1) < 1e-9;
    check(contiguous, "pieces cover the whole span without gaps");
    std::string joined;
    for (auto &p : b)
        joined += (joined.empty() ? "" : " ") + p.text;
    check(joined == t, "no text lost or changed");
    bool fits = true;
    for (auto &p : b)
        fits &= p.text.size() <= nanum::SPLIT_MAX_CHARS * 3 / 2;
    check(fits, "every piece is subtitle sized");

    auto c = nanum::split_utterance("Well... and then he left the room without saying a word to anyone at all, "
                                    "which is not like him.", 0.0, 7.0);
    check(c.size() == 1 || c[0].text.find("and then") != std::string::npos,
          "'...and' continuation is not a sentence start");


    // Japanese and Chinese: no spaces, often no punctuation at all.
    {
        std::string ja =
            "もちろんあんたは何もないわよね聞かなくてもわかるけど何だと聞かないと悪いような気がするから"
            "聞いてあげるわ予定があったらどうだってんだまず先にそれを言えってことはないのね";
        auto pieces = nanum::split_utterance(ja, 455.91, 12.35);
        bool fits = true, contiguous = std::abs(pieces.front().t0 - 455.91) < 1e-9 &&
                                       std::abs(pieces.back().t1 - 468.26) < 1e-9;
        std::string joined;
        for (size_t i = 0; i < pieces.size(); i++) {
            fits &= nanum::detail::text_units(pieces[i].text) <= nanum::SPLIT_MAX_UNITS &&
                    pieces[i].t1 - pieces[i].t0 <= nanum::SPLIT_MAX_DUR + 1e-9 &&
                    nanum::detail::valid_utf8_text(pieces[i].text);
            if (i)
                contiguous &= std::abs(pieces[i].t0 - pieces[i - 1].t1) < 1e-9;
            joined += pieces[i].text;
        }
        check(pieces.size() >= 3 && fits, "unpunctuated Japanese is cut into readable pieces (<= 33 chars, <= 6 s)");
        check(joined == ja && contiguous, "Japanese pieces keep every character and cover the whole span");

        std::string punct = "もちろんあんたは何もないわよね。聞かなくてもわかるけど、何だと聞かないと悪いような気がするから"
                            "聞いてあげるわ。予定があったらどうだってんだ？まず先にそれを言えってことはないのね！";
        auto p2 = nanum::split_utterance(punct, 0.0, 12.0);
        bool at_marks = !p2.empty();
        for (auto &p : p2)
            at_marks &= nanum::detail::text_units(p.text) <= nanum::SPLIT_MAX_UNITS &&
                        (p.text.size() < 3 || p.text.compare(p.text.size() - 3, 3, "\xE3\x80\x82") == 0 ||
                         p.text.compare(p.text.size() - 3, 3, "\xE3\x80\x81") == 0 ||
                         p.text.compare(p.text.size() - 3, 3, "\xEF\xBC\x9F") == 0 ||
                         p.text.compare(p.text.size() - 3, 3, "\xEF\xBC\x81") == 0);
        check(p2.size() >= 2 && at_marks, "Japanese with 。？！ is cut at the sentence ends");

        auto ends = nanum::detail::sentence_ends("そうなの。「違う。」ええ。");
        check(ends.size() == 3, "closing quotes stay with their sentence (。」)");
        check(nanum::split_utterance("はい。", 0, 1).size() == 1 && nanum::split_utterance("はい", 0, 1).size() == 1,
              "a short Japanese line stays one piece");

        std::string comma = "今日はとても寒いので、コートを着て、マフラーを巻いて、手袋もして、それから急いで学校へ向かいました、"
                            "朝ごはんも食べずに";
        auto p3 = nanum::split_utterance(comma, 0.0, 10.0);
        bool at_comma = p3.size() >= 2;
        for (size_t i = 0; i + 1 < p3.size(); i++)
            at_comma &= p3[i].text.size() >= 3 && p3[i].text.compare(p3[i].text.size() - 3, 3, "\xE3\x80\x81") == 0;
        check(at_comma, "an over-long Japanese sentence is cut at 、 nearest to the middle");

        std::string mixed = "Hello everyone, welcome to the show. 今日は皆さんに特別なお知らせがあります。それは来月から新しい番組が始まるということです。";
        auto p4 = nanum::split_utterance(mixed, 0.0, 14.0);
        bool mixed_ok = p4.size() >= 2;
        for (auto &p : p4)
            mixed_ok &= nanum::detail::text_units(p.text) <= nanum::SPLIT_MAX_UNITS;
        check(mixed_ok && p4[0].text == "Hello everyone, welcome to the show.", "mixed English/Japanese splits at the sentence ends");

        std::string zh = "我今天早上起来的时候发现外面下了很大的雪所以我决定不去上班而是留在家里喝茶看书听音乐过一个安静的下午";
        auto p5 = nanum::split_utterance(zh, 0.0, 9.0);
        bool zh_ok = p5.size() >= 2;
        for (auto &p : p5)
            zh_ok &= nanum::detail::text_units(p.text) <= nanum::SPLIT_MAX_UNITS && nanum::detail::valid_utf8_text(p.text);
        check(zh_ok, "unpunctuated Chinese is cut too, never inside a character");

        // Whisper's own phrase timestamps: a too-short phrase joins its neighbour while the
        // result still fits one subtitle (<= 6 s), otherwise it stays.
        std::vector<nanum::Piece> timed = {{0.0, 0.4, "はい"}, {0.4, 3.0, "そうですね"}, {3.0, 7.0, "それはそうとして"},
                                           {7.0, 7.3, "ね"}, {7.3, 13.0, "じゃあまたね"}, {13.0, 13.4, "うん"}};
        nanum::merge_short_pieces(timed);
        check(timed.size() == 4 && timed[0].text == "はいそうですね" && timed[0].t0 == 0.0 && timed[0].t1 == 3.0 &&
                  timed[1].text == "それはそうとしてね" && timed[1].t1 == 7.3 && timed[2].text == "じゃあまたね" &&
                  timed[3].text == "うん",
              "phrase timestamps: short phrases join a neighbour only while the result stays one subtitle");

        // English is untouched by the wide-character logic.
        std::string en = "It was a long cold winter and nobody in the village had enough wood to keep the fire going all night, "
                         "so they took turns watching the embers until the morning came.";
        auto p6 = nanum::split_utterance(en, 0.0, 10.0);
        check(p6.size() == 2 && p6[0].text.back() == ',' && p6[0].text.find("all night") != std::string::npos,
              "English: a long sentence is still cut once at the comma");
        check(nanum::is_number_noise("0.3.") && nanum::is_number_noise("0.8") && nanum::is_number_noise(" 3. ") &&
                  !nanum::is_number_noise("Yes.") && !nanum::is_number_noise("12345") &&
                  !nanum::is_number_noise("3 am") && !nanum::is_number_noise("") && !nanum::is_number_noise("\xE3\x81\xAF"),
              "number-only noise recognised, words and long numbers kept");
    }
    auto d = nanum::split_utterance("Yes. This is a considerably longer second sentence that carries on for a while "
                                    "so that the whole utterance is long.", 0.0, 7.0);
    bool min_dur = true;
    for (auto &p : d)
        min_dur &= p.t1 - p.t0 >= nanum::SPLIT_MIN_PIECE_DUR - 1e-9;
    check(min_dur, "no piece shorter than the minimum display time");
    // Text cleaning.
    using nanum::clean_subtitle_text;
    check(clean_subtitle_text("<i>Hello</i> <font color=\"#ff0\">there</font>") == "Hello there",
          "html tags stripped");
    check(clean_subtitle_text("{\\an8}Top\\Nline two") == "Top line two",
          "ASS overrides stripped, \\N joins lines");
    check(clean_subtitle_text("[music playing]") == "" && clean_subtitle_text("(door slams)") == "" &&
              clean_subtitle_text("\xE2\x99\xAA \xE2\x99\xAA") == "" && clean_subtitle_text("  \n ") == "",
          "sound-only and empty text dropped");
    check(clean_subtitle_text("[phone rings]\nWhat do you want?") == "What do you want?",
          "sound-only line dropped, speech kept");
    check(clean_subtitle_text("Tom &amp; Jerry\n<b>I <3 you</b>") == "Tom & Jerry I <3 you",
          "entities decoded, '<3' is not a tag");
    check(clean_subtitle_text("Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,Hi, {\\i1}you{\\i0}") ==
              "Hi, you",
          "ASS Dialogue prefix removed (commas in text kept)");
    check(clean_subtitle_text("\xE2\x99\xAA Hello darling \xE2\x99\xAA") ==
              "\xE2\x99\xAA Hello darling \xE2\x99\xAA",
          "lyrics between notes kept");

    // Windows.
    auto w1 = nanum::make_windows(130, 60);
    bool cover = !w1.empty() && w1.front().first == 0 && w1.back().second == 130;
    for (size_t i = 1; i < w1.size(); i++)
        cover &= w1[i].first == w1[i - 1].second;
    check(w1.size() == 3 && cover, "130 lines -> 3 contiguous windows");
    auto w2 = nanum::make_windows(61, 60);
    check(w2.size() == 2 && w2[0].second - w2[0].first >= 30 && w2[1].second - w2[1].first >= 30,
          "61 lines -> two balanced windows, no tiny tail");
    check(nanum::make_windows(60, 60).size() == 1 && nanum::make_windows(0, 60).empty() &&
              nanum::make_windows(1, 60).size() == 1,
          "window edge sizes");

    // Numbered output parsing.
    std::vector<std::string> out;
    check(nanum::parse_numbered("1. 안녕\n2. 잘 가\n3) 응", 3, out) && out.size() == 3 &&
              out[0] == "안녕" && out[2] == "응",
          "numbered output parsed (1. and 1))");
    check(nanum::parse_numbered("```\n1. a\n\n2. b\n```\n", 2, out) && out[1] == "b",
          "code fences and blank lines ignored");
    check(nanum::parse_numbered("<think>hmm\n1. x</think>\n1. a\n2. b", 2, out) && out[0] == "a",
          "think block removed");
    check(!nanum::parse_numbered("1. a\n2. b", 3, out), "too few lines rejected");
    check(!nanum::parse_numbered("1. a\n2. b\n3. c", 2, out), "too many lines rejected");
    check(!nanum::parse_numbered("1. a\n3. c", 2, out), "skipped number rejected");
    check(!nanum::parse_numbered("1. a\n2.   \n", 2, out), "empty translation rejected");
    check(!nanum::parse_numbered("Sure! Here you go:\n1. a\n2. b", 2, out),
          "chatter around the answer rejected");
    check(nanum::parse_numbered("\"hello\"", 1, out) && out[0] == "hello",
          "single line may come back without its number");

    // Glossary.
    auto g = nanum::parse_glossary("- Kyon => 쿄\n2. Haruhi -> 하루히\n* **Asahina** => 아사히나\n"
                                   "noise without arrow\nSame => Same\n");
    check(g.size() == 3 && g[0].first == "Kyon" && g[0].second == "쿄" && g[1].first == "Haruhi" &&
              g[2].first == "Asahina" && g[2].second == "아사히나",
          "glossary lines parsed");
    nanum::merge_glossary(g, nanum::parse_glossary("KYON => 큐온\nYuki => 유키\nthe ship => 배"));
    check(g.size() == 4, "glossary drops lowercase common words");
    check(g[0].second == "쿄" && g[3].first == "Yuki", "glossary merge: first spelling wins, case-insensitive");

    // Byte-fallback tokens in model output.
    {
        std::string r;
        check(nanum::repair_byte_tokens("눈치<0xEC><0xB1><0x98>네", r) && r == "눈치챘네",
              "byte tokens decoded inside a word");
        check(nanum::repair_byte_tokens("<0xED><0x9B><0xA0>궈", r) && r == "훠궈",
              "byte tokens decoded at the start");
        check(nanum::repair_byte_tokens("a<0xe2><0x99><0xaa>b<0x41>", r) && r == "a\xE2\x99\xAA" "bA",
              "lowercase hex, ASCII byte and two runs");
        check(nanum::repair_byte_tokens("plain <0xZZ> text <0x4> and <0x", r) &&
                  r == "plain <0xZZ> text <0x4> and <0x",
              "text that is not a complete token is left alone");
        check(nanum::repair_byte_tokens("그냥 한국어", r) && r == "그냥 한국어", "clean text unchanged");
        check(!nanum::repair_byte_tokens("눈치<0xEC><0xB1>네", r), "truncated sequence is not repairable");
        check(!nanum::repair_byte_tokens("<0xFF>", r) && !nanum::repair_byte_tokens("<0x98>", r) &&
                  !nanum::repair_byte_tokens("<0xC0><0x80>", r) &&
                  !nanum::repair_byte_tokens("<0xED><0xA0><0x80>", r) && !nanum::repair_byte_tokens("<0x00>", r),
              "invalid UTF-8 (lone byte, overlong, surrogate, NUL) is not repairable");
        std::vector<std::string> nums;
        check(nanum::parse_numbered("1. 눈치<0xEC><0xB1><0x98>네\n2. ok", 2, nums) && nums[0] == "눈치챘네",
              "full-run line repaired");
        check(!nanum::parse_numbered("1. 눈치<0xEC><0xB1>네\n2. ok", 2, nums),
              "full-run line with broken bytes fails (retry / per-line fallback)");
        auto bg = nanum::parse_glossary("하\n<0xED><0x9B><0xA0>궈 => 훠궈\nHotpot => <0xED><0x9B><0xA0>궈\n"
                                        "Bad => <0xEC><0xB1>\nOk => 확인");
        check(bg.size() == 2 && bg[0].first == "Hotpot" && bg[0].second == "훠궈" && bg[1].first == "Ok",
              "glossary entries repaired, undecodable ones dropped");
    }

    // Style presets.
    {
        using nanum::style_instruction;
        check(style_instruction("natural", "", "Korean").empty() && style_instruction("", "", "Korean").empty() &&
                  style_instruction("bogus", "x", "Korean").empty(),
              "natural (and unknown) style adds nothing to the prompt");
        check(style_instruction("polite", "", "Korean").find("존댓말") != std::string::npos &&
                  style_instruction("polite", "", "Korean").find("-요") != std::string::npos,
              "polite + Korean mentions 존댓말");
        check(style_instruction("polite", "", "Japanese").find("polite") != std::string::npos &&
                  style_instruction("polite", "", "Japanese").find("존댓말") == std::string::npos,
              "Korean speech levels only for a Korean target");
        check(style_instruction("casual", "", "Korean").find("반말") != std::string::npos &&
                  style_instruction("casual", "", "English").find("반말") == std::string::npos,
              "casual + Korean mentions 반말");
        check(style_instruction("literal", "", "Korean").find("close to the wording") != std::string::npos,
              "literal style");
        check(style_instruction("custom", "  Speak like a pirate\n", "Korean").find("Speak like a pirate") !=
                      std::string::npos &&
                  style_instruction("custom", "", "Korean").empty(),
              "custom style uses its text, empty custom text adds nothing");
        check(nanum::style_key("Polite", "") == "polite" && nanum::style_key("custom", "") == "natural" &&
                  nanum::style_key("custom", "a") != nanum::style_key("custom", "b") &&
                  nanum::style_key("custom", "a") == nanum::style_key("custom", " a\n") &&
                  nanum::style_key("what", "") == "natural",
              "style cache keys");
        nanum::FullParams fp;
        fp.source_language = "English";
        fp.target_language = "Korean";
        std::vector<nanum::FullLine> fl(1);
        fl[0].src = "Hello.";
        std::string natural = nanum::window_prompt(fp, {}, fl, 0, 0, 1);
        fp.style = "casual";
        std::string casual = nanum::window_prompt(fp, {}, fl, 0, 0, 1);
        check(natural.find("Style:") == std::string::npos && casual.find("Style: Use casual") != std::string::npos &&
                  casual.find("반말") != std::string::npos,
              "full-run prompt carries the style, natural stays as before");
    }

    // Glossary relevance and cache key identity.
    {
        nanum::Glossary g = {{"Haruhi", "하루히"}, {"Kyon", "쿄"}, {"Al", "알"}, {"長門", "나가토"},
                             {"Nagato Yuki", "나가토 유키"}};
        auto rel = nanum::relevant_glossary(g, {"Did you see HARUHI today?", "Also, the 長門 case"});
        check(rel.size() == 2 && rel[0].first == "Haruhi" && rel[1].first == "長門",
              "relevant glossary: case-insensitive, not inside other words, non-ASCII keys");
        check(nanum::relevant_glossary(g, {"Haruhi's friend Kyon-kun"}).size() == 2,
              "relevant glossary: possessive / suffix after the name still matches");
        check(nanum::relevant_glossary(g, {"nothing here"}).empty() && nanum::relevant_glossary({}, {"Haruhi"}).empty(),
              "relevant glossary: none when nothing is mentioned");
        nanum::Glossary many;
        std::string text;
        for (int i = 0; i < 80; i++) {
            many.push_back({"Name" + std::string(1, (char)('A' + i / 26)) + (char)('a' + i % 26),
                            "이름" + std::to_string(i)});
            text += many.back().first + " ";
        }
        check(nanum::relevant_glossary(many, {text}).size() == nanum::MAX_PROMPT_GLOSSARY,
              "relevant glossary capped at 40");
        nanum::Glossary reordered(g.rbegin(), g.rend());
        check(!nanum::glossary_hash(g).empty() && nanum::glossary_hash({}).empty() &&
                  nanum::glossary_hash(g) == nanum::glossary_hash(reordered) &&
                  nanum::glossary_hash(g) != nanum::glossary_hash({{"Haruhi", "하루히"}}),
              "glossary hash: empty is empty, order-independent, content-sensitive");

        // Cache rows: from before ABI 6 (no t/g) = natural + empty glossary.
        namespace fs = std::filesystem;
        fs::path cache = fs::temp_directory_path() / "nanum_ai_selftest_cache.jsonl";
        {
            std::ofstream f(cache, std::ios::binary | std::ios::trunc);
            f << R"({"m":"mdl","l":"Korean","s":"Hello","k":"안녕"})" "\n"
              << R"({"m":"mdl","l":"Korean","s":"Bye","k":"잘 가","t":"polite"})" "\n"
              << R"({"m":"mdl","l":"Korean","s":"Haruhi!","k":"하루히!","g":")" << nanum::glossary_hash(g) << "\"}\n"
              << R"({"m":"mdl","l":"Korean","s":"Broken","k":"눈치<0xEC><0xB1>네"})" "\n"
              << R"({"m":"mdl","l":"Korean","s":"Fixed","k":"눈치<0xEC><0xB1><0x98>네"})" "\n"
              << R"({"m":"other","l":"Korean","s":"Hello","k":"다른 모델"})" "\n";
        }
        auto settings = std::make_shared<nanum::Settings>();
        TranslatorConfig tc;
        tc.model = "mdl";
        tc.target_language = "Korean";
        tc.cache_path = cache.string();
        tc.settings = settings;
        Translator tr(tc);                  // no endpoint: answers from the cache only
        std::vector<std::string> src = {"Hello", "Bye", "Haruhi!", "Broken", "Fixed"}, got;
        tr.translate(src, got);
        check(got[0] == "안녕" && got[1].empty() && got[2].empty() && got[3].empty() && got[4] == "눈치챘네",
              "old cache rows hit for natural + empty glossary; other style/glossary rows and broken bytes do not");
        settings->set_style("polite", "");
        tr.translate(src, got);
        check(got[0].empty() && got[1] == "잘 가", "polite style only sees polite rows");
        settings->set_style("natural", "");
        settings->set_glossary(g);
        tr.translate(src, got);
        check(got[0].empty() && got[2] == "하루히!", "glossary changes the cache identity");
        settings->set_glossary({{"Haruhi", "다른"}});
        tr.translate(src, got);
        check(got[2].empty(), "a different glossary misses");
        settings->set_glossary({});
        tr.translate(src, got);
        check(got[0] == "안녕", "clearing the glossary returns to the old rows");
        fs::remove(cache);

        auto live = std::make_shared<nanum::Settings>();
        live->set_glossary(nanum::parse_glossary("kyon => 쿄\nHaruhi => 하루히\nharuhi => 다른", false));
        live->merge_glossary(nanum::parse_glossary("HARUHI => x\nNagato => 나가토"));
        auto snap = live->snapshot();
        check(snap.glossary.size() == 3 && snap.glossary[0].first == "kyon" && snap.glossary[2].first == "Nagato" &&
                  snap.glossary_hash == nanum::glossary_hash(snap.glossary),
              "settings: user lines keep lowercase keys, merge is first-wins");
    }

    // Family name / given name / full name consistency.
    {
        auto value = [](const nanum::Glossary &g, const char *key) {
            for (auto &e : g)
                if (e.first == key)
                    return e.second;
            return std::string("(missing)");
        };
        nanum::Glossary a = {{"Haruhi Suzumiya", "스즈미야 하루히"}, {"Suzumiya", "스즈미야"}};
        nanum::harmonize_names(a);
        check(value(a, "Haruhi") == "하루히" && a.size() == 3, "missing given name derived from a family-name entry");
        nanum::Glossary b = {{"Suzumiya Haruhi", "스즈미야 하루히"}, {"Haruhi", "하루히"}};
        nanum::harmonize_names(b);
        check(value(b, "Suzumiya") == "스즈미야", "missing family name derived from a given-name entry");
        nanum::Glossary c = {{"Itsuki Koizumi", "코이즈미 이츠키"}, {"Koizumi", "코이즈미"}, {"Itsuki", "이쯔키"}};
        nanum::harmonize_names(c);
        check(value(c, "Itsuki") == "이츠키" && value(c, "Koizumi") == "코이즈미",
              "a part that differs from the full name is corrected to the full name's word");
        nanum::Glossary d = {{"涼宮ハルヒ", "스즈미야 하루히"}, {"涼宮", "스즈미야"}, {"SOS団の部室", "SOS단 부실"},
                             {"SOS団", "SOS단"}};
        nanum::harmonize_names(d);
        check(value(d, "ハルヒ") == "하루히" && value(d, "の部室") == "(missing)",
              "CJK names split at a known part; particle remainders are not names");
        nanum::Glossary e = {{"Haruhi Suzumiya", "스즈미야 하루히"}, {"Kyon", "쿈"}};
        nanum::harmonize_names(e);
        check(e.size() == 2, "a full name listed in one order only, with no part entry, derives nothing");
        nanum::Glossary f = {{"Haruhi", "하루"}, {"Haruhi Suzumiya", "스즈미야 하루히"}};
        nanum::harmonize_names(f, 1);
        check(value(f, "Haruhi") == "하루" && value(f, "Suzumiya") == "스즈미야",
              "the user's (locked) entries are never changed");
        std::string rest;
        check(!nanum::detail::name_part("Haruhi Suzumiyama", "Suzumiya", rest) &&
                  nanum::detail::name_part("Haruhi Suzumiya", "suzumiya", rest) && rest == "Haruhi",
              "parts must fall on word boundaries (case-insensitive)");

        nanum::Glossary names = {{"Haruhi Suzumiya", "스즈미야 하루히"}, {"Suzumiya Haruhi", "스즈미야 하루히"},
                                 {"Mikuru Asahina", "아사히나 미쿠루"}, {"Asahina Mikuru", "아사히나 미쿠루"},
                                 {"Itsuki Koizumi", "코이즈미 이츠키"}, {"Koizumi Itsuki", "코이즈미 이츠키"},
                                 {"Yeager Eren", "에렌 예거"}, {"Eren Yeager", "에렌 예거"},
                                 {"Time Loop", "시간 루프"}};
        nanum::harmonize_names(names);
        check(value(names, "Suzumiya") == "스즈미야" && value(names, "Haruhi") == "하루히" &&
                  value(names, "Asahina") == "아사히나" && value(names, "Mikuru") == "미쿠루" &&
                  value(names, "Koizumi") == "코이즈미" && value(names, "Itsuki") == "이츠키",
              "family and given name paired with the full name's words by sound (either name order)");
        check(value(names, "Eren") == "에렌" && value(names, "Yeager") == "예거",
              "given-name-first hangul order paired by sound too");
        check(value(names, "Time") == "(missing)" && value(names, "Loop") == "(missing)",
              "phrases listed in one order only are not split into words");
        nanum::Glossary lone = {{"Kyon Smith", "에이 오"}, {"Smith Kyon", "에이 오"}};
        nanum::harmonize_names(lone);
        check(lone.size() == 2, "sounds that decide nothing derive nothing");
        check(nanum::glossary_prompt({"English", "Korean"}, "Hi").find("family name alone and the given name alone") !=
                      std::string::npos &&
                  nanum::profile_glossary_prompt("W", "t", "ja", "Korean").find("family name alone and the given name alone") !=
                      std::string::npos &&
                  nanum::window_prompt({"English", "Korean"}, {{"A", "B"}}, {{0, 0, "x", ""}}, 0, 0, 1)
                          .find("family name, given name or full name") != std::string::npos,
              "extraction, profile and translation prompts cover family/given/full names");
        auto ans = nanum::parse_glossary_answer("Kyon => 쿈\nKyon => 다른\nBad => <0xEC><0xB1>\nEren Yeager => 에렌 예거\n"
                                                "Yeager Eren => 에렌 예거\n");
        check(value(ans, "Kyon") == "쿈" && value(ans, "Bad") == "(missing)" && value(ans, "Yeager") == "예거",
              "answer parsing: first wins, undecodable dropped, names harmonised");
        check(nanum::parse_glossary("人 => 인\nA => 에이\nSOS団 => SOS단").size() == 1 &&
                  nanum::parse_glossary("人 => 인", false).size() == 1,
              "a single-character key is not a name (but the user's own lines are kept)");
        check(nanum::first_lines("a\nb\nc\nd", 2) == "a\nb\n" && nanum::first_lines("a", 5) == "a\n",
              "answer lines beyond the requested count are ignored");
        check(nanum::looping_answer("A => 1\nA => 1\nA => 1\nA => 1\nA => 1\nA => 1\nA => 1\nA => 1\nB => 2") &&
                  !nanum::looping_answer("A => 1\nB => 2\nC => 3\nD => 4\nE => 5\nF => 6\nG => 7\nH => 8") &&
                  !nanum::looping_answer("A => 1\nA => 1\nA => 1"),
              "a looping answer is recognised");
    }

    // Model-written entries are validated; main characters are always named in the live prompt.
    {
        using nanum::entry_valid;
        check(!entry_valid("'s Sister", "\xEC\x97\xAC\xEB\x8F\x99\xEC\x83\x9D", "Korean") &&
                  !entry_valid("\xE2\x80\x99s House", "\xEC\xA7\x91", "Korean") && entry_valid("Kyon", "\xEC\xBF\x88", "Korean"),
              "a key that starts with punctuation is rejected");
        check(!entry_valid("\xE3\x82\xAD\xE3\x83\xA7\xE3\x83\xB3", "\xED\x82\xA4\xE3\x83\xA7\xE3\x83\xB3", "Korean") &&
                  !entry_valid("Kyon", "\xED\x82\xA4\xE3\x83\xA7\xE3\x83\xB3\xEC\x9D\x98", "Korean") &&
                  !entry_valid("Kyon", "\xED\x82\xA4\xE3\x83\xA7\xE3\x83\xB3", "Korean"),
              "Korean values with kana are rejected");
        check(!entry_valid("Kyon", "\xEC\xBF\x88\xEC\x9D\x98", "Korean") &&
                  !entry_valid("Kyon", "K\xEC\xBF\x88", "Korean") && !entry_valid("Kyon", "Kyon\xEC\xBF\x88", "Korean") &&
                  !entry_valid("Kyoui", "\xEA\xB2\xBD\xEC\x9D\xB4 (Kyoui)", "Korean") &&
                  !entry_valid("\xE4\xBA\xBA", "\xEC\x82\xAC\xEB\x9E\x8C \xE4\xBA\xBA", "Korean"),
              "particle at the end, Latin inside a Hangul word, notes in parentheses and han characters are rejected");
        check(entry_valid("SOS Brigade", "SOS\xEB\x8B\xA8", "Korean") && entry_valid("Haruhi", "\xED\x95\x98\xEB\xA3\xA8\xED\x9E\x88", "Korean") &&
                  entry_valid("Date", "12\xEC\x9B\x94 16\xEC\x9D\xBC", "Korean") && entry_valid("Kyon", "Kyon", "Japanese") &&
                  entry_valid("Haruhi", "\xE3\x83\x8F\xE3\x83\xAB\xE3\x83\x92", "Japanese"),
              "legitimate values (acronym with Hangul, digits, other target languages) are kept");
        auto g = nanum::parse_glossary_answer("'s Sister => \xEC\x97\xAC\xEB\x8F\x99\xEC\x83\x9D\nKyon => \xED\x82\xA4\xE3\x83\xA7\xE3\x83\xB3\xEC\x9D\x98\n"
                                              "Haruhi => \xED\x95\x98\xEB\xA3\xA8\xED\x9E\x88\n", "Korean");
        check(g.size() == 1 && g[0].first == "Haruhi", "answers drop invalid entries instead of repairing them");
        check(nanum::parse_glossary("'s Sister => \xEC\x97\xAC\xEB\x8F\x99\xEC\x83\x9D", false).size() == 1,
              "the user's own lines are not validated");
        nanum::Profile prof;
        check(nanum::parse_profile(R"({"work":"w","original_language":"ja","glossary":["Kyon => \u30ad\u30e7\u30f3\uc758","Haruhi => \ud558\ub8e8\ud788"]})",
                                   prof, "Korean") && prof.glossary.size() == 1,
              "profile glossary entries are validated for the target language");

        nanum::Glossary cast = {{"Haruhi Suzumiya", "A B"}, {"Suzumiya Haruhi", "A B"}, {"Kyon", "C"}, {"Haruhi", "B"},
                                {"Tsuruya", "D"}, {"North High", "E"}, {"Alien", "F"}, {"SOS Brigade", "G"}};
        auto mc = nanum::main_characters(cast);
        check(mc.size() == 4 && mc[0].first == "Haruhi Suzumiya" && mc[1].first == "Kyon" && mc[2].first == "Tsuruya" &&
                  mc[3].first == "Alien",
              "main characters: full names listed in both orders first, then capitalised one-word names that are not parts of them");
        check(nanum::main_characters(cast, 1).size() == 1 && nanum::main_characters({}).empty(),
              "main characters are capped");
        nanum::Glossary film = {{"Itsuki Koizumi", "코이즈미 이츠키"}, {"Koizumi Itsuki", "코이즈미 이츠키"},
                                {"Koizumi", "코이즈미"}, {"Itsuki", "이츠키"}, {"Kyon", "쿈"}, {"Tsuruya", "츠루야"}};
        std::string text = nanum::main_characters_text(film);
        check(text == "Itsuki Koizumi = 코이즈미 이츠키 (Itsuki = 이츠키, Koizumi = 코이즈미); Kyon = 쿈; Tsuruya = 츠루야",
              "main characters as prompt text, with the part forms spelled out");
        auto hints = nanum::garbled_name_hints(film, {"Hey, Korsumi. Oh, hello there.", "Cozamy, have you seen it?",
                                                      "Coismy said Tsuruya was here. Cousin Corn Koizumi"});
        check(hints.size() == 3 && hints[0].word == "Korsumi" && hints[0].key == "Koizumi" && hints[0].value == "코이즈미" &&
                  hints[1].word == "Cozamy" && hints[2].word == "Coismy",
              "garbled spellings of a name (Korsumi/Cozamy/Coismy ~ Koizumi) are hinted; real words, exact names are not");
        std::string repaired;
        check(!nanum::repair_byte_tokens("\xEC\x98\xA4\xEB\x8A\x98 \xEF\xBF\xBD\xEF\xBF\xBD\xEC\x95\xBC", repaired) &&
                  nanum::repair_byte_tokens("\xEC\x98\xA4\xEB\x8A\x98", repaired),
              "a line with replacement characters (the model's own broken bytes) counts as failed");
    }

    // Profile answers.
    {
        nanum::Profile p;
        std::string answer =
            "Sure!\n```json\n{\"work\": \"The Melancholy of Haruhi Suzumiya\", \"original_language\": \"ja-JP\", "
            "\"glossary\": [\"Haruhi Suzumiya => 스즈미야 하루히\", \"ハルヒ => 하루히\", \"Kyon => 쿄\", "
            "\"Nagato => <0xEB><0x82><0x98>가토\", \"Asahina => <0xEB><0x82>\", \"kyon => 큐온\", \"the club => 동아리\"]}\n```";
        check(nanum::parse_profile(answer, p) && p.work == "The Melancholy of Haruhi Suzumiya" &&
                  p.original_language == "ja",
              "profile: JSON found inside chatter and fences, language normalised");
        check(p.glossary.size() == 4 && p.glossary[0].first == "Haruhi Suzumiya" && p.glossary[1].first == "ハルヒ" &&
                  p.glossary[3].first == "Nagato" && p.glossary[3].second == "나가토",
              "profile: glossary validated, byte tokens repaired, undecodable and duplicate entries dropped");
        check(nanum::parse_profile(R"({"work":"","original_language":"jpn","glossary":"Ab => 에이비\nBc => 비씨"})", p) &&
                  p.original_language == "ja" && p.glossary.size() == 2,
              "profile: glossary as one string, 3-letter code");
        check(nanum::parse_profile(R"({"work":"x","original_language":"unknown","glossary":{"Kyon":"쿄"}})", p) &&
                  p.original_language.empty() && p.glossary.size() == 1 && p.glossary[0].second == "쿄",
              "profile: unknown language stays empty, glossary as object");
        check(nanum::parse_profile(R"({"work":"<0xEC><0xB1>","original_language":"","glossary":[]})", p) &&
                  p.work.empty() && p.glossary.empty(),
              "profile: undecodable work dropped");
        check(!nanum::parse_profile("I do not know this film.", p) && !nanum::parse_profile("{broken", p),
              "profile: no JSON object fails");
        nlohmann::json j = nlohmann::json::parse(nanum::profile_json(
            {"W", "ja", {{"Kyon", "쿄"}, {"Haruhi", "하루히"}}}));
        check(j["work"] == "W" && j["original_language"] == "ja" && j["glossary"] == "Kyon => 쿄\nHaruhi => 하루히",
              "profile JSON as documented in the header");
        std::string prompt = nanum::profile_prompt("Disappearance_Haruhi_Suzumiya", "en,ja", "Korean");
        check(prompt.find("Disappearance_Haruhi_Suzumiya") != std::string::npos && prompt.find("en,ja") != std::string::npos &&
                  nanum::profile_prompt("T", "", "Korean").find("Audio languages") == std::string::npos,
              "profile prompt names the title and the audio languages");
    }

    // Text input has independent live and transcript-collection modes.
    struct TextResult {
        int events = 0;
        double pts = 0, duration = 0;
        std::string source;
        bool translated = false;
    } text_result;
    auto text_cb = +[](void *user, double pts, double duration,
                       const char *source, const char *translation) {
        auto &r = *static_cast<TextResult *>(user);
        r.events++;
        r.pts = pts;
        r.duration = duration;
        r.source = source;
        r.translated = translation != nullptr;
    };
    nanum_ai_config text_cfg{};
    text_cfg.abi_version = NANUM_AI_ABI_VERSION;
    text_cfg.translate_only = 1;
    auto text_ai = nanum_ai_create(&text_cfg, text_cb, &text_result);
    if (text_ai) {
        nanum_ai_push_text(text_ai, 12.0, 3.5, "Text-only subtitle.");
        nanum_ai_wait_idle(text_ai, 5000);
        nanum_ai_destroy(text_ai);
    }
    check(text_result.events == 1 && text_result.pts == 12.0 &&
          text_result.duration == 3.5 && text_result.source == "Text-only subtitle." &&
          !text_result.translated, "model-free live text preserves subtitle timing and source");
    text_result = {};
    text_cfg.scan_only = 1;
    text_ai = nanum_ai_create(&text_cfg, text_cb, &text_result);
    size_t collected = 0;
    if (text_ai) {
        nanum_ai_push_text(text_ai, 12.0, 3.5, "First subtitle.");
        nanum_ai_push_text(text_ai, 16.0, 2.0, "Second subtitle.");
        collected = nanum_ai_transcript_size(text_ai);
        nanum_ai_destroy(text_ai);
    }
    check(collected == 2 && text_result.events == 0,
          "model-free scan collects distinct cues without live events");

    // ABI 6 exports.
    {
        nanum_ai_config c{};
        c.abi_version = NANUM_AI_ABI_VERSION;
        c.translate_only = 1;
        c.translate_style = "polite";
        c.glossary = "Kyon => 쿄\nkyon => 다른\nHaruhi -> 하루히";
        nanum_ai *ai = nanum_ai_create(&c, nullptr, nullptr);
        std::string got1, got2, got3;
        size_t len3 = 0, len_small = 0;
        char cut_buf[8] = "";
        if (ai) {
            char buf[256];
            size_t n = nanum_ai_get_glossary(ai, buf, sizeof(buf));
            got1.assign(buf, n);
            nanum_ai_set_style(ai, "casual", nullptr);
            nanum_ai_set_glossary(ai, "Nagato => 나가토");
            n = nanum_ai_get_glossary(ai, buf, sizeof(buf));
            got2.assign(buf, n);
            len_small = nanum_ai_get_glossary(ai, cut_buf, sizeof(cut_buf));
            nanum_ai_set_glossary(ai, nullptr);
            len3 = nanum_ai_get_glossary(ai, buf, sizeof(buf));
            got3 = buf;
            nanum_ai_destroy(ai);
        }
        check(got1 == "Kyon => 쿄\nHaruhi => 하루히", "config glossary parsed, duplicate keys dropped");
        check(got2 == "Nagato => 나가토" && len_small == got2.size() && std::strlen(cut_buf) < sizeof(cut_buf) &&
                  std::string("Nagato => 나가토").compare(0, std::strlen(cut_buf), cut_buf) == 0,
              "set_glossary replaces; get_glossary reports the full length and truncates safely");
        check(len3 == 0 && got3.empty(), "set_glossary(NULL) clears");
        char tiny[8];
        nanum_ai_config pc{};
        pc.abi_version = NANUM_AI_ABI_VERSION;
        check(nanum_ai_profile(&pc, "Some Film", "en,ja", tiny, sizeof(tiny)) == 0 &&
                  std::strlen(nanum_ai_last_error()) > 0,
              "profile without an endpoint fails with an error");
    }

    // Windows OCR on a bitmap rendered with GDI.
    {
        char langs[128] = "";
        nanum_ai_ocr_languages(langs, sizeof(langs));
        std::printf("  OCR languages installed: %s\n", *langs ? langs : "(none)");
        std::string have = std::string(",") + langs + ",";
        char text[1024];
        unsigned char blank[16 * 16];
        std::memset(blank, 255, sizeof(blank));
        check(nanum_ai_ocr(blank, 16, 16, 16, "xx-not-a-language", text, sizeof(text)) == 0 &&
                  std::string(nanum_ai_last_error()).find("not installed") != std::string::npos,
              "OCR: a missing language pack is reported clearly");
        check(nanum_ai_ocr(nullptr, 0, 0, 0, "en", text, sizeof(text)) == 0 && std::strlen(nanum_ai_last_error()) > 0,
              "OCR: an invalid bitmap is rejected");
        struct Sample {
            const char *lang;
            const wchar_t *text, *second, *font;
        } samples[] = {
            {"en", L"I don't think we should go there tonight.", L"Wait for me, I am coming with you.", L"Arial"},
            {"ko", L"오늘은 날씨가 정말 좋네요", L"저도 같이 가고 싶어요", L"Malgun Gothic"},
            {"ja", L"今日はとても寒いですね", L"私も一緒に行きたいです", L"Yu Gothic"},
        };
        const Sample *sample = nullptr;
        for (auto &s : samples)
            if (!sample && have.find(std::string(",") + s.lang + ",") != std::string::npos)
                sample = &s;
        if (!sample) {
            std::printf("  skip OCR rendering test: none of the en/ko/ja OCR language packs is installed\n");
        } else {
            std::printf("  OCR rendering test in '%s'%s\n", sample->lang,
                        std::strcmp(sample->lang, "en") ? " (the English pack is not installed)" : "");
            auto render = [&](const wchar_t *line, int px, int pad, int &w, int &h, std::vector<unsigned char> &gray) {
                HDC dc = CreateCompatibleDC(nullptr);
                HFONT font = CreateFontW(-px, 0, 0, 0, FW_BOLD, 0, 0, 0, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS,
                                         CLIP_DEFAULT_PRECIS, ANTIALIASED_QUALITY, DEFAULT_PITCH, sample->font);
                HGDIOBJ old = SelectObject(dc, font);
                RECT measure = {0, 0, 0, 0};
                DrawTextW(dc, line, -1, &measure, DT_CALCRECT | DT_SINGLELINE);
                w = measure.right + 2 * pad;
                h = measure.bottom + 2 * pad;
                BITMAPINFO bi = {};
                bi.bmiHeader = {sizeof(BITMAPINFOHEADER), w, -h, 1, 32, BI_RGB};
                void *bits = nullptr;
                HBITMAP dib = CreateDIBSection(dc, &bi, DIB_RGB_COLORS, &bits, nullptr, 0);
                HGDIOBJ oldbmp = SelectObject(dc, dib);
                std::memset(bits, 255, (size_t)w * h * 4);
                SetBkMode(dc, TRANSPARENT);
                SetTextColor(dc, RGB(0, 0, 0));
                RECT r = {pad, pad, w, h};
                DrawTextW(dc, line, -1, &r, DT_SINGLELINE | DT_NOCLIP);
                gray.resize((size_t)w * h);
                const unsigned char *p = (const unsigned char *)bits;
                for (size_t i = 0; i < gray.size(); i++)
                    gray[i] = p[i * 4 + 1];
                SelectObject(dc, oldbmp);
                DeleteObject(dib);
                SelectObject(dc, old);
                DeleteObject(font);
                DeleteDC(dc);
            };
            auto utf8 = [](const wchar_t *s) {
                char b[256];
                WideCharToMultiByte(CP_UTF8, 0, s, -1, b, sizeof(b), nullptr, nullptr);
                return std::string(b);
            };
            // Letters, digits and non-ASCII characters only: spacing and punctuation vary.
            auto key = [](const std::string &s) {
                std::string k;
                for (unsigned char c : s)
                    if (c >= 0x80)
                        k += (char)c;
                    else if (std::isalnum(c))
                        k += (char)std::tolower(c);
                return k;
            };
            const std::string want = key(utf8(sample->text));
            std::vector<unsigned char> gray;
            int w = 0, h = 0;
            render(sample->text, 48, 20, w, h, gray);
            bool ok = nanum_ai_ocr(gray.data(), w, h, w, sample->lang, text, sizeof(text)) != 0;
            std::printf("  OCR read: '%s'\n", ok ? text : nanum_ai_last_error());
            check(ok && key(text) == want, "OCR: text rendered with GDI is recognised");
            // Stride larger than the width, and a full language tag.
            std::vector<unsigned char> padded((size_t)(w + 37) * h, 255);
            for (int y = 0; y < h; y++)
                std::memcpy(&padded[(size_t)y * (w + 37)], &gray[(size_t)y * w], (size_t)w);
            ok = nanum_ai_ocr(padded.data(), w, h, w + 37, (std::string(sample->lang) + "-XX").c_str(), text, sizeof(text)) != 0;
            check(ok && key(text) == want, "OCR: stride beyond the width and a language tag with a region are handled");
            // A bitmap taller than the recogniser accepts is scaled down, not rejected.
            render(sample->second, 40, 10, w, h, gray);
            std::vector<unsigned char> huge((size_t)w * 2 * 3300, 255);
            for (int y = 0; y < h; y++)
                std::memcpy(&huge[(size_t)(y + 1500) * w * 2], &gray[(size_t)y * w], (size_t)w);
            ok = nanum_ai_ocr(huge.data(), w * 2, 3300, w * 2, sample->lang, text, sizeof(text)) != 0;
            std::printf("  OCR read (scaled down): '%s'\n", ok ? text : nanum_ai_last_error());
            check(ok, "OCR: a bitmap larger than the recogniser accepts is scaled down, not rejected");
            char tiny[4];
            render(sample->text, 48, 20, w, h, gray);
            check(nanum_ai_ocr(gray.data(), w, h, w, sample->lang, tiny, sizeof(tiny)) == 0 &&
                      std::string(nanum_ai_last_error()).find("output buffer") != std::string::npos,
                  "OCR: text longer than the output buffer fails");
            // Any thread, concurrently.
            std::vector<std::thread> pool;
            std::atomic<int> good{0};
            render(sample->text, 48, 20, w, h, gray);
            for (int i = 0; i < 4; i++)
                pool.emplace_back([&] {
                    char t[512];
                    good += nanum_ai_ocr(gray.data(), w, h, w, sample->lang, t, sizeof(t)) && key(t) == want;
                });
            for (auto &t : pool)
                t.join();
            check(good == 4, "OCR: four concurrent calls from other threads all succeed");
        }
    }

    std::printf("%s\n", bad ? "SELFTEST FAILED" : "selftest passed");
    return bad ? 1 : 0;
}

// ------------------------------------------------------------- full modes

struct Options {
    std::string engine = "ollama", model = "nemotron-3-super:cloud", omp_model, omp_command;
    std::string stt = "models/ggml-small.en.bin", vad = "models/ggml-silero-v5.1.2.bin";
    std::string lang = "en", target = "Korean";
};

static double now_s()
{
    return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count();
}

struct SrtLine { double pts, dur; std::string text; };

static double parse_srt_time(const std::string &s)
{
    int h = 0, m = 0, sec = 0, ms = 0;
    std::sscanf(s.c_str(), "%d:%d:%d%*[,.]%d", &h, &m, &sec, &ms);
    return h * 3600.0 + m * 60.0 + sec + ms / 1000.0;
}

static std::vector<SrtLine> read_srt(const char *path)
{
    std::vector<SrtLine> v;
    std::ifstream f(path, std::ios::binary);
    std::string line;
    SrtLine cur{};
    bool in_text = false;
    auto flush = [&] {
        if (in_text)
            v.push_back(cur);
        in_text = false;
        cur = {};
    };
    while (std::getline(f, line)) {
        if (!line.empty() && line.back() == '\r')
            line.pop_back();
        if (line.compare(0, 3, "\xEF\xBB\xBF") == 0)
            line.erase(0, 3);
        size_t arrow = line.find("-->");
        if (arrow != std::string::npos) {
            flush();
            cur.pts = parse_srt_time(line.substr(0, arrow));
            cur.dur = parse_srt_time(line.substr(arrow + 3)) - cur.pts;
            in_text = true;
        } else if (line.empty()) {
            flush();
        } else if (in_text) {
            cur.text += (cur.text.empty() ? "" : "\n") + line;
        }
    }
    flush();
    return v;
}

static std::string tr_endpoint()
{
    std::string e = std::getenv("NANUM_AI_TR_ENDPOINT") ? std::getenv("NANUM_AI_TR_ENDPOINT")
                                                        : "http://127.0.0.1:11434";
    return e == "off" ? "" : e;
}

static nanum_ai *create_for(const Options &o, bool scan_only, nanum_ai_event_cb cb)
{
    std::string endpoint = tr_endpoint();
    nanum_ai_config cfg = {};
    cfg.abi_version = NANUM_AI_ABI_VERSION;
    cfg.stt_model_path = o.stt.c_str();
    cfg.vad_model_path = o.vad.c_str();
    cfg.language = o.lang.c_str();
    cfg.use_gpu = !std::strcmp(nanum_ai_backend(), "cuda");
    cfg.translate_endpoint = endpoint.c_str();
    cfg.translate_model = o.model.c_str();
    cfg.target_language = o.target.c_str();
    cfg.translate_engine = o.engine.c_str();
    cfg.omp_model = o.omp_model.c_str();
    cfg.omp_command = o.omp_command.c_str();
    cfg.scan_only = scan_only;
    const char *style = std::getenv("NANUM_AI_TR_STYLE"), *glossary = std::getenv("NANUM_AI_TR_GLOSSARY");
    cfg.translate_style = style;
    cfg.translate_style_text = std::getenv("NANUM_AI_TR_STYLE_TEXT");
    cfg.glossary = glossary;
    nanum_ai *ai = nanum_ai_create(&cfg, cb, nullptr);
    if (!ai)
        std::fprintf(stderr, "create failed: %s\n", nanum_ai_last_error());
    return ai;
}

struct FullResult {
    std::mutex m;
    std::condition_variable cv;
    bool done = false;
    std::string error;
    std::vector<std::string> src, tr;
    std::vector<double> pts;
    double t0 = 0;
};

static void on_full(void *user, double progress, const nanum_ai_line *lines, size_t n, const char *error)
{
    auto *r = (FullResult *)user;
    if (!lines && !error) {
        std::fprintf(stderr, "  progress %5.1f%%  (+%.1fs)\n", progress * 100, now_s() - r->t0);
        return;
    }
    std::lock_guard<std::mutex> lk(r->m);
    if (error)
        r->error = error;
    for (size_t i = 0; i < n; i++) {
        r->pts.push_back(lines[i].pts);
        r->src.push_back(lines[i].source);
        r->tr.push_back(lines[i].translation);
    }
    r->done = true;
    r->cv.notify_all();
}

struct ExportCheck {
    size_t n = 0;
    bool sorted = true, no_translation = true;
};

static void on_export(void *user, const nanum_ai_line *lines, size_t n)
{
    auto *c = (ExportCheck *)user;
    c->n = n;
    for (size_t i = 0; i < n; i++) {
        c->no_translation &= lines[i].translation == nullptr && lines[i].source != nullptr;
        if (i)
            c->sorted &= lines[i - 1].pts <= lines[i].pts;
    }
}

static int run_full_translate(nanum_ai *ai)
{
    std::printf("transcript: %zu lines\n", nanum_ai_transcript_size(ai));
    ExportCheck ex;
    size_t exported = nanum_ai_transcript_export(ai, on_export, &ex);
    std::printf("export: %zu lines, sorted=%d, translation-free=%d\n", exported, ex.sorted,
                ex.no_translation);
    if (exported != nanum_ai_transcript_size(ai) || exported != ex.n || !ex.sorted ||
        !ex.no_translation) {
        std::fprintf(stderr, "transcript export mismatch\n");
        return 1;
    }
    FullResult r;
    r.t0 = now_s();
    if (nanum_ai_translate_all(ai, on_full, &r) != 0) {
        std::fprintf(stderr, "translate_all refused to start\n");
        return 1;
    }
    std::unique_lock<std::mutex> lk(r.m);
    if (const char *c = std::getenv("NANUM_TEST_CANCEL_AFTER_MS")) {
        // Cancel mid-run: there must be no final callback and no stall.
        r.cv.wait_for(lk, std::chrono::milliseconds(std::atoi(c)), [&] { return r.done; });
        double t = now_s();
        lk.unlock();
        nanum_ai_cancel_full(ai);
        nanum_ai_cancel_full(ai);
        lk.lock();
        bool late = r.cv.wait_for(lk, std::chrono::seconds(3), [&] { return r.done; });
        std::printf("cancel after %s ms: returned in %.2fs, final callback %s\n", c, now_s() - t,
                    late ? "CALLED (wrong)" : "not called (ok)");
        return late ? 1 : 0;
    }
    r.cv.wait(lk, [&] { return r.done; });
    double el = now_s() - r.t0;
    if (!r.error.empty()) {
        std::printf("FULL TRANSLATION ERROR after %.1fs: %s\n", el, r.error.c_str());
        return 1;
    }
    size_t empty = 0;
    for (size_t i = 0; i < r.src.size(); i++) {
        std::printf("[%8.2f] %s\n%*s=> %s\n", r.pts[i], r.src[i].c_str(), 11, "", r.tr[i].c_str());
        empty += r.tr[i].empty();
    }
    std::printf("full translation: %zu lines, %zu empty, %.1fs\n", r.src.size(), empty, el);
    return empty == r.src.size() ? 1 : 0;
}

static int full_srt(const char *path, const Options &o)
{
    auto lines = read_srt(path);
    nanum_ai *ai = create_for(o, true, on_event);
    if (!ai)
        return 1;
    for (auto &l : lines)
        nanum_ai_push_text(ai, l.pts, l.dur, l.text.c_str());
    std::printf("srt: %zu cues, engine=%s model=%s\n", lines.size(), o.engine.c_str(),
                (o.engine == "omp" ? o.omp_model : o.model).c_str());
    int rc = run_full_translate(ai);
    std::printf("live events delivered in scan_only: %d (must be 0)\n", n_events);
    nanum_ai_destroy(ai);
    return rc || n_events ? 1 : 0;
}

static int full_wav(const char *path, const Options &o)
{
    std::vector<float> pcm = read_wav(path);
    if (pcm.empty()) {
        std::fprintf(stderr, "cannot read wav\n");
        return 1;
    }
    nanum_ai *ai = create_for(o, true, on_event);
    if (!ai)
        return 1;
    double t = now_s();
    for (size_t i = 0; i < pcm.size(); i += 4000)
        nanum_ai_push_audio(ai, pcm.data() + i, std::min<size_t>(4000, pcm.size() - i), i / 16000.0);
    nanum_ai_flush(ai);
    bool idle = nanum_ai_wait_idle(ai, 600000);
    std::printf("scan: %.1fs audio in %.2fs (%s), engine=%s\n", pcm.size() / 16000.0, now_s() - t,
                idle ? "idle" : "TIMEOUT", o.engine.c_str());
    int rc = run_full_translate(ai);
    std::printf("live events delivered in scan_only: %d (must be 0)\n", n_events);
    nanum_ai_destroy(ai);
    return rc || n_events || !idle ? 1 : 0;
}

// Live text path: all cues pushed at once, translation starts at the playhead.
static int live_srt(const char *path, double playhead, const Options &o)
{
    auto lines = read_srt(path);
    nanum_ai *ai = create_for(o, false, on_event);
    if (!ai)
        return 1;
    t_start = std::chrono::steady_clock::now();
    nanum_ai_set_playhead(ai, playhead);
    for (auto &l : lines)
        nanum_ai_push_text(ai, l.pts, l.dur, l.text.c_str());
    std::printf("processed_until right after push: %.2f\n", nanum_ai_processed_until(ai));
    nanum_ai_flush(ai);
    bool ok = nanum_ai_wait_idle(ai, 600000);
    std::printf("live text: %zu cues, playhead %.1f, %d events, %d translated (%s)\n", lines.size(),
                playhead, n_events, n_translated, ok ? "idle" : "TIMEOUT");
    double pu = nanum_ai_processed_until(ai);
    std::printf("processed_until when idle: %.2f (last cue pts %.2f)\n", pu,
                lines.empty() ? 0.0 : lines.back().pts);
    nanum_ai_destroy(ai);
    return ok ? 0 : 1;
}

// nanum_ai_ocr() on an image file (png/bmp/jpg through WIC), printing the text.
static int run_ocr(const char *path, const char *lang)
{
    std::vector<unsigned char> gray;
    UINT w = 0, h = 0;
    HRESULT hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    IWICImagingFactory *factory = nullptr;
    IWICBitmapDecoder *decoder = nullptr;
    IWICBitmapFrameDecode *frame = nullptr;
    IWICFormatConverter *conv = nullptr;
    std::wstring wpath(std::strlen(path), L'\0');
    wpath.resize(MultiByteToWideChar(CP_UTF8, 0, path, -1, wpath.data(), (int)wpath.size() + 1) - 1);
    if (SUCCEEDED(hr) || hr == RPC_E_CHANGED_MODE)
        hr = CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&factory));
    if (SUCCEEDED(hr))
        hr = factory->CreateDecoderFromFilename(wpath.c_str(), nullptr, GENERIC_READ, WICDecodeMetadataCacheOnDemand, &decoder);
    if (SUCCEEDED(hr))
        hr = decoder->GetFrame(0, &frame);
    if (SUCCEEDED(hr))
        hr = factory->CreateFormatConverter(&conv);
    if (SUCCEEDED(hr))
        hr = conv->Initialize(frame, GUID_WICPixelFormat8bppGray, WICBitmapDitherTypeNone, nullptr, 0.0,
                              WICBitmapPaletteTypeCustom);
    if (SUCCEEDED(hr))
        hr = conv->GetSize(&w, &h);
    if (SUCCEEDED(hr)) {
        gray.resize((size_t)w * h);
        hr = conv->CopyPixels(nullptr, w, (UINT)gray.size(), gray.data());
    }
    for (IUnknown *p : {(IUnknown *)conv, (IUnknown *)frame, (IUnknown *)decoder, (IUnknown *)factory})
        if (p)
            p->Release();
    if (FAILED(hr)) {
        std::fprintf(stderr, "cannot read image '%s' (0x%08lx)\n", path, (unsigned long)hr);
        return 1;
    }
    char langs[128];
    nanum_ai_ocr_languages(langs, sizeof(langs));
    std::vector<char> text(1 << 16);
    double t0 = now_s();
    if (!nanum_ai_ocr(gray.data(), (int)w, (int)h, (int)w, lang, text.data(), text.size())) {
        std::fprintf(stderr, "OCR failed: %s\n", nanum_ai_last_error());
        return 1;
    }
    std::printf("%ux%u, lang %s (installed: %s), %.2fs\n%s\n", w, h, lang, langs, now_s() - t0, text.data());
    return 0;
}

static bool parse_options(int argc, char **argv, int first, Options &o)
{
    for (int i = first; i + 1 < argc; i += 2) {
        std::string k = argv[i], v = argv[i + 1];
        if (k == "--engine") o.engine = v;
        else if (k == "--model") o.model = v;
        else if (k == "--omp-model") o.omp_model = v;
        else if (k == "--omp-command") o.omp_command = v;
        else if (k == "--stt") o.stt = v;
        else if (k == "--vad") o.vad = v;
        else if (k == "--lang") o.lang = v;
        else if (k == "--target") o.target = v;
        else {
            std::fprintf(stderr, "unknown option %s\n", k.c_str());
            return false;
        }
    }
    return true;
}

// One nanum_ai_profile() call, printed readably.
static int run_profile(const char *title, const char *langs, const Options &o)
{
    std::string endpoint = tr_endpoint();
    nanum_ai_config cfg = {};
    cfg.abi_version = NANUM_AI_ABI_VERSION;
    cfg.translate_endpoint = endpoint.c_str();
    cfg.translate_model = o.model.c_str();
    cfg.target_language = o.target.c_str();
    cfg.translate_engine = o.engine.c_str();
    cfg.omp_model = o.omp_model.c_str();
    cfg.omp_command = o.omp_command.c_str();
    std::vector<char> buf(1 << 16);
    double t0 = now_s();
    if (!nanum_ai_profile(&cfg, title, langs, buf.data(), buf.size())) {
        std::fprintf(stderr, "profile failed: %s\n", nanum_ai_last_error());
        return 1;
    }
    nlohmann::json j = nlohmann::json::parse(buf.data(), nullptr, false);
    if (!j.is_object()) {
        std::fprintf(stderr, "profile returned invalid JSON: %s\n", buf.data());
        return 1;
    }
    std::printf("profile in %.1fs (%s, title '%s', audio '%s')\n", now_s() - t0,
                o.engine == "omp" ? o.omp_model.c_str() : o.model.c_str(), title, langs);
    std::printf("work: %s\noriginal_language: %s\nglossary (%zu entries):\n%s\n",
                j.value("work", "").c_str(), j.value("original_language", "").c_str(),
                nanum::parse_glossary(j.value("glossary", ""), false).size(),
                j.value("glossary", "").c_str());
    bool tokens = j.dump().find("<0x") != std::string::npos;
    std::printf("byte tokens left in output: %s\n", tokens ? "YES (bug)" : "none");
    return tokens ? 1 : 0;
}

int main(int argc, char **argv)
{
    if (argc > 1 && !std::strcmp(argv[1], "--selftest"))
        return selftest();
    if (argc > 2 && !std::strcmp(argv[1], "--ocr"))
        return run_ocr(argv[2], argc > 3 ? argv[3] : "en");
    if (argc > 3 && !std::strcmp(argv[1], "--profile")) {
        Options o;
        if (const char *m = std::getenv("NANUM_AI_TR_MODEL"))
            o.model = m;
        return parse_options(argc, argv, 4, o) ? run_profile(argv[2], argv[3], o) : 2;
    }
    if (argc > 2 && (!std::strcmp(argv[1], "--full-srt") || !std::strcmp(argv[1], "--full-wav") ||
                     !std::strcmp(argv[1], "--live-srt"))) {
        bool live = !std::strcmp(argv[1], "--live-srt");
        int first_opt = live ? 4 : 3;
        if (live && argc < 4) {
            std::fprintf(stderr, "usage: --live-srt file.srt playhead [options]\n");
            return 2;
        }
        Options o;
        if (!parse_options(argc, argv, first_opt, o))
            return 2;
        if (live)
            return live_srt(argv[2], std::atof(argv[3]), o);
        return !std::strcmp(argv[1], "--full-srt") ? full_srt(argv[2], o) : full_wav(argv[2], o);
    }
    if (argc < 4) {
        std::fprintf(stderr, "usage: %s stt.bin vad.bin file.wav [start_pts] [lang] [cache.jsonl]\n", argv[0]);
        return 2;
    }
    double start = argc > 4 ? std::atof(argv[4]) : 0.0;
    const char *lang = argc > 5 ? argv[5] : "en";
    const char *cache = argc > 6 ? argv[6] : nullptr;

    std::vector<float> pcm = read_wav(argv[3]);
    if (pcm.empty()) {
        std::fprintf(stderr, "cannot read wav\n");
        return 1;
    }

    std::string endpoint = tr_endpoint();
    std::string model = std::getenv("NANUM_AI_TR_MODEL") ? std::getenv("NANUM_AI_TR_MODEL")
                                                         : "gemma4:latest";
    std::string style = std::getenv("NANUM_AI_TR_STYLE") ? std::getenv("NANUM_AI_TR_STYLE") : "natural";
    std::string style_text = std::getenv("NANUM_AI_TR_STYLE_TEXT") ? std::getenv("NANUM_AI_TR_STYLE_TEXT") : "";
    std::string glossary_env = std::getenv("NANUM_AI_TR_GLOSSARY") ? std::getenv("NANUM_AI_TR_GLOSSARY") : "";
    nanum_ai_config cfg = {};
    cfg.abi_version = NANUM_AI_ABI_VERSION;
    cfg.stt_model_path = argv[1];
    cfg.vad_model_path = argv[2];
    cfg.language = lang;
    cfg.use_gpu = !std::strcmp(nanum_ai_backend(), "cuda");
    cfg.translate_endpoint = endpoint.c_str();
    cfg.translate_model = model.c_str();
    cfg.target_language = "Korean";
    cfg.cache_path = cache;
    cfg.translate_style = style.c_str();
    cfg.translate_style_text = style_text.c_str();
    cfg.glossary = glossary_env.c_str();

    auto t_load = std::chrono::steady_clock::now();
    nanum_ai *ai = nanum_ai_create(&cfg, on_event, nullptr);
    if (!ai) {
        std::fprintf(stderr, "create failed: %s\n", nanum_ai_last_error());
        return 1;
    }
    std::printf("model load: %.2fs, audio: %.1fs, start_pts=%.2f, translate=%s (%s), style=%s%s\n",
                std::chrono::duration<double>(std::chrono::steady_clock::now() - t_load).count(),
                pcm.size() / 16000.0, start, endpoint.empty() ? "off" : model.c_str(),
                cache ? cache : "no cache", cfg.translate_style,
                glossary_env.empty() ? "" : ", glossary from NANUM_AI_TR_GLOSSARY");

    t_start = std::chrono::steady_clock::now();
    const size_t block = 4000;      // 0.25 s, like decoded packets
    for (size_t i = 0; i < pcm.size(); i += block) {
        size_t n = std::min(block, pcm.size() - i);
        nanum_ai_push_audio(ai, pcm.data() + i, n, start + i / 16000.0);
    }
    nanum_ai_flush(ai);
    bool ok = nanum_ai_wait_idle(ai, 600000);
    std::printf("done in %.2fs wall (%s): %d events, %d translated\n",
                std::chrono::duration<double>(std::chrono::steady_clock::now() - t_start).count(),
                ok ? "idle" : "TIMEOUT", n_events, n_translated);
    nanum_ai_destroy(ai);
    return ok ? 0 : 1;
}
