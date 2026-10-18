# Building NanumPlayer from source

English · [한국어](ko/building.md)

NanumPlayer is built on Windows x64 only. It is a modified mpv built directly as `NanumPlayer.exe`;
there is no launcher and no `mpv.exe` child process.

## Architecture

```
Blu-ray / file ─▶ mpv demuxer (read-ahead of N seconds)
                    ├─▶ normal playback path
                    └─▶ nanum tap: audio packets are copied (only a copy is made under the lock)
                           │ separate thread: libavcodec decode → 16 kHz mono (centre channel weighted)
                           ▼
                      nanum_ai_cpu.dll / nanum_ai_cuda.dll (bundled, MSVC, common C ABI)
                        Silero VAD → whisper.cpp (speech recognition) → translation (Ollama API, batched) → memory cache
                           │ absolute-PTS events (arrive ahead of playback by the read-ahead span)
                           ▼
                      demux.c: injected into virtual ASS streams (playing-audio based, original-audio based) → libass renders
```

mpv is built with MSYS2 CLANG64 (clang/meson) and the AI engine with MSVC. Because the toolchains
differ, mpv loads the engine DLL at run time with `LoadLibrary`; the contract is
`third_party/mpv/nanum/nanum_ai_api.h` ↔ `nanum_ai/nanum_ai.h`, checked with `NANUM_AI_ABI_VERSION`.

## Repository layout

| Path | Contents |
|---|---|
| `third_party/mpv` | Submodule: [kimmingul/mpv](https://github.com/kimmingul/mpv), branch `nanum` (mpv plus NanumPlayer patches in `nanum/`, `osdep/nanum-*`, `demux/`, `player/`, `stream/`). |
| `third_party/whisper.cpp` | Submodule: [kimmingul/whisper.cpp](https://github.com/kimmingul/whisper.cpp), branch `nanum` (speech engine, statically linked; with a patch that lets the CPU computation be aborted). |
| `nanum_ai/` | CPU/CUDA engine sources: `nanum_ai.h` (C ABI), speech and VAD workers, `translator.*`, test harness. |
| `scripts/` | The Lua user interface: `nanum.lua` (menu, AI settings), `nanum-fluent.lua` (start screen and playback bar), `nanum-subtitles.lua`, `nanum-generate.lua`, `nanum-rip.lua`, `nanum-upscale.lua`, `nanum-picture.lua`, `nanum-i18n.lua`, and `shaders/`. |
| `locales/` | Translation catalogs, one JSON file per namespace (`core`, `fluent`, `generate`, `native`, `web`). Keys are the Korean source strings; each has `en`, `es`, `ja`, `zh-CN`, `zh-TW` values. Validated by `tools/compile_translations.py`. |
| `youtube/` | The YouTube and web-page browser helper `nanum_youtube.exe` (Win32 + WebView2). |
| `components/` | `catalog.json` (pinned size and SHA-256 of the optional components) and the NVIDIA CUDA redistribution terms. |
| `models/` | `catalog.json`: pinned download URLs, sizes and SHA-256 of the speech models. |
| `tools/` | Build, packaging and installer scripts (`build_nanum_ai.bat`, `build_youtube.bat`, `package.py`, `installer.iss`, `prepare_disc.py`, `compile_translations.py`, `nanum_seek_smoke.py`). |
| `poc/` | Verification scripts (`phase1_check.py`, `phase2_check.py`, `phase2_disc_check.py`, `phase3_lang_check.py`, `exit_check.py`). Sample audio and video are not in the repository. |
| `docs/` | This documentation. |

## Prerequisites

| Tool | Used for |
|---|---|
| Git with submodules | `git clone --recurse-submodules https://github.com/kimmingul/NanumPlayer.git` |
| Visual Studio 2022 (MSVC 14.44) | AI engines and browser helper (`tools\build_nanum_ai.bat`, `tools\build_youtube.bat`) |
| CUDA Toolkit 13.0 | Only for the CUDA engine. The CPU engine builds without it. |
| MSYS2 CLANG64 (clang, meson, ninja and the mpv dependencies) | The player |
| Python 3 | Packaging and checks |
| Inno Setup 6 | The installer |
| Windows SDK `signtool` and a code-signing certificate | Only for signed releases |
| Git for Windows (`patch`) | Applying `tools/disc-libbluray.patch` when building the disc libraries |
| WebView2 Runtime | Running the browser helper |

## Build steps

```bat
git clone --recurse-submodules https://github.com/kimmingul/NanumPlayer.git

:: The CPU build needs no CUDA Toolkit; the CUDA build needs CUDA 13.0
tools\build_nanum_ai.bat cpu
:: output: build\nanum_ai_cpu\nanum_ai_cpu.dll
tools\build_nanum_ai.bat cuda
:: output: build\nanum_ai_cuda\nanum_ai_cuda.dll
:: without an argument both engines are built

tools\build_youtube.bat
:: output: build\youtube\nanum_youtube.exe (needs the WebView2 Runtime to run; without it a notice
:: window is shown and the exit code is 2)
```

`build_youtube.bat` downloads the `Microsoft.Web.WebView2` NuGet package at a pinned version, verifies its
SHA-256 into `build/youtube` and links the static loader.

```bash
# mpv (MSYS2 CLANG64 shell)
pacman -S --needed mingw-w64-clang-x86_64-libdvdread mingw-w64-clang-x86_64-libdvdnav
# only needed to build the optional disc component at packaging time (see below):
pacman -S --needed mingw-w64-clang-x86_64-libdvdcss
cd third_party/mpv
meson setup build -Dlibmpv=false -Dlibbluray=enabled -Ddvdnav=enabled -Ddvda=enabled
meson compile -C build                               # -> build/NanumPlayer.exe
```

Running a development build: put `C:\msys64\clang64\bin` on `PATH` so the playback libraries are found,
and pass `--nanum-ai-dll=<absolute path>\build\nanum_ai_cpu\nanum_ai_cpu.dll`. A packaged build contains
all of that. The speech models are `ggml-small.en.bin`, `ggml-small.bin` and `ggml-silero-v5.1.2.bin`
(see the [reference](reference.md)); a packaged build uses the models downloaded to
`%LOCALAPPDATA%\NanumPlayer\models`, and a development run can also use the `models/` folder.

## Packaging

```bat
python tools/package.py [version] [--no-installer] [--sign <certificate SHA-1 thumbprint>]
```

The version is `NANUM_VERSION` in `third_party/mpv/osdep/nanum-version.h`; a given `[version]` must
equal it. The result is `dist/NanumPlayer-<version>/` (the portable folder: `NanumPlayer.exe`, the CPU
and CUDA engines, the YouTube helper, playback and VC runtimes in the root, and the UI in `scripts/`) and
`dist/NanumPlayer-Setup-<version>.exe` (the per-user installer). cuBLAS, the speech models and the
YouTube tools are not bundled. Prerequisites: built player, CPU and CUDA engines, YouTube helper, MSYS2
CLANG64 and Inno Setup 6. An existing output folder of the same version aborts the run.

- **Signing.** `--sign` signs NanumPlayer's own binaries (`NanumPlayer.exe`, `nanum_youtube.exe`,
  `nanum_ai_cpu.dll`, `nanum_ai_cuda.dll`), the installer and the uninstaller with the Windows SDK
  `signtool` (SHA-256, RFC 3161 timestamp). Third-party DLLs are left alone.
- **CUDA engine pin.** Before packaging, pin the size and SHA-256 of the built engine in
  `components/catalog.json`. For a signed release, sign the CUDA DLL first and pin those final bytes. The
  packager does not sign an engine that is already validly signed again, and aborts if the hash differs
  before and after packaging.
- **Disc libraries.** The packager runs `tools/prepare_disc.py`, which builds libbluray (with
  `tools/disc-libbluray.patch`, which removes upstream's fallback to look for a MakeMKV DLL) and the
  decryption libraries, builds libdvdread from the pinned source without a link-time libdvdcss (CSS support
  is loaded at run time only when the optional component provides it), verifies the SHA-256 of sources and
  licenses, and stages libdvdnav from MSYS2 CLANG64. The decryption libraries (libaacs, libbdplus, libdvdcss) are **never** staged in the installer or
  the portable ZIP (the packager fails if one is found); they go into the separate
  `dist/NanumPlayer-disc-components-<version>.zip`, whose size, SHA-256 and file list are pinned in
  `components/catalog.json`. A mismatch stops the build; `--pin-disc-components` updates the pin, and you
  upload exactly that ZIP to the component repository's release. See [disc components](disc-components.md).
  To verify a disc, use the portable folder from `python tools/package.py --no-installer` and install the
  component ZIP into it; a development run with the MSYS2 libbluray on `PATH` is not the same as a packaged
  build.
- **Translations.** The packager fails before staging if a supported UI language is missing from a
  catalog (`tools/compile_translations.py`'s `load_catalog`). Every user-visible string must exist in all
  six languages.

## Development environment (LSP)

`.omp/lsp.json` points to `clangd` (MSYS2 CLANG64) and a `.clangd` file in each folder selects the
compilation database:

| Area | Compilation database | Generated by |
|---|---|---|
| `third_party/mpv` (C) | `third_party/mpv/build/compile_commands.json` | `meson setup` |
| `nanum_ai` (C++, MSVC) | `build/nanum_ai_cpu/compile_commands.json` | `tools\build_nanum_ai.bat cpu` (the CUDA build is in `build/nanum_ai_cuda`) |

`nanum_ai/.clangd` names the `/imsvc` paths so that clangd finds the MSVC headers without a `vcvars`
environment; update it when you change the MSVC or SDK version.

## Tests and checks

- `nanum_ai_test --selftest` checks utterance splitting and the engine harness.
- `tools/nanum_seek_smoke.py` runs repeated seeks against a real disc or file and checks the landing
  position and the subtitle text.
- `poc/*.py` hold the phase checks used during development; see the
  [verification history](development/verification-history.md).
- Smoke-test the player with an isolated `--config-dir` folder so you do not touch your own settings.
