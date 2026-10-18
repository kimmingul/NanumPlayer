# NanumPlayer user guide

English · [한국어](ko/user-guide.md)

This guide walks through NanumPlayer from installation to the advanced features. Menu names are
quoted as the English interface shows them; the Korean equivalents are in the
[glossary](glossary.md). Settings and data locations are listed in [Privacy](privacy.md#where-data-lives);
command-line options are in the [reference](reference.md).

Contents: [Install](#install) · [Set up AI subtitles](#set-up-ai-subtitles) · [Play something](#play-something) ·
[Subtitles](#subtitles) · [Generate subtitle files](#generate-subtitle-files-without-playing) ·
[Video quality](#video-quality) · [Discs](#discs) · [YouTube and web pages](#youtube-and-web-pages) ·
[Interface language and shortcuts](#interface-language-and-shortcuts)

## Install

Download `NanumPlayer-Setup-<version>.exe` (or the portable ZIP) from the
[Releases page](https://github.com/kimmingul/NanumPlayer/releases/latest) and check it against
`SHA256SUMS-<version>.txt` (see the [README](../README.md#download) for the SmartScreen note).

The installer installs for the current user. Its optional tasks are all **unchecked** by default, and
nothing is downloaded unless you tick it:

| Task | What it downloads |
|---|---|
| English speech recognition: Whisper small.en + Silero VAD | The English speech model and the VAD model (about 466 MiB). |
| Multilingual speech recognition: Whisper small + Silero VAD | The multilingual speech model and the VAD model (about 466 MiB). |
| High-accuracy multilingual speech recognition: Whisper large-v3-turbo + Silero VAD | Whisper large-v3-turbo (q5_0) and the VAD model (about 548 MiB). When installed it is used for non-English audio instead of the small model. |
| Voice detection model only: Silero VAD | The VAD model (about 0.8 MiB). |
| NVIDIA CUDA acceleration: get cuBLAS | cuBLAS (about 507 MiB), only if no compatible CUDA 13 Toolkit is found. You accept NVIDIA's terms first. |
| YouTube playback components: yt-dlp + Deno | `yt-dlp` and Deno (about 60 MiB, the latest official releases at install time), for YouTube playback. |
| Blu-ray/DVD decryption components | Optional and separate; see [disc components](disc-components.md). |

The *Ready* page lists what is already present (installed models are shown as already installed and
are not downloaded again) and what is missing (speech models, CUDA Toolkit, driver and GPU, YouTube
tools, WebView2 Runtime, Ollama). It only informs; it installs nothing by itself.

Every download is pinned to an exact URL, size and SHA-256 and must verify before it is used. Models
are stored in `%LOCALAPPDATA%\NanumPlayer\models`, reused when you reinstall, and kept when you
uninstall. Unattended installs: `/TASKS=` installs without optional downloads; `/TASKS=cuda_accel`
requests the cuBLAS download and accepts the bundled NVIDIA terms. A requested download that fails makes
the installation fail with an error rather than succeed silently.

The portable ZIP needs no installation; models and tools download on demand into the same
`%LOCALAPPDATA%\NanumPlayer` folders.

## Set up AI subtitles

AI subtitles need three things: a source of text (speech recognition or an existing text subtitle), a
translation server and, for speech, the speech models.

### 1. Translation server

NanumPlayer sends text to an Ollama-compatible `/api/generate` endpoint, by default
`http://127.0.0.1:11434`. Install [Ollama](https://ollama.com), start it (`ollama serve`) and pull a
model, or sign in to use an Ollama cloud model.

Choose the model with **Ctrl+N → Translation model**. The list shows what the server reports: local
models with size and parameter count, and cloud models marked as such. If the server cannot be reached or
the model is not listed, type its name instead. A different server address can be set with
`--nanum-translate-endpoint` (an empty value turns translation off).

Model size matters. The default name, `gemma4:latest`, is 12.8 GB; on an 8 GB GPU it only partly fits and
competes with speech recognition and the video renderer, so translations can time out. A 4 GB-class
model translated 24 of 24 lines of a 150-second sample with the last line 12 seconds late, which is
usable in real time but misses some proper nouns and interjections. Cloud models translate faster and
better; see the [verification history](development/verification-history.md) for the measurements.

If the server is not running, every translation fails, but nothing disappears: lines that failed are
still shown as their original text, and a status chip tells you the server cannot be reached.

### 2. Speech models and the component manager

Speech recognition needs the Whisper model for the language plus the Silero VAD file. If you skipped
the downloads during setup, open **Ctrl+N → AI component manager**:

- Download all models or one at a time. Selecting a Whisper model also fetches the VAD file.
- Progress, integrity checking, errors and **Cancel** are shown. Closing the menu does not stop a
  download.
- Without models, or with AI turned off, playback starts immediately without waiting for subtitles. After
  a download finishes, the next file you open uses speech recognition. No restart is needed.
- Custom model paths and models found in an existing app folder are never overwritten.

English audio uses the English model; every other language uses the multilingual model (or
large-v3-turbo when installed). Audio without a language tag (common for web video) starts with
automatic multilingual language detection.

### 3. Acceleration

**Ctrl+N → AI component manager** (or the **AI acceleration mode** entry) selects the mode:

| Mode | Behavior |
|---|---|
| Automatic | CUDA when it can be used, otherwise CPU. |
| CPU | CPU only. |
| CUDA required | Use CUDA for speech recognition or report why it cannot; playback continues without AI subtitles. |

The CUDA engine (`nanum_ai_cuda.dll`, about 53 MiB) is included in the app and verified by size and
SHA-256 before it loads. It needs an NVIDIA GPU of compute capability 8.6 or newer, a compatible driver,
and cuBLAS from a **CUDA 13 Toolkit** (CUDA 12 is not enough). The Toolkit is read in place: it is found
through `CUDA_PATH`/`CUDA_PATH_V13_*`, the registry environment and
`%ProgramFiles%\NVIDIA GPU Computing Toolkit\CUDA\v13.*` (newest first). With a Toolkit and a compatible
GPU, Automatic mode uses the GPU from the first file, with no extra download or prompt. Without a Toolkit
you can download cuBLAS alone (about 507 MiB, NVIDIA's terms apply) into
`%LOCALAPPDATA%\NanumPlayer\accelerators\cuda\13`; it survives app updates and uninstalling.

Missing CUDA never disables CPU speech recognition or translation. Text-subtitle translation needs no
speech model and no CUDA at all; "CUDA required" applies to speech recognition only. Changes of mode or
downloads apply from the next file you open.

## Play something

| Action | How |
|---|---|
| Open a file | **Ctrl+O**, or drag the file into the window. |
| Open a Blu-ray or DVD | **Ctrl+D**, or `NanumPlayer.exe bd://longest --bluray-device=E:` / `dvd:// --dvd-device=E:` ([discs](#discs)). |
| YouTube | **Ctrl+Y** or **Play from a YouTube address…** ([YouTube and web pages](#youtube-and-web-pages)). |
| A video on any web page | **Ctrl+Shift+Y** or the **Play from a web page** button. |

Click the video to pause; double-click toggles full screen (**F** too). The playback bar hides itself
1.2 seconds after the mouse stops (**Ctrl+N → Playback bar auto-hide** offers short, normal and long),
and hides at once when the cursor leaves the window; it stays while paused or while the cursor is on it.
The start screen and the playback bar show the app version.

### Wait at the start, not after seeks

When you open a file, NanumPlayer waits until subtitles are ready for the first 30 seconds (the
*preroll*), then starts. After that, seeking on the timeline or with the arrow keys does not wait for
AI subtitles and keeps your play or pause state; subtitles for a span that is not yet processed can
arrive a little late. **Ctrl+K** shows how far ahead the subtitles are.

Read-ahead is what gives subtitles their lead: speech is recognized from audio the player has already
buffered. See the [reference](reference.md#read-ahead) for the settings.

### Status tag

Above the playback bar, a tag shows how the selected AI subtitle track is made: speech recognition on the
GPU or CPU, the source model or origin (for example `small.en`, `large-v3-turbo`, subtitle-based, disc
subtitle OCR), and the translation model with *local GPU*, *local GPU partly*, *local CPU* or *cloud*.
Click it to jump to the relevant setting. **Ctrl+N → Show AI info tags** turns it off.

## Subtitles

Open the list with the **Subtitles** button of the playback bar or from **Ctrl+N** (the *Subtitle* entry).
(**Ctrl+T** opens the plain list of the file's own tracks.)

### The subtitle list

One list holds every subtitle with a badge for its source:

| Badge | Meaning |
|---|---|
| `[AI]` | Made by NanumPlayer in the target language. The display mode applies to these entries. |
| `[Original]` | A subtitle that came with the disc, the file or the YouTube uploader, shown as it is. |
| `[File]` | A subtitle file with the video's name next to it (`name.srt`, `name.ko.srt`) or one you loaded yourself. |
| `[OCR]` | A disc image subtitle read by text recognition. |

- **Display mode** of the AI entries: *Translation only* (default), *Translation + original*,
  *Original only*. Changing it never reruns recognition or translation. A line that could not be
  translated is shown as its original text even in *Translation only* so the screen does not go blank.
- If the media has an original subtitle in your **target language** (not forced, commentary or
  auto-generated YouTube captions), NanumPlayer selects it automatically and skips the AI work for that
  file. Turn this off with **Show an original subtitle in the target language directly**. Choosing an AI
  entry restarts the AI work from the current position.
- When you choose an `[Original]` or `[File]` subtitle yourself, the AI work (speech recognition, OCR,
  original-language audio) pauses regardless of language, and resumes when you choose an AI entry again.
- During disc playback, choosing an embedded subtitle re-reads from the current position so it appears
  at once.
- For YouTube, `yt-dlp` is asked for the uploader's subtitles (auto-generated ones are not requested)
  in the target language and in English.

### Target language

**Ctrl+N → Translation target language** offers 33 languages or a name you type (any language name the
model understands, for example *Italian*). The default is your Windows display language. If the
recognized language equals the target, nothing is translated and the original is shown. A change applies
from the next file you open; the translation style and glossary apply immediately.

### Two audio inputs: playing audio and AI input audio

The audio you hear and the audio the AI reads are separate. When you switch to a different audio
language, NanumPlayer asks whether to **keep the existing AI input** (default), **generate from the new
audio**, or **look up saved subtitles for the new audio**. Dubbed and original audio differ in wording
and timing, so subtitles made from one may not fit the other.

For a film with several audio languages (for example a Blu-ray with English and Japanese audio),
NanumPlayer makes subtitles from the playing audio first. Then, at lower priority and from the same
read (no extra disc access), it makes subtitles from the original-language audio. They appear as two
tracks, for example "Korean (based on English audio)" and "Korean (based on Japanese audio)". The
original language is found by asking the translation model with the work's title (disc name, title tag
or file name) and the audio languages; if that fails and there are exactly two audio languages, the one
you are not playing is used. The second input works only while the first one is at least 30 seconds
ahead of playback, or idle. Turn it off with
**Ctrl+N → Also make subtitles from the original-language audio**. *Translation + original* shows each
track's own original text. Enabling it in the middle of playback skips the span already read ahead
(about two minutes); seeking later re-reads and analyses it.

### Text subtitles as the source

An AI subtitle's source is either speech recognition or a **text subtitle track** (SRT, ASS, mov_text,
WebVTT; embedded or external). Image subtitles (PGS and similar) are handled separately (see OCR below).
NanumPlayer chooses automatically:

- If the audio language is L and a text subtitle in L exists, it is used; otherwise speech recognition
  is. (A Japanese film with only English subtitles is recognized as Japanese speech.)
- If L is unknown, it looks for a text subtitle in English, then Japanese, Spanish, French, otherwise
  uses speech recognition. Forced and commentary tracks are ignored.
- **Ctrl+N → Input source** switches among Automatic, speech recognition and a specific subtitle track;
  it restarts from the current position. For an external file, the language comes from the file name
  suffix (`movie.en.srt`) when mpv does not know it.

### Importing subtitles

**Ctrl+N → Import a subtitle file…** (or dragging a file onto the window) loads `.srt`, `.ass`, `.ssa`,
`.vtt`, `.sub` or a `.zip` that contains one. Choose between:

- **Show as it is.** The file is used unchanged as an `[File]` subtitle.
- **Align timing with AI and translate.** NanumPlayer detects the encoding (UTF-8, UTF-16, CP949,
  Shift-JIS, CP1252) and the language, compares the cue times with the start of the speech-recognized
  subtitles, and corrects the offset (up to ±240 s) and the frame-rate ratio (23.976/24/25 fps
  conversions). If the confidence is low it does not shift anything and tells you; correct manually
  with the ±0.1 s and ±1 s adjustment entries. A Korean subtitle is kept as it is; other languages
  are translated with the style and glossary below.

A newly imported subtitle replaces the previously imported one. Working copies are deleted on exit;
the file you downloaded is never deleted. A subtitle file next to the video with the same name is loaded
automatically.

### Online subtitle search

**Ctrl+N → Find online subtitles (OpenSubtitles · Jimaku)** opens a search page in your browser for the
work's title. OpenSubtitles covers English, Japanese and Korean; Jimaku is for Japanese anime (it has no
address search, so the home page opens and the search text is copied to the clipboard). NanumPlayer never
automates the site. You download a subtitle yourself; for 20 minutes NanumPlayer watches your download
folder (changeable in the menu, default the Windows Downloads folder) for `.srt`, `.ass`, `.ssa`,
`.vtt`, `.sub` or `.zip` files and imports the new one. The import is time-aligned and translated as
above. Sites differ in cuts and edits, so automatic alignment may report low confidence.

### Image subtitles (PGS) with OCR

For a disc with image subtitles, NanumPlayer decodes the subtitle packets from the same demuxer (no
extra disc read), enlarges small text and reads it with **Windows OCR** (no model is bundled), then
translates it. The track is called, for example, "Korean (based on English disc subtitles)" and carries
the `[OCR]` badge. The English non-forced track is preferred. If the English OCR language pack is
missing, an installed Latin-script recognizer (for example Korean Windows' `ko`) is used and common
misreadings are corrected (`50`→`So`, `donlt`→`don't` ...). Install the English pack from
**Ctrl+N → Install the English OCR language pack (administrator)** for better accuracy; Japanese tracks
need the Japanese pack. The result is kept for the current playback only. Turn this off with
`nanum-pgs` (see the [reference](reference.md)).

### Glossary and translation style

NanumPlayer asks the translation model to identify the work from its title (disc name, title tag or file
name) and builds a glossary of characters (family, given and full names), places, organizations and
terms, each with one target-language spelling. The glossary is added to live translation (the entries
that occur in the line plus the main characters) and to full translation (the whole glossary).

**Ctrl+N → Glossary** shows the list and lets you add, change and delete entries, edit all of it in
Notepad, or rebuild it with AI. Changing one name offers to change the same person's family, given and
full names together. After a change, every existing subtitle containing the name (both tracks, saved
copies, full translation) is re-translated at once.

Quality depends on the model. A small local model may invent entries for characters it does not know;
look the list over and fix what is wrong. When you edit the glossary, NanumPlayer saves it as text files named
after the work in `%APPDATA%\NanumPlayer\glossary` (see [Privacy](privacy.md#where-data-lives)).

**Ctrl+N → Translation style**: *Natural* (default; keeps formal or casual speech consistent with the
characters' relationships), *Polite*, *Casual*, *Faithful to the original*, or *Custom* with your own
instruction. A change applies to everything translated from then on; caches are kept per style and
glossary.

### Whole-file ("full") translation

With **Full translation** on, a separate reader collects the whole source transcript, translates it in
60-line windows (5 lines overlapping) using the glossary, and writes an `.ass` file to a temporary folder;
the track is selected when finished. The engine is Ollama (default, the same server and model as live
translation) or **omp** (oh-my-pi, using a model you are already signed in to; the menu lists
`omp models --json`). Live translation always uses Ollama because omp takes seconds per call.

On an **optical disc** the whole-file reader is a second read position, so the playback and the scan can
slow each other. The scan starts 10 seconds in and never runs more than 90 seconds ahead of the engine.
On local files this is not a problem.

### Saved subtitles

By default, subtitles are held for the current playback and made again next time. Only if you pass
`--nanum-library-db=<path>` does NanumPlayer keep a per-film library (source transcript and times,
translations, model, target language, job state) in a SQLite file, so reopening is instant and you can
**re-translate from saved source text**. Files are identified by size plus a SHA-256 content fingerprint
(whole file up to 16 MiB; the two ends of 4 MiB and sixteen 256 KiB samples for larger files, so a change
outside the samples may go unnoticed); a moved file is recognized, a file with the same path alone is
not. Blu-ray discs are identified by libbluray's disc ID, volume, title or playlist, clips and tracks,
never by drive letter alone. Web media is never stored in the library. See [Privacy](privacy.md).

## Generate subtitle files without playing

**Ctrl+N → Generate full subtitles…** (window "Create subtitle files") makes subtitle files for a local
video or a Blu-ray title **without playing it**. A separate demuxer reads only the stream it needs at full
speed (no picture or sound output) and does not disturb a video you are watching. Choose the source:

- **Speech recognition** of an audio track (CPU or CUDA engine).
- A **text subtitle track**, or an external subtitle file.
- **OCR of an image subtitle track** (PGS or DVD), using Windows OCR.

The source-language SRT is saved first; then one translated SRT for each language you choose, with your
server, model, style and glossary. A language the source already has is not translated again. Progress and
elapsed time appear in the menu and in notifications; **Cancel** keeps files already written. Files are
named `<video name>.<language>.srt` next to the video (for discs
`%USERPROFILE%\Videos\NanumPlayer`, or a folder you choose). An existing name is never overwritten: `.2`,
`.3` is added. Each file is written as `.part` and renamed, so a stopped job never leaves a half-written
file. Use **First 10 minutes only (preview)** to check the OCR pack and translation quality first. Nothing is
written unless you start it, and nothing is remembered afterwards.

OCR of disc image subtitles reads the whole title, so it is as slow as your optical drive. Web videos are
not supported by this feature; use the AI subtitles while playing. For scripting, see the
[reference](reference.md#generate-subtitle-files).

## Video quality

### GPU upscaling

The **Picture** button on the playback bar (also **Ctrl+I**, or **Ctrl+N → Picture quality**) opens one menu
for upscaling and picture correction; it stays open so you can see each change. The button shows a blue dot
while an upscale method or a correction is on, and a yellow one after an error. The upscale choices are
under **Upscale**, and **Details…** has the per-control levels and the user shader list. Upscaling is
independent of CUDA speech recognition and needs no CUDA Toolkit.

- **Default**: no extra processing; restores renderer and scaler settings this feature changed. Your
  own filters and shaders are kept.
- **High-quality scaling**: `ewa_lanczossharp` with antiring 0.6 on a GPU renderer. Not an AI method.
- **NVIDIA RTX upscaling**: uses `gpu-next`, D3D11, D3D11VA and the NVIDIA extension of `d3d11vpp`. Needs
  a supported NVIDIA GPU and driver with RTX Video Super Resolution enabled in the NVIDIA app or control
  panel. The status "requested" means the filter was requested; it does not prove the driver is doing AI
  processing.
- **User shaders**: add mpv-compatible `.glsl`, `.hook` or `.frag` files one by one; select an entry to
  reorder or remove it. Shader packs such as Anime4K or FSRCNNX are not bundled. They are applied after
  existing shaders, in the order you choose.

RTX scale is **Auto / 1.5x / 2x / 3x**. Auto is computed from the source and window sizes, rounded up in
0.25 steps and capped at 4x, and removes the filter when no enlargement is needed; window resizes apply
after a short pause. A fixed 2x doubles width and height (1080p → 4K); do not apply a fixed factor to a
source that is already 4K or larger than the window.

The choice applies during playback and is saved in `~~/script-opts/nanum-upscale.conf` (by default
`%APPDATA%\NanumPlayer\script-opts`). Changing the renderer can briefly recreate the window contents.
An unsupported GPU or a shader compile error is shown in the status and the processing this feature
added is removed. RTX HDR conversion is not enabled; HDR and 10-bit support depends on the driver and
video path. Speech recognition, a local translation model and upscaling compete for the same GPU and
can increase dropped frames: lower the factor or compare with high-quality scaling.

### Built-in picture quality

The **Correction** section of the same menu (**Picture** button, **Ctrl+I**). Presets: **Original** (default, no correction), **Sharper anime**,
**Smoother old anime**, **Compressed video repair**. It uses no AI model and no download, only nine
original lightweight GPU shaders (about 12.3 KiB in total) and mpv's built-in features, independent of
any external Anime4K pack.

| Control | What it does |
|---|---|
| Noise reduction | Edge-preserving spatial filter that removes small noise in flat areas. Strong settings can erase background texture. |
| Debanding | Reduces gradient steps. |
| Line enhancement / Sharpening | Slightly darkens dark lines, or sharpens within the range of surrounding pixels. It does not redraw lines with AI. |
| Color correction | A mild increase of the existing saturation and contrast. It does not estimate original colors. |

Each control is **Off / Weak / Medium / Strong**; individual changes are saved as a custom combination.
**Compare before correction** temporarily turns off only these corrections; upscaling and your own
filters stay, and the comparison state is not saved. Selecting **Original** turns the corrections off and
saves that choice.

In RTX mode, line enhancement and sharpening **pause** to avoid sharpening twice, and return to their
selected strengths when you leave RTX. Noise reduction, debanding and color correction can run together.
The player cannot tell what a custom shader does, so avoid doubling up on sharpening.

This needs a `gpu-next` or `gpu` output and is saved in `~~/script-opts/nanum-picture.conf`, keeping
other filters and settings made elsewhere. Unsupported output and shader errors are reported in the
menu. These are real-time spatial filters: no temporal flicker removal, AI recoloring or restyling of
animation. With HDR or high-resolution video and concurrent AI subtitles, compare the result and the
playback load with the original.

## Discs

NanumPlayer plays Blu-ray and DVD in the player process itself. Unencrypted discs and disc folders
(`BDMV`) work without anything extra. For discs with copy protection, see
[disc components](disc-components.md): the decryption libraries are an optional separate installation.

- **Open:** **Ctrl+D** or the start-screen card; or `NanumPlayer.exe bd://longest --bluray-device=E:`,
  `NanumPlayer.exe dvd:// --dvd-device=E:`. You can also drag a Blu-ray folder onto the window.
- **Read-ahead for subtitles:** for AI subtitles on a disc use `--demuxer-readahead-secs=120
  --demuxer-max-bytes=1500MiB`; a Blu-ray mux of up to 48 Mbit/s makes 120 s about 720 MB.
- **Save to MKV:** **Ctrl+B → drive → title / all titles** writes lossless MKV files into
  `%USERPROFILE%\Videos\NanumPlayer`. Titles of at least 2 minutes are listed; the default angle's video,
  audio, subtitles and chapters are copied without re-encoding. **Ctrl+C** cancels the running save or
  search and removes only the unfinished file. An existing name is never overwritten: a number is added.
  For DVD, missing video timestamps are regenerated with FFmpeg and a command that moves on to the next
  title is cut at the real title boundary.
- **Diagnostics:** the detailed disc log is off by default; see [Troubleshooting](troubleshooting.md#disc-read-and-seek-diagnostics).

## YouTube and web pages

### YouTube

Press **Ctrl+Y** (or the start-screen **YouTube** button). A built-in browser window (WebView2,
`nanum_youtube.exe`) opens: pick a video and sign in as usual. NanumPlayer then plays it through `yt-dlp`
(with Deno; both optional downloads that are checked by SHA-256 and checked for updates) using that
window's cookies, and offers the same AI subtitles, glossary, style and so on. If the video has
uploader subtitles they are used as the source according to the input-source rules (switch to speech
recognition in the menu). You can also paste an address (**Ctrl+N → Play from a YouTube address…**) or add
a browser bookmark "Open with NanumPlayer" using the `nanumplayer://open?url=` scheme. Using your account
with an unofficial tool can make YouTube ask for extra checks or limit the account.

### Any web page

1. Choose **Play from a web page** on the start screen, press **Ctrl+Shift+Y**, or choose
   **Ctrl+N → Play from a web page video address…**, and paste the page's address.
2. In the built-in browser window, sign in if needed and **start the video on the site**.
3. Click **Play in NanumPlayer** at the top. The video and sound play in NanumPlayer with your usual AI
   subtitle settings (speech model and translation server as for any file).

The helper detects media loaded in iframes and observed HLS/DASH manifests; that video's cookies,
Referer and User-Agent are applied only to that file. DRM-protected video, pages that do not expose a
playable media or manifest URL, and servers that refuse playback outside the browser do not work. If the
address expires, reload the page. Nothing guarantees that every site works.

Both windows share an **InPrivate session**: sign-in lasts only for that session, browser
data is removed at the end, and **Ctrl+N → YouTube → End web session (sign out)** ends it
right away. See [Privacy](privacy.md#web-sessions) for what is and is not protected.

## Interface language and shortcuts

The interface follows the Windows display language on first run (or the language chosen in setup) and
falls back to English for unsupported languages. Change it with the language button at the top right of
the start screen, **Ctrl+Alt+L**, or **Ctrl+N → Interface language**. **Automatic** follows Windows
again. The choice is stored in `ui-language.conf` in the settings folder. `--nanum-ui-language=es` (also
`auto`, `ko`, `en`, `ja`, `zh-CN`, `zh-TW`) overrides it for that run only. Button labels of a running
browser window change at once; WebView2's own menus use the new language from the next browser session.
The interface language is independent of the speech and subtitle languages.

| Keys | Action |
|---|---|
| Ctrl+N | AI subtitle settings (the main menu) |
| Ctrl+K | AI subtitle status |
| Ctrl+O | Open file |
| Ctrl+D | Open Blu-ray drive or folder |
| Ctrl+A | Audio track panel |
| Ctrl+T | Plain subtitle track list |
| Ctrl+I | Picture quality (upscale and correction) |
| Ctrl+B | Save a Blu-ray or DVD title to MKV (Ctrl+C cancels) |
| Ctrl+Y | YouTube |
| Ctrl+Shift+Y | Play from a web page |
| Ctrl+Alt+L | Interface language |
| Space / F | Play-pause / full screen |
