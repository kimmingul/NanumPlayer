# Optional Blu-ray/DVD decryption components

English · [한국어](ko/disc-components.md)

> **Legal notice.** Circumventing copy protection is restricted or prohibited by law in many countries
> (for example Article 6 of the EU Copyright Directive 2001/29/EC and section 1201 of the US Digital
> Millennium Copyright Act, and similar laws elsewhere), in some places even for a copy of a disc you own.
> The NanumPlayer project does not give legal advice and cannot decide what is lawful for you. **You are
> responsible for complying with the laws that apply to you.** Install and use the component below only
> with discs you own or may lawfully use, and do not distribute copyrighted material.

## What it is, and what it is not

NanumPlayer plays Blu-ray and DVD in the player process. The libraries that read the discs' structure
(libbluray, libdvdread, libdvdnav) are part of the normal download, so **unencrypted discs, disc folders
and disc images play with no extra component**.

The libraries that remove copy protection are **not part of the default download** (not in the installer
and not in the portable ZIP). They are an optional component that you download and install separately,
on request:

| Library | Protection | License |
|---|---|---|
| libaacs (with libgcrypt and libgpg-error) | AACS (Blu-ray) | LGPL-2.1-or-later |
| libbdplus (with libgcrypt and libgpg-error) | BD+ (Blu-ray) | LGPL-2.1-or-later |
| libdvdcss | CSS (DVD) | GPL-2.0-or-later |

They are third-party software written by other projects, not by NanumPlayer. The component ZIP also
contains their license texts, the corresponding source code and build recipe, and a README that repeats the
legal notice above.

NanumPlayer does not use MakeMKV: no MakeMKV program, library, key or evaluation period is involved. The
component does not give equivalent support to other tools: a disc whose keys are not in the public key
database, a disc whose BD+ virtual-machine data is missing, an unsupported AACS version and a failing drive
authentication still end with an explicit error. Nothing is claimed about UHD discs or LibreDrive features.

## How you get it

The component is one ZIP asset, `NanumPlayer-disc-components-<version>.zip`, published as a release of
the repository `kimmingul/NanumPlayer-disc-components`. NanumPlayer accepts **only the exact ZIP its own
version pins** (size and SHA-256 in `components/catalog.json`), over HTTPS, and checks every file in it
again before it is loaded. There are four ways to install it:

1. **First use.** Open an encrypted disc. NanumPlayer explains that the component is optional and that you are
   responsible for the law, and offers to download and install it. Nothing is downloaded unless you agree.
2. **Menu.** Choose **Ctrl+N → Blu-ray/DVD decryption components** at any time.
3. **Installer.** The setup has an optional task for it that is **unchecked** by default.
4. **From a file.** If you downloaded the ZIP yourself (or are offline), install that copy from the same
   menu. It must be the unchanged ZIP that your NanumPlayer version pins.

Downloads show progress and can be cancelled; a failed or cancelled download leaves nothing half-installed.

Files are installed to `%LOCALAPPDATA%\NanumPlayer\components\disc\<version>`. **To remove the component, delete
that folder.** Uninstalling NanumPlayer keeps it, like the other downloaded components.

## The AACS key database

An AACS-protected Blu-ray also needs keys. NanumPlayer downloads the public FindVUK key database
(`fvonline-db.bplaced.net`, about 25 MB, about 65 MB when unpacked) **only after** the component is
installed **and** you have agreed. The install prompt tells you that installing counts as that agreement; it is remembered, and you can switch the automatic key database download off or on again in **Ctrl+N → Blu-ray/DVD decryption components**.
The ZIP structure, size and CRC are checked, and the file is replaced atomically as `KEYDB.cfg` in
`%APPDATA%\NanumPlayer\disc`. A working cache needs no network; a failed download keeps the old cache; a
database under one hour old is not downloaded again, and a disc that the fresh database does not open is
reported instead. The database is a third-party resource that the NanumPlayer project does not host or
control.

## If you upgrade from an older version

Earlier releases (up to 1.12.0) shipped these libraries in the application folder. The installer of a newer
version removes exactly those known files. If you play encrypted discs, NanumPlayer tells you how to install
the component; your settings, models and keys are not touched.

## Saving discs to MKV

**Ctrl+B** (see the [user guide](user-guide.md#discs)) uses the same libraries. For a protected disc it needs the
component too.

## For packagers

`python tools/package.py` never puts the decryption libraries into the stage, the installer or the portable
ZIP (it fails if it finds one) and builds `dist/NanumPlayer-disc-components-<version>.zip` separately. With
`--pin-disc-components` it writes that ZIP's size, SHA-256, file list and download URL into
`components/catalog.json`; without it, a mismatch stops the build. Upload exactly the pinned ZIP to the
component repository's release for the same version. See [building](building.md#packaging) and the
[third-party notices](../THIRD_PARTY_NOTICES.md).
