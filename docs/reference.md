# Reference: options, properties and commands

English · [한국어](ko/reference.md)

NanumPlayer is mpv with additions, so every mpv option, command and property works too. This page lists
the NanumPlayer-specific ones. Precedence of settings: defaults < user settings (`%APPDATA%\NanumPlayer`)
< command line.

Contents: [Options](#options---nanum-) · [Read-ahead](#read-ahead) · [Whole-file translation](#whole-file-translation-options) ·
[Original-language audio, glossary, style](#original-language-audio-glossary-and-style) ·
[Display, audio input, library](#display-input-audio-and-saved-subtitles) · [Import and OCR](#import-and-ocr) ·
[Generate subtitle files](#generate-subtitle-files) · [Diagnostics](#diagnostics-and-environment-variables)

## Options (`--nanum-*`)

| Option | Default | Description |
|---|---|---|
| `nanum` | yes (app default) | Turn the features on. `no` plays normally only. |
| `nanum-stt-model`, `nanum-vad-model` | app/user model path | Speech recognition needs the Whisper model for the selected language **and** the VAD model. |
| `nanum-ai-dll` | empty (managed automatically) | An explicit user engine path; it must satisfy the current backend contract (`NANUM_AI_ABI_VERSION`). |
| `nanum-acceleration` | `auto` | `auto`, `cpu` or `cuda` (required). Applies from the next file. |
| `nanum-language` | `auto` (app default) | Input language. English uses the English model, anything else the multilingual one. |
| `nanum-translate-endpoint` | `http://127.0.0.1:11434` | Ollama-compatible `/api/generate`. Empty turns translation off. |
| `nanum-translate-model` | `gemma4:latest` | Translation model. |
| `nanum-target-language` | Windows display language (for example `Korean`) | Target language: 33 languages from **Ctrl+N → Translation target language**, or a name you type. If it equals the source language, nothing is translated. |
| `nanum-cache` | – (not stored) | An explicit translation cache (JSONL) for local media. Never used for web media. |
| `nanum-test-subs` | no | Fixed test subtitles (development). |
| `nanum-ui-language` | `auto` | `auto`, `ko`, `en`, `ja`, `zh-CN`, `zh-TW`, `es`. Overrides the saved choice for this run only. |
| `nanum-library-db` | – (off) | Enables the persistent per-film library at this path for local media. |
| `nanum-pgs` | yes | Image-subtitle OCR. `no` turns it off. |
| `nanum-secondary` | yes | Also make subtitles from the original-language audio. |

## Read-ahead

The demuxer read-ahead (`demuxer-readahead-secs`) is the subtitle lead time. With the default (1 second)
subtitles arrive after the picture. For discs use for example:

```
--demuxer-readahead-secs=120 --demuxer-max-bytes=1500MiB
```

A Blu-ray mux of at most 48 Mbit/s makes 120 s about 720 MB, so raise `demuxer-max-bytes` as well.

Example command line for a Blu-ray in `E:` (the optional disc component must be installed if the disc is
encrypted):

```bat
NanumPlayer.exe bd://longest --bluray-device=E: --nanum ^
  --nanum-acceleration=auto ^
  --nanum-stt-model=D:\models\ggml-small.en.bin ^
  --nanum-vad-model=D:\models\ggml-silero-v5.1.2.bin ^
  --nanum-translate-model=<your model> ^
  --demuxer-readahead-secs=120 --demuxer-max-bytes=1500MiB --slang=kor
```

Required model files: `ggml-small.en.bin` (English Whisper), `ggml-small.bin` (multilingual, selected by
`--nanum-stt-model-multilingual`), `ggml-silero-v5.1.2.bin` (VAD). Packaged builds look in
`%LOCALAPPDATA%\NanumPlayer\models` by default.

## Whole-file translation options

These can be changed at run time.

| Option | Default | Description |
|---|---|---|
| `nanum-input` | `stt` | `stt` or `sub`. |
| `nanum-sub-id`, `nanum-sub-file` | – | For `sub` input: the track (`src-id` in `track-list`) or an external subtitle file. |
| `nanum-full` | no | Turn full translation on. |
| `nanum-full-dir` | session temporary folder | Explicitly choose where the result `.ass` of local media is saved. Web media always uses the temporary folder. |
| `nanum-full-engine` | `ollama` | `ollama` or `omp`. |
| `nanum-omp-model`, `nanum-omp-command` | –, `omp` | The omp model selector and executable. |

State properties (inside `demuxer-cache-state`): `nanum-full-state` (`off/scanning/translating/done/error`),
`nanum-full-progress`, `nanum-full-file`, `nanum-full-error`, `nanum-input-active`. **Ctrl+K** shows them too.

## Original-language audio, glossary and style

| Option | Description |
|---|---|
| `nanum-secondary` | Make a second subtitle track from the original-language audio (default yes). |
| `nanum-translate-style` | `natural` (default), `polite`, `casual`, `literal` (Faithful to the original) or `custom` (your text in `nanum-translate-style-text`). Applies to later translations; caches are kept per style and glossary. |

Properties: `nanum-track-primary` and `nanum-track-secondary` (the virtual track `src-id`),
`nanum-secondary-state`, `-language`, `-ready-until`, `-reason`, `nanum-original-language`,
`nanum-profile-state`, `nanum-profile-work`, `nanum-glossary`, `nanum-glossary-count`,
`nanum-glossary-apply-state`, `-progress`, `-changed`, `-error`, all in `demuxer-cache-state`. Request a
glossary change with `nanum-glossary-request=regenerate` or `nanum-glossary-request=file:<path>`.

## Display, input audio and saved subtitles

Run-time options: `nanum-display=translation|bilingual|source`, `nanum-audio-id=<input track src-id>`,
`nanum-library-action=ask|use|retranslate|regenerate|disable`, `nanum-library-auto-use=yes|no`. The
`nanum-library-*` fields of `demuxer-cache-state` report whether a saved copy exists, its input language
and errors.

## Import and OCR

Properties: `nanum-track-pgs`, `nanum-pgs-state`, `-language`, `-reason`, `-ready-until`,
`nanum-track-import`, `nanum-import-state`, `-progress`, `-error`, `-note`, `-offset`, `-scale`,
`-confidence`, `-low-confidence`, `-language`, `-origin`, `-lines`.

Requests: `nanum-import-sub=<path>|<language>|<origin>` and `nanum-import-adjust=<seconds>`.

## Generate subtitle files

- Command: `nanum-generate <JSON>` (abortable). The request and result shapes are defined in
  `third_party/mpv/osdep/nanum-generate.h`.
- Property `user-data/nanum/generate`: `status`, `progress`, `position`, `duration`, `target`,
  `outputs[]`, `error` and more.
- Script messages: `nanum-generate-start <json>`, `nanum-generate-cancel`, `nanum-generate-open`;
  script binding `nanum/nanum-generate`.
- The disc save has the script message `nanum-rip` and the property `user-data/nanum/rip`.

## Diagnostics and environment variables

| Name | Effect |
|---|---|
| `nanum-diagnostics on\|off\|toggle` (IPC command) | Detailed disc-read log, see [Troubleshooting](troubleshooting.md#disc-read-and-seek-diagnostics). |
| `NANUMPLAYER_DIAGNOSTICS=1` | Same, from the start. |
| `NANUMPLAYER_CRASH_DUMP_DIR` | Enable crash dumps in that folder. Dumps can contain secrets. |
| `NANUM_AI_DEBUG=1` | VAD, speech recognition and translation logs. |
| `NANUM_AI_VAD_THRESHOLD` | VAD threshold (default 0.25). |
| `user-data/nanum/app-version` | The application version property. |

Run-time settings of the **Ctrl+N** menu are saved in `~~/script-opts/nanum.conf`; engine options such as
model paths belong in `mpv.conf`.
