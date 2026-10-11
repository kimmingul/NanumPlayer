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
Name: "cuda_accel"; Description: "NVIDIA CUDA 가속: 엔진 다운로드 (약 53 MiB, CUDA 13 Toolkit 없으면 cuBLAS 약 507 MiB 추가)"; GroupDescription: "AI 가속 (선택, 인터넷 연결 필요):"; Flags: unchecked
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
  BluRayPage: TWizardPage;
  BluRayText: TNewMemo;
  BluRayButton: TNewButton;
  DriverAsked: Boolean;
  TasksAnnotated: Boolean;
  ToolkitKnown: Boolean;
  ToolkitMemo: String;

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
function FindToolkitDirectoryUncached: String;
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

// The Toolkit does not change while the wizard runs; look once (registry + a few file stats).
function FindToolkitDirectory: String;
begin
  if not ToolkitKnown then begin
    ToolkitMemo := FindToolkitDirectoryUncached;
    ToolkitKnown := True;
  end;
  Result := ToolkitMemo;
end;

// "13.4" out of ...\CUDA\v13.4\bin\x64 ('' if the folder is not named like that).
function ToolkitVersionOf(const Dir: String): String;
var
  P, I: Integer;
  S: String;
begin
  Result := '';
  P := Pos('\v13.', Dir);
  if P = 0 then Exit;
  S := Copy(Dir, P + 2, 16);
  I := Pos('\', S);
  if I > 0 then S := Copy(S, 1, I - 1);
  Result := S;
end;

function ModelIndex(const Id: String): Integer;
var
  I: Integer;
begin
  Result := -1;
  for I := 0 to {#ModelCount} - 1 do
    if ModelID(I) = Id then Result := I;
end;

// Read-only existence check by size (the SHA-256 is verified when something is downloaded).
function FileHasSize(const Filename: String; Size: Int64): Boolean;
var
  Actual: Int64;
begin
  Result := FileExists(Filename) and FileSize64(Filename, Actual) and (Actual = Size);
end;

// The model in the user model folder, or (older installs) in <app>\models.
function ModelFileOk(Index: Integer): Boolean;
begin
  Result := (Index >= 0) and
    (FileHasSize(ModelDirectory + '\' + ModelFilename(Index), ModelSize(Index)) or
     FileHasSize(AddBackslash(WizardDirValue) + 'models\' + ModelFilename(Index), ModelSize(Index)));
end;

// A Whisper task counts as installed when its model and the VAD model are both there.
function ModelTaskInstalled(const TaskId: String): Boolean;
begin
  if TaskId = 'vad' then
    Result := ModelFileOk(ModelIndex('vad'))
  else
    Result := ModelFileOk(ModelIndex(TaskId)) and ModelFileOk(ModelIndex('vad'));
end;

function EngineIndex: Integer;
var
  I: Integer;
begin
  Result := -1;
  for I := 0 to {#ComponentCount} - 1 do
    if ComponentID(I) = 'cuda_engine' then Result := I;
end;

// The CUDA engine in the cache (size only; the SHA-256 is checked when it is downloaded, and
// by the player, which asks for the update of an older engine).
function CudaEngineInstalled: Boolean;
begin
  Result := (EngineIndex >= 0) and
    FileHasSize(CudaDirectory + '\' + ComponentFilename(EngineIndex), ComponentSize(EngineIndex));
end;

// The downloaded cuBLAS pair (the Toolkit's is looked for separately).
function CudaCacheComplete: Boolean;
var
  I: Integer;
begin
  Result := True;
  for I := 0 to {#ComponentCount} - 1 do
    if (I <> EngineIndex) and
       not FileHasSize(CudaDirectory + '\' + ComponentFilename(I), ComponentSize(I)) then
      Result := False;
end;

// cuBLAS (and with it NVIDIA's license) is only needed without a Toolkit and without the
// downloaded copy.
function CudaRuntimeWanted: Boolean;
begin
  Result := CudaWanted and (FindToolkitDirectory = '') and not CudaCacheComplete;
end;

function CudaDownloadWanted: Boolean;
begin
  Result := CudaWanted and (not CudaEngineInstalled or CudaRuntimeWanted);
end;

function ComponentWanted(Index: Integer): Boolean;
begin
  if Index = EngineIndex then
    Result := CudaWanted
  else
    Result := CudaRuntimeWanted;
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
  if VerifiedFile(Destination, Size, Hash) then begin
    Log('Already installed and verified, not downloaded again: ' + Destination);
    Exit;
  end;
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

// Tag recorded in <Exe>.version ("<tag>\n<size>\n") if the file still has that size, else ''.
function StampTagOf(const Exe: String): String;
var
  Text: AnsiString;
  S: String;
  P: Integer;
  Size: Int64;
begin
  Result := '';
  if not (FileExists(Exe) and LoadStringFromFile(Exe + '.version', Text)) then Exit;
  S := String(Text);
  P := Pos(#10, S);
  if P = 0 then Exit;
  if FileSize64(Exe, Size) and (Trim(Copy(S, P + 1, 40)) = IntToStr(Size)) then
    Result := Trim(Copy(S, 1, P - 1));
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
  if StampTagOf(Dir + '\yt-dlp.exe') = Tag then
    Log('yt-dlp ' + Tag + ' is already installed (latest), not downloaded again')
  else begin
    Base := 'https://github.com/yt-dlp/yt-dlp/releases/download/' + Tag + '/';
    DownloadTemporaryFile(Base + 'SHA2-256SUMS', 'ytdlp-SHA2-256SUMS', '', nil);
    Hash := ChecksumOf(ExpandConstant('{tmp}\ytdlp-SHA2-256SUMS'), 'yt-dlp.exe');
    if Hash = '' then RaiseException('yt-dlp 릴리스의 체크섬에서 yt-dlp.exe를 찾을 수 없습니다.');
    EnsureFile(Base + 'yt-dlp.exe', 'yt-dlp.exe', Hash, -1, Dir + '\yt-dlp.exe', '', Interactive);
    WriteVersionStamp(Dir + '\yt-dlp.exe', Tag);
  end;

  // Deno (the JavaScript runtime yt-dlp needs for YouTube) is only fetched when missing.
  if FileExists(Dir + '\deno.exe') then begin
    Log('Deno is already installed, not downloaded again: ' + Dir + '\deno.exe');
    Exit;
  end;
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
    for I := 0 to {#ComponentCount} - 1 do begin
      if ComponentWanted(I) then
        EnsureFile(ComponentURL(I), ComponentFilename(I), ComponentHash(I), ComponentSize(I),
          CudaDirectory + '\' + ComponentFilename(I), '', Interactive);
    end;
    if CudaRuntimeWanted then begin
      License := ExpandConstant('{tmp}\LICENSE-NVIDIA-CUDA.txt');
      if FileExists(License) then
        CopyFile(License, CudaDirectory + '\LICENSE-NVIDIA-CUDA.txt', False);
    end;
  end;
end;

{ ---- What is already on this PC (read-only, logged) ---------------------------- }

function NvidiaGpuName: String;
var
  I: Integer;
  Desc: String;
begin
  Result := '';
  for I := 0 to 9 do
    if (Result = '') and
       RegQueryStringValue(HKLM, 'SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}\000' +
                           IntToStr(I), 'DriverDesc', Desc) and (Pos('NVIDIA', Uppercase(Desc)) > 0) then
      Result := Desc;
end;

// Microsoft Edge WebView2 Runtime (Evergreen): its version, '' if not installed.
function WebView2Version: String;
var
  Key, V: String;
begin
  Result := '';
  Key := 'Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}';
  if RegQueryStringValue(HKLM, 'SOFTWARE\WOW6432Node\' + Key, 'pv', V) then Result := V;
  if (Result = '') and RegQueryStringValue(HKLM, 'SOFTWARE\' + Key, 'pv', V) then Result := V;
  if (Result = '') and RegQueryStringValue(HKCU, 'Software\' + Key, 'pv', V) then Result := V;
  if Result = '0.0.0.0' then Result := '';
end;

// ollama.exe of a per-user or machine-wide install, or on PATH. '' if none.
function OllamaPath: String;
begin
  Result := ExpandConstant('{localappdata}\Programs\Ollama\ollama.exe');
  if not FileExists(Result) then Result := ExpandConstant('{commonpf64}\Ollama\ollama.exe');
  if not FileExists(Result) then Result := FileSearch('ollama.exe', GetEnv('PATH'));
end;

// MakeMKV's libmmbd64.dll in the standard folders (as the player's auto-detection). '' if none.
function MakeMkvPath: String;
begin
  Result := ExpandConstant('{commonpf64}\MakeMKV\libmmbd64.dll');
  if not FileExists(Result) then Result := ExpandConstant('{commonpf32}\MakeMKV\libmmbd64.dll');
  if not FileExists(Result) then Result := '';
end;

function YtdlpTag: String;
begin
  Result := StampTagOf(YoutubeDirectory + '\yt-dlp.exe');
end;

function DenoTag: String;
begin
  Result := StampTagOf(YoutubeDirectory + '\deno.exe');
end;

function YoutubeToolsInstalled: Boolean;
begin
  Result := FileExists(YoutubeDirectory + '\yt-dlp.exe') and FileExists(YoutubeDirectory + '\deno.exe');
end;

// "설치됨(a, b) / 없음(c)" for the speech models.
function ModelSummary: String;
var
  I: Integer;
  Have, Lack, Name: String;
begin
  Have := '';
  Lack := '';
  for I := 0 to {#ModelCount} - 1 do begin
    Name := ModelID(I);
    if Name = 'english' then Name := 'small.en'
    else if Name = 'multilingual' then Name := 'small'
    else if Name = 'multilingual_large' then Name := 'large-v3-turbo'
    else if Name = 'vad' then Name := 'VAD';
    if ModelFileOk(I) then begin
      if Have <> '' then Have := Have + ', ';
      Have := Have + Name;
    end else begin
      if Lack <> '' then Lack := Lack + ', ';
      Lack := Lack + Name;
    end;
  end;
  Result := '';
  if Have <> '' then Result := '설치됨 (' + Have + ')';
  if Lack <> '' then begin
    if Result <> '' then Result := Result + ' / ';
    Result := Result + '없음 (' + Lack + ')';
  end;
end;

function CudaSummary: String;
var
  Tk, Gpu: String;
begin
  Tk := FindToolkitDirectory;
  Result := '엔진: ';
  if CudaEngineInstalled then Result := Result + '설치됨' else Result := Result + '없음 (약 53 MiB 받을 수 있음)';
  Result := Result + '; cuBLAS: ';
  if Tk <> '' then Result := Result + 'CUDA Toolkit v' + ToolkitVersionOf(Tk)
  else if CudaCacheComplete then Result := Result + '캐시 설치됨'
  else Result := Result + '없음 (CPU 사용, 약 507 MiB 받을 수 있음)';
  Result := Result + '; 드라이버: ';
  if NvidiaDriverPresent then begin
    Gpu := NvidiaGpuName;
    if Gpu <> '' then Result := Result + Gpu else Result := Result + '있음';
  end else
    Result := Result + '없음 (GPU 가속 불가)';
end;

function YoutubeSummary: String;
begin
  if YoutubeToolsInstalled then
    Result := '설치됨 (yt-dlp ' + YtdlpTag + ', Deno ' + DenoTag + ')'
  else if FileExists(YoutubeDirectory + '\yt-dlp.exe') or FileExists(YoutubeDirectory + '\deno.exe') then
    Result := '일부만 설치됨'
  else
    Result := '없음 (YouTube 재생에 필요)';
end;

// One line of the "설치 전 확인" block (0..5): the state of a library or program.
function PreflightLine(Index: Integer): String;
var
  V: String;
begin
  Result := '';
  case Index of
    0: Result := '음성 모델: ' + ModelSummary;
    1: Result := 'CUDA: ' + CudaSummary;
    2: Result := 'YouTube 도구: ' + YoutubeSummary;
    3: begin
         V := WebView2Version;
         if V <> '' then Result := 'WebView2 런타임: 설치됨 (' + V + ')'
         else Result := 'WebView2 런타임: 없음 (YouTube 창에 필요 - Windows 업데이트 또는 Microsoft에서 설치)';
       end;
    4: begin
         V := OllamaPath;
         if V <> '' then Result := 'Ollama: 설치됨 (' + V + ')'
         else Result := 'Ollama: 없음 (번역에 필요 - https://ollama.com)';
       end;
    5: begin
         V := MakeMkvPath;
         if V <> '' then Result := 'MakeMKV: 설치됨 (' + V + ')'
         else Result := 'MakeMKV: 없음 (Blu-ray 재생에 필요)';
       end;
  end;
end;

// The "설치 전 확인" block: information only, nothing is installed without the user's choice.
function PreflightText(const Space, NewLine: String): String;
var
  I: Integer;
begin
  Result := '설치 전 확인:';
  for I := 0 to 5 do
    Result := Result + NewLine + Space + PreflightLine(I);
end;

procedure LogDetection;
var
  I: Integer;
begin
  for I := 0 to 5 do
    Log('Detect: ' + PreflightLine(I));
  for I := 0 to {#ModelCount} - 1 do
    Log('Task model_' + ModelID(I) + ' selected: ' + IntToStr(Ord(WizardIsTaskSelected('model_' + ModelID(I)))) +
        ', model wanted: ' + IntToStr(Ord(ModelWanted(I))));
  Log('Task cuda_accel selected: ' + IntToStr(Ord(CudaWanted)) + ', download wanted: ' + IntToStr(Ord(CudaDownloadWanted)));
  Log('Task youtube_tools selected: ' + IntToStr(Ord(YoutubeWanted)));
end;

// Appends the state to the task's caption; Block unchecks and disables it (so a silent
// /TASKS request for something that is already satisfied is skipped too).
procedure AnnotateTask(const Prefix, Note: String; Block: Boolean);
var
  I: Integer;
begin
  with WizardForm.TasksList do
    for I := 0 to Items.Count - 1 do
      if Pos(Prefix, ItemCaption[I]) = 1 then begin
        if Block then
          Log('Task not needed' + Note + ': ' + ItemCaption[I])
        else
          Log('Task note' + Note + ': ' + ItemCaption[I]);
        ItemCaption[I] := ItemCaption[I] + Note;
        if Block then begin
          Checked[I] := False;
          ItemEnabled[I] := False;
        end;
      end;
end;

procedure AnnotateTasks;
var
  Tk: String;
begin
  if ModelTaskInstalled('english') then AnnotateTask('영어 음성 인식', ' — 이미 설치됨', True);
  if ModelTaskInstalled('multilingual') then AnnotateTask('다국어 음성 인식', ' — 이미 설치됨', True);
  if ModelTaskInstalled('multilingual_large') then AnnotateTask('다국어 고정밀', ' — 이미 설치됨', True);
  if ModelTaskInstalled('vad') then AnnotateTask('음성 감지 모델만', ' — 이미 설치됨', True);
  Tk := FindToolkitDirectory;
  if CudaEngineInstalled and (Tk <> '') then
    AnnotateTask('NVIDIA CUDA 가속', ' — 이미 설치됨 (엔진 + CUDA Toolkit v' + ToolkitVersionOf(Tk) + ')', True)
  else if CudaEngineInstalled and CudaCacheComplete then
    AnnotateTask('NVIDIA CUDA 가속', ' — 이미 설치됨', True)
  else if not NvidiaDriverPresent then
    AnnotateTask('NVIDIA CUDA 가속', ' — NVIDIA 드라이버 없음', True)
  else if Tk <> '' then
    AnnotateTask('NVIDIA CUDA 가속', ' — CUDA Toolkit v' + ToolkitVersionOf(Tk) + ' 감지됨, 엔진만 받음', False)
  else if CudaEngineInstalled then
    AnnotateTask('NVIDIA CUDA 가속', ' — 엔진은 설치됨, cuBLAS를 받음', False);
  if YoutubeToolsInstalled then
    AnnotateTask('YouTube 재생', ' — 이미 설치됨 (선택하면 최신 버전으로 업데이트)', False);
end;

{ ---- Wizard ---------------------------------------------------------------- }

procedure BluRayButtonClick(Sender: TObject);
var
  Code: Integer;
begin
  ShellExec('open', 'https://www.makemkv.com/download/', '', '', SW_SHOWNORMAL, ewNoWait, Code);
end;

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

  // Shown after the task/license pages when MakeMKV (libmmbd64.dll) is not installed.
  BluRayPage := CreateCustomPage(CudaLicensePage.ID, 'Blu-ray 재생 준비',
    'MakeMKV가 설치되어 있지 않습니다.');
  BluRayText := TNewMemo.Create(BluRayPage);
  BluRayText.Parent := BluRayPage.Surface;
  BluRayText.Left := 0;
  BluRayText.Top := 0;
  BluRayText.Width := BluRayPage.SurfaceWidth;
  BluRayText.Height := ScaleY(110);
  BluRayText.ScrollBars := ssNone;
  BluRayText.ReadOnly := True;
  BluRayText.WordWrap := True;
  BluRayText.Text :=
    '암호화된 Blu-ray를 재생하려면 MakeMKV가 필요합니다. MakeMKV는 별도 프로그램이라 NanumPlayer에 포함되지 않습니다. ' +
    '설치 후 한 번 실행해 활성화(베타 키 또는 구매 키)하세요. 동영상 파일·YouTube·암호화되지 않은 디스크는 ' +
    'MakeMKV 없이 재생됩니다. Blu-ray를 쓰지 않으면 다음을 누르세요.';
  BluRayButton := TNewButton.Create(BluRayPage);
  BluRayButton.Parent := BluRayPage.Surface;
  BluRayButton.Left := 0;
  BluRayButton.Top := BluRayText.Height + ScaleY(8);
  BluRayButton.Width := ScaleX(220);
  BluRayButton.Height := ScaleY(26);
  BluRayButton.Caption := 'MakeMKV 받기 페이지 열기';
  BluRayButton.OnClick := @BluRayButtonClick;
end;

procedure CurPageChanged(CurPageID: Integer);
begin
  if (CurPageID = wpSelectTasks) and not TasksAnnotated then begin
    TasksAnnotated := True;
    AnnotateTasks;
  end;
end;

function ShouldSkipPage(PageID: Integer): Boolean;
begin
  Result := False;
  if PageID = CudaLicensePage.ID then
    Result := not CudaRuntimeWanted;
  // Blu-ray preparation: only when MakeMKV is missing, never in a silent setup (the
  // detection line in the log says it).
  if PageID = BluRayPage.ID then
    Result := WizardSilent or (MakeMkvPath <> '');
end;

function UpdateReadyMemo(Space, NewLine, MemoUserInfoInfo, MemoDirInfo, MemoTypeInfo,
  MemoComponentsInfo, MemoGroupInfo, MemoTasksInfo: String): String;
var
  I: Integer;
  Bytes: Int64;
  ToolkitDir: String;
begin
  Result := PreflightText(Space, NewLine) + NewLine + NewLine;
  if MemoDirInfo <> '' then Result := Result + MemoDirInfo + NewLine + NewLine;
  if MemoGroupInfo <> '' then Result := Result + MemoGroupInfo + NewLine + NewLine;
  if MemoTasksInfo <> '' then Result := Result + MemoTasksInfo;
  if CudaWanted then begin
    ToolkitDir := FindToolkitDirectory;
    Bytes := 0;
    for I := 0 to {#ComponentCount} - 1 do
      if ComponentWanted(I) and
         not FileHasSize(CudaDirectory + '\' + ComponentFilename(I), ComponentSize(I)) then
        Bytes := Bytes + ComponentSize(I);
    Result := Result + NewLine + NewLine + 'CUDA 가속 구성 요소:' + NewLine;
    if Bytes > 0 then Result := Result + Space + '설치 위치: ' + CudaDirectory + NewLine;
    if CudaEngineInstalled then Result := Result + Space + '엔진: 이미 설치됨' + NewLine
    else Result := Result + Space + '엔진: 내려받기' + NewLine;
    if ToolkitDir <> '' then
      Result := Result + Space + 'cuBLAS: CUDA Toolkit 사용 (' + ToolkitDir + ') - 내려받기 없음' + NewLine
    else if CudaCacheComplete then
      Result := Result + Space + 'cuBLAS: 이미 설치됨' + NewLine
    else
      Result := Result + Space + 'cuBLAS: 내려받기 (NVIDIA 라이선스 동의 필요)' + NewLine;
    Result := Result + Space + '내려받기 필요: 약 ' + IntToStr((Bytes + 1048575) div 1048576) + ' MiB';
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
  LogDetection;
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
