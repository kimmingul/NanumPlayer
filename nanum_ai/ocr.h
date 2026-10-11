// Text recognition of subtitle bitmaps with Windows.Media.Ocr (C++/WinRT, built into
// Windows 10/11, no model files). Thread safe: every call runs on its own short-lived
// thread with its own COM apartment, so callers in any apartment are fine.
#pragma once

#include <string>

namespace nanum {

// gray: 8-bit pixels, dark text on a light background preferred. lang: primary subtag
// ("en", "ja", ...). On success text holds the lines joined by "\n" (UTF-8); otherwise err
// says why (language pack not installed, ...). Bitmaps larger than the recogniser accepts
// are scaled down.
bool ocr_gray(const unsigned char *gray, int width, int height, int stride, const std::string &lang,
              std::string &text, std::string &err);

// Primary subtags of the installed OCR languages, comma separated ("en,ko"); "" when none.
std::string ocr_languages();

} // namespace nanum
