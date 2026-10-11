#include "ocr.h"

#include <windows.h>

#include <roapi.h>
#include <unknwn.h>

#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Globalization.h>
#include <winrt/Windows.Graphics.Imaging.h>
#include <winrt/Windows.Media.Ocr.h>
#include <winrt/Windows.Storage.Streams.h>

#include <algorithm>
#include <cstdint>
#include <functional>
#include <mutex>
#include <thread>
#include <vector>

// Raw access to the bytes of an IBuffer (robuffer.h is not available to desktop builds).
struct __declspec(uuid("905a0fef-bc53-11df-8c49-001e4fc686da")) IBufferByteAccess : ::IUnknown {
    virtual HRESULT __stdcall Buffer(uint8_t **value) = 0;
};

namespace nanum {
namespace {

using namespace winrt::Windows::Globalization;
using namespace winrt::Windows::Graphics::Imaging;
using namespace winrt::Windows::Media::Ocr;
using namespace winrt::Windows::Storage::Streams;

std::string utf8(const winrt::hstring &h)
{
    if (h.empty())
        return "";
    int n = WideCharToMultiByte(CP_UTF8, 0, h.c_str(), (int)h.size(), nullptr, 0, nullptr, nullptr);
    std::string s(n, '\0');
    WideCharToMultiByte(CP_UTF8, 0, h.c_str(), (int)h.size(), s.data(), n, nullptr, nullptr);
    return s;
}

std::string primary_subtag(const std::string &tag)
{
    std::string p = tag.substr(0, tag.find_first_of("-_"));
    for (char &c : p)
        c = (char)std::tolower((unsigned char)c);
    return p;
}

// Runs fn on a new thread in a multithreaded apartment (blocking on WinRT async operations
// is then allowed) and waits for it. Failures of the Windows runtime become error text.
// The process-wide MTA is kept alive for good: when the last thread leaves it, Windows
// unloads the runtime classes, while C++/WinRT keeps their cached factories.
bool run_in_apartment(const std::function<bool(std::string &)> &fn, std::string &err)
{
    static std::once_flag mta_once;
    std::call_once(mta_once, [] {
        CO_MTA_USAGE_COOKIE cookie;
        CoIncrementMTAUsage(&cookie);
    });
    bool ok = false;
    std::thread([&] {
        HRESULT hr = RoInitialize(RO_INIT_MULTITHREADED);
        if (FAILED(hr)) {
            err = "cannot initialise the Windows runtime (" + std::to_string((long)hr) + ")";
            return;
        }
        try {
            ok = fn(err);
        } catch (const winrt::hresult_error &e) {
            err = "Windows OCR failed: " + utf8(e.message());
            ok = false;
        } catch (const std::exception &e) {
            err = std::string("Windows OCR failed: ") + e.what();
            ok = false;
        }
        RoUninitialize();
    }).join();
    return ok;
}

// The recogniser for a primary subtag among the installed languages; null engine and err set
// when none matches.
OcrEngine engine_for(const std::string &lang, std::string &err)
{
    std::string want = primary_subtag(lang);
    for (const Language &l : OcrEngine::AvailableRecognizerLanguages()) {
        if (primary_subtag(utf8(l.LanguageTag())) == want) {
            if (OcrEngine e = OcrEngine::TryCreateFromLanguage(l))
                return e;
        }
    }
    std::string have;
    for (const Language &l : OcrEngine::AvailableRecognizerLanguages()) {
        std::string p = primary_subtag(utf8(l.LanguageTag()));
        if (have.find(p) == std::string::npos)
            have += (have.empty() ? "" : ",") + p;
    }
    err = "The Windows OCR language pack for '" + lang + "' is not installed (installed: " +
          (have.empty() ? "none" : have) +
          "). Add the language in Windows Settings > Time & language > Language & region, "
          "with its 'Optical character recognition' feature.";
    return nullptr;
}

// Area-averaged scale-down by an integer-free factor into a tightly packed buffer.
std::vector<uint8_t> scaled(const unsigned char *src, int w, int h, int stride, int nw, int nh)
{
    std::vector<uint8_t> out((size_t)nw * nh);
    for (int y = 0; y < nh; y++) {
        int y0 = (int)((int64_t)y * h / nh), y1 = std::max(y0 + 1, (int)((int64_t)(y + 1) * h / nh));
        for (int x = 0; x < nw; x++) {
            int x0 = (int)((int64_t)x * w / nw), x1 = std::max(x0 + 1, (int)((int64_t)(x + 1) * w / nw));
            unsigned sum = 0, n = 0;
            for (int yy = y0; yy < y1; yy++)
                for (int xx = x0; xx < x1; xx++, n++)
                    sum += src[(size_t)yy * stride + xx];
            out[(size_t)y * nw + x] = (uint8_t)(sum / n);
        }
    }
    return out;
}

bool wide_char(const std::string &s, size_t i, size_t &len)
{
    unsigned char c = (unsigned char)s[i];
    len = c < 0x80 ? 1 : c >= 0xF0 ? 4 : c >= 0xE0 ? 3 : c >= 0xC0 ? 2 : 1;
    if (len != 3 || i + 3 > s.size())
        return false;
    uint32_t cp = ((c & 0x0F) << 12) | (((unsigned char)s[i + 1] & 0x3F) << 6) | ((unsigned char)s[i + 2] & 0x3F);
    return (cp >= 0x2E80 && cp <= 0x9FFF) || (cp >= 0xFF00 && cp <= 0xFF60);
}

// Windows OCR separates Japanese and Chinese characters with spaces: remove those between
// two wide characters.
std::string join_cjk(const std::string &s)
{
    std::string out;
    for (size_t i = 0; i < s.size();) {
        if (s[i] == ' ' && !out.empty()) {
            size_t a = out.size() - 1;
            while (a > 0 && ((unsigned char)out[a] & 0xC0) == 0x80)
                a--;
            size_t l, l2;
            if (i + 1 < s.size() && wide_char(out, a, l) && wide_char(s, i + 1, l2)) {
                i++;
                continue;
            }
        }
        out += s[i++];
    }
    return out;
}

} // namespace

bool ocr_gray(const unsigned char *gray, int width, int height, int stride, const std::string &lang,
              std::string &text, std::string &err)
{
    if (!gray || width < 1 || height < 1 || stride < width) {
        err = "OCR: invalid bitmap";
        return false;
    }
    return run_in_apartment(
        [&](std::string &e) {
            OcrEngine engine = engine_for(lang, e);
            if (!engine)
                return false;
            // The recogniser takes images up to MaxImageDimension() on each side.
            const int max_dim = (int)OcrEngine::MaxImageDimension();
            int nw = width, nh = height;
            if (nw > max_dim || nh > max_dim) {
                double f = (double)max_dim / std::max(nw, nh);
                nw = std::max(1, (int)(nw * f));
                nh = std::max(1, (int)(nh * f));
            }
            std::vector<uint8_t> reduced;
            const unsigned char *src = gray;
            int sstride = stride;
            if (nw != width || nh != height) {
                reduced = scaled(gray, width, height, stride, nw, nh);
                src = reduced.data();
                sstride = nw;
            }

            Buffer buf((uint32_t)((size_t)nw * nh));
            buf.Length((uint32_t)((size_t)nw * nh));
            uint8_t *dst = nullptr;
            winrt::check_hresult(buf.as<IBufferByteAccess>()->Buffer(&dst));
            for (int y = 0; y < nh; y++)
                std::copy_n(src + (size_t)y * sstride, nw, dst + (size_t)y * nw);
            SoftwareBitmap bitmap(BitmapPixelFormat::Gray8, nw, nh, BitmapAlphaMode::Ignore);
            bitmap.CopyFromBuffer(buf);

            OcrResult result = engine.RecognizeAsync(bitmap).get();
            const bool cjk = primary_subtag(lang) == "ja" || primary_subtag(lang) == "zh";
            std::string out;
            for (const OcrLine &line : result.Lines()) {
                std::string l = utf8(line.Text());
                if (cjk)
                    l = join_cjk(l);
                if (!out.empty())
                    out += '\n';
                out += l;
            }
            text = std::move(out);
            return true;
        },
        err);
}

std::string ocr_languages()
{
    std::string list, err;
    run_in_apartment(
        [&](std::string &) {
            for (const Language &l : OcrEngine::AvailableRecognizerLanguages()) {
                std::string p = primary_subtag(utf8(l.LanguageTag()));
                bool dup = false;
                size_t pos = 0;
                while (pos <= list.size() && !list.empty()) {
                    size_t e = list.find(',', pos);
                    dup |= list.substr(pos, e == std::string::npos ? std::string::npos : e - pos) == p;
                    if (e == std::string::npos)
                        break;
                    pos = e + 1;
                }
                if (!dup)
                    list += (list.empty() ? "" : ",") + p;
            }
            return true;
        },
        err);
    return list;
}

} // namespace nanum
