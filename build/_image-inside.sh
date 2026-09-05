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

UUID=$(blkid -s UUID -o value "${LOOP}p1")
printf 'UUID=%s\t/\text4\tdefaults,noatime\t0 1\n' "$UUID" > /mnt/etc/fstab
printf '%s\n' "$HOSTNAME_" > /mnt/etc/hostname

mount --bind /dev  /mnt/dev
mount --bind /proc /mnt/proc
mount --bind /sys  /mnt/sys

# The chroot's own script, written out for the same reason this file exists.
cat > /mnt/tmp/setup.sh <<'INNER'
#!/bin/bash
set -euo pipefail

useradd -m -G wheel,audio,video,input -s /bin/bash "$USERNAME" 2>/dev/null || true
printf '%s:%s\n' "$USERNAME" "$PASSWORD" | chpasswd
printf 'root:%s\n' "$PASSWORD" | chpasswd
mkdir -p /etc/sudoers.d
echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/wheel
chmod 440 /etc/sudoers.d/wheel

# ⛔ REGENERATED --no-hostonly. The initramfs already in the rootfs was built
# inside a container against the CONTAINER's hardware; a hostonly image made
# there carries that machine's storage drivers and not the Pentium 4's IDE/SATA
# controller. The failure mode is a kernel panic on a box with no serial console.
dracut --force --no-hostonly

# ⚠ A SERIAL CONSOLE, ON PURPOSE AND SHIPPED. tty0 stays first so a monitor
# still shows everything; ttyS0 mirrors it. On a machine of this era that is a
# debugging lifeline — a kernel panic before X starts is otherwise a photograph
# of a screen — and it is what makes the image testable in qemu without a
# display at all. See build/boot-test.sh.
sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="loglevel=4 console=tty0 console=ttyS0,115200"/' /etc/default/grub
grep -q '^GRUB_TERMINAL' /etc/default/grub || echo 'GRUB_TERMINAL_OUTPUT="console serial"' >> /etc/default/grub
echo 'GRUB_SERIAL_COMMAND="serial --speed=115200 --unit=0"' >> /etc/default/grub

grub-install --target=i386-pc --boot-directory=/boot "$LOOP"
grub-mkconfig -o /boot/grub/grub.cfg

# ⛔ NEVER BOTH NetworkManager AND dhcpcd. They each want the interface and
# fight over it; enabling the pair is the classic way to get a machine that has
# an address for ten seconds at a time.
cd /etc/runit/runsvdir/default
ln -sf /etc/sv/dbus  .
ln -sf /etc/sv/udevd .
# ⚠ A GETTY ON THE SERIAL LINE, or the console added above is write-only. The
# kernel and runit both log to ttyS0, but the six agettys Void enables by
# default are all on VGA tty1-6 — so without this you can watch a boot over
# serial and then have nowhere to type. On a machine of this era, being able to
# log in without a monitor attached is the difference between debugging it and
# carrying it to a desk.
ln -sf /etc/sv/agetty-ttyS0 .
if [ "$TIER" = desktop ]; then
    ln -sf /etc/sv/elogind        .
    ln -sf /etc/sv/polkitd        .
    ln -sf /etc/sv/NetworkManager .
    ln -sf /etc/sv/lightdm        .
else
    ln -sf /etc/sv/dhcpcd .
fi
INNER
chmod +x /mnt/tmp/setup.sh
chroot /mnt env USERNAME="$USERNAME" PASSWORD="$PASSWORD" \
                TIER="$TIER" LOOP="$LOOP" /tmp/setup.sh
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
