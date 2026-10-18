# Terminology glossary (English ↔ Korean)

NanumPlayer's user-facing text exists in six interface languages: Korean (the source language of every
string), English, Spanish, Japanese, Simplified Chinese and Traditional Chinese. The documentation is
written in English (primary) and Korean. This page fixes the terms used across the player, the
installer, the documentation and the project website so that the two documentation languages and the
interface stay consistent.

Rules of thumb:

- The **English term is the label shown in the English interface** (taken from `locales/*.json`).
  Quote menu paths exactly as the interface shows them, for example **Ctrl+N → Video upscale**.
- The **Korean term is the label shown in the Korean interface**.
- Write the product name as **NanumPlayer** in every language; it is never transliterated.
- Keep file names, command-line options, property names and key names in `code` formatting and untranslated.

## Product and playback

| English | Korean | Notes |
|---|---|---|
| NanumPlayer | NanumPlayer | Product name; never transliterated. |
| player | 플레이어 | |
| start screen | 시작 화면 | The card screen shown when nothing is playing. |
| playback bar | 재생 바 | The auto-hiding control bar. |
| portable ZIP / portable folder | 포터블 ZIP / 포터블 폴더 | Runs without installing. |
| installer / setup | 설치 파일 | `NanumPlayer-Setup-<version>.exe`. |
| settings folder | 설정 폴더 | `%APPDATA%\NanumPlayer`. |
| interface language | 인터페이스 언어 | Language of menus and dialogs. Independent of the speech and subtitle languages. |
| Automatic (interface language) | 자동 | Follows the Windows display language. |
| web session (InPrivate) | 웹 세션 (InPrivate) | YouTube and web windows. Not anonymisation. |

## AI subtitles

| English | Korean | Notes |
|---|---|---|
| AI subtitles | AI 자막 | Subtitles made while playing. |
| speech recognition (STT) | 음성 인식 (STT) | Whisper. |
| voice detection (VAD) | 음성 감지 (VAD) | Silero VAD. The interface lists the model file as "VAD". |
| translation server | 번역 서버 | An Ollama-compatible server (local or Ollama cloud). |
| translation model | 번역 모델 | The model that translates, chosen from the server's list. |
| translation target language | 번역 목표 언어 | Defaults to the Windows display language. |
| input source | 입력 소스 | Speech recognition or a text subtitle track. |
| playing audio | 재생 음성 | The audio track you hear. |
| AI input audio | AI 입력 음성 | The audio track recognition reads. May differ from the playing audio. |
| original-language audio | 원어 음성 | The film's original dialogue language. Secondary AI input. |
| subtitles based on … audio | … 음성 기반 자막 | Track name, e.g. "Korean (based on English audio)". |
| translation only / translation + original / original only | 번역만 / 번역+원문 / 원문만 | Display modes of AI subtitles. |
| full translation | 전체 번역 | Whole-transcript translation by a separate reader. |
| full translation engine | 전체 번역 엔진 | Ollama (default) or omp. |
| preroll | 프리롤 | Wait at the start of a file until subtitles are ready ahead of playback. |
| read-ahead | 선읽기 | Demuxer read-ahead; it is also the subtitle lead time. |
| glossary | 용어집 | Per-work list of character and proper-name translations. |
| translation style | 번역 말투 | Natural / Polite / Casual / Faithful to the original / Custom. |
| acceleration mode (Auto / CPU / CUDA required) | 가속 모드 (자동 / CPU / CUDA 필수) | |
| AI component manager | AI 구성 요소 관리 | Downloads speech models, VAD, cuBLAS. |
| speech model (Whisper) | 음성 모델 (Whisper) | English, Multilingual, Multilingual (high accuracy) = 영어, 다국어, 다국어 고정밀. |

## Subtitle list and sources

| English | Korean | Notes |
|---|---|---|
| subtitle list | 자막 목록 | One list for every source. |
| source badge | 출처 배지 | |
| `[AI]` | `[AI]` | Translation to the target language by AI. |
| `[Original]` | `[원본 자막]` | Subtitle from the disc, file or YouTube uploader, shown as is. |
| `[File]` | `[파일]` | Subtitle file next to the video, or one you loaded. |
| `[OCR]` | `[OCR]` | Disc image subtitle read by text recognition. |
| text recognition (OCR) | 문자 인식 (OCR) | Windows OCR. |
| image subtitle (PGS) | 이미지 자막 (PGS) | |
| import a subtitle file | 자막 파일 가져오기 | Also by drag and drop. |
| show as is | 그대로 표시 | Import without translation. |
| align timing with AI and translate | AI로 시간 맞추고 번역 | Import with translation. |
| find online subtitles | 온라인 자막 찾기 | OpenSubtitles, Jimaku; you download in the browser. |
| subtitle timing adjustment | 자막 시간 미세 조정 | ±0.1 s / ±1 s. |
| generate full subtitles | 전체 자막 생성 | Whole-file SRT generation without playback. Window: "Create subtitle files" (자막 파일 만들기). |

## Video

| English | Korean | Notes |
|---|---|---|
| video upscale | 영상 업스케일 | **Ctrl+N → Video upscale**. |
| high-quality scaling | 고품질 크기 조정 | `ewa_lanczossharp`. Not AI. |
| NVIDIA RTX upscaling (RTX Video Super Resolution) | NVIDIA RTX 업스케일 (RTX Video Super Resolution) | Needs a supported NVIDIA GPU and driver. |
| user shaders | 사용자 셰이더 | mpv-compatible `.glsl`, `.hook`, `.frag`. |
| picture quality | 영상 화질 | **Ctrl+N → Picture quality**. Built-in correction presets. |
| Original / Sharper anime / Smoother old anime / Compressed video repair | 원본 / 애니 선명하게 / 옛날 애니 부드럽게 / 압축 영상 보정 | Presets. |
| noise reduction / debanding / line enhancement / sharpening / color correction | 노이즈 줄이기 / 색 띠 완화 / 선 강조 / 선명도 / 색 보정 | Each: Off / Weak / Medium / Strong (끔 / 약함 / 중간 / 강함). |
| compare before correction | 보정 전 화면 비교 | Temporary, not saved. |

## Web, discs and privacy

| English | Korean | Notes |
|---|---|---|
| play from a web page | 웹페이지에서 재생하기 | Start-screen button (Ctrl+Shift+Y). |
| Play in NanumPlayer | NanumPlayer에서 재생 | Button of the built-in web window. |
| Blu-ray/DVD decryption components (optional) | Blu-ray/DVD 복호화 구성 요소 (선택) | Separate download, menu entry in **Ctrl+N**; see [disc-components.md](disc-components.md). |
| Blu-ray / DVD | Blu-ray / DVD | |
| save disc (lossless MKV) | 디스크 저장 (무손실 MKV) | **Ctrl+B**. |
| diagnostic log (detailed disc reads) | 진단 로그 (디스크 읽기 상세) | Off by default. |
| private by default | 기본 비공개 | No playback history, logs or caches are kept by default. |
| code signing / SmartScreen | 코드 서명 / SmartScreen | |

## Keyboard shortcuts

| Keys | English | Korean |
|---|---|---|
| Ctrl+N | AI subtitle settings (main menu) | AI 자막 설정 (주 메뉴) |
| Ctrl+K | AI subtitle status | AI 자막 상태 |
| Ctrl+O | Open file | 파일 열기 |
| Ctrl+D | Open Blu-ray | Blu-ray 열기 |
| Ctrl+A | Audio track | 음성 트랙 |
| Ctrl+T | Subtitle track | 자막 트랙 |
| Ctrl+B | Save disc | 디스크 저장 |
| Ctrl+Y | YouTube | YouTube |
| Ctrl+Shift+Y | Play from a web page | 웹페이지에서 재생하기 |
| Ctrl+Alt+L | Interface language | 인터페이스 언어 |
