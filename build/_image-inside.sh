#!/bin/sh
#
# _image-inside.sh — the half of mkimage.sh that runs as root inside the
# container. Split out because it is three levels of quoting otherwise: a shell
# string, inside a docker -c string, inside a chroot -c string. That nesting is
# not a style objection — the first version of this file would not parse, and a
# version that parses but escapes one quote wrongly builds a subtly wrong image.
#
# Everything it needs arrives in the environment. Not invoked directly.
#
# ⚠ POSIX sh, and `set -eu` WITHOUT pipefail. The Void container ships dash as
# /bin/sh and no bash at all — the first run of this died on `stat /bin/bash: no
# such file or directory` before executing a line. The script inside the CHROOT
# is a different matter and may use bash, because the rootfs being built has it.
#
# SPDX-License-Identifier: GPL-2.0-or-later
set -eu

IMG="/out/$IMGNAME"

# ⛔ NOT `>/dev/null 2>&1 || true`. That is what this line was, and it turned a
# failed install into `parted: not found` twenty lines later with the actual
# reason discarded. If the image cannot be partitioned, say so here.
# ⚠ xbps UPDATES ITSELF FIRST OR REFUSES TO WORK AT ALL. The container image is
# older than the repository it is pointed at, and xbps will not install anything
# while it is behind: "The 'xbps' package must be updated". It is a hard stop,
# not a warning.
xbps-install -Suy xbps
xbps-install -Sy parted e2fsprogs util-linux
for t in parted mkfs.ext4 losetup blkid; do
    command -v "$t" >/dev/null || { echo "mkimage: $t missing after install" >&2; exit 1; }
done

# One bootable primary partition, msdos table. The 1 MiB start leaves the gap
# GRUB embeds its core image into; without it grub-install refuses.
parted -s "$IMG" mklabel msdos
parted -s "$IMG" mkpart primary ext4 1MiB 100%
parted -s "$IMG" set 1 boot on

LOOP=$(losetup --find --partscan --show "$IMG")
cleanup() {
    umount -R /mnt 2>/dev/null || true
    losetup -d "$LOOP" 2>/dev/null || true
}
trap cleanup EXIT

# ⚠ CONSERVATIVE ext4 FEATURES. metadata_csum_seed and orphan_file are both
# newer than plenty of bootloaders and rescue tools, and the cost of being wrong
# is a trip to a machine that will not boot rather than an error message.
# Nothing is gained by having them on a 2 GB root.
mkfs.ext4 -q -O ^metadata_csum_seed,^orphan_file -L "$HOSTNAME_" "${LOOP}p1"
mount "${LOOP}p1" /mnt
cp -a /out/rootfs/. /mnt/

# The installer travels in the image, because the image IS the installer: you
# boot it from a USB stick and it puts itself on a disk.
install -Dm755 /installer/ember-install /mnt/usr/bin/ember-install
install -Dm755 /installer/ember-mount-windows /mnt/usr/bin/ember-mount-windows

UUID=$(blkid -s UUID -o value "${LOOP}p1")
printf 'UUID=%s\t/\text4\tdefaults,noatime\t0 1\n' "$UUID" > /mnt/etc/fstab
printf '%s\n' "$HOSTNAME_" > /mnt/etc/hostname

mount --bind /dev  /mnt/dev
mount --bind /proc /mnt/proc
mount --bind /sys  /mnt/sys

# ⛔ THE CHROOT SCRIPT IS SHARED WITH THE PI PATH — see build/_chroot-setup.sh.
# It used to be a heredoc here, which meant the Pi builder would have needed its
# own copy of the accounts, the chpasswd trap and the service set. One of those
# copies would eventually have been fixed and the other not.
install -Dm755 /chroot-setup.sh /mnt/tmp/setup.sh
chroot /mnt env USERNAME="$USERNAME" PASSWORD="$PASSWORD" \
                TIER="$TIER" LOOP="$LOOP" BOOTLOADER=grub /tmp/setup.sh
rm -f /mnt/tmp/setup.sh

# ── verify by content, not by exit status ───────────────────────────────────
#
# grub-mkconfig inside a chroot on a loop device happily writes
# root=/dev/loop0p1 into grub.cfg. That is correct in here and meaningless on
# the target, and nothing else would notice until the machine failed to boot.
if grep -q '/dev/loop' /mnt/boot/grub/grub.cfg; then
    echo "mkimage: grub.cfg names a loop device — it would not boot" >&2
    grep -n '/dev/loop' /mnt/boot/grub/grub.cfg | head -5 >&2
    exit 1
fi
if ! grep -q "$UUID" /mnt/boot/grub/grub.cfg; then
    echo "mkimage: grub.cfg does not reference the root UUID $UUID" >&2
    exit 1
fi
if ! dd if="$IMG" bs=512 count=1 status=none | grep -qa GRUB; then
    echo "mkimage: no GRUB signature in the MBR — nothing would load" >&2
    exit 1
fi
# ⚠ Counted, not tested with a glob: `[ -s /mnt/boot/initramfs-*.img ]` passes
# the expansion straight to `[`, which errors on "too many arguments" the moment
# there is more than one kernel installed.
if [ "$(find /mnt/boot -maxdepth 1 -name 'initramfs-*.img' -size +1M | wc -l)" -lt 1 ]; then
    echo "mkimage: no initramfs of any size in /boot" >&2
    exit 1
fi

echo "inside: root UUID $UUID, grub.cfg and MBR both verified"
sync
