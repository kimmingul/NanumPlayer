"""Fetch the pinned, independent Windows disc libraries and corresponding source.

Usage: python tools/prepare_disc.py [destination]
Default destination: third_party/disc (generated; never contains MakeMKV).
The disc key database is NOT bundled here; the player obtains it over HTTPS.
"""
import hashlib
import io
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parent.parent
RELEASE = "0.12.0-0.2.0-20260715"
ARCHIVE_URL = ("https://github.com/KnugiHK/libaacs-libbdplus-windows/releases/download/"
               + RELEASE + "/libaacs_libbdplus.zip")
ARCHIVE_SHA = "99d5711aa8a221ecefdaa0158845a5ef5f4bf2d167d33b8f1bc9991328a71401"
BINARIES = {
    "libaacs.dll": "f701f19cbc9828573f65f0b9392d25a593ab6b9b30cce5b1a32b89d29cadb816",
    "libbdplus.dll": "eb828111783cb4d03c2adcccc1b50f07a860e74b43591c4689d3e50b5e6579ef",
}
DVD_BINARIES = {
    "libdvdcss-2.dll": "217492d7fa478a93ad4d4ddcf34b1dff9be6f3cf59b229de968722026b3504ae",
    "libdvdread-8.dll": "306c1fa5a60a09b1a15a0aa94ab5e29db88981ad77b5f8e93077fcc4ec1fb534",
    "libdvdnav-4.dll": "2f1b18d790b9a103a694cc0472e9dd97d2a3bd78272697ea544ec851b3db3274",
}
SOURCES = {
    "libbluray-1.5.0.tar.xz": (
        "https://download.videolan.org/pub/videolan/libbluray/1.5.0/libbluray-1.5.0.tar.xz",
        "f676408e91a5d321abf8b8d4dfdae36205c297dab5c54c3ec519639025f474a2"),
    "libaacs-0.12.0.tar.bz2": (
        "https://code.videolan.org/videolan/libaacs/-/archive/0.12.0/libaacs-0.12.0.tar.bz2",
        "25394f08b37ce944172ef7d67208864b079fa3594ede22b51028766a2fa88b6c"),
    "libbdplus-0.2.0.tar.bz2": (
        "https://code.videolan.org/videolan/libbdplus/-/archive/0.2.0/libbdplus-0.2.0.tar.bz2",
        "b2018f72ea07465a227f625b4d68ad1c8e7498b812a5e46f17d9f039cc948f9e"),
    "libgcrypt-1.12.2.tar.gz": (
        "https://github.com/gpg/libgcrypt/archive/refs/tags/libgcrypt-1.12.2.tar.gz",
        "3506339b02adb6148fa2365a4e748f3d30fcc351b8c443897cd0d6fbcd4cfaf8"),
    "libgpg-error-1.61.tar.gz": (
        "https://github.com/gpg/libgpg-error/archive/refs/tags/libgpg-error-1.61.tar.gz",
        "d856f3582d31fd754afe876abf6f269e4f2f4e75c7ca2047971fb6e9b1d6e552"),
    "Makefile": (
        "https://raw.githubusercontent.com/KnugiHK/libaacs-libbdplus-windows/" + RELEASE + "/Makefile",
        "b2d337ff502b56d13642d1917b52c496093acb515b91be9d71284329a922bdca"),
    "mingw-w64-libdvdcss-1.6.0-1.src.tar.zst": (
        "https://mirror.msys2.org/mingw/sources/mingw-w64-libdvdcss-1.6.0-1.src.tar.zst",
        "cc180aa06504341ebda02d64aae90cc9b9d8bcea60d003dbef2d1a61fe0e96ab"),
    "mingw-w64-libdvdread-7.1.1-1.src.tar.zst": (
        "https://mirror.msys2.org/mingw/sources/mingw-w64-libdvdread-7.1.1-1.src.tar.zst",
        "f5928433f1572f2996bf7f2fe49b2ce4148c603e6e9672919c811fcfe8e359cb"),
    "mingw-w64-libdvdnav-7.0.0-2.src.tar.zst": (
        "https://mirror.msys2.org/mingw/sources/mingw-w64-libdvdnav-7.0.0-2.src.tar.zst",
        "961e34401d8e33593cee3eaf4c6c7745f4767e9a170f73a6bec64ee5554c1ebd"),
}


def verified(path, digest):
    if not path.exists():
        return False
    checksum = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            checksum.update(chunk)
    actual = checksum.hexdigest()
    if actual != digest:
        raise ValueError(f"Refusing modified disc dependency: {path} ({actual})")
    return True


def fetch(url, digest):
    with urllib.request.urlopen(url, timeout=90) as response:
        if not response.url.startswith("https://"):
            raise ValueError("Disc dependency download redirected away from HTTPS")
        data = response.read(32 * 1024 * 1024 + 1)
    if len(data) > 32 * 1024 * 1024 or hashlib.sha256(data).hexdigest() != digest:
        raise ValueError(f"Disc dependency size/SHA-256 mismatch: {url}")
    return data


def publish(path, data, digest):
    if hashlib.sha256(data).hexdigest() != digest:
        raise ValueError(f"Disc dependency SHA-256 mismatch: {path.name}")
    if verified(path, digest):
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=path.parent, prefix=path.name + ".", delete=False) as f:
            temporary = Path(f.name)
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.replace(temporary, path)
        temporary = None
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def build_bluray(destination):
    """Build the public ABI with console-backed decryption fallbacks removed."""
    clang = Path("C:/msys64/clang64/bin")
    patch_program = shutil.which("patch") or "C:/Program Files/Git/usr/bin/patch.exe"
    patch = Path(__file__).with_name("disc-libbluray.patch")
    env = dict(os.environ, PATH=str(clang) + os.pathsep + os.environ.get("PATH", ""),
               CC="clang", CXX="clang++")
    with tempfile.TemporaryDirectory(prefix="nanum-libbluray-") as temporary:
        work = Path(temporary)
        with tarfile.open(destination / "sources" / "libbluray-1.5.0.tar.xz") as archive:
            members = archive.getmembers()
            for member in members:
                parts = Path(member.name).parts
                if (not (member.isfile() or member.isdir()) or not parts or
                        parts[0] != "libbluray-1.5.0" or ".." in parts):
                    raise ValueError("Unexpected libbluray source archive member")
            archive.extractall(work, members=members)
        source = work / "libbluray-1.5.0"
        subprocess.run([patch_program, "--batch", "--forward", "--fuzz=0", "-p1",
                        "--input=" + patch.as_posix()], cwd=source, check=True)
        build = work / "build"
        meson = str(clang / "meson.exe")
        subprocess.run([meson, "setup", str(build), str(source),
                        "--buildtype=release", "--default-library=shared",
                        "--wrap-mode=nodownload", "-Dbdj_jar=disabled",
                        "-Denable_examples=false", "-Dlibxml2=enabled",
                        "-Dfreetype=enabled"], env=env, check=True)
        subprocess.run([meson, "compile", "-C", str(build)], env=env, check=True)
        libraries = list(build.rglob("libbluray-4.dll"))
        if len(libraries) != 1:
            raise ValueError("The independent libbluray build did not produce exactly one DLL")
        shutil.copy2(libraries[0], destination / "libbluray-4.dll")
    # Corresponding source + exact modification + executable build recipe.
    for source_file in (patch, Path(__file__)):
        target = destination / "sources" / source_file.name
        if target.resolve() != source_file.resolve():
            shutil.copy2(source_file, target)


def prepare_disc(destination):
    destination = Path(destination)
    missing = [name for name, digest in BINARIES.items()
               if not verified(destination / name, digest)]
    build_license = destination / "BUILD-LICENSE"
    build_license_sha = "3972dc9744f6499f0f9b2dbf76696f2ae7ad8af9b23dde66d6af86c9dfb36986"
    if missing or not verified(build_license, build_license_sha):
        archive = zipfile.ZipFile(io.BytesIO(fetch(ARCHIVE_URL, ARCHIVE_SHA)))
        with archive:
            for name in missing:
                publish(destination / name, archive.read("winx64/" + name), BINARIES[name])
            publish(build_license, archive.read("LICENSE"), build_license_sha)
    for name, (url, digest) in SOURCES.items():
        path = destination / "sources" / name
        if not verified(path, digest):
            publish(path, fetch(url, digest), digest)
        if name == "Makefile" or name.endswith(".src.tar.zst"):
            continue
        # Preserve the libraries' own licenses as well as the build recipe's.
        # Never unpack arbitrary archive paths into the installation.
        with tarfile.open(path) as archive:
            for entry in archive.getmembers():
                if entry.isfile() and entry.name.count("/") == 1 and entry.name.rsplit("/", 1)[1] in ("COPYING", "COPYING.LIB"):
                    data = archive.extractfile(entry).read()
                    label = name.split("-", 1)[0] + "-" + entry.name.rsplit("/", 1)[1]
                    # libgpg-error has a hyphen in its name.
                    if name.startswith("libgpg-error-"):
                        label = "libgpg-error-" + entry.name.rsplit("/", 1)[1]
                    publish(destination / label, data, hashlib.sha256(data).hexdigest())
    build_bluray(destination)
    return destination


if __name__ == "__main__":
    folder = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "third_party" / "disc"
    print("Independent disc dependencies:", prepare_disc(folder))
