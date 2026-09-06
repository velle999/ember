#!/usr/bin/env bash
#
# mkimage.sh — turn a built rootfs into a disk image that boots.
#
# ── What this targets ───────────────────────────────────────────────────────
#
# ⛔ MBR AND BIOS, NOT GPT AND UEFI. The machine this exists for is a Pentium 4;
# there is no EFI firmware on it to find an ESP. GRUB goes into the MBR gap with
# --target=i386-pc, and the partition table is msdos. An image built the modern
# way is not "mostly right" on that hardware, it is unbootable.
#
# ── Why a container, again ──────────────────────────────────────────────────
#
# losetup, mkfs.ext4 and a chroot all need root. Borrowing the same Void image
# keeps that in one place and means the GRUB doing the installing is the same
# GRUB the target will run.
#
# ⚠ THE CHROOT RUNS THE TARGET'S OWN BINARIES, and for i686 that is free: 32-bit
# x86 executes natively on an x86_64 host, so grub-install and dracut inside the
# chroot are the i686 ones without any emulation. aarch64 would need
# qemu-user-static, which is why that path is refused for now rather than
# quietly producing something wrong.
#
# Usage:
#   build/mkimage.sh i686 desktop
#   EMBER_USER=velle EMBER_PASS=hunter2 build/mkimage.sh i686 desktop
#
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail
cd "$(dirname "$0")/.."
. build/config.sh

ARCH=${1:-i686}
TIER=${2:-desktop}
OUT="out/$EMBER_ID-$EMBER_VERSION-$ARCH-$TIER"
ROOTFS="$OUT/rootfs"
IMG="$OUT/$EMBER_ID-$EMBER_VERSION-$ARCH-$TIER.img"

USERNAME=${EMBER_USER:-ember}
PASSWORD=${EMBER_PASS:-ember}

case "$ARCH" in
    i686)    INSIDE=build/_image-inside.sh ;;
    aarch64) INSIDE=build/_image-inside-pi.sh
             # ⛔ The ARM chroot cannot run without qemu-user-static registered
             # in binfmt_misc — see mkrootfs.sh for the same refusal and why it
             # is a refusal rather than a warning.
             ls /proc/sys/fs/binfmt_misc/ 2>/dev/null | grep -qi 'aarch64\|arm64' || {
                 echo "mkimage: aarch64 needs qemu-user-static in binfmt_misc." >&2
                 echo "         docker run --privileged --rm tonistiigi/binfmt --install arm64" >&2
                 exit 1; }
             ;;
    *) echo "mkimage: unknown architecture $ARCH" >&2; exit 2 ;;
esac
[ -d "$ROOTFS" ] || { echo "mkimage: no rootfs at $ROOTFS — run build/mkrootfs.sh first" >&2; exit 1; }

# ⛔ A DIRECTORY IS NOT A FINISHED ROOTFS. mkrootfs.sh writes this stamp as its
# very last act, after xbps has returned and after every ELF in the tree has been
# checked for the right architecture. Building an image from a tree that is still
# being written produces one that boots, looks correct, and is missing whatever
# had not downloaded yet — which is exactly what happened: a 2785 MiB image with
# no wine, no retroarch and no browser, and not one thing reported an error.
if [ ! -f "$ROOTFS/.ember-rootfs-complete" ]; then
    echo "mkimage: $ROOTFS has no completion stamp." >&2
    echo "         Either mkrootfs.sh is still running, or it did not finish." >&2
    echo "         Wait for it, or re-run: build/mkrootfs.sh $ARCH $TIER" >&2
    exit 1
fi
docker info >/dev/null 2>&1 || { echo "mkimage: the docker daemon is not running" >&2; exit 1; }

# Room for the tree plus somewhere to live. Measured rather than guessed, since
# the tier and EMBER_WINE move it by nearly a gigabyte.
used_mb=$(docker run --rm -v "$PWD/$ROOTFS:/r:ro" "$VOID_IMAGE" du -sm /r | cut -f1)
# ⚠ 15% PLUS 768 MiB, NOT 40% PLUS A GIGABYTE. This headroom is for the LIVE
# session only — the installer sizes the real root partition to whatever free
# space it finds on the target disk, so slack carried in the image buys nothing
# once installed and costs it on every write of the stick.
#
# ⛔ AND IT IS THE DIFFERENCE BETWEEN FITTING AND NOT. At 40% the image reached
# 7604 MiB against a nominal 8 GB stick that offers about 7629 — a 25 MiB margin,
# which is not a margin. Sticks vary in exact capacity and the next package
# added would have made it unwritable.
size_mb=$(( used_mb * 115 / 100 + 768 ))
echo "== $EMBER_NAME $EMBER_VERSION — $ARCH / $TIER"
echo "   rootfs  ${used_mb} MiB"
echo "   image   ${size_mb} MiB  →  $IMG"
echo "   login   $USERNAME / $PASSWORD   (root shares the password)"

rm -f "$IMG"
truncate -s "${size_mb}M" "$IMG"

# ⚠ /dev is shared into the container because losetup creates nodes there and
# the host has to see them go away again; --privileged alone is not enough.
#
# ⚠ The in-container half is a FILE, not a -c string. See build/_image-inside.sh
# for why: it is otherwise three levels of nested quoting and the first attempt
# would not even parse.
docker run --rm --privileged \
    -v /dev:/dev \
    -v "$PWD/$OUT:/out" \
    -v "$PWD/$INSIDE:/image-inside.sh:ro" \
    -v "$PWD/build/_chroot-setup.sh:/chroot-setup.sh:ro" \
    -v "$PWD/installer:/installer:ro" \
    -v "$PWD/cores/$ARCH:/cores:ro" \
    -e IMGNAME="$(basename "$IMG")" \
    -e USERNAME="$USERNAME" -e PASSWORD="$PASSWORD" \
    -e HOSTNAME_="$EMBER_ID" -e TIER="$TIER" -e RPI_MODEL_N="$RPI_MODEL" \
    -e PI_MODE="$EMBER_PI_MODE" -e PI_ROTATE="$EMBER_PI_ROTATE" \
    "$VOID_IMAGE" /bin/sh /image-inside.sh

echo
echo "image: $IMG"
ls -lh "$IMG"
echo
echo "Write it to a disk, USB stick or SD card with:"
echo "    sudo dd if=$IMG of=/dev/sdX bs=4M status=progress conv=fsync"
