#!/usr/bin/env bash
#
# mk-kernel.sh — build a patched linux6.18 package for i686.
#
# ⛔ WHY A WHOLE KERNEL PACKAGE AND NOT JUST A MODULE. The nv4x fixes in
# patches/ add MODULE PARAMETERS (nouveau.accel_move=, nouveau.fence_sema=).
# Dropping a hand-built nouveau.ko over the stock one leaves an UNSIGNED
# OUT-OF-TREE module loaded on every boot, and on this hardware that is not
# cosmetic — it arms two separate kernel bugs:
#
#   * reading /proc/modules NULL-derefs in m_show, so `lsmod` KILLS THE MACHINE
#   * dracut-install reads /proc/modules too, so regenerating the initramfs
#     oopses mid-run and can leave a half-written, unbootable image
#
# Building the module in-tree, as part of the kernel package, removes the
# out-of-tree taint entirely and both traps with it. It also means xbps owns
# the file, so `xbps-install -Su` cannot silently replace the fix with stock
# nouveau the way it would a loose .ko.
#
# ⚠ THIS IS A LONG BUILD — tens of minutes, and it wants disk. It is not part
# of mkrootfs.sh for that reason: run it when the patches change, not on every
# image build. The result is a package in the local repository, and
# mkrootfs.sh installs from there if it is present.
#
#     build/mk-kernel.sh              # build for the pinned version
#     build/mk-kernel.sh 6.18.49_1    # or an explicit one
#
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail
cd "$(dirname "$0")/.."
. build/config.sh

KVER="${1:-$EMBER_KERNEL_VERSION}"
PKGVER="${KVER%_*}"                       # 6.18.49
SRCPKG="linux${PKGVER%.*}"                # linux6.18
ARCH=i686
OUT="out/${EMBER_ID}-repo-$ARCH"
WORK="out/kernel-build"
IMAGE="ghcr.io/void-linux/void-linux:latest-full-i686"

echo "== patched kernel: $SRCPKG $KVER -> $OUT"

# ⚠ The patches must be REAL DIFFS. An earlier generation of these files used
# `@@ function_name()` as hunk headers — readable, and completely inapplicable
# by patch(1). They documented the change instead of containing it, and nothing
# noticed because nothing ever tried to apply them. This script is that check:
# if a patch does not apply, the build stops here rather than quietly shipping
# a stock kernel that looks patched.
for p in patches/nouveau-*.patch; do
    grep -q '^@@ -[0-9]' "$p" || {
        echo "mk-kernel: $p has no line-numbered hunks — it is not an applicable diff" >&2
        exit 1; }
done

# ⛔ CHECK THE DISK BEFORE STARTING. This build peaks around 21 GB — a 15 GB
# kernel tree in the masterdir plus a multi-GB -dbg package — and it spends
# roughly 40 minutes getting there. Running out at the END means the compile
# succeeded and the .xbps could not be written:
#
#     xbps-create: ERROR: No space left on device
#     => ERROR: Failed to created binary package: linux6.18-...xbps!
#
# and it takes the whole filesystem to 0 bytes on the way, which breaks
# everything else running on the machine. Fail here instead, cheaply.
NEED_GB=25
FREE_GB=$(df -BG --output=avail . | tail -1 | tr -dc '0-9')
if [ "${FREE_GB:-0}" -lt "$NEED_GB" ]; then
    echo "mk-kernel: needs ~${NEED_GB}G free, have ${FREE_GB}G" >&2
    echo "           the build peaks ~21G and dies at the last step without it" >&2
    exit 1
fi
echo "   disk    ${FREE_GB}G free (needs ~${NEED_GB}G)"

mkdir -p "$WORK" "$OUT"

# ⚠ void-packages is a big checkout; keep it shallow and reuse it.
if [ ! -d "$WORK/void-packages/.git" ]; then
    echo "   clone   void-packages (shallow)"
    git clone --depth 1 https://github.com/void-linux/void-packages "$WORK/void-packages"
fi

SRCDIR="$WORK/void-packages/srcpkgs/$SRCPKG"
[ -d "$SRCDIR" ] || { echo "mk-kernel: no srcpkgs/$SRCPKG in void-packages" >&2; exit 1; }

# ⛔ VERIFY THE VERSION BEFORE BUILDING, not after. void-packages is rolling: if
# its linux6.18 has moved past the version the reference machine runs, the
# module built here will not match the running kernel's vermagic and modprobe
# will refuse it — after a build long enough that nobody wants to repeat it.
TMPL_VER=$(sed -n 's/^version=//p' "$SRCDIR/template" | head -1)
if [ "$TMPL_VER" != "$PKGVER" ]; then
    echo "mk-kernel: void-packages has $SRCPKG $TMPL_VER, this tree pins $PKGVER" >&2
    echo "           update EMBER_KERNEL_VERSION in build/config.sh, or pin the checkout" >&2
    exit 1
fi

echo "   patch   $(ls patches/nouveau-*.patch | wc -l) nouveau patches into $SRCPKG"
mkdir -p "$SRCDIR/patches"
cp patches/nouveau-*.patch "$SRCDIR/patches/"

# ⚠ Bump the revision so the result OUTRANKS Void's own package. Same version
# and same revision means xbps has no reason to prefer ours, and the image
# silently gets stock nouveau back.
sed -i "s/^revision=.*/revision=99/" "$SRCDIR/template"

echo "   build   this takes tens of minutes"
docker run --rm --privileged \
    -v "$PWD/$WORK/void-packages:/void-packages" \
    -v "$PWD/$OUT:/out" \
    "$IMAGE" \
    /bin/sh -euc "
        # THREE THINGS THIS CONTAINER DOES NOT GIVE YOU, each failing in a way
        # that names the wrong culprit:
        #
        # 1. xbps refuses to install ANYTHING until it updates itself --
        #    'The xbps package must be updated' -- and if that message is
        #    swallowed, every later install silently does nothing.
        # 2. There is no bash. xbps-src is a #!/bin/bash script, so it fails as
        #        /bin/sh: 1: ./xbps-src: not found
        #    for a file that exists and is executable.
        # 3. xbps-src REFUSES TO RUN AS ROOT, which is what a container gives
        #    you by default: 'ERROR: xbps-src cannot be used as root.'
        xbps-install -Sy xbps >/dev/null 2>&1 || true
        xbps-install -Sy bash shadow git >/dev/null
        # 4. A STALE etc/conf IS INVISIBLE AND SILENT. Setting
        #    XBPS_CHROOT_CMD=ethereal makes install_base_chroot() return
        #    immediately, so 'binary-bootstrap' prints nothing, exits 0, and
        #    leaves masterdir empty -- and the build then fails with
        #    'Bootstrap not installed in masterdir' pointing at the wrong step.
        #    The checkout is reused between runs, so the file outlives the
        #    attempt that created it.
        rm -f /void-packages/etc/conf
        id -u 1000 >/dev/null 2>&1 || useradd -m -u 1000 -s /bin/bash builder
        BU=\$(id -nu 1000)
        chown \$BU /void-packages /out
        # The bind-mounted tree is already owned by uid 1000 on the host, so the
        # build user is created with that uid rather than chown-ing a 23k-file
        # checkout on every run.
        su \$BU -c 'cd /void-packages && ./xbps-src binary-bootstrap && ./xbps-src -j'\$(nproc)' pkg $SRCPKG'
        # ⚠ NOT the -dbg package. Kernel debug symbols are 1.8 GB — fourteen
        # times the kernel itself — and mkrootfs.sh bind-mounts this directory
        # into every image build. It is a build artefact, not something an
        # image should carry or a laptop should copy around.
        find /void-packages/hostdir/binpkgs -name '*.xbps' ! -name '*-dbg-*' \
             -exec cp -v {} /out/ \;
    "

echo "   index   rebuilding repository metadata"
docker run --rm -v "$PWD/$OUT:/out" "$IMAGE" \
    /bin/sh -euc "xbps-rindex -a /out/*.xbps"

echo "== done: $(ls "$OUT"/${SRCPKG}-*.xbps 2>/dev/null | wc -l) kernel package(s) in $OUT"
ls -1 "$OUT"/*.xbps 2>/dev/null | sed 's/^/   /'
