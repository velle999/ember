#!/usr/bin/env bash
#
# mk-thunar.sh — build a patched Thunar package for i686.
#
# ⛔ WHY A PATCHED FILE MANAGER. Closing a Thunar window leaves its
# ThunarStandardView running statusbar work for the life of the process, against
# a widget tree that no longer exists. Measured on the reference machine
# 2026-09-08 with stock Thunar 4.20.9: 3431 log lines in 46 minutes, exactly
# 801 ms apart, in a `Thunar --daemon` with no windows open —
#
#     exo-CRITICAL: IA__exo_icon_view_get_selected_items:
#                   assertion 'EXO_IS_ICON_VIEW (icon_view)' failed
#
# — a wakeup every 801 ms on a Pentium 4, an .xsession-errors growing about
# 11 MB a day with nothing to rotate it, and one leaked view object per window
# closed on a machine with 2 GB. patches/thunar-statusbar-timeout-outlives-view
# .patch has the full mechanism and the gdb backtrace it came from.
#
# ⚠ THIS PACKAGE IS IN THE ROOTFS, NOT THE IMAGE LAYER. Unlike everything in
# installer/, a new Thunar does not reach an image by rebuilding the image: the
# order is this script, then build/mkrootfs.sh, then build/mkimage.sh. Skipping
# the middle step produces an image that looks rebuilt and ships stock Thunar.
#
# ⚠ Not part of mkrootfs.sh, for the same reason mk-kernel.sh is not: run it
# when the patch changes. The result is a package in the local repository and
# mkrootfs.sh installs from there if it is present.
#
#     build/mk-thunar.sh
#
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail
cd "$(dirname "$0")/.."
. build/config.sh

SRCPKG=Thunar
ARCH=i686
OUT="out/${EMBER_ID}-repo-$ARCH"
# ⚠ THE SAME CHECKOUT mk-kernel.sh USES, deliberately. void-packages is a 3 GB
# tree with a bootstrapped masterdir; a second copy is a second thing to keep
# current and several gigabytes to keep it in. The directory is named for the
# kernel because that is what first needed it.
WORK="out/kernel-build"
IMAGE="ghcr.io/void-linux/void-linux:latest-full-i686"
PATCH=patches/thunar-statusbar-timeout-outlives-view.patch

echo "== patched $SRCPKG -> $OUT"

# ⚠ A REAL DIFF, not a description of one. Same check as mk-kernel.sh, and for
# the same reason: a patch with no line-numbered hunks applies to nothing, and
# without this the build succeeds and ships stock Thunar.
grep -q '^@@ -[0-9]' "$PATCH" || {
    echo "mk-thunar: $PATCH has no line-numbered hunks — it is not an applicable diff" >&2
    exit 1; }

mkdir -p "$WORK" "$OUT"

if [ ! -d "$WORK/void-packages/.git" ]; then
    echo "   clone   void-packages (shallow)"
    git clone --depth 1 https://github.com/void-linux/void-packages "$WORK/void-packages"
fi

SRCDIR="$WORK/void-packages/srcpkgs/$SRCPKG"
[ -d "$SRCDIR" ] || { echo "mk-thunar: no srcpkgs/$SRCPKG in void-packages" >&2; exit 1; }

# ⛔ THE PATCH IS AGAINST ONE VERSION AND SAYS SO. void-packages is rolling. A
# hunk that no longer applies stops the build loudly, but a hunk that still
# applies to a version whose surrounding code has moved is worse — so the
# version is checked here rather than trusted to patch(1).
TMPL_VER=$(sed -n 's/^version=//p' "$SRCDIR/template" | head -1)
WANT_VER=4.20.9
if [ "$TMPL_VER" != "$WANT_VER" ]; then
    echo "mk-thunar: void-packages has $SRCPKG $TMPL_VER, the patch is against $WANT_VER" >&2
    echo "           re-check the patch against the new source, then bump WANT_VER here" >&2
    exit 1
fi

echo "   patch   $PATCH into $SRCPKG $TMPL_VER"
mkdir -p "$SRCDIR/patches"
cp "$PATCH" "$SRCDIR/patches/"

# ⚠ Bump the revision so the result OUTRANKS Void's own package. Same version
# and same revision means xbps has no reason to prefer ours, and the image
# silently gets stock Thunar back. 99 is the marker this tree uses for "ours".
sed -i "s/^revision=.*/revision=99/" "$SRCDIR/template"

echo "   build   a few minutes"
docker run --rm --privileged \
    -v "$PWD/$WORK/void-packages:/void-packages" \
    -v "$PWD/$OUT:/out" \
    "$IMAGE" \
    /bin/sh -euc "
        # The same three container facts mk-kernel.sh documents: xbps must
        # update itself before it will install anything, there is no bash for
        # xbps-src's shebang, and xbps-src refuses to run as root.
        xbps-install -Sy xbps >/dev/null 2>&1 || true
        xbps-install -Sy bash shadow git >/dev/null
        rm -f /void-packages/etc/conf
        id -u 1000 >/dev/null 2>&1 || useradd -m -u 1000 -s /bin/bash builder
        BU=\$(id -nu 1000)
        chown \$BU /void-packages /out
        su \$BU -c 'cd /void-packages && ./xbps-src binary-bootstrap && ./xbps-src -j'\$(nproc)' pkg $SRCPKG'
        # ⛔ .i686.xbps ONLY. xbps-src also produces the x86_64 '-32bit' compat
        # packages from this same template, and a bare '$SRCPKG-*.xbps' glob
        # rakes them into an i686 repository where they do not belong:
        # xbps-rindex ignores them, so nothing complains and they simply sit
        # there being bind-mounted into every image build.
        find /void-packages/hostdir/binpkgs -name '$SRCPKG-*.i686.xbps' \
             -exec cp -v {} /out/ \;
    "

echo "   index   rebuilding repository metadata"
docker run --rm -v "$PWD/$OUT:/out" "$IMAGE" \
    /bin/sh -euc "xbps-rindex -a /out/*.xbps"

echo "== done: $(ls "$OUT"/${SRCPKG}-*.xbps 2>/dev/null | wc -l) $SRCPKG package(s) in $OUT"
ls -1 "$OUT"/${SRCPKG}-*.xbps 2>/dev/null | sed 's/^/   /'
