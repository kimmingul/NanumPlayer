NanumPlayer
===========

NanumPlayer.exe is the native player itself, not a launcher. No mpv.exe child
process is used. Open a file from the start card, drag it into the window, or run
NanumPlayer.exe "movie.mkv". AI subtitles are shown as Korean tracks named after
their source, e.g. "한국어 (영어 음성 기반)". When the audio has several languages
(e.g. a US Blu-ray of a Japanese film), Korean is also made from the original-language
audio ("한국어 (일본어 음성 기반)") at lower priority, from the same disc read; the
playback-audio track stays selected, choose the other in the subtitle menu. Both are
saved per film and shown immediately when the film is opened again.

Requirements
- Windows 10/11 x64 with an AVX2 CPU. CPU speech recognition is included.
- A translation server: Ollama (https://ollama.com) running, with a model installed.
  Pick it with Ctrl+N > 번역 모델: the list shows the models installed in Ollama
  (local with size, and cloud models); you can also type a name. gemma4:latest
  (default) is large; pick a model that fits your GPU or a cloud model.
- Optional: oh-my-pi ("omp" on PATH) for the whole-file translation engine.

Whisper and Silero .bin models are NOT included in this installer/portable folder.
The installer offers optional downloads: English Whisper + Silero (~466 MiB),
multilingual Whisper + Silero (~466 MiB), high-accuracy multilingual Whisper
large-v3-turbo + Silero (~548 MiB, used for non-English audio when installed),
or Silero alone (~0.8 MiB). Nothing is downloaded by default.
Downloads use pinned official URLs and must pass size/SHA-256 verification.
Models are stored in %LOCALAPPDATA%\NanumPlayer\models, reused on reinstall,
and retained on uninstall. Ollama translation models are separate.
After skipping downloads, use Ctrl+N > AI 구성 요소 관리 to download all or individual
models, inspect progress/errors, or cancel. Whisper selections also prepare VAD.
Closing the menu does not cancel a download. Normal playback works without models;
completed downloads enable speech recognition on the next file without a restart.
Explicit custom model paths and existing app-folder models are not overwritten.

CUDA acceleration: the CUDA engine ships with NanumPlayer; it needs NVIDIA's cuBLAS
(a CUDA 13 Toolkit, or the optional download). Select it at install time or use
Ctrl+N > AI 구성 요소 관리. Modes: Auto (CUDA when usable, otherwise CPU), CPU,
CUDA required. Missing CUDA never disables CPU processing or external translation.
CUDA-required mode shows an actionable error without blocking ordinary playback.
Text subtitle input and full text translation need neither Whisper/VAD nor CUDA.
CUDA required applies to speech recognition, not text translation.
Changing the AI input between text and speech restarts that input's engine safely.
Already buffered audio is fed to newly selected speech input. A fully translated
external subtitle file releases preroll even when shorter than the requested lead.
The optional engine requires compute capability 8.6+ and a compatible NVIDIA driver.

An installed CUDA 13 Toolkit (found via CUDA_PATH_V13_*/CUDA_PATH, the registry
environment or %ProgramFiles%\NVIDIA GPU Computing Toolkit) is used in place, so Auto
mode uses the GPU on the first file with no download and no license step; CUDA 12 is not
enough. Without a Toolkit the app uses the CPU and offers the cuBLAS download (~507 MiB,
NVIDIA terms must be accepted). Files are size/SHA-256 verified, cancel-safe and cached
under %LOCALAPPDATA%\NanumPlayer\accelerators\cuda\13 (independent of the app version;
old per-version folders are migrated by a verified copy); uninstall retains them.
Quitting during playback no longer waits for a running speech-recognition pass.
Downloads and mode changes activate on the next opened file, not during playback.
Silent install: /TASKS=cuda_accel requests CUDA downloads and accepts the bundled
NVIDIA terms. /TASKS= installs the CPU player without optional downloads.
Requested download failures return an installation error, not silent success.

Glossary and style (Ctrl+N): the translation model identifies the film from its
title and builds a glossary of characters (family, given and full names) and
proper nouns used for all translation. View, add, change or delete entries in
Ctrl+N > 용어집 (or edit them all in Notepad); changes also retranslate the existing
subtitles that contain those names. Quality depends on the model; check the list.
번역 말투 (style): natural (default) / polite / casual / close to the original / custom.
Byte-token garbage from some local models ("<0xED><0x9B><0xA0>") is repaired.

Disc image subtitles (PGS) are read with Windows OCR into an extra track
"한국어 (영어 디스크 자막 기반)". Without the English OCR pack the installed
recognizer (e.g. Korean) is used with corrections; install the English pack from
Ctrl+N for better accuracy. Ctrl+N > 온라인 자막 찾기 opens OpenSubtitles or Jimaku
in your browser; subtitles you download (also .zip) are picked up from the Downloads
folder, time-aligned automatically to the speech subtitles, and translated.

Keys
  Ctrl+N   AI subtitle settings (input source, full translation, engine, model)
  Ctrl+K   AI subtitle status
  Ctrl+O   Native file picker
  Ctrl+D   Blu-ray drive/folder
  Ctrl+A   Audio track panel
  Ctrl+T   Subtitle track panel

The Windows 11-style interface has dark rounded panels and an automatically
hiding playback bar with seeking, volume, fullscreen and AI settings.

Settings and caches: %APPDATA%\NanumPlayer (mpv.conf, script-opts\nanum.conf, tr_cache.jsonl).
Whole-file translations: %LOCALAPPDATA%\NanumPlayer\full.

Subtitle display (Ctrl+N): translation only (default), translation + original, original only.
Changing the display does not rerun recognition or translation.

Listening audio and the AI input audio are independent. Switching to another language
asks whether to keep the original AI input, generate from the new audio, or look up saved
subtitles for it. Cancelling keeps the old input and any running work.

The SQLite library is %LOCALAPPDATA%\NanumPlayer\library.sqlite.
On reopening recognized media, choose use saved translation, translate saved original
(no audio scan/STT), regenerate from audio, or disable AI for this playback.
An optional remembered setting automatically uses saved translations.
Failed/cancelled regeneration retains the previous completed translation.
This build supports Blu-ray and media files, not dvd:// (DVD libraries are not compiled).

Blu-ray discs: install and activate MakeMKV first. NanumPlayer automatically uses
libmmbd64.dll from MakeMKV's standard Program Files installation directory without
copying or bundling it. User-provided libaacs.dll and libbdplus.dll beside the
player (or in the legacy bin folder), and explicit LIBAACS_PATH / LIBBDPLUS_PATH
environment variables, take precedence. For a custom
MakeMKV install, set those variables to the absolute libmmbd64 path WITHOUT ".dll"
(libbluray appends that extension on Windows). Then run:
  NanumPlayer.exe bd://longest --bluray-device=E:

Playback failures cancel AI subtitle preparation and display an error.
Normal log: %APPDATA%\NanumPlayer\last-playback.log (8 MiB, 2 previous files).
Ctrl+N > 진단 로그(디스크 읽기 상세) enables bounded disc I/O diagnostics:
%APPDATA%\NanumPlayer\diagnostics\disc-DATE-TIME-PID.log (8 MiB each, newest 8).
IPC command: nanum-diagnostics on|off|toggle. Startup: NANUMPLAYER_DIAGNOSTICS=1.
Diagnostics correlate seeks, first data, ReadFile errors and Windows events;
they do not record media payload, keys or drive serials. Explicit --log-file
keeps the standard mpv log policy.
This version fixes seek recovery when Blu-ray TrueHD and its AC-3 core share
a stream ID. The AI decoder stays on one stream instead of repeatedly restarting.
Repeated seek replay clears the subtitle decoder cache before reusing saved cues.
Disc read errors are separate from AI readiness; check the diagnostic log if
a particular Blu-ray position stalls.

The player is built from mpv (GPLv2+), whisper.cpp (MIT) and ffmpeg; source is the NanumPlayer
repository.
