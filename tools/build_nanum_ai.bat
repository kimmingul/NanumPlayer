@echo off
rem Builds separate CPU and optional CUDA engines with the same C ABI.
setlocal
call "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat" || exit /b 1
set "CUDA_PATH=C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v13.0"
set "PATH=%CUDA_PATH%\bin;C:\Program Files\CMake\bin;C:\Program Files\Microsoft Visual Studio\18\Insiders\Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja;%PATH%"
set "SRC=%~dp0..\nanum_ai"
if /i "%~1"=="cuda" goto cuda
set "OUT=%~dp0..\build\nanum_ai_cpu"
cmake -S "%SRC%" -B "%OUT%" -G Ninja -DCMAKE_BUILD_TYPE=Release -DNANUM_AI_CUDA=OFF || exit /b 1
cmake --build "%OUT%" --target nanum_ai nanum_ai_test -j 8 || exit /b 1
if /i "%~1"=="cpu" exit /b 0
:cuda
set "OUT=%~dp0..\build\nanum_ai_cuda"
cmake -S "%SRC%" -B "%OUT%" -G Ninja -DCMAKE_BUILD_TYPE=Release -DNANUM_AI_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=86 || exit /b 1
cmake --build "%OUT%" --target nanum_ai nanum_ai_test -j 8 || exit /b 1
