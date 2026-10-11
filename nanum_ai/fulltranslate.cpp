#include "fulltranslate.h"

#include <cwchar>
#include <cwctype>

#include <windows.h>

#include <chrono>
#include <cstdlib>
#include <mutex>
#include <thread>

namespace nanum {
namespace {

bool debug_on()
{
    static const bool dbg = std::getenv("NANUM_AI_DEBUG") != nullptr;
    return dbg;
}

std::wstring widen(const std::string &s)
{
    if (s.empty())
        return L"";
    int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), nullptr, 0);
    std::wstring w(n, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), w.data(), n);
    return w;
}

// ------------------------------------------------------------------ ollama

class OllamaEngine : public Engine {
public:
    explicit OllamaEngine(TranslatorConfig cfg)
        : timeout_ms_(std::max(cfg.timeout_ms, 180000)),    // windows are big requests
          tr_(without_cache(std::move(cfg)))
    {
    }

    bool run(const std::string &prompt, std::string &out, std::string &err) override
    {
        if (!tr_.enabled()) {
            err = "no translation endpoint configured";
            return false;
        }
        return tr_.complete(prompt, out, err, {8192, timeout_ms_});
    }

    void cancel() override { tr_.abort(); }

private:
    static TranslatorConfig without_cache(TranslatorConfig c)
    {
        c.cache_path.clear();
        return c;
    }
    int timeout_ms_;
    Translator tr_;
};

// --------------------------------------------------------------------- omp

std::wstring quote_arg(const std::wstring &a)
{
    if (!a.empty() && a.find_first_of(L" \t\"") == std::wstring::npos)
        return a;
    std::wstring r = L"\"";
    size_t bs = 0;
    for (wchar_t c : a) {
        if (c == L'\\') {
            bs++;
            continue;
        }
        if (c == L'"') {
            r.append(bs * 2 + 1, L'\\');
            r += L'"';
        } else {
            r.append(bs, L'\\');
            r += c;
        }
        bs = 0;
    }
    r.append(bs * 2, L'\\');
    r += L'"';
    return r;
}

void read_all(HANDLE h, std::string &out, size_t limit)
{
    char buf[8192];
    DWORD got;
    while (ReadFile(h, buf, sizeof(buf), &got, nullptr) && got) {
        if (out.size() < limit)
            out.append(buf, std::min<size_t>(got, limit - out.size()));
    }
}

class OmpEngine : public Engine {
public:
    OmpEngine(std::string command, std::string model, int timeout_s)
        : command_(command.empty() ? "omp" : std::move(command)), model_(std::move(model)),
          timeout_s_(timeout_s)
    {
    }

    bool run(const std::string &prompt, std::string &out, std::string &err) override;

    void cancel() override
    {
        std::lock_guard<std::mutex> lk(m_);
        cancelled_ = true;
        if (job_)
            TerminateJobObject(job_, 1);
    }

private:
    std::string command_, model_;
    int timeout_s_;
    std::mutex m_;
    bool cancelled_ = false;
    HANDLE job_ = nullptr;
    unsigned counter_ = 0;
};

bool OmpEngine::run(const std::string &prompt, std::string &out, std::string &err)
{
    if (model_.empty()) {
        err = "no omp model selected";
        return false;
    }
    {
        std::lock_guard<std::mutex> lk(m_);
        if (cancelled_) {
            err = "cancelled";
            return false;
        }
    }

    // The prompt goes through a file: it is too long for a command line.
    wchar_t tmpdir[MAX_PATH + 1];
    DWORD tn = GetTempPathW(MAX_PATH, tmpdir);
    std::wstring file = std::wstring(tmpdir, tn) + L"nanum_omp_" +
                        std::to_wstring(GetCurrentProcessId()) + L"_" +
                        std::to_wstring(GetTickCount64()) + L"_" + std::to_wstring(counter_++) +
                        L".txt";
    HANDLE hf = CreateFileW(file.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
                            FILE_ATTRIBUTE_TEMPORARY, nullptr);
    if (hf == INVALID_HANDLE_VALUE) {
        err = "cannot create the omp prompt file";
        return false;
    }
    DWORD wrote = 0;
    bool wok = WriteFile(hf, prompt.data(), (DWORD)prompt.size(), &wrote, nullptr) &&
               wrote == prompt.size();
    CloseHandle(hf);
    if (!wok) {
        DeleteFileW(file.c_str());
        err = "cannot write the omp prompt file";
        return false;
    }

    std::wstring exe = widen(command_);
    std::wstring cmd = quote_arg(exe) +
                       L" -p --no-tools --no-session --no-extensions --no-skills --no-rules "
                       L"--no-title --thinking=off --model " + quote_arg(widen(model_)) + L" " +
                       quote_arg(L"@" + file);
    {
        std::wstring low = exe;
        for (auto &c : low)
            c = (wchar_t)towlower(c);
        auto ends = [&](const wchar_t *e) {
            size_t n = wcslen(e);
            return low.size() >= n && low.compare(low.size() - n, n, e) == 0;
        };
        if (ends(L".cmd") || ends(L".bat"))
            cmd = L"cmd.exe /d /s /c \"" + cmd + L"\"";
    }

    SECURITY_ATTRIBUTES sa = {sizeof(sa), nullptr, TRUE};
    HANDLE out_r = nullptr, out_w = nullptr, err_r = nullptr, err_w = nullptr;
    HANDLE nul = CreateFileW(L"NUL", GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, &sa,
                             OPEN_EXISTING, 0, nullptr);
    bool ok = nul != INVALID_HANDLE_VALUE && CreatePipe(&out_r, &out_w, &sa, 0) &&
              CreatePipe(&err_r, &err_w, &sa, 0);
    if (ok) {
        SetHandleInformation(out_r, HANDLE_FLAG_INHERIT, 0);
        SetHandleInformation(err_r, HANDLE_FLAG_INHERIT, 0);
    }

    PROCESS_INFORMATION pi = {};
    HANDLE job = nullptr;
    std::string output, errout;
    bool started = false, timed_out = false, was_cancelled = false;
    DWORD exit_code = 0;

    if (ok) {
        // Only these three handles are inherited, not every inheritable handle
        // of the host process.
        HANDLE inherit[3] = {nul, out_w, err_w};
        SIZE_T asz = 0;
        InitializeProcThreadAttributeList(nullptr, 1, 0, &asz);
        std::vector<char> abuf(asz);
        auto *attrs = (LPPROC_THREAD_ATTRIBUTE_LIST)abuf.data();
        bool have_attrs = InitializeProcThreadAttributeList(attrs, 1, 0, &asz) &&
                          UpdateProcThreadAttribute(attrs, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
                                                    inherit, sizeof(inherit), nullptr, nullptr);
        STARTUPINFOEXW si = {};
        si.StartupInfo.cb = sizeof(si);
        si.StartupInfo.dwFlags = STARTF_USESTDHANDLES | STARTF_USESHOWWINDOW;
        si.StartupInfo.wShowWindow = SW_HIDE;
        si.StartupInfo.hStdInput = nul;
        si.StartupInfo.hStdOutput = out_w;
        si.StartupInfo.hStdError = err_w;
        si.lpAttributeList = have_attrs ? attrs : nullptr;
        if (!have_attrs)
            si.StartupInfo.cb = sizeof(STARTUPINFOW);

        job = CreateJobObjectW(nullptr, nullptr);
        if (job) {
            JOBOBJECT_EXTENDED_LIMIT_INFORMATION li = {};
            li.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            SetInformationJobObject(job, JobObjectExtendedLimitInformation, &li, sizeof(li));
        }

        std::vector<wchar_t> cl(cmd.begin(), cmd.end());
        cl.push_back(L'\0');
        DWORD flags = CREATE_NO_WINDOW | CREATE_SUSPENDED | CREATE_UNICODE_ENVIRONMENT |
                      (have_attrs ? EXTENDED_STARTUPINFO_PRESENT : 0);
        started = CreateProcessW(nullptr, cl.data(), nullptr, nullptr, TRUE, flags, nullptr,
                                 nullptr, &si.StartupInfo, &pi) != 0;
        if (have_attrs)
            DeleteProcThreadAttributeList(attrs);
        if (!started)
            err = "cannot start '" + command_ + "' (error " + std::to_string(GetLastError()) + ")";
    }
    if (out_w)
        CloseHandle(out_w);
    if (err_w)
        CloseHandle(err_w);
    if (nul && nul != INVALID_HANDLE_VALUE)
        CloseHandle(nul);

    if (started) {
        if (job)
            AssignProcessToJobObject(job, pi.hProcess);
        {
            std::lock_guard<std::mutex> lk(m_);
            job_ = job;
            if (cancelled_ && job_)
                TerminateJobObject(job_, 1);
        }
        ResumeThread(pi.hThread);
        CloseHandle(pi.hThread);

        std::thread t_out([&] { read_all(out_r, output, 16u << 20); });
        std::thread t_err([&] { read_all(err_r, errout, 16u << 10); });

        auto t0 = std::chrono::steady_clock::now();
        for (;;) {
            DWORD w = WaitForSingleObject(pi.hProcess, 200);
            if (w == WAIT_OBJECT_0)
                break;
            {
                std::lock_guard<std::mutex> lk(m_);
                was_cancelled = cancelled_;
            }
            bool to = std::chrono::steady_clock::now() - t0 > std::chrono::seconds(timeout_s_);
            if (was_cancelled || to) {
                timed_out = to && !was_cancelled;
                if (job)
                    TerminateJobObject(job, 1);
                else
                    TerminateProcess(pi.hProcess, 1);
                WaitForSingleObject(pi.hProcess, 5000);
                break;
            }
        }
        GetExitCodeProcess(pi.hProcess, &exit_code);
        // Stragglers (child processes of omp) must not keep the pipes open.
        if (job)
            TerminateJobObject(job, 1);
        t_out.join();
        t_err.join();
        {
            std::lock_guard<std::mutex> lk(m_);
            job_ = nullptr;
            was_cancelled = cancelled_;
        }
        CloseHandle(pi.hProcess);
    }
    if (job)
        CloseHandle(job);
    if (out_r)
        CloseHandle(out_r);
    if (err_r)
        CloseHandle(err_r);
    DeleteFileW(file.c_str());

    if (!started)
        return false;
    if (was_cancelled) {
        err = "cancelled";
        return false;
    }
    if (timed_out) {
        err = "omp timed out after " + std::to_string(timeout_s_) + " s";
        return false;
    }
    if (exit_code != 0) {
        std::string tail = trim_ws(errout.empty() ? output : errout);
        if (tail.size() > 300)
            tail = tail.substr(tail.size() - 300);
        err = "omp exited with code " + std::to_string(exit_code) +
              (tail.empty() ? "" : ": " + tail);
        return false;
    }
    out = std::move(output);
    return true;
}

} // namespace

std::unique_ptr<Engine> make_ollama_engine(TranslatorConfig cfg)
{
    return std::make_unique<OllamaEngine>(std::move(cfg));
}

std::unique_ptr<Engine> make_omp_engine(const std::string &command, const std::string &model,
                                        int timeout_s)
{
    return std::make_unique<OmpEngine>(command, model, timeout_s);
}

// ------------------------------------------------------------------ driver

namespace {

constexpr int MAX_CONSECUTIVE_ENGINE_FAILURES = 3;

struct Run {
    Engine &engine;
    const FullParams &p;
    const std::atomic<bool> &cancel;
    int consecutive_failures = 0;
    std::string fatal;          // set when the engine is clearly unusable
    std::string last_err;

    // One engine call. false: no usable text (engine failure counted).
    bool call(const std::string &prompt, std::string &text)
    {
        std::string err;
        auto t0 = std::chrono::steady_clock::now();
        bool ok = engine.run(prompt, text, err);
        if (debug_on())
            std::fprintf(stderr, "full: call %zu chars -> %s in %.1fs %s\n", prompt.size(),
                         ok ? "ok" : "FAIL",
                         std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count(),
                         ok ? "" : err.c_str());
        if (ok) {
            consecutive_failures = 0;
            return true;
        }
        if (!cancel.load()) {
            last_err = err;
            if (++consecutive_failures >= MAX_CONSECUTIVE_ENGINE_FAILURES)
                fatal = err;
        }
        return false;
    }

    bool stopped() const { return cancel.load() || !fatal.empty(); }

    // Translates lines[begin,end): two attempts, parsed strictly.
    bool translate_range(std::vector<FullLine> &lines, const Glossary &gl, size_t begin, size_t end)
    {
        size_t ctx = begin > p.overlap ? begin - p.overlap : 0;
        std::string prompt = window_prompt(p, gl, lines, ctx, begin, end);
        for (int attempt = 0; attempt < 2 && !stopped(); attempt++) {
            std::string text;
            std::vector<std::string> tr;
            if (call(prompt, text) && parse_numbered(text, end - begin, tr)) {
                for (size_t i = begin; i < end; i++)
                    lines[i].tr = tr[i - begin];
                return true;
            }
            if (debug_on())
                std::fprintf(stderr, "full: window %zu-%zu attempt %d malformed or failed\n",
                             begin, end, attempt + 1);
        }
        return false;
    }
};

} // namespace

std::string translate_full(Engine &engine, std::vector<FullLine> &lines, const FullParams &params,
                           Glossary &glossary, const std::atomic<bool> &cancel,
                           const std::function<void(double)> &progress)
{
    Run run{engine, params, cancel};
    for (auto &l : lines)
        l.tr.clear();
    if (lines.empty())
        return "nothing to translate";

    // 1) Glossary: the given entries first, the extraction only adds names they lack and
    // makes family/given/full names consistent without touching the given ones.
    const size_t given = glossary.size();
    auto chunks = glossary_chunks(lines);
    for (size_t i = 0; i < chunks.size() && !run.stopped(); i++) {
        std::string text;
        if (run.call(glossary_prompt(params, chunks[i]), text))
            merge_glossary(glossary, parse_glossary_answer(text, params.target_language));
        progress(0.05 * (double)(i + 1) / (double)chunks.size());
    }
    harmonize_names(glossary, given);
    if (debug_on()) {
        std::fprintf(stderr, "full: glossary %zu entries\n", glossary.size());
        for (auto &g : glossary)
            std::fprintf(stderr, "  %s => %s\n", g.first.c_str(), g.second.c_str());
    }

    // 2) Windows.
    auto windows = make_windows(lines.size(), params.window);
    size_t done = 0;
    for (auto &w : windows) {
        if (run.stopped())
            break;
        if (!run.translate_range(lines, glossary, w.first, w.second) && !run.stopped()) {
            // 3) Line-by-line fallback through the same engine.
            for (size_t i = w.first; i < w.second && !run.stopped(); i++)
                run.translate_range(lines, glossary, i, i + 1);
        }
        done += w.second - w.first;
        if (!run.stopped())
            progress(0.05 + 0.95 * (double)done / (double)lines.size());
    }

    if (cancel.load())
        return "cancelled";
    if (!run.fatal.empty())
        return "translation engine failed: " + run.fatal;
    bool any = false;
    for (auto &l : lines)
        any |= !l.tr.empty();
    if (!any)
        return "no line could be translated" +
               (run.last_err.empty() ? std::string() : ": " + run.last_err);
    return "";
}

} // namespace nanum
