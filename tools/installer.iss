; NanumPlayer installer. Built by tools\package.py (passes /DAppVersion, /DStageDir,
; /DModelCatalogFile and /DComponentCatalogFile).
#ifndef AppVersion
#define AppVersion "0.0.0"
#endif
#ifndef StageDir
#define StageDir "..\dist\stage"
#endif
#ifndef ModelCatalogFile
#error Package with tools/package.py to generate the pinned model catalogue.
#endif
#ifndef ComponentCatalogFile
#error Package with tools/package.py to generate the pinned CUDA component catalogue.
#endif
; The cuBLAS cache of the optional CUDA payload: %LOCALAPPDATA%\NanumPlayer\accelerators\cuda\<CUDA major>.
; (The CUDA engine itself is part of the application.)
#ifndef CudaMajor
#error Package with tools/package.py to specify the CUDA major version of the component catalogue.
#endif

[Setup]
AppId={{6D2F3C1A-7B0E-4E55-9C6B-4A1D5E0F9A21}
AppName=NanumPlayer
AppVersion={#AppVersion}
AppPublisher=NanumPlayer
DefaultDirName={autopf}\NanumPlayer
DefaultGroupName=NanumPlayer
UninstallDisplayIcon={app}\NanumPlayer.exe
SetupIconFile=..\third_party\mpv\etc\nanum-icon.ico
OutputDir=..\dist
OutputBaseFilename=NanumPlayer-Setup-{#AppVersion}
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
DiskSpanning=no
#ifdef Sign
SignTool=nanumsign
SignedUninstaller=yes
#endif

[Languages]
Name: "korean"; MessagesFile: "compiler:Languages\Korean.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked
Name: "model_english"; Description: "영어 음성 인식: Whisper small.en + Silero VAD (약 466 MiB 다운로드)"; GroupDescription: "AI 모델 다운로드 (선택, 인터넷 연결 필요):"; Flags: unchecked
Name: "model_multilingual"; Description: "다국어 음성 인식: Whisper small + Silero VAD (약 466 MiB 다운로드)"; GroupDescription: "AI 모델 다운로드 (선택, 인터넷 연결 필요):"; Flags: unchecked
Name: "model_multilingual_large"; Description: "다국어 고정밀 음성 인식: Whisper large-v3-turbo + Silero VAD (약 548 MiB 다운로드, 외국어 영상 권장)"; GroupDescription: "AI 모델 다운로드 (선택, 인터넷 연결 필요):"; Flags: unchecked
Name: "model_vad"; Description: "음성 감지 모델만: Silero VAD (약 0.8 MiB 다운로드)"; GroupDescription: "AI 모델 다운로드 (선택, 인터넷 연결 필요):"; Flags: unchecked
Name: "cuda_accel"; Description: "NVIDIA CUDA 가속: cuBLAS 다운로드 (약 507 MiB, CUDA 13 Toolkit이 있으면 필요 없음)"; GroupDescription: "AI 가속 (선택, 인터넷 연결 필요):"; Flags: unchecked
Name: "youtube_tools"; Description: "YouTube 재생 구성 요소: yt-dlp + Deno (약 60 MiB 다운로드, 설치 시점의 최신 공식 릴리스)"; GroupDescription: "YouTube (선택, 인터넷 연결 필요):"; Flags: unchecked

[Files]
Source: "{#StageDir}\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion
; shown (and cached next to the CUDA components) when the CUDA task is chosen
Source: "{#StageDir}\LICENSE-NVIDIA-CUDA.txt"; Flags: dontcopy

[InstallDelete]
#ifdef CleanupFile
#include CleanupFile
#endif

[Icons]
Name: "{group}\NanumPlayer"; Filename: "{app}\NanumPlayer.exe"
Name: "{group}\{cm:UninstallProgram,NanumPlayer}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\NanumPlayer"; Filename: "{app}\NanumPlayer.exe"; Tasks: desktopicon

[Registry]
; "NanumPlayer로 열기": nanumplayer://open?url=<encoded> opens the player (per user). The
; portable player registers the same keys on first run; keep both identical.
Root: HKCU; Subkey: "Software\Classes\nanumplayer"; ValueType: string; ValueName: ""; ValueData: "URL:NanumPlayer"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\nanumplayer"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\nanumplayer\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: "{app}\NanumPlayer.exe,0"
Root: HKCU; Subkey: "Software\Classes\nanumplayer\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\NanumPlayer.exe"" ""%1"""

[Run]
Filename: "{app}\NanumPlayer.exe"; Description: "{cm:LaunchProgram,NanumPlayer}"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
; user settings/caches in %APPDATA%\NanumPlayer, models and CUDA components in %LOCALAPPDATA%\NanumPlayer are kept on purpose
Type: files; Name: "{app}\*.tmp"

[Code]
var
  ModelDownloadPage: TDownloadWizardPage;
  CudaLicensePage: TWizardPage;
  CudaLicenseMemo: TNewMemo;
  CudaLicenseAccept: TNewCheckBox;
  DriverAsked: Boolean;

#include ModelCatalogFile
#include ComponentCatalogFile

function MoveFileEx(Source, Destination: String; Flags: Integer): Boolean;
  external 'MoveFileExW@kernel32.dll stdcall';

function ModelDirectory: String;
begin
  Result := ExpandConstant('{localappdata}\NanumPlayer\models');
end;

function CudaDirectory: String;
begin
  Result := ExpandConstant('{localappdata}\NanumPlayer\accelerators\cuda\{#CudaMajor}');
end;

function ModelWanted(Index: Integer): Boolean;
begin
  Result := WizardIsTaskSelected('model_' + ModelID(Index));
  if ModelID(Index) = 'vad' then
    Result := Result or WizardIsTaskSelected('model_english') or
      WizardIsTaskSelected('model_multilingual') or WizardIsTaskSelected('model_multilingual_large');
end;

function AnyModelWanted: Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 0 to {#ModelCount} - 1 do
    Result := Result or ModelWanted(I);
end;

function CudaWanted: Boolean;
begin
  Result := WizardIsTaskSelected('cuda_accel');
end;

function YoutubeWanted: Boolean;
begin
  Result := WizardIsTaskSelected('youtube_tools');
end;

{ ---- CUDA Toolkit reuse -------------------------------------------------- }
{ Only decides whether cuBLAS has to be downloaded (and the NVIDIA license asked).
  The player probes the exact directory again when it loads the engine, so a rejected
  Toolkit later just offers the download in the AI component manager. The Toolkit is
  only read. Like the player it also looks at the persistent environment (registry):
  a Toolkit installed after Explorer started is not in the inherited one. }

function ToolkitDirectoryUsable(const Dir: String): Boolean;
var
  MS1, LS1, MS2, LS2: Cardinal;
begin
  Result := False;
  if not (FileExists(Dir + '\cublas64_13.dll') and FileExists(Dir + '\cublasLt64_13.dll')) then Exit;
  if not GetVersionNumbers(Dir + '\cublas64_13.dll', MS1, LS1) then Exit;
  if not GetVersionNumbers(Dir + '\cublasLt64_13.dll', MS2, LS2) then Exit;
  // ABI 13 is encoded in the DLL filenames; NVIDIA's file version is unrelated.
  Result := (MS1 = MS2) and (LS1 = LS2);
end;

function ToolkitRootDirectory(const Root: String): String;
begin
  Result := '';
  if Root = '' then Exit;
  if ToolkitDirectoryUsable(Root + '\bin\x64') then
    Result := Root + '\bin\x64'
  else if ToolkitDirectoryUsable(Root + '\bin') then
    Result := Root + '\bin';
end;

// The value of an environment variable: this process, then the user and the system
// environment in the registry.
function EnvOrRegistry(const Name: String): String;
begin
  Result := GetEnv(Name);
  if Result = '' then
    if not RegQueryStringValue(HKCU, 'Environment', Name, Result) then Result := '';
  if Result = '' then
    if not RegQueryStringValue(HKLM, 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment',
                               Name, Result) then Result := '';
end;

// CUDA_PATH_V13_<n> (highest first), CUDA_PATH, then the default install folders.
// '' when there is no compatible Toolkit.
function FindToolkitDirectory: String;
var
  N: Integer;
begin
  Result := '';
  for N := 19 downto 0 do begin
    Result := ToolkitRootDirectory(EnvOrRegistry('CUDA_PATH_V13_' + IntToStr(N)));
    if Result <> '' then Exit;
  end;
  Result := ToolkitRootDirectory(EnvOrRegistry('CUDA_PATH'));
  if Result <> '' then Exit;
  for N := 19 downto 0 do begin
    Result := ToolkitRootDirectory(ExpandConstant('{commonpf64}') +
      '\NVIDIA GPU Computing Toolkit\CUDA\v13.' + IntToStr(N));
    if Result <> '' then Exit;
  end;
end;

// The cuBLAS download is only needed (and its NVIDIA license only asked) without a Toolkit.
function CudaDownloadWanted: Boolean;
begin
  Result := CudaWanted and (FindToolkitDirectory = '');
end;

function ComponentWanted(Index: Integer; const ToolkitDir: String): Boolean;
begin
  Result := CudaWanted;
  // cuBLAS comes from a compatible Toolkit when there is one; the engine always comes from the release
  if Result and (ToolkitDir <> '') and
     ((ComponentID(Index) = 'cublas') or (ComponentID(Index) = 'cublas_lt')) then
    Result := False;
end;

function NvidiaDriverPresent: Boolean;
begin
  Result := FileExists(ExpandConstant('{sys}\nvcuda.dll'));
end;

{ ---- Verified download + store ------------------------------------------- }

function VerifiedFile(const Filename: String; Size: Int64; const Hash: String): Boolean;
var
  Actual: Int64;
begin
  Result := False;
  if not FileExists(Filename) then Exit;
  try
    Result := FileSize64(Filename, Actual) and ((Size < 0) or (Actual = Size)) and
      (CompareText(GetSHA256OfFile(Filename), Hash) = 0);
  except
    Log('Cannot verify file: ' + Filename + ': ' + GetExceptionMessage);
  end;
end;

// Makes Destination a size+SHA-256 verified file. An already verified file is kept; a file
// stored earlier stays even if a later download fails. Raises on failure.
procedure EnsureFile(const Url, Name, Hash: String; Size: Int64; const Destination, LegacySource: String;
  Interactive: Boolean);
var
  Partial, Source: String;
  Downloaded: Boolean;
begin
  if VerifiedFile(Destination, Size, Hash) then Exit;
  Partial := Destination + '.setup.part';
  Downloaded := False;
  try
    if (LegacySource <> '') and VerifiedFile(LegacySource, Size, Hash) then
      Source := LegacySource
    else begin
      if Interactive then begin
        ModelDownloadPage.Clear;
        ModelDownloadPage.Add(Url, Name, Hash);
        ModelDownloadPage.Download;
      end else
        DownloadTemporaryFile(Url, Name, Hash, nil);
      Source := ExpandConstant('{tmp}\') + Name;
      Downloaded := True;
    end;
    if not CopyFile(Source, Partial, False) then
      RaiseException('파일을 저장할 수 없습니다: ' + Partial);
    if not VerifiedFile(Partial, Size, Hash) then
      RaiseException('무결성 검증에 실패했습니다: ' + Name);
    if not MoveFileEx(Partial, Destination, 9) then
      RaiseException('파일을 적용할 수 없습니다. 파일 접근 권한을 확인하세요: ' + Destination);
    if Downloaded then DeleteFile(Source);
  finally
    DeleteFile(Partial);
  end;
end;

{ ---- YouTube tools (yt-dlp + Deno, latest official releases) ---------------- }
{ Unlike the models these are not pinned: the tag of the latest release is read from the
  GitHub API, the files are fetched from that exact tag and verified against the release's
  own checksum files. The player's component manager (nanum-youtube-win.c) does the same
  and reads the .version stamps written here. }

function YoutubeDirectory: String;
begin
  Result := ExpandConstant('{localappdata}\NanumPlayer\youtube\bin');
end;

function LatestTag(const Repository: String): String;
var
  Json: AnsiString;
  Rest: String;
  P, I: Integer;
begin
  DownloadTemporaryFile('https://api.github.com/repos/' + Repository + '/releases/latest',
    'release.json', '', nil);
  if not LoadStringFromFile(ExpandConstant('{tmp}\release.json'), Json) then
    RaiseException('릴리스 정보를 읽을 수 없습니다: ' + Repository);
  P := Pos('"tag_name"', String(Json));
  if P = 0 then RaiseException('릴리스 정보 형식이 올바르지 않습니다: ' + Repository);
  Rest := Copy(String(Json), P + 10, 200);
  P := Pos('"', Rest);
  Rest := Copy(Rest, P + 1, 100);
  P := Pos('"', Rest);
  Result := Copy(Rest, 1, P - 1);
  if Result = '' then RaiseException('릴리스 태그를 찾을 수 없습니다: ' + Repository);
  for I := 1 to Length(Result) do
    if not (((Result[I] >= '0') and (Result[I] <= '9')) or ((Result[I] >= 'a') and (Result[I] <= 'z')) or
            ((Result[I] >= 'A') and (Result[I] <= 'Z')) or (Result[I] = '.') or (Result[I] = '-') or
            (Result[I] = '_')) then
      RaiseException('릴리스 태그가 올바르지 않습니다: ' + Repository);
end;

function IsHexDigit(C: Char): Boolean;
begin
  Result := ((C >= '0') and (C <= '9')) or ((C >= 'a') and (C <= 'f')) or ((C >= 'A') and (C <= 'F'));
end;

// SHA-256 out of a checksum file: the line "<hex>  <Name>" of Name, or (Name = '') the first
// 64 hex digit token (Deno's single-file checksum is certutil style: "Hash : <hex>").
function ChecksumOf(const Filename, Name: String): String;
var
  Text: AnsiString;
  S, Tail: String;
  I, J: Integer;
begin
  Result := '';
  if not LoadStringFromFile(Filename, Text) then Exit;
  S := String(Text);
  I := 1;
  while I <= Length(S) do begin
    if not IsHexDigit(S[I]) then
      I := I + 1
    else begin
      J := I;
      while (J <= Length(S)) and IsHexDigit(S[J]) do J := J + 1;
      if J - I = 64 then begin
        if Name = '' then begin
          Result := Lowercase(Copy(S, I, 64));
          Exit;
        end;
        Tail := Copy(S, J, Length(S));
        if Pos(#10, Tail) > 0 then Tail := Copy(Tail, 1, Pos(#10, Tail) - 1);
        Tail := Trim(Tail);
        if (Length(Tail) > 0) and (Tail[1] = '*') then Tail := Copy(Tail, 2, Length(Tail));
        if Tail = Name then begin
          Result := Lowercase(Copy(S, I, 64));
          Exit;
        end;
      end;
      I := J;
    end;
  end;
end;

procedure WriteVersionStamp(const Exe, Tag: String);
var
  Size: Int64;
begin
  if FileSize64(Exe, Size) then
    SaveStringToFile(Exe + '.version', Tag + #10 + IntToStr(Size) + #10, False);
end;

// Verified download of a file that is not kept as is (the Deno zip) into {tmp}.
procedure FetchToTemp(const Url, Name, Hash: String; Interactive: Boolean);
begin
  if Interactive then begin
    ModelDownloadPage.Clear;
    ModelDownloadPage.Add(Url, Name, Hash);
    ModelDownloadPage.Download;
  end else
    DownloadTemporaryFile(Url, Name, Hash, nil);
end;

procedure PrepareYoutube(Interactive: Boolean);
var
  Dir, Tag, Base, Hash, Zip, Unpacked, Partial, DenoZip: String;
  Code: Integer;
begin
  DenoZip := 'deno-x86_64-pc-windows-msvc.zip';
  Dir := YoutubeDirectory;
  if not ForceDirectories(Dir) then
    RaiseException('YouTube 폴더를 만들 수 없습니다: ' + Dir);

  Tag := LatestTag('yt-dlp/yt-dlp');
  Base := 'https://github.com/yt-dlp/yt-dlp/releases/download/' + Tag + '/';
  DownloadTemporaryFile(Base + 'SHA2-256SUMS', 'ytdlp-SHA2-256SUMS', '', nil);
  Hash := ChecksumOf(ExpandConstant('{tmp}\ytdlp-SHA2-256SUMS'), 'yt-dlp.exe');
  if Hash = '' then RaiseException('yt-dlp 릴리스의 체크섬에서 yt-dlp.exe를 찾을 수 없습니다.');
  EnsureFile(Base + 'yt-dlp.exe', 'yt-dlp.exe', Hash, -1, Dir + '\yt-dlp.exe', '', Interactive);
  WriteVersionStamp(Dir + '\yt-dlp.exe', Tag);

  // Deno (the JavaScript runtime yt-dlp needs for YouTube) is only fetched when missing.
  if FileExists(Dir + '\deno.exe') then Exit;
  Tag := LatestTag('denoland/deno');
  Base := 'https://github.com/denoland/deno/releases/download/' + Tag + '/';
  DownloadTemporaryFile(Base + DenoZip + '.sha256sum', 'deno.sha256sum', '', nil);
  Hash := ChecksumOf(ExpandConstant('{tmp}\deno.sha256sum'), '');
  if Hash = '' then RaiseException('Deno 릴리스의 체크섬을 찾을 수 없습니다.');
  FetchToTemp(Base + DenoZip, DenoZip, Hash, Interactive);
  Zip := ExpandConstant('{tmp}\') + DenoZip;
  Unpacked := ExpandConstant('{tmp}\deno-unpacked');
  Partial := Dir + '\deno.exe.setup.part';
  try
    if not ForceDirectories(Unpacked) then
      RaiseException('임시 폴더를 만들 수 없습니다: ' + Unpacked);
    if not Exec(ExpandConstant('{sys}\tar.exe'), '-xf "' + Zip + '" -C "' + Unpacked + '" deno.exe', '',
                SW_HIDE, ewWaitUntilTerminated, Code) or (Code <> 0) or not FileExists(Unpacked + '\deno.exe') then
      RaiseException('Deno 압축을 풀 수 없습니다 (Windows tar.exe 필요).');
    if not CopyFile(Unpacked + '\deno.exe', Partial, False) then
      RaiseException('파일을 저장할 수 없습니다: ' + Partial);
    if not MoveFileEx(Partial, Dir + '\deno.exe', 9) then
      RaiseException('파일을 적용할 수 없습니다. 파일 접근 권한을 확인하세요: ' + Dir + '\deno.exe');
    WriteVersionStamp(Dir + '\deno.exe', Tag);
  finally
    DeleteFile(Partial);
    DeleteFile(Zip);
    DeleteFile(Unpacked + '\deno.exe');
  end;
end;

// Models into %LOCALAPPDATA%\NanumPlayer\models, CUDA components into the versioned
// accelerators\cuda directory. Interactive: wizard progress page; otherwise (silent) no UI.
procedure PrepareDownloads(Interactive: Boolean);
var
  I: Integer;
  ToolkitDir, Legacy, License: String;
begin
  if AnyModelWanted then begin
    if not ForceDirectories(ModelDirectory) then
      RaiseException('모델 폴더를 만들 수 없습니다: ' + ModelDirectory);
    for I := 0 to {#ModelCount} - 1 do begin
      if ModelWanted(I) then begin
        Legacy := ExpandConstant('{app}\models\') + ModelFilename(I);
        EnsureFile(ModelURL(I), ModelFilename(I), ModelHash(I), ModelSize(I),
          ModelDirectory + '\' + ModelFilename(I), Legacy, Interactive);
      end;
    end;
  end;
  if YoutubeWanted then PrepareYoutube(Interactive);
  if CudaWanted then begin
    ToolkitDir := FindToolkitDirectory;
    if ToolkitDir <> '' then
      Log('CUDA Toolkit found, no cuBLAS download needed: ' + ToolkitDir);
  end;
  if CudaDownloadWanted then begin
    if not ForceDirectories(CudaDirectory) then
      RaiseException('CUDA 구성 요소 폴더를 만들 수 없습니다: ' + CudaDirectory);
    ToolkitDir := '';
    for I := 0 to {#ComponentCount} - 1 do begin
      if ComponentWanted(I, ToolkitDir) then
        EnsureFile(ComponentURL(I), ComponentFilename(I), ComponentHash(I), ComponentSize(I),
          CudaDirectory + '\' + ComponentFilename(I), '', Interactive);
    end;
    License := ExpandConstant('{tmp}\LICENSE-NVIDIA-CUDA.txt');
    if FileExists(License) then
      CopyFile(License, CudaDirectory + '\LICENSE-NVIDIA-CUDA.txt', False);
  end;
end;

{ ---- Wizard ---------------------------------------------------------------- }

procedure InitializeWizard;
begin
  ModelDownloadPage := CreateDownloadPage('AI 구성 요소 다운로드',
    '다운로드 후 크기와 SHA-256을 검증합니다. 취소하거나 건너뛰어도 설정 메뉴(Ctrl+N → AI 구성 요소 관리)에서 받을 수 있습니다.', nil);
  ModelDownloadPage.ShowBaseNameInsteadOfUrl := True;

  ExtractTemporaryFile('LICENSE-NVIDIA-CUDA.txt');
  CudaLicensePage := CreateCustomPage(wpSelectTasks, 'NVIDIA CUDA 라이선스',
    'CUDA 가속 구성 요소(NVIDIA CUDA 엔진, cuBLAS)를 내려받으려면 라이선스에 동의해야 합니다.');
  CudaLicenseMemo := TNewMemo.Create(CudaLicensePage);
  CudaLicenseMemo.Parent := CudaLicensePage.Surface;
  CudaLicenseMemo.Left := 0;
  CudaLicenseMemo.Top := 0;
  CudaLicenseMemo.Width := CudaLicensePage.SurfaceWidth;
  CudaLicenseMemo.Height := CudaLicensePage.SurfaceHeight - ScaleY(32);
  CudaLicenseMemo.ScrollBars := ssVertical;
  CudaLicenseMemo.ReadOnly := True;
  CudaLicenseMemo.WordWrap := True;
  CudaLicenseMemo.Lines.LoadFromFile(ExpandConstant('{tmp}\LICENSE-NVIDIA-CUDA.txt'));
  CudaLicenseAccept := TNewCheckBox.Create(CudaLicensePage);
  CudaLicenseAccept.Parent := CudaLicensePage.Surface;
  CudaLicenseAccept.Left := 0;
  CudaLicenseAccept.Top := CudaLicenseMemo.Height + ScaleY(8);
  CudaLicenseAccept.Width := CudaLicensePage.SurfaceWidth;
  CudaLicenseAccept.Height := ScaleY(20);
  CudaLicenseAccept.Caption := '위 NVIDIA CUDA 라이선스 조건에 동의합니다';
  CudaLicenseAccept.Checked := False;
end;

function ShouldSkipPage(PageID: Integer): Boolean;
begin
  Result := False;
  if PageID = CudaLicensePage.ID then
    Result := not CudaDownloadWanted;
end;

function UpdateReadyMemo(Space, NewLine, MemoUserInfoInfo, MemoDirInfo, MemoTypeInfo,
  MemoComponentsInfo, MemoGroupInfo, MemoTasksInfo: String): String;
var
  I: Integer;
  Bytes: Int64;
  ToolkitDir: String;
begin
  Result := '';
  if MemoDirInfo <> '' then Result := Result + MemoDirInfo + NewLine + NewLine;
  if MemoGroupInfo <> '' then Result := Result + MemoGroupInfo + NewLine + NewLine;
  if MemoTasksInfo <> '' then Result := Result + MemoTasksInfo;
  if CudaWanted then begin
    ToolkitDir := FindToolkitDirectory;
    Bytes := 0;
    for I := 0 to {#ComponentCount} - 1 do
      if ComponentWanted(I, ToolkitDir) and
         not FileExists(CudaDirectory + '\' + ComponentFilename(I)) then
        Bytes := Bytes + ComponentSize(I);
    Result := Result + NewLine + NewLine + 'CUDA 가속 구성 요소:' + NewLine;
    if ToolkitDir <> '' then
      Result := Result + Space + 'cuBLAS: CUDA Toolkit 사용 (' + ToolkitDir + ') - 내려받기 없음' + NewLine
    else
      Result := Result + Space + '설치 위치: ' + CudaDirectory + NewLine +
        Space + 'cuBLAS: 내려받기, 약 ' + IntToStr((Bytes + 1048575) div 1048576) + ' MiB';
  end;
end;

function NextButtonClick(CurPageID: Integer): Boolean;
var
  Error: String;
begin
  Result := True;
  // Silent setup still invokes page callbacks. /TASKS=cuda_accel is explicit
  // acceptance; downloads run once in PrepareToInstall, without wizard UI.
  if WizardSilent then Exit;
  if CurPageID = CudaLicensePage.ID then begin
    if not CudaLicenseAccept.Checked then begin
      MsgBox('CUDA 가속 구성 요소를 받으려면 라이선스에 동의해야 합니다.' + #13#10 +
        '동의하지 않으면 이전 화면에서 CUDA 가속 항목을 해제하세요 (CPU 엔진은 기본 포함).', mbInformation, MB_OK);
      Result := False;
    end;
    Exit;
  end;
  if CurPageID <> wpReady then Exit;
  if not (AnyModelWanted or CudaDownloadWanted or YoutubeWanted) then Exit;
  if CudaDownloadWanted and not DriverAsked and not NvidiaDriverPresent then begin
    DriverAsked := True;
    if SuppressibleMsgBox('NVIDIA 드라이버(nvcuda.dll)를 찾을 수 없습니다. CUDA 가속은 NVIDIA GPU와 드라이버가 있어야 동작합니다.' + #13#10 +
        '그래도 CUDA 구성 요소를 내려받으시겠습니까? (아니오: 돌아가서 항목을 해제하면 CPU만으로 설치됩니다)',
        mbConfirmation, MB_YESNO, IDYES) = IDNO then begin
      Result := False;
      Exit;
    end;
  end;
  ModelDownloadPage.Clear;
  ModelDownloadPage.Show;
  try
    try
      PrepareDownloads(True);
    except
      if ModelDownloadPage.AbortedByUser then
        Log('Download cancelled; task choices can be changed.')
      else begin
        Error := GetExceptionMessage;
        SuppressibleMsgBox(Error + #13#10 +
          '이미 받은 파일은 보존됩니다. 모델/CUDA/YouTube 항목을 해제하면 (CPU 엔진은 기본 포함) 설치를 계속할 수 있고, ' +
          '설치 후 설정 메뉴(Ctrl+N → AI 구성 요소 관리)에서 다시 받을 수 있습니다.',
          mbError, MB_OK, IDOK);
      end;
      Result := False;
    end;
  finally
    ModelDownloadPage.Hide;
  end;
end;

// Gate installation before any files are installed. In silent mode a returned
// error aborts setup with a nonzero exit instead of an unsuppressible code dialog.
function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := '';
  if WizardSilent and (AnyModelWanted or CudaDownloadWanted or YoutubeWanted) then begin
    try
      if CudaDownloadWanted and not NvidiaDriverPresent then
        Log('NVIDIA driver (nvcuda.dll) not found; CUDA components are fetched because the task was selected.');
      PrepareDownloads(False);
    except
      Result := 'Requested component download failed: ' + GetExceptionMessage +
        '. Run setup with /TASKS= to install the CPU player without downloads.';
      Log(Result);
    end;
  end;
end;
