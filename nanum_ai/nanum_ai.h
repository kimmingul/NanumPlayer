/*
 * nanum_ai: speech-to-text and translation engine for NanumPlayer.
 *
 * Plain C ABI so the GPL mpv fork can load it without sharing a toolchain
 * (mpv is built with clang/MinGW, this DLL with MSVC + CUDA).
 */
#ifndef NANUM_AI_H
#define NANUM_AI_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#ifdef _WIN32
#  ifdef NANUM_AI_BUILD
#    define NANUM_AI_API __declspec(dllexport)
#  else
#    define NANUM_AI_API __declspec(dllimport)
#  endif
#else
#  define NANUM_AI_API
#endif

#define NANUM_AI_ABI_VERSION 7

typedef struct nanum_ai nanum_ai;

typedef struct nanum_ai_config {
    int abi_version;            // must be NANUM_AI_ABI_VERSION

    // Speech-to-text (whisper.cpp + Silero VAD).
    const char *stt_model_path; // ggml whisper model (.bin)
    const char *vad_model_path; // ggml silero VAD model (.bin)
    const char *stt_model_multilingual_path; // used for languages other than
                                             // English; NULL: keep stt_model_path
    const char *language;       // "en", "ja", ... or "auto"
    int use_gpu;                // 1: require a CUDA engine and compatible GPU; 0: CPU
    int n_threads;              // CPU threads, 0: default

    // Translation through an Ollama-compatible /api/generate endpoint.
    // NULL or "" for translate_endpoint disables translation.
    const char *translate_endpoint;   // e.g. "http://127.0.0.1:11434"
    const char *translate_model;      // e.g. "gemma4:latest"
    const char *target_language;      // e.g. "Korean"
    int translate_timeout_ms;         // per request, 0: 90000
    int translate_context_lines;      // previous source lines, 0: 3
    const char *cache_path;           // JSONL translation cache, NULL: none

    // ABI 4: full pre-translation (nanum_ai_translate_all) and text input.
    const char *translate_engine;     // translate_all(): "ollama" (NULL/"" = ollama) or "omp"
    const char *omp_model;            // omp --model selector
    const char *omp_command;          // omp executable, NULL/"" -> "omp"
    int scan_only;                    // 1: lines are only collected into the transcript, never
                                      //    translated live (the event callback is never invoked)
    // ABI 5
    int translate_only;               // 1: no speech recognition (stt/vad paths may be NULL,
                                      //    audio is ignored). scan_only independently selects
                                      //    transcript collection instead of live text events.
    // ABI 6
    const char *translate_style;      // "natural" (NULL/"" = natural) | "polite" | "casual" |
                                      // "literal" | "custom"
    const char *translate_style_text; // instruction used when translate_style is "custom"
    const char *glossary;             // initial glossary, lines "source => target"; NULL/"": none
} nanum_ai_config;

// Called from an internal worker thread, in timeline order per batch.
// pts/duration are seconds on the timeline given to nanum_ai_push_audio().
// translation is NULL when translation is disabled or failed; failures are
// never cached.
typedef void (*nanum_ai_event_cb)(void *user, double pts, double duration,
                                  const char *source, const char *translation);

// Engine kind and a model-independent CUDA readiness probe.
// CPU builds return 0 from the probe. Failure details: nanum_ai_last_error().
NANUM_AI_API const char *nanum_ai_backend(void);
NANUM_AI_API int nanum_ai_gpu_available(void);

// Returns NULL on failure; see nanum_ai_last_error().
NANUM_AI_API nanum_ai *nanum_ai_create(const nanum_ai_config *cfg,
                                       nanum_ai_event_cb cb, void *user);
NANUM_AI_API void nanum_ai_destroy(nanum_ai *ai);

// Never blocks (copies the samples). Mono float32, 16 kHz; start_pts is the
// timestamp of samples[0]. A start_pts that does not continue the previous
// chunk (seek, refresh) discards the audio and queued translations that are
// still pending.
NANUM_AI_API void nanum_ai_push_audio(nanum_ai *ai, const float *samples,
                                      size_t n, double start_pts);

// End of stream: process everything that is buffered.
NANUM_AI_API void nanum_ai_flush(nanum_ai *ai);

// Drop all pending audio and queued translations.
NANUM_AI_API void nanum_ai_reset(nanum_ai *ai);

// The spoken language changed (the user switched the audio track). "en", "ja",
// ... or "auto". Pending audio is dropped; English uses stt_model_path, any
// other language the multilingual model.
NANUM_AI_API void nanum_ai_set_language(nanum_ai *ai, const char *language);

// Seconds on the push_audio() timeline up to which audio has been recognised
// and its lines delivered (translation included). NaN: unknown, e.g. right
// after a seek.
NANUM_AI_API double nanum_ai_processed_until(nanum_ai *ai);

// Waits until all pushed audio has been processed and translated. Returns 1
// if idle, 0 on timeout. Mainly for tests.
NANUM_AI_API int nanum_ai_wait_idle(nanum_ai *ai, int timeout_ms);

// Thread-local description of the last failure of nanum_ai_create().
NANUM_AI_API const char *nanum_ai_last_error(void);

// Source line from a text subtitle (UTF-8). The DLL strips ASS/HTML tags and \N,
// and drops empty / sound-only ("[music]") lines. Live: queued and translated in
// batches with context like an STT line, delivered through the event callback.
// scan_only: appended to the transcript.
NANUM_AI_API void nanum_ai_push_text(nanum_ai *ai, double pts, double duration,
                                     const char *text);

// Live text mode: lines at/after pts are translated first (then it wraps to
// earlier ones). Cheap, any thread.
NANUM_AI_API void nanum_ai_set_playhead(nanum_ai *ai, double pts);

typedef struct nanum_ai_line {
    double pts;
    double duration;
    const char *source;
    const char *translation;
} nanum_ai_line;

// progress in [0,1] while running (lines == NULL, n == 0). Exactly one final
// call: error == NULL and lines/n = all lines in timeline order (translation is
// never NULL; "" only if a line failed twice), or error != NULL. Called from an
// internal thread. The pointers are valid only during the call.
typedef void (*nanum_ai_full_cb)(void *user, double progress,
                                 const nanum_ai_line *lines, size_t n,
                                 const char *error);

// Translates the whole transcript collected so far (STT lines in scan_only
// mode, or pushed text lines). Call after nanum_ai_flush() + nanum_ai_wait_idle().
// Starts a thread; returns 0 on start, nonzero if already running or empty.
NANUM_AI_API int nanum_ai_translate_all(nanum_ai *ai, nanum_ai_full_cb cb, void *user);

// Idempotent; the final callback is NOT called after a cancel.
NANUM_AI_API void nanum_ai_cancel_full(nanum_ai *ai);

NANUM_AI_API size_t nanum_ai_transcript_size(nanum_ai *ai);

// ABI 5: durable transcript export.
// Hands the transcript collected so far (scan_only STT lines or pushed text
// lines) to cb as ONE snapshot: lines sorted by pts, translation == NULL,
// pointers valid only during the call. The snapshot is copied under the
// engine lock and cb runs outside of it, so pushes/flush/destroy may race with
// the call and never corrupt it; cb may call back into the engine (except
// destroy). Returns the number of lines in the snapshot (cb is not called for
// 0). Safe from any thread, including while translate_all() runs.
typedef void (*nanum_ai_transcript_cb)(void *user, const nanum_ai_line *lines, size_t n);
NANUM_AI_API size_t nanum_ai_transcript_export(nanum_ai *ai, nanum_ai_transcript_cb cb,
                                               void *user);

// ABI 6: translation consistency and style.
// Replaces the glossary used by later live batches and full runs (lines
// "source => target"). Any thread.
NANUM_AI_API void nanum_ai_set_glossary(nanum_ai *ai, const char *text);
// Style for lines translated from now on (values as nanum_ai_config). Any thread.
NANUM_AI_API void nanum_ai_set_style(nanum_ai *ai, const char *style, const char *text);
// Current glossary: set/initial entries first, then entries a full run extracted.
// Returns the length without NUL; writes at most outsz-1 bytes plus NUL.
NANUM_AI_API size_t nanum_ai_get_glossary(nanum_ai *ai, char *out, size_t outsz);
// Blocking one-off query of the translation model (cfg: translate_endpoint/model,
// or omp when translate_engine is "omp"; target_language). title: disc/film title
// or file name; audio_languages: comma separated codes of the audio tracks. On
// success writes the JSON object
//   {"work":"...","original_language":"<ISO 639-1 or empty>","glossary":"<lines>"}
// and returns 1; 0 on failure (nanum_ai_last_error()). original_language is
// empty unless the model is confident. Glossary keys include the names as written
// in the original language and their English/romanized spellings; values are the
// established forms in target_language.
NANUM_AI_API int nanum_ai_profile(const nanum_ai_config *cfg, const char *title,
                                  const char *audio_languages, char *out, size_t outsz);

// ABI 7: OCR of image subtitles with Windows.Media.Ocr (built into Windows 10/11, no
// bundled model). gray: 8-bit, dark text on a light background preferred; lang: "en", "ja",
// ... (BCP-47 primary subtag). Returns 1 and the UTF-8 text (lines joined by "\n"), or 0
// (nanum_ai_last_error(), e.g. the OCR language pack is not installed or the text is
// longer than outsz). Any thread; does not need an engine handle.
NANUM_AI_API int nanum_ai_ocr(const unsigned char *gray, int width, int height, int stride,
                              const char *lang, char *out, size_t outsz);
// Comma separated OCR languages available on this PC (primary subtags, e.g. "en,ko").
// Returns the length without NUL; writes at most outsz-1 bytes plus NUL.
NANUM_AI_API size_t nanum_ai_ocr_languages(char *out, size_t outsz);

#ifdef __cplusplus
}
#endif

#endif
