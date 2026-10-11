#include "nanum_ai.h"

#include <algorithm>
#include <unordered_set>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "ggml.h"
#include "fulltranslate.h"
#include "textclean.h"
#include "translator.h"
#include "ocr.h"
#include "profile.h"
#include "split.h"
#include "whisper.h"
#ifdef NANUM_AI_CUDA
#include <cuda_runtime_api.h>
#endif

namespace {

constexpr int    SR            = 16000;
constexpr double WINDOW_S      = 20.0;  // process once this much audio is buffered
constexpr double TAIL_HOLD_S   = 1.0;   // speech ending this close to the window
                                        // end may continue in the next window
constexpr double PAD_S         = 0.25;  // context added around a speech segment
constexpr double MIN_INPUT_S   = 1.1;   // whisper rejects clips shorter than 1 s
constexpr float  NO_SPEECH_MAX = 0.6f;
constexpr size_t MAX_BATCH     = 6;     // lines per translation request
constexpr int    PROFILE_IDENTIFY_MS  = 30000;  // nanum_ai_profile(): identification request
constexpr int    PROFILE_BUDGET_MS    = 60000;  // ... both requests together, where possible
constexpr int    PROFILE_MIN_NAMES_MS = 15000;  // ... the names request always gets this much
constexpr int    PROFILE_NAMES_TOKENS = 1500;   // ... and the most it may write (about 60 lines)
constexpr size_t PROFILE_NAMES_LINES = 60;      // ... lines of it used (what the prompt asks for)
constexpr double PROFILE_REPEAT_PENALTY = 1.2;
constexpr double PROFILE_RETRY_TEMPERATURE = 0.8;

thread_local std::string g_error;

void log_cb(enum ggml_log_level level, const char *text, void *)
{
    if (level >= GGML_LOG_LEVEL_WARN)
        std::fputs(text, stderr);
}

struct Segment {
    double t0, t1;      // seconds, relative to the start of the analysed audio
};

struct Job {
    uint64_t gen;
    double pts, dur;
    std::string text;
    std::string lang;           // spoken language of the line ("en", "ja", ...)
    bool text_line = false;     // from a text subtitle, not from STT
};

std::string trim(const std::string &s)
{
    size_t a = s.find_first_not_of(" \t\r\n");
    if (a == std::string::npos)
        return "";
    size_t b = s.find_last_not_of(" \t\r\n");
    return s.substr(a, b - a + 1);
}

// Whisper tends to emit a lone "you" for very short noise bursts, and a few digits for music.
bool is_short_hallucination(const std::string &s, double dur)
{
    if (nanum::is_number_noise(s))
        return true;                // "0.3." for music
    if (dur >= 0.6)
        return false;
    std::string t;
    for (unsigned char c : s)
        if (std::isalnum(c))
            t += (char)std::tolower(c);
    return t == "you";
}

std::string language_name(const std::string &code)
{
    if (code == "en") return "English";
    if (code == "ja") return "Japanese";
    if (code == "ko") return "Korean";
    if (code == "zh") return "Chinese";
    if (code == "fr") return "French";
    if (code == "de") return "German";
    if (code == "es") return "Spanish";
    return "the source language";
}

TranslatorConfig translator_config(const nanum_ai_config *cfg)
{
    TranslatorConfig tc;
    tc.model = cfg->translate_model && *cfg->translate_model ? cfg->translate_model
                                                              : "gemma4:latest";
    tc.target_language = cfg->target_language && *cfg->target_language
                             ? cfg->target_language : "Korean";
    tc.timeout_ms = cfg->translate_timeout_ms > 0 ? cfg->translate_timeout_ms : 40000;
    tc.context_lines = cfg->translate_context_lines > 0 ? cfg->translate_context_lines : 3;
    if (cfg->translate_endpoint && *cfg->translate_endpoint) {
        tc.endpoint = cfg->translate_endpoint;
        if (cfg->cache_path)
            tc.cache_path = cfg->cache_path;
    }
    return tc;
}

} // namespace

struct nanum_ai {
    std::string stt_path, vad_path, language;
    std::string multi_path, cur_model_path;
    std::string want_language;      // latest requested language (guarded by m)
    std::string pending_language;   // applied by the STT thread between windows
    bool language_pending = false;
    double processed = -1;          // audio analysed up to here (guarded by m)
    double last_delivered = -1;     // pts of the last line handed to the callback
    int use_gpu = 1, n_threads = 0;
    nanum_ai_event_cb cb = nullptr;
    void *user = nullptr;

    whisper_context *wctx = nullptr;
    whisper_vad_context *vctx = nullptr;
    std::unique_ptr<Translator> tr;

    std::mutex m;                       // guards everything below it
    std::condition_variable cv;         // STT thread wakeup
    std::condition_variable tcv;        // translator thread wakeup
    std::condition_variable idle_cv;
    std::vector<float> buf;             // pending audio
    double buf_pts = 0;                 // timestamp of buf[0]
    double next_pts = 0;                // timestamp expected for the next chunk
    bool have_audio = false;
    std::atomic<uint64_t> gen{0};       // bumped on every discontinuity
    bool flush = false;
    bool stop = false;
    std::atomic<bool> aborting{false};  // destroy: abandon the whisper computation in flight
    std::atomic<uint64_t> work_gen{0};  // generation of the audio being transcribed (STT thread)
    bool stt_busy = false;
    std::deque<Job> tq;                 // lines waiting for translation
    bool tr_busy = false;
    double text_ready = -1;             // max pts of pushed live text lines, -1: none
    double busy_min = -1, busy_end = -1;    // text batch being translated

    // STT-thread-owned: audio kept from the previous window.
    std::vector<float> carry;
    double carry_pts = 0;
    uint64_t carry_gen = 0;

    // ABI 4 --------------------------------------------------------------
    bool scan_only = false;
    bool no_stt = false;                // translate_only: no whisper/VAD, no STT thread
    std::atomic<double> playhead{-1};   // live text mode: translate from here first
    TranslatorConfig tcfg;              // also used by translate_all()
    std::shared_ptr<nanum::Settings> settings;      // style and glossary (any thread)
    std::string engine, omp_model, omp_command;
    struct TLine { double pts, dur; std::string text; };
    std::vector<TLine> transcript;      // scan_only / text lines (guarded by m)
    std::unordered_set<std::string> transcript_seen;

    struct FullRun {
        std::atomic<bool> cancel{false};
        bool finished = false;          // guarded by nanum_ai::m
        std::shared_ptr<nanum::Engine> engine;
        std::thread th;
    };
    std::shared_ptr<FullRun> full;

    void add_transcript(double pts, double dur, const std::string &text);
    void run_full(std::shared_ptr<FullRun> run, std::vector<nanum::FullLine> lines,
                  std::string source_language, nanum_ai_full_cb cb, void *cbuser);

    std::thread stt_th, tr_th;

    bool pending_locked() const
    {
        return !buf.empty() || !carry.empty() || flush || stt_busy ||
               !tq.empty() || tr_busy;
    }

    void run_stt();
    void apply_language();
    void run_translate();
    void process(const std::vector<float> &audio, double pts, uint64_t g, bool final);
    std::string transcribe(const float *samples, size_t n, float *no_speech,
                           std::vector<nanum::Piece> *timed = nullptr);
    void emit(uint64_t g, double pts, double dur, const std::string &text);
};

// Without `timed` one text for the whole clip (single segment, no timestamps). With it the
// text is split into whisper's segments, times in seconds from the start of the clip.
std::string nanum_ai::transcribe(const float *samples, size_t n, float *no_speech,
                                 std::vector<nanum::Piece> *timed)
{
    std::vector<float> padded;
    if (n < (size_t)(MIN_INPUT_S * SR)) {
        padded.assign(samples, samples + n);
        padded.resize((size_t)(MIN_INPUT_S * SR), 0.0f);
        samples = padded.data();
        n = padded.size();
    }

    whisper_full_params p = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    p.n_threads = n_threads > 0 ? n_threads : 4;
    p.language = language.c_str();
    p.translate = false;
    p.no_context = true;
    p.no_timestamps = timed == nullptr;
    p.single_segment = timed == nullptr;
    p.print_special = p.print_progress = p.print_realtime = p.print_timestamps = false;
    p.suppress_blank = true;
    p.suppress_nst = true;
    p.no_speech_thold = NO_SPEECH_MAX;

    // Checked by whisper before every graph computation: shutdown or a seek/reset
    // makes the clip stale, so a long CPU decode (large models) is abandoned at once.
    p.abort_callback = [](void *user) {
        auto *self = static_cast<nanum_ai *>(user);
        return self->aborting.load() || self->gen.load() != self->work_gen.load();
    };
    p.abort_callback_user_data = this;
    if (whisper_full(wctx, p, samples, (int)n) != 0)
        return "";

    std::string text;
    *no_speech = 0.0f;
    int ns = whisper_full_n_segments(wctx);
    for (int i = 0; i < ns; i++) {
        std::string seg = whisper_full_get_segment_text(wctx, i);
        text += seg;
        *no_speech = std::max(*no_speech, whisper_full_get_segment_no_speech_prob(wctx, i));
        if (timed) {
            seg = trim(seg);
            if (!seg.empty())
                timed->push_back({whisper_full_get_segment_t0(wctx, i) / 100.0,
                                  whisper_full_get_segment_t1(wctx, i) / 100.0, seg});
        }
    }
    return trim(text);
}

void nanum_ai::add_transcript(double pts, double dur, const std::string &text)
{
    std::string key = std::to_string(std::llround(pts * 100)) + '|' + text;
    if (!transcript_seen.insert(key).second)
        return;
    transcript.push_back({pts, dur, text});
}

void nanum_ai::emit(uint64_t g, double pts, double dur, const std::string &text)
{
    if (scan_only) {
        std::lock_guard<std::mutex> lk(m);
        if (!stop && gen == g)
            add_transcript(pts, dur, text);
    } else if (tr && tr->enabled()) {
        {
            std::lock_guard<std::mutex> lk(m);
            if (stop || gen != g)
                return;
            tq.push_back({g, pts, dur, text, language});
        }
        tcv.notify_one();
    } else if (cb) {
        cb(user, pts, dur, text.c_str(), nullptr);
    }
}

// STT thread, between windows: switch the spoken language and, when the
// language needs another model (English-only vs multilingual), the model.
void nanum_ai::apply_language()
{
    std::string lang;
    {
        std::lock_guard<std::mutex> lk(m);
        if (!language_pending)
            return;
        lang = pending_language;
        language_pending = false;
    }
    if (lang == language)
        return;
    const std::string &want = (lang == "en" || multi_path.empty()) ? stt_path : multi_path;
    if (want != cur_model_path) {
        whisper_context_params cp = whisper_context_default_params();
        cp.use_gpu = use_gpu != 0;
        if (whisper_context *nc = whisper_init_from_file_with_params(want.c_str(), cp)) {
            whisper_free(wctx);
            wctx = nc;
            cur_model_path = want;
        } else {
            std::fprintf(stderr, "nanum_ai: cannot load '%s', keeping the current model\n",
                         want.c_str());
        }
    }
    language = lang;
}

void nanum_ai::process(const std::vector<float> &audio, double pts, uint64_t g, bool final)
{
    static const bool dbg = std::getenv("NANUM_AI_DEBUG") != nullptr;
    const double dur = (double)audio.size() / SR;

    whisper_vad_params vp = whisper_vad_default_params();
    vp.threshold = std::getenv("NANUM_AI_VAD_THRESHOLD")
                       ? (float)std::atof(std::getenv("NANUM_AI_VAD_THRESHOLD"))
                       : 0.25f;
    vp.min_speech_duration_ms = 200;
    vp.min_silence_duration_ms = 300;
    vp.max_speech_duration_s = 15.0f;
    vp.speech_pad_ms = 80;

    std::vector<Segment> segs;
    if (whisper_vad_segments *vs = whisper_vad_segments_from_samples(vctx, vp, audio.data(), (int)audio.size())) {
        int n = whisper_vad_segments_n_segments(vs);
        for (int i = 0; i < n; i++)    // whisper reports centiseconds
            segs.push_back({whisper_vad_segments_get_segment_t0(vs, i) / 100.0,
                            whisper_vad_segments_get_segment_t1(vs, i) / 100.0});
        whisper_vad_free_segments(vs);
    }
    if (dbg)
        for (auto &s : segs)
            std::fprintf(stderr, "vad: %.2f-%.2f\n", pts + s.t0, pts + s.t1);

    // Segments touching the window end may continue: keep them for later.
    size_t keep_from = audio.size();
    size_t ndone = segs.size();
    if (!final) {
        for (size_t i = 0; i < segs.size(); i++) {
            if (segs[i].t1 > dur - TAIL_HOLD_S) {
                ndone = i;
                keep_from = (size_t)(std::max(0.0, segs[i].t0 - PAD_S) * SR);
                break;
            }
        }
        if (ndone == segs.size())
            keep_from = (size_t)(std::max(0.0, dur - TAIL_HOLD_S) * SR);
    }

    work_gen = g;
    for (size_t i = 0; i < ndone; i++) {
        {
            std::lock_guard<std::mutex> lk(m);
            if (stop || gen != g)
                return;     // seek or shutdown: stale work
        }
        double a = std::max(0.0, segs[i].t0 - PAD_S);
        double b = std::min(dur, segs[i].t1 + PAD_S);
        size_t s0 = (size_t)(a * SR), s1 = std::min(audio.size(), (size_t)(b * SR));
        if (s1 <= s0)
            continue;

        float nsp = 0;
        std::string text = transcribe(audio.data() + s0, s1 - s0, &nsp);
        if (dbg)
            std::fprintf(stderr, "stt: %.2f-%.2f nsp=%.2f '%s'\n", pts + segs[i].t0,
                         pts + segs[i].t1, nsp, text.c_str());
        if (nsp > NO_SPEECH_MAX || nanum::is_non_speech(text) ||
            is_short_hallucination(text, segs[i].t1 - segs[i].t0))
            continue;

        // A long utterance is decoded again with whisper's own segment timestamps (real
        // phrase times instead of a guess from the character count): in any language but
        // English always (Japanese and Chinese come back without punctuation), in English
        // only when the text cannot be cut at a sentence end or comma.
        std::vector<nanum::Piece> phrases;
        const double seg_dur = segs[i].t1 - segs[i].t0;
        const bool is_long = nanum::detail::text_units(text) > nanum::SPLIT_MAX_UNITS ||
                             seg_dur > nanum::SPLIT_MAX_DUR;
        bool unsplittable = false;
        if (is_long && language == "en")
            for (auto &piece : nanum::split_utterance(text, 0, seg_dur))
                unsplittable |= nanum::detail::text_units(piece.text) > nanum::SPLIT_MAX_UNITS * 3 / 2;
        if (is_long && (language != "en" || unsplittable)) {
            std::vector<nanum::Piece> timed;
            transcribe(audio.data() + s0, s1 - s0, &nsp, &timed);
            for (auto &t : timed) {
                if (nanum::is_non_speech(t.text) || nanum::is_number_noise(t.text))
                    continue;
                t.t0 = pts + a + t.t0;
                t.t1 = std::max(t.t0 + 0.1, pts + a + t.t1);
                phrases.push_back(std::move(t));
            }
            nanum::merge_short_pieces(phrases);
            if (phrases.size() < 2)
                phrases.clear();            // nothing gained: keep the single-segment text
            if (dbg)
                for (auto &t : phrases)
                    std::fprintf(stderr, "stt: timed %.2f-%.2f '%s'\n", t.t0, t.t1, t.text.c_str());
        }
        if (phrases.empty())
            phrases.push_back({pts + segs[i].t0, pts + segs[i].t1, text});

        for (auto &phrase : phrases)
            for (auto &piece : nanum::split_utterance(phrase.text, phrase.t0, phrase.t1 - phrase.t0))
                emit(g, piece.t0, piece.t1 - piece.t0, piece.text);
    }

    {
        std::lock_guard<std::mutex> lk(m);
        if (gen == g)
            processed = pts + (double)keep_from / SR;
    }
    if (!final && keep_from < audio.size()) {
        carry.assign(audio.begin() + keep_from, audio.end());
        carry_pts = pts + (double)keep_from / SR;
        carry_gen = g;
    }
}

void nanum_ai::run_stt()
{
    for (;;) {
        std::vector<float> audio;
        double pts;
        uint64_t g;
        bool final;
        {
            std::unique_lock<std::mutex> lk(m);
            cv.wait(lk, [&] {
                size_t have = buf.size() + (carry_gen == gen ? carry.size() : 0);
                return stop || flush || have >= (size_t)(WINDOW_S * SR);
            });
            if (stop)
                return;
            if (carry_gen != gen)
                carry.clear();
            g = gen;
            final = flush;
            flush = false;
            if (!carry.empty()) {
                audio = std::move(carry);
                pts = carry_pts;
                audio.insert(audio.end(), buf.begin(), buf.end());
            } else {
                audio = std::move(buf);
                pts = buf_pts;
            }
            carry.clear();
            buf.clear();
            buf_pts = pts + (double)audio.size() / SR;
            stt_busy = true;
        }

        apply_language();
        if (!audio.empty())
            process(audio, pts, g, final);

        {
            std::lock_guard<std::mutex> lk(m);
            stt_busy = false;
            if (!pending_locked())
                idle_cv.notify_all();
        }
    }
}

void nanum_ai::run_translate()
{
    for (;;) {
        std::vector<Job> batch;
        {
            std::unique_lock<std::mutex> lk(m);
            tcv.wait(lk, [&] { return stop || !tq.empty(); });
            if (stop)
                return;
            uint64_t cur = gen;     // jobs from before a seek are obsolete
            tq.erase(std::remove_if(tq.begin(), tq.end(),
                                    [&](const Job &j) { return j.gen != cur; }),
                     tq.end());
            if (!tq.empty() && tq.front().text_line) {
                // Text subtitles: timeline order, starting at the playhead,
                // wrapping to the earlier lines once the rest is done.
                std::stable_sort(tq.begin(), tq.end(),
                                 [](const Job &a, const Job &b) { return a.pts < b.pts; });
                size_t start = 0;
                double ph = playhead.load();
                if (ph >= 0) {
                    auto it = std::find_if(tq.begin(), tq.end(),
                                           [&](const Job &j) { return j.pts + j.dur >= ph; });
                    if (it != tq.end())
                        start = (size_t)(it - tq.begin());
                }
                size_t end = start;
                while (end < tq.size() && end - start < MAX_BATCH &&
                       (end == start || tq[end].lang == tq[start].lang))
                    end++;
                for (size_t i = start; i < end; i++)
                    batch.push_back(std::move(tq[i]));
                tq.erase(tq.begin() + start, tq.begin() + end);
            } else {
                while (!tq.empty() && batch.size() < MAX_BATCH &&
                       (batch.empty() || tq.front().lang == batch[0].lang)) {
                    batch.push_back(std::move(tq.front()));
                    tq.pop_front();
                }
            }
            tr_busy = !batch.empty();
            busy_min = busy_end = -1;
            if (!batch.empty() && batch[0].text_line) {
                busy_min = batch[0].pts;
                for (auto &j : batch) {
                    busy_min = std::min(busy_min, j.pts);
                    busy_end = std::max(busy_end, j.pts + j.dur);
                }
            }
            if (batch.empty() && !pending_locked())
                idle_cv.notify_all();
        }
        if (batch.empty())
            continue;

        std::vector<std::string> src, out;
        for (auto &j : batch)
            src.push_back(j.text);
        // Endpoint unreachable: give it a few seconds before showing a line
        // untranslated. A late translation beats a missing one while there
        // is lookahead to spare.
        for (int attempt = 0;; attempt++) {
            tr->set_source_language(language_name(batch[0].lang));
            tr->translate(src, out);
            bool missing = std::any_of(out.begin(), out.end(),
                                       [](const std::string &s) { return s.empty(); });
            if (!missing || !tr->transport_failed() || attempt >= 2)
                break;
            std::unique_lock<std::mutex> lk(m);
            tcv.wait_for(lk, std::chrono::seconds(5),
                         [&] { return stop || gen != batch[0].gen; });
            if (stop || gen != batch[0].gen)
                break;
        }
        tr->commit_context(src);

        for (size_t i = 0; i < batch.size(); i++) {
            {
                std::lock_guard<std::mutex> lk(m);
                if (stop || gen != batch[i].gen)
                    break;
            }
            if (cb)
                cb(user, batch[i].pts, batch[i].dur, batch[i].text.c_str(),
                   out[i].empty() ? nullptr : out[i].c_str());
        }
        if (!batch.empty()) {
            std::lock_guard<std::mutex> lk(m);
            if (gen == batch.back().gen)
                last_delivered = std::max(last_delivered, batch.back().pts);
        }

        {
            std::lock_guard<std::mutex> lk(m);
            tr_busy = false;
            busy_min = busy_end = -1;
            if (!pending_locked())
                idle_cv.notify_all();
        }
    }
}

void nanum_ai::run_full(std::shared_ptr<FullRun> run, std::vector<nanum::FullLine> lines,
                        std::string source_language, nanum_ai_full_cb cb, void *cbuser)
{
    nanum::FullParams params;
    params.source_language = source_language;
    params.target_language = tcfg.target_language;
    nanum::Settings::Snapshot snap = settings->snapshot();
    params.style = snap.style;
    params.style_text = snap.style_text;
    nanum::Glossary glossary = snap.glossary;       // seed; receives the extracted names too

    std::string error = nanum::translate_full(*run->engine, lines, params, glossary, run->cancel,
                                              [&](double p) {
                                                  if (!run->cancel.load() && cb)
                                                      cb(cbuser, p, nullptr, 0, nullptr);
                                              });
    if (error.empty())
        settings->merge_glossary(glossary);
    if (!run->cancel.load() && cb) {
        if (error.empty()) {
            std::vector<nanum_ai_line> out;
            out.reserve(lines.size());
            for (auto &l : lines)
                out.push_back({l.pts, l.dur, l.src.c_str(), l.tr.c_str()});
            cb(cbuser, 1.0, out.data(), out.size(), nullptr);
        } else {
            cb(cbuser, 0.0, nullptr, 0, error.c_str());
        }
    }
    std::lock_guard<std::mutex> lk(m);
    run->finished = true;
}

extern "C" {

NANUM_AI_API const char *nanum_ai_last_error(void)
{
    return g_error.c_str();
}

NANUM_AI_API const char *nanum_ai_backend(void)
{
#ifdef NANUM_AI_CUDA
    return "cuda";
#else
    return "cpu";
#endif
}

NANUM_AI_API int nanum_ai_gpu_available(void)
{
    g_error.clear();
#ifdef NANUM_AI_CUDA
    int count = 0;
    cudaError_t result = cudaGetDeviceCount(&count);
    if (result != cudaSuccess) {
        g_error = std::string("CUDA driver/runtime: ") + cudaGetErrorString(result);
        return 0;
    }
    if (count == 0) {
        g_error = "No NVIDIA CUDA GPU is available";
        return 0;
    }
    cudaDeviceProp device{};
    result = cudaGetDeviceProperties(&device, 0);
    if (result != cudaSuccess) {
        g_error = std::string("CUDA device query: ") + cudaGetErrorString(result);
        return 0;
    }
    if (device.major * 10 + device.minor < 86) {
        g_error = "This CUDA engine requires compute capability 8.6 or newer";
        return 0;
    }
    return 1;
#else
    g_error = "The CPU engine does not provide CUDA acceleration";
    return 0;
#endif
}

NANUM_AI_API nanum_ai *nanum_ai_create(const nanum_ai_config *cfg,
                                       nanum_ai_event_cb cb, void *user)
{
    g_error.clear();
    if (!cfg || cfg->abi_version != NANUM_AI_ABI_VERSION) {
        g_error = "ABI version mismatch";
        return nullptr;
    }
    bool no_stt = cfg->translate_only != 0;
    if (!no_stt && (!cfg->stt_model_path || !cfg->vad_model_path)) {
        g_error = "stt_model_path and vad_model_path are required";
        return nullptr;
    }
    if (!no_stt && cfg->use_gpu && !nanum_ai_gpu_available())
        return nullptr;

    whisper_log_set(log_cb, nullptr);

    auto *ai = new nanum_ai;
    ai->stt_path = cfg->stt_model_path ? cfg->stt_model_path : "";
    ai->vad_path = cfg->vad_model_path ? cfg->vad_model_path : "";
    ai->no_stt = no_stt;
    ai->language = cfg->language && *cfg->language ? cfg->language : "en";
    ai->want_language = ai->language;
    if (cfg->stt_model_multilingual_path)
        ai->multi_path = cfg->stt_model_multilingual_path;
    ai->use_gpu = cfg->use_gpu;
    ai->n_threads = cfg->n_threads;
    ai->cb = cb;
    ai->user = user;

    TranslatorConfig tc = translator_config(cfg);
    tc.source_language = language_name(ai->language);
    ai->settings = std::make_shared<nanum::Settings>();
    ai->settings->set_style(cfg->translate_style ? cfg->translate_style : "",
                            cfg->translate_style_text ? cfg->translate_style_text : "");
    ai->settings->set_glossary(nanum::parse_glossary(cfg->glossary ? cfg->glossary : "", false));
    tc.settings = ai->settings;
    ai->tcfg = tc;
    ai->tr = std::make_unique<Translator>(tc);
    ai->scan_only = cfg->scan_only != 0;
    if (cfg->translate_engine)
        ai->engine = cfg->translate_engine;
    if (cfg->omp_model)
        ai->omp_model = cfg->omp_model;
    if (cfg->omp_command)
        ai->omp_command = cfg->omp_command;

    if (!no_stt) {
        whisper_context_params cp = whisper_context_default_params();
        cp.use_gpu = cfg->use_gpu != 0;
        ai->cur_model_path = (ai->language == "en" || ai->multi_path.empty()) ? ai->stt_path
                                                                              : ai->multi_path;
        ai->wctx = whisper_init_from_file_with_params(ai->cur_model_path.c_str(), cp);
        if (!ai->wctx) {
            g_error = "cannot load STT model: " + ai->cur_model_path;
            delete ai;
            return nullptr;
        }

        whisper_vad_context_params vcp = whisper_vad_default_context_params();
        vcp.use_gpu = false;        // tiny model, keep the GPU for whisper
        ai->vctx = whisper_vad_init_from_file_with_params(ai->vad_path.c_str(), vcp);
        if (!ai->vctx) {
            g_error = "cannot load VAD model: " + ai->vad_path;
            whisper_free(ai->wctx);
            delete ai;
            return nullptr;
        }

        ai->stt_th = std::thread([ai] { ai->run_stt(); });
    }
    ai->tr_th = std::thread([ai] { ai->run_translate(); });
    return ai;
}

NANUM_AI_API void nanum_ai_destroy(nanum_ai *ai)
{
    if (!ai)
        return;
    std::shared_ptr<nanum_ai::FullRun> full;
    {
        std::lock_guard<std::mutex> lk(ai->m);
        ai->stop = true;
        ai->aborting = true;
        ai->gen++;
        full = ai->full;
    }
    if (full) {
        full->cancel = true;
        if (full->engine)
            full->engine->cancel();
        if (full->th.joinable())
            full->th.join();
    }
    ai->cv.notify_all();
    ai->tcv.notify_all();
    if (ai->tr)
        ai->tr->abort();        // do not wait for a running request
    if (ai->stt_th.joinable())
        ai->stt_th.join();
    if (ai->tr_th.joinable())
        ai->tr_th.join();
    whisper_vad_free(ai->vctx);
    whisper_free(ai->wctx);
    delete ai;
}

NANUM_AI_API void nanum_ai_push_text(nanum_ai *ai, double pts, double duration,
                                     const char *text)
{
    if (!ai || !text)
        return;
    std::string clean = nanum::clean_subtitle_text(text);
    if (clean.empty())
        return;
    {
        std::lock_guard<std::mutex> lk(ai->m);
        if (ai->stop)
            return;
        if (ai->scan_only) {
            ai->add_transcript(pts, duration, clean);
            return;
        }
        // The demuxer may deliver a packet again (seek back into read-ahead).
        for (const Job &j : ai->tq)
            if (j.text_line && j.gen == ai->gen && std::fabs(j.pts - pts) < 0.005 &&
                j.text == clean)
                return;
        ai->tq.push_back({ai->gen, pts, duration, clean, ai->want_language, true});
        ai->text_ready = std::max(ai->text_ready, pts);
    }
    ai->tcv.notify_one();
}

NANUM_AI_API void nanum_ai_set_playhead(nanum_ai *ai, double pts)
{
    if (ai)
        ai->playhead.store(pts);
}

NANUM_AI_API size_t nanum_ai_transcript_size(nanum_ai *ai)
{
    if (!ai)
        return 0;
    std::lock_guard<std::mutex> lk(ai->m);
    return ai->transcript.size();
}

NANUM_AI_API size_t nanum_ai_transcript_export(nanum_ai *ai, nanum_ai_transcript_cb cb,
                                               void *user)
{
    if (!ai)
        return 0;
    std::vector<nanum_ai::TLine> t;
    {
        std::lock_guard<std::mutex> lk(ai->m);
        t = ai->transcript;
    }
    if (t.empty())
        return 0;
    std::stable_sort(t.begin(), t.end(), [](const nanum_ai::TLine &a, const nanum_ai::TLine &b) {
        return a.pts < b.pts;
    });
    if (cb) {
        std::vector<nanum_ai_line> out;
        out.reserve(t.size());
        for (auto &l : t)
            out.push_back({l.pts, l.dur, l.text.c_str(), nullptr});
        cb(user, out.data(), out.size());
    }
    return t.size();
}

NANUM_AI_API int nanum_ai_translate_all(nanum_ai *ai, nanum_ai_full_cb cb, void *user)
{
    if (!ai)
        return 1;
    std::shared_ptr<nanum_ai::FullRun> old;
    {
        std::lock_guard<std::mutex> lk(ai->m);
        if (ai->stop || ai->transcript.empty())
            return 1;
        if (ai->full && !ai->full->finished && !ai->full->cancel.load())
            return 1;       // already running
        if (ai->full && ai->full->th.get_id() == std::this_thread::get_id())
            return 1;       // from the callback of the run being replaced

        std::vector<nanum_ai::TLine> t = ai->transcript;
        std::stable_sort(t.begin(), t.end(), [](const nanum_ai::TLine &a, const nanum_ai::TLine &b) {
            return a.pts < b.pts;
        });
        std::vector<nanum::FullLine> lines;
        lines.reserve(t.size());
        for (auto &l : t) {
            nanum::FullLine fl;
            fl.pts = l.pts;
            fl.dur = l.dur;
            fl.src = std::move(l.text);
            lines.push_back(std::move(fl));
        }

        old = std::move(ai->full);
        auto run = std::make_shared<nanum_ai::FullRun>();
        if (ai->engine == "omp")
            run->engine = nanum::make_omp_engine(ai->omp_command, ai->omp_model, 300);
        else
            run->engine = nanum::make_ollama_engine(ai->tcfg);
        ai->full = run;
        run->th = std::thread([ai, run, lines = std::move(lines),
                               src = language_name(ai->want_language), cb, user]() mutable {
            ai->run_full(run, std::move(lines), src, cb, user);
        });
    }
    if (old) {      // finished or cancelled: nothing left but to reap the thread
        old->cancel = true;
        if (old->engine)
            old->engine->cancel();
        if (old->th.joinable())
            old->th.join();
    }
    return 0;
}

NANUM_AI_API void nanum_ai_cancel_full(nanum_ai *ai)
{
    if (!ai)
        return;
    std::shared_ptr<nanum_ai::FullRun> run;
    {
        std::lock_guard<std::mutex> lk(ai->m);
        run = ai->full;
    }
    if (!run)
        return;
    run->cancel = true;
    if (run->engine)
        run->engine->cancel();
}

NANUM_AI_API void nanum_ai_push_audio(nanum_ai *ai, const float *samples,
                                      size_t n, double start_pts)
{
    if (!ai || !samples || !n || ai->no_stt)
        return;
    bool wake;
    {
        std::lock_guard<std::mutex> lk(ai->m);
        if (!ai->have_audio || std::fabs(start_pts - ai->next_pts) > 0.25) {
            // Seek or first chunk: whatever is pending belongs to another
            // position and is dropped.
            ai->gen++;
            ai->buf.clear();
            ai->buf_pts = start_pts;
            ai->processed = ai->last_delivered = -1;
            ai->have_audio = true;
        }
        ai->buf.insert(ai->buf.end(), samples, samples + n);
        ai->next_pts = start_pts + (double)n / SR;
        wake = ai->buf.size() >= (size_t)(WINDOW_S * SR);
    }
    if (wake)
        ai->cv.notify_one();
}

NANUM_AI_API void nanum_ai_flush(nanum_ai *ai)
{
    if (!ai || ai->no_stt)
        return;
    {
        std::lock_guard<std::mutex> lk(ai->m);
        ai->flush = true;
    }
    ai->cv.notify_one();
}

NANUM_AI_API void nanum_ai_set_language(nanum_ai *ai, const char *language)
{
    if (!ai || !language)
        return;
    std::string lang = *language ? language : "auto";
    std::lock_guard<std::mutex> lk(ai->m);
    if (lang == ai->want_language)
        return;
    ai->want_language = lang;
    ai->pending_language = lang;
    ai->language_pending = true;
    // Audio and lines of the previous language are obsolete.
    ai->gen++;
    ai->buf.clear();
    ai->tq.clear();
    ai->have_audio = false;
    ai->processed = ai->last_delivered = ai->text_ready = -1;
}

NANUM_AI_API void nanum_ai_reset(nanum_ai *ai)
{
    if (!ai)
        return;
    std::lock_guard<std::mutex> lk(ai->m);
    ai->gen++;
    ai->buf.clear();
    ai->tq.clear();
    ai->have_audio = false;
    ai->processed = ai->last_delivered = ai->text_ready = -1;
}

NANUM_AI_API double nanum_ai_processed_until(nanum_ai *ai)
{
    if (!ai)
        return NAN;
    std::lock_guard<std::mutex> lk(ai->m);
    if (ai->text_ready >= 0) {
        // Text lines: everything pushed so far is "known"; the lines still
        // waiting (or in flight) at/after the playhead hold the horizon back.
        double ph = ai->playhead.load();
        double ready = ai->text_ready;
        for (const Job &j : ai->tq)
            if (j.text_line && j.gen == ai->gen && (ph < 0 || j.pts + j.dur >= ph))
                ready = std::min(ready, j.pts);
        if (ai->tr_busy && ai->busy_min >= 0 && (ph < 0 || ai->busy_end >= ph))
            ready = std::min(ready, ai->busy_min);
        return ready;
    }
    if (ai->processed < 0)
        return NAN;
    double ready = ai->processed;
    if (!ai->tq.empty() || ai->tr_busy)     // translation is still behind
        ready = ai->last_delivered < 0 ? NAN : std::min(ready, ai->last_delivered);
    return ready;
}

NANUM_AI_API int nanum_ai_wait_idle(nanum_ai *ai, int timeout_ms)
{
    if (!ai)
        return 1;
    std::unique_lock<std::mutex> lk(ai->m);
    return ai->idle_cv.wait_for(lk, std::chrono::milliseconds(timeout_ms),
                                [&] { return !ai->pending_locked(); }) ? 1 : 0;
}

NANUM_AI_API void nanum_ai_set_glossary(nanum_ai *ai, const char *text)
{
    if (ai)
        ai->settings->set_glossary(nanum::parse_glossary(text ? text : "", false));
}

NANUM_AI_API void nanum_ai_set_style(nanum_ai *ai, const char *style, const char *text)
{
    if (ai)
        ai->settings->set_style(style ? style : "", text ? text : "");
}

NANUM_AI_API size_t nanum_ai_get_glossary(nanum_ai *ai, char *out, size_t outsz)
{
    if (!ai)
        return 0;
    std::string s = nanum::format_glossary(ai->settings->snapshot().glossary);
    if (out && outsz) {
        size_t n = std::min(s.size(), outsz - 1);
        while (n > 0 && n < s.size() && ((unsigned char)s[n] & 0xC0) == 0x80)
            n--;                // do not cut a UTF-8 character
        std::memcpy(out, s.data(), n);
        out[n] = '\0';
    }
    return s.size();
}

NANUM_AI_API int nanum_ai_profile(const nanum_ai_config *cfg, const char *title,
                                  const char *audio_languages, char *out, size_t outsz)
{
    static const bool dbg = std::getenv("NANUM_AI_DEBUG") != nullptr;
    g_error.clear();
    if (!cfg || cfg->abi_version != NANUM_AI_ABI_VERSION) {
        g_error = "ABI version mismatch";
        return 0;
    }
    if (!title || !*title || !out || !outsz) {
        g_error = "title and output buffer are required";
        return 0;
    }
    TranslatorConfig tc = translator_config(cfg);
    tc.cache_path.clear();
    const bool omp = cfg->translate_engine && !std::strcmp(cfg->translate_engine, "omp");
    if (!omp && tc.endpoint.empty()) {
        g_error = "no translation endpoint configured";
        return 0;
    }
    Translator ollama(tc);
    const auto t0 = std::chrono::steady_clock::now();
    auto elapsed_ms = [&] {
        return (int)std::chrono::duration_cast<std::chrono::milliseconds>(
                   std::chrono::steady_clock::now() - t0).count();
    };
    // One request; schema is only used by the Ollama engine (the prompt asks for JSON anyway).
    auto ask = [&](const std::string &prompt, const char *schema, int timeout_ms,
                   double temperature, std::string &text, std::string &err) {
        bool ok;
        if (omp) {
            auto engine = nanum::make_omp_engine(cfg->omp_command ? cfg->omp_command : "",
                                                 cfg->omp_model ? cfg->omp_model : "",
                                                 timeout_ms / 1000);
            ok = engine->run(prompt, text, err);
        } else {
            Translator::CompleteOptions opt;
            opt.timeout_ms = timeout_ms;
            opt.temperature = temperature;
            if (schema) {
                opt.format_schema = schema;
            } else {                // the names list: bounded and not allowed to loop
                opt.max_tokens = PROFILE_NAMES_TOKENS;
                opt.repeat_penalty = PROFILE_REPEAT_PENALTY;
            }
            ok = ollama.complete(prompt, text, err, opt);
        }
        if (dbg)
            std::fprintf(stderr, "profile: %s answer after %.1fs%s:\n%s\n", ok ? "raw" : "FAILED",
                         elapsed_ms() / 1000.0,
                         text.find("<0x") != std::string::npos ? " (contains byte tokens)" : "",
                         ok ? text.c_str() : err.c_str());
        return ok;
    };

    // 1) Which work, which original language.
    std::string text, err;
    if (!ask(nanum::profile_prompt(title, audio_languages ? audio_languages : "", tc.target_language),
             nanum::profile_schema(), PROFILE_IDENTIFY_MS, 0.2, text, err)) {
        g_error = "profile query failed: " + err;
        return 0;
    }
    nanum::Profile profile;
    if (!nanum::parse_profile(text, profile, tc.target_language)) {
        g_error = "profile query: the model did not answer with a JSON object";
        return 0;
    }
    // 2) The names of that work as plain lines (small local models answer these reliably,
    // unlike an array inside a JSON schema). A failure here keeps the identification. A
    // model that loops on one line gets a second, warmer try while time remains.
    if (!profile.work.empty()) {
        const std::string prompt = nanum::profile_glossary_prompt(
            profile.work, title, profile.original_language, tc.target_language);
        for (int attempt = 0; attempt < 2; attempt++) {
            int left = PROFILE_BUDGET_MS - elapsed_ms();
            if (attempt && left < PROFILE_MIN_NAMES_MS)
                break;
            std::string names;
            if (!ask(prompt, nullptr, std::max(PROFILE_MIN_NAMES_MS, left),
                     attempt ? PROFILE_RETRY_TEMPERATURE : 0.2, names, err))
                break;
            profile.glossary = nanum::parse_glossary_answer(
                nanum::first_lines(names, PROFILE_NAMES_LINES), tc.target_language);
            if (!nanum::looping_answer(names))
                break;
        }
    }
    std::string json = nanum::profile_json(profile);
    if (json.size() >= outsz) {
        g_error = "profile query: output buffer too small";
        return 0;
    }
    std::memcpy(out, json.c_str(), json.size() + 1);
    return 1;
}

NANUM_AI_API int nanum_ai_ocr(const unsigned char *gray, int width, int height, int stride,
                              const char *lang, char *out, size_t outsz)
{
    g_error.clear();
    if (!out || !outsz) {
        g_error = "OCR: output buffer is required";
        return 0;
    }
    out[0] = '\0';
    std::string text;
    if (!nanum::ocr_gray(gray, width, height, stride, lang && *lang ? lang : "en", text, g_error))
        return 0;
    if (text.size() >= outsz) {
        g_error = "OCR: text does not fit the output buffer";
        return 0;
    }
    std::memcpy(out, text.c_str(), text.size() + 1);
    return 1;
}

NANUM_AI_API size_t nanum_ai_ocr_languages(char *out, size_t outsz)
{
    std::string s = nanum::ocr_languages();
    if (out && outsz) {
        size_t n = std::min(s.size(), outsz - 1);
        std::memcpy(out, s.data(), n);
        out[n] = '\0';
    }
    return s.size();
}

} // extern "C"
