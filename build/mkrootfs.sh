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
    i686)    REPO="$VOID_REPO_I686";    EXTRA="profiles/arch-i686.pkgs";    MODEL_PKGS="" ;;
    aarch64) REPO="$VOID_REPO_AARCH64"; EXTRA="profiles/arch-aarch64.pkgs"; MODEL_PKGS="$RPI_PKGS" ;;
esac

# shellcheck disable=SC2046
PKGS=$(cat profiles/base.pkgs "profiles/$TIER.pkgs" "$EXTRA" |
       sed 's/#.*//' | tr -s ' \t' '\n' | grep -v '^$' | sort -u | tr '\n' ' ')
PKGS="$PKGS $MODEL_PKGS"

echo "== $EMBER_NAME $EMBER_VERSION — $ARCH / $TIER"
echo "   repo    $REPO"
[ -n "$MODEL_PKGS" ] && echo "   pi      model $RPI_MODEL → $MODEL_PKGS"
echo "   rootfs  $ROOTFS"
echo "   pkgs    $(echo "$PKGS" | wc -w)"

mkdir -p "$ROOTFS"

# ⚠ --privileged, and it is load-bearing rather than lazy. xbps creates device
# nodes and sets ownership inside the target root; without it the unpack fails
# partway and leaves a rootfs missing exactly the files nothing later checks for.
docker run --rm --privileged \
    -v "$PWD/$ROOTFS:/rootfs" \
    "$VOID_IMAGE" \
    /bin/sh -euc "
        xbps-install -y -S -R '$REPO' -r /rootfs -A '$ARCH' $PKGS
    "

echo
echo "rootfs built: $ROOTFS"
du -sh "$ROOTFS" 2>/dev/null || true
