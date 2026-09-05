#!/bin/sh
#
# _image-inside-pi.sh — a Raspberry Pi 4/5 SD-card image.
#
# ⛔ A PI DOES NOT BOOT LIKE A PC AND THIS IS NOT THE SAME FILE WITH A DIFFERENT
# BOOTLOADER. There is no MBR boot code, no GRUB and no initramfs in the chain.
# The Pi's own firmware reads a FAT32 partition directly: it loads start4.elf,
# which loads kernel8.img and the device tree named for the board, and passes it
# whatever single line is in cmdline.txt. Everything that makes a PC image boot
# is absent here, and everything that makes this boot is absent there.
#
# ⚠ THE FAT PARTITION MUST BE FIRST AND MUST BE FAT32. The firmware looks at the
# first partition of the first bootable device and nowhere else.
#
# ⛔ AND THE ROOT IS NAMED BY PARTUUID, NOT BY DEVICE. Void ships cmdline.txt
# hardcoded to /dev/mmcblk0p2, which is correct for an SD card and WRONG the
# moment the same image is written to a USB stick — where it is /dev/sda2 and
# the kernel panics unable to mount root. A Pi 4 can boot from either, so the
# image must not care which it landed on.
#
# ⚠ POSIX sh: the Void container ships dash and no bash. See _image-inside.sh.
#
# SPDX-License-Identifier: GPL-2.0-or-later
set -eu

IMG="/out/$IMGNAME"
BOOT_MB=256

xbps-install -Suy xbps
xbps-install -Sy parted e2fsprogs dosfstools util-linux
for t in parted mkfs.ext4 mkfs.vfat losetup blkid; do
    command -v "$t" >/dev/null || { echo "mkimage: $t missing after install" >&2; exit 1; }
done

# ⚠ msdos, not GPT. Pi 4 firmware can read GPT with recent EEPROM, but MBR is
# what every Pi reads and there is nothing here that needs more than four
# partitions.
parted -s "$IMG" mklabel msdos
parted -s "$IMG" mkpart primary fat32 1MiB "$((BOOT_MB + 1))MiB"
parted -s "$IMG" mkpart primary ext4  "$((BOOT_MB + 1))MiB" 100%
parted -s "$IMG" set 1 boot on
# 0x0c is FAT32 LBA. The firmware is content with 0x0b or 0x0c; some tooling is
# fussier, and being explicit costs nothing.
parted -s "$IMG" set 1 lba on

LOOP=$(losetup --find --partscan --show "$IMG")
cleanup() {
    umount -R /mnt/boot 2>/dev/null || true
    umount -R /mnt 2>/dev/null || true
    losetup -d "$LOOP" 2>/dev/null || true
}
trap cleanup EXIT

# ⛔ WAIT FOR THE NODES. --partscan is asynchronous and the delay scales with the
# image; mounting immediately fails with ENOENT from mount(2), which reads like
# a missing mount point rather than a device that has not appeared yet.
i=0
while [ $i -lt 60 ]; do
    [ -b "${LOOP}p1" ] && [ -b "${LOOP}p2" ] && break
    i=$((i + 1)); sleep 0.5
done
[ -b "${LOOP}p2" ] || { echo "mkimage: partition nodes never appeared" >&2; exit 1; }

mkfs.vfat -F 32 -n EMBERBOOT "${LOOP}p1" >/dev/null
mkfs.ext4 -F -q -O ^metadata_csum_seed,^orphan_file -L "$HOSTNAME_" "${LOOP}p2"

mount "${LOOP}p2" /mnt
cp -a /out/rootfs/. /mnt/

# ── the boot partition ──────────────────────────────────────────────────────
# Void's rpi packages put the firmware, the kernel and 365 overlays in /boot of
# the rootfs. That directory IS the FAT partition; it is moved there and left as
# an empty mount point.
mkdir -p /mnt/boot
mount "${LOOP}p1" /mnt/boot.fat 2>/dev/null || { mkdir -p /mnt/boot.fat; mount "${LOOP}p1" /mnt/boot.fat; }
cp -a /mnt/boot/. /mnt/boot.fat/
rm -rf /mnt/boot/*
umount /mnt/boot.fat && rmdir /mnt/boot.fat
mount "${LOOP}p1" /mnt/boot

# ⚠ PARTUUID comes from the MBR disk identifier plus the partition number, which
# is what the Pi kernel resolves without help from an initramfs. `-02` is the
# second partition.
PTUUID=$(blkid -c /dev/null -s PTUUID -o value "$LOOP")
ROOTUUID=$(blkid -c /dev/null -s UUID -o value "${LOOP}p2")
BOOTUUID=$(blkid -c /dev/null -s UUID -o value "${LOOP}p1")

# ⛔ cmdline.txt IS ONE LINE. A newline in the middle silently truncates the
# arguments after it, and the symptom is a kernel that boots and cannot find
# root — with no clue as to why.
printf 'root=PARTUUID=%s-02 rw rootwait fsck.repair=yes console=ttyAMA0,115200 console=tty1 loglevel=4\n' \
    "$PTUUID" > /mnt/boot/cmdline.txt

# ⚠ APPENDED, NOT REPLACED. Void already ships dtoverlay=vc4-kms-v3d, which is
# what gives the Pi 4 its real Mesa V3D driver rather than a framebuffer —
# overwriting config.txt would cost the hardware GL this whole target depends on.
{
    echo ''
    echo '# Ember'
    echo 'arm_64bit=1'
    echo 'enable_uart=1'
    echo 'disable_overscan=1'
    # ⚠ Model-specific KMS overlay. Void ships vc4-kms-v3d-pi4.dtbo and
    # vc4-kms-v3d-pi5.dtbo alongside the generic one; the generic overlay is
    # written by the rpi packages and the specific one is appended after it, so
    # the later line wins. On a Pi 4 the -pi4 variant is what drives both HDMI
    # outputs at full clock.
    if [ -f "/mnt/boot/overlays/vc4-kms-v3d-pi${RPI_MODEL_N}.dtbo" ]; then
        echo "dtoverlay=vc4-kms-v3d-pi${RPI_MODEL_N}"
    fi
} >> /mnt/boot/config.txt

printf 'UUID=%s\t/\text4\tdefaults,noatime\t0 1\n'          "$ROOTUUID" >  /mnt/etc/fstab
printf 'UUID=%s\t/boot\tvfat\tdefaults,nofail\t0 2\n'       "$BOOTUUID" >> /mnt/etc/fstab
printf 'tmpfs\t/tmp\ttmpfs\tdefaults,nosuid,nodev\t0 0\n'               >> /mnt/etc/fstab
printf '%s\n' "$HOSTNAME_" > /mnt/etc/hostname

# ⛔ FORCE vc4 AND v3d TO LOAD. Without a DRM device X has nothing to drive:
# the firmware hands the kernel a simple-framebuffer, the console renders on it
# perfectly, and Xorg then finds no /dev/dri/card* and dies — which looks like a
# broken desktop rather than a missing driver. `cat /sys/class/graphics/fb0/name`
# saying "simple" instead of "vc4" is the tell.
#
# ⚠ There is NO INITRAMFS on this target, so nothing loads a module before the
# root is mounted, and the DT modalias autoload has to happen through udev after
# it. Naming them here does not depend on that working.
mkdir -p /mnt/etc/modules-load.d
printf 'vc4\nv3d\n' > /mnt/etc/modules-load.d/10-ember-vc4.conf

install -Dm755 /installer/ember-install /mnt/usr/bin/ember-install
install -Dm755 /installer/ember-mount-windows /mnt/usr/bin/ember-mount-windows
install -Dm755 /installer/ember-disc /mnt/usr/bin/ember-disc
install -Dm755 /installer/ember-expand-root /mnt/usr/bin/ember-expand-root
install -Dm644 /installer/06-ember-expand.sh /mnt/etc/runit/core-services/06-ember-expand.sh
install -Dm644 /installer/thunar-uca.xml /mnt/etc/xdg/Thunar/uca.xml

# ── libretro cores ──────────────────────────────────────────────────────────
# ⚠ /usr/lib/libretro is where RetroArch looks by default on Linux, and the
# config below says so explicitly rather than relying on that default: a
# retroarch.cfg that names no core directory sends a first-time user to the
# online updater, which is the one thing this machine cannot use.
if [ -d /cores ] && [ -n "$(ls -A /cores 2>/dev/null)" ]; then
    mkdir -p /mnt/usr/lib/libretro
    cp -a /cores/. /mnt/usr/lib/libretro/
    chmod 0644 /mnt/usr/lib/libretro/*.so 2>/dev/null || true
    mkdir -p /mnt/etc
    if [ -f /mnt/etc/retroarch.cfg ]; then
        sed -i 's|^libretro_directory =.*|libretro_directory = "/usr/lib/libretro"|' /mnt/etc/retroarch.cfg
        grep -q '^libretro_directory' /mnt/etc/retroarch.cfg || \
            echo 'libretro_directory = "/usr/lib/libretro"' >> /mnt/etc/retroarch.cfg
    else
        echo 'libretro_directory = "/usr/lib/libretro"' > /mnt/etc/retroarch.cfg
    fi
    echo "inside: $(ls /mnt/usr/lib/libretro/*.so 2>/dev/null | wc -l) libretro cores installed"
fi

mount --bind /dev  /mnt/dev
mount --bind /proc /mnt/proc
mount --bind /sys  /mnt/sys

install -Dm755 /chroot-setup.sh /mnt/tmp/setup.sh
chroot /mnt env USERNAME="$USERNAME" PASSWORD="$PASSWORD" \
                TIER="$TIER" LOOP="$LOOP" BOOTLOADER=none /tmp/setup.sh
rm -f /mnt/tmp/setup.sh

# ── verify by content, not by exit status ───────────────────────────────────
for f in start4.elf fixup4.dat kernel8.img bcm2711-rpi-4-b.dtb config.txt cmdline.txt; do
    [ -s "/mnt/boot/$f" ] || { echo "mkimage: /boot/$f missing from the FAT partition" >&2; exit 1; }
done
# The Pi 5 needs its own device tree; absence is a warning, not a failure, since
# this image is built for a named model.
[ -s /mnt/boot/bcm2712-rpi-5-b.dtb ] || echo "mkimage: note — no Pi 5 device tree in this image"

# ⛔ ONE LINE, and it must name a PARTUUID. This is the check that would have
# caught shipping Void's hardcoded /dev/mmcblk0p2.
[ "$(wc -l < /mnt/boot/cmdline.txt)" = 1 ] || { echo "mkimage: cmdline.txt is not one line" >&2; exit 1; }
grep -q "root=PARTUUID=$PTUUID-02" /mnt/boot/cmdline.txt || {
    echo "mkimage: cmdline.txt does not name the root PARTUUID" >&2; exit 1; }
grep -q 'vc4-kms-v3d' /mnt/boot/config.txt || {
    echo "mkimage: config.txt lost the vc4-kms-v3d overlay — no hardware GL" >&2; exit 1; }

echo "inside: root PARTUUID ${PTUUID}-02, FAT boot partition and config verified"
sync
