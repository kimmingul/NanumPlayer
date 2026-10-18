# 참조: 옵션, 속성, 명령

[English](../reference.md) · 한국어

NanumPlayer는 mpv에 기능을 더한 것이므로 mpv의 모든 옵션, 명령, 속성도 그대로 동작합니다. 이 문서는
NanumPlayer 전용 항목을 정리합니다. 설정 우선순위: 기본값 < 사용자 설정(`%APPDATA%\NanumPlayer`)
< 명령줄.

목차: [옵션](#옵션---nanum-) · [선읽기](#선읽기) · [전체 번역 옵션](#전체-번역-옵션) ·
[원어 음성, 용어집, 말투](#원어-음성-용어집-말투) ·
[화면 표시, 입력 음성, 저장된 자막](#화면-표시-입력-음성-저장된-자막) · [가져오기와 OCR](#가져오기와-ocr) ·
[자막 파일 생성](#자막-파일-생성) · [진단과 환경 변수](#진단과-환경-변수)

## 옵션 (`--nanum-*`)

| 옵션 | 기본값 | 설명 |
|---|---|---|
| `nanum` | yes (앱 기본값) | 기능을 켭니다. `no`이면 일반 재생만 합니다. |
| `nanum-stt-model`, `nanum-vad-model` | 앱/사용자 모델 경로 | 음성 인식에는 선택 언어의 Whisper 모델 **과** VAD 모델이 모두 필요합니다. |
| `nanum-ai-dll` | 비어 있음 (자동 관리) | 사용자가 명시하는 엔진 경로입니다. 현재 백엔드 계약(`NANUM_AI_ABI_VERSION`)을 만족해야 합니다. |
| `nanum-acceleration` | `auto` | `auto`, `cpu`, `cuda`(필수). 다음 파일부터 적용됩니다. |
| `nanum-language` | `auto` (앱 기본값) | 입력 언어. 영어는 영어 모델, 그 외는 다국어 모델을 사용합니다. |
| `nanum-translate-endpoint` | `http://127.0.0.1:11434` | Ollama 호환 `/api/generate`. 비워 두면 번역을 끕니다. |
| `nanum-translate-model` | `gemma4:latest` | 번역 모델. |
| `nanum-target-language` | Windows 표시 언어 (예: `Korean`) | 번역 목표 언어: **Ctrl+N → 번역 목표 언어**의 33개 언어 또는 직접 입력한 이름. 원본 언어와 같으면 번역하지 않습니다. |
| `nanum-cache` | – (저장 안 함) | 로컬 미디어용으로 명시하는 번역 캐시(JSONL). 웹 미디어에는 사용하지 않습니다. |
| `nanum-test-subs` | no | 고정 테스트 자막(개발용). |
| `nanum-ui-language` | `auto` | `auto`, `ko`, `en`, `ja`, `zh-CN`, `zh-TW`, `es`. 이번 실행에 한해 저장된 선택보다 우선합니다. |
| `nanum-library-db` | – (꺼짐) | 이 경로에 로컬 미디어용 영화별 영구 라이브러리를 켭니다. |
| `nanum-pgs` | yes | 이미지 자막 OCR. `no`이면 끕니다. |
| `nanum-secondary` | yes | 원어 음성으로도 자막을 만듭니다. |

## 선읽기

디먹서 선읽기(`demuxer-readahead-secs`)가 곧 자막 선행 시간입니다. 기본값(1초)이면 자막이 화면보다
늦게 도착합니다. 디스크에는 예를 들어 다음을 사용하세요.

```
--demuxer-readahead-secs=120 --demuxer-max-bytes=1500MiB
```

최대 48 Mbit/s의 Blu-ray 먹스에서 120초는 약 720 MB이므로 `demuxer-max-bytes`도 함께 올리세요.

`E:`의 Blu-ray를 재생하는 명령줄 예시입니다(디스크가 암호화되어 있으면 선택 디스크 구성 요소를 설치해야
합니다).

```bat
NanumPlayer.exe bd://longest --bluray-device=E: --nanum ^
  --nanum-acceleration=auto ^
  --nanum-stt-model=D:\models\ggml-small.en.bin ^
  --nanum-vad-model=D:\models\ggml-silero-v5.1.2.bin ^
  --nanum-translate-model=<your model> ^
  --demuxer-readahead-secs=120 --demuxer-max-bytes=1500MiB --slang=kor
```

필요한 모델 파일: `ggml-small.en.bin`(영어 Whisper), `ggml-small.bin`(다국어, `--nanum-stt-model-multilingual`로
선택), `ggml-silero-v5.1.2.bin`(VAD). 배포본은 기본적으로 `%LOCALAPPDATA%\NanumPlayer\models`에서
찾습니다.

## 전체 번역 옵션

실행 중에 바꿀 수 있습니다.

| 옵션 | 기본값 | 설명 |
|---|---|---|
| `nanum-input` | `stt` | `stt` 또는 `sub`. |
| `nanum-sub-id`, `nanum-sub-file` | – | `sub` 입력용: 트랙(`track-list`의 `src-id`) 또는 외부 자막 파일. |
| `nanum-full` | no | 전체 번역을 켭니다. |
| `nanum-full-dir` | 세션 임시 폴더 | 로컬 미디어의 결과 `.ass`를 저장할 위치를 명시적으로 선택합니다. 웹 미디어는 항상 임시 폴더를 사용합니다. |
| `nanum-full-engine` | `ollama` | `ollama` 또는 `omp`. |
| `nanum-omp-model`, `nanum-omp-command` | –, `omp` | omp 모델 선택자와 실행 파일. |

상태 속성(`demuxer-cache-state` 안): `nanum-full-state`(`off/scanning/translating/done/error`),
`nanum-full-progress`, `nanum-full-file`, `nanum-full-error`, `nanum-input-active`. **Ctrl+K**에서도
확인할 수 있습니다.

## 원어 음성, 용어집, 말투

| 옵션 | 설명 |
|---|---|
| `nanum-secondary` | 원어 음성으로 두 번째 자막 트랙을 만듭니다(기본 yes). |
| `nanum-translate-style` | `natural`(기본), `polite`, `casual`, `literal`(원문에 가깝게), `custom`(`nanum-translate-style-text`에 쓴 사용자 문구). 이후의 번역에 적용되며 캐시는 말투와 용어집별로 유지됩니다. |

속성: `nanum-track-primary`, `nanum-track-secondary`(가상 트랙 `src-id`),
`nanum-secondary-state`, `-language`, `-ready-until`, `-reason`, `nanum-original-language`,
`nanum-profile-state`, `nanum-profile-work`, `nanum-glossary`, `nanum-glossary-count`,
`nanum-glossary-apply-state`, `-progress`, `-changed`, `-error`는 모두 `demuxer-cache-state`에 있습니다.
용어집 변경은 `nanum-glossary-request=regenerate` 또는 `nanum-glossary-request=file:<path>`로
요청합니다.

## 화면 표시, 입력 음성, 저장된 자막

실행 중 옵션: `nanum-display=translation|bilingual|source`, `nanum-audio-id=<input track src-id>`,
`nanum-library-action=ask|use|retranslate|regenerate|disable`, `nanum-library-auto-use=yes|no`.
`demuxer-cache-state`의 `nanum-library-*` 필드는 저장된 사본의 존재 여부, 입력 언어, 오류를 알려 줍니다.

## 가져오기와 OCR

속성: `nanum-track-pgs`, `nanum-pgs-state`, `-language`, `-reason`, `-ready-until`,
`nanum-track-import`, `nanum-import-state`, `-progress`, `-error`, `-note`, `-offset`, `-scale`,
`-confidence`, `-low-confidence`, `-language`, `-origin`, `-lines`.

요청: `nanum-import-sub=<path>|<language>|<origin>`, `nanum-import-adjust=<seconds>`.

## 자막 파일 생성

- 명령: `nanum-generate <JSON>`(중단 가능). 요청과 결과의 형식은
  `third_party/mpv/osdep/nanum-generate.h`에 정의되어 있습니다.
- 속성 `user-data/nanum/generate`: `status`, `progress`, `position`, `duration`, `target`,
  `outputs[]`, `error` 등.
- 스크립트 메시지: `nanum-generate-start <json>`, `nanum-generate-cancel`, `nanum-generate-open`;
  스크립트 바인딩 `nanum/nanum-generate`.
- 디스크 저장에는 스크립트 메시지 `nanum-rip`과 속성 `user-data/nanum/rip`이 있습니다.

## 진단과 환경 변수

| 이름 | 효과 |
|---|---|
| `nanum-diagnostics on\|off\|toggle` (IPC 명령) | 디스크 읽기 상세 로그. [문제 해결](troubleshooting.md#디스크-읽기와-탐색-진단)을 참고하세요. |
| `NANUMPLAYER_DIAGNOSTICS=1` | 같은 기능을 시작할 때부터 켭니다. |
| `NANUMPLAYER_CRASH_DUMP_DIR` | 해당 폴더에 충돌 덤프를 켭니다. 덤프에는 비밀 정보가 포함될 수 있습니다. |
| `NANUM_AI_DEBUG=1` | VAD, 음성 인식, 번역 로그. |
| `NANUM_AI_VAD_THRESHOLD` | VAD 임계값(기본 0.25). |
| `user-data/nanum/app-version` | 애플리케이션 버전 속성. |

**Ctrl+N** 메뉴의 실행 중 설정은 `~~/script-opts/nanum.conf`에 저장됩니다. 모델 경로 같은 엔진 옵션은
`mpv.conf`에 둡니다.
