; NanumPlayer installer. Built by tools\package.py (passes /DAppVersion, /DStageDir,
; /DModelCatalogFile, /DComponentCatalogFile and /DDiscCatalogFile).
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
#ifndef DiscCatalogFile
#error Package with tools/package.py to generate the pinned optional disc component catalogue.
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

; Wizard texts: Inno's own translations (compiler:Languages) plus the pinned upstream Chinese
; ones in tools\languages (see the provenance header there). English is first on purpose: Setup
; falls back to the first language when the Windows UI language is not one of these six, and the
; player falls back to English in that case too. The Nanum texts (tasks, pages, messages) are
; the CustomMessages of NanumMessages.iss, one block per language.
[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "korean"; MessagesFile: "compiler:Languages\Korean.isl"
Name: "japanese"; MessagesFile: "compiler:Languages\Japanese.isl"
Name: "chinesesimplified"; MessagesFile: "languages\ChineseSimplified.isl"
Name: "chinesetraditional"; MessagesFile: "languages\ChineseTraditional.isl"
Name: "spanish"; MessagesFile: "compiler:Languages\Spanish.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked
Name: "model_english"; Description: "{cm:TaskModelEnglish}"; GroupDescription: "{cm:GroupModels}"; Flags: unchecked
Name: "model_multilingual"; Description: "{cm:TaskModelMultilingual}"; GroupDescription: "{cm:GroupModels}"; Flags: unchecked
Name: "model_multilingual_large"; Description: "{cm:TaskModelLarge}"; GroupDescription: "{cm:GroupModels}"; Flags: unchecked
Name: "model_vad"; Description: "{cm:TaskModelVad}"; GroupDescription: "{cm:GroupModels}"; Flags: unchecked
Name: "cuda_accel"; Description: "{cm:TaskCuda}"; GroupDescription: "{cm:GroupAccel}"; Flags: unchecked
Name: "youtube_tools"; Description: "{cm:TaskYoutube}"; GroupDescription: "{cm:GroupYoutube}"; Flags: unchecked
; Not part of the default package: the copy protection circumvention libraries (libaacs, libbdplus,
; libdvdcss) are a separate optional download, pinned like the other components.
Name: "disc_components"; Description: "{cm:TaskDisc}"; GroupDescription: "{cm:GroupDisc}"; Flags: unchecked

#include "languages\NanumMessages.iss"

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
; user settings/caches in %APPDATA%\NanumPlayer, models, CUDA and disc components in %LOCALAPPDATA%\NanumPlayer are kept on purpose
Type: files; Name: "{app}\*.tmp"

[Code]
var
  ModelDownloadPage: TDownloadWizardPage;
  CudaLicensePage: TWizardPage;
  CudaLicenseMemo: TNewMemo;
  CudaLicenseAccept: TNewCheckBox;
  DriverAsked: Boolean;
  TasksAnnotated: Boolean;
  ToolkitKnown: Boolean;
  ToolkitMemo: String;

function M(const Key: String): String;
begin
  Result := CustomMessage(Key);
end;

function MF(const Key, Arg1: String): String;
begin
  Result := FmtMessage(CustomMessage(Key), [Arg1]);
end;

function MF2(const Key, Arg1, Arg2: String): String;
begin
  Result := FmtMessage(CustomMessage(Key), [Arg1, Arg2]);
end;

#include ModelCatalogFile
#include ComponentCatalogFile
#include DiscCatalogFile

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

// The optional Blu-ray/DVD decryption components (the player's disc component manager uses the same
// folder and checks the same pinned file list before it loads anything).
function DiscDirectory: String;
begin
  Result := ExpandConstant('{localappdata}\NanumPlayer\components\disc\{#DiscVersion}');
end;

function DiscWanted: Boolean;
begin
  Result := WizardIsTaskSelected('disc_components');
end;

function DiscFilePath(const Root: String; Index: Integer): String;
var
  Name: String;
begin
  Name := DiscFileFilename(Index);
  StringChangeEx(Name, '/', '\', True);
  Result := Root + '\' + Name;
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

// The downloaded cuBLAS pair (the Toolkit's is looked for separately). The CUDA engine is
// bundled in the application folder, never cached or downloaded.
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
  Result := CudaRuntimeWanted;
end;

// Only the cuBLAS pair is ever downloaded; the CUDA engine ships in the application folder.
function ComponentWanted(Index: Integer): Boolean;
begin
  Result := (Index <> EngineIndex) and CudaRuntimeWanted;
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
      RaiseException(MF('ErrSave', Partial));
    if not VerifiedFile(Partial, Size, Hash) then
      RaiseException(MF('ErrIntegrity', Name));
    if not MoveFileEx(Partial, Destination, 9) then
      RaiseException(MF('ErrApply', Destination));
    if Downloaded then DeleteFile(Source);
  finally
    DeleteFile(Partial);
  end;
end;

{ ---- Blu-ray/DVD decryption components (optional) ------------------------------- }
{ One pinned ZIP; every file of the pinned list is verified (name, size, SHA-256) after it is
  unpacked into a staging folder, and only then is the folder renamed into place. }

function DiscFilesVerified(const Root: String): Boolean;
var
  I: Integer;
begin
  Result := DirExists(Root);
  for I := 0 to {#DiscFileCount} - 1 do
    if Result then
      Result := VerifiedFile(DiscFilePath(Root, I), DiscFileSize(I), DiscFileHash(I));
end;

procedure PrepareDisc(Interactive: Boolean);
var
  Stage, Zip: String;
  Code: Integer;
begin
  if DiscFilesVerified(DiscDirectory) then begin
    Log('Disc components already installed and verified: ' + DiscDirectory);
    Exit;
  end;
  if not ForceDirectories(ExtractFileDir(DiscDirectory)) then
    RaiseException(MF('ErrDiscDir', DiscDirectory));
  if Interactive then begin
    ModelDownloadPage.Clear;
    ModelDownloadPage.Add(DiscPackURL(0), DiscPackFilename(0), DiscPackHash(0));
    ModelDownloadPage.Download;
  end else
    DownloadTemporaryFile(DiscPackURL(0), DiscPackFilename(0), DiscPackHash(0), nil);
  Zip := ExpandConstant('{tmp}\') + DiscPackFilename(0);
  Stage := DiscDirectory + '.setup-part';
  try
    DelTree(Stage, True, True, True);
    if not ForceDirectories(Stage) then
      RaiseException(MF('ErrDiscDir', Stage));
    if not Exec(ExpandConstant('{sys}\tar.exe'), '-xf "' + Zip + '" -C "' + Stage + '"', '',
                SW_HIDE, ewWaitUntilTerminated, Code) or (Code <> 0) then
      RaiseException(M('ErrDiscUnpack'));
    if not DiscFilesVerified(Stage) then
      RaiseException(MF('ErrIntegrity', DiscPackFilename(0)));
    if DirExists(DiscDirectory) then
      DelTree(DiscDirectory, True, True, True);
    if not MoveFileEx(Stage, DiscDirectory, 8) then
      RaiseException(MF('ErrApply', DiscDirectory));
  finally
    DelTree(Stage, True, True, True);
    DeleteFile(Zip);
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
    RaiseException(MF('ErrReleaseRead', Repository));
  P := Pos('"tag_name"', String(Json));
  if P = 0 then RaiseException(MF('ErrReleaseFormat', Repository));
  Rest := Copy(String(Json), P + 10, 200);
  P := Pos('"', Rest);
  Rest := Copy(Rest, P + 1, 100);
  P := Pos('"', Rest);
  Result := Copy(Rest, 1, P - 1);
  if Result = '' then RaiseException(MF('ErrReleaseTagMissing', Repository));
  for I := 1 to Length(Result) do
    if not (((Result[I] >= '0') and (Result[I] <= '9')) or ((Result[I] >= 'a') and (Result[I] <= 'z')) or
            ((Result[I] >= 'A') and (Result[I] <= 'Z')) or (Result[I] = '.') or (Result[I] = '-') or
            (Result[I] = '_')) then
      RaiseException(MF('ErrReleaseTagInvalid', Repository));
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
    RaiseException(MF('ErrYoutubeDir', Dir));

  Tag := LatestTag('yt-dlp/yt-dlp');
  if StampTagOf(Dir + '\yt-dlp.exe') = Tag then
    Log('yt-dlp ' + Tag + ' is already installed (latest), not downloaded again')
  else begin
    Base := 'https://github.com/yt-dlp/yt-dlp/releases/download/' + Tag + '/';
    DownloadTemporaryFile(Base + 'SHA2-256SUMS', 'ytdlp-SHA2-256SUMS', '', nil);
    Hash := ChecksumOf(ExpandConstant('{tmp}\ytdlp-SHA2-256SUMS'), 'yt-dlp.exe');
    if Hash = '' then RaiseException(M('ErrYtdlpChecksum'));
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
  if Hash = '' then RaiseException(M('ErrDenoChecksum'));
  FetchToTemp(Base + DenoZip, DenoZip, Hash, Interactive);
  Zip := ExpandConstant('{tmp}\') + DenoZip;
  Unpacked := ExpandConstant('{tmp}\deno-unpacked');
  Partial := Dir + '\deno.exe.setup.part';
  try
    if not ForceDirectories(Unpacked) then
      RaiseException(MF('ErrTempDir', Unpacked));
    if not Exec(ExpandConstant('{sys}\tar.exe'), '-xf "' + Zip + '" -C "' + Unpacked + '" deno.exe', '',
                SW_HIDE, ewWaitUntilTerminated, Code) or (Code <> 0) or not FileExists(Unpacked + '\deno.exe') then
      RaiseException(M('ErrDenoUnpack'));
    if not CopyFile(Unpacked + '\deno.exe', Partial, False) then
      RaiseException(MF('ErrSave', Partial));
    if not MoveFileEx(Partial, Dir + '\deno.exe', 9) then
      RaiseException(MF('ErrApply', Dir + '\deno.exe'));
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
      RaiseException(MF('ErrModelDir', ModelDirectory));
    for I := 0 to {#ModelCount} - 1 do begin
      if ModelWanted(I) then begin
        Legacy := ExpandConstant('{app}\models\') + ModelFilename(I);
        EnsureFile(ModelURL(I), ModelFilename(I), ModelHash(I), ModelSize(I),
          ModelDirectory + '\' + ModelFilename(I), Legacy, Interactive);
      end;
    end;
  end;
  if YoutubeWanted then PrepareYoutube(Interactive);
  if DiscWanted then PrepareDisc(Interactive);
  if CudaWanted then begin
    ToolkitDir := FindToolkitDirectory;
    if ToolkitDir <> '' then
      Log('CUDA Toolkit found, no cuBLAS download needed: ' + ToolkitDir);
  end;
  if CudaDownloadWanted then begin
    if not ForceDirectories(CudaDirectory) then
      RaiseException(MF('ErrCudaDir', CudaDirectory));
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

// "installed (a, b) / missing (c)" for the speech models.
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
  if Have <> '' then Result := MF('SumInstalled', Have);
  if Lack <> '' then begin
    if Result <> '' then Result := Result + ' / ';
    Result := Result + MF('SumMissing', Lack);
  end;
end;

function CudaSummary: String;
var
  Tk, Gpu: String;
begin
  Tk := FindToolkitDirectory;
  Result := M('SumEngine') + '; ';
  if Tk <> '' then Result := Result + MF('SumCublas', MF('SumToolkit', ToolkitVersionOf(Tk)))
  else if CudaCacheComplete then Result := Result + MF('SumCublas', M('SumCublasCached'))
  else Result := Result + MF('SumCublas', M('SumCublasNone'));
  if NvidiaDriverPresent then begin
    Gpu := NvidiaGpuName;
    if Gpu = '' then Gpu := M('SumDriverPresent');
    Result := Result + '; ' + MF('SumDriver', Gpu);
  end else
    Result := Result + '; ' + MF('SumDriver', M('SumDriverNone'));
end;

function YoutubeSummary: String;
begin
  if YoutubeToolsInstalled then
    Result := MF2('SumYoutubeOk', YtdlpTag, DenoTag)
  else if FileExists(YoutubeDirectory + '\yt-dlp.exe') or FileExists(YoutubeDirectory + '\deno.exe') then
    Result := M('SumYoutubePartial')
  else
    Result := M('SumYoutubeNone');
end;

// One line of the pre-installation check block (0..5): the state of a library or program.
function PreflightLine(Index: Integer): String;
var
  V: String;
begin
  Result := '';
  case Index of
    0: Result := MF('PreModels', ModelSummary);
    1: Result := MF('PreCuda', CudaSummary);
    2: Result := MF('PreYoutube', YoutubeSummary);
    3: begin
         V := WebView2Version;
         if V <> '' then Result := MF('PreWebView2Ok', V)
         else Result := M('PreWebView2No');
       end;
    4: begin
         V := OllamaPath;
         if V <> '' then Result := MF('PreOllamaOk', V)
         else Result := M('PreOllamaNo');
       end;
    5: Result := M('PreDisk');
  end;
end;

// The pre-installation check block: information only, nothing is installed without the user's choice.
function PreflightText(const Space, NewLine: String): String;
var
  I: Integer;
begin
  Result := M('PreTitle');
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
  Log('Task disc_components selected: ' + IntToStr(Ord(DiscWanted)));
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
        ItemCaption[I] := ItemCaption[I] + ' ' + Note;
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
  if ModelTaskInstalled('english') then AnnotateTask(M('TaskModelEnglish'), M('NoteInstalled'), True);
  if ModelTaskInstalled('multilingual') then AnnotateTask(M('TaskModelMultilingual'), M('NoteInstalled'), True);
  if ModelTaskInstalled('multilingual_large') then AnnotateTask(M('TaskModelLarge'), M('NoteInstalled'), True);
  if ModelTaskInstalled('vad') then AnnotateTask(M('TaskModelVad'), M('NoteInstalled'), True);
  Tk := FindToolkitDirectory;
  if Tk <> '' then
    AnnotateTask(M('TaskCuda'), MF('NoteToolkit', ToolkitVersionOf(Tk)), True)
  else if CudaCacheComplete then
    AnnotateTask(M('TaskCuda'), M('NoteCublasCached'), True)
  else if not NvidiaDriverPresent then
    AnnotateTask(M('TaskCuda'), M('NoteNoDriver'), True)
  else
    AnnotateTask(M('TaskCuda'), M('NoteCublasOnly'), False);
  if YoutubeToolsInstalled then
    AnnotateTask(M('TaskYoutube'), M('NoteYoutubeInstalled'), False);
  if DiscFilesVerified(DiscDirectory) then
    AnnotateTask(M('TaskDisc'), M('NoteInstalled'), True);
end;

{ ---- Wizard ---------------------------------------------------------------- }


procedure InitializeWizard;
begin
  ModelDownloadPage := CreateDownloadPage(M('DownloadTitle'), M('DownloadDesc'), nil);
  ModelDownloadPage.ShowBaseNameInsteadOfUrl := True;

  ExtractTemporaryFile('LICENSE-NVIDIA-CUDA.txt');
  CudaLicensePage := CreateCustomPage(wpSelectTasks, M('LicenseTitle'), M('LicenseDesc'));
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
  CudaLicenseAccept.Caption := M('LicenseAccept');
  CudaLicenseAccept.Checked := False;

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
    Result := Result + NewLine + NewLine + M('ReadyCudaHeader') + NewLine;
    if Bytes > 0 then Result := Result + Space + MF('ReadyLocation', CudaDirectory) + NewLine;
    Result := Result + Space + M('ReadyEngine') + NewLine;
    if ToolkitDir <> '' then
      Result := Result + Space + MF('ReadyCublasToolkit', ToolkitDir) + NewLine
    else if CudaCacheComplete then
      Result := Result + Space + M('ReadyCublasInstalled') + NewLine
    else
      Result := Result + Space + M('ReadyCublasDownload') + NewLine;
    Result := Result + Space + MF('ReadyDownloadSize', IntToStr((Bytes + 1048575) div 1048576));
  end;
  if DiscWanted and not DiscFilesVerified(DiscDirectory) then begin
    Result := Result + NewLine + NewLine + M('ReadyDiscHeader') + NewLine;
    Result := Result + Space + MF('ReadyLocation', DiscDirectory) + NewLine;
    Result := Result + Space + MF('ReadyDownloadSize', IntToStr((DiscPackSize(0) + 1048575) div 1048576));
  end;
  // An upgrade removes the decryption libraries of earlier versions (they are an optional
  // component now): say so, and how to get them back.
  if (not DiscWanted) and FileExists(AddBackslash(WizardDirValue) + 'disc\libaacs.dll') and
     not DiscFilesVerified(DiscDirectory) then
    Result := Result + NewLine + NewLine + M('ReadyDiscLegacy');
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
      MsgBox(M('LicenseRequired'), mbInformation, MB_OK);
      Result := False;
    end;
    Exit;
  end;
  if CurPageID <> wpReady then Exit;
  // The notice of the optional decryption components is shown before anything is downloaded.
  if DiscWanted and not DiscFilesVerified(DiscDirectory) then
    if MsgBox(M('DiscNotice'), mbConfirmation, MB_YESNO or MB_DEFBUTTON2) = IDNO then begin
      Result := False;
      Exit;
    end;
  if not (AnyModelWanted or CudaDownloadWanted or YoutubeWanted or DiscWanted) then Exit;
  if CudaDownloadWanted and not DriverAsked and not NvidiaDriverPresent then begin
    DriverAsked := True;
    if SuppressibleMsgBox(M('DriverMissing'),
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
        SuppressibleMsgBox(MF('DownloadFailedHint', Error),
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
  if WizardSilent and (AnyModelWanted or CudaDownloadWanted or YoutubeWanted or DiscWanted) then begin
    try
      if CudaDownloadWanted and not NvidiaDriverPresent then
        Log('NVIDIA driver (nvcuda.dll) not found; CUDA components are fetched because the task was selected.');
      PrepareDownloads(False);
    except
      Result := MF('SilentDownloadFailed', GetExceptionMessage);
      Log(Result);
    end;
  end;
end;

// The language code the player understands (shared contract order ko, en, ja, zh-CN, zh-TW, es)
// for the language chosen in this wizard.
function PlayerUiLanguage: String;
var
  Lang: String;
begin
  Lang := ActiveLanguage;
  if Lang = 'korean' then Result := 'ko'
  else if Lang = 'japanese' then Result := 'ja'
  else if Lang = 'chinesesimplified' then Result := 'zh-CN'
  else if Lang = 'chinesetraditional' then Result := 'zh-TW'
  else if Lang = 'spanish' then Result := 'es'
  else Result := 'en';
end;

// First install only: when the player has no saved interface language yet, store the wizard's
// choice so the player starts in the same language. An existing preference (upgrade) is kept.
// This is only the interface language; AI source/target languages are separate settings.
procedure CurStepChanged(CurStep: TSetupStep);
var
  Dir, Conf: String;
begin
  if CurStep <> ssPostInstall then Exit;
  Dir := ExpandConstant('{userappdata}\NanumPlayer');
  Conf := Dir + '\ui-language.conf';
  if FileExists(Conf) then begin
    Log('Interface language preference kept: ' + Conf);
    Exit;
  end;
  if not ForceDirectories(Dir) then begin
    Log('Cannot create ' + Dir + '; the player picks its interface language itself.');
    Exit;
  end;
  if SaveStringToFile(Conf, PlayerUiLanguage + #10, False) then
    Log('Interface language saved: ' + PlayerUiLanguage)
  else
    Log('Cannot save ' + Conf);
end;
