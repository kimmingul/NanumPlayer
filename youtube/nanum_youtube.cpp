// NanumPlayer YouTube helper (1.5.0).
//
// A small WebView2 browser used to choose a YouTube video and to sign in. When the user opens
// a video, the helper pauses the page, exports the YouTube/Google cookies as a Netscape
// cookies.txt for yt-dlp, tells NanumPlayer (mpv JSON IPC) to play the canonical URL and hides
// itself. Cookie values are never logged or printed.
//
// CLI:  nanum_youtube.exe [--pipe <mpv ipc pipe>] [--url <start url>] [--export-cookies-only]
//                         [--quit]
// Env:  NANUMPLAYER_YOUTUBE_DIR  state root (default %LOCALAPPDATA%\NanumPlayer\youtube);
//                                profile\ and cookies.txt live inside.
//       NANUMPLAYER_YOUTUBE_LOG  optional log file (no cookie values are ever written)
// Exit: 0 ok, 1 bad arguments, 2 WebView2 runtime missing, 3 WebView2 init failed,
//       4 cookie export failed, 5 timeout, 6 no running instance reachable, 7 --quit timeout

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
#include <sddl.h>
#include <dwmapi.h>
#include <commctrl.h>
#include <uxtheme.h>
#include <wrl.h>
#include <WebView2.h>

#include <algorithm>
#include <cstdarg>
#include <cstdio>
#include <functional>
#include <string>
#include <vector>

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
};

enum CopyType : ULONG_PTR { kCopyShow = 1, kCopyExport = 2, kCopyQuit = 3 };

enum ControlId { kIdBack = 101, kIdForward, kIdReload, kIdEdit, kIdPlay };
enum TimerId { kTimerLeave = 1, kTimerPipeWatch, kTimerExportOnly };
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

// ---------------------------------------------------------------- state / paths

struct App {
    // configuration
    std::wstring root, profileDir, cookiePath, pipe, startUrl;
    bool pipeSeen = false;
    ULONGLONG launchedAt = 0;
    bool exportOnly = false;
    uint64_t nameHash = 0;

    // window
    HWND hwnd = nullptr, back = nullptr, fwd = nullptr, reload = nullptr, edit = nullptr, play = nullptr;
    HFONT font = nullptr;
    HBRUSH barBrush = nullptr, editBrush = nullptr;
    int dpi = 96;
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

void ExportCookies(std::function<void(bool, int)> done) {
    ComPtr<ICoreWebView2_2> wv2;
    ComPtr<ICoreWebView2CookieManager> cm;
    if (!g.wv || FAILED(g.wv.As(&wv2)) || FAILED(wv2->get_CookieManager(&cm))) {
        done(false, 0);
        return;
    }
    HRESULT hr = cm->GetCookies(
        L"", Callback<ICoreWebView2GetCookiesCompletedHandler>(
                 [done](HRESULT result, ICoreWebView2CookieList* list) -> HRESULT {
                     if (FAILED(result) || !list) {
                         done(false, 0);
                         return S_OK;
                     }
                     UINT count = 0;
                     list->get_Count(&count);
                     std::string out =
                         "# Netscape HTTP Cookie File\n# This is a generated file! Do not edit.\n\n";
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
                         if (name.empty() || !WantedCookieDomain(domain) || bad(name) || bad(value) ||
                             bad(domain) || bad(path))
                             continue;
                         long long exp = session || expires <= 0 ? 0 : (long long)expires;
                         if (path.empty()) path = L"/";
                         std::string line;
                         if (httpOnly) line += "#HttpOnly_";
                         line += Utf8(domain);
                         line += domain[0] == L'.' ? "\tTRUE\t" : "\tFALSE\t";
                         line += Utf8(path);
                         line += secure ? "\tTRUE\t" : "\tFALSE\t";
                         line += std::to_string(exp);
                         line += "\t" + Utf8(name) + "\t" + Utf8(value) + "\n";
                         out += line;
                         written++;
                     }
                     bool ok = WriteFileAtomic(g.cookiePath, out);
                     SecureZeroMemory(out.data(), out.size());
                     Log(L"cookies exported: %d entries, %s", written, ok ? L"ok" : L"write failed");
                     done(ok, written);
                     return S_OK;
                 })
                 .Get());
    if (FAILED(hr)) done(false, 0);
}

// ---------------------------------------------------------------- mpv IPC

enum class IpcResult { Sent, NoPipe, Failed, Launched };

// Sends the open request to mpv's JSON IPC and reads the reply to this request (request_id 1).
IpcResult SendIpc(const std::wstring& pipe, const std::wstring& url) {
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
    std::string esc;
    for (char c : Utf8(url)) {
        if (c == '"' || c == '\\') esc += '\\';
        if ((unsigned char)c >= 0x20) esc += c;
    }
    std::string msg =
        "{\"command\":[\"script-message\",\"nanum-youtube-open\",\"" + esc + "\"],\"request_id\":1}\n";
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
    CloseHandle(h);
    Log(L"ipc: sent %s (%s)", url.c_str(), ok ? L"ok" : L"failed");
    return ok ? IpcResult::Sent : IpcResult::Failed;
}

bool PipeExists(const std::wstring& pipe) {
    if (WaitNamedPipeW(pipe.c_str(), 1)) return true;
    return GetLastError() != ERROR_FILE_NOT_FOUND;
}

// No player running: start NanumPlayer.exe (next to this exe) with the protocol URL; it plays
// the video itself, or forwards it to a player that appeared meanwhile.
bool LaunchPlayer(const std::wstring& canon) {
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
    std::wstring cmd = L"\"" + exe + L"\" \"nanumplayer://open?url=" + UrlEncode(canon) + L"\"";
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
    Log(L"launch: started NanumPlayer for %s", canon.c_str());
    return true;
}

// ---------------------------------------------------------------- window helpers

void RunWhenReady(std::function<void()> fn) {
    if (g.ready) fn();
    else g.whenReady.push_back(std::move(fn));
}

void NavigateTo(const std::wstring& url) {
    if (g.wv) g.wv->Navigate(url.c_str());
}

void FinishExportOnly(int code) {
    g.exitCode = code;
    DestroyWindow(g.hwnd);
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

void Layout() {
    RECT rc;
    GetClientRect(g.hwnd, &rc);
    int bar = S(46), pad = S(6), bh = S(32), y = (bar - bh) / 2;
    int wBack = S(60), wFwd = S(60), wReload = S(84), wPlay = S(196);
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
    g.font = CreateFontW(-S(15), 0, 0, 0, FW_NORMAL, 0, 0, 0, HANGUL_CHARSET, 0, 0, CLEARTYPE_QUALITY, 0,
                         L"Malgun Gothic");
    for (HWND h : {g.back, g.fwd, g.reload, g.edit, g.play})
        if (h) SendMessageW(h, WM_SETFONT, (WPARAM)g.font, TRUE);
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
    Log(L"video: %s", canon.c_str());
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
        std::wstring msg = r == IpcResult::NoPipe
                               ? L"NanumPlayer를 실행할 수 없습니다.\nNanumPlayer.exe가 이 프로그램과 같은 폴더에 있는지 확인하세요."
                               : L"NanumPlayer에 연결할 수 없습니다.\nNanumPlayer가 실행 중인지 확인하세요.";
        MessageBoxW(g.hwnd, msg.c_str(), L"NanumPlayer YouTube", MB_OK | MB_ICONWARNING);
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
    MessageBoxW(g.hwnd, L"재생할 동영상 페이지가 아닙니다.\nYouTube에서 동영상을 선택하세요.", L"NanumPlayer YouTube",
                MB_OK | MB_ICONINFORMATION);
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

void OnWebViewReady() {
    g.controller->get_CoreWebView2(&g.wv);
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
                                    Log(L"source-changed: %s", src.c_str());
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
                                     Log(L"history-changed: %s", src.c_str());
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
    g.wv->AddScriptToExecuteOnDocumentCreated(kDocumentScript, nullptr);

    Layout();
    g.controller->put_IsVisible(TRUE);
    UpdateNavButtons();

    for (auto& fn : g.whenReady) fn();
    g.whenReady.clear();

    if (g.exportOnly) {
        SetTimer(g.hwnd, kTimerExportOnly, 20000, nullptr);
        ExportCookies([](bool ok, int) { FinishExportOnly(ok ? kOk : kExportFailed); });
        return;
    }
    NavigateTo(g.startUrl.empty() ? kHome : g.startUrl);
    g.controller->MoveFocus(COREWEBVIEW2_MOVE_FOCUS_REASON_PROGRAMMATIC);
}

void StartWebView() {
    std::wstring userData = g.profileDir;
    HRESULT hr = CreateCoreWebView2EnvironmentWithOptions(
        nullptr, userData.c_str(), nullptr,
        Callback<ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler>(
            [](HRESULT result, ICoreWebView2Environment* env) -> HRESULT {
                if (FAILED(result) || !env) {
                    wchar_t msg[256];
                    swprintf_s(msg, L"WebView2를 시작할 수 없습니다. (0x%08X)", (unsigned)result);
                    Log(L"init failed: %s", msg);
                    if (!g.exportOnly) MessageBoxW(g.hwnd, msg, L"NanumPlayer YouTube", MB_OK | MB_ICONERROR);
                    g.exitCode = kInitFailed;
                    DestroyWindow(g.hwnd);
                    return S_OK;
                }
                g.env = env;
                env->CreateCoreWebView2Controller(
                    g.hwnd, Callback<ICoreWebView2CreateCoreWebView2ControllerCompletedHandler>(
                                [](HRESULT r, ICoreWebView2Controller* c) -> HRESULT {
                                    if (FAILED(r) || !c) {
                                        wchar_t msg[256];
                                        swprintf_s(msg, L"WebView2 창을 만들 수 없습니다. (0x%08X)", (unsigned)r);
                                        Log(L"controller failed: %s", msg);
                                        if (!g.exportOnly)
                                            MessageBoxW(g.hwnd, msg, L"NanumPlayer YouTube", MB_OK | MB_ICONERROR);
                                        g.exitCode = kInitFailed;
                                        DestroyWindow(g.hwnd);
                                        return S_OK;
                                    }
                                    g.controller = c;
                                    OnWebViewReady();
                                    return S_OK;
                                })
                                .Get());
                return S_OK;
            })
            .Get());
    if (FAILED(hr)) {
        wchar_t msg[256];
        swprintf_s(msg, L"WebView2를 시작할 수 없습니다. (0x%08X)", (unsigned)hr);
        Log(L"init failed: %s", msg);
        if (!g.exportOnly) MessageBoxW(g.hwnd, msg, L"NanumPlayer YouTube", MB_OK | MB_ICONERROR);
        g.exitCode = kInitFailed;
        DestroyWindow(g.hwnd);
    }
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
        Log(L"forwarded start: pipe %s, url %s", pipe.empty() ? L"(unchanged)" : L"updated", url.c_str());
        if (!g.exportOnly) ShowFront();
        UrlParts u = SplitUrl(url);
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
        g.back = btn(L"뒤로", kIdBack);
        g.fwd = btn(L"앞으로", kIdForward);
        g.reload = btn(L"새로고침", kIdReload);
        g.play = btn(L"NanumPlayer에서 재생", kIdPlay);
        g.edit = CreateWindowExW(0, L"EDIT", L"", WS_CHILD | WS_VISIBLE | WS_TABSTOP | WS_BORDER | ES_AUTOHSCROLL,
                                 0, 0, 10, 10, h, (HMENU)(INT_PTR)kIdEdit, nullptr, nullptr);
        SetWindowTheme(g.edit, L"DarkMode_CFD", L"Explorer");
        SetWindowSubclass(g.edit, EditProc, 1, 0);
        SendMessageW(g.edit, EM_SETCUEBANNER, TRUE, (LPARAM)L"주소 또는 검색어를 입력하세요");
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
            if (g.wv) g.wv->Reload();
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
        return TRUE;
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
        } else if (w == kTimerExportOnly) {
            FinishExportOnly(kTimeout);
        }
        return 0;
    case WM_CLOSE:
        DestroyWindow(h);
        return 0;
    case WM_DESTROY:
        g.controller.Reset();
        g.wv.Reset();
        g.env.Reset();
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

bool SendCopy(HWND target, ULONG_PTR type, const std::wstring& text) {
    DWORD pid = 0;
    GetWindowThreadProcessId(target, &pid);
    AllowSetForegroundWindow(pid);
    COPYDATASTRUCT cd = {type, (DWORD)((text.size() + 1) * sizeof(wchar_t)), (PVOID)text.c_str()};
    DWORD_PTR res = 0;
    return SendMessageTimeoutW(target, WM_COPYDATA, 0, (LPARAM)&cd, SMTO_ABORTIFHUNG, 5000, &res) != 0;
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
    return SendCopy(target, kCopyShow, pipe + L"\n" + url) ? kOk : kNoInstance;
}

int RunQuit() {
    HWND target = FindWindowW(WindowClassName().c_str(), nullptr);
    if (!target) return kOk;
    DWORD pid = 0;
    GetWindowThreadProcessId(target, &pid);
    HANDLE proc = OpenProcess(SYNCHRONIZE, FALSE, pid);
    if (!SendCopy(target, kCopyQuit, L"")) {
        if (proc) CloseHandle(proc);
        return kNoInstance;
    }
    int code = kOk;
    if (proc) {
        if (WaitForSingleObject(proc, 5000) != WAIT_OBJECT_0) code = kQuitTimeout;
        CloseHandle(proc);
    }
    return code;
}

}  // namespace

int WINAPI wWinMain(HINSTANCE inst, HINSTANCE, PWSTR, int) {
    int argc = 0;
    LPWSTR* argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    bool quit = false;
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
        else if (a == L"--export-cookies-only") g.exportOnly = true;
        else if (a == L"--quit") quit = true;
        else {
            MessageBoxW(nullptr,
                        L"사용법: nanum_youtube.exe [--pipe <mpv 파이프>] [--url <주소>] [--export-cookies-only] [--quit]",
                        L"NanumPlayer YouTube", MB_OK | MB_ICONINFORMATION);
            return kBadArgs;
        }
    }
    LocalFree(argv);

    std::wstring envRoot = EnvVar(L"NANUMPLAYER_YOUTUBE_DIR");
    g.root = FullPath(envRoot.empty() ? DefaultRoot() : envRoot);
    g.profileDir = g.root + L"\\profile";
    g.cookiePath = g.root + L"\\cookies.txt";
    g.nameHash = Fnv1a(Lower(g.root));
    if (quit) return RunQuit();

    // Single instance per state root: forward to the running one.
    HANDLE mutex = CreateMutexW(nullptr, TRUE, MutexName().c_str());
    if (mutex && GetLastError() == ERROR_ALREADY_EXISTS) {
        HWND target = FindInstanceWindow(5000);
        if (!target) return kNoInstance;
        return RunForwarded(target, g.pipe, g.startUrl, g.exportOnly);
    }
    if (g.pipe.empty()) g.pipe = DefaultPipe();

    if (FAILED(CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED))) return kInitFailed;

    LPWSTR ver = nullptr;
    HRESULT vr = GetAvailableCoreWebView2BrowserVersionString(nullptr, &ver);
    bool haveRuntime = SUCCEEDED(vr) && ver && *ver;
    if (ver) CoTaskMemFree(ver);
    if (!haveRuntime) {
        Log(L"WebView2 runtime missing (0x%08X)", (unsigned)vr);
        if (!g.exportOnly) {
            std::wstring msg =
                L"Microsoft Edge WebView2 런타임이 설치되어 있지 않아 YouTube 창을 열 수 없습니다.\n\n"
                L"다음 주소에서 \"Evergreen 부트스트래퍼\"를 설치한 뒤 다시 시도하세요.\n";
            msg += kRuntimeUrl;
            MessageBoxW(nullptr, msg.c_str(), L"NanumPlayer YouTube", MB_OK | MB_ICONERROR);
        }
        return kNoRuntime;
    }

    if (SHCreateDirectoryExW(nullptr, g.profileDir.c_str(), nullptr) != ERROR_SUCCESS &&
        GetFileAttributesW(g.profileDir.c_str()) == INVALID_FILE_ATTRIBUTES) {
        if (!g.exportOnly)
            MessageBoxW(nullptr, (L"프로필 폴더를 만들 수 없습니다.\n" + g.profileDir).c_str(), L"NanumPlayer YouTube",
                        MB_OK | MB_ICONERROR);
        return kInitFailed;
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
    bool startHidden = g.exportOnly || (!g.startUrl.empty() && ParseVideo(g.startUrl, direct));
    if (g.exportOnly) {
        ;
    } else if (!startHidden) {
        ShowWindow(hwnd, SW_SHOW);
        UpdateWindow(hwnd);
    }
    SetTimer(hwnd, kTimerPipeWatch, 3000, nullptr);
    StartWebView();

    MSG msg;
    while (GetMessageW(&msg, nullptr, 0, 0) > 0) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
    CoUninitialize();
    if (mutex) CloseHandle(mutex);
    return g.exitCode ? g.exitCode : (int)msg.wParam;
}
