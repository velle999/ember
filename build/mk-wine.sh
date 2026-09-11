#!/usr/bin/env bash
#
# mk-wine.sh — build a patched Wine package for i686.
#
# ⛔ WHY A PATCHED WINE. Wine 11.17 leaves the extension table of any OpenGL
# context older than 3.0 EMPTY, so on the reference machine's NVIDIA 304 stack
# (OpenGL 2.1) every game that goes through wined3d — Direct3D and DirectDraw
# alike — calls a NULL GL function during adapter setup and dies at address 0.
# Pure-OpenGL games are unaffected, which is what made it look like "wine works
# on half the games". patches/wine-11.17-legacy-gl-context-extensions.patch has
# the mechanism and the measurements; it is a one-line fix to a shadowed local.
#
# ⚠ THIS PACKAGE IS IN THE ROOTFS, NOT THE IMAGE LAYER — same order as
# mk-thunar.sh: this script, then build/mkrootfs.sh, then build/mkimage.sh.
#
# ⚠ Not part of mkrootfs.sh; run it when the patch or Void's wine version
# changes. The result is a package in the local repository and mkrootfs.sh
# installs from there if it is present.
#
#     build/mk-wine.sh
#
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail
cd "$(dirname "$0")/.."
. build/config.sh

SRCPKG=wine
ARCH=i686
OUT="out/${EMBER_ID}-repo-$ARCH"
WORK="out/kernel-build"   # the shared void-packages checkout, see mk-thunar.sh
IMAGE="ghcr.io/void-linux/void-linux:latest-full-i686"
PATCH=patches/wine-11.17-legacy-gl-context-extensions.patch
WANT_VER=11.17

echo "== patched $SRCPKG -> $OUT"

grep -q '^@@ -[0-9]' "$PATCH" || {
    echo "mk-wine: $PATCH has no line-numbered hunks — it is not an applicable diff" >&2
    exit 1; }

mkdir -p "$WORK" "$OUT"

if [ ! -d "$WORK/void-packages/.git" ]; then
    echo "   clone   void-packages (shallow)"
    git clone --depth 1 https://github.com/void-linux/void-packages "$WORK/void-packages"
fi

SRCDIR="$WORK/void-packages/srcpkgs/$SRCPKG"
[ -d "$SRCDIR" ] || { echo "mk-wine: no srcpkgs/$SRCPKG in void-packages" >&2; exit 1; }

# ⛔ The checkout is shallow and only as fresh as its last pull; the patch is
# against one version and says so. A newer wine may have fixed this upstream —
# check dlls/win32u/opengl.c parse_current_extensions() before bumping.
TMPL_VER=$(sed -n 's/^version=//p' "$SRCDIR/template" | head -1)
# ⚠ Refresh ONLY srcpkgs/wine when it is behind. A whole-tree pull would also
# move linux6.18, Thunar and mesa, which mk-kernel.sh / mk-thunar.sh pin and
# have patched in this same working tree.
if [ "$TMPL_VER" != "$WANT_VER" ]; then
    echo "   refresh srcpkgs/$SRCPKG ($TMPL_VER) from void-packages master"
    git -C "$WORK/void-packages" fetch --depth 1 origin master
    git -C "$WORK/void-packages" checkout FETCH_HEAD -- "srcpkgs/$SRCPKG"
    TMPL_VER=$(sed -n 's/^version=//p' "$SRCDIR/template" | head -1)
fi
if [ "$TMPL_VER" != "$WANT_VER" ]; then
    echo "mk-wine: void-packages has $SRCPKG $TMPL_VER, the patch is against $WANT_VER" >&2
    echo "         (git -C $WORK/void-packages pull --depth 1 if it is OLDER)" >&2
    exit 1
fi

echo "   patch   $PATCH into $SRCPKG $TMPL_VER"
mkdir -p "$SRCDIR/patches"
cp "$PATCH" "$SRCDIR/patches/"

# revision 99 = "ours", so it outranks Void's wine-11.17_1 (see mk-thunar.sh)
sed -i "s/^revision=.*/revision=99/" "$SRCDIR/template"

echo "   build   wine is large: expect tens of minutes"
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
        # ⛔ i686 + noarch ONLY, and only OUR revision: the same template also
        # yields x86_64 '-32bit' compat packages, and wine-mono/wine-gecko are
        # separate source packages whose names also start with 'wine'.
        find /void-packages/hostdir/binpkgs \\( -name 'wine*-${WANT_VER}_99.i686.xbps' \
             -o -name 'wine*-${WANT_VER}_99.noarch.xbps' \\) ! -name '*-dbg-*' \
             -exec cp -v {} /out/ \;
    "

echo "   index   rebuilding repository metadata"
docker run --rm -v "$PWD/$OUT:/out" "$IMAGE" \
    /bin/sh -euc "xbps-rindex -a /out/*.xbps"

echo "== done: $(ls "$OUT"/wine*-${WANT_VER}_99.*.xbps 2>/dev/null | wc -l) $SRCPKG package(s) in $OUT"
ls -1 "$OUT"/wine*-${WANT_VER}_99.*.xbps 2>/dev/null | sed 's/^/   /'
