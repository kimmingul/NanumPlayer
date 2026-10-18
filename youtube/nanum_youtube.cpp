// NanumPlayer YouTube helper (1.5.0).
//
// A small WebView2 browser used to choose a YouTube video and to sign in. The browser is always InPrivate:
// its session (history, cookies, cache, logins) lives in a user-data folder that exists for one run only.
// It is deleted when the helper exits (after the browser process ended); what a run that was killed, or the
// persistent profile of releases up to 1.8.1, left behind is deleted at the next start and by --quit.
// When the user opens a video, the helper pauses the page, exports this session's YouTube/Google cookies as
// a Netscape cookies.txt for yt-dlp (it lives as long as the session), tells NanumPlayer (mpv JSON IPC) to
// play the canonical URL and hides itself. Cookie values and page addresses are never logged or printed.
//
// Web-page mode: a non-YouTube http(s) page given with --url (or typed into the address bar) is
// browsed in the same window. "NanumPlayer에서 재생" then probes the top page and every iframe for
// the media that is really playing (HTMLMediaElement.currentSrc; for MediaSource blob: streams the
// HLS/DASH manifest seen on the network) and sends `script-message nanum-web-open <json>` over the mpv IPC
// pipe: {url, origin, referer, user_agent, title?, cookie_jar?}. cookie_jar is Netscape cookie-file text
// with the cookies that match the media URL only; the player reads it from memory, no cookie file exists.
// Nothing is sent without the click; DRM-protected media is refused. Signed URLs and cookie values are
// never logged.
//
// CLI:  nanum_youtube.exe [--pipe <mpv ipc pipe>] [--url <start url>] [--language <auto|ko|en|ja|zh-CN|zh-TW|es>]
//                         [--export-cookies-only] [--quit]
//       --language selects the language of every caption, message and dialog of the helper (and of the
//       WebView2 browser UI, for a helper that starts). Without it %APPDATA%\NanumPlayer\ui-language.conf
//       is read (auto: the Windows display language). A helper that is already running takes the language
//       of a later start without restarting; its private browser session is untouched.
// Env:  NANUMPLAYER_YOUTUBE_DIR  state root (default %LOCALAPPDATA%\NanumPlayer\youtube);
//                                sessions\ (this run's browser data) and cookies.txt live inside, bin\ is
//                                never touched.
//       NANUMPLAYER_YOUTUBE_LOG  optional log file (no cookie values or addresses are ever written)
// Exit: 0 ok, 1 bad arguments, 2 WebView2 runtime missing, 3 WebView2 (InPrivate) init failed,
//       4 cookie export failed, 5 timeout, 6 no running instance reachable, 7 --quit timeout,
//       8 session data could not be deleted completely (still in use by another process)
//       --quit: 0 when no helper is left and all of the above data is deleted (also when none ran).
//       --export-cookies-only asks the running helper to rewrite cookies.txt (6 when none runs: the
//       cookies of a session do not outlive its helper).

#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#define NOMINMAX
#include <windows.h>
#include <windowsx.h>
#include <shellapi.h>
#include <shlobj.h>
#include <tlhelp32.h>
#include <sddl.h>
#include <dwmapi.h>
#include <commctrl.h>
#include <uxtheme.h>
#include <wrl.h>
#include <WebView2.h>
#include <WebView2EnvironmentOptions.h>

#include <algorithm>
#include <cstdarg>
#include <cstdio>
#include <functional>
#include <string>
#include <vector>

#include "nanum_web_i18n.h"  // generated from locales/web.json by tools/compile_translations.py

#pragma comment(lib, "user32.lib")
#pragma comment(lib, "gdi32.lib")
#pragma comment(lib, "shell32.lib")
#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "advapi32.lib")
#pragma comment(lib, "dwmapi.lib")
#pragma comment(lib, "comctl32.lib")
#pragma comment(lib, "uxtheme.lib")
#pragma comment(lib, "shlwapi.lib")
#pragma comment(lib, "version.lib")

using Microsoft::WRL::Callback;
using Microsoft::WRL::ComPtr;
using Microsoft::WRL::Make;

namespace {

constexpr wchar_t kHome[] = L"https://www.youtube.com/";
constexpr wchar_t kRuntimeUrl[] = L"https://go.microsoft.com/fwlink/p/?LinkId=2124703";

enum ExitCode {
    kOk = 0,
    kBadArgs = 1,
    kNoRuntime = 2,
    kInitFailed = 3,
    kExportFailed = 4,
    kTimeout = 5,
    kNoInstance = 6,
    kQuitTimeout = 7,
    kCleanupFailed = 8,
};

enum CopyType : ULONG_PTR { kCopyShow = 1, kCopyExport = 2, kCopyQuit = 3, kCopyHello = 4, kCopyLanguage = 5 };

// What a helper answers to WM_COPYDATA when its browser session is private. Helpers of releases up to
// 1.8.1 (persistent profile) answered TRUE.
constexpr DWORD_PTR kPrivateAck = 0x4E50;
constexpr DWORD kQuitWaitMs = 30000;

enum ControlId { kIdBack = 101, kIdForward, kIdReload, kIdEdit, kIdPlay };
enum TimerId { kTimerLeave = 1, kTimerPipeWatch, kTimerWebProbe, kTimerWebRetry };
constexpr UINT kMsgEnter = WM_APP + 1;

// ---------------------------------------------------------------- strings / logging

std::wstring Widen(const char* s, int n) {
    if (n <= 0) return {};
    int len = MultiByteToWideChar(CP_UTF8, 0, s, n, nullptr, 0);
    std::wstring out(len, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, s, n, out.data(), len);
    return out;
}

std::string Utf8(const std::wstring& w) {
    if (w.empty()) return {};
    int len = WideCharToMultiByte(CP_UTF8, 0, w.data(), (int)w.size(), nullptr, 0, nullptr, nullptr);
    std::string out(len, '\0');
    WideCharToMultiByte(CP_UTF8, 0, w.data(), (int)w.size(), out.data(), len, nullptr, nullptr);
    return out;
}

std::wstring Lower(std::wstring s) {
    for (auto& c : s) c = (wchar_t)towlower(c);
    return s;
}

bool EndsWith(const std::wstring& s, const std::wstring& suffix) {
    return s.size() >= suffix.size() && s.compare(s.size() - suffix.size(), suffix.size(), suffix) == 0;
}

std::wstring Trim(const std::wstring& s) {
    size_t a = s.find_first_not_of(L" \t\r\n");
    if (a == std::wstring::npos) return {};
    size_t b = s.find_last_not_of(L" \t\r\n");
    return s.substr(a, b - a + 1);
}

std::wstring TakeString(LPWSTR p) {
    std::wstring s = p ? p : L"";
    if (p) CoTaskMemFree(p);
    return s;
}

std::wstring EnvVar(const wchar_t* name) {
    DWORD n = GetEnvironmentVariableW(name, nullptr, 0);
    if (!n) return {};
    std::wstring v(n, L'\0');
    v.resize(GetEnvironmentVariableW(name, v.data(), n));
    return v;
}

void Log(const wchar_t* fmt, ...) {
    static std::wstring path = EnvVar(L"NANUMPLAYER_YOUTUBE_LOG");
    if (path.empty()) return;
    wchar_t buf[1024];
    va_list ap;
    va_start(ap, fmt);
    _vsnwprintf_s(buf, _TRUNCATE, fmt, ap);
    va_end(ap);
    SYSTEMTIME st;
    GetLocalTime(&st);
    wchar_t line[1200];
    _snwprintf_s(line, _TRUNCATE, L"%02d:%02d:%02d.%03d %s\n", st.wHour, st.wMinute, st.wSecond,
                 st.wMilliseconds, buf);
    HANDLE h = CreateFileW(path.c_str(), FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
                           OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (h == INVALID_HANDLE_VALUE) return;
    std::string u = Utf8(line);
    DWORD w;
    WriteFile(h, u.data(), (DWORD)u.size(), &w, nullptr);
    CloseHandle(h);
}

std::wstring UrlEncode(const std::wstring& s) {
    std::string u = Utf8(s);
    std::wstring out;
    for (unsigned char c : u) {
        if (isalnum(c) || c == '-' || c == '_' || c == '.' || c == '~') {
            out += (wchar_t)c;
        } else {
            wchar_t b[4];
            swprintf_s(b, L"%%%02X", c);
            out += b;
        }
    }
    return out;
}

uint64_t Fnv1a(const std::wstring& s) {
    uint64_t h = 1469598103934665603ull;
    for (wchar_t c : s) {
        h ^= (uint64_t)c;
        h *= 1099511628211ull;
    }
    return h;
}

// ---------------------------------------------------------------- YouTube URLs

struct UrlParts {
    bool ok = false;
    std::wstring scheme, host, path, query;
};

UrlParts SplitUrl(const std::wstring& u) {
    UrlParts r;
    size_t p = u.find(L"://");
    if (p == std::wstring::npos) return r;
    r.scheme = Lower(u.substr(0, p));
    size_t a = p + 3;
    size_t e = u.find_first_of(L"/?#", a);
    if (e == std::wstring::npos) e = u.size();
    std::wstring auth = u.substr(a, e - a);
    if (auth.find(L'@') != std::wstring::npos) return r;  // userinfo tricks are never valid here
    size_t colon = auth.find(L':');
    if (colon != std::wstring::npos) auth.resize(colon);
    r.host = Lower(auth);
    std::wstring rest = u.substr(e);
    size_t hash = rest.find(L'#');
    if (hash != std::wstring::npos) rest.resize(hash);
    size_t q = rest.find(L'?');
    r.path = rest.substr(0, q);
    if (q != std::wstring::npos) r.query = rest.substr(q + 1);
    r.ok = !r.host.empty() && (r.scheme == L"http" || r.scheme == L"https");
    return r;
}

std::wstring QueryParam(const std::wstring& q, const std::wstring& key) {
    size_t pos = 0;
    while (pos <= q.size()) {
        size_t amp = q.find(L'&', pos);
        if (amp == std::wstring::npos) amp = q.size();
        std::wstring item = q.substr(pos, amp - pos);
        size_t eq = item.find(L'=');
        if (item.substr(0, eq) == key) return eq == std::wstring::npos ? L"" : item.substr(eq + 1);
        pos = amp + 1;
    }
    return {};
}

bool IsYouTubeHost(const std::wstring& h) {
    return h == L"youtube.com" || EndsWith(h, L".youtube.com");
}

bool IsValidId(const std::wstring& id) {
    if (id.size() != 11) return false;
    for (wchar_t c : id)
        if (!(iswalnum(c) && c < 128) && c != L'-' && c != L'_') return false;
    return true;
}

long ParseSeconds(const std::wstring& t) {
    if (t.empty()) return 0;
    bool digits = std::all_of(t.begin(), t.end(), [](wchar_t c) { return c >= L'0' && c <= L'9'; });
    if (digits) return t.size() > 7 ? 0 : _wtol(t.c_str());
    long total = 0, cur = 0;
    bool have = false;
    for (wchar_t c : t) {
        if (c >= L'0' && c <= L'9') {
            cur = cur * 10 + (c - L'0');
            have = true;
            if (cur > 10000000) return 0;
        } else if (have && (c == L'h' || c == L'm' || c == L's')) {
            total += cur * (c == L'h' ? 3600 : c == L'm' ? 60 : 1);
            cur = 0;
            have = false;
        } else {
            return 0;
        }
    }
    return have ? 0 : total;
}

struct VideoRef {
    std::wstring id;
    long t = 0;
    std::wstring Canonical() const {
        std::wstring u = L"https://www.youtube.com/watch?v=" + id;
        if (t > 0) u += L"&t=" + std::to_wstring(t);
        return u;
    }
};

// /watch?v=, /shorts/, /live/ and youtu.be/ links.
bool ParseVideo(const std::wstring& url, VideoRef& out) {
    UrlParts u = SplitUrl(url);
    if (!u.ok) return false;
    std::wstring id;
    if (u.host == L"youtu.be") {
        id = u.path.size() > 1 ? u.path.substr(1) : L"";
        id = id.substr(0, id.find(L'/'));
    } else if (IsYouTubeHost(u.host)) {
        if (u.path == L"/watch" || u.path == L"/watch/") {
            id = QueryParam(u.query, L"v");
        } else {
            for (const wchar_t* prefix : {L"/shorts/", L"/live/"}) {
                size_t n = wcslen(prefix);
                if (u.path.compare(0, n, prefix) == 0) {
                    id = u.path.substr(n);
                    id = id.substr(0, id.find(L'/'));
                    break;
                }
            }
        }
    }
    if (!IsValidId(id)) return false;
    out.id = id;
    std::wstring t = QueryParam(u.query, L"t");
    if (t.empty()) t = QueryParam(u.query, L"start");
    out.t = ParseSeconds(t);
    return true;
}

bool IsTrustedPageHost(const std::wstring& url) {
    UrlParts u = SplitUrl(url);
    return u.ok && (IsYouTubeHost(u.host) || u.host == L"youtu.be");
}

// A page that is not YouTube: handled by the generic web-page mode.
bool IsWebPageUrl(const std::wstring& url) {
    UrlParts u = SplitUrl(url);
    return u.ok && !IsYouTubeHost(u.host) && u.host != L"youtu.be";
}

std::wstring StripFragment(const std::wstring& u) {
    size_t h = u.find(L'#');
    return h == std::wstring::npos ? u : u.substr(0, h);
}

// An http(s) URL that is safe to hand to the player: no userinfo, no whitespace/control characters
// (CR/LF would split a header), bounded length.
bool ValidHttpUrl(const std::wstring& u, size_t maxLen = 8192) {
    if (u.empty() || u.size() > maxLen) return false;
    for (wchar_t c : u)
        if (c <= 0x20 || c == 0x7f) return false;
    return SplitUrl(u).ok;
}

// scheme://authority (lower case), "" for anything that is not an http(s) URL.
std::wstring OriginOf(const std::wstring& url) {
    UrlParts u = SplitUrl(url);
    if (!u.ok) return {};
    size_t a = url.find(L"://") + 3;
    size_t e = url.find_first_of(L"/?#", a);
    return u.scheme + L"://" + Lower(url.substr(a, e == std::wstring::npos ? std::wstring::npos : e - a));
}

// ---------------------------------------------------------------- web-page mode state

// One <video>/<audio> element reported by the page script during a probe.
struct WebElem {
    std::wstring key, frameUrl, src, ua;
    int ready = 0, w = 0, h = 0, videoWidth = 0;
    long duration = -1;
    bool paused = true, ended = false, drm = false, video = true;
};

enum class SeenKind { Direct, Hls, Dash };

// A media response seen on the network (manifests, and direct media for its actual Referer).
struct SeenMedia {
    std::wstring url, referer;  // url without fragment
    SeenKind kind = SeenKind::Direct;
    bool master = false;
    uint64_t epoch = 0;
    ULONGLONG tick = 0;
};

struct WebState {
    bool mode = false;         // generic web-page mode enabled (scripts + network sniffing active)
    bool scriptAdded = false;  // page script registered with WebView2
    bool busy = false;         // a probe or handoff is in flight
    uint64_t epoch = 1;        // bumps with every new top-level document: older detections are stale
    uint64_t probeId = 0, probeEpoch = 0;
    std::vector<WebElem> elems;
    std::vector<SeenMedia> seen;
    // handoff waiting for a freshly launched player
    bool retryActive = false;
    std::string retryPayload;
    ULONGLONG retryDeadline = 0;
};

// ---------------------------------------------------------------- state / paths

struct App {
    // configuration
    std::wstring root, sessionsDir, sessionDir, cookiePath, pipe, startUrl;
    bool pipeSeen = false;
    ULONGLONG launchedAt = 0;
    bool exportOnly = false;      // --export-cookies-only: only meaningful against a running helper
    bool startPending = false;     // the browser is being created; the end of the run waits for that
    bool closing = false;          // the window is being destroyed (--quit, closed, player gone)
    uint64_t nameHash = 0;
    WebState web;

    // window
    HWND hwnd = nullptr, back = nullptr, fwd = nullptr, reload = nullptr, edit = nullptr, play = nullptr;
    HFONT font = nullptr;
    HBRUSH barBrush = nullptr, editBrush = nullptr;
    int dpi = 96;
    int lang = 1;  // interface language: index into kLangCodes
    bool hiddenAfterSend = false;

    // webview
    ComPtr<ICoreWebView2Environment> env;
    ComPtr<ICoreWebView2Controller> controller;
    ComPtr<ICoreWebView2> wv;
    bool ready = false;
    std::vector<std::function<void()>> whenReady;

    // video handling
    bool pending = false;
    std::wstring lastCanon;
    ULONGLONG lastSent = 0, suppressUntil = 0;
    enum class Origin { Navigation, Spa, Button } leaveOrigin = Origin::Spa;

    int exitCode = kOk;
} g;

int S(int v) { return MulDiv(v, g.dpi, 96); }

// ---------------------------------------------------------------- interface language

// Fixed language order of the translation catalog (locales/web.json): the index is what the generated
// lookup takes.
constexpr const wchar_t* kLangCodes[6] = {L"ko", L"en", L"ja", L"zh-CN", L"zh-TW", L"es"};
// Language of the WebView2 browser UI (context menus, dialogs, Accept-Language).
constexpr const wchar_t* kBrowserLangs[6] = {L"ko", L"en-US", L"ja", L"zh-CN", L"zh-TW", L"es"};
constexpr const wchar_t* kFontNames[6] = {L"Malgun Gothic", L"Segoe UI",           L"Yu Gothic UI",
                                          L"Microsoft YaHei UI", L"Microsoft JhengHei UI", L"Segoe UI"};

// The text for `key` (its Korean source) in the interface language; the key itself when it is unknown.
const wchar_t* T(const wchar_t* key) {
    const wchar_t* r = nanum_web_tr(key, (unsigned)g.lang);
    return r && *r ? r : key;
}

// Language of the Windows display: the first preferred UI language; unsupported ones are English.
int WindowsLanguageIndex() {
    std::wstring name;
    ULONG count = 0, len = 0;
    if (GetUserPreferredUILanguages(MUI_LANGUAGE_NAME, &count, nullptr, &len) && len > 1) {
        std::wstring buf(len, L'\0');
        if (GetUserPreferredUILanguages(MUI_LANGUAGE_NAME, &count, buf.data(), &len)) name = buf.c_str();
    }
    if (name.empty()) {
        wchar_t b[LOCALE_NAME_MAX_LENGTH];
        if (GetUserDefaultLocaleName(b, (int)std::size(b))) name = b;
    }
    name = Lower(name);
    auto is = [&](const wchar_t* p) {
        size_t n = wcslen(p);
        return name.compare(0, n, p) == 0 && (name.size() == n || name[n] == L'-');
    };
    if (is(L"ko")) return 0;
    if (is(L"ja")) return 2;
    if (is(L"es")) return 5;
    if (is(L"zh")) {
        bool hans = name.find(L"hans") != std::wstring::npos;
        bool hant = name.find(L"hant") != std::wstring::npos || name.find(L"-tw") != std::wstring::npos ||
                    name.find(L"-hk") != std::wstring::npos || name.find(L"-mo") != std::wstring::npos;
        return hant && !hans ? 4 : 3;
    }
    return 1;
}

// A canonical language code or "auto" (the Windows language).
bool ParseLanguage(std::wstring s, int& idx) {
    s = Lower(Trim(s));
    for (auto& c : s)
        if (c == L'_') c = L'-';
    if (s == L"auto") {
        idx = WindowsLanguageIndex();
        return true;
    }
    for (int i = 0; i < 6; i++) {
        if (s == Lower(kLangCodes[i])) {
            idx = i;
            return true;
        }
    }
    return false;
}

// The player's saved choice (%APPDATA%\NanumPlayer\ui-language.conf: one code or auto); missing or
// unreadable means auto.
int ConfiguredLanguage() {
    int idx = -1;
    PWSTR p = nullptr;
    std::wstring path;
    if (SUCCEEDED(SHGetKnownFolderPath(FOLDERID_RoamingAppData, 0, nullptr, &p))) {
        path = p;
        path += L"\\NanumPlayer\\ui-language.conf";
    }
    CoTaskMemFree(p);
    if (!path.empty()) {
        HANDLE h = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
                               OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (h != INVALID_HANDLE_VALUE) {
            char buf[64];
            DWORD n = 0;
            if (ReadFile(h, buf, sizeof(buf), &n, nullptr)) {
                std::wstring text = Widen(buf, (int)n);
                if (!text.empty() && text[0] == 0xFEFF) text.erase(0, 1);
                ParseLanguage(text.substr(0, text.find(L'\n')), idx);
            }
            CloseHandle(h);
        }
    }
    return idx >= 0 ? idx : WindowsLanguageIndex();
}

std::wstring DefaultRoot() {
    PWSTR p = nullptr;
    std::wstring out;
    if (SUCCEEDED(SHGetKnownFolderPath(FOLDERID_LocalAppData, 0, nullptr, &p))) {
        out = p;
        out += L"\\NanumPlayer\\youtube";
    }
    CoTaskMemFree(p);
    return out;
}

std::wstring FullPath(const std::wstring& p) {
    DWORD n = GetFullPathNameW(p.c_str(), 0, nullptr, nullptr);
    if (!n) return p;
    std::wstring out(n, L'\0');
    out.resize(GetFullPathNameW(p.c_str(), n, out.data(), nullptr));
    while (out.size() > 3 && (out.back() == L'\\' || out.back() == L'/')) out.pop_back();
    return out;
}

std::wstring Suffix() {
    wchar_t b[24];
    swprintf_s(b, L"%016llx", (unsigned long long)g.nameHash);
    return b;
}
std::wstring WindowClassName() { return L"NanumPlayerYouTubeHelper_" + Suffix(); }
std::wstring MutexName() { return L"Local\\NanumPlayerYouTubeHelper_" + Suffix(); }
std::wstring ExportEventName(bool ok) {
    return L"Local\\NanumPlayerYouTubeExport" + std::wstring(ok ? L"Ok_" : L"Fail_") + Suffix();
}

std::wstring NormalizePipe(const std::wstring& name);

std::wstring DefaultPipe() {
    std::wstring env = NormalizePipe(EnvVar(L"NANUMPLAYER_IPC_PIPE"));
    if (!env.empty()) return env;
    wchar_t user[256];
    DWORD n = (DWORD)std::size(user);
    std::wstring name;
    if (GetUserNameW(user, &n) && n > 0) name.assign(user, n - 1);
    for (auto& c : name)
        if (!((c >= L'0' && c <= L'9') || (c >= L'A' && c <= L'Z') || (c >= L'a' && c <= L'z') || c == L'_' || c == L'-'))
            c = L'_';
    return L"\\\\.\\pipe\\nanumplayer-" + name;
}

std::wstring NormalizePipe(const std::wstring& name) {
    std::wstring t = Trim(name);
    if (t.empty()) return t;
    if (Lower(t).compare(0, 9, L"\\\\.\\pipe\\") == 0) return t;
    return L"\\\\.\\pipe\\" + t;
}

void ShowFront() {
    ShowWindow(g.hwnd, IsIconic(g.hwnd) ? SW_RESTORE : SW_SHOW);
    g.hiddenAfterSend = false;
    SetForegroundWindow(g.hwnd);
}

// A modal message in the interface language. A TaskDialog, so that even its button follows the chosen
// language and not the one of Windows (MessageBox buttons do). `icon`: MB_ICONINFORMATION/WARNING/ERROR.
void ShowMessage(HWND owner, const wchar_t* text, UINT icon = MB_ICONINFORMATION) {
    TASKDIALOG_BUTTON ok = {IDOK, T(L"확인")};
    TASKDIALOGCONFIG cfg = {sizeof(cfg)};
    cfg.hwndParent = owner;
    cfg.dwFlags = TDF_ALLOW_DIALOG_CANCELLATION;
    cfg.pszWindowTitle = L"NanumPlayer YouTube";
    cfg.pszMainIcon = icon == MB_ICONERROR ? TD_ERROR_ICON : icon == MB_ICONWARNING ? TD_WARNING_ICON : TD_INFORMATION_ICON;
    cfg.pszContent = text;
    cfg.cButtons = 1;
    cfg.pButtons = &ok;
    cfg.nDefaultButton = IDOK;
    int pressed = 0;
    if (FAILED(TaskDialogIndirect(&cfg, &pressed, nullptr, nullptr)))
        MessageBoxW(owner, text, cfg.pszWindowTitle, MB_OK | icon);
}

// ---------------------------------------------------------------- session data
//
// All the helper keeps on disk exists for one run:
//   <root>\sessions\<id>\   WebView2 user-data folder of the run (InPrivate: engine scratch files only)
//   <root>\cookies.txt      YouTube cookies for yt-dlp, written per YouTube handoff
// A run deletes both when it ends, after the browser process has exited. A killed run leaves them behind;
// the next start and --quit delete them while holding the single-instance mutex, so nothing in use can be
// hit. The persistent profile of releases up to 1.8.1 (<root>\profile, <root>\web-cookies\) goes the same
// way. <root>\bin\ (downloaded tools) is never touched.

constexpr DWORD kRemoveRetryMs = 8000;

// Extended-length form, so that deep browser cache paths cannot fail on MAX_PATH. `p` is absolute.
std::wstring LongPath(const std::wstring& p) {
    if (p.compare(0, 4, L"\\\\?\\") == 0) return p;
    if (p.compare(0, 2, L"\\\\") == 0) return L"\\\\?\\UNC\\" + p.substr(2);
    return L"\\\\?\\" + p;
}

// Deletes a file or a directory tree without ever following a link: a junction or symbolic link is
// removed itself, not its target. True once nothing is left at `path`.
bool RemoveTree(const std::wstring& path) {
    DWORD a = GetFileAttributesW(path.c_str());
    if (a == INVALID_FILE_ATTRIBUTES) {
        DWORD e = GetLastError();
        return e == ERROR_FILE_NOT_FOUND || e == ERROR_PATH_NOT_FOUND;
    }
    if (a & FILE_ATTRIBUTE_READONLY) SetFileAttributesW(path.c_str(), a & ~FILE_ATTRIBUTE_READONLY);
    if (!(a & FILE_ATTRIBUTE_DIRECTORY)) return DeleteFileW(path.c_str()) != 0;
    if (!(a & FILE_ATTRIBUTE_REPARSE_POINT)) {
        WIN32_FIND_DATAW fd;
        HANDLE h = FindFirstFileW((path + L"\\*").c_str(), &fd);
        if (h != INVALID_HANDLE_VALUE) {
            do {
                if (wcscmp(fd.cFileName, L".") && wcscmp(fd.cFileName, L"..")) RemoveTree(path + L"\\" + fd.cFileName);
            } while (FindNextFileW(h, &fd));
            FindClose(h);
        }
    }
    return RemoveDirectoryW(path.c_str()) != 0;
}

// RemoveTree, retried until `deadline` (GetTickCount64) while another process (the browser winding
// down, a virus scanner) still holds some of the files.
bool RemoveTreeBefore(const std::wstring& path, ULONGLONG deadline) {
    std::wstring p = LongPath(path);
    for (;;) {
        if (RemoveTree(p)) return true;
        if (GetTickCount64() >= deadline) return false;
        Sleep(200);
    }
}

bool Exists(const std::wstring& path) { return GetFileAttributesW(LongPath(path).c_str()) != INVALID_FILE_ATTRIBUTES; }

// Deletes everything an earlier run or release left behind. Only called while this process holds the
// single-instance mutex. True when nothing of it remains.
bool PurgeOwnedData() {
    ULONGLONG deadline = GetTickCount64() + kRemoveRetryMs;
    bool ok = true;
    for (const wchar_t* f : {L"\\cookies.txt", L"\\cookies.txt.tmp", L"\\web-cookies"})
        ok = RemoveTreeBefore(g.root + f, deadline) && ok;
    // The persistent profile of releases up to 1.8.1; only a WebView2 user-data folder is deleted.
    std::wstring profile = g.root + L"\\profile";
    if (Exists(profile + L"\\EBWebView")) ok = RemoveTreeBefore(profile, deadline) && ok;
    else RemoveDirectoryW(LongPath(profile).c_str());  // the empty folder an old release created
    std::vector<std::wstring> stale;
    WIN32_FIND_DATAW fd;
    HANDLE h = FindFirstFileW(LongPath(g.sessionsDir + L"\\*").c_str(), &fd);
    if (h != INVALID_HANDLE_VALUE) {
        do {
            if (wcscmp(fd.cFileName, L".") && wcscmp(fd.cFileName, L"..")) stale.push_back(g.sessionsDir + L"\\" + fd.cFileName);
        } while (FindNextFileW(h, &fd));
        FindClose(h);
    }
    for (auto& s : stale) ok = RemoveTreeBefore(s, deadline) && ok;
    RemoveDirectoryW(LongPath(g.sessionsDir).c_str());  // only succeeds when it is empty
    return ok;
}

// <root>\sessions\<random id>: this run's user-data folder.
bool CreateSessionDir() {
    GUID guid;
    if (FAILED(CoCreateGuid(&guid))) return false;
    wchar_t id[40];
    swprintf_s(id, L"%08lx%04x%04x%02x%02x%02x%02x%02x%02x%02x%02x", guid.Data1, guid.Data2, guid.Data3,
               guid.Data4[0], guid.Data4[1], guid.Data4[2], guid.Data4[3], guid.Data4[4], guid.Data4[5],
               guid.Data4[6], guid.Data4[7]);
    std::wstring dir = g.sessionsDir + L"\\" + id;
    int r = SHCreateDirectoryExW(nullptr, dir.c_str(), nullptr);
    if (r != ERROR_SUCCESS && r != ERROR_ALREADY_EXISTS) return false;
    g.sessionDir = dir;
    return true;
}

// Dispatches messages for up to `ms` (the browser's COM callbacks need them).
void PumpMessages(DWORD ms) {
    MsgWaitForMultipleObjects(0, nullptr, FALSE, ms, QS_ALLINPUT);
    MSG m;
    while (PeekMessageW(&m, nullptr, 0, 0, PM_REMOVE)) {
        TranslateMessage(&m);
        DispatchMessageW(&m);
    }
}

// The msedgewebview2.exe processes this process started (open handles, still running): the browser
// process of this run's WebView2. One user-data folder per run, so they are ours alone; their own
// children (renderer, GPU, crash handler) leave with them.
std::vector<HANDLE> BrowserProcesses() {
    std::vector<HANDLE> procs;
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap == INVALID_HANDLE_VALUE) return procs;
    PROCESSENTRY32W pe = {sizeof(pe)};
    DWORD self = GetCurrentProcessId();
    for (BOOL ok = Process32FirstW(snap, &pe); ok; ok = Process32NextW(snap, &pe)) {
        if (pe.th32ParentProcessID != self || _wcsicmp(pe.szExeFile, L"msedgewebview2.exe") != 0) continue;
        HANDLE h = OpenProcess(SYNCHRONIZE | PROCESS_TERMINATE, FALSE, pe.th32ProcessID);
        if (!h) continue;
        if (WaitForSingleObject(h, 0) == WAIT_OBJECT_0) CloseHandle(h);  // already ended
        else procs.push_back(h);
    }
    CloseHandle(snap);
    return procs;
}

// The end of a run (every WebView2 object is released): waits until the browser process is gone, then
// deletes this run's data. True when it is all gone.
bool FinishSession() {
    // The browser leaves by itself once nothing references it. One that was still starting when the run
    // ended is released by its own callbacks; its process is awaited like the others.
    ULONGLONG end = GetTickCount64() + 10000;
    for (;;) {
        std::vector<HANDLE> procs = BrowserProcesses();
        bool done = !g.startPending && procs.empty();
        if (!done && GetTickCount64() >= end) {
            Log(L"session: browser did not exit in time, terminating it");
            for (HANDLE h : procs) {
                TerminateProcess(h, 1);
                WaitForSingleObject(h, 3000);
            }
            done = true;
        }
        for (HANDLE h : procs) CloseHandle(h);
        if (done) break;
        PumpMessages(25);
    }
    ULONGLONG deadline = GetTickCount64() + kRemoveRetryMs;
    bool ok = true;
    for (const std::wstring& f : {g.cookiePath, g.cookiePath + L".tmp"}) ok = RemoveTreeBefore(f, deadline) && ok;
    if (!g.sessionDir.empty()) ok = RemoveTreeBefore(g.sessionDir, deadline) && ok;
    RemoveDirectoryW(LongPath(g.sessionsDir).c_str());  // only succeeds when it is empty
    Log(L"session: cleanup %s", ok ? L"complete" : L"incomplete");
    return ok;
}

// ---------------------------------------------------------------- cookie export

// Owner-only DACL so cookies.txt is unreadable by other accounts.
bool UserOnlyAttributes(SECURITY_ATTRIBUTES& sa, PSECURITY_DESCRIPTOR& sd) {
    HANDLE tok = nullptr;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &tok)) return false;
    DWORD n = 0;
    GetTokenInformation(tok, TokenUser, nullptr, 0, &n);
    std::vector<BYTE> buf(n);
    bool ok = GetTokenInformation(tok, TokenUser, buf.data(), n, &n) != 0;
    CloseHandle(tok);
    if (!ok) return false;
    LPWSTR sid = nullptr;
    if (!ConvertSidToStringSidW(((TOKEN_USER*)buf.data())->User.Sid, &sid)) return false;
    std::wstring sddl = std::wstring(L"D:P(A;;FA;;;") + sid + L")";
    LocalFree(sid);
    if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl.c_str(), SDDL_REVISION_1, &sd, nullptr))
        return false;
    sa = {sizeof(sa), sd, FALSE};
    return true;
}

bool WriteFileAtomic(const std::wstring& dst, const std::string& data) {
    SECURITY_ATTRIBUTES sa;
    PSECURITY_DESCRIPTOR sd = nullptr;
    if (!UserOnlyAttributes(sa, sd)) return false;
    std::wstring tmp = dst + L".tmp";
    DeleteFileW(tmp.c_str());
    HANDLE h = CreateFileW(tmp.c_str(), GENERIC_WRITE, 0, &sa, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    LocalFree(sd);
    if (h == INVALID_HANDLE_VALUE) return false;
    DWORD w = 0;
    bool ok = WriteFile(h, data.data(), (DWORD)data.size(), &w, nullptr) && w == data.size() &&
              FlushFileBuffers(h);
    CloseHandle(h);
    if (ok) ok = MoveFileExW(tmp.c_str(), dst.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH) != 0;
    if (!ok) DeleteFileW(tmp.c_str());
    return ok;
}

bool WantedCookieDomain(std::wstring d) {
    d = Lower(d);
    if (!d.empty() && d[0] == L'.') d.erase(0, 1);
    return d == L"youtube.com" || EndsWith(d, L".youtube.com") || d == L"google.com" ||
           EndsWith(d, L".google.com");
}

// Which cookies to collect.
struct CookieJob {
    std::wstring uri;         // cookies matching this URL only; empty: the whole session
    bool youtubeOnly;         // keep only YouTube/Google domains (yt-dlp export)
    std::wstring host;        // !youtubeOnly: additionally require the cookie domain to cover this host
    bool httpOnlyPrefix;      // yt-dlp's "#HttpOnly_" prefix; mpv's parser would read it as part of the domain
};

// A cookie domain attribute covers the host (RFC 6265 domain-match, leading dot optional).
bool CookieDomainCovers(std::wstring domain, const std::wstring& host) {
    domain = Lower(domain);
    if (!domain.empty() && domain[0] == L'.') domain.erase(0, 1);
    return !domain.empty() && (host == domain || EndsWith(host, L"." + domain));
}

// The cookie jar of this run's InPrivate session.
ComPtr<ICoreWebView2CookieManager> SessionCookieManager() {
    ComPtr<ICoreWebView2_13> w13;
    ComPtr<ICoreWebView2Profile> profile;
    ComPtr<ICoreWebView2Profile5> profile5;
    ComPtr<ICoreWebView2CookieManager> cm;
    if (g.wv && SUCCEEDED(g.wv.As(&w13)) && SUCCEEDED(w13->get_Profile(&profile)) && SUCCEEDED(profile.As(&profile5)))
        profile5->get_CookieManager(&cm);
    return cm;
}

// Netscape cookie-file text of the matching cookies (the header line always); `done` gets it by
// reference and the text is wiped when it returns.
void CollectCookies(const CookieJob& job, std::function<void(bool, int, std::string&)> done) {
    std::string none;
    ComPtr<ICoreWebView2CookieManager> cm = SessionCookieManager();
    if (!cm) {
        done(false, 0, none);
        return;
    }
    HRESULT hr = cm->GetCookies(
        job.uri.c_str(),
        Callback<ICoreWebView2GetCookiesCompletedHandler>(
            [job, done](HRESULT result, ICoreWebView2CookieList* list) -> HRESULT {
                if (FAILED(result) || !list) {
                    std::string none;
                    done(false, 0, none);
                    return S_OK;
                }
                UINT count = 0;
                list->get_Count(&count);
                std::string out = "# Netscape HTTP Cookie File\n# This is a generated file! Do not edit.\n\n";
                int written = 0;
                for (UINT i = 0; i < count; i++) {
                    ComPtr<ICoreWebView2Cookie> c;
                    if (FAILED(list->GetValueAtIndex(i, &c)) || !c) continue;
                    LPWSTR n = nullptr, v = nullptr, d = nullptr, p = nullptr;
                    c->get_Name(&n);
                    c->get_Value(&v);
                    c->get_Domain(&d);
                    c->get_Path(&p);
                    std::wstring name = TakeString(n), value = TakeString(v), domain = TakeString(d),
                                 path = TakeString(p);
                    BOOL httpOnly = FALSE, secure = FALSE, session = FALSE;
                    double expires = 0;
                    c->get_IsHttpOnly(&httpOnly);
                    c->get_IsSecure(&secure);
                    c->get_IsSession(&session);
                    c->get_Expires(&expires);
                    auto bad = [](const std::wstring& s) {
                        return s.find_first_of(L"\t\r\n") != std::wstring::npos;
                    };
                    bool wanted = job.youtubeOnly ? WantedCookieDomain(domain) : CookieDomainCovers(domain, job.host);
                    if (name.empty() || domain.empty() || !wanted || bad(name) || bad(value) || bad(domain) ||
                        bad(path))
                        continue;
                    long long exp = session || expires <= 0 ? 0 : (long long)expires;
                    if (path.empty()) path = L"/";
                    std::string line;
                    if (httpOnly && job.httpOnlyPrefix) line += "#HttpOnly_";
                    line += Utf8(domain);
                    line += domain[0] == L'.' ? "\tTRUE\t" : "\tFALSE\t";
                    line += Utf8(path);
                    line += secure ? "\tTRUE\t" : "\tFALSE\t";
                    line += std::to_string(exp);
                    line += "\t" + Utf8(name) + "\t" + Utf8(value) + "\n";
                    out += line;
                    written++;
                }
                done(true, written, out);
                SecureZeroMemory(out.data(), out.size());
                return S_OK;
            })
            .Get());
    if (FAILED(hr)) done(false, 0, none);
}

// The YouTube/Google cookies of this session as <root>\cookies.txt (owner-only), for yt-dlp.
void ExportCookies(std::function<void(bool, int)> done) {
    CollectCookies({L"", true, L"", true}, [done](bool ok, int count, std::string& text) {
        if (ok) ok = WriteFileAtomic(g.cookiePath, text);
        Log(L"cookies exported: %d entries, %s", count, ok ? L"ok" : L"failed");
        done(ok, count);
    });
}

// ---------------------------------------------------------------- mpv IPC

enum class IpcResult { Sent, NoPipe, Failed, Launched };

const wchar_t* PlayerUnreachableText(IpcResult r) {
    return r == IpcResult::NoPipe
               ? T(L"NanumPlayer를 실행할 수 없습니다.\nNanumPlayer.exe가 이 프로그램과 같은 폴더에 있는지 확인하세요.")
               : T(L"NanumPlayer에 연결할 수 없습니다.\nNanumPlayer가 실행 중인지 확인하세요.");
}

// A JSON string literal. Control characters are escaped, never dropped: the argument is passed on
// exactly as given (a nested JSON document stays valid).
std::string JsonQuote(const std::string& s) {
    std::string out = "\"";
    for (unsigned char c : s) {
        if (c == '"' || c == '\\') {
            out += '\\';
            out += (char)c;
        } else if (c == '\t' || c == '\n' || c == '\r') {  // a cookie jar is mostly these
            out += c == '\t' ? "\\t" : c == '\n' ? "\\n" : "\\r";
        } else if (c < 0x20 || c == 0x7f) {
            char b[8];
            snprintf(b, sizeof(b), "\\u%04x", c);
            out += b;
        } else {
            out += (char)c;
        }
    }
    out += '"';
    return out;
}

// Runs one mpv JSON IPC command (UTF-8 arguments, no shell involved) and reads the reply to this
// request (request_id 1). `what` is a log label (never a secret); `reply` receives the reply line.
IpcResult SendIpcCommand(const std::wstring& pipe, const std::vector<std::string>& args, const wchar_t* what,
                         std::string* reply = nullptr) {
    if (pipe.empty()) return IpcResult::NoPipe;
    HANDLE h = INVALID_HANDLE_VALUE;
    DWORD err = 0;
    for (int i = 0; i < 30; i++) {
        h = CreateFileW(pipe.c_str(), GENERIC_READ | GENERIC_WRITE, 0, nullptr, OPEN_EXISTING, 0, nullptr);
        if (h != INVALID_HANDLE_VALUE) break;
        err = GetLastError();
        if (err == ERROR_FILE_NOT_FOUND || err == ERROR_PATH_NOT_FOUND) break;  // no player: caller launches one
        if (err == ERROR_PIPE_BUSY) WaitNamedPipeW(pipe.c_str(), 500);
        else Sleep(100);
    }
    if (h == INVALID_HANDLE_VALUE) {
        Log(L"ipc: cannot open pipe (error %lu)", err);
        return err == ERROR_FILE_NOT_FOUND || err == ERROR_PATH_NOT_FOUND ? IpcResult::NoPipe : IpcResult::Failed;
    }
    std::string msg = "{\"command\":[";
    for (size_t i = 0; i < args.size(); i++) {
        if (i) msg += ',';
        msg += JsonQuote(args[i]);
    }
    msg += "],\"request_id\":1}\n";
    DWORD w = 0;
    bool ok = WriteFile(h, msg.data(), (DWORD)msg.size(), &w, nullptr) && w == msg.size();
    if (ok) {
        // mpv also pushes event lines; wait (briefly) for the reply line carrying our request_id.
        std::string buf;
        bool answered = false;
        for (ULONGLONG end = GetTickCount64() + 3000; !answered && GetTickCount64() < end;) {
            DWORD avail = 0;
            if (!PeekNamedPipe(h, nullptr, 0, nullptr, &avail, nullptr)) break;
            if (!avail) {
                Sleep(10);
                continue;
            }
            char tmp[512];
            DWORD r = 0;
            if (!ReadFile(h, tmp, std::min<DWORD>(avail, sizeof(tmp)), &r, nullptr) || !r) break;
            buf.append(tmp, r);
            size_t pos = 0, nl;
            while ((nl = buf.find('\n', pos)) != std::string::npos) {
                std::string line = buf.substr(pos, nl - pos);
                pos = nl + 1;
                if (line.find("\"request_id\":1") == std::string::npos) continue;
                answered = true;
                if (reply) *reply = line;
                if (line.find("\"error\":\"success\"") == std::string::npos) {
                    ok = false;
                    Log(L"ipc: mpv rejected the command");
                }
                break;
            }
            buf.erase(0, pos);
        }
        if (!answered) Log(L"ipc: no reply from mpv (command was written)");
    }
    SecureZeroMemory(msg.data(), msg.size());
    CloseHandle(h);
    Log(L"ipc: sent %s (%s)", what, ok ? L"ok" : L"failed");
    return ok ? IpcResult::Sent : IpcResult::Failed;
}

IpcResult SendIpc(const std::wstring& pipe, const std::wstring& url) {
    return SendIpcCommand(pipe, {"script-message", "nanum-youtube-open", Utf8(url)}, L"nanum-youtube-open");
}

bool PipeExists(const std::wstring& pipe) {
    if (WaitNamedPipeW(pipe.c_str(), 1)) return true;
    return GetLastError() != ERROR_FILE_NOT_FOUND;
}

// Starts NanumPlayer.exe (next to this exe) with the given, already quoted, command-line arguments.
bool LaunchPlayerWith(const std::wstring& args, const wchar_t* label) {
    wchar_t self[MAX_PATH * 2];
    DWORD n = GetModuleFileNameW(nullptr, self, (DWORD)std::size(self));
    if (!n || n >= std::size(self)) return false;
    std::wstring dir(self, n);
    dir.resize(dir.find_last_of(L'\\') + 1);
    std::wstring exe = dir + L"NanumPlayer.exe";
    if (GetFileAttributesW(exe.c_str()) == INVALID_FILE_ATTRIBUTES) {
        Log(L"launch: %s not found", exe.c_str());
        return false;
    }
    std::wstring cmd = L"\"" + exe + L"\"" + (args.empty() ? L"" : L" " + args);
    STARTUPINFOW si = {sizeof(si)};
    PROCESS_INFORMATION pi = {};
    if (!CreateProcessW(exe.c_str(), cmd.data(), nullptr, nullptr, FALSE, 0, nullptr, dir.c_str(), &si, &pi)) {
        Log(L"launch: CreateProcess failed (%lu)", GetLastError());
        return false;
    }
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    g.launchedAt = GetTickCount64();
    g.pipeSeen = false;
    Log(L"launch: started NanumPlayer for %s", label);
    return true;
}

// No player running: start NanumPlayer.exe with the protocol URL; it plays the video itself, or
// forwards it to a player that appeared meanwhile.
bool LaunchPlayer(const std::wstring& canon) {
    return LaunchPlayerWith(L"\"nanumplayer://open?url=" + UrlEncode(canon) + L"\"", L"a YouTube video");
}

// No player running and the media needs per-file options: start an idle player listening on our
// pipe; the handoff follows once it answers.
bool LaunchIdlePlayer() { return LaunchPlayerWith(L"\"--input-ipc-server=" + g.pipe + L"\"", L"a web page"); }

// The player's script has registered `nanum-web-open` once it publishes user-data/nanum/web-ready=true.
bool PlayerScriptsLoaded(const std::wstring& pipe) {
    std::string reply;
    if (SendIpcCommand(pipe, {"get_property", "user-data/nanum/web-ready"}, L"web-ready", &reply) !=
        IpcResult::Sent)
        return false;
    return reply.find("\"data\":true") != std::string::npos;
}

// ---------------------------------------------------------------- window helpers

void RunWhenReady(std::function<void()> fn) {
    if (g.ready) fn();
    else g.whenReady.push_back(std::move(fn));
}

void NavigateTo(const std::wstring& url) {
    if (g.wv) g.wv->Navigate(url.c_str());
}

void UpdateNavButtons() {
    if (!g.wv) return;
    BOOL b = FALSE, f = FALSE;
    g.wv->get_CanGoBack(&b);
    g.wv->get_CanGoForward(&f);
    EnableWindow(g.back, b);
    EnableWindow(g.fwd, f);
}

std::wstring CurrentSource() {
    LPWSTR s = nullptr;
    if (g.wv) g.wv->get_Source(&s);
    return TakeString(s);
}

int TextWidth(HWND h) {
    wchar_t t[128];
    int n = GetWindowTextW(h, t, (int)std::size(t));
    HDC dc = GetDC(g.hwnd);
    HGDIOBJ old = g.font ? SelectObject(dc, g.font) : nullptr;
    SIZE sz = {};
    GetTextExtentPoint32W(dc, t, n, &sz);
    if (old) SelectObject(dc, old);
    ReleaseDC(g.hwnd, dc);
    return sz.cx;
}

void Layout() {
    RECT rc;
    GetClientRect(g.hwnd, &rc);
    int bar = S(46), pad = S(6), bh = S(32), y = (bar - bh) / 2;
    int wBack = std::max(S(60), TextWidth(g.back) + S(28)), wFwd = std::max(S(60), TextWidth(g.fwd) + S(28)),
        wReload = std::max(S(84), TextWidth(g.reload) + S(28)), wPlay = std::max(S(196), TextWidth(g.play) + S(36));
    int x = pad;
    MoveWindow(g.back, x, y, wBack, bh, TRUE);
    x += wBack + pad;
    MoveWindow(g.fwd, x, y, wFwd, bh, TRUE);
    x += wFwd + pad;
    MoveWindow(g.reload, x, y, wReload, bh, TRUE);
    x += wReload + pad;
    int playX = rc.right - pad - wPlay;
    int eh = S(28);
    MoveWindow(g.edit, x, (bar - eh) / 2, std::max(S(80), playX - pad - x), eh, TRUE);
    MoveWindow(g.play, playX, y, wPlay, bh, TRUE);
    if (g.controller) {
        RECT b = {0, bar, rc.right, rc.bottom};
        g.controller->put_Bounds(b);
    }
}

void MakeFont() {
    if (g.font) DeleteObject(g.font);
    g.font = CreateFontW(-S(15), 0, 0, 0, FW_NORMAL, 0, 0, 0, DEFAULT_CHARSET, 0, 0, CLEARTYPE_QUALITY, 0,
                         kFontNames[g.lang]);
    for (HWND h : {g.back, g.fwd, g.reload, g.edit, g.play})
        if (h) SendMessageW(h, WM_SETFONT, (WPARAM)g.font, TRUE);
}

// Every caption of the window in the interface language.
void ApplyWindowLanguage() {
    SetWindowTextW(g.back, T(L"뒤로"));
    SetWindowTextW(g.fwd, T(L"앞으로"));
    SetWindowTextW(g.reload, T(L"새로고침"));
    SetWindowTextW(g.play, T(L"NanumPlayer에서 재생"));
    SendMessageW(g.edit, EM_SETCUEBANNER, TRUE, (LPARAM)T(L"주소 또는 검색어를 입력하세요"));
}

// Changes the interface language of the running window: only captions and fonts, the browser (and its
// private session) is untouched.
void SetLanguage(int idx) {
    if (idx == g.lang) return;
    g.lang = idx;
    if (!g.hwnd || !g.play) return;
    ApplyWindowLanguage();
    MakeFont();
    Layout();
    for (HWND h : {g.back, g.fwd, g.reload, g.edit, g.play}) InvalidateRect(h, nullptr, TRUE);
}

// ---------------------------------------------------------------- video handling

void PauseScript() {
    if (!g.wv) return;
    g.wv->ExecuteScript(
        L"(function(){try{window.__nanumGuardUntil=Date.now()+8000;"
        L"if(!window.__nanumGuard){window.__nanumGuard=1;document.addEventListener('play',function(e){"
        L"if(Date.now()<window.__nanumGuardUntil&&e.target&&e.target.pause)e.target.pause();},true);}"
        L"document.querySelectorAll('video,audio').forEach(function(v){try{v.pause()}catch(e){}});}"
        L"catch(e){}})();",
        nullptr);
}

void OnVideo(const VideoRef& v, App::Origin origin) {
    ULONGLONG now = GetTickCount64();
    if (g.pending) return;
    if (origin != App::Origin::Button) {
        if (now < g.suppressUntil) return;
        if (v.Canonical() == g.lastCanon && now - g.lastSent < 4000) return;
    }
    std::wstring canon = v.Canonical();
    g.pending = true;
    g.lastCanon = canon;
    g.lastSent = now;
    Log(L"video: handing over to the player");
    PauseScript();
    ExportCookies([canon, origin](bool ok, int) {
        if (!ok) Log(L"video: cookie export failed, sending anyway");
        IpcResult r = SendIpc(g.pipe, canon);
        if (r == IpcResult::NoPipe && LaunchPlayer(canon)) r = IpcResult::Launched;
        g.pending = false;
        g.lastSent = GetTickCount64();
        if (r == IpcResult::Sent || r == IpcResult::Launched) {
            if (r == IpcResult::Sent) g.pipeSeen = true;
            g.hiddenAfterSend = true;
            ShowWindow(g.hwnd, SW_HIDE);
            g.leaveOrigin = origin;
            if (origin != App::Origin::Button) SetTimer(g.hwnd, kTimerLeave, 400, nullptr);
            return;
        }
        ShowFront();
        ShowMessage(g.hwnd, PlayerUnreachableText(r), MB_ICONWARNING);
    });
}

// After handing a video to the player, leave the watch page so the next choice starts fresh.
void LeavePage() {
    g.suppressUntil = GetTickCount64() + 1500;
    std::wstring src = CurrentSource();
    if (g.leaveOrigin == App::Origin::Navigation) {
        if (src.empty() || src == L"about:blank") NavigateTo(kHome);
        return;
    }
    BOOL canBack = FALSE;
    g.wv->get_CanGoBack(&canBack);
    if (canBack) g.wv->GoBack();
    else NavigateTo(kHome);
}

// ---------------------------------------------------------------- web-page mode

// Runs in every frame of every document once web mode is on. It does nothing on its own: the host
// sends {probe|pause} commands (top frame via ExecuteScript, child frames by window.postMessage
// down the frame tree) and the frames answer with one delimited string per media element, sent
// straight to the host and relayed through the parent frames (the host drops duplicates).
// What a page claims is never trusted by itself: the host cross-checks the URL with the responses
// it observed on the network before any cookie is read.
constexpr wchar_t kWebScript[] = LR"JS((function(){
if(window.__nanumWeb)return;window.__nanumWeb=1;
var TOP=window.top===window,RS='\x1e',US='\x1f',DID=Math.random().toString(36).slice(2)+Date.now().toString(36);
function cl(s){return String(s==null?'':s).replace(/[\x00-\x1f\x7f]/g,'').slice(0,8192);}
function toHost(m){try{window.chrome.webview.postMessage(m);return true;}catch(e){return false;}}
function emit(m){toHost(m);if(!TOP){try{parent.postMessage({nanumRelay:m},'*');}catch(e){}}}
function kids(c,id){for(var i=0;i<window.frames.length;i++){try{window.frames[i].postMessage({nanumCmd:c,id:id},'*');}catch(e){}}}
function walk(root,out,cnt){try{var l=root.querySelectorAll('video,audio');for(var i=0;i<l.length;i++)out.push(l[i]);
var a=root.querySelectorAll('*');for(var j=0;j<a.length&&cnt.n<20000;j++,cnt.n++){var s=a[j].shadowRoot;if(s)walk(s,out,cnt);}}catch(e){}}
function media(){var o=[];walk(document,o,{n:0});return o;}
function scan(id){var v=media();for(var i=0;i<v.length;i++){var e=v[i],r=e.getBoundingClientRect();
var w=Math.max(0,Math.min(r.right,innerWidth)-Math.max(r.left,0)),h=Math.max(0,Math.min(r.bottom,innerHeight)-Math.max(r.top,0)),d=e.duration;
emit([RS+'nw1',id,DID+':'+i,cl(location.href),cl(e.currentSrc),e.readyState|0,e.paused?1:0,isFinite(d)?Math.round(d):-1,
Math.round(w),Math.round(h),e.videoWidth|0,(e.mediaKeys||e.__nanumDrm)?1:0,e.tagName==='VIDEO'?1:0,e.ended?1:0].join(US));}}
function pause(){window.__nanumGuardUntil=Date.now()+8000;if(!window.__nanumGuard){window.__nanumGuard=1;
document.addEventListener('play',function(e){if(Date.now()<window.__nanumGuardUntil&&e.target&&e.target.pause)e.target.pause();},true);}
var v=media();for(var i=0;i<v.length;i++){try{v[i].pause();}catch(e){}}}
function run(c,id){if(c==='probe')scan(cl(id));else if(c==='pause')pause();kids(c,id);}
window.addEventListener('message',function(e){var d=e.data;if(!d||typeof d!=='object')return;
if(typeof d.nanumRelay==='string'&&d.nanumRelay.charAt(0)===RS){if(e.source===window)return;
if(TOP)toHost(d.nanumRelay);else{try{parent.postMessage(d,'*');}catch(x){}}return;}
if(typeof d.nanumCmd==='string'&&!TOP&&e.source===parent)run(d.nanumCmd,d.id);},false);
window.__nanumCmd=function(c,id){if(TOP)run(c,id);};
['encrypted','waitingforkey'].forEach(function(t){document.addEventListener(t,function(e){
try{if(e.target&&e.target.nodeType===1)e.target.__nanumDrm=1;}catch(x){}},true);});
})();)JS";

constexpr wchar_t kFrameMsgPrefix[] = L"\x1e" L"nw1";
constexpr size_t kMaxSeenManifests = 64, kMaxSeenDirect = 128;

void WebNotice(const wchar_t* text, UINT icon = MB_ICONINFORMATION) {
    ShowFront();
    ShowMessage(g.hwnd, text, icon);
}

void RunScript(const std::wstring& js) {
    if (g.wv) g.wv->ExecuteScript(js.c_str(), nullptr);
}

// Web mode: page script registered for the next documents, network sniffing and the explicit play
// action become active. Every open window keeps its YouTube behaviour.
void EnableWebMode() {
    g.web.mode = true;
    RunWhenReady([] {
        if (g.web.scriptAdded || !g.wv) return;
        g.web.scriptAdded = true;
        g.wv->AddScriptToExecuteOnDocumentCreated(kWebScript, nullptr);
    });
}

// A new top-level document: whatever was detected before belongs to the old page.
void ResetWebDetections() {
    g.web.epoch++;
    g.web.elems.clear();
    g.web.seen.clear();
}

void NoteWebNavigation(const std::wstring& target) {
    if (g.web.mode && StripFragment(target) != StripFragment(CurrentSource())) ResetWebDetections();
}

std::wstring HeaderValue(ICoreWebView2HttpResponseHeaders* h, const wchar_t* name) {
    BOOL has = FALSE;
    LPWSTR v = nullptr;
    if (!h || FAILED(h->Contains(name, &has)) || !has || FAILED(h->GetHeader(name, &v))) return {};
    return TakeString(v);
}

std::wstring HeaderValue(ICoreWebView2HttpRequestHeaders* h, const wchar_t* name) {
    BOOL has = FALSE;
    LPWSTR v = nullptr;
    if (!h || FAILED(h->Contains(name, &has)) || !has || FAILED(h->GetHeader(name, &v))) return {};
    return TakeString(v);
}

// Keeps the manifests and media responses the browser itself received: the only evidence of a
// MediaSource stream's real address, and the actual Referer a media request carried.
void OnResponseReceived(ICoreWebView2WebResourceResponseReceivedEventArgs* a) {
    if (!g.web.mode) return;
    ComPtr<ICoreWebView2WebResourceRequest> req;
    ComPtr<ICoreWebView2WebResourceResponseView> resp;
    if (FAILED(a->get_Request(&req)) || FAILED(a->get_Response(&resp)) || !req || !resp) return;
    LPWSTR u = nullptr;
    if (FAILED(req->get_Uri(&u))) return;
    std::wstring url = StripFragment(TakeString(u));
    if (!ValidHttpUrl(url)) return;
    int status = 0;
    resp->get_StatusCode(&status);
    if (status != 200 && status != 206) return;
    ComPtr<ICoreWebView2HttpResponseHeaders> rh;
    resp->get_Headers(&rh);
    std::wstring type = Lower(HeaderValue(rh.Get(), L"Content-Type"));
    std::wstring path = Lower(SplitUrl(url).path);
    auto typeIs = [&](const wchar_t* p) { return type.compare(0, wcslen(p), p) == 0; };
    SeenKind kind;
    if (EndsWith(path, L".m3u8") || type.find(L"mpegurl") != std::wstring::npos) kind = SeenKind::Hls;
    else if (EndsWith(path, L".mpd") || type.find(L"dash+xml") != std::wstring::npos) kind = SeenKind::Dash;
    else if (typeIs(L"video/") || typeIs(L"audio/")) kind = SeenKind::Direct;
    else return;

    SeenMedia m;
    m.url = url;
    m.kind = kind;
    m.master = kind == SeenKind::Dash;
    m.epoch = g.web.epoch;
    m.tick = GetTickCount64();
    ComPtr<ICoreWebView2HttpRequestHeaders> qh;
    if (SUCCEEDED(req->get_Headers(&qh))) m.referer = StripFragment(HeaderValue(qh.Get(), L"Referer"));

    auto& seen = g.web.seen;
    seen.erase(std::remove_if(seen.begin(), seen.end(),
                              [&](const SeenMedia& s) { return s.epoch == m.epoch && s.url == m.url; }),
               seen.end());
    bool manifest = kind != SeenKind::Direct;
    size_t cap = manifest ? kMaxSeenManifests : kMaxSeenDirect, count = 0;
    for (auto& s : seen) count += (s.kind != SeenKind::Direct) == manifest;
    for (auto it = seen.begin(); count >= cap && it != seen.end();) {
        if ((it->kind != SeenKind::Direct) == manifest) {
            it = seen.erase(it);
            count--;
        } else {
            ++it;
        }
    }
    seen.push_back(m);

    if (kind == SeenKind::Hls) {
        // A master playlist (variants) is what a player should open, not one of its media playlists.
        uint64_t epoch = m.epoch;
        resp->GetContent(Callback<ICoreWebView2WebResourceResponseViewGetContentCompletedHandler>(
                             [url, epoch](HRESULT hr, IStream* s) -> HRESULT {
                                 if (FAILED(hr) || !s) return S_OK;
                                 std::string body;
                                 char buf[4096];
                                 ULONG n = 0;
                                 while (body.size() < 131072 && SUCCEEDED(s->Read(buf, sizeof(buf), &n)) && n)
                                     body.append(buf, n);
                                 bool master = body.find("#EXT-X-STREAM-INF") != std::string::npos;
                                 for (auto& e : g.web.seen)
                                     if (e.epoch == epoch && e.url == url) e.master = master;
                                 return S_OK;
                             })
                             .Get());
    }
}

const SeenMedia* FindSeen(const std::wstring& url) {
    std::wstring u = StripFragment(url);
    for (auto& s : g.web.seen)
        if (s.epoch == g.web.epoch && s.url == u) return &s;
    return nullptr;
}

// Whether a request that carried this Referer came from the frame being played (or the top page).
bool RefererFits(const std::wstring& referer, const std::wstring& frameOrigin, const std::wstring& topOrigin) {
    std::wstring ro = OriginOf(referer);
    return ro.empty() || ro == frameOrigin || ro == topOrigin;  // no Referer: the policy withheld it
}

// The manifest the active frame loaded: Referer from that frame (or the top page), master playlists
// first, newest wins.
const SeenMedia* PickManifest(const std::wstring& frameOrigin, const std::wstring& topOrigin) {
    const SeenMedia* best = nullptr;
    int bestScore = -1;
    for (auto& m : g.web.seen) {
        if (m.epoch != g.web.epoch || m.kind == SeenKind::Direct) continue;
        if (!RefererFits(m.referer, frameOrigin, topOrigin)) continue;
        int score = (OriginOf(m.referer) == frameOrigin && !frameOrigin.empty() ? 4 : 0) + (m.master ? 2 : 0);
        if (score >= bestScore) {
            best = &m;
            bestScore = score;
        }
    }
    return best;
}

double ElemScore(const WebElem& e) {
    double s = 0;
    if (!e.paused && !e.ended) s += 1000;
    if (e.ready >= 2) s += 200;
    s += std::min((double)e.w * e.h / 1000.0, 500.0);
    if (e.duration > 0) s += std::min(e.duration / 60.0, 100.0);
    if (e.video) s += 50;
    return s;
}

std::vector<std::wstring> SplitFields(const std::wstring& s, wchar_t sep) {
    std::vector<std::wstring> out;
    size_t pos = 0;
    for (;;) {
        size_t e = s.find(sep, pos);
        out.push_back(s.substr(pos, e == std::wstring::npos ? std::wstring::npos : e - pos));
        if (e == std::wstring::npos) return out;
        pos = e + 1;
    }
}

// One element report from a frame (see kWebScript). Only accepted while our probe is running.
void OnWebFrameMessage(const std::wstring& m) {
    if (!g.web.mode || !g.web.busy || g.web.probeEpoch != g.web.epoch || m.size() > 40000) return;
    std::vector<std::wstring> f = SplitFields(m, L'\x1f');
    if (f.size() != 14 || f[0] != kFrameMsgPrefix || f[1] != std::to_wstring(g.web.probeId)) return;
    WebElem e;
    e.key = f[2];
    e.frameUrl = f[3];
    e.src = f[4];
    e.ready = _wtoi(f[5].c_str());
    e.paused = f[6] == L"1";
    e.duration = _wtol(f[7].c_str());
    e.w = _wtoi(f[8].c_str());
    e.h = _wtoi(f[9].c_str());
    e.videoWidth = _wtoi(f[10].c_str());
    e.drm = f[11] == L"1";
    e.video = f[12] == L"1";
    e.ended = f[13] == L"1";
    for (auto& x : g.web.elems)
        if (x.key == e.key) return;  // same element reported directly and through its parent frame
    g.web.elems.push_back(std::move(e));
}

struct WebChoice {
    std::wstring url, origin, referer, title, ua;
    bool credentialed = false;  // the URL was observed on the network for the active frame
    const wchar_t* kind = L"direct";
};

std::string CleanHeaderText(const std::wstring& s, size_t maxLen) {
    std::wstring t;
    for (wchar_t c : s)
        if (c >= 0x20 && c != 0x7f) t += c;
    if (t.size() > maxLen) {
        t.resize(maxLen);
        if (IS_HIGH_SURROGATE(t.back())) t.pop_back();
    }
    return Utf8(Trim(t));
}

constexpr size_t kMaxWebPayload = 60000;  // the player's script refuses requests above 65536 bytes

// {url, origin, referer, user_agent, title?, cookie_jar?} - the single argument of nanum-web-open.
// cookie_jar: Netscape cookie-file text with exactly the cookies the browser would send to `url` (domain,
// path and secure flag kept). The player reads it from memory (memory://); no cookie file is ever written.
std::string BuildWebPayload(const WebChoice& c, const std::string& cookieJar) {
    std::string p = "{\"url\":" + JsonQuote(Utf8(c.url)) + ",\"origin\":" + JsonQuote(Utf8(c.origin)) +
                    ",\"referer\":" + JsonQuote(Utf8(c.referer)) +
                    ",\"user_agent\":" + JsonQuote(CleanHeaderText(c.ua, 512));
    std::string title = CleanHeaderText(c.title, 200);
    if (!title.empty()) p += ",\"title\":" + JsonQuote(title);
    if (!cookieJar.empty()) p += ",\"cookie_jar\":" + JsonQuote(cookieJar);
    p += "}";
    return p;
}

void FinishWebHandoff(IpcResult r, std::string payload) {
    SecureZeroMemory(payload.data(), payload.size());
    g.pending = false;
    if (r == IpcResult::Sent) {
        g.pipeSeen = true;
        g.hiddenAfterSend = true;
        ShowWindow(g.hwnd, SW_HIDE);
        return;
    }
    WebNotice(PlayerUnreachableText(r), MB_ICONWARNING);
}

void DeliverWebPayload(std::string payload) {
    IpcResult r = SendIpcCommand(g.pipe, {"script-message", "nanum-web-open", payload}, L"nanum-web-open");
    if (r == IpcResult::NoPipe && LaunchIdlePlayer()) {
        // The per-file options must reach the player's own script, so wait for a player to listen.
        g.web.retryActive = true;
        g.web.retryPayload = std::move(payload);
        g.web.retryDeadline = GetTickCount64() + 40000;
        SetTimer(g.hwnd, kTimerWebRetry, 500, nullptr);
        std::wstring title = T(L"NanumPlayer를 시작하는 중…");
        title += L" - NanumPlayer YouTube";
        SetWindowTextW(g.hwnd, title.c_str());
        return;
    }
    FinishWebHandoff(r, std::move(payload));
}

void WebRetryTick() {
    if (!g.web.retryActive) {
        KillTimer(g.hwnd, kTimerWebRetry);
        return;
    }
    ULONGLONG now = GetTickCount64();
    bool pipe = PipeExists(g.pipe);
    bool ready = pipe && PlayerScriptsLoaded(g.pipe);
    bool give_up = !ready && now > g.web.retryDeadline;
    if (!give_up && !ready) return;
    KillTimer(g.hwnd, kTimerWebRetry);
    g.web.retryActive = false;
    std::string payload = std::move(g.web.retryPayload);
    g.web.retryPayload.clear();
    IpcResult r = give_up ? (pipe ? IpcResult::Failed : IpcResult::NoPipe)
                          : SendIpcCommand(g.pipe, {"script-message", "nanum-web-open", payload}, L"nanum-web-open");
    FinishWebHandoff(r, std::move(payload));
}

void HandoffWeb(const WebChoice& c) {
    g.pending = true;
    RunScript(L"window.__nanumCmd&&window.__nanumCmd('pause','0')");
    Log(L"web: handoff %s, %s", c.kind, c.credentialed ? L"with cookies" : L"no cookies");
    if (!c.credentialed) {
        DeliverWebPayload(BuildWebPayload(c, std::string()));
        return;
    }
    // Only the cookies the browser would send to this very URL.
    UrlParts mu = SplitUrl(c.url);
    CollectCookies({c.url, false, mu.host, false}, [c](bool ok, int count, std::string& jar) {
        std::string payload = BuildWebPayload(c, ok && count > 0 ? jar : std::string());
        if (payload.size() > kMaxWebPayload) {
            SecureZeroMemory(payload.data(), payload.size());
            g.pending = false;
            WebNotice(T(L"이 영상에 필요한 쿠키가 너무 커서 NanumPlayer로 넘길 수 없습니다."), MB_ICONWARNING);
            return;
        }
        DeliverWebPayload(std::move(payload));
    });
}

std::wstring WebUserAgent() {
    ComPtr<ICoreWebView2Settings> st;
    ComPtr<ICoreWebView2Settings2> st2;
    LPWSTR ua = nullptr;
    if (g.wv && SUCCEEDED(g.wv->get_Settings(&st)) && SUCCEEDED(st.As(&st2)) && SUCCEEDED(st2->get_UserAgent(&ua)))
        return TakeString(ua);
    return {};
}

// Choose what to play from the probe replies and the observed network responses.
void FinishWebProbe() {
    g.web.busy = false;
    if (g.web.probeEpoch != g.web.epoch) return;  // the page changed meanwhile
    std::wstring top = CurrentSource();
    std::wstring topOrigin = OriginOf(top);
    const WebElem* best = nullptr;
    double bestScore = -1;
    for (auto& e : g.web.elems) {
        if (e.src.empty()) continue;
        double s = ElemScore(e);
        if (s > bestScore) {
            best = &e;
            bestScore = s;
        }
    }
    Log(L"web: probe found %d media element(s), %d network response(s)", (int)g.web.elems.size(),
        (int)g.web.seen.size());
    if (!best) {
        WebNotice(T(L"재생할 영상을 찾지 못했습니다.\n페이지에서 영상을 한 번 재생해 로딩을 시작한 뒤 다시 눌러 주세요."));
        return;
    }
    if (best->drm) {
        WebNotice(T(L"이 영상은 DRM(저작권 보호 암호화)으로 보호되어 NanumPlayer에서 재생할 수 없습니다.\n"
                    L"DRM은 우회하지 않습니다."),
                  MB_ICONWARNING);
        return;
    }
    std::wstring frameUrl = StripFragment(best->frameUrl);
    std::wstring frameOrigin = ValidHttpUrl(frameUrl) ? OriginOf(frameUrl) : topOrigin;
    std::wstring refererFallback = ValidHttpUrl(frameUrl) ? frameUrl : StripFragment(top);

    WebChoice c;
    c.origin = top;
    c.title = [] {
        LPWSTR t = nullptr;
        if (g.wv) g.wv->get_DocumentTitle(&t);
        return TakeString(t);
    }();
    c.ua = WebUserAgent();
    const SeenMedia* seen = nullptr;
    std::wstring src = best->src;
    if (Lower(src).compare(0, 5, L"blob:") == 0) {
        // MediaSource: the player needs the stream's manifest, which only the network shows.
        seen = PickManifest(frameOrigin, topOrigin);
        if (!seen) {
            WebNotice(T(L"이 영상은 브라우저 내부(MediaSource) 스트림이라 재생 주소(m3u8/mpd)를 찾지 못했습니다.\n"
                        L"영상을 처음부터 다시 로딩한 뒤 시도해 주세요. 파일 단위로 나뉜 암호화 스트림은 지원하지 않습니다."),
                      MB_ICONWARNING);
            return;
        }
        c.url = seen->url;
        c.kind = seen->kind == SeenKind::Dash ? L"dash" : L"hls";
        c.credentialed = true;
    } else if (ValidHttpUrl(src)) {
        c.url = StripFragment(src);
        seen = FindSeen(c.url);
        if (seen) {
            c.kind = seen->kind == SeenKind::Hls ? L"hls" : seen->kind == SeenKind::Dash ? L"dash" : L"direct";
            c.credentialed = RefererFits(seen->referer, frameOrigin, topOrigin);
        } else if (best->ready < 1) {
            WebNotice(T(L"영상이 아직 로딩되지 않았습니다. 재생이 시작된 뒤 다시 눌러 주세요."));
            return;
        }
        // Not seen on the network (cache, service worker) but the element has loaded it: it is played
        // without any cookie, so a page cannot use this to make the player send credentials.
    } else {
        WebNotice(T(L"이 영상의 주소(데이터/내부 주소)는 NanumPlayer에서 재생할 수 없습니다."), MB_ICONWARNING);
        return;
    }
    c.referer = seen && !seen->referer.empty() && ValidHttpUrl(seen->referer) ? seen->referer : refererFallback;
    if (!ValidHttpUrl(c.url) || !ValidHttpUrl(c.referer) || !ValidHttpUrl(c.origin, 16384)) {
        WebNotice(T(L"영상 주소가 올바르지 않아 재생할 수 없습니다."), MB_ICONWARNING);
        return;
    }
    HandoffWeb(c);
}

void StartWebProbe() {
    if (g.web.busy || g.pending) return;
    g.web.busy = true;
    g.web.elems.clear();
    g.web.probeId++;
    g.web.probeEpoch = g.web.epoch;
    RunScript(L"window.__nanumCmd&&window.__nanumCmd('probe','" + std::to_wstring(g.web.probeId) + L"')");
    SetTimer(g.hwnd, kTimerWebProbe, 700, nullptr);
}

void CheckSource(const std::wstring& url, App::Origin origin) {
    VideoRef v;
    if (ParseVideo(url, v)) OnVideo(v, origin);
}

std::wstring Classify(const std::wstring& input) {
    std::wstring t = Trim(input);
    if (t.empty()) return t;
    std::wstring l = Lower(t);
    if (l.compare(0, 7, L"http://") == 0 || l.compare(0, 8, L"https://") == 0) return t;
    if (t.find(L' ') == std::wstring::npos && t.find(L'.') != std::wstring::npos) return L"https://" + t;
    return L"https://www.youtube.com/results?search_query=" + UrlEncode(t);
}

void OnEnterInAddress() {
    wchar_t buf[2048];
    GetWindowTextW(g.edit, buf, 2048);
    std::wstring url = Classify(buf);
    if (!url.empty()) {
        // A page outside YouTube: media detection must be armed before its documents are created.
        if (IsWebPageUrl(url)) EnableWebMode();
        NavigateTo(url);
        SetFocus(g.hwnd);
        if (g.controller) g.controller->MoveFocus(COREWEBVIEW2_MOVE_FOCUS_REASON_PROGRAMMATIC);
    }
}

void OnPlayButton() {
    VideoRef v;
    if (ParseVideo(CurrentSource(), v)) {
        OnVideo(v, App::Origin::Button);
        return;
    }
    if (g.web.mode && IsWebPageUrl(CurrentSource())) {
        StartWebProbe();
        return;
    }
    ShowMessage(g.hwnd, T(L"재생할 동영상 페이지가 아닙니다.\nYouTube에서 동영상을 선택하세요."), MB_ICONINFORMATION);
}

// ---------------------------------------------------------------- WebView2

constexpr wchar_t kDocumentScript[] =
    L"(function(){if(window.top!==window||window.__nanumHook)return;window.__nanumHook=1;"
    L"function rep(){try{window.chrome.webview.postMessage(String(location.href));}catch(e){}}"
    L"var p=history.pushState,r=history.replaceState;"
    L"history.pushState=function(){var x=p.apply(this,arguments);rep();return x;};"
    L"history.replaceState=function(){var x=r.apply(this,arguments);rep();return x;};"
    L"window.addEventListener('popstate',rep);"
    L"document.addEventListener('yt-navigate-start',rep);"
    L"document.addEventListener('yt-navigate-finish',rep);})();";

// A failure that ends this run: message, exit code, window closed.
void FailInit(const wchar_t* what, HRESULT hr) {
    g.startPending = false;
    wchar_t msg[320];
    swprintf_s(msg, L"%s (0x%08X)", what, (unsigned)hr);
    Log(L"init failed: %s", msg);
    if (g.closing) return;  // the run is ending (--quit, window closed) while the browser starts
    ShowMessage(g.hwnd, msg, MB_ICONERROR);
    g.exitCode = kInitFailed;
    DestroyWindow(g.hwnd);
}

// The browser session of this run must be InPrivate: the browser keeps no history, cookies or cache in a
// profile, whatever the pages do.
bool VerifyPrivateSession() {
    ComPtr<ICoreWebView2_13> w13;
    ComPtr<ICoreWebView2Profile> profile;
    BOOL priv = FALSE;
    return g.wv && SUCCEEDED(g.wv.As(&w13)) && SUCCEEDED(w13->get_Profile(&profile)) && profile &&
           SUCCEEDED(profile->get_IsInPrivateModeEnabled(&priv)) && priv;
}

// Closes the browser and drops every reference to it, so that its process can exit.
void ReleaseWebView() {
    if (g.controller) g.controller->Close();
    g.controller.Reset();
    g.wv.Reset();
    g.env.Reset();
    g.ready = false;
}

void OnWebViewReady() {
    g.controller->get_CoreWebView2(&g.wv);
    if (!VerifyPrivateSession()) {
        FailInit(T(L"InPrivate 브라우저 세션을 확인할 수 없어 창을 열지 않습니다."), E_FAIL);
        return;
    }
    g.ready = true;
    ComPtr<ICoreWebView2Settings> st;
    if (SUCCEEDED(g.wv->get_Settings(&st))) {
        st->put_IsStatusBarEnabled(FALSE);
        st->put_AreDefaultScriptDialogsEnabled(TRUE);
    }
    EventRegistrationToken tok;
    g.wv->add_NavigationStarting(
        Callback<ICoreWebView2NavigationStartingEventHandler>(
            [](ICoreWebView2*, ICoreWebView2NavigationStartingEventArgs* a) -> HRESULT {
                LPWSTR u = nullptr;
                a->get_Uri(&u);
                std::wstring url = TakeString(u);
                NoteWebNavigation(url);
                VideoRef v;
                if (ParseVideo(url, v) && !g.pending && GetTickCount64() >= g.suppressUntil) {
                    Log(L"nav-start: video page, cancelled");
                    a->put_Cancel(TRUE);
                    OnVideo(v, App::Origin::Navigation);
                }
                return S_OK;
            })
            .Get(),
        &tok);
    g.wv->add_SourceChanged(Callback<ICoreWebView2SourceChangedEventHandler>(
                                [](ICoreWebView2*, ICoreWebView2SourceChangedEventArgs*) -> HRESULT {
                                    std::wstring src = CurrentSource();
                                    Log(L"source-changed");
                                    if (!(GetFocus() == g.edit)) SetWindowTextW(g.edit, src.c_str());
                                    CheckSource(src, App::Origin::Spa);
                                    return S_OK;
                                })
                                .Get(),
                            &tok);
    g.wv->add_HistoryChanged(Callback<ICoreWebView2HistoryChangedEventHandler>(
                                 [](ICoreWebView2*, IUnknown*) -> HRESULT {
                                     UpdateNavButtons();
                                     std::wstring src = CurrentSource();
                                     Log(L"history-changed");
                                     CheckSource(src, App::Origin::Spa);
                                     return S_OK;
                                 })
                                 .Get(),
                             &tok);
    g.wv->add_WebMessageReceived(
        Callback<ICoreWebView2WebMessageReceivedEventHandler>(
            [](ICoreWebView2*, ICoreWebView2WebMessageReceivedEventArgs* a) -> HRESULT {
                LPWSTR m = nullptr;
                if (FAILED(a->TryGetWebMessageAsString(&m))) return S_OK;
                std::wstring url = TakeString(m);
                if (url.compare(0, wcslen(kFrameMsgPrefix), kFrameMsgPrefix) == 0) {
                    OnWebFrameMessage(url);  // media report from a frame; accepted only during our probe
                    return S_OK;
                }
                // The page is untrusted: only act when the real top-level document is on YouTube.
                if (IsTrustedPageHost(CurrentSource())) CheckSource(url, App::Origin::Spa);
                return S_OK;
            })
            .Get(),
        &tok);
    g.wv->add_DocumentTitleChanged(
        Callback<ICoreWebView2DocumentTitleChangedEventHandler>([](ICoreWebView2*, IUnknown*) -> HRESULT {
            LPWSTR t = nullptr;
            g.wv->get_DocumentTitle(&t);
            std::wstring title = TakeString(t);
            if (!title.empty()) title += L" - ";
            title += L"NanumPlayer YouTube";
            SetWindowTextW(g.hwnd, title.c_str());
            return S_OK;
        }).Get(),
        &tok);
    g.wv->add_NewWindowRequested(
        Callback<ICoreWebView2NewWindowRequestedEventHandler>(
            [](ICoreWebView2*, ICoreWebView2NewWindowRequestedEventArgs* a) -> HRESULT {
                LPWSTR u = nullptr;
                a->get_Uri(&u);
                std::wstring url = TakeString(u);
                a->put_Handled(TRUE);
                if (!url.empty()) NavigateTo(url);
                return S_OK;
            })
            .Get(),
        &tok);
    g.controller->add_AcceleratorKeyPressed(
        Callback<ICoreWebView2AcceleratorKeyPressedEventHandler>(
            [](ICoreWebView2Controller*, ICoreWebView2AcceleratorKeyPressedEventArgs* a) -> HRESULT {
                COREWEBVIEW2_KEY_EVENT_KIND kind;
                UINT key = 0;
                a->get_KeyEventKind(&kind);
                a->get_VirtualKey(&key);
                if (kind == COREWEBVIEW2_KEY_EVENT_KIND_KEY_DOWN && key == 'L' &&
                    (GetKeyState(VK_CONTROL) & 0x8000)) {
                    SetFocus(g.edit);
                    SendMessageW(g.edit, EM_SETSEL, 0, -1);
                    a->put_Handled(TRUE);
                }
                return S_OK;
            })
            .Get(),
        &tok);
    {
        ComPtr<ICoreWebView2_2> wv2;
        if (SUCCEEDED(g.wv.As(&wv2))) {
            wv2->add_WebResourceResponseReceived(
                Callback<ICoreWebView2WebResourceResponseReceivedEventHandler>(
                    [](ICoreWebView2*, ICoreWebView2WebResourceResponseReceivedEventArgs* a) -> HRESULT {
                        OnResponseReceived(a);
                        return S_OK;
                    })
                    .Get(),
                &tok);
        }
    }
    g.wv->AddScriptToExecuteOnDocumentCreated(kDocumentScript, nullptr);

    Layout();
    g.controller->put_IsVisible(TRUE);
    UpdateNavButtons();

    for (auto& fn : g.whenReady) fn();
    g.whenReady.clear();

    NavigateTo(g.startUrl.empty() ? kHome : g.startUrl);
    g.controller->MoveFocus(COREWEBVIEW2_MOVE_FOCUS_REASON_PROGRAMMATIC);
}

void StartWebView() {
    g.startPending = true;
    // The browser UI (context menus, dialogs) starts in the interface language. A running browser keeps
    // its language: restarting it would drop the private session.
    ComPtr<CoreWebView2EnvironmentOptions> envOptions = Make<CoreWebView2EnvironmentOptions>();
    envOptions->put_Language(kBrowserLangs[g.lang]);
    envOptions->put_TargetCompatibleBrowserVersion(L"86.0.616.0");  // the loader default, not this SDK's build
    HRESULT hr = CreateCoreWebView2EnvironmentWithOptions(
        nullptr, g.sessionDir.c_str(), envOptions.Get(),
        Callback<ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler>(
            [](HRESULT result, ICoreWebView2Environment* env) -> HRESULT {
                if (g.closing) {  // the run ended while the browser started: nothing will use it
                    g.startPending = false;
                    return S_OK;
                }
                if (FAILED(result) || !env) {
                    FailInit(T(L"WebView2를 시작할 수 없습니다."), result);
                    return S_OK;
                }
                g.env = env;
                // Always InPrivate, in a user-data folder that exists for this run only. There is no
                // persistent fallback: a runtime without the controller options API cannot be used.
                ComPtr<ICoreWebView2Environment10> env10;
                ComPtr<ICoreWebView2ControllerOptions> options;
                BOOL priv = FALSE;
                HRESULT r = g.env.As(&env10);
                if (SUCCEEDED(r)) r = env10->CreateCoreWebView2ControllerOptions(&options);
                if (SUCCEEDED(r)) r = options->put_IsInPrivateModeEnabled(TRUE);
                if (SUCCEEDED(r)) r = options->get_IsInPrivateModeEnabled(&priv);
                if (SUCCEEDED(r) && !priv) r = E_FAIL;
                if (SUCCEEDED(r))
                    r = env10->CreateCoreWebView2ControllerWithOptions(
                        g.hwnd, options.Get(),
                        Callback<ICoreWebView2CreateCoreWebView2ControllerCompletedHandler>(
                            [](HRESULT cr, ICoreWebView2Controller* c) -> HRESULT {
                                g.startPending = false;
                                if (g.closing) {
                                    // The run ended while the browser started: that browser ends too.
                                    if (SUCCEEDED(cr) && c) c->Close();
                                    return S_OK;
                                }
                                if (FAILED(cr) || !c) {
                                    FailInit(T(L"WebView2 창을 만들 수 없습니다."), cr);
                                    return S_OK;
                                }
                                g.controller = c;
                                OnWebViewReady();
                                return S_OK;
                            })
                            .Get());
                if (FAILED(r))
                    FailInit(T(L"InPrivate 브라우저를 만들 수 없습니다. WebView2 런타임을 최신으로 업데이트하세요."), r);
                return S_OK;
            })
            .Get());
    if (FAILED(hr)) FailInit(T(L"WebView2를 시작할 수 없습니다."), hr);
}

// ---------------------------------------------------------------- window procedure

constexpr COLORREF kBar = RGB(0x1f, 0x1f, 0x1f), kBtn = RGB(0x3a, 0x3a, 0x3a), kBtnDown = RGB(0x55, 0x55, 0x55),
                   kAccent = RGB(0xc8, 0x2d, 0x2d), kText = RGB(0xee, 0xee, 0xee),
                   kTextOff = RGB(0x80, 0x80, 0x80), kEdit = RGB(0x2e, 0x2e, 0x2e);

void DrawButton(const DRAWITEMSTRUCT* d) {
    bool off = (d->itemState & ODS_DISABLED) != 0, down = (d->itemState & ODS_SELECTED) != 0;
    HBRUSH bar = CreateSolidBrush(kBar);
    FillRect(d->hDC, &d->rcItem, bar);
    DeleteObject(bar);
    COLORREF c = d->CtlID == kIdPlay ? (down ? RGB(0x9a, 0x20, 0x20) : kAccent) : (down ? kBtnDown : kBtn);
    if (off) c = RGB(0x2a, 0x2a, 0x2a);
    HBRUSH br = CreateSolidBrush(c);
    HGDIOBJ ob = SelectObject(d->hDC, br), op = SelectObject(d->hDC, GetStockObject(NULL_PEN));
    RoundRect(d->hDC, d->rcItem.left, d->rcItem.top, d->rcItem.right + 1, d->rcItem.bottom + 1, S(8), S(8));
    SelectObject(d->hDC, ob);
    SelectObject(d->hDC, op);
    DeleteObject(br);
    wchar_t text[64];
    GetWindowTextW(d->hwndItem, text, 64);
    SetBkMode(d->hDC, TRANSPARENT);
    SetTextColor(d->hDC, off ? kTextOff : kText);
    HGDIOBJ of = SelectObject(d->hDC, g.font);
    RECT r = d->rcItem;
    DrawTextW(d->hDC, text, -1, &r, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
    SelectObject(d->hDC, of);
}

// The address bar's context menu, in the interface language (the system one follows Windows' language).
void ShowEditMenu(HWND h, LPARAM l) {
    POINT pt = {GET_X_LPARAM(l), GET_Y_LPARAM(l)};
    if (l == (LPARAM)-1) {  // from the keyboard
        RECT r;
        GetWindowRect(h, &r);
        pt = {r.left + S(8), r.bottom};
    }
    SetFocus(h);
    DWORD a = 0, b = 0;
    SendMessageW(h, EM_GETSEL, (WPARAM)&a, (LPARAM)&b);
    bool hasSel = a != b, hasText = GetWindowTextLengthW(h) > 0;
    enum { kUndo = 1, kCut, kCopy, kPaste, kDelete, kAll };
    HMENU menu = CreatePopupMenu();
    if (!menu) return;
    auto add = [&](UINT id, const wchar_t* text, bool on) {
        AppendMenuW(menu, MF_STRING | (on ? MF_ENABLED : MF_GRAYED), id, text);
    };
    add(kUndo, T(L"실행 취소"), SendMessageW(h, EM_CANUNDO, 0, 0) != 0);
    AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
    add(kCut, T(L"잘라내기"), hasSel);
    add(kCopy, T(L"복사"), hasSel);
    add(kPaste, T(L"붙여넣기"), IsClipboardFormatAvailable(CF_UNICODETEXT) != 0);
    add(kDelete, T(L"삭제"), hasSel);
    AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
    add(kAll, T(L"모두 선택"), hasText);
    int cmd = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON, pt.x, pt.y, 0, h, nullptr);
    DestroyMenu(menu);
    switch (cmd) {
    case kUndo: SendMessageW(h, WM_UNDO, 0, 0); break;
    case kCut: SendMessageW(h, WM_CUT, 0, 0); break;
    case kCopy: SendMessageW(h, WM_COPY, 0, 0); break;
    case kPaste: SendMessageW(h, WM_PASTE, 0, 0); break;
    case kDelete: SendMessageW(h, WM_CLEAR, 0, 0); break;
    case kAll: SendMessageW(h, EM_SETSEL, 0, -1); break;
    }
}

LRESULT CALLBACK EditProc(HWND h, UINT m, WPARAM w, LPARAM l, UINT_PTR, DWORD_PTR) {
    if (m == WM_KEYDOWN && w == VK_RETURN) {
        PostMessageW(g.hwnd, kMsgEnter, 0, 0);
        return 0;
    }
    if (m == WM_CHAR && (w == VK_RETURN || w == VK_ESCAPE)) {
        if (w == VK_ESCAPE) {
            SetWindowTextW(h, CurrentSource().c_str());
            SendMessageW(h, EM_SETSEL, 0, -1);
        }
        return 0;
    }
    if (m == WM_CONTEXTMENU) {
        ShowEditMenu(h, l);
        return 0;
    }
    return DefSubclassProc(h, m, w, l);
}

void HandleCopyData(const COPYDATASTRUCT* cd) {
    switch (cd->dwData) {
    case kCopyShow: {
        std::wstring text((const wchar_t*)cd->lpData, cd->cbData / sizeof(wchar_t));
        size_t nl = text.find(L'\n');
        std::wstring pipe = text.substr(0, nl);
        std::wstring url = nl == std::wstring::npos ? L"" : text.substr(nl + 1);
        if (!pipe.empty()) g.pipe = NormalizePipe(pipe);
        Log(L"forwarded start: pipe %s", pipe.empty() ? L"(unchanged)" : L"updated");
        ShowFront();
        UrlParts u = SplitUrl(url);
        if (u.ok && IsWebPageUrl(url)) EnableWebMode();
        if (u.ok) RunWhenReady([url] { NavigateTo(url); });
        break;
    }
    case kCopyExport:
        RunWhenReady([] {
            ExportCookies([](bool ok, int) {
                HANDLE e = OpenEventW(EVENT_MODIFY_STATE, FALSE, ExportEventName(ok).c_str());
                if (e) {
                    SetEvent(e);
                    CloseHandle(e);
                }
            });
        });
        break;
    case kCopyQuit:
        PostMessageW(g.hwnd, WM_CLOSE, 0, 0);
        break;
    case kCopyLanguage: {
        std::wstring code(std::wstring((const wchar_t*)cd->lpData, cd->cbData / sizeof(wchar_t)).c_str());
        int idx = 0;
        if (ParseLanguage(code, idx)) {
            Log(L"language: %s", kLangCodes[idx]);
            SetLanguage(idx);
        }
        break;
    }
    }
}

LRESULT CALLBACK WndProc(HWND h, UINT m, WPARAM w, LPARAM l) {
    switch (m) {
    case WM_CREATE: {
        g.hwnd = h;
        g.dpi = GetDpiForWindow(h);
        g.barBrush = CreateSolidBrush(kBar);
        g.editBrush = CreateSolidBrush(kEdit);
        auto btn = [&](const wchar_t* t, int id) {
            return CreateWindowExW(0, L"BUTTON", t, WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_OWNERDRAW, 0, 0, 10, 10,
                                   h, (HMENU)(INT_PTR)id, nullptr, nullptr);
        };
        g.back = btn(T(L"뒤로"), kIdBack);
        g.fwd = btn(T(L"앞으로"), kIdForward);
        g.reload = btn(T(L"새로고침"), kIdReload);
        g.play = btn(T(L"NanumPlayer에서 재생"), kIdPlay);
        g.edit = CreateWindowExW(0, L"EDIT", L"", WS_CHILD | WS_VISIBLE | WS_TABSTOP | WS_BORDER | ES_AUTOHSCROLL,
                                 0, 0, 10, 10, h, (HMENU)(INT_PTR)kIdEdit, nullptr, nullptr);
        SetWindowTheme(g.edit, L"DarkMode_CFD", L"Explorer");
        SetWindowSubclass(g.edit, EditProc, 1, 0);
        SendMessageW(g.edit, EM_SETCUEBANNER, TRUE, (LPARAM)T(L"주소 또는 검색어를 입력하세요"));
        BOOL dark = TRUE;
        DwmSetWindowAttribute(h, 20 /*DWMWA_USE_IMMERSIVE_DARK_MODE*/, &dark, sizeof(dark));
        COLORREF cap = kBar, txt = kText;
        DwmSetWindowAttribute(h, 35 /*DWMWA_CAPTION_COLOR*/, &cap, sizeof(cap));
        DwmSetWindowAttribute(h, 36 /*DWMWA_TEXT_COLOR*/, &txt, sizeof(txt));
        MakeFont();
        EnableWindow(g.back, FALSE);
        EnableWindow(g.fwd, FALSE);
        return 0;
    }
    case WM_SIZE:
        if (w != SIZE_MINIMIZED) Layout();
        return 0;
    case WM_GETMINMAXINFO:
        ((MINMAXINFO*)l)->ptMinTrackSize = {S(720), S(420)};
        return 0;
    case WM_DPICHANGED: {
        g.dpi = HIWORD(w);
        const RECT* r = (const RECT*)l;
        SetWindowPos(h, nullptr, r->left, r->top, r->right - r->left, r->bottom - r->top,
                     SWP_NOZORDER | SWP_NOACTIVATE);
        MakeFont();
        Layout();
        return 0;
    }
    case WM_ERASEBKGND: {
        RECT rc;
        GetClientRect(h, &rc);
        FillRect((HDC)w, &rc, g.barBrush);
        return 1;
    }
    case WM_CTLCOLOREDIT:
        SetTextColor((HDC)w, kText);
        SetBkColor((HDC)w, kEdit);
        return (LRESULT)g.editBrush;
    case WM_DRAWITEM:
        DrawButton((const DRAWITEMSTRUCT*)l);
        return TRUE;
    case WM_COMMAND:
        switch (LOWORD(w)) {
        case kIdBack:
            if (g.wv) g.wv->GoBack();
            break;
        case kIdForward:
            if (g.wv) g.wv->GoForward();
            break;
        case kIdReload:
            if (g.wv) {
                if (g.web.mode) ResetWebDetections();
                g.wv->Reload();
            }
            break;
        case kIdPlay:
            OnPlayButton();
            break;
        }
        return 0;
    case kMsgEnter:
        OnEnterInAddress();
        return 0;
    case WM_SETFOCUS:
        if (g.controller) g.controller->MoveFocus(COREWEBVIEW2_MOVE_FOCUS_REASON_PROGRAMMATIC);
        return 0;
    case WM_COPYDATA:
        HandleCopyData((const COPYDATASTRUCT*)l);
        return kPrivateAck;
    case WM_TIMER:
        if (w == kTimerLeave) {
            KillTimer(h, kTimerLeave);
            LeavePage();
        } else if (w == kTimerPipeWatch) {
            // Hidden helper with no player left: nothing to wait for any more.
            if (g.hiddenAfterSend && !g.pipe.empty()) {
                if (PipeExists(g.pipe)) {
                    g.pipeSeen = true;
                } else if (g.pipeSeen || (g.launchedAt && GetTickCount64() - g.launchedAt > 60000)) {
                    Log(L"player pipe gone, exiting");
                    DestroyWindow(h);
                }
            }
        } else if (w == kTimerWebProbe) {
            KillTimer(h, kTimerWebProbe);
            FinishWebProbe();
        } else if (w == kTimerWebRetry) {
            WebRetryTick();
        }
        return 0;
    case WM_CLOSE:
        DestroyWindow(h);
        return 0;
    case WM_DESTROY:
        g.closing = true;
        ReleaseWebView();
        PostQuitMessage(g.exitCode);
        return 0;
    }
    return DefWindowProcW(h, m, w, l);
}

// ---------------------------------------------------------------- instance forwarding

HWND FindInstanceWindow(int waitMs) {
    for (int waited = 0;; waited += 100) {
        HWND h = FindWindowW(WindowClassName().c_str(), nullptr);
        if (h || waited >= waitMs) return h;
        Sleep(100);
    }
}

bool SendCopy(HWND target, ULONG_PTR type, const std::wstring& text, DWORD_PTR* reply = nullptr) {
    DWORD pid = 0;
    GetWindowThreadProcessId(target, &pid);
    AllowSetForegroundWindow(pid);
    COPYDATASTRUCT cd = {type, (DWORD)((text.size() + 1) * sizeof(wchar_t)), (PVOID)text.c_str()};
    DWORD_PTR res = 0;
    bool ok = SendMessageTimeoutW(target, WM_COPYDATA, 0, (LPARAM)&cd, SMTO_ABORTIFHUNG, 5000, &res) != 0;
    if (reply) *reply = res;
    return ok;
}

bool IsPrivateInstance(HWND target) {
    DWORD_PTR reply = 0;
    return SendCopy(target, kCopyHello, L"", &reply) && reply == kPrivateAck;
}

int RunForwarded(HWND target, const std::wstring& pipe, const std::wstring& url, bool exportOnly) {
    if (exportOnly) {
        HANDLE ok = CreateEventW(nullptr, TRUE, FALSE, ExportEventName(true).c_str());
        HANDLE fail = CreateEventW(nullptr, TRUE, FALSE, ExportEventName(false).c_str());
        if (!ok || !fail) return kExportFailed;
        ResetEvent(ok);
        ResetEvent(fail);
        if (!SendCopy(target, kCopyExport, L"")) return kNoInstance;
        HANDLE both[2] = {ok, fail};
        DWORD r = WaitForMultipleObjects(2, both, FALSE, 25000);
        CloseHandle(ok);
        CloseHandle(fail);
        return r == WAIT_OBJECT_0 ? kOk : r == WAIT_OBJECT_0 + 1 ? kExportFailed : kTimeout;
    }
    // The running helper takes this start's language (its browser and private session stay as they are).
    SendCopy(target, kCopyLanguage, kLangCodes[g.lang]);
    return SendCopy(target, kCopyShow, pipe + L"\n" + url) ? kOk : kNoInstance;
}

// Asks the helper behind `target` to quit and waits for its process to end (it deletes its session
// data first): kOk, kNoInstance (not reachable) or kQuitTimeout.
int StopInstance(HWND target, DWORD waitMs) {
    DWORD pid = 0;
    GetWindowThreadProcessId(target, &pid);
    HANDLE proc = OpenProcess(SYNCHRONIZE, FALSE, pid);
    if (!SendCopy(target, kCopyQuit, L"")) {
        if (proc) CloseHandle(proc);
        return kNoInstance;
    }
    int code = kOk;
    if (proc) {
        if (WaitForSingleObject(proc, waitMs) != WAIT_OBJECT_0) code = kQuitTimeout;
        CloseHandle(proc);
    }
    return code;
}

// --quit: no helper is left and everything it (or an earlier run or release) stored is deleted.
// kOk: nothing running and nothing left (also when no helper was running); kQuitTimeout: the helper
// did not end; kCleanupFailed: some data is still locked by another process.
int RunQuit() {
    const ULONGLONG deadline = GetTickCount64() + kQuitWaitMs;
    HANDLE mutex = nullptr;
    for (;;) {
        mutex = CreateMutexW(nullptr, TRUE, MutexName().c_str());
        if (!mutex) return kInitFailed;
        if (GetLastError() != ERROR_ALREADY_EXISTS) break;  // no helper: this process holds the state root
        CloseHandle(mutex);
        mutex = nullptr;
        ULONGLONG now = GetTickCount64();
        if (now >= deadline) return kQuitTimeout;
        HWND target = FindWindowW(WindowClassName().c_str(), nullptr);
        if (!target) {  // starting up or already shutting down
            Sleep(100);
            continue;
        }
        int r = StopInstance(target, (DWORD)(deadline - now));
        if (r != kOk) return r;
    }
    bool clean = PurgeOwnedData();
    ReleaseMutex(mutex);
    CloseHandle(mutex);
    return clean ? kOk : kCleanupFailed;
}

}  // namespace

int WINAPI wWinMain(HINSTANCE inst, HINSTANCE, PWSTR, int) {
    int argc = 0;
    LPWSTR* argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    bool quit = false, badArgs = false, hasLang = false;
    std::wstring langArg;
    for (int i = 1; i < argc; i++) {
        std::wstring a = argv[i];
        auto value = [&](const wchar_t* name, std::wstring& out) {
            size_t n = wcslen(name);
            if (a == name && i + 1 < argc) {
                out = argv[++i];
                return true;
            }
            if (a.compare(0, n + 1, std::wstring(name) + L"=") == 0) {
                out = a.substr(n + 1);
                return true;
            }
            return false;
        };
        std::wstring v;
        if (value(L"--pipe", v)) g.pipe = NormalizePipe(v);
        else if (value(L"--url", v)) g.startUrl = Trim(v);
        else if (value(L"--language", v)) {
            langArg = v;
            hasLang = true;
        } else if (a == L"--export-cookies-only") g.exportOnly = true;
        else if (a == L"--quit") quit = true;
        else badArgs = true;
    }
    LocalFree(argv);

    // Interface language: --language, else the player's saved choice. Never the AI languages.
    int langIdx = 0;
    if (hasLang && ParseLanguage(langArg, langIdx)) g.lang = langIdx;
    else {
        if (hasLang) badArgs = true;
        g.lang = ConfiguredLanguage();
    }
    if (badArgs) {
        ShowMessage(nullptr,
                    T(L"사용법: nanum_youtube.exe [--pipe <mpv 파이프>] [--url <주소>] "
                      L"[--language <auto|ko|en|ja|zh-CN|zh-TW|es>] [--export-cookies-only] [--quit]"),
                    MB_ICONINFORMATION);
        return kBadArgs;
    }

    std::wstring envRoot = EnvVar(L"NANUMPLAYER_YOUTUBE_DIR");
    g.root = FullPath(envRoot.empty() ? DefaultRoot() : envRoot);
    g.sessionsDir = g.root + L"\\sessions";
    g.cookiePath = g.root + L"\\cookies.txt";
    g.nameHash = Fnv1a(Lower(g.root));
    if (g.root.size() <= 3) {  // empty or a drive root: nothing below it may ever be deleted
        if (!quit) ShowMessage(nullptr, T(L"상태 폴더를 정할 수 없습니다."), MB_ICONERROR);
        return kInitFailed;
    }
    if (quit) return RunQuit();

    // Single instance per state root: forward to the running one.
    HANDLE mutex = nullptr;
    for (bool takenOver = false;; takenOver = true) {
        mutex = CreateMutexW(nullptr, TRUE, MutexName().c_str());
        if (!mutex) return kInitFailed;
        if (GetLastError() != ERROR_ALREADY_EXISTS) break;
        CloseHandle(mutex);
        mutex = nullptr;
        HWND target = FindInstanceWindow(5000);
        if (!target) return kNoInstance;
        if (IsPrivateInstance(target)) return RunForwarded(target, g.pipe, g.startUrl, g.exportOnly);
        // A helper of an earlier release keeps a persistent browser profile: it is closed first.
        if (g.exportOnly || takenOver || StopInstance(target, 15000) != kOk) return kNoInstance;
    }
    if (g.exportOnly) {
        // The cookies of a session exist only while its helper runs; a new helper has none to export.
        ReleaseMutex(mutex);
        CloseHandle(mutex);
        return kNoInstance;
    }
    if (g.pipe.empty()) g.pipe = DefaultPipe();

    if (FAILED(CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED))) return kInitFailed;

    LPWSTR ver = nullptr;
    HRESULT vr = GetAvailableCoreWebView2BrowserVersionString(nullptr, &ver);
    bool haveRuntime = SUCCEEDED(vr) && ver && *ver;
    if (ver) CoTaskMemFree(ver);
    if (!haveRuntime) {
        Log(L"WebView2 runtime missing (0x%08X)", (unsigned)vr);
        std::wstring msg = T(
            L"Microsoft Edge WebView2 런타임이 설치되어 있지 않아 YouTube 창을 열 수 없습니다.\n\n"
            L"다음 주소에서 \"Evergreen 부트스트래퍼\"를 설치한 뒤 다시 시도하세요.\n");
        msg += kRuntimeUrl;
        ShowMessage(nullptr, msg.c_str(), MB_ICONERROR);
        return kNoRuntime;
    }


    INITCOMMONCONTROLSEX icc = {sizeof(icc), ICC_STANDARD_CLASSES};
    InitCommonControlsEx(&icc);

    WNDCLASSEXW wc = {sizeof(wc)};
    std::wstring cls = WindowClassName();
    wc.lpfnWndProc = WndProc;
    wc.hInstance = inst;
    wc.lpszClassName = cls.c_str();
    wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    wc.hIcon = (HICON)LoadImageW(inst, MAKEINTRESOURCEW(1), IMAGE_ICON, 0, 0, LR_DEFAULTSIZE | LR_SHARED);
    wc.hIconSm = (HICON)LoadImageW(inst, MAKEINTRESOURCEW(1), IMAGE_ICON, GetSystemMetrics(SM_CXSMICON),
                                   GetSystemMetrics(SM_CYSMICON), LR_SHARED);
    RegisterClassExW(&wc);

    HWND hwnd = CreateWindowExW(0, cls.c_str(), L"NanumPlayer YouTube", WS_OVERLAPPEDWINDOW, CW_USEDEFAULT,
                                CW_USEDEFAULT, 1280, 820, nullptr, nullptr, inst, nullptr);
    if (!hwnd) return kInitFailed;
    {
        int dpi = GetDpiForWindow(hwnd);
        RECT r;
        GetWindowRect(hwnd, &r);
        SetWindowPos(hwnd, nullptr, r.left, r.top, MulDiv(1280, dpi, 96), MulDiv(820, dpi, 96), SWP_NOZORDER | SWP_NOMOVE);
    }
    // A video link on the command line goes straight to the player without showing a window.
    VideoRef direct;
    bool startHidden = !g.startUrl.empty() && ParseVideo(g.startUrl, direct);
    if (!startHidden) {
        ShowWindow(hwnd, SW_SHOW);
        UpdateWindow(hwnd);
    }
    // A page outside YouTube on the command line: web-page mode (media detection + explicit play).
    if (IsWebPageUrl(g.startUrl)) EnableWebMode();
    // Whatever earlier runs (or releases) left behind is deleted before this run's browser exists.
    if (!PurgeOwnedData()) Log(L"session: data of an earlier run could not be removed yet");
    if (!CreateSessionDir()) {
        ShowMessage(hwnd, T(L"브라우저 세션 폴더를 만들 수 없습니다."), MB_ICONERROR);
        return kInitFailed;
    }
    SetTimer(hwnd, kTimerPipeWatch, 3000, nullptr);
    StartWebView();

    MSG msg;
    while (GetMessageW(&msg, nullptr, 0, 0) > 0) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
    // The window is gone and the browser released: its process ends, then this run's data is deleted.
    if (!FinishSession() && !g.exitCode) g.exitCode = kCleanupFailed;
    CoUninitialize();
    ReleaseMutex(mutex);
    CloseHandle(mutex);
    return g.exitCode ? g.exitCode : (int)msg.wParam;
}
