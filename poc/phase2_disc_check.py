"""Phase 2 final check on the real Blu-ray: play in real time and measure how
far ahead of playback each AI subtitle line reaches mpv.

lead = event pts - playback position at the moment nanum logged the event.
lead > 0 means the line was available before it had to be shown.

Usage: phase2_disc_check.py [start_s] [play_s] [readahead_s] [translate_model]
"""
import json
import os
import re
import statistics
import subprocess
import sys
import threading
import time

ROOT = r"D:\repo\NanumPlayer"
MPV = ROOT + r"\third_party\mpv\build\NanumPlayer.exe"
PIPE = r"\\.\pipe\nanum_phase2_disc"
LOG = ROOT + r"\cache\phase2_disc.log"
ERR = ROOT + r"\cache\phase2_disc.err"
EVENT_RE = re.compile(r"^\[\s*([\d.]+)\].*nanum\] event ([\d.]+) \+([\d.]+): (.*?) \| (.*)$")


class Ipc:
    def __init__(self):
        self.f = None
        self.rid = 0
        self.lock = threading.Lock()

    def connect(self, timeout=20):
        end = time.time() + timeout
        while time.time() < end:
            try:
                self.f = open(PIPE, "r+b", buffering=0)
                return
            except OSError:
                time.sleep(0.1)
        raise TimeoutError("mpv pipe")

    def cmd(self, *args):
        with self.lock:
            self.rid += 1
            self.f.write((json.dumps({"command": list(args), "request_id": self.rid}) + "\n").encode())
            while True:
                d = json.loads(self.f.readline().decode())
                if d.get("request_id") == self.rid:
                    return d

    def prop(self, name):
        return self.cmd("get_property", name).get("data")


def main():
    start = float(sys.argv[1]) if len(sys.argv) > 1 else 300.0
    play_s = float(sys.argv[2]) if len(sys.argv) > 2 else 150.0
    readahead = sys.argv[3] if len(sys.argv) > 3 else "120"
    model = sys.argv[4] if len(sys.argv) > 4 else "gemma4:latest"
    cache = ROOT + r"\cache\p2_disc_cache.jsonl"
    for f in (cache, LOG):
        if os.path.exists(f):
            os.remove(f)

    env = dict(os.environ)
    env["PATH"] = ";".join([r"C:\msys64\clang64\bin", ROOT + r"\build\nanum_ai_cpu", env["PATH"]])
    env["NANUM_AI_DEBUG"] = "1"
    args = [MPV, "--no-config", "--idle=yes", "--vo=null", "--ao=null", "--slang=kor",
            "--bluray-device=E:", f"--start={start}",
            f"--demuxer-readahead-secs={readahead}", "--demuxer-max-bytes=1500MiB",
            "--nanum",
            f"--nanum-ai-dll={ROOT}\\build\\nanum_ai_cpu\\nanum_ai_cpu.dll",
            f"--nanum-stt-model={ROOT}\\models\\ggml-small.en.bin",
            f"--nanum-vad-model={ROOT}\\models\\ggml-silero-v5.1.2.bin",
            f"--nanum-cache={cache}", f"--nanum-translate-model={model}",
            f"--input-ipc-server={PIPE}", f"--log-file={LOG}", "--msg-level=all=v"]
    err = open(ERR, "wb")
    t_launch = time.time()
    p = subprocess.Popen(args, env=env, stdout=subprocess.DEVNULL, stderr=err)
    ipc = Ipc()
    samples = []        # (seconds since launch, playback position)
    shown = []          # (position, sub-text) sampled while playing
    ok = True
    try:
        ipc.connect()
        ipc.cmd("loadfile", "bd://longest")
        end = time.time() + 180
        while time.time() < end and not ipc.prop("duration"):
            time.sleep(0.3)
        print(f"loaded after {time.time() - t_launch:.1f}s; sub tracks:",
              [(t['id'], t.get('title')) for t in ipc.prop('track-list') if t['type'] == 'sub'])

        t_play = time.time()
        next_probe = t_play + 20
        while time.time() - t_play < play_s:
            pos = ipc.prop("time-pos")
            if pos is not None:
                samples.append((time.time() - t_launch, pos))
            if time.time() >= next_probe:
                next_probe += 6
                txt = ipc.prop("sub-text")
                if txt:
                    shown.append((pos, txt))
            time.sleep(0.4)
        print(f"after {play_s:.0f}s: playback at {samples[-1][1]:.1f}s, "
              f"demuxer-cache-time={ipc.prop('demuxer-cache-time')}")
    finally:
        t_quit = time.time()
        try:
            ipc.cmd("quit")
        except Exception:
            pass
        try:
            p.wait(timeout=30)
            print(f"mpv exited {time.time() - t_quit:.1f}s after quit (code {p.returncode})")
        except Exception:
            p.kill()
            print("WARN: mpv did not exit within 30 s")
            ok = False
        err.close()

    evs = []
    for line in open(LOG, encoding="utf-8", errors="replace"):
        m = EVENT_RE.match(line)
        if m:
            evs.append((float(m.group(1)), float(m.group(2)), m.group(4), m.group(5).strip()))
    ntr = sum("(no translation)" not in e[3] for e in evs)
    print(f"events: {len(evs)}, translated: {ntr}")
    ok &= len(evs) > 0 and ntr >= 0.9 * len(evs)

    def pos_at(log_t):
        return min(samples, key=lambda s: abs(s[0] - log_t))[1]

    leads = [(pts, pts - pos_at(log_t)) for log_t, pts, _, _ in evs]
    steady = [l for pts, l in leads if pts > start + 60]
    print("first events (pts, lead):", [(round(a, 1), round(b, 1)) for a, b in leads[:6]])
    if steady:
        ahead = sum(l > 0 for l in steady)
        print(f"steady state (>60 s into playback): {len(steady)} events, "
              f"{ahead} ahead of playback ({100 * ahead / len(steady):.0f}%), "
              f"median lead {statistics.median(steady):.1f}s, min {min(steady):.1f}s")
        ok &= ahead / len(steady) >= 0.8
    else:
        print("no steady-state events")
        ok = False
    print("live sub-text samples while playing:")
    for pos, txt in shown:
        print(f"  t={pos:7.1f}  {txt!r}"[:220])
    ok &= any(re.search(r"[가-힣]", t) for _, t in shown)
    errs = open(ERR, encoding="utf-8", errors="replace").read().splitlines()
    tr_lines = [l for l in errs if l.startswith("tr:")]
    print(f"translator batches: {len(tr_lines)}; failures: "
          f"{sum('ok' not in l for l in tr_lines)}")
    for l in tr_lines[:4]:
        print("  ", l)
    print("RESULT:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
