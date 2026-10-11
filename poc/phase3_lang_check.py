"""Phase 3 check on the real disc (with scripts/nanum.lua loaded):

  1. Pre-roll: playback must not start moving before AI subtitles are ready,
     and the first lines must reach mpv before they are due.
  2. Language routing: Japanese audio -> Japanese text -> Korean.
  3. Changing the listening audio must retain the pinned Japanese AI input
     unless the user explicitly chooses regeneration.
"""
import json
import os
import re
import statistics
import subprocess
import sys
import time

ROOT = r"D:\repo\NanumPlayer"
MPV = ROOT + r"\third_party\mpv\build\NanumPlayer.exe"
PIPE = r"\\.\pipe\nanum_phase3_lang"
LOG = ROOT + r"\cache\phase3_lang.log"
EVENT_RE = re.compile(r"^\[\s*([\d.]+)\].*nanum\] event ([\d.]+) \+([\d.]+): (.*?) \| (.*)$")


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


has_ja = lambda s: re.search(r"[\u3040-\u30ff\u4e00-\u9fff]", s) is not None
has_ko = lambda s: re.search(r"[\uac00-\ud7a3]", s) is not None


def main():
    start = float(sys.argv[1]) if len(sys.argv) > 1 else 300.0
    ja_s = float(sys.argv[2]) if len(sys.argv) > 2 else 60.0
    after_s = float(sys.argv[3]) if len(sys.argv) > 3 else 80.0
    for f in (LOG, ROOT + r"\cache\p3_cache.jsonl"):
        if os.path.exists(f):
            os.remove(f)
    env = dict(os.environ)
    env["PATH"] = ";".join([r"C:\msys64\clang64\bin", ROOT + r"\build\nanum_ai_cpu", env["PATH"]])
    env["NANUM_AI_DEBUG"] = "1"
    args = [MPV, "--no-config", "--idle=yes", "--vo=null", "--ao=null", "--slang=kor",
            "--aid=3", "--bluray-device=E:", f"--start={start}",
            f"--script={ROOT}\\scripts\\nanum.lua", "--script-opts=nanum-preroll=25",
            "--demuxer-readahead-secs=90", "--demuxer-max-bytes=1200MiB", "--nanum",
            f"--nanum-ai-dll={ROOT}\\build\\nanum_ai_cpu\\nanum_ai_cpu.dll",
            f"--nanum-stt-model={ROOT}\\models\\ggml-small.en.bin",
            f"--nanum-stt-model-multilingual={ROOT}\\models\\ggml-small.bin",
            f"--nanum-vad-model={ROOT}\\models\\ggml-silero-v5.1.2.bin",
            f"--nanum-cache={ROOT}\\cache\\p3_cache.jsonl",
            "--nanum-translate-model=nemotron-3-super:cloud",
            f"--input-ipc-server={PIPE}", f"--log-file={LOG}", "--msg-level=all=v"]
    p = subprocess.Popen(args, env=env, stdout=subprocess.DEVNULL,
                         stderr=open(ROOT + r"\cache\phase3_lang.err", "wb"))
    ipc = Ipc()
    t0 = time.time()
    samples = []                    # (seconds since launch, time-pos, paused)
    switch = {}
    try:
        ipc.connect()
        ipc.cmd("loadfile", "bd://longest")
        while time.time() - t0 < 180 and not ipc.prop("duration"):
            time.sleep(0.3)
        t_loaded = time.time() - t0
        print(f"loaded at +{t_loaded:.1f}s; aid={ipc.prop('aid')}, sid={ipc.prop('sid')}")

        def sample_for(seconds):
            end = time.time() + seconds
            while time.time() < end:
                samples.append((time.time() - t0, ipc.prop("time-pos"), ipc.prop("pause")))
                time.sleep(0.4)

        sample_for(ja_s)
        switch["pos"] = ipc.prop("time-pos")
        switch["t"] = time.time() - t0
        switch["pin"] = ipc.prop("options/nanum-audio-id")
        print(f"switching to aid=1 at playback {switch['pos']:.1f}s")
        ipc.cmd("set_property", "aid", 1)
        sample_for(after_s)
        print("aid now:", ipc.prop("aid"))
        switch["pin_after"] = ipc.prop("options/nanum-audio-id")
    finally:
        try:
            ipc.cmd("quit")
        except Exception:
            pass
        try:
            p.wait(timeout=30)
            print("mpv exit code", hex(p.returncode & 0xffffffff))
        except Exception:
            p.kill()
            print("WARN: mpv did not exit")

    evs = []
    for line in open(LOG, encoding="utf-8", errors="replace"):
        m = EVENT_RE.match(line)
        if m:
            evs.append((float(m.group(1)), float(m.group(2)), m.group(4), m.group(5).strip()))
    pos_at = lambda t: min(samples, key=lambda s: abs(s[0] - t))[1] or 0.0

    # 1. pre-roll
    moved = next((s[0] for s in samples if s[1] is not None and s[1] > start + 0.5 and not s[2]), None)
    first = evs[0] if evs else None
    print(f"playback began moving at +{moved:.1f}s (loaded at +{t_loaded:.1f}s): pre-roll {moved - t_loaded:.1f}s" if moved else "playback never moved")
    ok = moved is not None and moved - t_loaded >= 3
    ja_phase = [e for e in evs if e[0] < switch["t"]]
    leads = [e[1] - pos_at(e[0]) for e in ja_phase if e[1] > start + 5]
    print(f"JA phase: {len(ja_phase)} events, lead median {statistics.median(leads):.1f}s, min {min(leads):.1f}s" if leads else "no JA events")
    ok &= bool(leads) and sum(l > 0 for l in leads) >= 0.8 * len(leads)

    # 2. routing
    ja = [e for e in ja_phase if has_ja(e[2])]
    print(f"Japanese source lines: {len(ja)}/{len(ja_phase)}; all translated: {all(has_ko(e[3]) for e in ja)}")
    for e in ja[:3]:
        print(f"   {e[1]:7.1f}  {e[2][:30]}  =>  {e[3][:30]}")
    ok &= len(ja) >= 3 and all(has_ko(e[3]) for e in ja)

    # 3. Playback audio changes independently of the pinned AI source.
    print(f"AI input stayed pinned: {switch['pin']} -> {switch['pin_after']}")
    ok &= switch["pin"] == switch["pin_after"]
    later_ja = [e for e in evs if e[0] >= switch["t"] and has_ja(e[2])]
    print(f"Japanese lines after the listening-audio switch: {len(later_ja)}")
    ok &= bool(later_ja) and all(has_ko(e[3]) for e in later_ja)
    print("RESULT:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
