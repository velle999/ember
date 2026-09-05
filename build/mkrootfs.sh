#!/usr/bin/env bash
#
# mkrootfs.sh — a Void rootfs for one architecture and one weight tier.
#
# ── Why this runs in a container ────────────────────────────────────────────
#
# Building a Void rootfs needs xbps, Void's package manager, which is not
# packaged for the distributions this is developed on. Rather than vendor a
# static xbps and keep it current by hand, the build borrows Void's own image.
#
# ── The asymmetry between the two targets, which is not a detail ────────────
#
# ⚠ i686 RUNS NATIVELY ON AN x86_64 HOST. A 32-bit x86 rootfs can be built
# completely here — package scriptlets execute, because the host CPU is the
# target CPU with more registers. Nothing needs emulating.
#
# ⛔ aarch64 DOES NOT. Its scriptlets are ARM binaries, so the host needs
# qemu-user-static registered with binfmt_misc before any of them can run. A
# build without that does not fail loudly — xbps unpacks every file correctly
# and then skips or errors the post-install scripts, and what comes out is a
# rootfs that looks complete, is missing generated files, and fails at boot.
# So it is checked for up front and refused, rather than discovered on a Pi.
#
# Usage:
#   build/mkrootfs.sh i686 desktop-min
#   build/mkrootfs.sh aarch64 desktop
#
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail
cd "$(dirname "$0")/.."
. build/config.sh

ARCH=${1:-}
TIER=${2:-desktop-min}
case "$ARCH" in
    i686|aarch64) ;;
    *) echo "usage: $0 <i686|aarch64> [desktop-min|desktop]" >&2; exit 2 ;;
esac
[ -f "profiles/$TIER.pkgs" ] || { echo "no such tier: profiles/$TIER.pkgs" >&2; exit 2; }

OUT="out/$EMBER_ID-$EMBER_VERSION-$ARCH-$TIER"
ROOTFS="$OUT/rootfs"

# ── the checks, before anything is downloaded ───────────────────────────────

command -v docker >/dev/null || { echo "mkrootfs: docker is not installed" >&2; exit 1; }
if ! docker info >/dev/null 2>&1; then
    cat >&2 <<'MSG'
mkrootfs: the docker daemon is not running (or is not reachable by this user).

  Start it:   sudo systemctl start docker
  Persist it: sudo systemctl enable --now docker

If you are not in the docker group, add yourself and log back in:
  sudo usermod -aG docker "$USER"
MSG
    exit 1
fi

if [ "$ARCH" = aarch64 ]; then
    # See the header: a missing binfmt handler produces a rootfs that looks
    # right and does not boot, so this is a refusal and not a warning.
    if ! ls /proc/sys/fs/binfmt_misc/ 2>/dev/null | grep -qi 'aarch64\|arm64'; then
        cat >&2 <<'MSG'
mkrootfs: aarch64 needs qemu-user-static registered with binfmt_misc, and it is
          not. Without it the ARM package scriptlets cannot run: the rootfs
          would unpack cleanly, skip its post-install steps, and fail to boot.

  One-shot registration (re-run after a reboot):
      docker run --privileged --rm tonistiigi/binfmt --install arm64

  Or install the host package that does it permanently:
      Arch:   sudo pacman -S qemu-user-static qemu-user-static-binfmt
      Debian: sudo apt install qemu-user-static binfmt-support
MSG
        exit 1
    fi
fi

# ── the package list ────────────────────────────────────────────────────────

case "$ARCH" in
    i686)
        REPO="$VOID_REPO_I686"; EXTRA="profiles/arch-i686.pkgs"
        MODEL_PKGS="$KERNEL_I686"
        [ "$EMBER_WINE" = 1 ] && EXTRA="$EXTRA profiles/legacy-wine.pkgs"
        ;;
    aarch64)
        REPO="$VOID_REPO_AARCH64"; EXTRA="profiles/arch-aarch64.pkgs"
        MODEL_PKGS="$RPI_PKGS"
        ;;
esac

# shellcheck disable=SC2046
PKGS=$(cat profiles/base.pkgs "profiles/$TIER.pkgs" $EXTRA |
       sed 's/#.*//' | tr -s ' \t' '\n' | grep -v '^$' | sort -u | tr '\n' ' ')
PKGS="$PKGS $MODEL_PKGS"

echo "== $EMBER_NAME $EMBER_VERSION — $ARCH / $TIER"
echo "   repo    $REPO"
[ "$ARCH" = aarch64 ] && echo "   pi      model $RPI_MODEL → $MODEL_PKGS"
[ "$ARCH" = i686 ] && echo "   kernel  $KERNEL_I686   wine=$EMBER_WINE"
echo "   rootfs  $ROOTFS"
echo "   pkgs    $(echo "$PKGS" | wc -w)"

# ⛔ THE OLD ROOTFS IS DESTROYED FIRST, AND IT TAKES DOCKER TO DO IT. Everything
# under it is owned by root (the container created it), so a plain `rm -rf` here
# fails with EPERM — and the failure is easy to miss, after which xbps installs
# ON TOP of whatever was there. That is not hypothetical: the first build of this
# tree was an aborted x86_64 attempt, the rm failed, and the i686 build layered
# over it and left two x86_64 binaries (firefox, iptables-xml) in a tree that
# otherwise passed every check.
#
# ⚠ The path is composed from EMBER_ID/version/arch/tier and nothing else, and
# it is passed as a fixed mount rather than interpolated into the shell inside
# the container — a `rm -rf` built by string-substitution is not a thing to have.
if [ -d "$ROOTFS" ]; then
    echo "   clean   removing the previous $ROOTFS"
    docker run --rm -v "$PWD/$OUT:/out" "$VOID_IMAGE" \
        /bin/sh -euc 'rm -rf /out/rootfs'
fi
mkdir -p "$ROOTFS"

# ⛔ XBPS_ARCH IS THE ONLY WAY TO SET THE TARGET ARCHITECTURE, and the mistake
# worth documenting is the one this line replaced: `xbps-install -A i686`.
# `-A` LOOKS like --arch and is nothing of the sort — in xbps-install it means
# "set automatic installation mode". So the flag was accepted, silently ignored
# as an architecture, and xbps fetched x86_64-repodata and began building an
# x86_64 rootfs that would have installed cleanly, booted on nothing this
# project targets, and reported success throughout.
#
# ⚠ THE SIGNING KEYS ARE COPIED IN FIRST. A fresh rootdir has no keys, so xbps
# stops to ask whether to trust the repository — and with no TTY that prompt does
# not fail loudly, it reads EOF and dies with "Resource temporarily unavailable".
# void-mklive does the same thing for the same reason.
#
# ⚠ --privileged, and it is load-bearing rather than lazy. xbps creates device
# nodes and sets ownership inside the target root; without it the unpack fails
# partway and leaves a rootfs missing exactly the files nothing later checks for.
docker run --rm --privileged \
    -v "$PWD/$ROOTFS:/rootfs" \
    -e XBPS_ARCH="$ARCH" \
    "$VOID_IMAGE" \
    /bin/sh -euc "
        mkdir -p /rootfs/var/db/xbps/keys
        cp /var/db/xbps/keys/*.plist /rootfs/var/db/xbps/keys/
        xbps-install -y -S -R '$REPO' -r /rootfs $PKGS
        # The download cache is a build artefact, not part of the system: it is
        # the single biggest thing in the tree (1.5 GB on the first build here)
        # and every byte of it is a copy of something already unpacked.
        rm -rf /rootfs/var/cache/xbps
    "

# ── VERIFY BY CONTENT, NOT BY EXIT STATUS ───────────────────────────────────
#
# The whole reason this check exists is the -A mistake above: every command
# succeeded, and what came out was the wrong architecture. An exit status cannot
# see that, so the ELF header of something the rootfs actually contains is asked
# instead.
# ⛔ EVERY ELF IN THE TREE, NOT ONE OF THEM. The first version of this check
# read a single binary, passed, and shipped a tree with two x86_64 executables
# still in it. One sample cannot see contamination — that is the entire nature of
# contamination — so the whole tree is walked.
python3 - "$ROOTFS" "$ARCH" <<'ENDPY' || exit 1
import os, sys
root, arch = sys.argv[1], sys.argv[2]
want = {"i686": 3, "aarch64": 183}[arch]
names = {3: "i386", 40: "arm", 62: "x86_64", 183: "aarch64", 243: "riscv"}

# ⚠ DEVICE FIRMWARE IS ELF TOO, AND IT IS NOT FOR THIS CPU. /usr/lib/firmware
# holds blobs that are uploaded to a sound card or a NIC and executed by the
# hardware on it — miXart8.elf reports e_machine 5120, which is not a host
# architecture at all. Flagging those as "wrong architecture" is not a bug being
# caught, it is a correct file being misread, and it would make this check
# something people learn to ignore.
#
# So: skip firmware paths, and only judge machine types that are HOSTS. Real
# contamination is always one of those — the leftover this check was written for
# was an x86_64 (62) firefox sitting in an i686 tree.
def is_firmware(rel):
    return "/firmware/" in "/" + rel

bad, n = [], 0
for dirpath, _, files in os.walk(root):
    for f in files:
        p = os.path.join(dirpath, f)
        if os.path.islink(p) or is_firmware(os.path.relpath(p, root)):
            continue
        try:
            with open(p, "rb") as fh:
                if fh.read(4) != b"\x7fELF":
                    continue
                fh.seek(18)
                m = int.from_bytes(fh.read(2), "little")
        except OSError:
            continue
        n += 1
        if m != want and m in names:
            bad.append((os.path.relpath(p, root), m))
print(f"verified:     {n} ELF objects scanned", end="")
if bad:
    print(f"\nmkrootfs: WRONG ARCHITECTURE — {len(bad)} object(s) are not {arch}:",
          file=sys.stderr)
    for p, m in bad[:10]:
        print(f"          {names.get(m, m):8} /{p}", file=sys.stderr)
    sys.exit(1)
print(f", all {names[want]}")
ENDPY

echo
echo "rootfs built: $ROOTFS"
du -sh "$ROOTFS" 2>/dev/null || true
