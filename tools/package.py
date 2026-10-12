"""Builds dist/NanumPlayer-<version> and dist/NanumPlayer-Setup-<version>.exe.

Prerequisites: built mpv (third_party/mpv/build), CPU engine (tools/build_nanum_ai.bat cpu),
MSYS2 CLANG64 (DLL dependency closure), Inno Setup 6 (installer).
Usage: python tools/package.py [version] [--no-installer] [--sign <certificate SHA-1 thumbprint>]
The version is NANUM_VERSION in third_party/mpv/osdep/nanum-version.h; a given [version] must equal it.
--sign signs NanumPlayer's own binaries in the stage, the installer and its uninstaller
(Windows SDK signtool, SHA-256, RFC 3161 timestamp). Third-party DLLs keep their own state.
"""
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CLANG = r"C:\msys64\clang64\bin"
MPV_DIR = os.path.join(ROOT, "third_party", "mpv", "build")
VC_REDIST = r"C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Redist\MSVC\14.44.35112\x64"
ISCC = os.path.join(os.environ.get("LOCALAPPDATA", ""), "Programs", "Inno Setup 6", "ISCC.exe")
SIGNTOOL = r"C:\Program Files (x86)\Windows Kits\10\bin\10.0.26100.0\x64\signtool.exe"
TIMESTAMP = "http://timestamp.digicert.com"
OWN_BINARIES = ("NanumPlayer.exe", "nanum_youtube.exe", "nanum_ai_cpu.dll")
thumbprint = sys.argv[sys.argv.index("--sign") + 1] if "--sign" in sys.argv else None


def sign_command(thumb):
    return [SIGNTOOL, "sign", "/sha1", thumb, "/fd", "sha256", "/tr", TIMESTAMP, "/td", "sha256"]


# MakeMKV's libmmbd (renamed to libaacs/libbdplus) is the user's own; never ship it.
NEVER_SHIP = {"libaacs.dll", "libbdplus.dll"}


def header_version():
    """The release version in third_party/mpv/osdep/nanum-version.h (what NanumPlayer.exe reports)."""
    with open(os.path.join(ROOT, "third_party", "mpv", "osdep", "nanum-version.h"), encoding="utf-8") as f:
        text = f.read()
    parts = [re.search(rf"#define NANUM_VERSION_{n} (\d+)", text) for n in ("MAJOR", "MINOR", "PATCH")]
    string = re.search(r'#define NANUM_VERSION "([^"]+)"', text)
    if not string or not all(parts) or string.group(1) != ".".join(p.group(1) for p in parts):
        sys.exit("nanum-version.h: NANUM_VERSION does not match NANUM_VERSION_MAJOR/MINOR/PATCH")
    return string.group(1)


version = header_version()
given = [a for i, a in enumerate(sys.argv[1:], 1)
         if not a.startswith("--") and sys.argv[i - 1] != "--sign"]
if given and given[0] != version:
    sys.exit(f"version {given[0]} differs from NANUM_VERSION {version} in nanum-version.h "
             "(the built NanumPlayer.exe reports the latter; change the header and rebuild)")
stage = os.path.join(ROOT, "dist", f"NanumPlayer-{version}")


def deps(path):
    out = subprocess.run([os.path.join(CLANG, "objdump.exe"), "-p", path],
                         capture_output=True, text=True, errors="replace").stdout
    return set(re.findall(r"DLL Name: (\S+)", out))


def closure(exe):
    found, todo, seen = {}, [exe], set()
    while todo:
        for d in deps(todo.pop()):
            k = d.lower()
            if k in seen or k in NEVER_SHIP:
                continue
            seen.add(k)
            path = os.path.join(CLANG, d)
            if os.path.exists(path):         # system / api-ms DLLs are not found here
                found[d] = path
                todo.append(path)
    return found


def copy(src, dst_dir):
    os.makedirs(dst_dir, exist_ok=True)
    shutil.copy2(src, dst_dir)


def write_catalogue(path, prefix, entries):
    fields = (("ID", "id", "String"), ("Filename", "filename", "String"),
              ("Hash", "sha256", "String"), ("URL", "url", "String"),
              ("Size", "size", "Int64"))
    with open(path, "w", encoding="utf-8-sig") as f:
        f.write(f"#define {prefix}Count {len(entries)}\n")
        for suffix, field, kind in fields:
            f.write(f"function {prefix}{suffix}(Index: Integer): {kind};\nbegin\n  case Index of\n")
            for i, entry in enumerate(entries):
                value = str(entry[field])
                if kind == "String":
                    value = "'" + value.replace("'", "''") + "'"
                f.write(f"    {i}: Result := {value};\n")
            fallback = "''" if kind == "String" else "0"
            f.write(f"  else Result := {fallback};\n  end;\nend;\n\n")


with open(os.path.join(ROOT, "components", "catalog.json"), encoding="utf-8") as f:
    component_catalogue = json.load(f)


# Never remove a distribution the user may currently be running.
if os.path.exists(stage):
    raise SystemExit(f"Output already exists: {stage}. Choose a new version or move it aside.")
# The native player is the executable itself. Keep runtime DLLs next to it for
# Windows' safe loader; there is no launcher or nested mpv.exe.
bindir = stage
os.makedirs(bindir)

player = os.path.join(MPV_DIR, "NanumPlayer.exe")
copy(player, bindir)
libs = closure(player)
for p in libs.values():
    copy(p, bindir)
print(f"NanumPlayer.exe + {len(libs)} DLLs")

# YouTube browser helper (tools/build_youtube.bat): chooses/logs in, the player plays.
youtube_helper = os.path.join(ROOT, "build", "youtube", "nanum_youtube.exe")
if not os.path.isfile(youtube_helper):
    raise SystemExit(f"Missing {youtube_helper}; run tools\\build_youtube.bat first.")
copy(youtube_helper, bindir)

ai_dll = os.path.join(ROOT, "build", "nanum_ai_cpu", "nanum_ai_cpu.dll")
copy(ai_dll, bindir)
for p in closure(ai_dll).values():
    copy(p, bindir)
# The CUDA engine is an optional verified download (components/catalog.json pins the file that is
# uploaded to the release). It is not shipped; refuse to package a catalog that does not describe
# the engine that was built and signed.
cuda_dll = os.path.join(ROOT, "build", "nanum_ai_cuda", "nanum_ai_cuda.dll")
engine_pin = next(c for c in component_catalogue["components"] if c["id"] == "cuda_engine")
with open(cuda_dll, "rb") as f:
    engine_bytes = f.read()
if len(engine_bytes) != engine_pin["size"] or hashlib.sha256(engine_bytes).hexdigest() != engine_pin["sha256"]:
    raise SystemExit(f"components/catalog.json does not match {cuda_dll} (size/SHA-256); "
                     "pin the signed engine that is uploaded to the release.")
for sub, n in (("Microsoft.VC143.CRT", "msvcp140.dll"), ("Microsoft.VC143.CRT", "vcruntime140.dll"),
               ("Microsoft.VC143.CRT", "vcruntime140_1.dll"), ("Microsoft.VC143.OpenMP", "vcomp140.dll")):
    copy(os.path.join(VC_REDIST, sub, n), bindir)

for script in ("nanum.lua", "nanum-fluent.lua", "fluent-input.lua"):
    copy(os.path.join(ROOT, "scripts", script), os.path.join(stage, "scripts"))
copy(os.path.join(ROOT, "models", "catalog.json"), os.path.join(stage, "models"))
copy(os.path.join(ROOT, "components", "catalog.json"), os.path.join(stage, "components"))
copy(os.path.join(ROOT, "components", "LICENSE-NVIDIA-CUDA.txt"), stage)
copy(os.path.join(ROOT, "third_party", "whisper.cpp", "LICENSE"), stage)
copy(os.path.join(ROOT, "third_party", "mpv", "LICENSE.GPL"), stage)


with open(os.path.join(stage, "README.txt"), "w", encoding="utf-8") as f:
    f.write(open(os.path.join(ROOT, "tools", "dist_readme.txt"), encoding="utf-8").read())

# Upgrade removes only known files from our old nested runtime layout. Never
# delete a user's libaacs/libbdplus or settings/models/library.
cleanup = os.path.join(ROOT, "dist", f"NanumPlayer-{version}-cleanup.iss")
obsolete = {"mpv.exe", "mpv.com", "libmpv-2.dll"}
obsolete.update(name for name in os.listdir(stage) if name.lower().endswith(".dll"))
with open(cleanup, "w", encoding="utf-8") as f:
    for name in sorted(obsolete):
        if name.lower() not in NEVER_SHIP:
            f.write(f'Type: files; Name: "{{app}}\\bin\\{name}"\n')
    for name in ("nanum_ai.dll", "nanum_ai_cuda.dll", "cublas64_13.dll",
                 "cublasLt64_13.dll", "mpv.exe", "mpv.com", "libmpv-2.dll"):
        f.write(f'Type: files; Name: "{{app}}\\{name}"\n')

# Native player and installer use the same pinned catalogue.
with open(os.path.join(ROOT, "models", "catalog.json"), encoding="utf-8") as f:
    catalogue = json.load(f)["models"]
catalogue_code = os.path.join(ROOT, "dist", f"NanumPlayer-{version}-models.iss")
write_catalogue(catalogue_code, "Model", catalogue)

component_code = os.path.join(ROOT, "dist", f"NanumPlayer-{version}-components.iss")
write_catalogue(component_code, "Component", component_catalogue["components"])

if thumbprint:
    subprocess.run(sign_command(thumbprint) + [os.path.join(stage, n) for n in OWN_BINARIES], check=True)
    subprocess.run([SIGNTOOL, "verify", "/pa"] + [os.path.join(stage, n) for n in OWN_BINARIES], check=True)

if "--no-installer" not in sys.argv:
    iscc = [ISCC, f"/DAppVersion={version}", f"/DStageDir={stage}", f"/DCleanupFile={cleanup}",
            f"/DModelCatalogFile={catalogue_code}", f"/DComponentCatalogFile={component_code}",
            f"/DCudaMajor={component_catalogue['cuda_major']}"]
    if thumbprint:
        # Inno Setup signs Setup.exe and the uninstaller with this tool ($f = file, $q = quote).
        tool = " ".join(["$q" + SIGNTOOL + "$q"] + sign_command(thumbprint)[1:])
        iscc += ["/DSign", f"/Snanumsign={tool} $f"]
    subprocess.run(iscc + [os.path.join(ROOT, "tools", "installer.iss")], check=True)
    print("installer:", os.path.join(ROOT, "dist", f"NanumPlayer-Setup-{version}.exe"))
