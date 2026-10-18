# Privacy

English · [한국어](ko/privacy.md)

NanumPlayer is built so that, by default, nothing about what you watched is kept. This page lists what
is stored, what is downloaded, and what leaves your PC, so you can check the claims against the
[source code](https://github.com/kimmingul/NanumPlayer).

NanumPlayer has no accounts, no telemetry or analytics and no automatic update check, and it contains
no server of its own. The only network connections made by NanumPlayer's own code are the ones
listed in [what the player downloads and contacts](#what-the-player-downloads-and-contacts). The
**About** entry at the bottom of **Ctrl+N** merely opens the GitHub releases page in your browser.

## What is not kept by default

Unless you switch them on explicitly, none of these is written:

- playback logs (the default log is off),
- watch history and resume positions, visited addresses and playback positions,
- translation caches (JSONL files),
- the subtitle library (a SQLite file of saved subtitles),
- GPU shader and color-profile disk caches,
- crash dumps.

Whole-file translation results and subtitle-import working copies live in a transient folder of the
running process (`%TEMP%\NanumPlayer-session-<pid>-<start time>`). It is emptied when media ends,
removed when the player exits, and swept at the next start if the player was killed.

Files that earlier versions kept in their default places (the `last-playback*.log` files in the settings
folder, `tr_cache.jsonl`, `%LOCALAPPDATA%\NanumPlayer\library.sqlite*`, the `full\`, `cache\` and `dumps\`
folders, and old browser profiles) are removed the first time a newer version starts, unless you pointed
the matching option at a place of your own. Models, settings, downloaded tools, disc keys and videos or
subtitle files you saved yourself are never touched.

Options that change this, each of which keeps data **only if you pass it explicitly**:

| Option | What it keeps |
|---|---|
| `--log-file=<file>` | mpv's normal log. It may contain addresses and file names. Do not use it for private viewing. |
| `--nanum-cache=<file>` | A translation cache for local media. Never used for web media. |
| `--nanum-library-db=<file>` | A per-film library of source transcript, times, translations, model and target language. Never used for web media. |
| `--nanum-full-dir=<folder>` | Whole-file translation results of local media. Web media always uses the transient folder. |
| `NANUMPLAYER_CRASH_DUMP_DIR` | Crash dumps. They can contain addresses, cookies and other process memory. |
| `NANUMPLAYER_DIAGNOSTICS=1` or **Ctrl+N → Diagnostic log (detailed disc reads)** | The disc diagnostic log described in [Troubleshooting](troubleshooting.md#disc-read-and-seek-diagnostics). |

## Where data lives

| What | Where |
|---|---|
| Settings (`mpv.conf`, `script-opts\*.conf`, `ui-language.conf`) | `%APPDATA%\NanumPlayer` (the *settings folder*; `~~` in mpv terms) |
| Glossary files | `%APPDATA%\NanumPlayer\glossary\<work name>.txt` and `<work name>.applied.txt`. Written whenever you edit the glossary (in the menu or in Notepad), kept afterwards, and named after the work's title: delete the folder if you do not want a trace of what you watched. Nothing is written there unless you edit the glossary. |
| Diagnostic logs (when you turn them on) | `%APPDATA%\NanumPlayer\diagnostics\` |
| Speech models | `%LOCALAPPDATA%\NanumPlayer\models` |
| cuBLAS runtime (optional) | `%LOCALAPPDATA%\NanumPlayer\accelerators\cuda\13` |
| YouTube tools (`yt-dlp`, Deno) | `%LOCALAPPDATA%\NanumPlayer\youtube` |
| Disc components and the AACS key database (optional, see [disc components](disc-components.md)) | Under `%LOCALAPPDATA%\NanumPlayer` and `%APPDATA%\NanumPlayer\disc` |
| Subtitle files you generate or save, MKV files you save | Next to the video, or `%USERPROFILE%\Videos\NanumPlayer` |

Uninstalling keeps models, the cuBLAS runtime and your settings.

## What the player downloads and contacts

| When | Where it connects | What is sent or fetched |
|---|---|---|
| Translating (always, when translation is on) | The **translation server** you configured; by default `http://127.0.0.1:11434` on your own PC | The text to translate: recognized speech or subtitle lines. For the glossary also the work's title (disc name, title tag or file name) and the audio languages. If you use an Ollama **cloud** model, Ollama forwards this text to its cloud; read Ollama's privacy terms. NanumPlayer has no control over what the server you choose does with it. |
| Whole-file translation with `omp` | The `omp` command you configured, and the provider behind the model you chose | The same text. |
| You choose to download speech models (installer or **AI component manager**) | Hugging Face, at pinned revisions of `ggerganov/whisper.cpp` and `ggml-org/whisper-vad` | A file download. Size and SHA-256 are verified. |
| You choose to download cuBLAS | GitHub releases of this repository | A file download, verified. |
| You choose to install the YouTube tools, and when you use YouTube playback | GitHub releases of `yt-dlp` and `denoland/deno` (and their release API to find the latest version) | A file download, verified; a version check. |
| YouTube and web windows | The sites you visit, through WebView2 (Microsoft Edge engine) | Normal browsing traffic. See [private web sessions](#private-web-sessions). |
| Playing YouTube | YouTube, through `yt-dlp` | The video request, using the window's cookies. |
| Playing a web page video | The video's own server | The media request with that video's cookies, Referer and User-Agent. |
| **Find online subtitles** | Your default browser opens OpenSubtitles or Jimaku | The title search text appears in the address for OpenSubtitles; for Jimaku it is copied to the clipboard. NanumPlayer does not control the site and does not read it. |
| You choose to install the optional disc component | GitHub releases of the component repository; after your consent, the FindVUK public key database | See [disc components](disc-components.md). |
| You choose **Install the English OCR language pack** | Windows (Microsoft) | Windows' own language-pack installer. |

Every download goes through one HTTPS-only module with fixed size and SHA-256 checks where files are
pinned, progress and cancel. A failed or cancelled download leaves existing good files untouched and
removes its temporary file.

## Private web sessions

The YouTube and web-page windows always run in an **InPrivate** WebView2 session. Sign-in lasts only
for that session; when the session ends (or when you choose **End the private web session (sign out)**),
login, cookies and browser temporary data are removed. The session folder is deleted after the browser
process exits, and a leftover session from a crash is cleaned at the next start.

- Cookies of an ordinary web video are passed to the player in memory, scoped by domain and path, and
  used only for that file.
- YouTube cookies use a browser-session temporary file and a player-owned temporary copy for the
  extractor, each deleted at session end. If `yt-dlp` rewrites cookies when it exits, the browser's
  deleted file is not recreated.
- WebView2 may create temporary files while it runs.

**Private mode is not anonymity or secure deletion.** It does not hide your traffic from websites,
network operators, the translation server or its provider, and it cannot prevent the operating system
from paging memory or leaving deleted files recoverable. A search page opened in your own browser (online
subtitle search) follows that browser's privacy settings.

## Third-party tools and your data

Speech recognition runs on your PC (whisper.cpp); no audio is uploaded by NanumPlayer. The text that is
translated is sent to the translation server you chose, which is why a local server keeps everything on
your PC and a cloud server does not.
