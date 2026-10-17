; NanumPlayer setup/uninstaller custom messages (Korean, English, Japanese, Simplified and
; Traditional Chinese, Spanish). Included by installer.iss; the standard wizard texts come from
; the Inno Setup .isl files. %n = line break, %1/%2 = arguments (FmtMessage).
[CustomMessages]
korean.GroupModels=AI 모델 다운로드 (선택, 인터넷 연결 필요):
english.GroupModels=AI model downloads (optional, internet connection required):
japanese.GroupModels=AI モデルのダウンロード (任意、インターネット接続が必要):
chinesesimplified.GroupModels=AI 模型下载（可选，需要联网）：
chinesetraditional.GroupModels=AI 模型下載（選用，需要網際網路連線）：
spanish.GroupModels=Descarga de modelos de IA (opcional, requiere conexión a Internet):

korean.GroupAccel=AI 가속 (선택, 인터넷 연결 필요):
english.GroupAccel=AI acceleration (optional, internet connection required):
japanese.GroupAccel=AI アクセラレーション (任意、インターネット接続が必要):
chinesesimplified.GroupAccel=AI 加速（可选，需要联网）：
chinesetraditional.GroupAccel=AI 加速（選用，需要網際網路連線）：
spanish.GroupAccel=Aceleración de IA (opcional, requiere conexión a Internet):

korean.GroupYoutube=YouTube (선택, 인터넷 연결 필요):
english.GroupYoutube=YouTube (optional, internet connection required):
japanese.GroupYoutube=YouTube (任意、インターネット接続が必要):
chinesesimplified.GroupYoutube=YouTube（可选，需要联网）：
chinesetraditional.GroupYoutube=YouTube（選用，需要網際網路連線）：
spanish.GroupYoutube=YouTube (opcional, requiere conexión a Internet):

korean.TaskModelEnglish=영어 음성 인식: Whisper small.en + Silero VAD (약 466 MiB 다운로드)
english.TaskModelEnglish=English speech recognition: Whisper small.en + Silero VAD (about 466 MiB download)
japanese.TaskModelEnglish=英語の音声認識: Whisper small.en + Silero VAD (約 466 MiB をダウンロード)
chinesesimplified.TaskModelEnglish=英语语音识别：Whisper small.en + Silero VAD（下载约 466 MiB）
chinesetraditional.TaskModelEnglish=英語語音辨識：Whisper small.en + Silero VAD（下載約 466 MiB）
spanish.TaskModelEnglish=Reconocimiento de voz en inglés: Whisper small.en + Silero VAD (descarga de unos 466 MiB)

korean.TaskModelMultilingual=다국어 음성 인식: Whisper small + Silero VAD (약 466 MiB 다운로드)
english.TaskModelMultilingual=Multilingual speech recognition: Whisper small + Silero VAD (about 466 MiB download)
japanese.TaskModelMultilingual=多言語の音声認識: Whisper small + Silero VAD (約 466 MiB をダウンロード)
chinesesimplified.TaskModelMultilingual=多语言语音识别：Whisper small + Silero VAD（下载约 466 MiB）
chinesetraditional.TaskModelMultilingual=多語言語音辨識：Whisper small + Silero VAD（下載約 466 MiB）
spanish.TaskModelMultilingual=Reconocimiento de voz multilingüe: Whisper small + Silero VAD (descarga de unos 466 MiB)

korean.TaskModelLarge=다국어 고정밀 음성 인식: Whisper large-v3-turbo + Silero VAD (약 548 MiB 다운로드, 외국어 영상 권장)
english.TaskModelLarge=High-accuracy multilingual speech recognition: Whisper large-v3-turbo + Silero VAD (about 548 MiB download, recommended for foreign-language videos)
japanese.TaskModelLarge=多言語の高精度音声認識: Whisper large-v3-turbo + Silero VAD (約 548 MiB をダウンロード、外国語の動画に推奨)
chinesesimplified.TaskModelLarge=多语言高精度语音识别：Whisper large-v3-turbo + Silero VAD（下载约 548 MiB，推荐用于外语视频）
chinesetraditional.TaskModelLarge=多語言高精確度語音辨識：Whisper large-v3-turbo + Silero VAD（下載約 548 MiB，建議用於外語影片）
spanish.TaskModelLarge=Reconocimiento de voz multilingüe de alta precisión: Whisper large-v3-turbo + Silero VAD (descarga de unos 548 MiB, recomendado para vídeos en otros idiomas)

korean.TaskModelVad=음성 감지 모델만: Silero VAD (약 0.8 MiB 다운로드)
english.TaskModelVad=Voice detection model only: Silero VAD (about 0.8 MiB download)
japanese.TaskModelVad=音声検出モデルのみ: Silero VAD (約 0.8 MiB をダウンロード)
chinesesimplified.TaskModelVad=仅语音检测模型：Silero VAD（下载约 0.8 MiB）
chinesetraditional.TaskModelVad=僅語音偵測模型：Silero VAD（下載約 0.8 MiB）
spanish.TaskModelVad=Solo el modelo de detección de voz: Silero VAD (descarga de unos 0,8 MiB)

korean.TaskCuda=NVIDIA CUDA 가속: cuBLAS 받기 (CUDA 엔진은 설치에 포함됨; CUDA 13 Toolkit이 없을 때만 약 507 MiB 다운로드)
english.TaskCuda=NVIDIA CUDA acceleration: get cuBLAS (the CUDA engine is included in the installation; about 507 MiB is downloaded only if the CUDA 13 Toolkit is missing)
japanese.TaskCuda=NVIDIA CUDA アクセラレーション: cuBLAS を取得 (CUDA エンジンはインストールに含まれます。CUDA 13 Toolkit がない場合のみ約 507 MiB をダウンロード)
chinesesimplified.TaskCuda=NVIDIA CUDA 加速：获取 cuBLAS（CUDA 引擎已包含在安装中；仅在没有 CUDA 13 Toolkit 时下载约 507 MiB）
chinesetraditional.TaskCuda=NVIDIA CUDA 加速：取得 cuBLAS（CUDA 引擎已包含在安裝中；僅在沒有 CUDA 13 Toolkit 時下載約 507 MiB）
spanish.TaskCuda=Aceleración NVIDIA CUDA: obtener cuBLAS (el motor CUDA está incluido en la instalación; solo se descargan unos 507 MiB si falta el CUDA 13 Toolkit)

korean.TaskYoutube=YouTube 재생 구성 요소: yt-dlp + Deno (약 60 MiB 다운로드, 설치 시점의 최신 공식 릴리스)
english.TaskYoutube=YouTube playback components: yt-dlp + Deno (about 60 MiB download, latest official releases at install time)
japanese.TaskYoutube=YouTube 再生コンポーネント: yt-dlp + Deno (約 60 MiB をダウンロード、インストール時点の最新公式リリース)
chinesesimplified.TaskYoutube=YouTube 播放组件：yt-dlp + Deno（下载约 60 MiB，安装时的最新官方版本）
chinesetraditional.TaskYoutube=YouTube 播放元件：yt-dlp + Deno（下載約 60 MiB，安裝時的最新官方版本）
spanish.TaskYoutube=Componentes de reproducción de YouTube: yt-dlp + Deno (descarga de unos 60 MiB, últimas versiones oficiales en el momento de la instalación)

korean.NoteInstalled=— 이미 설치됨
english.NoteInstalled=- already installed
japanese.NoteInstalled=— インストール済み
chinesesimplified.NoteInstalled=— 已安装
chinesetraditional.NoteInstalled=— 已安裝
spanish.NoteInstalled=— ya instalado

korean.NoteToolkit=— 엔진은 설치에 포함, CUDA Toolkit v%1 사용 (내려받기 없음)
english.NoteToolkit=- engine included in the installation, using CUDA Toolkit v%1 (no download)
japanese.NoteToolkit=— エンジンはインストールに含まれます。CUDA Toolkit v%1 を使用 (ダウンロードなし)
chinesesimplified.NoteToolkit=— 引擎已包含在安装中，使用 CUDA Toolkit v%1（无需下载）
chinesetraditional.NoteToolkit=— 引擎已包含在安裝中，使用 CUDA Toolkit v%1（無需下載）
spanish.NoteToolkit=— motor incluido en la instalación, se usa CUDA Toolkit v%1 (sin descarga)

korean.NoteCublasCached=— 엔진은 설치에 포함, cuBLAS 이미 설치됨
english.NoteCublasCached=- engine included in the installation, cuBLAS already installed
japanese.NoteCublasCached=— エンジンはインストールに含まれます。cuBLAS はインストール済み
chinesesimplified.NoteCublasCached=— 引擎已包含在安装中，cuBLAS 已安装
chinesetraditional.NoteCublasCached=— 引擎已包含在安裝中，cuBLAS 已安裝
spanish.NoteCublasCached=— motor incluido en la instalación, cuBLAS ya instalado

korean.NoteNoDriver=— NVIDIA 드라이버 없음
english.NoteNoDriver=- no NVIDIA driver
japanese.NoteNoDriver=— NVIDIA ドライバーがありません
chinesesimplified.NoteNoDriver=— 未找到 NVIDIA 驱动程序
chinesetraditional.NoteNoDriver=— 找不到 NVIDIA 驅動程式
spanish.NoteNoDriver=— no hay controlador NVIDIA

korean.NoteCublasOnly=— 엔진은 설치에 포함, cuBLAS만 받음
english.NoteCublasOnly=- engine included in the installation, only cuBLAS is downloaded
japanese.NoteCublasOnly=— エンジンはインストールに含まれます。cuBLAS のみ取得
chinesesimplified.NoteCublasOnly=— 引擎已包含在安装中，仅下载 cuBLAS
chinesetraditional.NoteCublasOnly=— 引擎已包含在安裝中，僅下載 cuBLAS
spanish.NoteCublasOnly=— motor incluido en la instalación, solo se descarga cuBLAS

korean.NoteYoutubeInstalled=— 이미 설치됨 (선택하면 최신 버전으로 업데이트)
english.NoteYoutubeInstalled=- already installed (select to update to the latest version)
japanese.NoteYoutubeInstalled=— インストール済み (選択すると最新バージョンに更新)
chinesesimplified.NoteYoutubeInstalled=— 已安装（选中后将更新到最新版本）
chinesetraditional.NoteYoutubeInstalled=— 已安裝（選取後將更新到最新版本）
spanish.NoteYoutubeInstalled=— ya instalado (selecciónelo para actualizar a la última versión)

korean.ErrSave=파일을 저장할 수 없습니다: %1
english.ErrSave=Cannot save the file: %1
japanese.ErrSave=ファイルを保存できません: %1
chinesesimplified.ErrSave=无法保存文件：%1
chinesetraditional.ErrSave=無法儲存檔案：%1
spanish.ErrSave=No se puede guardar el archivo: %1

korean.ErrIntegrity=무결성 검증에 실패했습니다: %1
english.ErrIntegrity=Integrity verification failed: %1
japanese.ErrIntegrity=整合性の検証に失敗しました: %1
chinesesimplified.ErrIntegrity=完整性验证失败：%1
chinesetraditional.ErrIntegrity=完整性驗證失敗：%1
spanish.ErrIntegrity=Falló la verificación de integridad: %1

korean.ErrApply=파일을 적용할 수 없습니다. 파일 접근 권한을 확인하세요: %1
english.ErrApply=Cannot apply the file. Check the file access permissions: %1
japanese.ErrApply=ファイルを適用できません。ファイルのアクセス権を確認してください: %1
chinesesimplified.ErrApply=无法应用文件。请检查文件访问权限：%1
chinesetraditional.ErrApply=無法套用檔案。請檢查檔案存取權限：%1
spanish.ErrApply=No se puede aplicar el archivo. Compruebe los permisos de acceso: %1

korean.ErrReleaseRead=릴리스 정보를 읽을 수 없습니다: %1
english.ErrReleaseRead=Cannot read the release information: %1
japanese.ErrReleaseRead=リリース情報を読み取れません: %1
chinesesimplified.ErrReleaseRead=无法读取发行版信息：%1
chinesetraditional.ErrReleaseRead=無法讀取發行版資訊：%1
spanish.ErrReleaseRead=No se puede leer la información de la versión: %1

korean.ErrReleaseFormat=릴리스 정보 형식이 올바르지 않습니다: %1
english.ErrReleaseFormat=The release information format is invalid: %1
japanese.ErrReleaseFormat=リリース情報の形式が正しくありません: %1
chinesesimplified.ErrReleaseFormat=发行版信息格式不正确：%1
chinesetraditional.ErrReleaseFormat=發行版資訊格式不正確：%1
spanish.ErrReleaseFormat=El formato de la información de la versión no es válido: %1

korean.ErrReleaseTagMissing=릴리스 태그를 찾을 수 없습니다: %1
english.ErrReleaseTagMissing=Cannot find the release tag: %1
japanese.ErrReleaseTagMissing=リリースタグが見つかりません: %1
chinesesimplified.ErrReleaseTagMissing=找不到发行版标签：%1
chinesetraditional.ErrReleaseTagMissing=找不到發行版標籤：%1
spanish.ErrReleaseTagMissing=No se encuentra la etiqueta de la versión: %1

korean.ErrReleaseTagInvalid=릴리스 태그가 올바르지 않습니다: %1
english.ErrReleaseTagInvalid=The release tag is invalid: %1
japanese.ErrReleaseTagInvalid=リリースタグが正しくありません: %1
chinesesimplified.ErrReleaseTagInvalid=发行版标签不正确：%1
chinesetraditional.ErrReleaseTagInvalid=發行版標籤不正確：%1
spanish.ErrReleaseTagInvalid=La etiqueta de la versión no es válida: %1

korean.ErrYoutubeDir=YouTube 폴더를 만들 수 없습니다: %1
english.ErrYoutubeDir=Cannot create the YouTube folder: %1
japanese.ErrYoutubeDir=YouTube フォルダーを作成できません: %1
chinesesimplified.ErrYoutubeDir=无法创建 YouTube 文件夹：%1
chinesetraditional.ErrYoutubeDir=無法建立 YouTube 資料夾：%1
spanish.ErrYoutubeDir=No se puede crear la carpeta de YouTube: %1

korean.ErrYtdlpChecksum=yt-dlp 릴리스의 체크섬에서 yt-dlp.exe를 찾을 수 없습니다.
english.ErrYtdlpChecksum=Cannot find yt-dlp.exe in the checksums of the yt-dlp release.
japanese.ErrYtdlpChecksum=yt-dlp リリースのチェックサムに yt-dlp.exe が見つかりません。
chinesesimplified.ErrYtdlpChecksum=在 yt-dlp 发行版的校验和中找不到 yt-dlp.exe。
chinesetraditional.ErrYtdlpChecksum=在 yt-dlp 發行版的檢查碼中找不到 yt-dlp.exe。
spanish.ErrYtdlpChecksum=No se encuentra yt-dlp.exe en las sumas de comprobación de la versión de yt-dlp.

korean.ErrDenoChecksum=Deno 릴리스의 체크섬을 찾을 수 없습니다.
english.ErrDenoChecksum=Cannot find the checksum of the Deno release.
japanese.ErrDenoChecksum=Deno リリースのチェックサムが見つかりません。
chinesesimplified.ErrDenoChecksum=找不到 Deno 发行版的校验和。
chinesetraditional.ErrDenoChecksum=找不到 Deno 發行版的檢查碼。
spanish.ErrDenoChecksum=No se encuentra la suma de comprobación de la versión de Deno.

korean.ErrTempDir=임시 폴더를 만들 수 없습니다: %1
english.ErrTempDir=Cannot create the temporary folder: %1
japanese.ErrTempDir=一時フォルダーを作成できません: %1
chinesesimplified.ErrTempDir=无法创建临时文件夹：%1
chinesetraditional.ErrTempDir=無法建立暫存資料夾：%1
spanish.ErrTempDir=No se puede crear la carpeta temporal: %1

korean.ErrDenoUnpack=Deno 압축을 풀 수 없습니다 (Windows tar.exe 필요).
english.ErrDenoUnpack=Cannot extract Deno (Windows tar.exe is required).
japanese.ErrDenoUnpack=Deno を展開できません (Windows の tar.exe が必要です)。
chinesesimplified.ErrDenoUnpack=无法解压 Deno（需要 Windows tar.exe）。
chinesetraditional.ErrDenoUnpack=無法解壓縮 Deno（需要 Windows tar.exe）。
spanish.ErrDenoUnpack=No se puede extraer Deno (se requiere tar.exe de Windows).

korean.ErrModelDir=모델 폴더를 만들 수 없습니다: %1
english.ErrModelDir=Cannot create the model folder: %1
japanese.ErrModelDir=モデルフォルダーを作成できません: %1
chinesesimplified.ErrModelDir=无法创建模型文件夹：%1
chinesetraditional.ErrModelDir=無法建立模型資料夾：%1
spanish.ErrModelDir=No se puede crear la carpeta de modelos: %1

korean.ErrCudaDir=CUDA 구성 요소 폴더를 만들 수 없습니다: %1
english.ErrCudaDir=Cannot create the CUDA components folder: %1
japanese.ErrCudaDir=CUDA コンポーネントのフォルダーを作成できません: %1
chinesesimplified.ErrCudaDir=无法创建 CUDA 组件文件夹：%1
chinesetraditional.ErrCudaDir=無法建立 CUDA 元件資料夾：%1
spanish.ErrCudaDir=No se puede crear la carpeta de componentes CUDA: %1

korean.SumInstalled=설치됨 (%1)
english.SumInstalled=Installed (%1)
japanese.SumInstalled=インストール済み (%1)
chinesesimplified.SumInstalled=已安装（%1）
chinesetraditional.SumInstalled=已安裝（%1）
spanish.SumInstalled=Instalado (%1)

korean.SumMissing=없음 (%1)
english.SumMissing=Missing (%1)
japanese.SumMissing=なし (%1)
chinesesimplified.SumMissing=缺少（%1）
chinesetraditional.SumMissing=缺少（%1）
spanish.SumMissing=Falta (%1)

korean.SumEngine=엔진: 설치에 포함됨 (설치 시 함께 설치)
english.SumEngine=Engine: included in the installation (installed together)
japanese.SumEngine=エンジン: インストールに含まれます (一緒にインストール)
chinesesimplified.SumEngine=引擎：已包含在安装中（随安装一同安装）
chinesetraditional.SumEngine=引擎：已包含在安裝中（隨安裝一同安裝）
spanish.SumEngine=Motor: incluido en la instalación (se instala junto con ella)

korean.SumCublas=cuBLAS: %1
english.SumCublas=cuBLAS: %1
japanese.SumCublas=cuBLAS: %1
chinesesimplified.SumCublas=cuBLAS：%1
chinesetraditional.SumCublas=cuBLAS：%1
spanish.SumCublas=cuBLAS: %1

korean.SumToolkit=CUDA Toolkit v%1
english.SumToolkit=CUDA Toolkit v%1
japanese.SumToolkit=CUDA Toolkit v%1
chinesesimplified.SumToolkit=CUDA Toolkit v%1
chinesetraditional.SumToolkit=CUDA Toolkit v%1
spanish.SumToolkit=CUDA Toolkit v%1

korean.SumCublasCached=캐시 설치됨
english.SumCublasCached=cached copy installed
japanese.SumCublasCached=キャッシュ済み
chinesesimplified.SumCublasCached=缓存已安装
chinesetraditional.SumCublasCached=快取已安裝
spanish.SumCublasCached=copia en caché instalada

korean.SumCublasNone=없음 (CPU 사용, 약 507 MiB 받을 수 있음)
english.SumCublasNone=missing (CPU is used; about 507 MiB can be downloaded)
japanese.SumCublasNone=なし (CPU を使用、約 507 MiB をダウンロード可能)
chinesesimplified.SumCublasNone=缺少（使用 CPU，可下载约 507 MiB）
chinesetraditional.SumCublasNone=缺少（使用 CPU，可下載約 507 MiB）
spanish.SumCublasNone=falta (se usa la CPU; se pueden descargar unos 507 MiB)

korean.SumDriver=드라이버: %1
english.SumDriver=Driver: %1
japanese.SumDriver=ドライバー: %1
chinesesimplified.SumDriver=驱动程序：%1
chinesetraditional.SumDriver=驅動程式：%1
spanish.SumDriver=Controlador: %1

korean.SumDriverPresent=있음
english.SumDriverPresent=present
japanese.SumDriverPresent=あり
chinesesimplified.SumDriverPresent=存在
chinesetraditional.SumDriverPresent=存在
spanish.SumDriverPresent=presente

korean.SumDriverNone=없음 (GPU 가속 불가)
english.SumDriverNone=missing (no GPU acceleration)
japanese.SumDriverNone=なし (GPU アクセラレーション不可)
chinesesimplified.SumDriverNone=缺少（无法使用 GPU 加速）
chinesetraditional.SumDriverNone=缺少（無法使用 GPU 加速）
spanish.SumDriverNone=falta (sin aceleración por GPU)

korean.SumYoutubeOk=설치됨 (yt-dlp %1, Deno %2)
english.SumYoutubeOk=Installed (yt-dlp %1, Deno %2)
japanese.SumYoutubeOk=インストール済み (yt-dlp %1, Deno %2)
chinesesimplified.SumYoutubeOk=已安装（yt-dlp %1，Deno %2）
chinesetraditional.SumYoutubeOk=已安裝（yt-dlp %1，Deno %2）
spanish.SumYoutubeOk=Instalado (yt-dlp %1, Deno %2)

korean.SumYoutubePartial=일부만 설치됨
english.SumYoutubePartial=Partially installed
japanese.SumYoutubePartial=一部のみインストール済み
chinesesimplified.SumYoutubePartial=仅部分安装
chinesetraditional.SumYoutubePartial=僅部分安裝
spanish.SumYoutubePartial=Instalado parcialmente

korean.SumYoutubeNone=없음 (YouTube 재생에 필요)
english.SumYoutubeNone=Missing (required for YouTube playback)
japanese.SumYoutubeNone=なし (YouTube 再生に必要)
chinesesimplified.SumYoutubeNone=缺少（YouTube 播放需要）
chinesetraditional.SumYoutubeNone=缺少（YouTube 播放需要）
spanish.SumYoutubeNone=Falta (necesario para reproducir YouTube)

korean.PreTitle=설치 전 확인:
english.PreTitle=Pre-installation check:
japanese.PreTitle=インストール前の確認:
chinesesimplified.PreTitle=安装前检查：
chinesetraditional.PreTitle=安裝前檢查：
spanish.PreTitle=Comprobación previa a la instalación:

korean.PreModels=음성 모델: %1
english.PreModels=Speech models: %1
japanese.PreModels=音声モデル: %1
chinesesimplified.PreModels=语音模型：%1
chinesetraditional.PreModels=語音模型：%1
spanish.PreModels=Modelos de voz: %1

korean.PreCuda=CUDA: %1
english.PreCuda=CUDA: %1
japanese.PreCuda=CUDA: %1
chinesesimplified.PreCuda=CUDA：%1
chinesetraditional.PreCuda=CUDA：%1
spanish.PreCuda=CUDA: %1

korean.PreYoutube=YouTube 도구: %1
english.PreYoutube=YouTube tools: %1
japanese.PreYoutube=YouTube ツール: %1
chinesesimplified.PreYoutube=YouTube 工具：%1
chinesetraditional.PreYoutube=YouTube 工具：%1
spanish.PreYoutube=Herramientas de YouTube: %1

korean.PreWebView2Ok=WebView2 런타임: 설치됨 (%1)
english.PreWebView2Ok=WebView2 Runtime: installed (%1)
japanese.PreWebView2Ok=WebView2 ランタイム: インストール済み (%1)
chinesesimplified.PreWebView2Ok=WebView2 运行时：已安装（%1）
chinesetraditional.PreWebView2Ok=WebView2 執行階段：已安裝（%1）
spanish.PreWebView2Ok=Runtime de WebView2: instalado (%1)

korean.PreWebView2No=WebView2 런타임: 없음 (YouTube 창에 필요 - Windows 업데이트 또는 Microsoft에서 설치)
english.PreWebView2No=WebView2 Runtime: missing (needed for the YouTube window - install it through Windows Update or from Microsoft)
japanese.PreWebView2No=WebView2 ランタイム: なし (YouTube ウィンドウに必要 - Windows Update または Microsoft からインストール)
chinesesimplified.PreWebView2No=WebView2 运行时：缺少（YouTube 窗口需要 - 请通过 Windows 更新或从 Microsoft 安装）
chinesetraditional.PreWebView2No=WebView2 執行階段：缺少（YouTube 視窗需要 - 請透過 Windows Update 或從 Microsoft 安裝）
spanish.PreWebView2No=Runtime de WebView2: falta (necesario para la ventana de YouTube; instálelo desde Windows Update o desde Microsoft)

korean.PreOllamaOk=Ollama: 설치됨 (%1)
english.PreOllamaOk=Ollama: installed (%1)
japanese.PreOllamaOk=Ollama: インストール済み (%1)
chinesesimplified.PreOllamaOk=Ollama：已安装（%1）
chinesetraditional.PreOllamaOk=Ollama：已安裝（%1）
spanish.PreOllamaOk=Ollama: instalado (%1)

korean.PreOllamaNo=Ollama: 없음 (번역에 필요 - https://ollama.com)
english.PreOllamaNo=Ollama: missing (needed for translation - https://ollama.com)
japanese.PreOllamaNo=Ollama: なし (翻訳に必要 - https://ollama.com)
chinesesimplified.PreOllamaNo=Ollama：缺少（翻译需要 - https://ollama.com）
chinesetraditional.PreOllamaNo=Ollama：缺少（翻譯需要 - https://ollama.com）
spanish.PreOllamaNo=Ollama: falta (necesario para traducir - https://ollama.com)

korean.PreDisk=디스크: 독립 Blu-ray/DVD 엔진 내장 (MakeMKV 불필요, 암호화 Blu-ray의 키 DB는 필요 시 자동 다운로드)
english.PreDisk=Discs: standalone Blu-ray/DVD engine built in (MakeMKV not needed; the key database for encrypted Blu-rays is downloaded automatically when needed)
japanese.PreDisk=ディスク: 独立した Blu-ray/DVD エンジンを内蔵 (MakeMKV は不要。暗号化された Blu-ray のキー DB は必要時に自動ダウンロード)
chinesesimplified.PreDisk=光盘：内置独立的 Blu-ray/DVD 引擎（无需 MakeMKV；加密 Blu-ray 的密钥数据库将在需要时自动下载）
chinesetraditional.PreDisk=光碟：內建獨立的 Blu-ray/DVD 引擎（不需要 MakeMKV；加密 Blu-ray 的金鑰資料庫將在需要時自動下載）
spanish.PreDisk=Discos: motor independiente de Blu-ray/DVD integrado (no se necesita MakeMKV; la base de datos de claves de los Blu-ray cifrados se descarga automáticamente cuando hace falta)

korean.DownloadTitle=AI 구성 요소 다운로드
english.DownloadTitle=Downloading AI components
japanese.DownloadTitle=AI コンポーネントのダウンロード
chinesesimplified.DownloadTitle=下载 AI 组件
chinesetraditional.DownloadTitle=下載 AI 元件
spanish.DownloadTitle=Descarga de componentes de IA

korean.DownloadDesc=다운로드 후 크기와 SHA-256을 검증합니다. 취소하거나 건너뛰어도 설정 메뉴(Ctrl+N → AI 구성 요소 관리)에서 받을 수 있습니다.
english.DownloadDesc=The size and SHA-256 are verified after download. If you cancel or skip, you can still get them from the settings menu (Ctrl+N → Manage AI components).
japanese.DownloadDesc=ダウンロード後にサイズと SHA-256 を検証します。キャンセルまたはスキップしても、設定メニュー (Ctrl+N → AI コンポーネントの管理) から取得できます。
chinesesimplified.DownloadDesc=下载后会验证大小和 SHA-256。即使取消或跳过，也可以在设置菜单（Ctrl+N → 管理 AI 组件）中下载。
chinesetraditional.DownloadDesc=下載後會驗證大小與 SHA-256。即使取消或略過，也可以在設定選單（Ctrl+N → 管理 AI 元件）中下載。
spanish.DownloadDesc=Tras la descarga se verifican el tamaño y el SHA-256. Aunque cancele u omita este paso, podrá obtenerlos desde el menú de ajustes (Ctrl+N → Administrar componentes de IA).

korean.LicenseTitle=NVIDIA CUDA 라이선스
english.LicenseTitle=NVIDIA CUDA license
japanese.LicenseTitle=NVIDIA CUDA ライセンス
chinesesimplified.LicenseTitle=NVIDIA CUDA 许可协议
chinesetraditional.LicenseTitle=NVIDIA CUDA 授權條款
spanish.LicenseTitle=Licencia de NVIDIA CUDA

korean.LicenseDesc=CUDA 가속 구성 요소(NVIDIA CUDA 엔진, cuBLAS)를 내려받으려면 라이선스에 동의해야 합니다.
english.LicenseDesc=You must accept the license to download the CUDA acceleration components (NVIDIA CUDA engine, cuBLAS).
japanese.LicenseDesc=CUDA アクセラレーションコンポーネント (NVIDIA CUDA エンジン、cuBLAS) をダウンロードするには、ライセンスに同意する必要があります。
chinesesimplified.LicenseDesc=要下载 CUDA 加速组件（NVIDIA CUDA 引擎、cuBLAS），必须同意许可协议。
chinesetraditional.LicenseDesc=要下載 CUDA 加速元件（NVIDIA CUDA 引擎、cuBLAS），必須同意授權條款。
spanish.LicenseDesc=Debe aceptar la licencia para descargar los componentes de aceleración CUDA (motor NVIDIA CUDA, cuBLAS).

korean.LicenseAccept=위 NVIDIA CUDA 라이선스 조건에 동의합니다
english.LicenseAccept=I accept the NVIDIA CUDA license terms above
japanese.LicenseAccept=上記の NVIDIA CUDA ライセンス条項に同意します
chinesesimplified.LicenseAccept=我同意上述 NVIDIA CUDA 许可条款
chinesetraditional.LicenseAccept=我同意上述 NVIDIA CUDA 授權條款
spanish.LicenseAccept=Acepto los términos de la licencia de NVIDIA CUDA anteriores

korean.LicenseRequired=CUDA 가속 구성 요소를 받으려면 라이선스에 동의해야 합니다.%n동의하지 않으면 이전 화면에서 CUDA 가속 항목을 해제하세요 (CPU 엔진은 기본 포함).
english.LicenseRequired=You must accept the license to download the CUDA acceleration components.%nIf you do not agree, clear the CUDA acceleration item on the previous page (the CPU engine is included by default).
japanese.LicenseRequired=CUDA アクセラレーションコンポーネントを取得するには、ライセンスに同意する必要があります。%n同意しない場合は、前の画面で CUDA アクセラレーションの項目をオフにしてください (CPU エンジンは標準で含まれます)。
chinesesimplified.LicenseRequired=要获取 CUDA 加速组件，必须同意许可协议。%n如果不同意，请在上一页取消选中 CUDA 加速项（默认已包含 CPU 引擎）。
chinesetraditional.LicenseRequired=要取得 CUDA 加速元件，必須同意授權條款。%n如果不同意，請在上一頁取消選取 CUDA 加速項目（預設已包含 CPU 引擎）。
spanish.LicenseRequired=Debe aceptar la licencia para obtener los componentes de aceleración CUDA.%nSi no está de acuerdo, desactive la opción de aceleración CUDA en la página anterior (el motor de CPU se incluye de forma predeterminada).

korean.ReadyCudaHeader=CUDA 가속 구성 요소:
english.ReadyCudaHeader=CUDA acceleration components:
japanese.ReadyCudaHeader=CUDA アクセラレーションコンポーネント:
chinesesimplified.ReadyCudaHeader=CUDA 加速组件：
chinesetraditional.ReadyCudaHeader=CUDA 加速元件：
spanish.ReadyCudaHeader=Componentes de aceleración CUDA:

korean.ReadyLocation=설치 위치: %1
english.ReadyLocation=Install location: %1
japanese.ReadyLocation=インストール先: %1
chinesesimplified.ReadyLocation=安装位置：%1
chinesetraditional.ReadyLocation=安裝位置：%1
spanish.ReadyLocation=Ubicación de instalación: %1

korean.ReadyEngine=엔진: 이 설치 프로그램에 포함됨 (내려받기 없음)
english.ReadyEngine=Engine: included in this installer (no download)
japanese.ReadyEngine=エンジン: このインストーラーに含まれます (ダウンロードなし)
chinesesimplified.ReadyEngine=引擎：已包含在此安装程序中（无需下载）
chinesetraditional.ReadyEngine=引擎：已包含在此安裝程式中（無需下載）
spanish.ReadyEngine=Motor: incluido en este instalador (sin descarga)

korean.ReadyCublasToolkit=cuBLAS: CUDA Toolkit 사용 (%1) - 내려받기 없음
english.ReadyCublasToolkit=cuBLAS: using the CUDA Toolkit (%1) - no download
japanese.ReadyCublasToolkit=cuBLAS: CUDA Toolkit を使用 (%1) - ダウンロードなし
chinesesimplified.ReadyCublasToolkit=cuBLAS：使用 CUDA Toolkit（%1）- 无需下载
chinesetraditional.ReadyCublasToolkit=cuBLAS：使用 CUDA Toolkit（%1）- 無需下載
spanish.ReadyCublasToolkit=cuBLAS: se usa el CUDA Toolkit (%1) - sin descarga

korean.ReadyCublasInstalled=cuBLAS: 이미 설치됨
english.ReadyCublasInstalled=cuBLAS: already installed
japanese.ReadyCublasInstalled=cuBLAS: インストール済み
chinesesimplified.ReadyCublasInstalled=cuBLAS：已安装
chinesetraditional.ReadyCublasInstalled=cuBLAS：已安裝
spanish.ReadyCublasInstalled=cuBLAS: ya instalado

korean.ReadyCublasDownload=cuBLAS: 내려받기 (NVIDIA 라이선스 동의 필요)
english.ReadyCublasDownload=cuBLAS: download (NVIDIA license acceptance required)
japanese.ReadyCublasDownload=cuBLAS: ダウンロード (NVIDIA ライセンスへの同意が必要)
chinesesimplified.ReadyCublasDownload=cuBLAS：下载（需要同意 NVIDIA 许可协议）
chinesetraditional.ReadyCublasDownload=cuBLAS：下載（需要同意 NVIDIA 授權條款）
spanish.ReadyCublasDownload=cuBLAS: descarga (requiere aceptar la licencia de NVIDIA)

korean.ReadyDownloadSize=내려받기 필요: 약 %1 MiB
english.ReadyDownloadSize=Download required: about %1 MiB
japanese.ReadyDownloadSize=必要なダウンロード: 約 %1 MiB
chinesesimplified.ReadyDownloadSize=需要下载：约 %1 MiB
chinesetraditional.ReadyDownloadSize=需要下載：約 %1 MiB
spanish.ReadyDownloadSize=Descarga necesaria: unos %1 MiB

korean.DriverMissing=NVIDIA 드라이버(nvcuda.dll)를 찾을 수 없습니다. CUDA 가속은 NVIDIA GPU와 드라이버가 있어야 동작합니다.%n그래도 CUDA 구성 요소를 내려받으시겠습니까? (아니오: 돌아가서 항목을 해제하면 CPU만으로 설치됩니다)
english.DriverMissing=The NVIDIA driver (nvcuda.dll) was not found. CUDA acceleration only works with an NVIDIA GPU and driver.%nDownload the CUDA components anyway? (No: go back and clear the item to install with the CPU only)
japanese.DriverMissing=NVIDIA ドライバー (nvcuda.dll) が見つかりません。CUDA アクセラレーションは NVIDIA GPU とドライバーがある場合にのみ動作します。%nそれでも CUDA コンポーネントをダウンロードしますか? (いいえ: 戻って項目をオフにすると CPU のみでインストールされます)
chinesesimplified.DriverMissing=找不到 NVIDIA 驱动程序 (nvcuda.dll)。CUDA 加速需要 NVIDIA GPU 和驱动程序才能工作。%n仍要下载 CUDA 组件吗？（否：返回并取消选中该项，将仅使用 CPU 安装）
chinesetraditional.DriverMissing=找不到 NVIDIA 驅動程式 (nvcuda.dll)。CUDA 加速需要 NVIDIA GPU 與驅動程式才能運作。%n仍要下載 CUDA 元件嗎？（否：返回並取消選取該項目，將僅使用 CPU 安裝）
spanish.DriverMissing=No se encontró el controlador de NVIDIA (nvcuda.dll). La aceleración CUDA solo funciona con una GPU y un controlador de NVIDIA.%n¿Descargar los componentes CUDA de todos modos? (No: vuelva atrás y desactive la opción para instalar solo con la CPU)

korean.DownloadFailedHint=%1%n이미 받은 파일은 보존됩니다. 모델/CUDA/YouTube 항목을 해제하면 (CPU 엔진은 기본 포함) 설치를 계속할 수 있고, 설치 후 설정 메뉴(Ctrl+N → AI 구성 요소 관리)에서 다시 받을 수 있습니다.
english.DownloadFailedHint=%1%nFiles that were already downloaded are kept. Clear the model/CUDA/YouTube items (the CPU engine is included by default) to continue the installation, and download them again after installing from the settings menu (Ctrl+N → Manage AI components).
japanese.DownloadFailedHint=%1%nダウンロード済みのファイルは保持されます。モデル/CUDA/YouTube の項目をオフにすると (CPU エンジンは標準で含まれます) インストールを続行でき、インストール後に設定メニュー (Ctrl+N → AI コンポーネントの管理) から再度取得できます。
chinesesimplified.DownloadFailedHint=%1%n已下载的文件会被保留。取消选中模型/CUDA/YouTube 项（默认已包含 CPU 引擎）即可继续安装，安装后可在设置菜单（Ctrl+N → 管理 AI 组件）中重新下载。
chinesetraditional.DownloadFailedHint=%1%n已下載的檔案會被保留。取消選取模型/CUDA/YouTube 項目（預設已包含 CPU 引擎）即可繼續安裝，安裝後可在設定選單（Ctrl+N → 管理 AI 元件）中重新下載。
spanish.DownloadFailedHint=%1%nLos archivos ya descargados se conservan. Desactive las opciones de modelos/CUDA/YouTube (el motor de CPU se incluye de forma predeterminada) para continuar con la instalación; podrá volver a descargarlos después desde el menú de ajustes (Ctrl+N → Administrar componentes de IA).

korean.SilentDownloadFailed=요청한 구성 요소 다운로드에 실패했습니다: %1. 다운로드 없이 CPU 플레이어를 설치하려면 /TASKS= 옵션으로 설치 프로그램을 실행하세요.
english.SilentDownloadFailed=Requested component download failed: %1. Run setup with /TASKS= to install the CPU player without downloads.
japanese.SilentDownloadFailed=要求されたコンポーネントのダウンロードに失敗しました: %1。ダウンロードなしで CPU プレーヤーをインストールするには、/TASKS= オプションを付けてセットアップを実行してください。
chinesesimplified.SilentDownloadFailed=请求的组件下载失败：%1。若要在不下载的情况下安装 CPU 播放器，请使用 /TASKS= 参数运行安装程序。
chinesetraditional.SilentDownloadFailed=要求的元件下載失敗：%1。若要在不下載的情況下安裝 CPU 播放器，請使用 /TASKS= 參數執行安裝程式。
spanish.SilentDownloadFailed=Falló la descarga del componente solicitado: %1. Ejecute el instalador con /TASKS= para instalar el reproductor de CPU sin descargas.
