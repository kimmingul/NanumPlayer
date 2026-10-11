cmake_minimum_required(VERSION 3.20)
project(nanum_ai LANGUAGES C CXX)

# Language servers (clangd) read build/nanum_ai_cpu/compile_commands.json.
set(CMAKE_EXPORT_COMPILE_COMMANDS ON CACHE BOOL "" FORCE)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

option(NANUM_AI_CUDA "Build the optional NVIDIA CUDA engine" OFF)

if(NANUM_AI_CUDA)
    find_package(CUDAToolkit REQUIRED)
endif()
set(GGML_NATIVE OFF CACHE BOOL "" FORCE)
# whisper.cpp is linked statically into the DLL.
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_SERVER OFF CACHE BOOL "" FORCE)
set(WHISPER_CURL OFF CACHE BOOL "" FORCE)
set(GGML_CUDA ${NANUM_AI_CUDA} CACHE BOOL "" FORCE)
add_subdirectory(${CMAKE_CURRENT_SOURCE_DIR}/../third_party/whisper.cpp
                 ${CMAKE_BINARY_DIR}/whisper)

add_library(nanum_ai SHARED nanum_ai.cpp translator.cpp fulltranslate.cpp ocr.cpp)
target_compile_definitions(nanum_ai PRIVATE NANUM_AI_BUILD NOMINMAX WIN32_LEAN_AND_MEAN
                           _CRT_SECURE_NO_WARNINGS)
target_compile_options(nanum_ai PRIVATE /utf-8)
target_link_libraries(nanum_ai PRIVATE whisper winhttp windowsapp)
if(NANUM_AI_CUDA)
    set_target_properties(nanum_ai PROPERTIES OUTPUT_NAME nanum_ai_cuda)
    target_compile_definitions(nanum_ai PRIVATE NANUM_AI_CUDA=1)
    target_link_libraries(nanum_ai PRIVATE CUDA::cudart_static)
else()
    set_target_properties(nanum_ai PROPERTIES OUTPUT_NAME nanum_ai_cpu)
endif()

# The selftest drives the translator (cache rows) directly, so it compiles that unit itself.
add_executable(nanum_ai_test test_cli.cpp translator.cpp)
target_compile_definitions(nanum_ai_test PRIVATE _CRT_SECURE_NO_WARNINGS NOMINMAX WIN32_LEAN_AND_MEAN)
target_compile_options(nanum_ai_test PRIVATE /utf-8)
target_link_libraries(nanum_ai_test PRIVATE nanum_ai winhttp)
