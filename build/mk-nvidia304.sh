#!/usr/bin/env bash
#
# mk-nvidia304.sh — build the OPTIONAL NVIDIA 304 stack: the kernel module and a
# private xorg-server 1.19 to run it under.
#
# ⛔ THIS IS OPT-IN AND IT STAYS OPT-IN. nouveau is what Ember boots. Nothing
# here loads or runs unless somebody types `ember-gpu nvidia`. Two reasons, and
# the second one is the serious one:
#
#   1. PERFORMANCE IS UNMEASURED. The reason to want 304 — reclocking, mature
#      3D on a card nouveau cannot clock — is still an assumption. Every number
#      taken so far was vsync-capped or CPU-bound. See docs/target-p4.md.
#
#   2. ⛔ IT ARMS A KERNEL BUG THIS PROJECT ALREADY FOUND. nvidia.ko is an
#      unsigned out-of-tree module, and on this hardware that is exactly when
#      reading /proc/modules NULL-derefs in m_show: once it is loaded, `lsmod`
#      kills the machine and so does anything invoking dracut. It is why
#      mk-kernel.sh builds the nouveau patches IN-TREE rather than shipping a
#      loose .ko. ember-gpu says so before it does anything.
#
# ── What it produces ────────────────────────────────────────────────────────
#
#   out/ember-nvidia304-i686/nvidia.ko      the kernel module
#   out/ember-nvidia304-i686/x11-19.tar.gz  /opt/x11-19: server + driver + GL
#
# _image-inside.sh installs both if the directory exists, and silently ships
# without them if it does not — the same arrangement as installer/wifi.nmconnection.
#
# ⚠ THE MODULE IS TIED TO ONE KERNEL. vermagic is checked at load, so this must
# be rebuilt whenever EMBER_KERNEL_VERSION moves or the module will refuse to
# load on the image that ships it.
#
# ⚠ ~45 minutes: a kernel module build plus a full X server build.
#
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail
cd "$(dirname "$0")/.."
. build/config.sh

ARCH=i686
OUT="out/${EMBER_ID}-nvidia304-$ARCH"
WORK="out/nvidia304-build"
IMAGE="ghcr.io/void-linux/void-linux:latest-full-$ARCH"
NV=304.137
RUN="NVIDIA-Linux-x86-${NV}.run"
FORK="https://github.com/flydiscohuebr/nvidia-304"

echo "== NVIDIA $NV stack -> $OUT"

NEED_GB=10
FREE_GB=$(df -BG --output=avail . | tail -1 | tr -dc '0-9')
[ "${FREE_GB:-0}" -ge "$NEED_GB" ] || {
    echo "mk-nvidia304: needs ~${NEED_GB}G free, have ${FREE_GB}G" >&2; exit 1; }

mkdir -p "$OUT" "$WORK"

# ⚠ The patches come from the fork, not from this tree — they are a hundred
# files and they are not ours to vendor. Cloned shallow and reused.
[ -d "$WORK/nvidia-304/.git" ] || {
    echo "   clone   the nvidia-304 patch set"
    git clone --depth 1 -q "$FORK" "$WORK/nvidia-304"; }

[ -f "$WORK/$RUN" ] || {
    echo "   fetch   $RUN"
    curl -fsSL -o "$WORK/$RUN" \
      "https://us.download.nvidia.com/XFree86/Linux-x86/${NV}/${RUN}"; }

# The kernel patches, and the order the fork applies them in.
KP="$WORK/nvidia-304/Archlinux/nvidia-304.137/nvidia-304xx-utils"
XP="$WORK/nvidia-304/Archlinux/xorg-server1.19-git-edit"
[ -d "$KP" ] && [ -d "$XP" ] || { echo "mk-nvidia304: the fork's layout moved" >&2; exit 1; }

mkdir -p "$WORK/kpatches" "$WORK/xpatches"
cp "$KP"/0*.patch "$WORK/kpatches/"
cp "$XP"/*.patch "$XP"/*.diff "$WORK/xpatches/" 2>/dev/null || true
sed -n '/^prepare()/,/^}/p' "$XP/PKGBUILD" |
    grep -oE "\.\./[A-Za-z0-9._+-]+\.(patch|diff)" | sed 's|\.\./||' > "$WORK/xpatches/order.txt"
echo "   patches kernel $(ls "$WORK/kpatches" | wc -l), xserver $(wc -l < "$WORK/xpatches/order.txt")"

# ⚠ The kernel tarball, for the archheaders repair — Void's headers package
# omits arch/x86/entry/syscalls and the module cannot build without it.
KSRCDIR="out/kernel-build/void-packages/hostdir/sources/linux6.18-${EMBER_KERNEL_VERSION%_*}"
[ -d "$KSRCDIR" ] || { echo "mk-nvidia304: no kernel sources at $KSRCDIR — run build/mk-kernel.sh first" >&2; exit 1; }

cp build/_nvidia304-inside.sh "$WORK/inside.sh"
echo "   build   ~45 minutes"
docker run --rm \
    -v "$PWD/$WORK:/work" \
    -v "$PWD/$OUT:/out" \
    -v "$PWD/out/${EMBER_ID}-repo-$ARCH:/emberrepo:ro" \
    -v "$PWD/$KSRCDIR:/work/linux-src:ro" \
    "$IMAGE" /bin/sh /work/inside.sh

echo "== done"
ls -lh "$OUT" | sed 's/^/   /'
