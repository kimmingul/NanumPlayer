# NanumPlayer

해외 Blu-ray(영어/일본어 음성, 영어 자막만 수록)를 재생하면서 **대사를 실시간으로 인식·번역해 한국어 자막 트랙으로 보여 주는** 플레이어. 음성이 여러 언어면 재생 음성 기반(`한국어 (영어 음성 기반)`)과 원어 음성 기반(`한국어 (일본어 음성 기반)`) 자막을 함께 만듭니다.
mpv 소스에 AI 엔진을 직접 붙인 네이티브 구조입니다. 수정된 mpv 자체를 `NanumPlayer.exe`로 빌드하며, 별도 런처나 `mpv.exe` 자식 프로세스를 사용하지 않습니다.

```
Blu-ray / 파일 ─▶ mpv demuxer (선읽기 N초)
                    ├─▶ 일반 재생 경로
                    └─▶ nanum 탭: 오디오 패킷 복사 (락 안에서는 복사만)
                           │ 별도 스레드: libavcodec 디코드 → 16 kHz 모노(센터 채널 가중)
                           ▼
                      nanum_ai_cpu.dll / 선택 CUDA 엔진 (MSVC, 공통 C ABI)
                        Silero VAD → whisper.cpp(STT) → 번역(Ollama API, 배치) → JSONL 캐시
                           │ 절대 PTS 이벤트 (선읽기 구간만큼 재생보다 앞서 도착)
                           ▼
                      demux.c: 가상 ASS 스트림(재생 음성 기반, 원어 음성 기반)에 주입 → libass 렌더
```

## 저장소 구성

| 경로 | 내용 |
|---|---|
| `third_party/mpv` | 서브모듈: [kimmingul/mpv](https://github.com/kimmingul/mpv) `nanum` 브랜치 (mpv + NanumPlayer 패치: `nanum/`, `osdep/nanum-*`, `demux/`, `player/`, `stream/`) |
| `third_party/whisper.cpp` | 서브모듈: [kimmingul/whisper.cpp](https://github.com/kimmingul/whisper.cpp) `nanum` 브랜치 (STT 엔진, 정적 링크; CPU 계산 중단 콜백 패치) |
| `nanum_ai/` | CPU/CUDA 엔진 소스: `nanum_ai.h`(C ABI), STT/VAD 워커, `translator.*`, 테스트 하네스 |
| `tools/build_nanum_ai.bat` | CPU 기본 엔진 및 선택 CUDA 엔진 빌드 (VS 2022 MSVC 14.44) |
| `youtube/` | YouTube 브라우저 도우미 `nanum_youtube.exe` (Win32 + WebView2): 영상 선택/로그인, 쿠키 내보내기(`cookies.txt`), mpv IPC로 `nanum-youtube-open` 전달 |
| `tools/build_youtube.bat` | 도우미 빌드 (VS 2022 MSVC). `Microsoft.Web.WebView2` NuGet 패키지를 버전 고정 + SHA-256 확인 후 `build/youtube`에 받아 정적 로더로 링크 |
| `poc/` | 검증 스크립트 (`phase1_check.py`, `phase2_check.py`, `phase2_disc_check.py`, `phase3_lang_check.py`, `exit_check.py`). 샘플 오디오·영상은 저장소에 포함하지 않습니다 |
| `tools/package.py` | 포터블 배포본·설치 파일 생성, `--sign <인증서 지문>`으로 코드 서명 |

mpv는 MSYS2 CLANG64(clang/meson)로, AI 엔진은 MSVC로 빌드합니다. 툴체인이 달라 mpv가 DLL을 런타임에 `LoadLibrary`합니다
(`third_party/mpv/nanum/nanum_ai_api.h` ↔ `nanum_ai/nanum_ai.h`, `NANUM_AI_ABI_VERSION`으로 확인).

## 빌드

```bat
git clone --recurse-submodules https://github.com/kimmingul/NanumPlayer.git

:: CPU 빌드는 CUDA Toolkit 없이 가능; CUDA 빌드는 CUDA 13.0 필요
tools\build_nanum_ai.bat cpu
:: 출력: build\nanum_ai_cpu\nanum_ai_cpu.dll
tools\build_nanum_ai.bat cuda
:: 출력: build\nanum_ai_cuda\nanum_ai_cuda.dll
:: 인자 생략 시 두 엔진을 모두 빌드

tools\build_youtube.bat
::: 출력: build\youtube\nanum_youtube.exe (실행에 WebView2 런타임 필요; 없으면 안내 창 후 종료 코드 2)
```
```bash
# mpv (MSYS2 CLANG64 셸)
cd third_party/mpv
meson setup build -Dlibmpv=false -Dlibbluray=enabled   # 최초 1회
meson compile -C build                               # -> build/NanumPlayer.exe
```
필요 모델: `ggml-small.en.bin`(영어 Whisper), `ggml-small.bin`(다국어, `--nanum-stt-model-multilingual`), `ggml-silero-v5.1.2.bin`(VAD). 개발용 `models/`의 기존 모델도 사용할 수 있으며, 배포본은 다운로드한 `%LOCALAPPDATA%\NanumPlayer\models`의 파일을 기본으로 사용합니다.
개발용 네이티브 실행 파일은 재생 라이브러리를 찾도록 PATH에 `C:\msys64\clang64\bin`을 두고 `--nanum-ai-dll=<절대 경로>\build\nanum_ai_cpu\nanum_ai_cpu.dll`을 지정할 수 있습니다. 배포본은 이를 모두 포함하며 CUDA DLL 폴더를 PATH에 추가할 필요가 없습니다.


### 배포본 만들기

`python tools/package.py [버전] [--sign <인증서 SHA-1 지문>]` → `dist/NanumPlayer-<버전>/`(포터블 폴더: `NanumPlayer.exe`, CPU·CUDA 엔진, YouTube 도우미, 재생/VC 런타임은 루트, UI는 `scripts/`)와 `dist/NanumPlayer-Setup-<버전>.exe`(사용자 단위 설치). cuBLAS·음성 모델·YouTube 도구는 번들하지 않습니다. 전제: 네이티브 플레이어·CPU/CUDA 엔진·YouTube 도우미 빌드, MSYS2 CLANG64, Inno Setup 6. 기존 배포 폴더가 있으면 중단합니다.
`--sign`은 Windows SDK `signtool`(SHA-256, RFC 3161 타임스탬프)로 NanumPlayer 자체 바이너리(`NanumPlayer.exe`, `nanum_youtube.exe`, `nanum_ai_cpu.dll`, `nanum_ai_cuda.dll`)와 설치 파일·제거 프로그램에 서명합니다. 서드파티 DLL은 그대로 둡니다.
설정 우선순위는 기본값 < 사용자 설정 < 명령행이며 사용자 설정은 `%APPDATA%\NanumPlayer`에 둡니다. 복호화 DLL은 번들하지 않고 설치된 MakeMKV를 자동 연결합니다. CPU 엔진은 AVX2 x64, 선택 CUDA 엔진은 compute 8.6 이상과 호환 드라이버가 필요합니다.

Whisper·Silero 모델 파일은 설치파일과 포터블 배포에서 제외합니다. 설치 화면에서 영어 Whisper+Silero(약 466 MiB), 다국어 Whisper+Silero(약 466 MiB), 다국어 고정밀 Whisper large-v3-turbo(q5_0, 약 548 MiB)+Silero, Silero만(약 0.8 MiB)을 선택 다운로드할 수 있습니다. 기본은 다운로드하지 않습니다. large-v3-turbo가 설치되면 영어가 아닌 입력(일본어 등)은 small 대신 이 모델을 사용합니다. 공식 저장소의 고정 리비전 URL과 크기·SHA-256은 `models/catalog.json`으로 관리합니다. 모델은 `%LOCALAPPDATA%\NanumPlayer\models`에 검증 후 저장하고 재설치 때 재사용하며, 앱을 삭제해도 유지합니다. 기존 설치 폴더의 검증된 모델도 재다운로드하지 않고 옮겨 사용할 수 있습니다. Ollama 번역 모델은 별도 준비가 필요합니다.

설치 중 다운로드를 건너뛰었으면 **Ctrl+N → AI 구성 요소 관리**에서 전체/개별 모델을 받습니다. 실제 다운로드 진행률·무결성 검증·오류·취소 상태를 표시하며 메뉴를 닫아도 다운로드는 계속됩니다. 영어/다국어 Whisper를 선택하면 VAD도 함께 준비합니다. 모델이 없거나 AI가 꺼져 있으면 프리롤 대기 없이 일반 재생하며, 다운로드 완료 후 다음에 여는 파일부터 음성 인식을 사용할 수 있습니다. 앱 재시작은 필요 없습니다. 사용자 지정 모델 경로와 기존 설치 폴더의 모델은 덮어쓰지 않습니다.

### 선택 CUDA 가속

CPU 엔진과 CUDA 엔진(`nanum_ai_cuda.dll`, 약 53 MiB)이 모두 앱에 포함됩니다. CUDA 엔진에 필요한 cuBLAS(`cublas64_13.dll`, `cublasLt64_13.dll`)는 설치된 **CUDA 13 Toolkit**에서 그대로 사용합니다. Toolkit은 프로세스 환경 변수(`CUDA_PATH`, `CUDA_PATH_V13_*`), 레지스트리 환경 변수(Toolkit을 앱 실행 후 설치한 경우 대비), `%ProgramFiles%\NVIDIA GPU Computing Toolkit\CUDA\v13.*` 순으로 찾고 최신 버전을 우선합니다. Toolkit과 호환 GPU가 있으면 자동 모드에서 첫 파일부터 다운로드·확인 창 없이 GPU를 씁니다. CUDA 12 Toolkit만으로는 부족합니다.

Toolkit이 없으면 설정의 **AI 구성 요소 관리** 또는 설치 화면에서 cuBLAS만(약 507 MiB) 받을 수 있습니다. 다운로드 전 NVIDIA 조건에 동의하며, 크기/SHA-256(`components/catalog.json`)을 검증한 뒤 앱 버전과 무관한 `%LOCALAPPDATA%\NanumPlayer\accelerators\cuda\13`에 저장합니다. 예전 버전 폴더에 검증된 cuBLAS가 있으면 내려받지 않고 복사합니다. 제거 시 유지합니다.

가속 모드는 `auto`(사용 가능한 CUDA, 아니면 CPU), `cpu`, `cuda`(필수)입니다. CUDA가 없다고 CPU 음성 인식이나 외부 Ollama/omp 번역이 불가능한 것은 아닙니다. 텍스트 자막 입력은 음성 모델과 CUDA 없이 CPU 번역 전용으로 동작하며 CUDA 필수 설정도 음성 입력에만 적용합니다. 음성 입력의 CUDA 미설치·비호환과 모델 누락은 별도로 안내하고 일반 재생은 계속합니다. 다운로드·가속 모드 변경은 다음 파일부터 적용합니다. 재생 중 AI 입력을 텍스트↔음성으로 바꾸면 이전 작업을 종료하고 해당 입력용 엔진을 새로 시작합니다.

### 디스크 읽기·탐색 진단

기본 `%APPDATA%\NanumPlayer\last-playback.log`는 정보·경고·오류만 기록하며 8 MiB에서 순환하고 이전 파일 2개를 유지합니다. Fluent 레이아웃과 패킷 단위 로그는 기본 기록하지 않습니다. 사용자가 명시한 `--log-file`은 기존 mpv 로그 정책을 유지합니다.

**Ctrl+N → 진단 로그(디스크 읽기 상세)**로 켜거나 IPC 명령 `nanum-diagnostics on`/`off`/`toggle`, 시작 환경 변수 `NANUMPLAYER_DIAGNOSTICS=1`을 사용합니다. 상세 로그는 `~~/diagnostics/disc-날짜-시간-PID.log`에 저장하며 파일당 최대 8 MiB, 최근 8개만 유지합니다. 설정 경로를 지정하지 않으면 `~~`는 `%APPDATA%\NanumPlayer`입니다.

상세 로그는 탐색 요청·실제 착지·첫 데이터 도착, 읽기 오프셋·길이·소요 시간, 실패한 Windows `ReadFile`의 오류 코드, 드라이브 모델·펌웨어·연결 종류를 기록합니다. 실패 후 관련 Windows 이벤트와 접근 가능한 MakeMKV 로그의 제한된 부분을 수집하며 키·미디어 내용·드라이브 일련번호는 기록하지 않습니다. 파일 읽기가 성공했는데 AACS 복호화가 실패한 경우와 실제 OS 읽기 실패를 구분합니다. 드라이브의 SCSI sense 데이터는 이 파일 I/O 계층에서 제공되지 않으므로 오류 코드를 지어내지 않습니다.


1.0.1: 배포본의 `cannot find libaacs` 오류를 수정했습니다. MakeMKV 자동 연결, 파일 종료/실패 시 AI 대기 해제, 화면 오류 안내 및 `%APPDATA%\NanumPlayer\last-playback.log` 기록을 추가했습니다. 실행 중인 구 배포본을 삭제하지 않도록 패키징 출력도 버전별 폴더로 분리했습니다.

1.1.0: 별도 런처를 제거하고 네이티브 실행 파일·아이콘·어두운 Windows 창 테두리를 적용했습니다. 기본 mpv OSC 대신 Windows 11 스타일의 시작 카드, 자동 숨김 재생 바, 탐색·볼륨 조작, 자막·음성·AI 설정 패널을 제공합니다. Blu-ray의 TrueHD와 AC-3 코어가 같은 스트림 ID를 공유할 때 AI 디코더가 매 패킷마다 재시작되던 오류를 수정했습니다. AI 입력은 하나의 실제 스트림에 고정하고, 탐색 시 디코더·준비 시각을 재설정합니다. 파일의 캐시 탐색에서 가상 AI 자막 스트림이 갱신 대기에 남던 문제도 수정했습니다.
Whisper·Silero 모델은 번들에서 제외하고 설치 및 설정 메뉴의 선택 다운로드로 전환했습니다. 모델 초기화는 첫 입력 언어를 확인한 뒤 수행하므로 일본어 입력이 불필요하게 영어 모델을 요구하지 않습니다. 반복 탐색에서는 같은 대사의 겹치는 재분석 결과를 중복 표시하지 않으며 ASS 캐시를 비운 뒤 저장된 큐를 다시 전달합니다.

1.2.0: 내장 CPU 엔진과 선택 다운로드 CUDA 엔진·cuBLAS를 분리했습니다. 설치·설정에서 같은 고정 자산 목록을 사용하고 호환 Toolkit은 원본 위치에서 재사용합니다. 자동·CPU·CUDA 필수 모드와 모델/가속 누락 안내를 분리했으며 설치의 무인 선택 다운로드도 실행합니다. 기본 로그의 용량·보관 수를 제한하고 선택 디스크 진단에 Windows 읽기 오류·탐색 시간·관련 이벤트를 추가했습니다. GPU→CPU 전환 직후 종료 시 OpenMP 런타임의 대기 스레드가 해제된 DLL을 실행하던 문제를 수정했습니다. 엔진은 파일별로 해제하고 OpenMP 런타임만 프로세스 종료까지 유지합니다.

1.2.1: 텍스트 자막 입력과 전체 텍스트 번역에서 Whisper·VAD·CUDA 의존성을 제거했습니다. 번역 전용과 스캔 전용을 독립된 모드로 처리하고 텍스트↔음성 입력 전환 시 작업·엔진을 안전하게 다시 시작합니다. 새 음성 입력은 이미 버퍼링된 오디오도 전달받으며 짧은 외부 자막은 전체 번역 완료 후 프리롤 목표보다 짧아도 재생합니다. 1.2.0 다운로드 자산은 바꾸지 않고 수정 CUDA 엔진의 URL·SHA-256과 사용자 캐시를 1.2.1로 분리했습니다.

1.3.0: 음성이 여러 언어인 Blu-ray·파일에서 재생 음성 기반 자막을 먼저 만들고, AI가 판별한 원어 음성 기반 자막을 같은 스트림에서 낮은 우선순위로 함께 만듭니다(추가 디스크 읽기 없음). 두 결과를 영화별로 저장해 다시 열면 바로 사용합니다. 작품 제목으로 등장인물·고유명사 용어집(성·이름·전체 이름 포함)을 만들어 실시간·전체 번역에 적용하고, 메뉴에서 보고 고치면 이미 만든 자막도 다시 번역합니다. 번역 말투 설정, Whisper large-v3-turbo 선택 다운로드를 추가했습니다. 재분석으로 같은 대사가 두 줄로 겹치던 문제와 로컬 모델의 `<0xHH>` 바이트 토큰 글자 깨짐(기존 캐시 포함)을 수정했습니다.

1.4.0: 디스크의 이미지 자막(PGS)을 Windows 문자 인식(OCR)으로 읽어 `한국어 (영어 디스크 자막 기반)` 트랙을 추가로 만듭니다(디스크와 시간이 정확히 맞음, 추가 디스크 읽기 없음). Ctrl+N → **온라인 자막 찾기**로 OpenSubtitles(영어/일본어/한국어)·Jimaku(일본어) 검색 페이지를 브라우저로 열고, 사용자가 받은 자막(zip 포함)을 다운로드 폴더에서 자동으로 가져와 음성 인식 자막에 맞춰 시간을 자동 조정한 뒤 번역 트랙(`한국어 (OpenSubtitles 영어 자막 기반)` 등)으로 보여 줍니다. 사이트 자동 조작은 하지 않습니다. 번역 모델은 Ollama에 설치된 모델 목록에서 고릅니다. 모든 결과는 영화별로 저장됩니다.

1.5.0: YouTube 재생. 첫 화면 **YouTube**(Ctrl+Y)가 앱 안 YouTube 창(WebView2, `nanum_youtube.exe`)을 열어 평소처럼 고르고 로그인합니다(로그인 정보는 `%LOCALAPPDATA%\NanumPlayer\youtube`에 유지). 영상을 고르면 그 창의 로그인 쿠키로 NanumPlayer가 yt-dlp(+Deno, 선택 다운로드·SHA-256 검증·업데이트 확인)를 통해 재생하고, 음성 인식·번역·용어집·말투·저장(영상 ID 기준) 등 기존 기능을 그대로 씁니다. 영상에 자막이 있으면 입력 소스 규칙에 따라 그 자막을 원문으로 씁니다(메뉴에서 STT로 변경 가능). 주소 붙여넣기(Ctrl+N → YouTube 주소로 재생), 브라우저 즐겨찾기용 "NanumPlayer로 열기"(`nanumplayer://open?url=`)도 지원합니다. 비공식 도구로 로그인 계정을 쓰면 YouTube가 확인 절차나 제한을 걸 수 있습니다.

1.5.1: 재생 중 종료가 느리던 문제를 수정했습니다. 원인은 CPU에서 large-v3-turbo 음성 인식이 도는 동안 엔진 정리가 진행 중인 Whisper 계산(최대 20초 구간, 인코더 포함)을 끝까지 기다린 것이었습니다(재현 19.7초). Whisper에 중단 콜백을 연결하고, 내장 whisper.cpp가 이 콜백을 인코더 계산 도중에도 CPU 백엔드에 전달하도록 패치해 종료 0.3초, 탐색 시 지난 구간 계산도 즉시 버립니다. 앱 업데이트 후 CUDA 엔진이 바뀌지 않았으면 이전 버전 폴더의 엔진을 SHA-256 확인 후 복사해 쓰고, 바뀌었으면 "CUDA 엔진 업데이트 필요" 안내(버전당 한 번)와 상태 표시를 하며 그동안 CPU를 씁니다.

1.6.0: CUDA 엔진을 앱에 포함했습니다. CUDA 13 Toolkit을 설치하면 엔진 다운로드 없이 바로 GPU를 씁니다(레지스트리·기본 설치 폴더에서도 Toolkit을 찾음). Toolkit이 없을 때만 cuBLAS를 받으며, 캐시는 앱 버전과 무관하게 유지됩니다. 1.5.1의 "CUDA 엔진 업데이트 필요" 안내는 없앴습니다.

1.6.1: 설치 파일이 설치 전에 이미 있는 구성 요소를 확인합니다. 선택 화면에서 설치된 음성 모델·VAD·cuBLAS 캐시는 "이미 설치됨"으로 비활성화하고, 호환 CUDA 13 Toolkit이 있으면 CUDA 항목을 "Toolkit v13.x 감지됨, 받을 필요 없음"으로, NVIDIA 드라이버가 없으면 "드라이버 없음"으로 표시합니다. YouTube 도구는 설치돼 있으면 최신일 때 다시 받지 않습니다. 준비 화면의 "설치 전 확인"에 음성 모델, CUDA(Toolkit·드라이버·GPU), YouTube 도구, WebView2 런타임, Ollama, MakeMKV 상태와 없을 때 필요한 조치를 보여 줍니다(정보만 표시, 자동 설치 없음). 감지 결과는 설치 로그에도 기록됩니다.

1.6.2: 암호화된 Blu-ray 재생에 필요한 MakeMKV 안내를 강화했습니다. 설치 파일은 MakeMKV(`libmmbd64.dll`)가 없으면 "Blu-ray 재생 준비" 화면에서 필요성을 알리고 받기 페이지를 열 수 있게 합니다(건너뛰기 가능, 무인 설치는 로그만). 앱은 디스크 재생 실패 원인을 구분합니다: 복호화 라이브러리가 없으면 "MakeMKV가 설치되어 있지 않습니다", 있는데 암호를 풀지 못하면 "활성화되지 않았거나 키가 만료됐을 수 있습니다"를 보여 주고 [MakeMKV 실행]·[받기 페이지 열기]·[다시 시도]를 제공합니다.

1.6.3: 재생 바가 마우스를 멈춘 뒤 1.2초(설정: 짧게/보통 2초/길게 3초)에 사라지고, 커서가 창 밖으로 나가면 바로 사라집니다(일시정지·바 위 커서는 유지). 재생 바 위에 선택한 AI 자막 트랙의 처리 방식 태그(음성 인식 GPU/CPU, 원문 모델·출처, 번역 모델과 로컬 GPU/GPU 일부/CPU/클라우드)를 표시하고, 눌러서 해당 설정으로 갑니다(Ctrl+N에서 끄기 가능). 앱 버전을 시작 화면, Ctrl+N 정보 항목, Ctrl+K에 표시합니다. 버전은 `third_party/mpv/osdep/nanum-version.h` 한 곳에서 관리합니다(플레이어·YouTube 도우미 파일 정보, 패키징 공통).

## 실행

```bat
NanumPlayer.exe bd://longest --bluray-device=E: --nanum ^
  --nanum-acceleration=auto ^
  --nanum-stt-model=D:\repo\NanumPlayer\models\ggml-small.en.bin ^
  --nanum-vad-model=D:\repo\NanumPlayer\models\ggml-silero-v5.1.2.bin ^
  --nanum-translate-model=nemotron-3-super:cloud ^
  --nanum-cache=D:\repo\NanumPlayer\cache\tr_cache.jsonl ^
  --demuxer-readahead-secs=120 --demuxer-max-bytes=1500MiB --slang=kor
```
Blu-ray 복호화는 설치·활성화된 MakeMKV의 `libmmbd64.dll`을 사용합니다. 플레이어는 표준 설치 경로를 자동 탐색합니다. 앱 루트 또는 기존 `bin`에 직접 설치한 `libaacs.dll`/`libbdplus.dll`이나 `LIBAACS_PATH`/`LIBBDPLUS_PATH` 환경변수가 있으면 우선 사용합니다. 사용자 지정 MakeMKV 경로는 이 환경변수에 `.dll` 확장자를 뺀 절대 경로로 지정하세요(libbluray가 Windows에서 확장자를 붙입니다). 복호화 DLL은 재배포하지 않습니다.

### 옵션 (`--nanum-*`)

| 옵션 | 기본값 | 설명 |
|---|---|---|
| `nanum` | yes (앱 기본) | 기능 켜기; no이면 일반 재생만 |
| `nanum-stt-model`, `nanum-vad-model` | 앱/사용자 모델 경로 | 음성 인식에는 선택 언어 Whisper와 VAD 모두 필요 |
| `nanum-ai-dll` | 빈 값 (자동 관리) | 명시적 사용자 엔진 경로; 현재 백엔드 계약 필수 |
| `nanum-acceleration` | `auto` | `auto` / `cpu` / `cuda` 필수; 다음 파일부터 적용 |
| `nanum-language` | `auto` (앱 기본) | 입력 언어; 영어는 영어 모델, 그 외는 다국어 모델 |
| `nanum-translate-endpoint` | `http://127.0.0.1:11434` | Ollama 호환 `/api/generate`. 빈 값이면 번역 끔 |
| `nanum-translate-model` | `gemma4:latest` | 번역 모델 |
| `nanum-target-language` | `Korean` | 목표 언어 |
| `nanum-cache` | – | 번역 캐시(JSONL). 실패 결과는 저장하지 않음 |
| `nanum-test-subs` | no | 고정 테스트 자막 (개발용) |

선읽기(`demuxer-readahead-secs`)가 곧 자막 선행 시간입니다. 기본값(1초)이면 자막이 재생보다 늦게 도착합니다.
BD 최대 mux 48 Mbps 기준 120초 ≈ 720 MB 이므로 `demuxer-max-bytes`도 함께 올려야 합니다.
진단: `NANUM_AI_DEBUG=1`(VAD/STT/번역 로그), `NANUM_AI_VAD_THRESHOLD`(기본 0.25).

### 입력 소스와 전체 번역 모드

AI 자막의 원문은 **음성 인식(STT)** 또는 **텍스트 자막 트랙**(SRT/ASS/mov_text/WebVTT; 내장 또는 외부 파일)에서 옵니다. 이미지 자막(PGS 등)은 쓰지 않습니다. `scripts/nanum.lua`가 자동으로 고릅니다.

- 오디오 트랙 언어 L이 있으면 L 언어 텍스트 자막 → 없으면 STT (영어 자막만 있는 일본어 영화는 일본어 STT).
- L을 알 수 없으면 영어 → 일본어 → 스페인어 → 프랑스어 순으로 텍스트 자막, 없으면 STT. forced/해설 트랙은 제외.
- 재생 중 Ctrl+N 메뉴에서 입력 소스(자동/STT/특정 자막 트랙)를 바꿀 수 있습니다. 바꾸면 현재 위치에서 다시 시작합니다.
- 외부 자막 파일은 mpv가 언어를 알려 주지 않으면 파일명 접미사(`movie.en.srt`)로 언어를 추정합니다.

**전체 번역(`nanum-full=yes`, 메뉴에서 켜기)**: 재생 중 별도 디먹서/엔진이 원문 대본을 모읍니다. 원문을 SQLite에 먼저 저장한 뒤 용어집 + 60줄 창(5줄 겹침)으로 번역합니다. 완성 자막은 `nanum-full-dir`(기본 `%LOCALAPPDATA%\NanumPlayer\full`)에 `.ass`로 출력하며 `ko (AI full)` 트랙을 선택합니다. 다음 재생에는 저장본 사용·원문 재번역·음성 재인식·AI 끄기를 선택합니다. 저장본 자동 사용은 선택적으로 켤 수 있습니다.
전체 번역 엔진은 `nanum-full-engine=ollama`(기본, 라이브와 같은 서버/모델) 또는 `omp`(oh-my-pi; `nanum-omp-model`에 이미 로그인된 모델의 selector, 메뉴에서 `omp models --json` 목록으로 선택). 라이브 번역은 항상 Ollama입니다(omp는 호출당 수 초 걸려 부적합).

| 옵션 (런타임 변경 가능) | 기본값 | 설명 |
|---|---|---|
| `nanum-input` | stt | `stt` / `sub` |
| `nanum-sub-id`, `nanum-sub-file` | – | `sub` 입력의 트랙(`track-list`의 `src-id`) 또는 외부 자막 파일 |
| `nanum-full` | no | 전체 번역 켜기 |
| `nanum-full-dir` | `%LOCALAPPDATA%\NanumPlayer\full` | 결과 `.ass` 저장 위치 |
| `nanum-full-engine` | ollama | `ollama` / `omp` |
| `nanum-omp-model`, `nanum-omp-command` | –, `omp` | omp 모델 selector, 실행 파일 |

진행 상태는 `demuxer-cache-state`의 `nanum-full-state`(`off/scanning/translating/done/error`), `nanum-full-progress`, `nanum-full-file`, `nanum-full-error`, `nanum-input-active`로 노출되며 Ctrl+K에도 표시됩니다.
전체 번역은 읽기 위치를 하나 더 만들기 때문에 **광학 디스크에서는 재생과 같은 드라이브를 두 곳에서 읽어 서로 느려질 수 있습니다**(스캔은 시작 10초 뒤 시작하고 엔진보다 90초 이상 앞서가지 않도록 속도를 조절). 로컬 파일에서는 문제없습니다.

### 원어 음성 기반 자막·용어집·말투 (1.3.0)

- **두 자막 트랙**: 재생(또는 지정) 음성이 우선 입력, 원어 음성이 보조 입력입니다. 원어는 작품 제목(디스크 이름·제목 태그·파일명)과 음성 언어 목록을 번역 모델에 물어 판별하고, 판별하지 못하면 음성 언어가 정확히 둘일 때 재생 음성이 아닌 쪽을 씁니다. 보조 입력은 같은 디먹서 패킷을 쓰므로 디스크를 추가로 읽지 않으며, 우선 입력이 재생보다 30초 이상 앞서거나 쉴 때만 인식·번역합니다. 기본 선택은 재생 음성 기반이며 자막 메뉴에서 바꿉니다. 번역+원문 표시는 각 트랙의 원문을 보여 줍니다. Ctrl+N → **원어 음성으로도 자막 만들기**(`nanum-secondary`)로 끕니다.
- **영화별 저장**: 두 입력의 자막과 실제 분석한 시간 구간을 라이브러리에 저장합니다(스키마 v2, 이 DB는 1.2.x에서 열 수 없음). 다시 열면 저장된 자막을 바로 보여 주고 그 구간은 다시 분석하지 않으며 프리롤도 준비된 것으로 봅니다.
- **용어집**: 작품 식별과 함께 등장인물·지명·단체·고유 용어를 원어 표기, 영어/로마자 표기(두 이름 순서), 성·이름 단독 표기까지 하나의 한국어 표기로 맞춰 만듭니다. 실시간 번역에는 해당 줄에 나오는 항목과 주요 인물 목록을, 전체 번역에는 전체 용어집을 넣습니다. Ctrl+N → **용어집**에서 목록 보기, 항목 추가·수정·삭제, 메모장 일괄 편집, AI로 다시 만들기를 할 수 있습니다. 한 이름을 고치면 같은 인물의 성·이름·전체 이름 항목을 함께 고칠지 묻습니다. 수정하면 그 이름이 들어간 기존 자막(두 트랙, 저장본, 전체 번역)을 다시 번역해 바로 바꿉니다. 품질은 번역 모델에 따라 다르며 로컬 `gemma4`는 작품의 등장인물을 잘 모르면 항목을 지어낼 수 있으니 확인 후 고치세요.
- **번역 말투**(`nanum-translate-style`): 자연스럽게(기본, 인물 관계에 맞춰 존댓말/반말 유지) / 존댓말 / 반말 / 원문에 충실 / 직접 입력(`nanum-translate-style-text`). 바꾸면 이후 번역부터 바로 적용하며 캐시는 말투·용어집별로 구분합니다.
- 상태는 `demuxer-cache-state`의 `nanum-track-primary/secondary`(가상 트랙 src-id), `nanum-secondary-state/language/ready-until/reason`, `nanum-original-language`, `nanum-profile-state/work`, `nanum-glossary`, `nanum-glossary-count`, `nanum-glossary-apply-state/progress/changed/error`로 노출합니다. 용어집 변경은 `nanum-glossary-request=regenerate|file:<경로>`로 요청합니다.
- 같은 구간을 다시 분석(탐색·재동기화)해 생긴 겹치는 자막은 하나만 남기고, 더 완전한 문장이면 교체합니다. 한 트랙의 자막은 다음 자막 시작에서 끝나도록 표시해 두 줄로 겹치지 않습니다.
- 로컬 Ollama 모델이 한글을 `<0xED><0x9B><0xA0>` 같은 바이트 토큰으로 내보내면 UTF-8로 복원하고, 복원할 수 없는 줄은 번역 실패로 처리해 저장하지 않습니다. 기존 캐시의 깨진 줄도 읽을 때 복원합니다.

### 디스크 자막 OCR·온라인 자막 가져오기 (1.4.0)

- **디스크 이미지 자막(PGS)**: 같은 디먹서의 자막 패킷을 libavcodec으로 디코드해 흰 바탕 검은 글씨로 바꾸고, 작은 글씨는 확대해 Windows.Media.Ocr로 읽습니다(모델 번들 없음). 강제 자막이 아닌 영어 트랙을 우선 고릅니다. 영어 OCR 언어 팩이 없으면 설치된 라틴 문자 인식기(한국어 Windows의 `ko` 등)로 읽고, 흔한 오인식(`50`→`So`, `505`→`SOS`, `tO`→`to`, `TeII`→`Tell`, `donlt`→`don't` 등)을 교정합니다. Ctrl+N에서 **영어 OCR 언어 팩 설치(관리자 권한)**를 고르면 정확도가 높아집니다. 일본어 트랙은 일본어 팩이 필요합니다. 우선 입력 다음 순서로 처리하며 결과와 분석 구간을 영화별로 저장합니다. `nanum-pgs`로 끕니다.
- **온라인 자막**: Ctrl+N → **온라인 자막 찾기**에서 OpenSubtitles(영어·일본어·한국어) 또는 Jimaku(일본어 애니메이션)를 고르면 작품명으로 검색 페이지를 엽니다(Jimaku는 주소 검색을 지원하지 않아 홈을 열고 검색어를 클립보드에 복사). 사용자가 직접 내려받은 `.srt/.ass/.ssa/.vtt/.sub/.zip`을 다운로드 폴더(메뉴에서 변경 가능)에서 20분 동안 감시해 가져옵니다. **자막 파일 가져오기…**와 창에 끌어 놓기도 됩니다.
- **가져오기 처리**: 인코딩(UTF-8/UTF-16/CP949/Shift-JIS/CP1252)과 언어를 판별하고, 음성 인식 자막의 시작 시각과 비교해 오프셋(±240초)과 속도 배율(23.976/24/25 fps 변환)을 자동으로 맞춥니다. 신뢰도가 낮으면 맞추지 않고 알리며, **자막 시간 미세 조정**(±0.1/±1초)으로 고칠 수 있습니다. 한국어 자막은 그대로, 다른 언어는 말투·용어집을 적용해 전체 번역합니다. 새로 가져오면 이전 가져온 트랙을 대체하고 라이브러리에는 모두 남습니다.
- 상태: `nanum-track-pgs`, `nanum-pgs-state/language/reason/ready-until`, `nanum-track-import`, `nanum-import-state/progress/error/note/offset/scale/confidence/low-confidence/language/origin/lines`. 요청: `nanum-import-sub=<경로>|<언어>|<출처>`, `nanum-import-adjust=<초>`.

### 표시·입력 음성·저장 자막 (1.0.2)

- Ctrl+N → **자막 표시**: 번역만(기본) / 번역+원문 / 원문만. 라이브 및 완성 자막 모두 즉시 전환하며 STT·번역은 다시 돌리지 않습니다. 번역 실패 줄은 번역만 화면에 원문으로 대신 표시하지 않습니다.
- 재생 음성과 AI 입력 음성을 분리합니다. 다른 언어의 음성으로 바꾸면 기존 입력 유지(기본) / 새 음성 기준 생성 / 새 음성의 저장본 조회를 선택합니다. 기존 입력 유지 시 진행 중인 생성 작업도 유지합니다. 원어/더빙은 대사·시각이 달라 기존 자막이 맞지 않을 수 있습니다.
- `%LOCALAPPDATA%\NanumPlayer\library.sqlite`: 미디어, 입력 트랙, 원문 대본/시각, 번역본/모델/목표 언어 및 작업 상태를 저장합니다. SQLite WAL과 트랜잭션을 사용합니다. `nanum-library-db`로 위치를 변경할 수 있습니다.
- 원문 대본이 있으면 **저장된 원문으로 다시 번역**으로 디스크 읽기·STT를 생략합니다. 새 생성이 실패하거나 취소되면 이전 완성 번역은 유지합니다.
- 파일 식별은 크기 + SHA-256 콘텐츠 지문입니다. 16MiB 이하는 전체, 큰 파일은 양 끝 4MiB와 16개 256KiB 표본을 읽습니다. 표본 밖 수정은 탐지하지 못할 수 있습니다. 이동된 동일 파일은 재사용하며 경로만 같다는 이유로 재사용하지 않습니다.
- Blu-ray 식별은 libbluray의 디스크 ID·볼륨·선택 타이틀/플레이리스트·클립·트랙 정보입니다. 드라이브 문자만으로 재사용하지 않습니다. 식별할 수 없는 입력은 재사용을 거부하며 저장 실패는 오류로 알립니다. 구 URL 기반 ASS 파일은 자동으로 가져오지 않습니다.
- 현재 실행 파일은 DVD 재생 라이브러리 없이 빌드돼 `dvd://`를 지원하지 않습니다. DVD 트랙별 저장은 libdvdnav/libdvdread가 있는 빌드가 선행돼야 합니다. 일반 파일로 연 VOB는 파일 지문으로 식별합니다.

런타임 옵션: `nanum-display=translation|bilingual|source`, `nanum-audio-id=<입력 트랙 src-id>`, `nanum-library-action=ask|use|retranslate|regenerate|disable`, `nanum-library-auto-use=yes|no`. `demuxer-cache-state`의 `nanum-library-*` 필드에 저장본 유무·입력 언어·오류를 노출합니다.

## 검증된 것 (이 PC: RTX 3070 Ti, Pioneer BDR-UD03)

- STT: 영화 오디오 150초를 1.55초에 처리 (RTF ≈ 0.01), 시각은 컨테이너 절대 PTS.
- 실제 디스크(`bd://longest`, 300초 지점부터 150초 실시간 재생, 120초 선읽기): 이벤트 22개 전부 번역, 재생 60초 이후 구간 16/16이 재생보다 먼저 도착 (선행 중앙값 ≈ 100초), 재생 중 `sub-text`에 한/영 자막 표시 확인.
- 번역 서버가 죽어 있어도 지연 2.4초, 실패는 캐시하지 않음.
- 재생 음성과 AI 입력 분리: 재생 음성을 다른 트랙으로 바꿔도 고정된 영어 AI 입력과 자막 생성이 유지됨. 새 음성으로 만들려면 별도 생성 선택이 필요합니다.
- 전체 번역 (`film_150s.wav`, 로컬): 스캔→번역→저장→`ko (AI full)` 자동 적용까지 약 10초. Ollama(`nemotron-3-super:cloud`)와 omp(`anthropic/claude-haiku-4-5`) 모두 확인. 영어 SRT(40컷) 번역: Ollama 7~9초, omp 12초. 종료 시 스캔 중 10/10 정상 종료.
- 1.1.0 실제 Blu-ray 탐색: 300 → 4500 → 900 → 4500 → 같은 4500 → 4504 → -6초 모두 한국어 `sub-text` 확인. TrueHD 스트림 하나만 분석하고 디코더 초기화는 최초 1회, 스트림 파라미터 경고는 0회. 파일 캐시 탐색 8 → 15 → 8 → 8 → 12 → -6초도 정확한 착지·한국어 자막 확인 (`tools/nanum_seek_smoke.py`).
- 모델 없이 설치, 설치 중 VAD 실제 다운로드 및 검증·재사용, 제거 후 모델 유지 확인. 설정 메뉴에서 Whisper 두 모델+VAD 실제 다운로드·취소·진행률, 완료 후 같은 프로세스에서 다음 파일의 한국어 자막 확인. 잘못된 SHA-256 및 HTTP 404는 오류로 끝나며 기존 정상 파일을 보존하고 임시 파일을 제거함. 영어 모델+VAD만 설치한 언어 태그 없는 WAV도 한국어 자막 확인.
- 1.2.0: CUDA 파일 없는 배포본에서 CPU 한국어 자막, 다운로드한 CUDA 엔진+cuBLAS로 CUDA 한국어 자막, 기존 CUDA 13 Toolkit을 재사용해 엔진 52.6 MiB만 다운로드한 CUDA 한국어 자막을 확인했습니다. 공개 GitHub 자산의 실제 다운로드·취소·재개 및 세 파일의 크기/SHA-256 일치, 모델 누락·CUDA 필수 미설치 시 AI 준비 대기 없는 일반 재생, 설정의 진행률·라이선스·진단 토글을 확인했습니다.
- AI를 끈 실제 E: 디스크에서도 `ReadFile` CRC 오류 23(약 21초 대기)과 Windows `cdrom` 이벤트 7을 수집했습니다. 플레이어·AI·libbluray·MakeMKV 없이 같은 오프셋을 직접 읽어도 CRC 오류 23과 27초 대기를 확인했습니다. 파일 읽기 성공 후 AACS 복호화 실패도 별도로 기록됩니다.
- 1.2.0 설치: 기본 선택 다운로드 없음·오프라인 CPU 설치, GUI의 CUDA 라이선스 동의·Toolkit 재사용·실제 엔진 다운로드, 무인 CUDA/VAD 선택의 검증된 캐시 재사용을 확인했습니다. 요청한 URL이 HTTP 404이면 설치 전 종료 코드 7로 중단하며, 제거 후 모델 세 파일과 CUDA 캐시가 유지됩니다. GPU→CPU 다음 파일 전환 직후 종료는 수정 후 4/4 정상 종료했습니다. 설치된 플레이어로 실제 디스크 300 → 4500 → 900초 탐색은 한국어 자막·TrueHD 입력 하나·스트림 경고 0개로 통과했습니다.
- 1.2.1: 음성 모델과 CUDA가 없는 CUDA 필수 설정에서도 영어 SRT의 한국어 표시, 음성 입력의 모델 누락 안내, 텍스트 입력 복귀, 전체 텍스트 번역·저장 및 정상 종료를 실제 플레이어에서 확인했습니다. 번역 전용 실시간 이벤트 누락은 회귀 테스트에서 수정 전 실패·수정 후 통과했습니다.
- 1.2.1 추가: 두 컷 외부 자막의 기본 30초 프리롤이 전체 번역 완료 후 즉시 해제되고, 모델·CUDA 없는 실제 영상 창에 한국어가 렌더링됨을 확인했습니다. 공개 1.2.1 엔진 다운로드·SHA-256 일치·Toolkit 재사용, 버퍼링된 오디오로 CPU 텍스트→CUDA 음성→CPU 텍스트 두 차례 전환 및 정상 종료, 70초 지점의 실제 음성 인식 한국어 자막을 확인했습니다.
- 1.2.1 최종 설치: 패키저가 자산 목록의 버전을 설치 파일에 전달하며 무인 CUDA 선택 설치가 실제 `cuda/1.2.1` 캐시를 만들고 SHA-256이 일치했습니다. 설치된 플레이어의 CUDA 음성 한국어 자막·정상 종료, 제거 후 CUDA 캐시 유지, CUDA 없는 배포본의 CPU 음성 한국어 자막도 확인했습니다.
- 1.3.0 (실제 E: 디스크, CUDA, `nemotron-3-super:cloud`): 440초부터 재생 시 `한국어 (영어 음성 기반)`·`한국어 (일본어 음성 기반)` 두 트랙이 모두 438.5초부터 분석·저장되고 일본어 기반이 영어 기반을 따라잡았습니다. 작품 `The Disappearance of Haruhi Suzumiya`·원어 `ja`·용어집 64개, 일본어 장문 대사는 최장 3.9초·26자로 나뉘고 화면 두 줄 겹침 0회였습니다. 다시 열면 저장본으로 15초 만에 473초까지 준비됐습니다. 디스크 오디오의 뒤로 탐색 반복(`120,rel-7,rel-11,rel-5`)에서 저장 자막 겹침 0쌍, 메뉴에서 `小泉 => 코이즈미` 추가 시 기존 자막 `소이즈`가 `코이즈미`로 재번역·저장됐습니다. 사용자 캐시의 `<0xHH>` 3줄은 번역 서버 없이 `눈치챘네`·`훠궈`로 복원 표시됐습니다. 설치(선택 다운로드 없음)·실행·제거와 1.3.0 CUDA 엔진·large-v3-turbo 실제 다운로드 SHA-256 일치를 확인했습니다.

## 알려진 한계

- 검증 디스크의 중간 지점 이후에서 AI를 꺼도 Windows CRC 읽기 오류와 `cdrom` 이벤트 7이 관측됐습니다. 실제 I/O 지연이며 AI 준비 문제와 별개입니다. 디스크·드라이브·연결 경로 중 단일 원인은 아직 구분되지 않았으며 복호화 실패도 함께 발생합니다.
- **로컬 번역 모델**: `gemma4:latest`(12.8 GB)는 8 GB VRAM에 일부만 올라가 whisper/mpv와 동시에 돌면 타임아웃. 4 GB급 `lcp-qwen35-4b-q4km:latest`(2.7 GB)는 영화 오디오 150초에서 24/24줄 번역, 마지막 줄 지연 12초(`nanum_ai_test`)로 실시간 사용 가능하나 일부 단어가 미번역(고유명사·감탄사)으로 남는 등 품질은 클라우드 모델(`nemotron-3-super:cloud`, 배치당 ~1초)보다 낮음. `--nanum-translate-model`로 선택. `gemma4`는 작품 식별·용어집 생성에서 등장인물을 지어내거나 잘못 들은 이름(`Korsumi` 등)을 용어집 표기로 고치지 못하는 경우가 있어, 용어집 품질은 클라우드 모델이 훨씬 좋습니다. AI가 만든 표기(예: `Kyon => 키온`)는 메뉴에서 확인 후 고치세요.
- 재생 중 **원어 음성으로도 자막 만들기**를 새로 켜면 이미 미리 읽은 구간(약 2분)은 건너뛰고 그 뒤부터 분석합니다. 건너뛴 구간은 탐색으로 다시 읽을 때 분석됩니다.
- 한국어 OCR 인식기로 영문 이미지 자막을 읽으면 교정 후에도 일부 단어를 잘못 읽습니다(예: `cold`→`00년`). 영어 OCR 언어 팩을 설치하면 좋아집니다. 사이트 자막은 판본에 따라 대사·편집이 달라 시간 자동 맞춤의 신뢰도가 낮을 수 있습니다.
- 번역 서버(Ollama, `ollama serve`)가 꺼져 있으면 `transport error`로 번역이 전부 실패하고 프리롤이 timeout(90초)까지 대기함. 실행 전에 서버를 띄워야 함.
- 프리롤은 `scripts/nanum.lua`(`--script=`)가 담당: 시작 시 `preroll`(30초), 탐색 후 `seek_preroll`(8초)만큼 자막이 준비될 때까지 재생을 멈춤. 스크립트 없이는 시작 직후 약 20초 자막이 늦음.
- 긴 발화(최대 15초)는 `split.h`가 문장 끝에서 나눠 시간을 글자 수로 배분함 (`nanum_ai_test --selftest`로 검증).
- 다국어 small 모델의 일본어 인식은 부정확합니다. Whisper large-v3-turbo(선택 다운로드)를 받으면 크게 좋아지지만 GPU 메모리를 더 쓰므로 8 GB GPU에서 로컬 번역 모델과 함께 쓰면 느려질 수 있습니다.
- 종료 시 `0xC0000005`가 150초 실디스크 측정 1회에서 관찰됨. 이후 재측정, 종료 스트레스(총 45회 이상), 실디스크 phase3 검증 2회에서는 재현되지 않음. 원인 미확정. 재발하면 `%LOCALAPPDATA%\NanumPlayer\dumps`에 미니덤프가 자동 저장되므로 `cdb -z <dmp> -c ".ecxr;k"`로 분석할 수 있음 (`NANUM_CRASH_TEST=1`로 경로 확인 가능).
- 설정 UI는 `scripts/nanum.lua`의 메뉴(Ctrl+n)입니다. `~~/script-opts/nanum.conf`에 저장됩니다. **번역 모델**은 번역 서버의 `/api/tags` 목록(로컬 모델은 크기·파라미터 수 표시, 클라우드 모델 구분)에서 고르며, 서버에 연결할 수 없거나 목록에 없는 모델은 직접 입력합니다. 번역 모델·서버·목표 언어는 다음에 여는 파일부터, 말투·원어 자막·용어집은 즉시 적용됩니다. 그 외 엔진 옵션(모델 경로 등)은 `mpv.conf`로 설정합니다.

## 개발 환경 (LSP)

`.omp/lsp.json`이 `clangd`(MSYS2 CLANG64)를 지정하고, 폴더별 `.clangd`가 컴파일 DB를 고릅니다.

| 영역 | 컴파일 DB | 생성 |
|---|---|---|
| `third_party/mpv` (C) | `third_party/mpv/build/compile_commands.json` | `meson setup` |
| `nanum_ai` (C++, MSVC) | `build/nanum_ai_cpu/compile_commands.json` | `tools\build_nanum_ai.bat cpu` (CUDA 빌드는 `build/nanum_ai_cuda`) |

`nanum_ai/.clangd`는 vcvars 환경 없이 clangd가 MSVC 헤더를 찾도록 `/imsvc` 경로를 명시합니다. MSVC/SDK 버전을 바꾸면 갱신하세요.
