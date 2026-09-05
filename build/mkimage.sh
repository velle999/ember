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

if [ "$ARCH" != i686 ]; then
    echo "mkimage: only i686 is wired up. A Pi image is not a disk image with a" >&2
    echo "         BIOS bootloader — it is a FAT firmware partition plus config.txt," >&2
    echo "         and building it needs qemu-user-static for the ARM chroot." >&2
    exit 2
fi
[ -d "$ROOTFS" ] || { echo "mkimage: no rootfs at $ROOTFS — run build/mkrootfs.sh first" >&2; exit 1; }
docker info >/dev/null 2>&1 || { echo "mkimage: the docker daemon is not running" >&2; exit 1; }

# Room for the tree plus somewhere to live. Measured rather than guessed, since
# the tier and EMBER_WINE move it by nearly a gigabyte.
used_mb=$(docker run --rm -v "$PWD/$ROOTFS:/r:ro" "$VOID_IMAGE" du -sm /r | cut -f1)
size_mb=$(( used_mb * 14 / 10 + 1024 ))
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
    -v "$PWD/build/_image-inside.sh:/image-inside.sh:ro" \
    -v "$PWD/installer:/installer:ro" \
    -e IMGNAME="$(basename "$IMG")" \
    -e USERNAME="$USERNAME" -e PASSWORD="$PASSWORD" \
    -e HOSTNAME_="$EMBER_ID" -e TIER="$TIER" \
    "$VOID_IMAGE" /bin/sh /image-inside.sh

echo
echo "image: $IMG"
ls -lh "$IMG"
echo
echo "Write it to a disk or USB stick with:"
echo "    sudo dd if=$IMG of=/dev/sdX bs=4M status=progress conv=fsync"
