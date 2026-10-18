# Third-party notices

NanumPlayer's own source code is licensed under the GNU General Public License, version 2 or (at your
option) any later version ([LICENSE](LICENSE)). NanumPlayer is built on and distributed with many
third-party components. This file lists them and their licenses. It is information, not a replacement for
the license texts that ship with each component.

The released binaries link **FFmpeg built under GPL-3.0-or-later** (its build configuration enables GPL and
version-3 components such as x264 and x265). A distributed binary that combines GPL-2.0-or-later code with
that FFmpeg is therefore governed by the terms of the GPL **version 3** as a whole; the text is in
[LICENSES/GPL-3.0.txt](LICENSES/GPL-3.0.txt). NanumPlayer's source permits this because it is licensed
"version 2 or any later version".

## Source code

| Component | Where to get the corresponding source |
|---|---|
| NanumPlayer (this repository) | <https://github.com/kimmingul/NanumPlayer> |
| NanumPlayer's modified mpv (`nanum` branch) | <https://github.com/kimmingul/mpv> (submodule `third_party/mpv`) |
| NanumPlayer's modified whisper.cpp (`nanum` branch) | <https://github.com/kimmingul/whisper.cpp> (submodule `third_party/whisper.cpp`) |
| The unmodified libraries in the package (the table below) | The upstream projects, and the MSYS2 package sources at <https://packages.msys2.org/> (each package page links its source and build recipe). The `tools/prepare_disc.py` script also verifies the SHA-256 of the sources of the disc libraries it builds. |

If you received a binary from this project and want the exact corresponding source of a component and cannot
find it at the places above, [open an issue](https://github.com/kimmingul/NanumPlayer/issues) and we will point
you to it.

## Components written for or modified by NanumPlayer

| Component | License | Notes |
|---|---|---|
| NanumPlayer: the `nanum/` and `osdep/nanum-*` additions, Lua scripts, GPU shaders in `scripts/shaders`, AI engine (`nanum_ai/`), browser helper (`youtube/`), tools | GPL-2.0-or-later | Written for this project. |
| mpv | GPL-2.0-or-later (as built here; mpv is LGPL-2.1-or-later when built without GPL-only parts) | <https://mpv.io/>; see `third_party/mpv/Copyright` for the files with other licenses. |
| whisper.cpp and ggml | MIT | <https://github.com/ggml-org/whisper.cpp>. Speech recognition engine, linked into the AI engine DLLs. NanumPlayer carries a patch that lets a running CPU computation be aborted. |

## Main third-party components

| Component | License | Notes |
|---|---|---|
| FFmpeg (libavcodec, libavformat, libavfilter, libavutil, libswscale, libswresample, libavdevice) | GPL-3.0-or-later (as built in the MSYS2 package) | <https://ffmpeg.org/>. Decoding, demuxing, filters. |
| libass | ISC | Subtitle rendering. |
| libplacebo | LGPL-2.1-or-later | GPU video renderer (`gpu-next`) and mpv-compatible user shaders. |
| libbluray | LGPL-2.1-or-later | Blu-ray navigation, built by `tools/prepare_disc.py` with `tools/disc-libbluray.patch`, which removes upstream's lookup of a third-party decryption DLL. Source and patch are in the package's `disc/sources` folder. |
| libdvdread, libdvdnav | GPL-2.0-or-later | DVD navigation. libdvdread is built by `tools/prepare_disc.py` from the pinned upstream source without a link-time dependency on libdvdcss (CSS support is loaded at run time only when the optional decryption component provides it); the source is in the package's `disc/sources` folder. |
| LuaJIT (`lua51.dll`) | MIT | mpv scripting. |
| SQLite | Public domain | Optional subtitle library. |
| Microsoft WebView2 SDK (static loader, `Microsoft.Web.WebView2` NuGet package) | Microsoft BSD-style license, bundled with the package | Linked into `nanum_youtube.exe`. The **WebView2 Runtime** itself is a Microsoft component under Microsoft's own terms; it is not distributed by this project. |
| Microsoft Visual C++ runtime (`msvcp140.dll`, `vcruntime140*.dll`, `vcomp140.dll`) | Microsoft redistributable terms | Needed by the MSVC-built AI engines. |
| LLVM libc++, libunwind and OpenMP (`libomp.dll`) | Apache-2.0 with LLVM exception | |
| NVIDIA cuBLAS (`cublas64_13.dll`, `cublasLt64_13.dll`) | NVIDIA CUDA Toolkit license terms, [components/LICENSE-NVIDIA-CUDA.txt](components/LICENSE-NVIDIA-CUDA.txt) | **Optional download only**; never in the default package. The files are unmodified and provided solely for use with NanumPlayer; selecting the download means you accept NVIDIA's terms. The CUDA engine (`nanum_ai_cuda.dll`) is NanumPlayer's own code. |

## Models, tools and data that are downloaded on request

These are not part of the package. NanumPlayer downloads them only when you ask, at pinned addresses and with
size and SHA-256 checks, and they keep their own licenses.

| Item | License | Source |
|---|---|---|
| OpenAI Whisper models, ggml format (`ggml-small.en.bin`, `ggml-small.bin`, `ggml-large-v3-turbo-q5_0.bin`) | MIT | <https://huggingface.co/ggerganov/whisper.cpp> (pinned revision in `models/catalog.json`) |
| Silero VAD model, ggml format (`ggml-silero-v5.1.2.bin`) | MIT | <https://huggingface.co/ggml-org/whisper-vad> (pinned revision in `models/catalog.json`) |
| yt-dlp | Unlicense | <https://github.com/yt-dlp/yt-dlp>; for YouTube playback |
| Deno | MIT | <https://github.com/denoland/deno>; used by yt-dlp |
| Blu-ray/DVD decryption components: libaacs, libbdplus (LGPL-2.1-or-later), libdvdcss (GPL-2.0-or-later), libgcrypt, libgpg-error (LGPL-2.1-or-later, GPL-2.0-or-later parts) | As listed | The separately downloaded component; read [docs/disc-components.md](docs/disc-components.md) first. Its package carries its own license texts and sources. |
| AACS key database (FindVUK) | Not distributed by this project | Downloaded from its public site only after you installed the optional component and agreed; see [docs/privacy.md](docs/privacy.md). |

Ollama, `omp` (oh-my-pi) and the translation models you use with them are separate software with their own
licenses; NanumPlayer does not include them.

## Installer and documentation

- The installer is made with [Inno Setup](https://jrsoftware.org/isinfo.php) (modified BSD-style license).
  The Simplified and Traditional Chinese wizard texts in `tools/languages/` are unmodified upstream Inno Setup
  translation files; their provenance and license are stated in the header of each file.
- The Code of Conduct is adapted from the [Contributor Covenant](https://www.contributor-covenant.org),
  version 2.1, licensed under
  [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).

## Libraries bundled in the default package

The portable package ships the runtime DLLs of the MSYS2 `mingw-w64-clang-x86_64` packages below next to
`NanumPlayer.exe`. Versions are those of the 1.12.0 build, without `libdvdcss`, which belongs to the
optional disc component; later builds can differ, and the DLLs in a package are the ones that apply. Licenses are as declared in the MSYS2 package metadata. Several of these
libraries are GPL or LGPL: you may replace the LGPL libraries with your own compatible build, and the GPL
terms apply to the combined work as described at the top of this file.

| Package | Version | License (per MSYS2 metadata) | DLLs |
|---|---|---|---|
| ffmpeg | 9.0.2-1 | GPL-3.0-or-later | `avcodec-63.dll`, `avdevice-63.dll`, `avfilter-12.dll`, `avformat-63.dll`, `avutil-61.dll`, `swresample-7.dll`, `swscale-10.dll` |
| ggml | 0.26.0-1 | MIT | `ggml-0.dll`, `ggml-base-0.dll` |
| aom | 3.15.1-1 | BSD-2-Clause | `libaom.dll` |
| libass | 0.17.5-1 | ISC | `libass-9.dll` |
| libbluray | 1.5.0-1 | LGPL-2.1-or-later | `libbluray-4.dll` |
| brotli | 1.2.0-1 | MIT | `libbrotlicommon.dll`, `libbrotlidec.dll`, `libbrotlienc.dll` |
| bzip2 | 1.0.8-4 | custom | `libbz2-1.dll` |
| libc++ | 22.1.8-1 | Apache-2.0 WITH LLVM-exception | `libc++.dll` |
| libcaca | 0.99.beta20-8 | LGPL | `libcaca-0.dll` |
| cairo | 1.18.6-2 | LGPL-2.1-or-later OR MPL-1.1 | `libcairo-2.dll` |
| openssl | 3.6.5-1 | Apache-2.0 | `libcrypto-3-x64.dll`, `libssl-3-x64.dll` |
| curl | 8.22.0-1 | MIT | `libcurl-4.dll` |
| libdatrie | 0.2.14-1 | LGPL | `libdatrie-1.dll` |
| dav1d | 1.5.4-1 | BSD-2-Clause | `libdav1d-7.dll` |
| libdeflate | 1.26-1 | MIT | `libdeflate.dll` |
| libdovi | 3.4.0-1 | MIT | `libdovi.dll` |
| libdvdnav | 7.0.0-2 | GPL-2.0-or-later | `libdvdnav-4.dll` |
| libdvdread | 7.1.1-1 | GPL-2.0-or-later | `libdvdread-8.dll` |
| expat | 2.8.5-1 | MIT | `libexpat-1.dll` |
| libffi | 3.8.0-1 | MIT | `libffi-8.dll` |
| fontconfig | 2.18.3-1 | custom | `libfontconfig-1.dll` |
| freetype | 2.14.3-1 | GPL-2.0-or-later OR FTL | `libfreetype-6.dll` |
| fribidi | 1.0.17-1 | LGPL-2.1-or-later | `libfribidi-0.dll` |
| gdk-pixbuf2 | 2.44.8-1 | LGPL-2.1-or-later | `libgdk_pixbuf-2.0-0.dll` |
| glib2 | 2.90.0-1 | LGPL-2.1-or-later | `libgio-2.0-0.dll`, `libglib-2.0-0.dll`, `libgmodule-2.0-0.dll`, `libgobject-2.0-0.dll` |
| libgme | 0.6.5-2 | LGPL | `libgme.dll` |
| gmp | 6.3.0-2 | LGPL3 GPL | `libgmp-10.dll` |
| gnutls | 3.8.13-3 | GPL-3.0-or-later LGPL-2.1-or-later | `libgnutls-30.dll` |
| graphite2 | 1.3.15-1 | LGPL-2.1-or-later | `libgraphite2.dll` |
| gsm | 1.0.24-1 | custom | `libgsm.dll` |
| harfbuzz | 14.5.1-1 | MIT | `libharfbuzz-0.dll` |
| nettle | 4.0-1 | GPL-2.0-or-later LGPL-3.0-or-later | `libhogweed-7.dll`, `libnettle-9.dll` |
| highway | 1.4.0-3 | Apache-2.0 | `libhwy.dll` |
| libiconv | 1.19-1 | LGPL-2.1-or-later documentation: GPL-3.0-or-later | `libiconv-2.dll` |
| libidn2 | 2.3.8-4 | GPL-2.0-or-later LGPL-3.0-or-later | `libidn2-0.dll` |
| gettext-runtime | 1.0-1 | GPL-3.0-or-later AND LGPL-2.1-or-later | `libintl-8.dll` |
| jbigkit | 2.1-6 | GPL-2.0 | `libjbig-0.dll` |
| libjpeg-turbo | 3.2.0-1 | custom:BSD-like | `libjpeg-8.dll` |
| libjxl | 0.12.0-1 | BSD-3-Clause | `libjxl.dll`, `libjxl_cms.dll`, `libjxl_threads.dll` |
| liblc3 | 1.1.3-1 | Apache-2.0 | `liblc3-1.dll` |
| lcms2 | 2.19.1-1 | MIT AND GPL-3.0-or-later | `liblcms2-2.dll` |
| lerc | 4.1.1-1 | Apache-2.0 | `libLerc.dll` |
| xz | 5.8.4-1 | 0BSD AND LGPL-2.1-or-later AND GPL-2.0-or-later | `liblzma-5.dll` |
| libmodplug | 0.8.9.0-5 | PublicDomain | `libmodplug-1.dll` |
| lame | 3.100-3 | LGPL | `libmp3lame-0.dll` |
| nghttp2 | 1.70.0-1 | MIT | `libnghttp2-14.dll` |
| nghttp3 | 1.18.0-1 | MIT | `libnghttp3-9.dll` |
| ngtcp2 | 1.25.0-1 | MIT | `libngtcp2-16.dll`, `libngtcp2_crypto_ossl-0.dll` |
| libogg | 1.3.6-1 | BSD-3-Clause | `libogg-0.dll` |
| llvm-openmp | 22.1.8-1 | Apache-2.0 WITH LLVM-exception | `libomp.dll` |
| openal | 1.25.2-1 | GPL-2.0-or-later | `libopenal-1.dll` |
| opencore-amr | 0.1.6-1 | Apache | `libopencore-amrnb-0.dll`, `libopencore-amrwb-0.dll` |
| openjpeg2 | 2.5.4-2 | BSD-2-Clause | `libopenjp2-7.dll` |
| opus | 1.6.1-1 | BSD-3-Clause | `libopus-0.dll` |
| p11-kit | 0.26.5-1 | BSD-3-Clause | `libp11-kit-0.dll` |
| pango | 1.58.2-1 | LGPL-2.1 | `libpango-1.0-0.dll`, `libpangocairo-1.0-0.dll`, `libpangoft2-1.0-0.dll`, `libpangowin32-1.0-0.dll` |
| pcre2 | 10.49-1 | BSD-3-Clause | `libpcre2-8-0.dll` |
| pixman | 0.46.4-3 | MIT | `libpixman-1-0.dll` |
| libplacebo | 7.360.1-2 | LGPL2.1 | `libplacebo-360.dll` |
| libpng | 1.6.59-1 | custom | `libpng16-16.dll` |
| libpsl | 0.21.5-3 | MIT | `libpsl-5.dll` |
| rav1e | 0.8.1-1 | BSD-2-Clause | `librav1e.dll` |
| librsvg | 2.63.2-1 | LGPL-2.1-or-later | `librsvg-2-2.dll` |
| rtmpdump | 2.6-2 | GPL-2.0-or-later LGPL-2.1-or-later | `librtmp-1.dll` |
| shaderc | 2026.4-1 | Apache-2.0 | `libshaderc_shared.dll` |
| libwebp | 1.6.0-1 | BSD-3-Clause | `libsharpyuv-0.dll`, `libwebp-7.dll`, `libwebpmux-3.dll` |
| libsoxr | 0.1.3-5 | LGPL | `libsoxr.dll` |
| speex | 1.2.1-1 | BSD | `libspeex-1.dll` |
| spirv-cross | 1~1.4.363.0-1 | Apache-2.0 | `libspirv-cross-c-shared.dll` |
| sqlite3 | 3.53.4-1 | PublicDomain | `libsqlite3-0.dll` |
| srt | 1.5.7-1 | MPL-2.0 | `libsrt.dll` |
| libssh | 0.12.2-1 | LGPL-2.1-or-later | `libssh.dll` |
| libssh2 | 1.11.1-2 | BSD-3-Clause | `libssh2-1.dll` |
| svt-av1 | 4.2.0-1 | BSD-3-Clause-Clear | `libSvtAv1Enc-4.dll` |
| libtasn1 | 4.21.0-1 | GPL3, LGPL | `libtasn1-6.dll` |
| libthai | 0.1.30-1 | LGPL-2.1-or-later | `libthai-0.dll` |
| libtheora | 1.2.0-1 | BSD-3-Clause | `libtheoradec-2.dll`, `libtheoraenc-2.dll` |
| libtiff | 4.7.2-1 | MIT | `libtiff-6.dll` |
| libunibreak | 7.0-1 | Zlib | `libunibreak-7.dll` |
| libunistring | 1.4.2-1 | LGPL-3.0-or-later OR GPL-3.0-or-later | `libunistring-5.dll` |
| libunwind | 22.1.8-1 | Apache-2.0 WITH LLVM-exception | `libunwind.dll` |
| libva | 2.24.1-1 | MIT | `libva.dll`, `libva_win32.dll` |
| vid.stab | 1.1.2-1 | GPL-2.0-or-later | `libvidstab.dll` |
| libvorbis | 1.3.7-3 | custom | `libvorbis-0.dll`, `libvorbisenc-2.dll` |
| libvpl | 2.17.0-1 | MIT | `libvpl-2.dll` |
| libvpx | 1.17.0-1 | BSD-3-Clause | `libvpx-1.dll` |
| whisper.cpp | 1~1.9.4.r183.g60c0be6ac-1 | MIT | `libwhisper-1.dll` |
| libwinpthread | 14.0.0.r426.g4564ee4b5-1 | MIT AND BSD-3-Clause-Clear | `libwinpthread-1.dll` |
| libx264 | 0.165.r3222.b35605a-3 | custom | `libx264-165.dll` |
| x265 | 4.3-1 | GPL | `libx265-217.dll` |
| libxml2 | 2.15.4-1 | MIT | `libxml2-16.dll` |
| zimg | 3.0.6-3 | WTFPL | `libzimg-2.dll` |
| zstd | 1.5.7-2 | BSD-3-Clause OR GPL-2.0-or-later | `libzstd.dll` |
| zvbi | 0.2.45-1 | GPL-2.0-or-later AND BSD-2-Clause AND LGPL-2.1-or-later AND MIT | `libzvbi-0.dll` |
| luajit | 2.1.1788460057-2 | MIT | `lua51.dll` |
| vulkan-loader | 1~1.4.363.0-1 | Apache-2.0 | `vulkan-1.dll` |
| xvidcore | 1.3.7-5 | GPL | `xvidcore.dll` |
| zlib | 1.3.2-2 | Zlib | `zlib1.dll` |
