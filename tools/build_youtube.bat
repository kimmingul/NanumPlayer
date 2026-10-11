@echo off
rem Builds the YouTube browser helper: build\youtube\nanum_youtube.exe (MSVC + WebView2 static loader).
rem The Microsoft.Web.WebView2 SDK is fetched from NuGet into build\youtube on first use; the .nupkg
rem is pinned by version and verified against the SHA-256 below before it is unpacked.
setlocal
set "WV2_VER=1.0.4258.31"
set "WV2_SHA256=56f7f4b8bf9aee4b8efefbbdd4f67d5f74ebd1b100ed0806da71bf76af481aa9"
set "SRC=%~dp0..\youtube"
set "OUT=%~dp0..\build\youtube"
set "PKG=%OUT%\Microsoft.Web.WebView2.%WV2_VER%"
set "NUPKG=%OUT%\Microsoft.Web.WebView2.%WV2_VER%.nupkg"
set "WV2_URL=https://api.nuget.org/v3-flatcontainer/microsoft.web.webview2/%WV2_VER%/microsoft.web.webview2.%WV2_VER%.nupkg"
if not exist "%OUT%" mkdir "%OUT%"
if exist "%PKG%\.verified" goto compile

if exist "%NUPKG%" goto verify
echo Downloading Microsoft.Web.WebView2 %WV2_VER% ...
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ProgressPreference='SilentlyContinue'; [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -UseBasicParsing -Uri $env:WV2_URL -OutFile $env:NUPKG" || exit /b 1
:verify
powershell -NoProfile -ExecutionPolicy Bypass -Command "if ((Get-FileHash -Algorithm SHA256 -LiteralPath $env:NUPKG).Hash -ne $env:WV2_SHA256) { exit 1 }"
if errorlevel 1 (
  echo ERROR: SHA-256 mismatch for %NUPKG%; deleting it.
  del "%NUPKG%"
  exit /b 1
)
if exist "%PKG%" rmdir /s /q "%PKG%"
powershell -NoProfile -ExecutionPolicy Bypass -Command "Add-Type -AssemblyName System.IO.Compression.FileSystem; [IO.Compression.ZipFile]::ExtractToDirectory($env:NUPKG, $env:PKG)" || exit /b 1
echo verified> "%PKG%\.verified"

:compile
call "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat" || exit /b 1
pushd "%SRC%"
rc /nologo /fo "%OUT%\nanum_youtube.res" nanum_youtube.rc || (popd & exit /b 1)
popd
cl /nologo /std:c++17 /EHsc /O2 /MT /W3 /utf-8 /DUNICODE /D_UNICODE ^
  /I"%PKG%\build\native\include" "%SRC%\nanum_youtube.cpp" "%OUT%\nanum_youtube.res" ^
  /Fo"%OUT%\\" /Fe"%OUT%\nanum_youtube.exe" ^
  /link /SUBSYSTEM:WINDOWS /MANIFEST:NO "%PKG%\build\native\x64\WebView2LoaderStatic.lib" || exit /b 1
echo Built %OUT%\nanum_youtube.exe
