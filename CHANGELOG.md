# Changelog

All notable changes to NanumPlayer are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/) (the application version is `NANUM_VERSION` in
`third_party/mpv/osdep/nanum-version.h`).

Versions marked *internal build* were never published as separate GitHub releases; their changes first
shipped in the release named after them. Dates are release dates (UTC); internal builds have none.

## [Unreleased]

## [1.13.2] - 2026-10-18

### Added
- **Picture** button in the playback bar (with a status dot and tooltip) and the **Ctrl+I** shortcut open a
  quick picture menu: upscaling (default, high quality, RTX auto/1.5x/2x/3x, custom shaders), correction
  presets, before/after comparison and detailed settings.

### Changed
- Ctrl+N: **Video upscaling** and **Picture quality** are merged into one **Picture quality** entry.

## [1.13.1] - 2026-10-18

### Changed
- The playback header no longer shows the app version; the window title shows it instead
  (`<video> - NanumPlayer 1.13.1`). The start screen keeps its version badge.

### Fixed
- AI subtitles (and other ASS/image subtitles) are lifted above the playback bar instead of being hidden
  behind it.

## [1.13.0] - 2026-10-18

Changes made while preparing the public launch of the project.

### Added

- **Optional Blu-ray/DVD decryption components.** The libraries that remove copy protection (libaacs,
  libbdplus, libdvdcss) are no longer part of the installer or the portable ZIP. They are one separately
  downloaded asset (`NanumPlayer-disc-components-<version>.zip`) that the player offers to install when an
  encrypted disc needs it, from **Ctrl+N → Blu-ray/DVD decryption components**, from an unchecked installer task or
  from a ZIP you downloaded yourself. The download is pinned by size and SHA-256 and verified again before
  loading. The public AACS key database is fetched only after the component is installed and you agreed. See
  [docs/disc-components.md](docs/disc-components.md).
- English documentation (README, user guide, reference, privacy, troubleshooting, building) with Korean
  translations, a terminology glossary, a verification history, `LICENSE` (GPL-2.0-or-later),
  `THIRD_PARTY_NOTICES.md`, `CONTRIBUTING.md`, `SECURITY.md`, `CODE_OF_CONDUCT.md`, and GitHub issue and pull
  request templates.
- `tools/check_i18n.py`, which verifies that every user-visible string exists in all six interface languages.
- A documentation and project website (Astro Starlight, English and Korean) in `site/`.

### Changed

- **Upgrading from 1.12.0 or earlier:** the installer removes the decryption libraries that earlier versions
  placed in the application folder. To play encrypted discs again, install the optional component (the player
  tells you how). Unprotected discs, your settings, models and keys are unaffected.
- Choosing an `[Original]` or `[File]` subtitle yourself now pauses the AI work (speech recognition, OCR,
  original-language audio) regardless of the subtitle's language; choosing an AI entry restarts it from the
  current position.

### Fixed

- Choosing an embedded subtitle during disc playback now re-reads from the current position, so it appears at once
  instead of up to two minutes late (verified on a Blu-ray).

## [1.12.0] - 2026-10-18

### Added

- **Unified subtitle list.** The **Subtitles** button opens one list that labels each entry with its source:
  `[AI]`, `[Original]` (disc, file or YouTube uploader subtitle), `[File]` and `[OCR]`.
- A subtitle that already exists in the target language (disc, file or YouTube uploader subtitle) is shown
  directly without AI work.
- Subtitle files can be loaded **as they are** or **translated** (aligned in time with AI). A subtitle with
  the same name as the video is loaded automatically.
- **Ctrl+N → Generate full subtitles…** makes a source-language SRT and one translated SRT per language
  without playing, from speech recognition, a text subtitle track or image-subtitle (PGS) OCR.
- **Picture quality** (internal build 1.11.0): presets Original, Sharper anime, Smoother old anime and
  Compressed video repair; Off/Weak/Medium/Strong control of noise reduction, debanding, line
  enhancement, sharpening and color correction; a temporary compare-before-correction view. It uses nine
  lightweight GPU shaders (about 12.3 KiB) and no AI model. RTX upscaling pauses line enhancement and
  sharpening automatically.

### Changed

- The default translation target language is the Windows display language. Nothing is translated if the
  source already is the target language.
- Release installers and NanumPlayer's own binaries are signed with a timestamped certificate (*Nanum Space
  Co,. Ltd*); `SHA256SUMS` accompanies each release.

### Fixed

- When the translation server cannot be reached, the original text is shown instead of removing the
  subtitle.

## [1.11.0] - internal build

### Added

- **Ctrl+N → Picture quality** with the presets, controls and compare view listed under 1.12.0.

## [1.10.0] - 2026-10-17

First public release since 1.6.3; it also contains everything from the internal builds 1.7.0 to 1.9.0
below.

### Added

- **GPU video upscaling** (**Ctrl+N → Video upscale**): Default, High-quality scaling, NVIDIA RTX upscaling
  (Auto, 1.5x, 2x, 3x) and user GLSL shaders with reordering. Settings are saved and your own filters are
  preserved. Unsupported processing and shader compile errors are shown; the RTX status says whether it was
  requested and does not claim the driver is processing the video.

### Changed

- Installer and portable ZIP are signed with a timestamped certificate; `SHA256SUMS` accompanies the release.

## [1.9.0] - internal build

### Added

- The app version is shown at the top left of the start screen and above the playback controls.
- The interface is available in Korean, English, Japanese, Simplified Chinese, Traditional Chinese and
  Spanish: menus, settings, native dialogs, web windows and the installer. Change it from the start-screen
  language button, **Ctrl+Alt+L** or **Ctrl+N → Interface language**. The interface language is
  independent of the speech and subtitle translation languages.

## [1.8.2] - internal build

### Changed

- YouTube and web windows always open InPrivate; login, cookies and browser temporary data are removed when
  the session ends. Cookies of an ordinary web video are passed in memory instead of through a file.
- Playback logs, watch and position history, translation JSONL, the subtitle library, GPU disk caches and
  crash dumps are no longer written by default. Whole-file translation results go to a temporary folder that
  is cleared on exit.

## [1.8.1] - internal build

### Added

- **Play from a web page** on the start screen.

### Fixed

- The final translation is now handled when a translation model puts its reasoning and a draft JSON before
  the answer.
- Web audio without a language tag starts with automatic multilingual language detection.
- The CPU and CUDA engines, fixed in this version, are bundled so that old cached engines are never used.
- After a timeline or arrow-key seek the player no longer pauses automatically to wait for AI subtitles; it
  keeps the previous play or pause state.

## [1.8.0] - internal build

### Added

- **Play web-page videos** (**Ctrl+Shift+Y**, or **Ctrl+N → Play from a web page video address…**): open a
  site in the built-in browser, start the video there, and click **Play in NanumPlayer**. iframes and detected
  HLS/DASH manifests are handled; the video's own cookies, Referer and User-Agent apply to that file only.
  Subtitles come from NanumPlayer's usual speech recognition and translation.

## [1.7.0] - internal build

### Added

- **Ctrl+B** saves a Blu-ray or DVD title to MKV inside the player, without re-encoding and keeping audio,
  subtitles and chapters, with progress, Ctrl+C cancellation and preservation of existing files. For DVD, missing
  video timestamps are generated with FFmpeg and a command that moves on to the next title is cut at the real
  title boundary, which prevents dropped frames and content from another title.

### Changed

- The MakeMKV executable and DLL dependencies were removed in favor of independent disc libraries and an
  automatic AACS key database download.

## [1.6.3] - 2026-10-12

### Changed

- The playback bar hides 1.2 seconds after the mouse stops (setting: short, normal 2 s, long 3 s) and at once
  when the cursor leaves the window; it stays while paused or while the cursor is on it.
- A tag above the playback bar shows how the selected AI subtitle track is made (speech recognition on GPU or
  CPU, source model or origin, translation model and whether it runs on a local GPU, partly on the GPU, on
  the CPU or in the cloud). Click it to open the related setting; **Ctrl+N** turns it off.
- The app version is shown on the start screen, in the **Ctrl+N** About entry (which opens the releases page)
  and in **Ctrl+K**. The version is defined in one place, `third_party/mpv/osdep/nanum-version.h`, shared by
  the player, the YouTube helper's file information and packaging.

## [1.6.2] - 2026-10-11

### Changed

- Guidance for the MakeMKV program that encrypted Blu-ray playback needed at that time: the installer
  announced it and could open its download page, and the player told "not installed" and "could not decrypt
  (not activated or key expired)" apart. Superseded by 1.7.0.

## [1.6.1] - 2026-10-11

### Added

- The installer checks what is already installed before it installs: installed speech models, VAD and cuBLAS
  caches are shown as already installed and disabled; with a compatible CUDA 13 Toolkit the CUDA item says it
  need not be downloaded; a missing NVIDIA driver is shown. The *Ready* page lists speech models, CUDA (Toolkit,
  driver, GPU), YouTube tools, WebView2 Runtime, Ollama and MakeMKV state with what to do. It informs only; nothing
  is installed automatically. The results are written to the install log.

### Changed

- The CUDA engine (`nanum_ai_cuda.dll`, about 53 MiB, signed and pinned by SHA-256) is an optional download
  again, which brings the installer back from 82 MiB to 47 MiB. With a CUDA 13 Toolkit only the engine is
  fetched and the Toolkit's cuBLAS is used. The cache is `%LOCALAPPDATA%\NanumPlayer\accelerators\cuda\13`,
  independent of the app version. (The engine is bundled with the app again in 1.8.1.)
- YouTube tools are not downloaded again when they are current.

## [1.6.0] - 2026-10-11

### Added

- The CUDA engine is included in the app. With a CUDA 13 Toolkit installed the GPU is used without a download
  (the Toolkit is also found through the registry and the default install folder). Only if there is no
  Toolkit is cuBLAS offered; its cache is independent of the app version.
- Code signing of binaries, the installer and the uninstaller.

### Changed

- Removed the "CUDA engine update required" notice that 1.5.1 introduced.

### Fixed

- Quitting during playback was slow (up to about 20 seconds on the CPU); speech recognition now stops at once
  (see 1.5.1).

## [1.5.1] - 2026-10-11

### Fixed

- Slow exit during playback. With large-v3-turbo on the CPU the engine cleanup waited for the running Whisper
  computation (up to a 20-second span, encoder included): 19.7 seconds in a repro. Whisper now has an abort
  callback, and the bundled whisper.cpp passes it to the CPU backend even during the encoder, giving an exit
  in 0.3 seconds, and the computation of a past span is discarded at once on a seek.
- After an app update, if the CUDA engine is unchanged the engine of the previous version folder is copied
  after a SHA-256 check; if it changed, a "CUDA engine update required" notice (once per version) and status
  appear and the CPU is used meanwhile.

## [1.5.0] - 2026-10-11

### Added

- **YouTube playback.** The start-screen **YouTube** button (Ctrl+Y) opens an in-app YouTube window (WebView2,
  `nanum_youtube.exe`) where you choose and sign in as usual. The chosen video is played by NanumPlayer through
  `yt-dlp` (and Deno; optional, SHA-256-verified downloads with update checks) using that window's cookies,
  with speech recognition, translation, glossary, style and saving by video ID. If the video has subtitles
  they are used as the source by the input-source rules (switchable to speech recognition). Paste an address
  (**Ctrl+N → Play from a YouTube address…**) or use the "Open with NanumPlayer" browser bookmark
  (`nanumplayer://open?url=`). Using your account with an unofficial tool can make YouTube add checks or
  limits.

## [1.4.0] - 2026-10-10

### Added

- **Disc image subtitles (PGS)** are decoded from the same demuxer, read with Windows OCR and shown as an extra
  track, for example "Korean (based on English disc subtitles)", with exact disc timing and no extra disc reads.
- **Find online subtitles** (OpenSubtitles for English/Japanese/Korean and Jimaku for Japanese) opens the search
  page in your browser; subtitles you download (also `.zip`) are picked up from the download folder, aligned in
  time with the speech-recognized subtitles and shown as a translated track such as "Korean (based on
  OpenSubtitles English subtitles)". The site is never automated. The translation model is chosen from the
  models installed in Ollama. Results are saved per film (when the library is enabled).
- Engine ABI 7 (CUDA engine with Windows OCR for disc image subtitles).

## [1.3.0] - 2026-10-10

### Added

- For Blu-rays and files with several audio languages, subtitles are made from the playing audio first and, at
  lower priority and from the same stream, from the original-language audio identified by AI (no extra disc
  reads). Both results are stored per film and reused when reopened.
- A **glossary** of characters (family, given and full names) and proper nouns is built from the work's
  title, applied to live and whole-file translation, and editable in the menu; editing it re-translates
  existing subtitles.
- **Translation style** setting; optional download of Whisper large-v3-turbo.
- Engine ABI 6 (translation style, per-film glossary, title profile, byte-token repair).

### Fixed

- The same line shown twice after re-analysis, and garbled text from `<0xHH>` byte tokens of local models
  (also in existing caches).

## [1.2.1] - 2026-10-09

### Changed

- Text-subtitle input and whole-text translation no longer depend on Whisper, VAD or CUDA. Translation-only and
  scan-only are separate modes, and switching between text and speech input safely restarts the work and
  engine. New speech input also receives audio that was already buffered, and a short external subtitle plays
  after the whole translation even if shorter than the preroll target.
- The corrected CUDA engine's URL, SHA-256 and user cache are separate from 1.2.0's, whose assets are unchanged.

## [1.2.0] - 2026-10-09

### Added

- The built-in CPU engine and the optional CUDA engine plus cuBLAS are separate. Setup and settings use the same
  pinned asset list, and a compatible Toolkit is reused in place. Modes Auto, CPU and CUDA required, and
  separate notices for missing models or acceleration. Unattended installs also run the chosen optional
  downloads.
- Optional disc diagnostics: Windows read errors, seek timings and related events.

### Changed

- Default log size and retention are bounded.

### Fixed

- Right after a GPU → CPU switch, a waiting thread of the OpenMP runtime executed an unloaded DLL at exit. The
  engine is released per file and only the OpenMP runtime stays until the process ends.

## [1.1.0] - internal build

### Added

- Native executable, icon and dark Windows window border; no separate launcher.
- Windows 11-style start card, auto-hiding playback bar, seek and volume controls, and subtitle, audio and AI
  setting panels instead of the default mpv on-screen controller.
- Optional model downloads from setup and the settings menu.

### Changed

- Speech models are no longer bundled. Model initialization waits for the first input language, so Japanese
  input no longer asks for the English model needlessly.
- The AI input is fixed to one real stream, and a seek resets the decoder and ready time.
- On repeated seeks, overlapping re-analysis of the same line is not shown twice, and the ASS cache is cleared
  before the stored cues are delivered again.

### Fixed

- The AI decoder restarted on every packet when a Blu-ray's TrueHD and AC-3 core shared a stream ID.
- A virtual AI subtitle stream stayed waiting for an update after a cached seek in a file.

## [1.0.2] - internal build

### Added

- Display modes for AI subtitles (translation only, translation + original, original only).
- The playing audio and the AI input audio are separated; switching audio asks whether to keep the AI input,
  generate from the new audio or look up the new audio's saved subtitles.
- A per-film subtitle library (`library.sqlite`, SQLite WAL) that stores media, input tracks, source
  transcripts and times, translations, model, target language and job state; **Re-translate from saved source
  text** skips disc reading and recognition. Files are identified by size plus a SHA-256 content fingerprint
  and Blu-rays by libbluray's disc identity, never by drive letter. DVD playback via `dvd://`.

## [1.0.1] - internal build

### Fixed

- The `cannot find libaacs` error of the package.
- AI waiting is released when a file ends or fails.

### Added

- On-screen error notices and `last-playback.log` (removed from the defaults in 1.8.2).

### Changed

- Packaging output is separated into per-version folders so a running older package is not deleted.

[Unreleased]: https://github.com/kimmingul/NanumPlayer/compare/v1.13.2...HEAD
[1.13.2]: https://github.com/kimmingul/NanumPlayer/releases/tag/v1.13.2
[1.13.1]: https://github.com/kimmingul/NanumPlayer/releases/tag/v1.13.1
[1.13.0]: https://github.com/kimmingul/NanumPlayer/releases/tag/v1.13.0
[1.12.0]: https://github.com/kimmingul/NanumPlayer/releases/tag/v1.12.0
[1.10.0]: https://github.com/kimmingul/NanumPlayer/releases/tag/v1.10.0
[1.6.3]: https://github.com/kimmingul/NanumPlayer/releases/tag/v1.6.3
[1.6.2]: https://github.com/kimmingul/NanumPlayer/releases/tag/v1.6.2
[1.6.1]: https://github.com/kimmingul/NanumPlayer/releases/tag/v1.6.1
[1.6.0]: https://github.com/kimmingul/NanumPlayer/releases/tag/v1.6.0
[1.5.1]: https://github.com/kimmingul/NanumPlayer/releases/tag/v1.5.1
[1.5.0]: https://github.com/kimmingul/NanumPlayer/releases/tag/v1.5.0
[1.4.0]: https://github.com/kimmingul/NanumPlayer/releases/tag/v1.4.0
[1.3.0]: https://github.com/kimmingul/NanumPlayer/releases/tag/v1.3.0
[1.2.1]: https://github.com/kimmingul/NanumPlayer/releases/tag/v1.2.1
[1.2.0]: https://github.com/kimmingul/NanumPlayer/releases/tag/v1.2.0
