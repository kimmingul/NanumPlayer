# Troubleshooting and known limitations

English · [한국어](ko/troubleshooting.md)

Press **Ctrl+K** during playback to see the state of AI subtitles (how far ahead they are, input source,
errors). Most messages also tell you which **Ctrl+N** entry to open.

## Common problems

### The installer or the program is flagged by Windows

Release files are code-signed and timestamped (publisher *Nanum Space Co,. Ltd*), but SmartScreen also
looks at how often a file has been downloaded, so a new release can still show "Windows protected your PC".
Compare the file's SHA-256 with `SHA256SUMS-<version>.txt` from the same release page
(`Get-FileHash <file> -Algorithm SHA256`), then choose **More info → Run anyway**. Third-party DLLs in the
package keep their own signature state.

### No AI subtitles appear

Check in this order:

1. **Translation server.** Is Ollama running (`ollama serve`)? **Ctrl+N → Translation model** lists its
   models; if the list cannot be fetched, the server is unreachable or the address is wrong. When the
   server is down every translation fails with a `transport error`, the preroll waits until its time-out
   (90 seconds), and lines that were not translated are shown as original text with a status chip that
   says the server cannot be reached. Start the server before opening the video.
2. **Speech models.** For speech recognition you need the Whisper model for the language and the VAD file
   (**Ctrl+N → AI component manager**). Without them playback starts normally and says what is missing. A
   download finishing takes effect from the next file you open.
3. **A subtitle already exists in your target language.** The player then shows it and skips the AI work
   on purpose. Choose an `[AI]` entry in the subtitle list to start it.
4. **You chose an `[Original]` or `[File]` subtitle.** The AI work is paused until you pick an AI entry.
5. **The input source.** Ctrl+N → Input source: *Automatic* prefers a text subtitle in the audio's language;
   image subtitles (PGS) are only used through OCR.

### Subtitles arrive late

Subtitles are as early as the read-ahead allows. The default read-ahead is 1 second, which makes
subtitles arrive after the dialogue. Raise `--demuxer-readahead-secs` (and `--demuxer-max-bytes` with it);
see [the reference](reference.md#read-ahead). A mux of 48 Mbit/s makes 120 s about 720 MB. A span that has
not been processed yet after a seek can show subtitles late; they appear when processing catches up.

### The model is too slow or translations time out

The default name `gemma4:latest` is 12.8 GB. On an 8 GB GPU it runs only partly on the GPU, and together
with speech recognition and the renderer it can time out. Choose a smaller local model or an Ollama cloud
model in **Ctrl+N → Translation model**. The model's quality matters most for proper nouns: small local
models can leave names and interjections untranslated or invent glossary entries, so check the
**Glossary** list.

### CUDA is not used

- The CUDA engine needs an NVIDIA GPU of compute capability 8.6+, a current driver and **CUDA 13** cuBLAS.
  CUDA 12 alone is not enough. Install the CUDA 13 Toolkit, or download cuBLAS in the AI component manager.
- A message says the driver was not found: install the NVIDIA driver.
- In *CUDA required* mode a missing or incompatible CUDA is reported and playback continues without AI
  subtitles; switch to *Automatic* or *CPU*.
- Mode changes and downloads apply from the next file you open.
- The tag above the playback bar shows `CPU ⚠` when the GPU could be used but the CPU is working.

### OCR of disc subtitles is poor

Reading English image subtitles with only the Korean recognizer leaves some misreadings even after
corrections (for example the word `cold` can come out as digits followed by a Korean character). Install the English OCR language pack
(**Ctrl+N → Install the English OCR language pack (administrator)**), which needs administrator rights.
Japanese tracks need the Japanese pack. Subtitles downloaded from sites can differ in cuts and edits from
your disc, so the automatic timing alignment can report low confidence; adjust manually with the ±0.1 s
and ±1 s entries.

### YouTube

- The YouTube tools (`yt-dlp`, Deno) are an optional download: **Ctrl+N → YouTube**.
- YouTube may ask whether you are a robot, or require sign-in for age-restricted, members-only or
  private videos. Sign in in the YouTube window and try again.
- Using your account with an unofficial tool can make YouTube add checks or limit the account.

### Web-page videos do not play

DRM-protected video, pages that never load a playable media or manifest address, and servers that
block playback outside the browser are unsupported. If the address expired, reload the page in the
window and press **Play in NanumPlayer** again. If the browser window does not open, the WebView2
Runtime is missing: install it from Microsoft and try again.

### Discs

- Encrypted discs need the [optional disc component](disc-components.md). Without it NanumPlayer says
  so and offers to install it.
- A Blu-ray that needs keys can still fail when the public key database has no entry for it, the BD+
  virtual-machine data is unavailable, the AACS version or drive authentication is unsupported. Those
  failures are reported, not hidden. There is no claim of equivalent support to other tools for every BD+
  or UHD disc.
- On an optical disc, whole-file translation and OCR read from a second position and slow each other and
  playback. Use local files for those.

## Disc read and seek diagnostics

The normal playback log is not saved. An explicit `--log-file` uses mpv's standard log policy and may
contain addresses and file names, so do not use it for private viewing.

Switch the detailed disc log on with **Ctrl+N → Diagnostic log (detailed disc reads)**, the IPC command
`nanum-diagnostics on|off|toggle`, or the environment variable `NANUMPLAYER_DIAGNOSTICS=1` at start.
Logs are written to `%APPDATA%\NanumPlayer\diagnostics\disc-<date>-<time>-<pid>.log`, at most 8 MiB per
file, keeping the newest 8.

A log records seek requests, the actual landing position and first data arrival, read offsets, lengths
and durations, the error code of a failing Windows `ReadFile`, and the drive's model, firmware and
connection type. After a failure it collects the related Windows storage events. It does not record keys,
media content or drive serial numbers. It distinguishes a successful file read followed by a failed
decryption from a real operating-system read failure. SCSI sense data is not available at this file-I/O
layer, so no error code is invented for it.

## Known limitations

- On the verified disc, Windows CRC read errors and `cdrom` event 7 were observed after the middle of the
  disc even with AI turned off. That is real I/O delay, separate from AI readiness. A single cause among
  disc, drive and connection path has not been isolated, and decryption failures occurred as well.
- Turning **Also make subtitles from the original-language audio** on during playback skips the span
  already read ahead (about two minutes); the skipped span is analyzed when you seek back to it.
- The multilingual `small` Whisper model recognizes Japanese poorly. The optional large-v3-turbo model
  improves it a lot, but it uses more GPU memory and can slow a local translation model on an 8 GB GPU.
- The preroll is handled only when a file is first opened (default 30 seconds). Seeks on the timeline or
  with the arrow keys do not wait and keep the play or pause state. Subtitles for spans that have not
  been processed can arrive late.
- Long utterances (up to 15 seconds) are split at sentence ends with times shared by character count.
- A crash with `0xC0000005` at exit was seen once in a 150-second real-disc measurement and did not
  reproduce in later repeated checks; the cause is unconfirmed. Crash dumps are off by default for
  privacy; set `NANUMPLAYER_CRASH_DUMP_DIR` to a folder only when you need diagnostics, and treat dumps as
  sensitive since they contain process memory.
- Settings that are not in the **Ctrl+N** menu (model paths and other engine options) go in `mpv.conf`.
  The translation model, server and target language apply from the next file you open; style, original-
  language subtitles and glossary apply at once.
- RTX upscaling status "requested" is not proof that the driver is processing the video.
- Windows only (x64). Other platforms are not built.

## Getting help

If something is not covered here, [open an issue](https://github.com/kimmingul/NanumPlayer/issues/new/choose)
and include the version (shown on the start screen and in **Ctrl+K**), your Windows version, GPU, the
translation model, and what **Ctrl+K** says. Do not attach logs that contain addresses you want to keep
private.

## Security problems and privacy questions

Do not report a security problem in a public issue. Use [private vulnerability reporting](https://github.com/kimmingul/NanumPlayer/security/advisories/new)
or e-mail [mgkim@nanumspace.com](mailto:mgkim@nanumspace.com) with the subject "NanumPlayer security". See [SECURITY.md](../SECURITY.md).
