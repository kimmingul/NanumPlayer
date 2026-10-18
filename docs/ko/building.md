# 소스에서 NanumPlayer 빌드하기

[English](../building.md) · 한국어

NanumPlayer는 Windows x64에서만 빌드합니다. 수정된 mpv 자체를 `NanumPlayer.exe`로 빌드하며,
별도 런처나 `mpv.exe` 자식 프로세스를 사용하지 않습니다.

## 구조

```
Blu-ray / 파일 ─▶ mpv demuxer (선읽기 N초)
                    ├─▶ 일반 재생 경로
                    └─▶ nanum 탭: 오디오 패킷 복사 (락 안에서는 복사만)
                           │ 별도 스레드: libavcodec 디코드 → 16 kHz 모노(센터 채널 가중)
                           ▼
                      nanum_ai_cpu.dll / nanum_ai_cuda.dll (내장, MSVC, 공통 C ABI)
                        Silero VAD → whisper.cpp(음성 인식) → 번역(Ollama API, 배치) → 메모리 캐시
                           │ 절대 PTS 이벤트 (선읽기 구간만큼 재생보다 앞서 도착)
                           ▼
                      demux.c: 가상 ASS 스트림(재생 음성 기반, 원어 음성 기반)에 주입 → libass 렌더
```

mpv는 MSYS2 CLANG64(clang/meson)로, AI 엔진은 MSVC로 빌드합니다. 툴체인이 달라 mpv가 엔진 DLL을
런타임에 `LoadLibrary`합니다. 계약은 `third_party/mpv/nanum/nanum_ai_api.h` ↔ `nanum_ai/nanum_ai.h`이며
`NANUM_AI_ABI_VERSION`으로 확인합니다.

## 저장소 구성

| 경로 | 내용 |
|---|---|
| `third_party/mpv` | 서브모듈: [kimmingul/mpv](https://github.com/kimmingul/mpv) `nanum` 브랜치 (mpv + NanumPlayer 패치: `nanum/`, `osdep/nanum-*`, `demux/`, `player/`, `stream/`). |
| `third_party/whisper.cpp` | 서브모듈: [kimmingul/whisper.cpp](https://github.com/kimmingul/whisper.cpp) `nanum` 브랜치 (음성 엔진, 정적 링크; CPU 계산 중단 패치 포함). |
| `nanum_ai/` | CPU/CUDA 엔진 소스: `nanum_ai.h`(C ABI), 음성 인식·VAD 워커, `translator.*`, 테스트 하네스. |
| `scripts/` | Lua 사용자 인터페이스: `nanum.lua`(메뉴, AI 설정), `nanum-fluent.lua`(시작 화면과 재생 바), `nanum-subtitles.lua`, `nanum-generate.lua`, `nanum-rip.lua`, `nanum-upscale.lua`, `nanum-picture.lua`, `nanum-i18n.lua`, `shaders/`. |
| `locales/` | 번역 카탈로그. 네임스페이스(`core`, `fluent`, `generate`, `native`, `web`)마다 JSON 파일 하나. 키는 한국어 원문이며 각각 `en`, `es`, `ja`, `zh-CN`, `zh-TW` 값을 가집니다. `tools/compile_translations.py`로 검증합니다. |
| `youtube/` | YouTube·웹페이지 브라우저 도우미 `nanum_youtube.exe` (Win32 + WebView2). |
| `components/` | `catalog.json`(선택 구성 요소의 고정 크기와 SHA-256)과 NVIDIA CUDA 재배포 조건. |
| `models/` | `catalog.json`: 음성 모델의 고정 다운로드 URL, 크기, SHA-256. |
| `tools/` | 빌드, 패키징, 설치 파일 스크립트 (`build_nanum_ai.bat`, `build_youtube.bat`, `package.py`, `installer.iss`, `prepare_disc.py`, `compile_translations.py`, `nanum_seek_smoke.py`). |
| `poc/` | 검증 스크립트 (`phase1_check.py`, `phase2_check.py`, `phase2_disc_check.py`, `phase3_lang_check.py`, `exit_check.py`). 샘플 오디오·영상은 저장소에 포함하지 않습니다. |
| `docs/` | 이 문서들. |

## 준비물

| 도구 | 용도 |
|---|---|
| 서브모듈을 지원하는 Git | `git clone --recurse-submodules https://github.com/kimmingul/NanumPlayer.git` |
| Visual Studio 2022 (MSVC 14.44) | AI 엔진과 브라우저 도우미 (`tools\build_nanum_ai.bat`, `tools\build_youtube.bat`) |
| CUDA Toolkit 13.0 | CUDA 엔진에만 필요합니다. CPU 엔진은 없이도 빌드됩니다. |
| MSYS2 CLANG64 (clang, meson, ninja와 mpv 의존 라이브러리) | 플레이어 |
| Python 3 | 패키징과 검증 |
| Inno Setup 6 | 설치 파일 |
| Windows SDK `signtool`과 코드 서명 인증서 | 서명 배포에만 필요 |
| Git for Windows (`patch`) | 디스크 라이브러리를 빌드할 때 `tools/disc-libbluray.patch` 적용 |
| WebView2 런타임 | 브라우저 도우미 실행 |

## 빌드 단계

```bat
git clone --recurse-submodules https://github.com/kimmingul/NanumPlayer.git

:: CPU 빌드는 CUDA Toolkit 없이 가능; CUDA 빌드는 CUDA 13.0 필요
tools\build_nanum_ai.bat cpu
:: 출력: build\nanum_ai_cpu\nanum_ai_cpu.dll
tools\build_nanum_ai.bat cuda
:: 출력: build\nanum_ai_cuda\nanum_ai_cuda.dll
:: 인자 생략 시 두 엔진을 모두 빌드

tools\build_youtube.bat
:: 출력: build\youtube\nanum_youtube.exe (실행에 WebView2 런타임 필요; 없으면 안내 창 후 종료 코드 2)
```

`build_youtube.bat`은 `Microsoft.Web.WebView2` NuGet 패키지를 버전 고정으로 받아 SHA-256을 확인한 뒤
`build/youtube`에 두고 정적 로더를 링크합니다.

```bash
# mpv (MSYS2 CLANG64 셸)
pacman -S --needed mingw-w64-clang-x86_64-libdvdread mingw-w64-clang-x86_64-libdvdnav
# 패키징할 때 선택 디스크 구성 요소를 빌드하는 경우에만 필요합니다(아래 참고):
pacman -S --needed mingw-w64-clang-x86_64-libdvdcss
cd third_party/mpv
meson setup build -Dlibmpv=false -Dlibbluray=enabled -Ddvdnav=enabled -Ddvda=enabled
meson compile -C build                               # -> build/NanumPlayer.exe
```

개발용 빌드를 실행하려면 재생 라이브러리를 찾도록 PATH에 `C:\msys64\clang64\bin`을 두고
`--nanum-ai-dll=<절대 경로>\build\nanum_ai_cpu\nanum_ai_cpu.dll`을 지정합니다. 배포본은 이를 모두
포함합니다. 음성 모델은 `ggml-small.en.bin`, `ggml-small.bin`, `ggml-silero-v5.1.2.bin`이며
([참조](reference.md) 참고), 배포본은 다운로드한 `%LOCALAPPDATA%\NanumPlayer\models`의 모델을 사용하고
개발 실행은 `models/` 폴더의 모델도 사용할 수 있습니다.

## 배포본 만들기

```bat
python tools/package.py [버전] [--no-installer] [--sign <인증서 SHA-1 지문>]
```

버전은 `third_party/mpv/osdep/nanum-version.h`의 `NANUM_VERSION`이며, `[버전]`을 지정하면 이 값과 같아야
합니다. 결과는 `dist/NanumPlayer-<버전>/`(포터블 폴더: `NanumPlayer.exe`, CPU·CUDA 엔진, YouTube 도우미,
재생/VC 런타임은 루트, UI는 `scripts/`)와 `dist/NanumPlayer-Setup-<버전>.exe`(사용자 단위 설치 파일)입니다.
cuBLAS, 음성 모델, YouTube 도구는 번들하지 않습니다. 전제: 빌드된 플레이어, CPU·CUDA 엔진, YouTube 도우미,
MSYS2 CLANG64, Inno Setup 6. 같은 버전의 출력 폴더가 이미 있으면 중단합니다.

- **서명.** `--sign`은 Windows SDK `signtool`(SHA-256, RFC 3161 타임스탬프)로 NanumPlayer 자체 바이너리
  (`NanumPlayer.exe`, `nanum_youtube.exe`, `nanum_ai_cpu.dll`, `nanum_ai_cuda.dll`)와 설치 파일·제거
  프로그램에 서명합니다. 서드파티 DLL은 그대로 둡니다.
- **CUDA 엔진 고정.** 패키징 전에 `components/catalog.json`의 크기/SHA-256을 빌드된 엔진에 맞춰 고정합니다.
  서명 배포는 먼저 CUDA DLL을 서명하고 그 최종 바이트를 고정하세요. 패키저는 이미 유효하게 서명된 엔진을
  다시 서명하지 않으며, 포장 전후 해시가 달라지면 중단합니다.
- **디스크 라이브러리.** 패키저는 `tools/prepare_disc.py`를 실행해 libbluray(`tools/disc-libbluray.patch` 적용;
  이 패치는 upstream의 MakeMKV DLL 탐색 fallback을 제거합니다)와 복호화 라이브러리를 빌드하고, 소스와
  라이선스의 SHA-256을 확인하고, libdvdread는 고정된 소스에서 libdvdcss 링크 의존성 없이 빌드하며(CSS 지원은 선택 구성 요소가 있을 때만 런타임에
  불러옵니다), libdvdnav는 MSYS2 CLANG64에서 준비합니다. 복호화 라이브러리(libaacs,
  libbdplus, libdvdcss)는 설치 파일과 포터블 ZIP에 **절대** 넣지 않으며(하나라도 발견되면 패키저가
  실패합니다), 별도의 `dist/NanumPlayer-disc-components-<버전>.zip`에 담깁니다. 이 ZIP의 크기, SHA-256,
  파일 목록은 `components/catalog.json`에 고정되며, 불일치하면 빌드가 중단됩니다. `--pin-disc-components`로
  고정값을 갱신하고, 정확히 그 ZIP을 구성 요소 저장소의 릴리스에 올립니다.
  [디스크 구성 요소](disc-components.md)를 참고하세요. 디스크를 검증하려면
  `python tools/package.py --no-installer`가 만든 포터블 폴더를 사용하고 거기에 구성 요소 ZIP을 설치하세요.
  원본 MSYS2 libbluray를 PATH에서 쓰는 개발 실행은 배포본과 같지 않습니다.
- **번역.** 지원하는 UI 언어가 카탈로그에 하나라도 없으면 패키저는 준비 단계 전에 실패합니다
  (`tools/compile_translations.py`의 `load_catalog`). 사용자에게 보이는 모든 문자열은 여섯 언어 모두에
  있어야 합니다.

## 개발 환경 (LSP)

`.omp/lsp.json`이 `clangd`(MSYS2 CLANG64)를 지정하고, 폴더별 `.clangd`가 컴파일 DB를 고릅니다.

| 영역 | 컴파일 DB | 생성 |
|---|---|---|
| `third_party/mpv` (C) | `third_party/mpv/build/compile_commands.json` | `meson setup` |
| `nanum_ai` (C++, MSVC) | `build/nanum_ai_cpu/compile_commands.json` | `tools\build_nanum_ai.bat cpu` (CUDA 빌드는 `build/nanum_ai_cuda`) |

`nanum_ai/.clangd`는 vcvars 환경 없이 clangd가 MSVC 헤더를 찾도록 `/imsvc` 경로를 명시합니다. MSVC/SDK
버전을 바꾸면 갱신하세요.

## 테스트와 검증

- `nanum_ai_test --selftest`는 발화 분할과 엔진 하네스를 검사합니다.
- `tools/nanum_seek_smoke.py`는 실제 디스크나 파일에서 탐색을 반복하며 착지 위치와 자막 텍스트를 확인합니다.
- `poc/*.py`는 개발 중 사용한 단계별 검증 스크립트입니다. [검증 기록](../development/verification-history.md)을
  참고하세요.
- 플레이어 스모크 테스트는 격리된 `--config-dir` 폴더로 실행해 자신의 설정을 건드리지 않도록 하세요.
