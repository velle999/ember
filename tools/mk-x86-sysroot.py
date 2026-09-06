#!/usr/bin/env python3
"""
mk-x86_64-sysroot.py — build an x86_64 DEV sysroot out of Ubuntu amd64 debs.

FEX's thunk build cross-compiles the guest half of every thunk to x86_64, and
passes X86_DEV_ROOTFS to the compiler as --sysroot. The Pi has no x86_64
anything, and the FEX runtime RootFS is not a substitute: it carries three
entries in /usr/include and no crt1.o.

⛔ ABSOLUTE SYMLINKS ARE THE WHOLE TRAP. A .deb ships
/usr/lib/x86_64-linux-gnu/libGL.so -> /usr/lib/x86_64-linux-gnu/libGL.so.1 as an
ABSOLUTE link. Unpacked into a sysroot it resolves against the HOST root, where
that path is either missing or — worse — the aarch64 library, so the link either
fails to find it or silently offers the wrong architecture. Every absolute
symlink is rewritten relative at the end.
"""
import gzip, io, os, re, subprocess, sys, tarfile, urllib.request
from pathlib import Path

MIRROR = "http://archive.ubuntu.com/ubuntu/"
SUITES = ["noble", "noble-updates"]
COMPONENTS = ["main", "universe"]
# ⛔ BOTH, because FEX adds guest-libs AND guest-libs-32 unconditionally when
# BUILD_THUNKS is on — a 64-bit-only sysroot fails at the 32-bit ExternalProject
# after everything else has already built. Ubuntu noble's i386 port is partial
# but carries every one of the seeds below.
ARCHES = ["amd64", "i386"]

# The 15 guest thunk libraries include these headers; everything else is a
# dependency pulled in behind them.
SEED = [
    "libc6-dev", "linux-libc-dev", "libgcc-13-dev", "libstdc++-13-dev",
    "libx11-dev", "libxext-dev", "libxshmfence-dev", "libxcb1-dev",
    "mesa-common-dev", "libgl-dev", "libglx-dev", "libegl-dev", "libgles-dev",
    "libglvnd-dev", "libdrm-dev", "libvulkan-dev", "libwayland-dev",
    "libsdl2-dev", "libasound2-dev",
]

# Packaging machinery that no header needs. Pulling perl into a sysroot is a
# few hundred MB of nothing.
SKIP = {
    "dpkg", "perl", "perl-base", "debconf", "ucf", "install-info",
    "sensible-utils", "base-files", "base-passwd", "libdebconfclient0",
    "tzdata", "debianutils", "dash", "bash", "coreutils", "sed", "grep",
    "gcc-13", "cpp-13", "binutils", "libc-bin", "adduser", "passwd",
    # Nothing here needs a Python interpreter to provide a header. Some -dev
    # packages depend on one for a codegen tool; the headers land regardless.
    "python3", "python3-minimal", "python3.12", "python3.12-minimal",
    "libpython3.12-minimal", "libpython3.12-stdlib", "python3-pkg-resources",
    "media-types", "mime-support", "readline-common", "libreadline8t64",
}


def fetch(url):
    with urllib.request.urlopen(url, timeout=120) as r:
        return r.read()


def load_index(arch):
    """pkg -> stanza dict, plus virtual -> real from Provides."""
    pkgs, provides = {}, {}
    for suite in SUITES:
        for comp in COMPONENTS:
            url = f"{MIRROR}dists/{suite}/{comp}/binary-{arch}/Packages.gz"
            print(f"  index  {suite}/{comp}", flush=True)
            try:
                raw = gzip.decompress(fetch(url)).decode("utf-8", "replace")
            except Exception as e:
                print(f"         skipped ({e})")
                continue
            for stanza in raw.split("\n\n"):
                if not stanza.strip():
                    continue
                f = {}
                key = None
                for line in stanza.split("\n"):
                    if line[:1] in (" ", "\t") and key:
                        continue
                    if ":" in line:
                        key, _, val = line.partition(":")
                        f[key.strip()] = val.strip()
                name = f.get("Package")
                if not name:
                    continue
                # later suites (noble-updates) override earlier ones
                pkgs[name] = f
                for p in re.split(r",\s*", f.get("Provides", "")):
                    p = p.split("(")[0].strip()
                    if p:
                        provides.setdefault(p, name)
    return pkgs, provides


def deps_of(stanza):
    out = []
    for clause in re.split(r",\s*", stanza.get("Depends", "")):
        clause = clause.strip()
        if not clause:
            continue
        # "a | b" — take the first alternative that exists
        alts = [a.split("(")[0].split(":")[0].strip() for a in clause.split("|")]
        out.append([a for a in alts if a])
    return out


def resolve(pkgs, provides, seed):
    want, queue, missing = set(), list(seed), []
    while queue:
        name = queue.pop()
        if name in want or name in SKIP:
            continue
        real = name if name in pkgs else provides.get(name)
        if not real:
            missing.append(name)
            continue
        if real in want or real in SKIP:
            continue
        want.add(real)
        for alts in deps_of(pkgs[real]):
            pick = next((a for a in alts if a in pkgs or a in provides), None)
            if pick:
                queue.append(pick)
    return sorted(want), sorted(set(missing))


def _sysroot_filter(member, path):
    """
    ⛔ PYTHON'S `tar` FILTER REJECTS A DEB THAT SHIPS AN ABSOLUTE SYMLINK, and
    plenty of them do — libpython ships
    usr/lib/python3.12/sitecustomize.py -> /etc/python3.12/sitecustomize.py.
    Extraction dies with OutsideDestinationError naming a path that is not
    outside anything; it is absolute, which the filter treats as the same
    thing.

    ⚠ The fix is NOT filter=None. That drops the traversal check with it, and
    these debs arrive over plain http from a mirror with no signature check.
    The link target is rewritten relative to the member's own directory and
    then handed to the real filter, so `..` escapes are still caught.
    """
    if (member.issym() or member.islnk()) and member.linkname.startswith("/"):
        own_dir = os.path.dirname(member.name.lstrip("./")) or "."
        rel = os.path.relpath(member.linkname.lstrip("/"), own_dir)
        member = member.replace(linkname=rel, deep=False)
    return tarfile.tar_filter(member, path)


def unpack(deb_path, root):
    """A .deb is an ar archive; we want data.tar.{xz,zst,gz}.

    ⚠ GNU `ar` does NOT read an archive from stdin — it wants a path, and
    `ar t -` exits 9 with nothing on stderr worth reading. The .deb is on disk
    in the cache anyway, so it is passed by name.
    """
    deb_path = str(deb_path)
    p = subprocess.run(["ar", "t", deb_path], capture_output=True, check=True)
    member = next(m for m in p.stdout.decode().split()
                  if m.startswith("data.tar"))
    p = subprocess.run(["ar", "p", deb_path, member],
                       capture_output=True, check=True)
    blob = p.stdout
    if member.endswith(".zst"):
        blob = subprocess.run(["zstd", "-dc"], input=blob,
                              capture_output=True, check=True).stdout
        mode = "r:"
    elif member.endswith(".xz"):
        mode = "r:xz"
    elif member.endswith(".gz"):
        mode = "r:gz"
    else:
        mode = "r:"
    with tarfile.open(fileobj=io.BytesIO(blob), mode=mode) as t:
        t.extractall(root, filter=_sysroot_filter)


def usrmerge(root):
    """
    ⛔ `base-files` IS SKIPPED, AND IT IS WHAT SHIPS /lib -> usr/lib. Ubuntu is
    usrmerged: every file lands under /usr, and the compatibility symlinks are
    a separate package. Without them `libc.so` — a linker SCRIPT, not a library
    — names /lib/x86_64-linux-gnu/libc.so.6, lld resolves that inside the
    sysroot, finds nothing, and reports it as a missing libc:

        cannot find /lib/x86_64-linux-gnu/libc.so.6 inside <sysroot>

    /lib64 points at the multiarch directory rather than usr/lib64, because
    that is where the deb actually puts ld-linux-x86-64.so.2.
    """
    for link, target in (("lib", "usr/lib"),
                         ("lib64", "usr/lib/x86_64-linux-gnu"),
                         ("bin", "usr/bin"),
                         ("sbin", "usr/sbin")):
        p = root / link
        if p.is_symlink() or p.exists():
            continue
        if (root / target).is_dir():
            p.symlink_to(target)

    # ⚠ The i386 loader is named /lib/ld-linux.so.2, which with lib -> usr/lib
    # lands in usr/lib rather than the multiarch directory the deb put it in.
    loader = root / "usr/lib/i386-linux-gnu/ld-linux.so.2"
    compat = root / "usr/lib/ld-linux.so.2"
    if loader.exists() and not compat.exists() and not compat.is_symlink():
        compat.symlink_to("i386-linux-gnu/ld-linux.so.2")


def relativise_symlinks(root):
    """
    ⛔ See the module docstring — and note that os.walk puts a symlinked
    DIRECTORY in `dirnames`, not `filenames`. An earlier version of this only
    looked at filenames and reported "rewrote 2 symlinks" on a tree with
    hundreds, which then poisoned the next extraction: usr/share/X11 was left
    pointing at an absolute /etc/X11, so unpacking usr/share/X11/rgb.txt
    resolved outside the sysroot and tarfile refused it.
    """
    fixed = 0
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        for name in list(dirnames) + list(filenames):
            p = os.path.join(dirpath, name)
            if not os.path.islink(p):
                continue
            target = os.readlink(p)
            if not target.startswith("/"):
                continue
            rel = os.path.relpath(os.path.join(root, target.lstrip("/")), dirpath)
            os.remove(p)
            os.symlink(rel, p)
            fixed += 1
    return fixed


def main():
    root = Path(sys.argv[1]).resolve()
    root.mkdir(parents=True, exist_ok=True)
    print("building x86_64 sysroot at", root, flush=True)

    cache = root.parent / "deb-cache"
    cache.mkdir(exist_ok=True)

    for arch in ARCHES:
        print(f"\n== {arch} ==", flush=True)
        pkgs, provides = load_index(arch)
        print(f"  {len(pkgs)} packages in index", flush=True)

        want, missing = resolve(pkgs, provides, SEED)
        print(f"  {len(want)} packages in the closure", flush=True)
        if missing:
            print("  ⚠ unresolved (not fatal, but say so):", ", ".join(missing))

        for i, name in enumerate(want, 1):
            fn = pkgs[name]["Filename"]
            local = cache / Path(fn).name
            if not local.exists():
                local.write_bytes(fetch(MIRROR + fn))
            if i % 25 == 0 or i == len(want):
                print(f"  [{i}/{len(want)}] {name}", flush=True)
            unpack(local, root)

    usrmerge(root)
    n = relativise_symlinks(root)
    print(f"  rewrote {n} absolute symlinks as relative", flush=True)

    for probe in ("usr/include/stdio.h",
                  "usr/include/GL/gl.h",
                  "usr/include/X11/Xlib.h",
                  "usr/include/alsa/asoundlib.h",
                  "usr/lib/x86_64-linux-gnu/crt1.o",
                  "usr/lib/x86_64-linux-gnu/libc.so",
                  "usr/include/i386-linux-gnu/asm/types.h",
                  "usr/lib/i386-linux-gnu/crt1.o",
                  "usr/lib/i386-linux-gnu/libc.so",
                  "usr/lib/i386-linux-gnu/libGL.so"):
        print(f"  {'ok ' if (root / probe).exists() else 'NO '} {probe}")
    for triple in ("x86_64-linux-gnu", "i686-linux-gnu", "i386-linux-gnu"):
        crt = list(root.glob(f"usr/lib/gcc/{triple}/*/crtbeginS.o"))
        if crt:
            print(f"  ok  crtbeginS.o {crt[0].parent}")


if __name__ == "__main__":
    main()
