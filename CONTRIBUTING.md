# Contributing to NanumPlayer

Thank you for helping. NanumPlayer is a Windows video player built on mpv that makes AI subtitles while
you watch. Please read this page before you open an issue or a pull request. By taking part you agree to
follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## Ways to help

- **Report a bug or request a feature** with the [issue forms](https://github.com/kimmingul/NanumPlayer/issues/new/choose).
  Search the existing issues first.
- **Report a security problem privately**; see [SECURITY.md](SECURITY.md). Do not open a public issue.
- **Improve the documentation or a translation.** The user documentation is in English (primary) and
  Korean; the interface has six languages. Wording fixes are welcome.
- **Fix something.** Small, focused pull requests are easiest to review. For a larger change, open an
  issue first so we can agree on the approach.

## Reporting a bug well

Include what the issue form asks for. In particular:

- the NanumPlayer version (start screen, or **Ctrl+K**), your Windows version and your GPU;
- how you installed it (installer or portable ZIP) and how you started the player;
- the translation server and model, the speech model, and the acceleration mode (CPU or CUDA);
- what **Ctrl+K** shows during the problem;
- the smallest set of steps that reproduces it. For media problems, say the container, the codec and
  whether it is a file, a disc, YouTube or a web page; **do not attach copyrighted media**.

Logs: the player keeps no playback log by default. A log you create (`--log-file`, the disc diagnostic
log) can contain addresses, file names and paths. Read it and remove anything private before you attach it.

## Development setup

[docs/building.md](docs/building.md) lists the toolchain and the build steps: MSYS2 CLANG64 for the
player, Visual Studio 2022 (MSVC) for the AI engines and the browser helper, Inno Setup for the installer.
Clone with `--recurse-submodules`; the player and the speech engine are submodules on the `nanum` branch
of the project's forks (`kimmingul/mpv`, `kimmingul/whisper.cpp`).

Where things are:

| Area | Path | Language |
|---|---|---|
| Player patches, AI tap, subtitle injection | `third_party/mpv/nanum`, `third_party/mpv/osdep/nanum-*`, `demux/`, `player/`, `stream/` | C (mpv style) |
| AI engine (speech recognition, VAD, translation) | `nanum_ai/` | C++ (MSVC), C ABI in `nanum_ai.h` |
| User interface | `scripts/*.lua` | Lua (mpv scripting) |
| Translations | `locales/*.json` | JSON |
| Browser helper (YouTube, web pages) | `youtube/` | C++ (Win32, WebView2) |
| Packaging and installer | `tools/` | Python, Inno Setup |

Smoke-test with an isolated configuration folder (`--config-dir=<temp folder>`) so that your own settings,
models and sign-ins are untouched.

## Rules for changes

1. **Every user-visible string must exist in all six interface languages** (Korean, English, Spanish,
   Japanese, Simplified Chinese, Traditional Chinese). Route it through the translation helpers
   (`input.core_tr()` / `tr()` in Lua, `nanum_tr()`, `N_()` and the related macros in C, `T()` in the browser
   helper) with the Korean text as the key, and add the entry to the right file in `locales/` (`core` for the
   Lua menus, `fluent` for the start screen and playback bar, `generate` for subtitle generation, `native` for
   the C code, `web` for the browser helper), with `en`, `es`, `ja`, `zh-CN` and `zh-TW` values (an
   English-keyed native entry also needs an explicit `ko` value). Installer texts go in
   `tools/languages/NanumMessages.iss`. Keep printf conversions identical in every language. A literal that is
   intentionally not translated (log text, language names written in their own language, match patterns) takes
   an `i18n-ignore: <reason>` comment on the same or the previous line. Run `python tools/check_i18n.py`
   (exit code 0 means every language is complete); the CI workflow runs it too, and the packager rejects a catalog that lacks a language.
2. **Keep privacy by default.** Do not add telemetry, a persistent log, a history, a cache or a crash dump
   that is on by default, and do not add a network connection that is not documented in
   [docs/privacy.md](docs/privacy.md). Anything that keeps data must be opt-in and explicit.
3. **Downloads must be pinned.** A downloaded file needs an HTTPS URL, an exact size and a SHA-256, and
   must be verified before it is used (`components/catalog.json`, `models/catalog.json`).
4. **Do not claim what you did not verify.** Documentation and UI text must describe behavior you tested.
   When something is not verified, say so (see the [verification history](docs/development/verification-history.md)).
5. **Keep terminology consistent.** Use the terms in the [glossary](docs/glossary.md), and update the
   English and Korean documentation together.
6. **Do not add decryption code or keys to the default package.** Components that circumvent copy
   protection are an optional, separately downloaded component; see
   [docs/disc-components.md](docs/disc-components.md). Do not add or request keys, key databases or
   anything that facilitates infringing use.
7. **Match the surrounding style.** C code follows mpv's `.editorconfig` (4 spaces, 80 columns); keep Lua
   and C++ in the style of the file you edit. Do not reformat code you are not changing.
8. **Add a regression test** for a bug fix when one is practical. Do not add tests that only restate the
   implementation.

## Commits and pull requests

- One logical change per commit; write the subject line in the imperative ("Fix …", "Add …") and explain the
  *why* in the body when it is not obvious.
- Describe in the pull request what you changed, how you tested it (what you ran, on what media and
  hardware) and what you did not test. Fill in the pull request template.
- Update the documentation and the [changelog](CHANGELOG.md) (the *Unreleased* section) for user-visible
  changes.
- A maintainer may ask for changes. Be patient; this is a small project.

## Licensing of contributions

NanumPlayer is licensed under the GNU General Public License, version 2 or (at your option) any later
version ([LICENSE](LICENSE)). By submitting a contribution you state that you have the right to do so and
agree that it is licensed under the same terms, unless a file under `third_party/` states a different
license in its header, in which case the header applies. Third-party code you bring in must be under a
license compatible with the GPL; add it to [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
