#!/usr/bin/env bash
#
# mk-mesa.sh — build the patched mesa Ember ships for the nv30 machines.
#
# Two patches, both nv30, both found on the reference GeForce 7600:
#
#   mesa-nv30-idxbuf-reloc-dropped.patch
#       an indexed draw reached the engine with an unrelocated index buffer,
#       faulting on every indexed VBO draw
#
#   mesa-nv30-surface-del-leaks-resource-ref.patch
#       nv30_miptree_surface_del() frees the surface without dropping the
#       reference surface_new() took, so every render target leaks its miptree
#       and the X server grows ~38 MB/s whenever anything animates. A blank
#       screensaver killed the session in two minutes.
#
# ⚠ NOT build/mk-mesa-trace.sh. That one adds the leak counters and builds
# revision 98 into a scratch directory; this one builds the SHIPPING revision
# into the image's local repository. They deliberately do not share an output.
#
# ⛔ AND IT CLEANS srcpkgs/mesa/patches FIRST. The checkout is shared with
# mk-mesa-trace.sh, which leaves nv30-leak-trace.patch sitting there — and
# xbps-src applies every patch in that directory. Without the clean, a shipping
# build silently carries the instrumentation, which prints to stderr on every
# 512th texture transfer for the life of the X server.
#
#     build/mk-mesa.sh
#
# ⚠ ~40 minutes and several GB.
#
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail
cd "$(dirname "$0")/.."
. build/config.sh

SRCPKG=mesa
ARCH=i686
OUT="out/${EMBER_ID}-repo-$ARCH"
WORK="out/kernel-build"
IMAGE="ghcr.io/void-linux/void-linux:latest-full-i686"
REVISION=7
WANT_VER=26.1.8

PATCHES=(
    patches/mesa-nv30-idxbuf-reloc-dropped.patch
    patches/mesa-nv30-surface-del-leaks-resource-ref.patch
)

echo "== patched $SRCPKG ${WANT_VER}_${REVISION} -> $OUT"

for p in "${PATCHES[@]}"; do
    [ -f "$p" ] || { echo "mk-mesa: missing $p" >&2; exit 1; }
    grep -q '^@@ -[0-9]' "$p" || {
        echo "mk-mesa: $p has no line-numbered hunks — not an applicable diff" >&2
        exit 1; }
done

NEED_GB=12
FREE_GB=$(df -BG --output=avail . | tail -1 | tr -dc '0-9')
[ "${FREE_GB:-0}" -ge "$NEED_GB" ] || {
    echo "mk-mesa: needs ~${NEED_GB}G free, have ${FREE_GB}G" >&2; exit 1; }
echo "   disk    ${FREE_GB}G free"

mkdir -p "$WORK" "$OUT"
[ -d "$WORK/void-packages/.git" ] || {
    echo "   clone   void-packages (shallow)"
    git clone --depth 1 https://github.com/void-linux/void-packages "$WORK/void-packages"; }

SRCDIR="$WORK/void-packages/srcpkgs/$SRCPKG"
[ -d "$SRCDIR" ] || { echo "mk-mesa: no srcpkgs/$SRCPKG" >&2; exit 1; }

TMPL_VER=$(sed -n 's/^version=//p' "$SRCDIR/template" | head -1)
[ "$TMPL_VER" = "$WANT_VER" ] || {
    echo "mk-mesa: void-packages has $SRCPKG $TMPL_VER, the patches are against $WANT_VER" >&2
    echo "         re-check both against the new source before bumping WANT_VER" >&2
    exit 1; }

# ⛔ The clean the header warns about. Void's own musl patches live here too and
# must survive, so this removes only what this tree put there.
rm -f "$SRCDIR/patches/nv30-leak-trace.patch"
for p in "${PATCHES[@]}"; do rm -f "$SRCDIR/patches/$(basename "$p")"; done

echo "   patch   ${#PATCHES[@]} nv30 patches into $SRCPKG $TMPL_VER"
mkdir -p "$SRCDIR/patches"
cp "${PATCHES[@]}" "$SRCDIR/patches/"
[ -e "$SRCDIR/patches/nv30-leak-trace.patch" ] && {
    echo "mk-mesa: the leak-trace patch is still staged — refusing to ship it" >&2
    exit 1; }

sed -i "s/^revision=.*/revision=${REVISION}/" "$SRCDIR/template"

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
        # ⛔ .i686 ONLY, and only the four packages the image installs. The same
        # template also produces x86_64 '-32bit' compat packages, which xbps-rindex
        # ignores in an i686 repository — so they would sit there unnoticed.
        for p in mesa mesa-dri mesa-libgallium libgbm; do
            find /void-packages/hostdir/binpkgs -name \"\$p-${WANT_VER}_${REVISION}.i686.xbps\" \
                 -exec cp -v {} /out/ \;
        done
    "

echo "   index   rebuilding repository metadata"
docker run --rm -v "$PWD/$OUT:/out" "$IMAGE" \
    /bin/sh -euc "xbps-rindex -a /out/*.xbps"

echo "== done"
ls -1 "$OUT"/{mesa,mesa-dri,mesa-libgallium,libgbm}-${WANT_VER}_${REVISION}.i686.xbps 2>/dev/null | sed 's/^/   /'
