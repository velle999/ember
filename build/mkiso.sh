#!/usr/bin/env bash
#
# mkiso.sh — a bootable ISO of the same rootfs mkimage.sh writes to a stick.
#
# ── Why an ISO exists at all, next to the .img ──────────────────────────────
#
# ⛔ NOT EVERY PENTIUM 4 BOARD CAN BOOT FROM USB. Plenty of 865/875-era BIOSes
# either lack the option or implement it badly, and the machines this project
# targets are exactly those. An optical disc is the boot path that always works
# on that hardware, and the reference machine has two DVD drives.
#
# ⚠ THE .img IS STILL THE BETTER MEDIUM WHERE USB BOOT WORKS. It is a writable
# ext4 filesystem: it keeps what you do to it, ember-swap can put a swapfile on
# it, and ember-expand-root grows it. This ISO is read-only and forgets
# everything on reboot — it is an installer you can test-drive, not a system.
#
# ── How it differs, mechanically ────────────────────────────────────────────
#
# The .img is a configured Ember laid down on a partition. An ISO cannot be that:
# it is read-only, and a Linux system needs to write. So THAT SAME TREE becomes a
# squashfs and dracut's dmsquash-live stacks a RAM-backed overlay on top of it.
# ⛔ It is built from the .img and not from out/rootfs — see _mkiso-inside.sh for
# what happened the one time it was not.
#
# ⚠ THE OVERLAY IS IN RAM AND THIS IS A 2 GB MACHINE. That was nearly a
# non-starter: before the nv30 pixmap leak was fixed an idle desktop sat at
# 1114 MB used with another 1141 MB in swap, and there was no room for an
# overlay at all. With that fixed the same desktop idles at ~522 MB, so a few
# hundred MB of overlay is comfortable — and ember-zram is already in the boot
# path to absorb what it is not. Do not raise OVERLAY_MB without re-measuring;
# it comes straight out of what the desktop has to live in.
#
# ⚠ Squashfs also makes it FIT: a ~5.3 GB tree compresses to roughly 2 GB,
# which is a single-layer DVD with room to spare. The .img is 6.2 GB and is not.
#
#     build/mkiso.sh i686 desktop
#
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail
cd "$(dirname "$0")/.."
. build/config.sh

ARCH=${1:-i686}
TIER=${2:-desktop}
OUT="out/$EMBER_ID-$EMBER_VERSION-$ARCH-$TIER"
IMG="$OUT/$EMBER_ID-$EMBER_VERSION-$ARCH-$TIER.img"
ISO="$OUT/$EMBER_ID-$EMBER_VERSION-$ARCH-$TIER.iso"

# ⚠ The COW overlay, in MB, carved out of RAM at boot. See the header.
OVERLAY_MB=${EMBER_OVERLAY_MB:-512}

[ "$ARCH" = i686 ] || { echo "mkiso: only i686 for now — the Pi boots differently" >&2; exit 2; }
# ⛔ THE SOURCE IS THE .img, NOT out/rootfs. out/rootfs is the package tree
# before any configuration: no ember account, no enabled lightdm, no
# ember-install. An ISO built from it boots to an agetty that rejects every
# password, and passes every structural check while doing so. See
# build/_mkiso-inside.sh.
[ -f "$IMG" ] || {
    echo "mkiso: no image at $IMG — run build/mkimage.sh $ARCH $TIER first" >&2; exit 1; }
docker info >/dev/null 2>&1 || { echo "mkiso: the docker daemon is not running" >&2; exit 1; }

echo "== $EMBER_NAME $EMBER_VERSION — $ARCH / $TIER, ISO"
echo "   source   $IMG"
echo "   overlay  ${OVERLAY_MB} MB in RAM"
echo "   iso      $ISO"

rm -f "$ISO"
mkdir -p "$OUT"

docker run --rm --privileged \
    -v /dev:/dev \
    -v "$PWD/$OUT:/out" \
    -v "$PWD/build/_mkiso-inside.sh:/mkiso-inside.sh:ro" \
    -e ISONAME="$(basename "$ISO")" \
    -e IMGNAME="$(basename "$IMG")" \
    -e HOSTNAME_="$EMBER_ID" \
    -e EMBER_NAME="$EMBER_NAME" \
    -e EMBER_VERSION="$EMBER_VERSION" \
    -e OVERLAY_MB="$OVERLAY_MB" \
    "$VOID_IMAGE" /bin/sh /mkiso-inside.sh

echo
echo "iso: $ISO"
ls -lh "$ISO"
echo
echo "Burn it, or write it to a stick — it is isohybrid, so both work:"
echo "    xorriso -as cdrecord -v dev=/dev/sr0 blank=fast \"$ISO\""
echo "    sudo dd if=\"$ISO\" of=/dev/sdX bs=4M status=progress conv=fsync"
