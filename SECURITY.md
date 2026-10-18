# Security policy

## Supported versions

Security fixes are made for the **latest release** only. Please reproduce a problem on the latest
release (see the [Releases page](https://github.com/kimmingul/NanumPlayer/releases/latest)) before you
report it.

## Reporting a vulnerability

**Do not open a public issue for a security problem.** Report it privately:

1. Use GitHub's private reporting form: the **Security** tab of the repository, then
   **Report a vulnerability**
   ([github.com/kimmingul/NanumPlayer/security/advisories/new](https://github.com/kimmingul/NanumPlayer/security/advisories/new)); or
2. send an e-mail to [mgkim@nanumspace.com](mailto:mgkim@nanumspace.com) with the subject
   "NanumPlayer security".

Please include the NanumPlayer version, your Windows version, what you did, what happened, why you think
it is a security problem, and a proof of concept if you have one. Do not send media you do not have the
right to share.

This is a small project maintained by volunteers. We aim to acknowledge a report within 7 days, to tell you
whether we can reproduce it, and to publish a fix and a short advisory when the problem is confirmed. We
will credit you if you wish. Please give us a reasonable time to fix a problem before you disclose it.

## What is in scope

- NanumPlayer's own code: `NanumPlayer.exe` (the `nanum/` and `osdep/nanum-*` additions to mpv), the AI
  engines (`nanum_ai_cpu.dll`, `nanum_ai_cuda.dll`), the browser helper `nanum_youtube.exe`, the Lua
  scripts, the installer and the packaging scripts.
- The handling of downloads: the pinned URLs, size and SHA-256 checks, the way downloaded components are
  stored and loaded.
- Handling of untrusted input that NanumPlayer adds: subtitle files and archives (for example `.zip`
  imports), translation-server replies, web-page media addresses, cookies passed to the player.
- Anything that makes the default privacy promises in [docs/privacy.md](docs/privacy.md) untrue.

## What is out of scope

- Vulnerabilities in third-party software that NanumPlayer bundles or downloads (mpv, FFmpeg,
  whisper.cpp, libass, libbluray, WebView2, yt-dlp, Deno, Ollama and others). Report them to the upstream
  project; if a fix needs a new build of NanumPlayer, tell us once it is public.
- Problems that need an attacker who already has administrator rights or write access to the install folder
  or the user's profile.
- What a translation server or its provider does with the text it receives; this is described in
  [docs/privacy.md](docs/privacy.md).
- Requests about copy-protection circumvention. See [docs/disc-components.md](docs/disc-components.md).
- Reports produced by automated tools without a demonstrated impact.
