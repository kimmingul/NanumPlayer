# Verification history

English · developer-facing

This page records what was checked during development, on what hardware, and with which result. It
is a log, not a promise: results apply to the versions and the test setup named in each entry. All
measurements were made on one PC with an NVIDIA GeForce RTX 3070 Ti and a Pioneer BDR-UD03 Blu-ray drive.
User-facing limitations are in [Troubleshooting](../troubleshooting.md#known-limitations).

Terms: *STT* is speech recognition, *RTF* the real-time factor (processing time ÷ audio time), *PTS* the
presentation timestamp, *preroll* the wait at the start of a file for subtitles, *real disc* the
Blu-ray in drive `E:`.

## Initial development (the original notes carry no version label)

- STT: 150 seconds of film audio were processed in 1.55 seconds (RTF ≈ 0.01); times are the container's
  absolute PTS.
- Real disc (`bd://longest`, played in real time for 150 seconds from the 300-second mark, 120-second
  read-ahead): all 22 events were translated; from 60 seconds into playback, 16 of 16 events of the span
  arrived before playback (median lead ≈ 100 seconds); Korean and English subtitles were seen in
  `sub-text` during playback.
- With the translation server dead, the delay was 2.4 seconds and failures were not cached.
- Playing audio and AI input audio were separated: changing the playing audio to another track kept the
  fixed English AI input and subtitle generation. Generating from the new audio needs a separate choice.
- Whole-file translation (`film_150s.wav`, local): scan → translation → save → automatic application of
  `ko (AI full)` took about 10 seconds. Ollama (`nemotron-3-super:cloud`) and omp
  (`anthropic/claude-haiku-4-5`) were both verified. Translating an English SRT (40 cues): 7–9 seconds
  with Ollama, 12 seconds with omp. At exit, 10 of 10 runs during a scan ended normally.

## 1.1.0

- Real Blu-ray seeking: 300 → 4500 → 900 → 4500 → the same 4500 → 4504 → −6 seconds all showed Korean
  `sub-text`. Only one TrueHD stream was analyzed, the decoder was initialized once, and there were 0
  stream-parameter warnings. Cached file seeking 8 → 15 → 8 → 8 → 12 → −6 seconds also gave the exact
  landing and Korean subtitles (`tools/nanum_seek_smoke.py`).
## Model download and installer (the original notes carry no version label; optional model downloads arrived in 1.1.0)

- Installing without models; actually downloading the VAD during setup with verification and reuse;
  models retained after uninstall. From the settings menu, an actual download of both Whisper models plus
  VAD with cancellation and progress, and after completion Korean subtitles for the next file in the same
  process. A wrong SHA-256 and an HTTP 404 each ended as an error, kept the existing good file and removed
  the temporary file. A WAV without a language tag with only the English model and VAD installed also gave
  Korean subtitles.

## 1.2.0

- A package without CUDA files gave Korean subtitles on the CPU; the downloaded CUDA engine plus cuBLAS gave
  Korean subtitles on CUDA; reusing an existing CUDA 13 Toolkit and downloading only the 52.6 MiB engine
  gave Korean subtitles on CUDA. Actual download, cancellation and resume of the public GitHub assets were
  verified, and the size and SHA-256 of three files matched. With a missing model or an unavailable
  required CUDA, playback was normal with no wait for AI preparation. The progress, license and diagnostic
  toggle in the settings were verified.
- On the real `E:` disc with AI off, `ReadFile` CRC error 23 (about 21 seconds of waiting) and Windows
  `cdrom` event 7 were collected. Reading the same offset directly without the player, AI, libbluray or
  MakeMKV also gave CRC error 23 and a 27-second wait. A failed AACS decryption after a successful file
  read is also logged separately.
- Installation: no optional downloads by default and an offline CPU install; the GUI's CUDA license
  agreement, Toolkit reuse and an actual engine download; reuse of the verified cache by unattended
  CUDA/VAD selection. A requested URL that returns HTTP 404 aborts before installation with exit code 7;
  after uninstall the three model files and the CUDA cache remain. Exiting right after a GPU → CPU switch
  for the next file ended normally 4 of 4 times after the fix. With the installed player, real-disc seeks
  300 → 4500 → 900 seconds passed with Korean subtitles, a single TrueHD input and 0 stream warnings.

## 1.2.1

- With CUDA required but no speech models and no CUDA, Korean display of an English SRT, the missing-model
  notice for speech input, return to text input, whole-text translation and save, and a normal exit were
  all checked in the real player. A regression test for missing live events in translation-only mode failed
  before the fix and passed after it.
- Additionally: the default 30-second preroll of a two-cue external subtitle is released at once after the
  whole translation, and Korean was rendered in a real video window without models or CUDA. The public
  1.2.1 engine download, SHA-256 match and Toolkit reuse were checked; two switches CPU text → CUDA speech →
  CPU text using buffered audio ended normally; real speech-recognition Korean subtitles appeared at the
  70-second mark.
- Final installation: the packager passes the asset list's version to the installer, and unattended CUDA
  selection created the real `cuda/1.2.1` cache with a matching SHA-256. CUDA speech Korean subtitles and
  normal exit with the installed player, retention of the CUDA cache after uninstall, and CPU speech Korean
  subtitles from a package without CUDA were also verified.

## 1.3.0

Real `E:` disc, CUDA, `nemotron-3-super:cloud`:

- Playing from 440 seconds, both tracks ("Korean (based on English audio)" and "Korean (based on Japanese
  audio)") were analyzed and saved from 438.5 seconds, and the Japanese-based track caught up with the
  English-based one.
- Work identified as `The Disappearance of Haruhi Suzumiya`, original language `ja`, glossary of 64 entries.
  The longest Japanese utterance was split into pieces of at most 3.9 seconds and 26 characters, with 0
  on-screen two-line overlaps.
- Reopening gave subtitles ready up to 473 seconds from the saved copy in 15 seconds.
- Repeated backward seeks of the disc audio (`120,rel-7,rel-11,rel-5`) gave 0 overlapping pairs in the
  saved subtitles. Adding a glossary entry for the character Koizumi from the menu re-translated and saved an
  earlier mistranslation of that name in the existing subtitles with the new spelling.
- Three lines with `<0xHH>` byte-token corruption in the user cache were restored to correct Korean text
  when displayed, without a translation server.
- Installing (with no optional downloads), running and uninstalling, and real downloads of the 1.3.0 CUDA
  engine and large-v3-turbo with SHA-256 matches, were verified.

## 1.7.0

- With a package without MakeMKV and an empty key cache: download cancellation and temporary-file cleanup,
  automatic key acquisition, real `E:` Blu-ray playback, and saving a 123-second title with full decoding
  were verified.
- The 121-second MKV of a test disc made from a feature excerpt kept 2 TrueHD, 2 AC-3 and 2 PGS streams and
  chapters, and passed full video and audio decoding. The real menu's progress, Ctrl+C cancellation and
  preservation of the completed file were verified.
- Two synthetic DVD titles preserved the source video's 3,626 / 3,746 frames and 3,782 / 3,907 packets per
  audio stream, and a command that moves automatically to the next title was split into a separate file as
  well.
- Not verified: a real CSS DVD, DVDs with multiple PGCs or angles, and all BD+ and UHD discs.

## 1.8.0 and later

No verification entries were recorded in this log for 1.8.0 and later; the [changelog](../../CHANGELOG.md)
describes what changed in each version.
