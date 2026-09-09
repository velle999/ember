#!/bin/sh
#
# _mkiso-inside.sh — the container half of mkiso.sh. Split out for the same
# reason as _image-inside.sh: nested quoting is where the bugs live.
#
# ⚠ POSIX sh. The Void container ships dash and no bash.
#
# SPDX-License-Identifier: GPL-2.0-or-later
set -eu

ROOT=/out/rootfs
BUILD=/out/.isobuild
ISO="/out/$ISONAME"

xbps-install -Suy xbps >/dev/null 2>&1 || true
# ⚠ libgcc explicitly: mksquashfs is threaded and dies with "libgcc_s.so.1 must
# be installed for pthread_exit to work" without it — after doing all the
# compression work, so the failure costs the whole slow step.
xbps-install -Sy squashfs-tools xorriso syslinux dracut libgcc >/dev/null 2>&1
for t in mksquashfs xorriso; do
    command -v "$t" >/dev/null || { echo "mkiso: $t missing after install" >&2; exit 1; }
done

rm -rf "$BUILD"; mkdir -p "$BUILD/isolinux" "$BUILD/LiveOS"

# ── the initramfs, built INSIDE the rootfs ──────────────────────────────────
#
# ⛔ IT MUST BE BUILT IN THE CHROOT, NOT THE CONTAINER. dracut bakes in modules
# for one specific kernel, and the kernel that matters is the rootfs's patched
# linux6.18 — the container has no kernel at all. Building it outside produces
# an initramfs for the wrong kernel, or for none.
KVER=$(ls "$ROOT/lib/modules" | head -1)
[ -n "$KVER" ] || { echo "mkiso: no kernel modules in the rootfs" >&2; exit 1; }
echo "inside: kernel $KVER"

for d in dev proc sys; do mount --bind "/$d" "$ROOT/$d"; done
cleanup() { for d in dev proc sys; do umount "$ROOT/$d" 2>/dev/null || true; done; }
trap cleanup EXIT

# ⚠ --no-hostonly, or the initramfs carries THIS machine's storage drivers and
# not the target's — the same trap _chroot-setup.sh documents for the .img.
# ⚠ dmsquash-live is what turns a read-only squashfs into a writable root; and
# it pulls in the dm/overlay plumbing. Without it the kernel finds a squashfs
# it cannot write to and stops at a dracut shell.
chroot "$ROOT" /usr/bin/env dracut --force --no-hostonly \
    --add "dmsquash-live" \
    --add-drivers "squashfs loop overlay isofs sr_mod cdrom" \
    "/boot/initramfs-live-$KVER.img" "$KVER" >/dev/null 2>&1 || {
    echo "mkiso: dracut failed to build the live initramfs" >&2; exit 1; }

cp "$ROOT/boot/vmlinuz-$KVER" "$BUILD/isolinux/vmlinuz"
cp "$ROOT/boot/initramfs-live-$KVER.img" "$BUILD/isolinux/initrd.img"
rm -f "$ROOT/boot/initramfs-live-$KVER.img"
cleanup; trap - EXIT
echo "inside: kernel + live initramfs staged"

# ── the rootfs, squashed ────────────────────────────────────────────────────
#
# ⛔ NOTHING IS EXCLUDED, AND THAT IS DELIBERATE. An earlier version passed
# `-e proc sys dev/pts dev/shm`, which does not exclude their CONTENTS — it
# excludes the DIRECTORIES. The ISO then booted all the way to runit stage 2
# with no /proc to mount onto:
#
#     cannot create /proc/sys/kernel/hostname: Directory nonexistent
#     cat: /proc/cmdline: No such file or directory
#
# and every sysctl in 05-misc.sh failed. In the built rootfs /proc and /sys are
# empty and /dev holds one node, so there was never anything to exclude; the
# option only destroyed the mount points. ⚠ Only a real boot showed this — the
# ISO passed every structural check with the directories missing.
echo "inside: squashing the rootfs (this is the slow part)"
mksquashfs "$ROOT" "$BUILD/LiveOS/squashfs.img" \
    -comp xz -b 1M -no-progress >/dev/null

# ── isolinux, because this has to boot a 2003 BIOS ──────────────────────────
#
# ⛔ ISOLINUX AND NOT GRUB. The whole reason this ISO exists is boards that
# cannot boot USB, which are the same boards with the oldest BIOSes. isolinux is
# the most conservative El Torito loader there is; grub-mkrescue targets a
# richer firmware than these machines have.
for f in isolinux.bin ldlinux.c32 libcom32.c32 libutil.c32 vesamenu.c32; do
    find / -name "$f" -path "*syslinux*" -exec cp {} "$BUILD/isolinux/" \; -quit
done
[ -f "$BUILD/isolinux/isolinux.bin" ] || { echo "mkiso: isolinux.bin not found" >&2; exit 1; }

# ⚠ THE BOOT LINE CARRIES THE SAME GRAPHICS PARAMETERS AS THE INSTALLED SYSTEM.
# They are not optional here either: without fence_sema=0 the desktop dies
# sixteen seconds into GL load, and this medium runs the same desktop.
# ⚠ rd.live.overlay.size is in MB and comes out of RAM — see mkiso.sh.
CMDLINE="root=live:CDLABEL=EMBER rd.live.image rd.overlay rd.live.overlay.size=$OVERLAY_MB"
GFX="nouveau.vram_pushbuf=0 nouveau.accel_move=1 nouveau.fence_sema=0 ttm.dma32_pages_limit=65536"
CONSOLE="loglevel=4 console=tty0 console=ttyS0,115200"

cat > "$BUILD/isolinux/isolinux.cfg" <<CFG
UI vesamenu.c32
PROMPT 0
TIMEOUT 100
MENU TITLE $EMBER_NAME $EMBER_VERSION

LABEL ember
    MENU LABEL Try or install $EMBER_NAME
    MENU DEFAULT
    KERNEL vmlinuz
    APPEND initrd=initrd.img $CMDLINE $GFX $CONSOLE

LABEL embersafe
    MENU LABEL $EMBER_NAME with no acceleration
    KERNEL vmlinuz
    APPEND initrd=initrd.img $CMDLINE nomodeset $CONSOLE
CFG

# ── the ISO itself ──────────────────────────────────────────────────────────
#
# ⚠ -isohybrid-mbr makes the SAME file work written to a USB stick with dd, so
# one artefact serves both media. The MBR template comes from syslinux.
MBR=$(find / -name isohdpfx.bin -print -quit 2>/dev/null || true)
xorriso -as mkisofs \
    -o "$ISO" \
    -V EMBER \
    -J -r \
    -b isolinux/isolinux.bin \
    -c isolinux/boot.cat \
    -no-emul-boot -boot-load-size 4 -boot-info-table \
    ${MBR:+-isohybrid-mbr "$MBR"} \
    "$BUILD" >/dev/null 2>&1 || { echo "mkiso: xorriso failed" >&2; exit 1; }

rm -rf "$BUILD"
echo "inside: iso written, $(du -h "$ISO" | cut -f1)"
