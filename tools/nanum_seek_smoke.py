#!/usr/bin/env python3
"""AI subtitles after seeks: real-disc smoke driver and log oracle.

Background: with a Blu-ray TrueHD PID (TrueHD + its AC-3 core, two streams with
one demuxer id) the AI audio input used to take turns between both streams. Each
turn dropped the queued audio and re-opened the decoder ("analysing audio
stream" + "truehd: Stream parameters not seen; skipping frame" in a loop), so
the engine received a fraction of the audio on a compressed timeline and had no
Korean for tens of seconds after every seek (nanum/nanum.c, resolve_pin()).

Two uses:

  run      start the player on a disc/file, drive the seeks over mpv's JSON IPC,
           check readiness and Korean sub-text after each one, then analyse the
           player's own verbose log.  Uses a private config dir, library DB,
           translation cache and log; the user's %APPDATA% data is not touched.

  analyze  check an existing verbose log (--log-file, --msg-level=all=v) for the
           same properties; e.g. the log of a manual session.

  selftest feeds the analyzer a synthetic bad and a synthetic good log.

Examples (E: holds the disc; NanumPlayer.exe has its DLLs/models beside it):

  py tools/nanum_seek_smoke.py run --exe D:/path/NanumPlayer.exe
  py tools/nanum_seek_smoke.py run --exe D:/path/NanumPlayer.exe ^
        --scenario 300,4500,900,mid,mid,mid+4,rel-6 --lead 20
  py tools/nanum_seek_smoke.py run --exe D:/path/NanumPlayer.exe --url D:/m.mkv
  py tools/nanum_seek_smoke.py analyze %APPDATA%/NanumPlayer/last-playback.log

Scenario tokens: N (absolute seconds), mid (half the duration), mid+N / mid-N,
relN / rel-N (relative seek). A disc has no seekable demuxer cache, so the
second `mid` repeats the same landing; a file (--url) with a seekable cache also
exercises the in-cache path (`mid+4`, `rel-6` stay inside the cached range).

Exit status 0: every check passed.
"""

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import threading
import time

HANGUL = re.compile(r"[\uac00-\ud7a3]")
LINE = re.compile(r"^\[\s*([0-9.]+)\]\[(.)\]\[([^\]]*)\] (.*)$")
RE_SEEK = re.compile(r"^execute seek \(to ([-0-9.]+)")
RE_EVENT = re.compile(r"^event ([-0-9.]+) \+([0-9.]+): (.*?) \| (.*)$")
RE_TAP = re.compile(r"^tap: (?:AI input )?audio stream (\d+) \((\w+)\)")
RE_ANALYSING = re.compile(r"^analysing audio stream: (\w+)")


class Epoch:
    """Everything between one demuxer seek and the next."""

    def __init__(self, label, target, t0):
        self.label = label
        self.target = target
        self.t0 = t0            # log time of the seek
        self.t1 = t0
        self.decoder_opens = 0
        self.language_switches = 0
        self.param_warnings = 0
        self.flushes = 0
        self.events = 0
        self.korean_events = 0
        self.first_korean = None    # (log time, pts, text)

    def as_dict(self):
        return {
            "epoch": self.label, "target": self.target,
            "log_seconds": round(self.t1 - self.t0, 1),
            "decoder_opens": self.decoder_opens,
            "language_switches": self.language_switches,
            "param_warnings": self.param_warnings,
            "decoder_flushes": self.flushes,
            "events": self.events, "korean_events": self.korean_events,
            "first_korean_after_s": None if not self.first_korean
            else round(self.first_korean[0] - self.t0, 1),
            "first_korean_pts": None if not self.first_korean
            else self.first_korean[1],
        }


def analyze_lines(lines, args):
    epochs = [Epoch("start", None, 0.0)]
    taps = set()
    inputs = []
    last_seek = None
    for line in lines:
        m = LINE.match(line)
        if not m:
            continue
        t, _lvl, _mod, msg = float(m.group(1)), m.group(2), m.group(3), m.group(4)
        ep = epochs[-1]
        ep.t1 = t
        s = RE_SEEK.match(msg)
        if s:
            target = float(s.group(1))
            # nested demuxers log the same seek twice
            if last_seek is not None and last_seek[0] == target and t - last_seek[1] < 0.5:
                continue
            last_seek = (target, t)
            epochs.append(Epoch("seek %d" % (len(epochs)), target, t))
            continue
        if msg.startswith("audio language:"):
            ep.language_switches += 1
        elif msg.startswith("analysing audio stream:"):
            ep.decoder_opens += 1
        elif "Stream parameters not seen" in msg:
            ep.param_warnings += 1
        elif msg.startswith("audio decoder flushed"):
            ep.flushes += 1
        elif msg.startswith("AI audio input:"):
            inputs.append(msg)
        else:
            tp = RE_TAP.match(msg)
            if tp:
                taps.add((int(tp.group(1)), tp.group(2)))
                continue
            ev = RE_EVENT.match(msg)
            if ev:
                ep.events += 1
                if HANGUL.search(ev.group(4)):
                    ep.korean_events += 1
                    pts = float(ev.group(1))
                    near = ep.target is None or pts >= ep.target - 5
                    if near and ep.first_korean is None:
                        ep.first_korean = (t, pts, ev.group(4))

    failures = []
    for ep in epochs:
        if ep.decoder_opens > args.max_decoder_opens:
            failures.append("%s: decoder opened %d times (max %d): the audio input "
                            "is being switched/reset repeatedly"
                            % (ep.label, ep.decoder_opens, args.max_decoder_opens))
        if ep.language_switches > args.max_decoder_opens:
            failures.append("%s: audio language/stream re-announced %d times"
                            % (ep.label, ep.language_switches))
        if ep.param_warnings > args.max_param_warnings:
            failures.append("%s: %d 'Stream parameters not seen' warnings (max %d): "
                            "the TrueHD decoder keeps losing its state"
                            % (ep.label, ep.param_warnings, args.max_param_warnings))
        if (ep.t1 - ep.t0) >= args.min_epoch_seconds and ep.korean_events == 0 \
                and args.require_korean:
            failures.append("%s: no Korean event in %.0f s" % (ep.label, ep.t1 - ep.t0))
    if len(taps) > 1:
        failures.append("more than one audio stream is analysed: %s" % sorted(taps))
    return {"epochs": [e.as_dict() for e in epochs], "taps": sorted(taps),
            "inputs": inputs, "failures": failures}


def analyze_file(path, args):
    with open(path, encoding="utf-8", errors="replace") as f:
        return analyze_lines(f, args)


def print_analysis(res):
    print("%-9s %8s %8s %8s %9s %7s %7s %s" % ("epoch", "target", "opens", "lang",
                                              "param-warn", "events", "korean",
                                              "first Korean (s after seek)"))
    for e in res["epochs"]:
        print("%-9s %8s %8d %8d %9d %7d %7d %s" % (
            e["epoch"], "-" if e["target"] is None else "%.1f" % e["target"],
            e["decoder_opens"], e["language_switches"], e["param_warnings"],
            e["events"], e["korean_events"], e["first_korean_after_s"]))
    print("audio streams tapped:", res["taps"])
    for i in res["inputs"]:
        print(" ", i)
    for f in res["failures"]:
        print("FAIL:", f)


# --------------------------------------------------------------------------
# Driver

class Mpv:
    def __init__(self, pipe, proc, timeout=180):
        self.rid = 0
        deadline = time.time() + timeout
        while True:
            if proc.poll() is not None:
                raise RuntimeError("player exited (%s) before the IPC pipe appeared"
                                   % proc.returncode)
            try:
                self.f = open(pipe, "r+b", buffering=0)
                break
            except OSError:
                if time.time() > deadline:
                    raise
                time.sleep(0.25)

    def cmd(self, *args):
        self.rid += 1
        self.f.write((json.dumps({"command": list(args), "request_id": self.rid}) +
                      "\n").encode())
        while True:
            line = self.f.readline()
            if not line:
                raise EOFError("player closed the IPC pipe")
            obj = json.loads(line)
            if obj.get("request_id") == self.rid:
                return obj

    def get(self, prop, default=None):
        r = self.cmd("get_property", prop)
        return r.get("data", default) if r.get("error") == "success" else default


def pick(paths):
    for p in paths:
        if p and os.path.exists(p):
            return p
    return None


def player_args(args, work):
    exe_dir = os.path.dirname(os.path.abspath(args.exe))
    roots = [args.root, exe_dir, os.path.dirname(exe_dir)]
    models = [os.path.join(r, "models") for r in roots if r]

    def model(name):
        return pick([os.path.join(m, name) for m in models])

    cmd = [
        args.exe,
        "--config-dir=" + os.path.join(work, "config"),
        "--msg-level=all=v",
        "--log-file=" + os.path.join(work, "seek.log"),
        "--nanum",
        "--nanum-cache=" + os.path.join(work, "tr_cache.jsonl"),
        "--nanum-library-db=" + os.path.join(work, "library.db"),
        "--demuxer-readahead-secs=120",
        "--demuxer-max-bytes=1500MiB",
        "--slang=kor",
        "--vo=" + args.vo,
        "--ao=null",
        "--idle=no",
        "--force-window=no",
        "--input-ipc-server=" + args.pipe,
    ]
    for option, filename in (
            ("nanum-stt-model", "ggml-small.en.bin"),
            ("nanum-stt-model-multilingual", "ggml-small.bin"),
            ("nanum-vad-model", "ggml-silero-v5.1.2.bin")):
        path = model(filename)
        if path:
            cmd.append("--" + option + "=" + path)
    # Model-free packages resolve downloaded user models through native defaults.
    if args.url.startswith("bd:") and args.device:
        cmd.append("--bluray-device=" + args.device)
    for e in args.player_arg:
        cmd.append(e)
    cmd.append(args.url)
    return cmd


def abs_pos(m):
    pos = m.get("time-pos")
    if pos is None:
        return None
    return pos + (m.get("demuxer-start-time") or 0)


def ready_until(m):
    st = m.get("demuxer-cache-state") or {}
    return st.get("nanum-ready-until")


def ai_sid(m):
    for t in m.get("track-list") or []:
        if t.get("type") == "sub" and (t.get("title") == "ko (AI)" or
                                       (t.get("codec") == "ass" and t.get("lang") == "kor")):
            return t["id"]
    return None


def wait_ready(m, lead, timeout, near=None):
    """Seconds until the AI has recognised `lead` seconds ahead of the position."""
    t0 = time.monotonic()
    while time.monotonic() - t0 < timeout:
        pos, r = abs_pos(m), ready_until(m)
        if pos is not None and r is not None and r >= pos + lead and \
                (near is None or abs(pos - near) < 2):
            return time.monotonic() - t0
        time.sleep(0.4)
    return None


def wait_korean(m, timeout):
    t0 = time.monotonic()
    while time.monotonic() - t0 < timeout:
        txt = m.get("sub-text")
        if txt and HANGUL.search(txt):
            return time.monotonic() - t0, txt.replace("\n", " / ")
        time.sleep(0.3)
    return None, None


def step(m, label, args, seek=None):
    row = {"step": label}
    target = None
    landed = True
    if args.hold:
        m.cmd("set_property", "pause", True)
    if seek is not None:
        kind, value = seek
        target = value if kind == "absolute" else (abs_pos(m) or 0) + value
        m.cmd("seek", value, kind + "+exact")
        time.sleep(0.5)  # let even a same-position asynchronous seek start
        deadline = time.monotonic() + 30
        landed = False
        while time.monotonic() < deadline:
            pos = abs_pos(m)
            if pos is not None and abs(pos - target) < 2:
                landed = True
                break
            time.sleep(0.2)
        row["requested_at"] = round(target, 2)
        row["landed_at"] = None if pos is None else round(pos, 2)
    r = wait_ready(m, args.lead, args.ready_timeout,
                   near=target if args.hold else None) if landed else None
    row["ready_after_s"] = None if r is None else round(r, 1)
    if args.hold:
        m.cmd("set_property", "pause", False)
    k, txt = wait_korean(m, args.sub_timeout) if landed else (None, None)
    row["korean_after_s"] = None if k is None else round(k, 1)
    row["korean_text"] = txt
    row["shown_at"] = abs_pos(m) if k is not None else None
    lines = [line.strip() for line in (m.get("sub-text") or "").splitlines() if line.strip()]
    duplicates = m.get("options/nanum-display") == "translation" and len(lines) != len(set(lines))
    row["duplicate_lines"] = duplicates
    ok = landed and r is not None and k is not None and not duplicates
    row["ok"] = ok
    print("%-12s landed=%-9s ready=%-6s korean=%-6s %s %s" % (
        label, row.get("landed_at"), row["ready_after_s"], row["korean_after_s"],
        "OK" if ok else "FAIL", txt or ""))
    return row


def parse_scenario(text, duration):
    out = []
    for tok in text.split(","):
        tok = tok.strip()
        mm = re.fullmatch(r"mid([+-]\d+(?:\.\d+)?)?", tok)
        rel = re.fullmatch(r"rel([+-]?\d+(?:\.\d+)?)", tok)
        if mm:
            out.append((tok, ("absolute", duration / 2 + float(mm.group(1) or 0))))
        elif rel:
            out.append((tok, ("relative", float(rel.group(1)))))
        else:
            v = float(tok)
            out.append((tok, ("absolute", min(max(0, v), max(0, duration - 1)))))
    return out


def run(args):
    work = args.work or tempfile.mkdtemp(prefix="nanum-seek-")
    os.makedirs(os.path.join(work, "config"), exist_ok=True)
    args.pipe = r"\\.\pipe\nanum-seek-%d" % os.getpid()
    cmd = player_args(args, work)
    print("work dir:", work)
    print("command :", " ".join('"%s"' % c if " " in c else c for c in cmd))
    proc = subprocess.Popen(cmd)
    killer = threading.Timer(args.total_timeout, proc.kill)
    killer.start()
    rows, ok = [], True
    try:
        m = Mpv(args.pipe, proc)
        t0 = time.monotonic()
        while True:                     # the file is open once it has a duration
            if proc.poll() is not None:
                raise RuntimeError("player exited while loading")
            if m.get("duration") and m.get("time-pos") is not None:
                break
            if time.monotonic() - t0 > args.load_timeout:
                raise RuntimeError("media did not load in %d s" % args.load_timeout)
            time.sleep(0.5)
        duration = m.get("duration")
        print("loaded in %.0f s, duration %.0f s" % (time.monotonic() - t0, duration))
        sid = ai_sid(m)
        if sid is None:
            raise RuntimeError("no 'ko (AI)' subtitle track (is --nanum on, "
                               "are the DLL/model paths right?)")
        m.cmd("set_property", "sid", sid)
        m.cmd("set_property", "sub-visibility", True)
        if m.get("pause"):
            m.cmd("set_property", "pause", False)
        rows.append(step(m, "start", args))
        for label, seek in parse_scenario(args.scenario, duration):
            rows.append(step(m, label, args, seek))
        ok = all(r["ok"] for r in rows)
        try:
            m.cmd("quit")
        except Exception:
            pass
    except Exception as e:      # noqa: BLE001 - report and fall through to cleanup
        print("ERROR:", e)
        ok = False
    finally:
        try:
            proc.wait(timeout=30)
        except subprocess.TimeoutExpired:
            proc.kill()
        killer.cancel()

    log = os.path.join(work, "seek.log")
    res = analyze_file(log, args) if os.path.exists(log) else \
        {"failures": ["no log written"], "epochs": [], "taps": [], "inputs": []}
    print()
    print_analysis(res)
    report = os.path.join(work, "report.json")
    with open(report, "w", encoding="utf-8") as f:
        json.dump({"steps": rows, "analysis": res, "ok": ok and not res["failures"]},
                  f, ensure_ascii=False, indent=1)
    print("report:", report)
    print("log   :", log)
    good = ok and not res["failures"]
    print("RESULT:", "PASS" if good else "FAIL")
    return 0 if good else 1


# --------------------------------------------------------------------------

def selftest(args):
    def line(t, mod, msg, lvl="v"):
        return "[%8.3f][%s][%s] %s\n" % (t, lvl, mod, msg)

    bad = [line(1, "disc/nanum", "tap: audio stream 1 (truehd) pts=0.00 len=1 packets=1"),
           line(2, "disc/nanum", "tap: audio stream 2 (ac3) pts=0.00 len=1 packets=2")]
    for i in range(50):
        bad += [line(3 + i / 100, "disc/nanum", "audio language: en", "i"),
                line(3 + i / 100, "disc/nanum", "analysing audio stream: truehd 48000 Hz, 6 ch"),
                line(3 + i / 100, "ffmpeg/audio", "truehd: Stream parameters not seen; "
                     "skipping frame.", "w")]
    bad.append(line(30, "disc", "execute seek (to 543.36 flags 32)"))
    bad.append(line(70, "disc/nanum", "event 543.05 +1.8: a | 그건"))
    good = [line(1, "disc/nanum", "AI audio input: stream 1 (id 4352, truehd)"),
            line(1, "disc/nanum", "tap: AI input audio stream 1 (truehd) pts=0.00 len=1 "
                 "packets=1"),
            line(2, "disc/nanum", "audio language: en", "i"),
            line(2, "disc/nanum", "analysing audio stream: truehd 48000 Hz, 6 ch"),
            line(3, "disc/nanum", "event 4.0 +1.0: x | 안녕"),
            line(30, "disc", "execute seek (to 543.36 flags 32)"),
            line(30, "disc/nanum", "audio decoder flushed"),
            line(45, "disc/nanum", "event 543.05 +1.8: a | 그건")]
    rb = analyze_lines(bad, args)
    rg = analyze_lines(good, args)
    assert any("opened" in f for f in rb["failures"]), rb
    assert any("more than one audio stream" in f for f in rb["failures"]), rb
    assert any("Korean" in f for f in rb["failures"]), rb
    assert not rg["failures"], rg
    assert rg["epochs"][1]["first_korean_after_s"] == 15.0, rg
    print("selftest ok")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="mode", required=True)

    def common(p):
        p.add_argument("--max-decoder-opens", type=int, default=3,
                       help="decoder (re)opens / language announcements per seek epoch")
        p.add_argument("--max-param-warnings", type=int, default=1000,
                       help="'Stream parameters not seen' per epoch (TrueHD waits for "
                            "a major sync once after a seek; a loop gives thousands)")
        p.add_argument("--min-epoch-seconds", type=float, default=30,
                       help="epochs shorter than this need no Korean event")
        p.add_argument("--require-korean", action="store_true", default=True)

    a = sub.add_parser("analyze")
    a.add_argument("log")
    common(a)
    sub.add_parser("selftest")
    common(sub.choices["selftest"])

    r = sub.add_parser("run")
    common(r)
    r.add_argument("--exe", required=True, help="NanumPlayer.exe")
    r.add_argument("--root", help="folder with models/ "
                                  "(default: beside --exe)")
    r.add_argument("--url", default="bd://")
    r.add_argument("--device", default="E:", help="--bluray-device for bd:// urls")
    r.add_argument("--scenario", default="300,4500,900,mid,mid,mid+4,rel-6")
    r.add_argument("--lead", type=float, default=20,
                   help="seconds the AI must have recognised ahead of the position")
    r.add_argument("--ready-timeout", type=float, default=120)
    r.add_argument("--sub-timeout", type=float, default=120,
                   help="how long to play (after readiness) waiting for Korean text")
    r.add_argument("--load-timeout", type=float, default=180)
    r.add_argument("--total-timeout", type=float, default=3600)
    r.add_argument("--no-hold", dest="hold", action="store_false",
                   help="do not pause after a seek until the AI is ready")
    r.add_argument("--vo", default="null", help="video output (gpu-next: real window)")
    r.add_argument("--work", help="directory for config, DB, cache and log")
    r.add_argument("--player-arg", action="append", default=[],
                   help="extra player option, e.g. --player-arg=--script=...nanum.lua")

    args = ap.parse_args()
    if args.mode == "selftest":
        return selftest(args)
    if args.mode == "analyze":
        res = analyze_file(args.log, args)
        print_analysis(res)
        print("RESULT:", "FAIL" if res["failures"] else "PASS")
        return 1 if res["failures"] else 0
    return run(args)


if __name__ == "__main__":
    sys.exit(main())
