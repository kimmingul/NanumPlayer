"""Phase 1 acceptance check for the source-built mpv with the nanum demux bridge.

Checks: (1) 'ko (AI)' appears in track-list, (2) sub-text at given positions
matches the fixed test events, (3) text is still correct after seeking back
and forth, (4) tap log lines were emitted.

Test events live on the container's absolute timeline (one every 5 s, 3 s
long); mpv's time-pos is relative to demuxer-start-time.
"""
import json
import os
import subprocess
import sys
import time

MPV = r"D:\repo\NanumPlayer\third_party\mpv\build\NanumPlayer.exe"
PIPE = r"\\.\pipe\nanum_phase1"
LOG = r"D:\repo\NanumPlayer\cache\phase1.log"


class Ipc:
    def __init__(self):
        self.f = None
        self.rid = 0

    def connect(self, timeout=15):
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


def wait_for(fn, timeout=60):
    end = time.time() + timeout
    while time.time() < end:
        v = fn()
        if v:
            return v
        time.sleep(0.2)
    return None


def expected(abs_pos):
    k = int(abs_pos // 5)
    off = abs_pos - 5 * k
    return f"#{k} " if off < 3.0 else None


def main():
    media = sys.argv[1]
    positions = [float(x) for x in sys.argv[2:]] or [1.0, 6.0, 11.0]
    env = dict(os.environ, PATH=r"C:\msys64\clang64\bin;" + os.environ["PATH"])
    if os.path.exists(LOG):
        os.remove(LOG)
    args = [MPV, "--no-config", "--idle=yes", "--vo=null", "--ao=null", "--pause",
            "--nanum", "--nanum-test-subs", "--slang=kor", "--hr-seek=yes",
            "--bluray-device=E:", f"--input-ipc-server={PIPE}",
            f"--log-file={LOG}", "--msg-level=demux=v,all=warn"]
    p = subprocess.Popen(args, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    ok = True
    ipc = Ipc()
    try:
        ipc.connect()
        ipc.cmd("loadfile", media)
        if not wait_for(lambda: ipc.prop("duration"), 120):
            print("FAIL: file did not load")
            return 1

        tracks = ipc.prop("track-list") or []
        subs = [t for t in tracks if t["type"] == "sub"]
        print("sub tracks:", [(t["id"], t.get("title"), t.get("lang"), t.get("codec"), t.get("selected")) for t in subs])
        ai = [t for t in subs if t.get("title") == "ko (AI)"]
        print("1) 'ko (AI)' track present:", bool(ai))
        if not ai:
            return 1
        if not ai[0].get("selected"):
            ipc.cmd("set_property", "sid", ai[0]["id"])
        print("   sid =", ipc.prop("sid"))

        base = ipc.prop("time-pos") or 0.0
        start = ipc.prop("demuxer-start-time") or 0.0
        print("   time-pos =", base, " demuxer-start-time =", start)

        def check(pos, label):
            nonlocal ok
            ipc.cmd("seek", base + pos, "absolute", "exact")
            time.sleep(1.5)
            txt = wait_for(lambda: ipc.prop("sub-text"), 6) or ""
            exp = expected(start + base + pos)
            good = (exp in txt) if exp else (txt == "")
            want = f"contains {exp!r}" if exp else "empty"
            print(f"   {label} t=+{pos:6.1f}s abs={start + base + pos:8.2f} sub-text={txt!r} expect {want} -> {'OK' if good else 'FAIL'}")
            ok &= good

        print("2) display at positions (forward):")
        for pos in positions:
            check(pos, "fwd ")
        print("3) after seeking backwards:")
        for pos in reversed(positions):
            check(pos, "back")
    finally:
        try:
            ipc.cmd("quit")
        except Exception:
            pass
        try:
            p.wait(timeout=10)
        except Exception:
            p.kill()

    log = open(LOG, encoding="utf-8", errors="replace").read() if os.path.exists(LOG) else ""
    tap = [l for l in log.splitlines() if "nanum" in l]
    print("4) nanum log lines:", len(tap))
    for l in tap[:5]:
        print("  ", l[:150])
    ok &= any("tap:" in l for l in tap)
    print("RESULT:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
