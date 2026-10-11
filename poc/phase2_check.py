"""Phase 2 acceptance check: real audio -> mpv demux tap -> decode -> nanum_ai
(STT + translation) -> 'ko (AI)' subtitle track.

Expectations are taken from the events nanum logs, then compared with what
mpv actually renders (sub-text) at those timestamps.
"""
import json
import os
import re
import subprocess
import sys
import time

ROOT = r"D:\repo\NanumPlayer"
MPV = ROOT + r"\third_party\mpv\build\NanumPlayer.exe"
PIPE = r"\\.\pipe\nanum_phase2"
LOG = ROOT + r"\cache\phase2.log"
EVENT_RE = re.compile(r"event ([\d.]+) \+([\d.]+): (.*?) \| (.*)$")


class Ipc:
    def __init__(self):
        self.f = None
        self.rid = 0

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
        self.rid += 1
        self.f.write((json.dumps({"command": list(args), "request_id": self.rid}) + "\n").encode())
        while True:
            d = json.loads(self.f.readline().decode())
            if d.get("request_id") == self.rid:
                return d

    def prop(self, name):
        return self.cmd("get_property", name).get("data")


def events_from_log():
    evs = []
    if not os.path.exists(LOG):
        return evs
    for line in open(LOG, encoding="utf-8", errors="replace"):
        m = EVENT_RE.search(line)
        if m:
            evs.append((float(m.group(1)), float(m.group(2)), m.group(3), m.group(4).strip()))
    return evs


def main():
    media = sys.argv[1]
    cache = ROOT + r"\cache\p2_cache.jsonl"
    if len(sys.argv) > 2 and sys.argv[2] == "fresh" and os.path.exists(cache):
        os.remove(cache)
    if os.path.exists(LOG):
        os.remove(LOG)

    env = dict(os.environ)
    env["PATH"] = ";".join([r"C:\msys64\clang64\bin", ROOT + r"\build\nanum_ai_cpu", env["PATH"]])
    args = [MPV, "--no-config", "--idle=yes", "--vo=null", "--ao=null", "--pause",
            "--slang=kor", "--hr-seek=yes", "--bluray-device=E:",
            "--demuxer-readahead-secs=600", "--demuxer-max-bytes=1GiB",
            "--nanum",
            f"--nanum-ai-dll={ROOT}\\build\\nanum_ai_cpu\\nanum_ai_cpu.dll",
            f"--nanum-stt-model={ROOT}\\models\\ggml-small.en.bin",
            f"--nanum-vad-model={ROOT}\\models\\ggml-silero-v5.1.2.bin",
            f"--nanum-cache={cache}",
            f"--input-ipc-server={PIPE}", f"--log-file={LOG}", "--msg-level=all=v"]
    p = subprocess.Popen(args, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    ok = True
    ipc = Ipc()
    try:
        ipc.connect()
        t0 = time.time()
        ipc.cmd("loadfile", media)
        end = time.time() + 120
        while time.time() < end and not ipc.prop("duration"):
            time.sleep(0.2)
        tracks = [t for t in (ipc.prop("track-list") or []) if t["type"] == "sub"]
        print("sub tracks:", [(t["id"], t.get("title"), t.get("selected")) for t in tracks])
        ai = [t for t in tracks if t.get("title") == "ko (AI)"]
        if not ai:
            print("FAIL: no ko (AI) track")
            return 1
        if not ai[0].get("selected"):
            ipc.cmd("set_property", "sid", ai[0]["id"])

        # Wait until events stop arriving.
        last_n, last_change = -1, time.time()
        while time.time() - t0 < 600:
            n = len(events_from_log())
            if n != last_n:
                last_n, last_change = n, time.time()
            elif n > 0 and time.time() - last_change > 25:
                break
            time.sleep(1.0)
        evs = events_from_log()
        print(f"events: {len(evs)} (first at +{last_change - t0:.0f}s ... settled)")
        ok &= len(evs) >= 5
        translated = [e for e in evs if "(no translation)" not in e[3]]
        print(f"translated: {len(translated)}/{len(evs)}")
        ok &= len(translated) >= max(1, int(len(evs) * 0.9))

        start = ipc.prop("demuxer-start-time") or 0.0
        print("demuxer-start-time =", start)
        step = max(1, len(translated) // 7)
        shown = 0
        for pts, dur, src, ko in translated[::step][:8]:
            ipc.cmd("seek", pts + 0.4 - start, "absolute", "exact")
            time.sleep(1.2)
            txt = ipc.prop("sub-text") or ""
            good = ko[:6] in txt and src[:8] in txt
            shown += good
            print(f"  {'OK  ' if good else 'FAIL'} t={pts:7.2f} sub-text={txt!r}")
            ok &= good
        print(f"rendered correctly: {shown}")
    finally:
        try:
            ipc.cmd("quit")
        except Exception:
            pass
        try:
            p.wait(timeout=30)
        except Exception:
            p.kill()
            print("WARN: mpv did not exit within 30 s")
    print("RESULT:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
