"""Starts mpv with the AI engine on a local file, lets it run a few seconds,
quits via IPC and reports how it exited. Usage: exit_check.py [runs] [env=VAL ...]"""
import json
import os
import subprocess
import sys
import time

ROOT = r"D:\repo\NanumPlayer"
MPV = ROOT + r"\third_party\mpv\build\NanumPlayer.exe"
PIPE = r"\\.\pipe\nanum_exit"


def run_once(media, env, extra_args, wait_s):
    args = [MPV, "--no-config", "--idle=yes", "--vo=null", "--ao=null", "--slang=kor",
            "--demuxer-readahead-secs=600", "--demuxer-max-bytes=1GiB", "--nanum",
            f"--nanum-ai-dll={ROOT}\\build\\nanum_ai_cpu\\nanum_ai_cpu.dll",
            f"--nanum-stt-model={ROOT}\\models\\ggml-small.en.bin",
            f"--nanum-vad-model={ROOT}\\models\\ggml-silero-v5.1.2.bin",
            f"--nanum-cache={ROOT}\\cache\\exit_cache.jsonl",
            "--nanum-translate-model=nemotron-3-super:cloud",
            f"--input-ipc-server={PIPE}", f"--log-file={ROOT}\\cache\\exit.log", "--msg-level=all=v"] + extra_args
    p = subprocess.Popen(args, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    f = None
    for _ in range(100):
        try:
            f = open(PIPE, "r+b", buffering=0)
            break
        except OSError:
            time.sleep(0.1)

    def cmd(*a):
        f.write((json.dumps({"command": list(a)}) + "\n").encode())
        return f.readline()

    cmd("loadfile", media)
    time.sleep(wait_s)
    t = time.time()
    try:
        cmd("quit")
    except OSError:
        pass
    try:
        p.wait(timeout=60)
    except subprocess.TimeoutExpired:
        p.kill()
        return "HANG (killed after 60 s)"
    return f"exit code {p.returncode & 0xffffffff:#x} after {time.time() - t:.1f}s"


def main():
    runs = int(sys.argv[1]) if len(sys.argv) > 1 else 3
    env = dict(os.environ)
    env["PATH"] = ";".join([r"C:\msys64\clang64\bin", ROOT + r"\build\nanum_ai_cpu", env["PATH"]])
    for kv in sys.argv[2:]:
        k, _, v = kv.partition("=")
        env[k] = v
    for i in range(runs):
        print(f"run {i + 1}:", run_once(ROOT + r"\cache\disc_audio.mka", env, [], 12))


if __name__ == "__main__":
    main()
