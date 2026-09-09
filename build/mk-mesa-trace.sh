#!/usr/bin/env bash
#
# mk-mesa-trace.sh — build an INSTRUMENTED mesa for the nv30 leak hunt.
#
# ⛔ THIS PRODUCES A DIAGNOSTIC PACKAGE, NOT A SHIPPING ONE. It is the ordinary
# patched mesa plus patches/nv30-leak-trace.patch, which counts nv30's GART
# transfer temporaries and miptrees against their frees and prints a running
# balance to stderr. Do not put its output in an image; it exists to find the
# leak, and the revision (98) is deliberately below the shipping one so it
# cannot win a dependency resolution by accident.
#
# WHAT IT IS FOR. The X server leaks GPU-backed memory on nv30 at roughly
# 38 MB/s while anything animates — a screensaver takes the session down in two
# minutes on the reference machine. Established so far:
#
#   * it is inside Xorg — restarting X frees every byte, 2.7 GB in one case
#   * it is NOT glamor — same server and screensaver on llvmpipe leaked 2 MB
#     in 60 s, against ~2300 MB/min on nv30
#   * it is NOT the fence-deferred free path — NOUVEAU_DISABLE_FENCES=1 changed
#     nothing, which killed the best theory this project had
#   * the pages are ~92% zeros, and survive the client disconnecting
#
# So it is an allocation in nv30 that is never freed, and reading the code did
# not find it. This counts the two sites that can account for the volume.
#
# HOW TO USE THE RESULT:
#   build/mk-mesa-trace.sh
#   tools/install-mesa-fix.sh                     # ship it to the P4
#   then run X with NV30_LEAK_TRACE=1 and read /var/log/Xorg.0.log:
#       nv30-leak: tx map=N unmap_now=N unmap_fenced=N outstanding=N | ...
#   A growing "outstanding" or "held" names the leaking site. A flat balance
#   means the volume is somewhere neither counter sees, and the next suspects
#   are nouveau_mm slab reclaim and the buffer (non-miptree) path.
#
# ⚠ ~40 minutes and several GB. mesa is not Thunar.
#
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail
cd "$(dirname "$0")/.."
. build/config.sh

SRCPKG=mesa
ARCH=i686
OUT="out/${EMBER_ID}-mesa-trace"
WORK="out/kernel-build"          # the same checkout mk-kernel.sh and mk-thunar.sh use
IMAGE="ghcr.io/void-linux/void-linux:latest-full-i686"

echo "== instrumented $SRCPKG -> $OUT"

for p in patches/mesa-nv30-idxbuf-reloc-dropped.patch patches/nv30-leak-trace.patch; do
    [ -f "$p" ] || { echo "mk-mesa-trace: missing $p" >&2; exit 1; }
    grep -q '^@@ -[0-9]' "$p" || {
        echo "mk-mesa-trace: $p has no line-numbered hunks — not an applicable diff" >&2
        exit 1; }
done

# ⛔ DISK, BEFORE STARTING. Same lesson as mk-kernel.sh: running out at the end
# means the compile succeeded and the package could not be written, after most
# of an hour.
NEED_GB=12
FREE_GB=$(df -BG --output=avail . | tail -1 | tr -dc '0-9')
[ "${FREE_GB:-0}" -ge "$NEED_GB" ] || {
    echo "mk-mesa-trace: needs ~${NEED_GB}G free, have ${FREE_GB}G" >&2; exit 1; }
echo "   disk    ${FREE_GB}G free"

mkdir -p "$WORK" "$OUT"
[ -d "$WORK/void-packages/.git" ] || {
    echo "   clone   void-packages (shallow)"
    git clone --depth 1 https://github.com/void-linux/void-packages "$WORK/void-packages"; }

SRCDIR="$WORK/void-packages/srcpkgs/$SRCPKG"
[ -d "$SRCDIR" ] || { echo "mk-mesa-trace: no srcpkgs/$SRCPKG" >&2; exit 1; }

TMPL_VER=$(sed -n 's/^version=//p' "$SRCDIR/template" | head -1)
WANT_VER=26.1.8
[ "$TMPL_VER" = "$WANT_VER" ] || {
    echo "mk-mesa-trace: void-packages has $SRCPKG $TMPL_VER, patches are against $WANT_VER" >&2
    exit 1; }

echo "   patch   nv30 idxbuf fix + leak trace into $SRCPKG $TMPL_VER"
mkdir -p "$SRCDIR/patches"
cp patches/mesa-nv30-idxbuf-reloc-dropped.patch patches/nv30-leak-trace.patch "$SRCDIR/patches/"

# ⚠ 98, NOT 99 AND NOT 7. Below the shipping revision on purpose: this package
# must never win over a real one just because it is newer.
sed -i "s/^revision=.*/revision=98/" "$SRCDIR/template"

echo "   build   this takes tens of minutes"
docker run --rm --privileged \
    -v "$PWD/$WORK/void-packages:/void-packages" \
    -v "$PWD/$OUT:/out" \
    "$IMAGE" \
    /bin/sh -euc "
        xbps-install -Sy xbps >/dev/null 2>&1 || true
        xbps-install -Sy bash shadow git >/dev/null
        rm -f /void-packages/etc/conf
        id -u 1000 >/dev/null 2>&1 || useradd -m -u 1000 -s /bin/bash builder
        BU=\$(id -nu 1000)
        chown \$BU /void-packages /out
        su \$BU -c 'cd /void-packages && ./xbps-src binary-bootstrap && ./xbps-src -j'\$(nproc)' pkg $SRCPKG'
        find /void-packages/hostdir/binpkgs -name '*.i686.xbps' \
             \\( -name 'mesa-*' -o -name 'libgbm-*' \\) ! -name '*-dbg-*' \
             -exec cp -v {} /out/ \;
    "

echo "== done: $(ls "$OUT"/*.xbps 2>/dev/null | wc -l) package(s) in $OUT"
ls -1 "$OUT"/*.xbps 2>/dev/null | sed 's/^/   /'
