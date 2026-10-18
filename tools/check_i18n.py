#!/usr/bin/env python3
"""Verify that NanumPlayer's interface is fully translated into all six UI languages.

Checks (errors fail the run, warnings do not):

  catalogs   locales/*.json: valid, every language present, identical printf conversions, English-keyed
             entries carry an explicit Korean text, no untranslated Hangul in other languages, the same
             line-break / edge-whitespace shape as the source, no dead keys (never referenced by the code).
  Lua        scripts/*.lua: every core_tr()/tr() key exists in its catalog, enough arguments for the
             conversions, no hardcoded Korean/CJK text outside translation calls, no English literal passed
             to a toast/notification sink.
  C / C++    third_party/mpv nanum sources (nanum_tr, N_, nanum_trw, NANUM_MSG, NANUM_ARG, nanum_msg) and
             youtube/nanum_youtube.cpp (T): every key in locales/native.json / web.json, no hardcoded
             Korean/CJK text outside translation calls.
  installer  tools/languages/NanumMessages.iss: every custom message in all six languages with the same
             %n / %1 / %2 shape; every {cm:...}/M()/MF() use defined; no unused message; the [Languages]
             section lists the six languages.

Allowlist: a comment containing "i18n-ignore" on the same or the previous line exempts a literal from the
hardcoded-text rules (use it for log-only or protocol strings, with a reason). Log calls (MP_*, mp.msg.*,
print) are exempt automatically.

Warnings: translations whose display width exceeds 1.6x the Korean source and 60 columns.

Usage: python tools/check_i18n.py [--verbose] [--max-warnings N]
"""
import argparse
import os
import re
import sys
import unicodedata
from pathlib import Path

TOOLS = Path(__file__).resolve().parent
# NANUM_I18N_ROOT: check another copy of the tree (used to self-test the checker).
ROOT = Path(os.environ.get("NANUM_I18N_ROOT") or TOOLS.parent).resolve()
sys.path.insert(0, str(TOOLS))
from compile_translations import LANGUAGES, FORMAT, load_catalog  # noqa: E402

CATALOGS = ("core", "fluent", "generate", "native", "web")
HANGUL = re.compile(r"[\u1100-\u11ff\u3130-\u318f\uac00-\ud7a3]")
# Hangul, kana, CJK ideographs: text a user reads. Other non-ASCII (arrows, bullets, quotes) is a symbol.
CJK = re.compile(r"[\u1100-\u11ff\u3130-\u318f\uac00-\ud7a3\u3040-\u30ff\u3400-\u4dbf\u4e00-\u9fff]")
LATIN_WORD = re.compile(r"[A-Za-z]{3,}")
SENTENCE = re.compile(r"[A-Za-z]{3,}\s+\S")  # two or more words: text a person reads
EXAMPLE_TARGET = "히카리"  # the glossary template's example entry ("Hikari => 히카리") keeps its Korean sample
IGNORE = "i18n-ignore"

# Lua: translation function name -> catalog ("tr" depends on the file).
LUA_TR_NAMESPACE = {
    "nanum-fluent.lua": "fluent", "fluent-input.lua": "fluent", "nanum-rip.lua": "fluent",
    "nanum-generate.lua": "generate", "nanum-subtitles.lua": "core", "nanum.lua": "core",
}
LUA_LOG_CALLS = {"print"}
LUA_LOG_PREFIXES = ("msg", "mp.msg")
LUA_SINKS = {"notify", "add_toast", "toast", "osd_message"}

# C: function -> index of the key argument; all go to native.json.
C_KEY_CALLS = {"nanum_tr": 0, "nanum_trw": 0, "nanum_tr_lang": 0, "nanum_native_tr": 0, "N_": 0,
               "NANUM_ARG": 0, "NANUM_MSG": 1, "nanum_msg": 2, "MSG": 2}
C_LOG_CALLS = re.compile(r"^(MP_(MSG|FATAL|ERR|WARN|INFO|STATUS|V|DBG|TRACE|VERBOSE)|mp_msg|mp_err|mp_warn|mp_info|"
                         r"mp_verbose|mp_dbg|mp_fatal|mp_trace|mp_msg_log_buffer.*|printf|fprintf|OutputDebugString[AW]?|"
                         r"mp_.*_msg|MP_[A-Z]+)$")
C_FILES = (list((ROOT / "third_party/mpv/osdep").glob("nanum-*.c")) + list((ROOT / "third_party/mpv/osdep").glob("nanum-*.h")) +
           list((ROOT / "third_party/mpv/nanum").glob("*.c")) + list((ROOT / "third_party/mpv/nanum").glob("*.h")))
CPP_FILE = ROOT / "youtube/nanum_youtube.cpp"
CPP_KEY_CALLS = {"T": 0}

errors = []
warnings = []


def err(where, text):
    errors.append(f"{where}: {text}")


def warn(where, text):
    warnings.append(f"{where}: {text}")


def rel(path):
    try:
        return Path(path).resolve().relative_to(ROOT).as_posix()
    except ValueError:
        return str(path)


# ------------------------------------------------------------------------------------------ lexers
class Tok:
    __slots__ = ("kind", "text", "line", "wide")

    def __init__(self, kind, text, line, wide=False):
        self.kind, self.text, self.line, self.wide = kind, text, line, wide

    def __repr__(self):
        return f"{self.kind}:{self.text!r}@{self.line}"


C_ESC = {"n": "\n", "t": "\t", "r": "\r", "\\": "\\", '"': '"', "'": "'", "a": "\a", "b": "\b", "f": "\f", "v": "\v", "?": "?"}
LUA_ESC = {"n": "\n", "t": "\t", "r": "\r", "\\": "\\", '"': '"', "'": "'", "a": "\a", "b": "\b", "f": "\f", "v": "\v"}


def lex_c(src):
    """Tokens (id, str, punct) and the comment lines (line numbers whose comment holds IGNORE)."""
    toks, ignore_lines = [], set()
    i, n, line = 0, len(src), 1
    while i < n:
        c = src[i]
        if c == "\n":
            line += 1
            i += 1
        elif c in " \t\r\f\v":
            i += 1
        elif src.startswith("//", i):
            j = src.find("\n", i)
            j = n if j < 0 else j
            if IGNORE in src[i:j]:
                ignore_lines.add(line)
            i = j
        elif src.startswith("/*", i):
            j = src.find("*/", i + 2)
            j = n if j < 0 else j + 2
            body = src[i:j]
            if IGNORE in body:
                ignore_lines.update(range(line, line + body.count("\n") + 1))
            line += body.count("\n")
            i = j
        elif c == '"' or (c in "LuU" and src.startswith('"', i + 1)) or src.startswith('u8"', i):
            wide = c == "L"
            i = src.index('"', i)
            start_line = line
            i += 1
            out = []
            while i < n and src[i] != '"':
                if src[i] == "\\":
                    i += 1
                    e = src[i]
                    if e in C_ESC:
                        out.append(C_ESC[e])
                        i += 1
                    elif e == "x":
                        m = re.match(r"[0-9A-Fa-f]+", src[i + 1:])
                        out.append(chr(int(m.group(0)[:2], 16)))
                        i += 1 + len(m.group(0))
                    elif e in "01234567":
                        m = re.match(r"[0-7]{1,3}", src[i:])
                        out.append(chr(int(m.group(0), 8)))
                        i += len(m.group(0))
                    elif e in "uU":
                        k = 4 if e == "u" else 8
                        out.append(chr(int(src[i + 1:i + 1 + k], 16)))
                        i += 1 + k
                    elif e == "\n":
                        line += 1
                        i += 1
                    else:
                        out.append(e)
                        i += 1
                else:
                    if src[i] == "\n":
                        line += 1
                    out.append(src[i])
                    i += 1
            i += 1
            toks.append(Tok("str", "".join(out), start_line, wide))
            if len(toks) > 1 and toks[-2].kind == "str":  # adjacent literals concatenate
                prev = toks[-2]
                toks[-2:] = [Tok("str", prev.text + toks[-1].text, prev.line, prev.wide or wide)]
        elif c == "'":
            i += 1
            while i < n and src[i] != "'":
                i += 2 if src[i] == "\\" else 1
            i += 1
            toks.append(Tok("char", "", line))
        elif c.isalpha() or c == "_":
            m = re.compile(r"[A-Za-z_0-9]+").match(src, i)
            toks.append(Tok("id", m.group(0), line))
            i = m.end()
        elif c.isdigit():
            m = re.compile(r"[0-9A-Za-z_.]+").match(src, i)
            toks.append(Tok("num", m.group(0), line))
            i = m.end()
        else:
            toks.append(Tok("punct", c, line))
            i += 1
    return toks, ignore_lines


def lex_lua(src):
    toks, ignore_lines = [], set()
    i, n, line = 0, len(src), 1
    long_open = re.compile(r"\[(=*)\[")
    while i < n:
        c = src[i]
        if c == "\n":
            line += 1
            i += 1
        elif c in " \t\r":
            i += 1
        elif src.startswith("--", i):
            m = long_open.match(src, i + 2)
            if m:
                close = "]" + m.group(1) + "]"
                j = src.find(close, m.end())
                j = n if j < 0 else j + len(close)
                body = src[i:j]
                if IGNORE in body:
                    ignore_lines.update(range(line, line + body.count("\n") + 1))
                line += body.count("\n")
                i = j
            else:
                j = src.find("\n", i)
                j = n if j < 0 else j
                if IGNORE in src[i:j]:
                    ignore_lines.add(line)
                i = j
        elif c in "\"'":
            q = c
            start_line = line
            i += 1
            out = []
            while i < n and src[i] != q:
                if src[i] == "\\":
                    i += 1
                    e = src[i]
                    if e in LUA_ESC:
                        out.append(LUA_ESC[e])
                        i += 1
                    elif e.isdigit():
                        m = re.match(r"\d{1,3}", src[i:])
                        out.append(chr(int(m.group(0))))
                        i += len(m.group(0))
                    elif e == "x":
                        out.append(chr(int(src[i + 1:i + 3], 16)))
                        i += 3
                    elif e == "u":
                        m = re.match(r"u\{([0-9A-Fa-f]+)\}", src[i:])
                        out.append(chr(int(m.group(1), 16)))
                        i += len(m.group(0))
                    elif e == "z":
                        i += 1
                        while i < n and src[i] in " \t\r\n":
                            line += src[i] == "\n"
                            i += 1
                    elif e == "\n":
                        out.append("\n")
                        line += 1
                        i += 1
                    else:
                        out.append(e)
                        i += 1
                else:
                    out.append(src[i])
                    i += 1
            i += 1
            toks.append(Tok("str", "".join(out), start_line))
        elif c == "[" and long_open.match(src, i):
            m = long_open.match(src, i)
            close = "]" + m.group(1) + "]"
            j = src.find(close, m.end())
            body = src[m.end():j]
            if body.startswith("\n"):
                body = body[1:]
            toks.append(Tok("str", body, line))
            line += src[i:j].count("\n")
            i = j + len(close)
        elif c.isalpha() or c == "_":
            m = re.compile(r"[A-Za-z_0-9]+").match(src, i)
            toks.append(Tok("id", m.group(0), line))
            i = m.end()
        elif c.isdigit():
            m = re.compile(r"[0-9A-Za-z_.]+").match(src, i)
            toks.append(Tok("num", m.group(0), line))
            i = m.end()
        elif src.startswith("...", i):
            toks.append(Tok("punct", "...", line))
            i += 3
        elif src.startswith("..", i):
            toks.append(Tok("punct", "..", line))
            i += 2
        else:
            toks.append(Tok("punct", c, line))
            i += 1
    return toks, ignore_lines


def call_name(toks, k):
    """The dotted/colon name ending at identifier token k (a.b.c or a:b), as a string."""
    parts = [toks[k].text]
    j = k
    while j >= 2 and toks[j - 1].kind == "punct" and toks[j - 1].text in ".:" and toks[j - 2].kind == "id":
        parts.append(toks[j - 2].text)
        j -= 2
    return ".".join(reversed(parts))


def split_args(toks, open_idx):
    """Arguments of the call whose '(' is at open_idx: list of (token list), index of the matching ')'."""
    depth, args, cur, i = 0, [], [], open_idx
    while i < len(toks):
        t = toks[i]
        if t.kind == "punct" and t.text in "([{":
            depth += 1
            if depth > 1:
                cur.append(t)
        elif t.kind == "punct" and t.text in ")]}":
            depth -= 1
            if depth == 0:
                if cur or args:
                    args.append(cur)
                return args, i
            cur.append(t)
        elif t.kind == "punct" and t.text == "," and depth == 1:
            args.append(cur)
            cur = []
        else:
            cur.append(t)
        i += 1
    return args, i


def is_compared(toks, i):
    """True when the string token i is an operand of == or ~= (a value tested, not text shown)."""
    before = toks[i - 1].text + toks[i - 2].text if i >= 2 else ""
    after = toks[i + 1].text + toks[i + 2].text if i + 2 < len(toks) else ""
    return before in ("==", "=~") or after in ("==", "~=")


def format_count(key):
    return len([f for f in FORMAT.findall(key) if f != "%%"])


# ------------------------------------------------------------------------------------------ catalogs
def display_width(text):
    return sum(2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in text)


def load_all():
    cats = {}
    for ns in CATALOGS:
        path = ROOT / "locales" / f"{ns}.json"
        try:
            cats[ns] = load_catalog(path)
        except Exception as exc:  # noqa: BLE001 - report everything load_catalog rejects
            err(rel(path), str(exc))
    return cats


def source_text(key, row):
    """The Korean text of an entry: the key itself when it is Korean, else the explicit ko translation."""
    return row.get("ko") or key


def check_catalog(ns, cat):
    where = f"locales/{ns}.json"
    for key, row in cat.items():
        label = f"{where}[{key[:48]!r}]"
        ko = source_text(key, row)
        if not HANGUL.search(key) and "ko" not in row and re.search(r"[a-z]{3}", key):
            err(label, "English-keyed entry without an explicit 'ko' text (Korean UI would show English)")
        for lang in LANGUAGES:
            text = row.get(lang, key if lang == "ko" else None)
            if text is None:
                err(label, f"missing {lang}")
                continue
            if lang != "ko" and HANGUL.search(text.replace(EXAMPLE_TARGET, "")):
                err(label, f"{lang} text contains Hangul: {text[:60]!r}")
            if lang != "ko" and text == ko and HANGUL.search(ko):
                err(label, f"{lang} equals the Korean source (untranslated)")
            if text.count("\n") != ko.count("\n"):
                err(label, f"{lang} has {text.count(chr(10))} line breaks, source {ko.count(chr(10))}")
            if lang != "ko" and (text[:1].isspace() != ko[:1].isspace() or text[-1:].isspace() != ko[-1:].isspace()):
                err(label, f"{lang} edge whitespace differs from the source")
            if lang != "ko" and FORMAT.findall(ko) != FORMAT.findall(text):
                err(label, f"{lang} conversions {FORMAT.findall(text)} differ from {FORMAT.findall(ko)}")
            if lang in ("en", "ja", "zh-CN", "zh-TW", "es") and text.strip() == "":
                err(label, f"{lang} is blank")
            if lang != "ko":
                sw, tw = display_width(ko), display_width(text)
                if tw > 60 and tw > 1.6 * sw:
                    warn(label, f"{lang} width {tw} vs source {sw} ({tw / max(sw, 1):.1f}x): {text[:70]!r}")


# ------------------------------------------------------------------------------------------ Lua
def analyze_lua(path, cats, used, indirect):
    name = Path(path).name
    src = Path(path).read_text(encoding="utf-8-sig")
    toks, ignored = lex_lua(src)
    where = rel(path)
    tr_ns = LUA_TR_NAMESPACE.get(name, "core")
    keyed = set()  # token indices of strings that are catalog keys
    exempt = set()  # token indices of strings inside log calls
    called_ns = set()  # catalogs this file translates through
    for k, t in enumerate(toks):
        if t.kind != "id" or k + 1 >= len(toks) or not (toks[k + 1].kind == "punct" and toks[k + 1].text == "("):
            continue
        if k > 0 and toks[k - 1].kind == "id" and toks[k - 1].text == "function":
            continue  # a definition: function tr(key, ...)
        full = call_name(toks, k)
        last = t.text
        ns = "core" if last == "core_tr" else tr_ns if last == "tr" else None
        if ns:
            called_ns.add(ns)
        args, end = split_args(toks, k + 1)
        arg_range = range(k + 2, end)
        if full in LUA_LOG_CALLS or full.startswith(LUA_LOG_PREFIXES):
            exempt.update(arg_range)
            continue
        if ns and args:
            a0 = args[0]
            a0_idx = range(k + 2, k + 2 + len(a0))
            strs = [x for x in a0 if x.kind == "str"]
            idxs = [i for i in a0_idx if toks[i].kind == "str"]
            pure = all(x.kind == "str" or (x.kind == "punct" and x.text == "..") for x in a0)
            if pure and strs:
                key = "".join(x.text for x in a0 if x.kind == "str")
                keyed.update(idxs)
                check_lua_key(where, t.line, ns, key, len(args) - 1, args, cats, used)
            elif strs:
                # tr(cond and "a" or "b"): every literal that is not merely compared is a key
                concat = any(x.kind == "punct" and x.text == ".." for x in a0)
                for i in idxs:
                    x = toks[i]
                    if is_compared(toks, i):
                        continue
                    keyed.add(i)
                    if x.text in cats.get(ns, {}):
                        used[ns].add(x.text)
                    elif concat and (CJK.search(x.text) or SENTENCE.search(x.text)):
                        warn(f"{where}:{x.line}", f"key built by concatenation: {x.text[:50]!r}")
                    elif CJK.search(x.text) or SENTENCE.search(x.text):
                        err(f"{where}:{x.line}", f"{ns} key not in catalog: {x.text[:70]!r}")
            else:
                warn(f"{where}:{t.line}", f"{full}() key is not a literal (checked via literal-is-key rule)")
    # A literal that is a catalog key counts as a use (tables of keys translated later: tr(LABELS[i])).
    for t in toks:
        if t.kind == "str":
            for ns in called_ns:
                if t.text in cats.get(ns, {}):
                    used[ns].add(t.text)
    # Hangul literals outside translation calls
    for k, t in enumerate(toks):
        if t.kind != "str" or k in keyed or k in exempt or not CJK.search(t.text):
            continue
        if t.line in ignored or t.line - 1 in ignored:
            continue
        found = [ns for ns in called_ns if t.text in cats.get(ns, {})]
        if found:
            for ns in found:
                used[ns].add(t.text)
            indirect.append((where, t.line, t.text))
            continue
        err(f"{where}:{t.line}", f"hardcoded text outside translation: {t.text[:60]!r}")
    # English literals handed straight to UI sinks
    for k, t in enumerate(toks):
        if t.kind != "id" or t.text not in LUA_SINKS or k + 1 >= len(toks) or toks[k + 1].text != "(":
            continue
        if k > 0 and toks[k - 1].kind == "id" and toks[k - 1].text == "function":
            continue
        args, end = split_args(toks, k + 1)
        if not args:
            continue
        for i in range(k + 2, k + 2 + len(args[0])):
            if i in keyed or toks[i].kind != "str" or not SENTENCE.search(toks[i].text):
                continue
            if is_compared(toks, i):
                continue  # compared, not shown
            # nested translation call → keyed already; otherwise the literal reaches the screen untranslated
            if toks[i].line in ignored or toks[i].line - 1 in ignored:
                continue
            err(f"{where}:{toks[i].line}", f"untranslated literal passed to {t.text}(): {toks[i].text[:60]!r}")


def check_lua_key(where, line, ns, key, nargs, args, cats, used):
    cat = cats.get(ns)
    if cat is None:
        return
    if key not in cat:
        err(f"{where}:{line}", f"{ns} key not in catalog: {key[:70]!r}")
        return
    used[ns].add(key)
    need = format_count(key)
    last = args[-1] if len(args) > 1 else []
    open_ended = bool(last) and (last[-1].text in (")", "...") or last[0].text == "unpack")
    if need and nargs < need and not open_ended:
        err(f"{where}:{line}", f"{ns} key needs {need} argument(s), call passes {nargs}: {key[:60]!r}")
    if not nargs and "%%" in key:
        err(f"{where}:{line}", f"key with '%%' called without arguments (string.format is skipped, shows '%%'): {key[:60]!r}")


# ------------------------------------------------------------------------------------------ C / C++
def analyze_c(path, calls, ns, cats, used, wide_hint=False):
    src = Path(path).read_text(encoding="utf-8-sig")
    toks, ignored = lex_c(src)
    where = rel(path)
    cat = cats.get(ns)
    keyed, exempt = set(), set()
    is_header = str(path).endswith(".h")
    for k, t in enumerate(toks):
        if t.kind != "id" or k + 1 >= len(toks) or toks[k + 1].text != "(":
            continue
        if is_header and k > 0 and toks[k - 1].text == "define":
            continue
        args, end = split_args(toks, k + 1)
        arg_range = list(range(k + 2, end))
        if t.text in calls:
            idx = calls[t.text]
            # a macro/function definition's own parameter list has no strings; skip when <= idx args
            if idx >= len(args):
                continue
            a = args[idx]
            positions = {id(x) for x in a}
            strs = [x for x in a if x.kind == "str"]
            for i in arg_range:
                if id(toks[i]) in positions and toks[i].kind == "str":
                    keyed.add(i)
            if not strs:
                if any(x.kind == "id" for x in a):
                    continue  # forwarded variable (wrapper); its literals are checked at the definition's callers
                continue
            for x in strs:
                key = x.text
                if cat is None:
                    continue
                if key not in cat:
                    err(f"{where}:{x.line}", f"{ns} key not in catalog: {key[:70]!r}")
                else:
                    used[ns].add(key)
        elif C_LOG_CALLS.match(t.text) and not t.text.startswith("nanum_"):
            exempt.update(arg_range)
    for k, t in enumerate(toks):
        if t.kind != "str" or k in keyed or k in exempt or not CJK.search(t.text):
            continue
        if t.line in ignored or t.line - 1 in ignored:
            continue
        if cat is not None and t.text in cat:
            used[ns].add(t.text)
            err(f"{where}:{t.line}", f"catalog key used as a plain literal (wrap in N_()/translate): {t.text[:60]!r}")
            continue
        err(f"{where}:{t.line}", f"hardcoded text outside translation: {t.text[:60]!r}")


def analyze_cpp_extra(path):
    pass


# ------------------------------------------------------------------------------------------ installer
ISS_LANGS = ("korean", "english", "japanese", "chinesesimplified", "chinesetraditional", "spanish")


def check_installer():
    msgs = ROOT / "tools/languages/NanumMessages.iss"
    iss = ROOT / "tools/installer.iss"
    text = msgs.read_text(encoding="utf-8-sig")
    table = {}
    for n, raw in enumerate(text.splitlines(), 1):
        if not raw.strip() or raw.lstrip().startswith(";") or raw.startswith("["):
            continue
        m = re.match(r"^([a-z]+)\.([A-Za-z0-9_]+)=(.*)$", raw)
        if not m:
            err(f"{rel(msgs)}:{n}", f"unparseable line: {raw[:60]!r}")
            continue
        lang, key, value = m.groups()
        if lang not in ISS_LANGS:
            err(f"{rel(msgs)}:{n}", f"unknown language {lang!r}")
        if key in table and lang in table[key]:
            err(f"{rel(msgs)}:{n}", f"duplicate {lang}.{key}")
        table.setdefault(key, {})[lang] = value
    shape = lambda s: (sorted(re.findall(r"%\d", s)), s.count("%n"))  # noqa: E731
    for key, row in sorted(table.items()):
        for lang in ISS_LANGS:
            if lang not in row:
                err(f"{rel(msgs)}", f"{key}: missing {lang}")
            elif not row[lang].strip():
                err(f"{rel(msgs)}", f"{key}: blank {lang}")
        ko = row.get("korean", "")
        for lang in ISS_LANGS:
            v = row.get(lang)
            if v is None:
                continue
            if lang != "korean" and HANGUL.search(v):
                err(f"{rel(msgs)}", f"{key}.{lang} contains Hangul")
            if shape(v) != shape(ko):
                err(f"{rel(msgs)}", f"{key}.{lang} placeholders/line breaks {shape(v)} differ from korean {shape(ko)}")
            if v[:1].isspace() or v[-1:].isspace():
                err(f"{rel(msgs)}", f"{key}.{lang} has edge whitespace")
            neutral = HANGUL.search(ko) is None  # a message with no Korean text ("cuBLAS: %1") is language-neutral
            if lang in ("chinesesimplified", "chinesetraditional", "japanese") and not CJK.search(v) and not neutral:
                err(f"{rel(msgs)}", f"{key}.{lang} has no CJK text (untranslated?)")
            if lang in ("english", "spanish") and CJK.search(v):
                err(f"{rel(msgs)}", f"{key}.{lang} contains CJK text")
    code = iss.read_text(encoding="utf-8-sig")
    other = [p for p in (ROOT / "dist").glob("NanumPlayer-*.iss")] if (ROOT / "dist").exists() else []
    used = set(re.findall(r"\{cm:([A-Za-z0-9_]+)", code))
    used |= set(re.findall(r"\bMF?2?\(\s*'([A-Za-z0-9_]+)'", code))
    used |= set(re.findall(r"CustomMessage\(\s*'([A-Za-z0-9_]+)'", code))
    # keys of Inno's own .isl files that installer.iss refers to ({cm:CreateDesktopIcon}, {cm:AdditionalIcons}, ...)
    isl_keys = set()
    for p in (ROOT / "tools/languages").glob("*.isl"):
        isl_keys |= set(re.findall(r"^([A-Za-z0-9_]+)=", p.read_text(encoding="utf-8-sig"), re.M))
    for p in (ROOT / "tools/package.py",):
        used |= set(re.findall(r"\bMF?2?\(\s*'([A-Za-z0-9_]+)'", p.read_text(encoding="utf-8")))
    for key in sorted(used):
        if key not in table and key not in isl_keys and key not in INNO_BUILTIN_CM:
            err(rel(iss), f"message {key!r} used but not defined in NanumMessages.iss")
    for key in sorted(set(table) - used):
        err(rel(msgs), f"{key} is defined but never used")
    langs = re.findall(r'^Name:\s*"([a-z]+)"', code.split("[Languages]")[1].split("[Tasks]")[0], re.M)
    for lang in ISS_LANGS:
        if lang not in langs:
            err(rel(iss), f"[Languages] lacks {lang}")
    for lang in langs:
        if lang not in ISS_LANGS:
            err(rel(iss), f"[Languages] lists unsupported {lang}")
    for p in (ROOT / "tools/languages").glob("*.isl"):
        if not p.read_text(encoding="utf-8-sig").strip():
            err(rel(p), "empty language file")
    # Hangul in installer code outside comments and the messages file
    for n, raw in enumerate(code.splitlines(), 1):
        if CJK.search(raw) and not raw.lstrip().startswith(";") and "//" not in raw and IGNORE not in raw:
            err(f"{rel(iss)}:{n}", f"hardcoded CJK text: {raw.strip()[:60]!r}")
    return table


# Messages every Inno Setup language file provides, used by installer.iss through {cm:...}.
INNO_BUILTIN_CM = {"CreateDesktopIcon", "AdditionalIcons", "UninstallProgram", "LaunchProgram", "NameAndVersion",
                   "ProgramOnTheWeb", "AssocFileExtension", "AutoStartProgram", "AutoStartProgramGroupDescription",
                   "AssocingFileExtension", "CreateQuickLaunchIcon"}


# ------------------------------------------------------------------------------------------ main
def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--verbose", action="store_true", help="list every warning and literal-is-key use")
    parser.add_argument("--max-warnings", type=int, default=15, help="warnings printed without --verbose")
    parser.add_argument("--skip-native", action="store_true",
                        help="do not scan the mpv submodule's C sources (and treat native.json keys as used)")
    args = parser.parse_args()

    cats = load_all()
    for ns, cat in cats.items():
        check_catalog(ns, cat)
    used = {ns: set() for ns in CATALOGS}
    indirect = []
    for path in sorted((ROOT / "scripts").glob("*.lua")):
        analyze_lua(path, cats, used, indirect)
    if args.skip_native:
        used["native"] = set(cats.get("native", {}))
    elif not C_FILES:
        err("third_party/mpv", "native sources not found; run `git submodule update --init third_party/mpv` "
                               "or pass --skip-native")
    for path in sorted(set(C_FILES)) if not args.skip_native else ():
        analyze_c(path, C_KEY_CALLS, "native", cats, used)
    analyze_c(CPP_FILE, CPP_KEY_CALLS, "web", cats, used)
    check_installer()

    # Keys referenced by the code in any other way (strings kept in tables and translated later)
    for ns, cat in cats.items():
        for key in cat:
            if key not in used[ns]:
                err(f"locales/{ns}.json[{key[:48]!r}]", "unused key (no reference in the code); remove it")

    if args.verbose:
        for where, line, text in indirect:
            print(f"note: {where}:{line}: catalog key kept as a literal, translated later: {text[:50]!r}")
    shown = warnings if args.verbose else warnings[:args.max_warnings]
    for w in shown:
        print("warning:", w)
    if len(shown) < len(warnings):
        print(f"warning: ... {len(warnings) - len(shown)} more (use --verbose)")
    for e in errors:
        print("error:", e)
    total = sum(len(c) for c in cats.values())
    print(f"{total} catalog entries x {len(LANGUAGES)} languages; {len(indirect)} indirect literals; "
          f"{len(errors)} error(s), {len(warnings)} warning(s)")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
