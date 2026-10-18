NanumPlayer
===========

NanumPlayer.exe is the native player itself, not a launcher. No mpv.exe child
process is used. Open a file from the start card, drag it into the window, or run
NanumPlayer.exe "movie.mkv". AI subtitles are shown as tracks named after
their source, e.g. "Korean (based on English audio)" (the target language is your Windows
display language unless you change it). When the audio has several languages
(e.g. a US Blu-ray of a Japanese film), subtitles are also made from the original-language
audio ("Korean (based on Japanese audio)") at lower priority, from the same disc read; the
playback-audio track stays selected, choose the other in the subtitle menu.
Subtitles are held for this playback only by default and regenerated next time.

Interface language and version
- The app version is visible at the top-left of the start screen and in the
  playback header while the controls are shown, including small windows.
- Supported UI languages: Korean, English, Japanese, Simplified Chinese,
  Traditional Chinese and Spanish (player, settings, browser helper and setup).
- Use the start-screen language button, Ctrl+Alt+L, or Ctrl+N > Interface language.
  This does not change speech recognition or the subtitle translation language.
- The initial language follows Windows (English for unsupported languages), or
  your setup-language choice. Choose Automatic to follow Windows again.
- ui-language.conf in the settings directory retains the choice. The command-line
  --nanum-ui-language=auto|ko|en|ja|zh-CN|zh-TW|es overrides it for that run only.
- A running browser relabels its app buttons without losing the private session;
  WebView2's own menus use the new language when the next browser session starts.

GPU video upscaling (Ctrl+N > Video upscaling)
- Default restores options owned by this feature; unrelated filters and shaders
  remain intact. High-quality scaling uses ewa_lanczossharp with antiring 0.6.
- NVIDIA RTX selects gpu-next, D3D11, D3D11VA and the d3d11vpp NVIDIA extension.
  A supported NVIDIA GPU/driver is required. Enable RTX Video Super Resolution
  in the NVIDIA app/control panel. "Requested" does not confirm driver AI activity.
- RTX factor: Auto, 1.5x, 2x or 3x. Auto follows the source/window size, rounded up
  to quarter steps and capped at 4x; it skips processing when enlargement is not
  needed. Fixed factors multiply both dimensions, regardless of window size.
- Custom shaders: add mpv-compatible .glsl/.hook/.frag files in the list manager;
  select an entry to reorder or remove it. Third-party shader packs are not bundled.
  Selected shaders follow existing user shaders, which are preserved.
- Changes apply during playback and are saved in script-opts/nanum-upscale.conf
  under the settings directory. Renderer changes can briefly recreate the picture.
  Unsupported processing and shader compile failures appear in the status;
  processing added by this feature is removed on failure.
- This is separate from speech-recognition CUDA acceleration: no CUDA Toolkit
  is needed. RTX HDR conversion is not enabled. HDR/10-bit support depends on
  the driver and video processing path. Concurrent AI work can reduce frame rate.

Built-in picture correction (Ctrl+N > Picture quality)
- Presets: Original (default, no added correction), Sharper anime, Smoother old
  anime, and Compressed video repair. No AI models or downloads are required.
  Nine original lightweight GPU shaders total about 12.3 KiB.
- Noise reduction, debanding, line enhancement, sharpening and color correction
  each have Off / Weak / Medium / Strong settings. Color gently increases the
  existing saturation/contrast; line enhancement darkens lines, not AI redrawing.
- Compare before correction temporarily disables only these corrections.
  Upscaling and unrelated user filters remain active. Comparison is not saved;
  selecting Original disables corrections persistently.
- RTX mode pauses line enhancement and sharpening to avoid duplicate processing;
  their selected strengths return when leaving RTX. Denoise, deband and color
  can remain active. Avoid doubling sharpening with custom shaders.
- Requires gpu-next or gpu. Settings live in script-opts/nanum-picture.conf.
  Existing filters/shaders and externally changed controls are preserved.
  Unsupported rendering and shader errors appear in the menu.
- These are spatial filters, not temporal flicker correction, AI recoloring or
  animation restyling. Strong denoise can erase texture. Compare quality and
  playback load, especially with HDR, high resolution or concurrent AI subtitles.

Web-page videos (Ctrl+Shift+Y)
- Click "Play from a web page" on the start screen, or choose
  Ctrl+N > Play from a web page video address..., and paste the page URL.
- In the built-in WebView2 browser, sign in if needed and start the site's video,
  then click "Play in NanumPlayer". Playback and AI subtitles run in NanumPlayer,
  not over the website. The usual speech models and translation server are required.
- The helper detects loaded media in frames and observed HLS/DASH manifests.
  Video-specific cookies, Referer and User-Agent apply only to that file; they do
  not carry over to the next file. The YouTube-specific Ctrl+Y flow is unchanged.
- Untagged audio starts with multilingual automatic language detection.
  Install a multilingual speech model for automatic/non-English input.
- AI subtitle preparation can wait when first opening a file. Timeline and
  arrow-key seeks keep playing without an AI wait; manual pause stays paused.
- DRM, streams without an accessible media/manifest URL, and servers blocking
  playback outside the browser are unsupported. Reopen the page if a URL expires.
- YouTube and web pages always use an InPrivate session. Login lasts only for
  that session. Ctrl+N > YouTube > End the private web session (sign out) ends it.
- General-web cookies are passed in memory with domain/path scope. YouTube's
  helper cookie file is removed when its session ends. The extractor gets a
  player-owned temporary copy, removed with the player session, so yt-dlp cannot
  recreate the browser's cookie file after the browser has closed.
- WebView2 can create temporary files; the session directory is removed after
  the browser process exits. Stale browser sessions are cleared on next startup.
- This does not hide traffic from websites, network operators or translation
  providers, or guarantee forensic erasure of deleted files or OS-paged memory.

Requirements
- Windows 10/11 x64 with an AVX2 CPU. CPU speech recognition is included.
- A translation server: Ollama (https://ollama.com) running, with a model installed.
  Pick it with Ctrl+N > Translation model: the list shows the models installed in Ollama
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
After skipping downloads, use Ctrl+N > AI component manager to download all or individual
models, inspect progress/errors, or cancel. Whisper selections also prepare VAD.
Closing the menu does not cancel a download. Normal playback works without models;
completed downloads enable speech recognition on the next file without a restart.
Explicit custom model paths and existing app-folder models are not overwritten.

CUDA acceleration: the verified CUDA engine (~53 MiB) is bundled with the app.
It needs NVIDIA's cuBLAS from a CUDA 13 Toolkit or an optional download selected
at install time or via Ctrl+N > AI component manager. Modes: Auto (CUDA when usable, otherwise CPU), CPU,
CUDA required. Missing CUDA never disables CPU processing or external translation.
CUDA-required mode shows an actionable error without blocking ordinary playback.
Text subtitle input and full text translation need neither Whisper/VAD nor CUDA.
CUDA required applies to speech recognition, not text translation.
Changing the AI input between text and speech restarts that input's engine safely.
Already buffered audio is fed to newly selected speech input. A fully translated
external subtitle file releases preroll even when shorter than the requested lead.
The CUDA engine requires compute capability 8.6+ and a compatible NVIDIA driver.

An installed CUDA 13 Toolkit (found via CUDA_PATH_V13_*/CUDA_PATH, the registry
environment or %ProgramFiles%\NVIDIA GPU Computing Toolkit) is used in place for cuBLAS,
so no engine/runtime download or NVIDIA license step is needed; CUDA 12 is not
enough. Without a Toolkit the app uses the CPU and offers only the cuBLAS download
(~507 MiB, NVIDIA terms must be accepted). The bundled engine is size/SHA-256
verified before loading; a missing/damaged engine requires reinstalling the app.
Old cached engines are never loaded. Downloaded cuBLAS files are size/SHA-256
verified, cancel-safe and cached under %LOCALAPPDATA%\NanumPlayer\accelerators\cuda\13
(independent of app version; verified old runtime caches are migrated).
Uninstall retains downloaded runtimes.
Quitting during playback no longer waits for a running speech-recognition pass.
Downloads and mode changes activate on the next opened file, not during playback.
Silent install: /TASKS=cuda_accel requests cuBLAS downloads and accepts the bundled
NVIDIA terms. /TASKS= installs both engines without optional downloads.
Requested download failures return an installation error, not silent success.
Setup checks what is already installed: installed models, VAD and the cuBLAS cache
are shown as already installed and not downloaded again; with a CUDA 13 Toolkit the CUDA
download is not needed; current YouTube tools are not re-downloaded. The Ready page
lists models, CUDA (Toolkit, driver, GPU), YouTube tools, WebView2, Ollama and the built-in disc engine.
Silent install: /TASKS=disc_components downloads the optional Blu-ray/DVD decryption components
(see "Blu-ray and DVD" below; the task is explicit acceptance of its notice).

Glossary and style (Ctrl+N): the translation model identifies the film from its
title and builds a glossary of characters (family, given and full names) and
proper nouns used for all translation. View, add, change or delete entries in
Ctrl+N > Glossary (or edit them all in Notepad); changes also retranslate the existing
subtitles that contain those names. Quality depends on the model; check the list.
Translation style (Ctrl+N): natural (default) / polite / casual / faithful to the original / custom.
Byte-token garbage from some local models ("<0xED><0x9B><0xA0>") is repaired.

Disc image subtitles (PGS) are read with Windows OCR into an extra track
"Korean (based on English disc subtitles)". Without the English OCR pack the installed
recognizer (e.g. Korean) is used with corrections; install the English pack from
Ctrl+N for better accuracy. Ctrl+N > Find online subtitles (OpenSubtitles · Jimaku) opens OpenSubtitles or Jimaku
in your browser; subtitles you download (also .zip) are picked up from the Downloads
folder, time-aligned automatically to the speech subtitles, and translated.

Keys
  Ctrl+N   AI subtitle settings (input source, full translation, engine, model)
  Ctrl+K   AI subtitle status
  Ctrl+Alt+L  Interface language
  Ctrl+O   Native file picker
  Ctrl+D   Blu-ray drive/folder
  Ctrl+A   Audio track panel
  Ctrl+T   Subtitle track panel
  Ctrl+B   Native Blu-ray/DVD MKV save (Ctrl+C cancels)

The Windows 11-style interface has dark rounded panels and an automatically
hiding playback bar with seeking, volume, fullscreen and AI settings.

Settings: %APPDATA%\NanumPlayer (mpv.conf, script-opts\nanum.conf, ui-language.conf).
Playback logs, history/resume, translation disk caches, subtitle libraries,
GPU disk caches and crash dumps are off by default. Legacy default history and
cache files are removed on startup; models, tools, settings and disc keys stay.
Whole-file translations and import working copies use a per-process temporary
directory, cleared on file changes and normal exit. Stale result directories
from terminated players are cleared on next startup.

Subtitle list (the Subtitles button, or Ctrl+N): one list with source badges: [AI] made by NanumPlayer
in the target language, [Original] a disc/file/YouTube-uploader subtitle shown as it is, [File] a subtitle
file next to the video or one you loaded, [OCR] a disc image subtitle read by text recognition. A subtitle
that already exists in the target language is selected automatically and the AI work is skipped (turn
this off in Ctrl+N; choosing an AI entry restarts it). Choosing an [Original] or [File] subtitle yourself
pauses the AI work. Subtitle files can be loaded as they are or aligned to the speech and translated.
Target language (Ctrl+N): defaults to your Windows display language; if the audio already is that
language nothing is translated.
Subtitle display of AI entries (Ctrl+N): translation only (default), translation + original, original only.
Changing the display does not rerun recognition or translation.

Listening audio and the AI input audio are independent. Switching to another language
asks whether to keep the original AI input or generate from the new audio.
Cancelling keeps the old input and any running work.

Only explicit --nanum-library-db=<path> enables a persistent local-media library
and saved-subtitle choices. Explicit --nanum-cache and --nanum-full-dir can also
retain local-media data. Network media never uses these persistent destinations.
Do not enable these options if you want no retained playback information.
Blu-ray and DVD

Unprotected Blu-ray/DVD discs, disc folders (BDMV, VIDEO_TS) and disc images play with the
libraries in this package (libbluray, libdvdread, libdvdnav; their licenses and the
corresponding sources are in disc/). Blu-ray/DVD handling runs inside the player. No
MakeMKV executable, DLL, activation key or evaluation period is used.

Copy-protected discs (AACS, BD+ for Blu-ray, CSS for DVD) need the OPTIONAL Blu-ray/DVD
decryption components (libaacs, libbdplus, libdvdcss). They are NOT part of this package: a
separate download, NanumPlayer-disc-components-<version>.zip, whose size and SHA-256 are pinned
in components\catalog.json. Install it when the player offers it (the first time you open a
protected disc), in Ctrl+N > Blu-ray/DVD decryption components (download, or "install from a
ZIP file I downloaded" for offline use), or with the optional, unchecked task of the
installer. The player accepts only exactly the pinned ZIP, installs it to
%LOCALAPPDATA%\NanumPlayer\components\disc\<version> and verifies every file again before
it is loaded. Delete that folder to remove it. Upgrading from a version that shipped these
libraries inside the application folder removes them from there; install the component again
if you need it.
Circumventing copy protection is restricted or prohibited by law in many countries. You are
responsible for complying with the laws of your country.

When an encrypted Blu-ray needs keys, and only after the component is installed AND you agreed
once (asked when it is installed or first needed; Ctrl+N shows and withdraws it), the player
obtains the FindVUK public database over HTTPS:
  https://fvonline-db.bplaced.net/fv_download.php?lang=eng
It verifies ZIP structure, size and CRC, then atomically stores KEYDB.cfg in
%APPDATA%\NanumPlayer\disc. The download is about 25 MB; the unpacked cache is about 65 MB. A
working cache needs no network. A failed update preserves the old cache. A database under one
hour old is not fetched again.
Missing database keys, unavailable BD+ VM data, unsupported AACS versions and
drive authentication failures remain explicit errors. This is not a claim of
MakeMKV-equivalent support for every BD+/UHD disc or LibreDrive operation.
The bundled libbluray has its MakeMKV fallback removed; old renamed DLLs and
LIBAACS_PATH / LIBBDPLUS_PATH overrides are not used.

  NanumPlayer.exe bd://longest --bluray-device=E:
  NanumPlayer.exe dvd:// --dvd-device=E:

Ctrl+B lists titles at least two minutes long and writes the selected title(s),
using the default angle, as lossless MKV files under %USERPROFILE%\Videos\NanumPlayer.
Audio tracks, subtitles and chapters are retained. Ctrl+C cancels the native
operation and removes only its unfinished file; completed files remain.
Existing files are not overwritten. Scripted use: script-message nanum-rip.

Ctrl+N > Generate full subtitles... (the "Create subtitle files" window) makes SRT files for a local video or a Blu-ray title
without playing it: the source is speech recognition, a text subtitle track or OCR of an
image subtitle (PGS) track, followed by one translated SRT per chosen language. Files are
<name>.<language>.srt next to the video (discs: %USERPROFILE%\Videos\NanumPlayer or a
folder you choose); existing files are never overwritten (.2, .3, ...), unfinished files
are never left behind, and cancelling keeps what was already saved. Nothing is written
unless you start it. Scripted use: the nanum-generate command, script-message
nanum-generate-start/-cancel, property user-data/nanum/generate.

Playback failures cancel AI subtitle preparation and display an error.
No normal playback log is saved by default.
Ctrl+N > Diagnostic log (detailed disc reads) enables bounded disc I/O diagnostics:
%APPDATA%\NanumPlayer\diagnostics\disc-DATE-TIME-PID.log (8 MiB each, newest 8).
IPC command: nanum-diagnostics on|off|toggle. Startup: NANUMPLAYER_DIAGNOSTICS=1.
Diagnostics correlate seeks, first data, ReadFile errors and Windows events;
they do not record media payload, keys or drive serials. Explicit --log-file
keeps standard mpv logging and may contain URLs/paths; do not use it for privacy.
Crash dumps require explicit NANUMPLAYER_CRASH_DUMP_DIR and may contain secrets.
This version fixes seek recovery when Blu-ray TrueHD and its AC-3 core share
a stream ID. The AI decoder stays on one stream instead of repeatedly restarting.
Repeated seek replay clears the subtitle decoder cache before reusing saved cues.
Disc read errors are separate from AI readiness; check the diagnostic log if
a particular Blu-ray position stalls.

NanumPlayer is free software under the GNU General Public License, version 2 or (at your option) any
later version (LICENSE). It is built from mpv, whisper.cpp (MIT), FFmpeg and other third-party libraries;
see THIRD_PARTY_NOTICES.md for their licenses. Source code, documentation and the changelog:
https://github.com/kimmingul/NanumPlayer
