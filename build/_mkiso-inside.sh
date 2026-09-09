#!/bin/sh
#
# _mkiso-inside.sh — the container half of mkiso.sh. Split out for the same
# reason as _image-inside.sh: nested quoting is where the bugs live.
#
# ⚠ POSIX sh. The Void container ships dash and no bash.
#
# SPDX-License-Identifier: GPL-2.0-or-later
set -eu

IMG="/out/$IMGNAME"
BUILD=/out/.isobuild
# ⛔ THE OVERLAY SCRATCH MUST NOT LIVE UNDER $BUILD -- $BUILD is exactly what
# xorriso packages, so upper/ and work/ ended up INSIDE the ISO.
WORK=/out/.isowork
ISO="/out/$ISONAME"
LOWER=/mnt/img
LIVE=/out/.isotree

xbps-install -Suy xbps >/dev/null 2>&1 || true
# ⚠ libgcc explicitly: mksquashfs is threaded and dies with "libgcc_s.so.1 must
# be installed for pthread_exit to work" without it — after doing all the
# compression work, so the failure costs the whole slow step.
xbps-install -Sy squashfs-tools xorriso syslinux dracut libgcc util-linux eudev >/dev/null 2>&1
for t in mksquashfs xorriso losetup partx; do
    command -v "$t" >/dev/null || { echo "mkiso: $t missing after install" >&2; exit 1; }
done

rm -rf "$BUILD" "$WORK" "$LIVE"; mkdir -p "$BUILD/isolinux" "$BUILD/LiveOS" "$WORK"
mkdir -p "$LOWER" "$LIVE"

# ── the source tree is the FINISHED .img, not out/rootfs ────────────────────
#
# ⛔ out/rootfs IS NOT AN EMBER SYSTEM AND SQUASHING IT PRODUCES A USELESS ISO.
# It is the package tree mkrootfs.sh downloads, before any configuration. The
# things that make it Ember are applied afterwards and only on the image path:
# _chroot-setup.sh creates the ember account, sets both passwords and enables
# elogind/polkitd/NetworkManager/lightdm, and _image-inside.sh installs
# ember-install, ember-swap, ember-zram, ember-gpu, the X modesetting config and
# the cores.
#
# The first ISO was built from out/rootfs and booted to an agetty with no
# lightdm, no ember account — "won't accept ember ember", because the account did
# not exist — and no ember-install, so it could not have installed anything even
# if you got in. ⚠ IT PASSED EVERY STRUCTURAL CHECK. A well-formed ISO of an
# unconfigured tree is still a well-formed ISO; only booting it says otherwise.
#
# ⛔ SO DO NOT RE-IMPLEMENT THE SETUP HERE. A second copy of that logic is a
# second thing to forget to update. The .img is the tree that is known to boot;
# this squashes exactly it.
[ -f "$IMG" ] || { echo "mkiso: no image at $IMG" >&2; exit 1; }

LOOP=$(losetup --find --show -P "$IMG")

# ⛔ THE PARTITION NODE DOES NOT EXIST THE INSTANT losetup RETURNS. -P asks the
# kernel to scan the partition table, udev then creates ${LOOP}p1, and mounting
# in between fails with
#
#     mount: special device /dev/loop0p1 does not exist
#
# It is a race, so it passes most of the time and fails on a loaded machine --
# which is exactly the build that matters. Wait for the node instead of assuming
# it, and nudge the scan if it has not happened.
i=0
while [ ! -b "${LOOP}p1" ]; do
    i=$((i + 1))
    [ "$i" -gt 40 ] && { echo "mkiso: ${LOOP}p1 never appeared" >&2; losetup -d "$LOOP"; exit 1; }
    [ "$i" = 5 ] && { partx -a "$LOOP" 2>/dev/null || partprobe "$LOOP" 2>/dev/null || true; }
    command -v udevadm >/dev/null && udevadm settle --timeout=2 2>/dev/null || sleep 0.25
done

mount -o ro "${LOOP}p1" "$LOWER"

cleanup() {
    umount "$LIVE/var/tmp/ember-dracut" 2>/dev/null || true
    for d in dev proc sys; do umount "$LIVE/$d" 2>/dev/null || true; done
    umount "$LOWER" 2>/dev/null || true
    [ -n "${LOOP:-}" ] && losetup -d "$LOOP" 2>/dev/null || true
}
trap cleanup EXIT

# ⛔ A REAL COPY, NOT AN OVERLAY. An overlayfs merge of the image was the obvious
# way to get a writable tree without touching the .img, and dracut cannot build
# an initramfs on one: dracut-install fails on EVERY source file --
#
#     dracut-install: ERROR: installing '/etc/ld.so.conf'
#     dracut-install: ERROR: installing '.../modules.order'
#
# -- then exits 0 and writes a 1308-byte image that is nothing but the
# early-microcode stub. The kernel finds no /init in it, falls through to
# mounting the root device itself and panics:
#
#     Kernel panic: VFS: Unable to mount root fs on "live:CDLABEL=EMBER"
#
# ⚠ Moving dracut's --tmpdir off the overlay does NOT fix it; the failing side
# is reading the source tree, not writing the staging tree. A plain directory
# works, which is what this project's earlier ISOs were built from.
#
# ⚠ It costs a 5.3 GB copy and the disk space to hold it. That is the price of
# an initramfs that exists.
echo "inside: copying the tree out of $IMGNAME (~5 GB)"
mkdir -p "$LIVE"
cp -a "$LOWER/." "$LIVE/"
umount "$LOWER"; losetup -d "$LOOP"; LOOP=""
echo "inside: tree copied"

# ── the two things a live medium needs changed ──────────────────────────────
#
# ⛔ fstab NAMES A UUID THAT DOES NOT EXIST HERE. It is the root partition of
# the .img; on the live medium root is the squashfs plus a RAM overlay. Left in
# place it is a mount/fsck target that cannot be satisfied.
: > "$LIVE/etc/fstab"
printf '# Live medium: root is a squashfs with a RAM overlay, mounted by dracut.\n' \
    >> "$LIVE/etc/fstab"

# ⚠ ember-expand-root is left ENABLED on purpose — it reads the root device,
# finds it is not a partition it can grow, notes that and exits 0. Same for
# ember-swap: a swapfile cannot be made on a read-only root, it declines, and
# ember-zram picks it up. Both are the designed fallbacks, already tested.

# ── the initramfs, built INSIDE the tree ────────────────────────────────────
#
# ⛔ IT MUST BE BUILT IN THE CHROOT, NOT THE CONTAINER. dracut bakes in modules
# for one specific kernel, and the kernel that matters is the patched linux6.18
# in that tree — the container has no kernel at all.
KVER=$(ls "$LIVE/lib/modules" | head -1)
[ -n "$KVER" ] || { echo "mkiso: no kernel modules in the image" >&2; exit 1; }
echo "inside: kernel $KVER"

for d in dev proc sys; do mount --bind "/$d" "$LIVE/$d"; done

# ⛔ dracut's STAGING DIRECTORY MUST NOT BE ON THE OVERLAY. dracut-install
# copies with operations overlayfs does not support, and every single file
# failed:
#
#     dracut-install: ERROR: installing '/etc/ld.so.conf'
#     dracut-install: ERROR: installing '/usr/lib/.../modules.order'
#
# dracut then exits 0 and writes a 1308-byte image containing nothing but the
# early-microcode stub. Pointing --tmpdir at a plain bind mount puts the staging
# tree on real filesystem and leaves only the finished image on the overlay.
mkdir -p "$WORK/dtmp" "$LIVE/var/tmp/ember-dracut"
mount --bind "$WORK/dtmp" "$LIVE/var/tmp/ember-dracut"

# ⚠ --no-hostonly, or the initramfs carries THIS machine's storage drivers and
# not the target's — the same trap _chroot-setup.sh documents for the .img.
# ⚠ dmsquash-live is what turns a read-only squashfs into a writable root; and
# it pulls in the dm/overlay plumbing. Without it the kernel finds a squashfs
# it cannot write to and stops at a dracut shell.
# ⛔ DO NOT SEND dracut's OUTPUT TO /dev/null. It exited 0 having written a
# 1308-byte file -- the early-microcode stub and nothing else -- and with the
# output discarded there was no sign of it. The kernel then found an initrd with
# no /init, fell through to mounting the root device itself, and panicked with
#     VFS: Unable to mount root fs on "live:CDLABEL=EMBER"
DLOG=/out/dracut-live.log
chroot "$LIVE" /usr/bin/env dracut --force --no-hostonly \
    --tmpdir /var/tmp/ember-dracut \
    --add "dmsquash-live" \
    --add-drivers "squashfs loop overlay isofs sr_mod cdrom" \
    "/boot/initramfs-live-$KVER.img" "$KVER" >"$DLOG" 2>&1 || {
    echo "mkiso: dracut failed to build the live initramfs; last lines:" >&2
    tail -25 "$DLOG" >&2; exit 1; }

# ⛔ AND CHECK WHAT IT PRODUCED, NOT THAT IT PRODUCED SOMETHING. An exit status
# of 0 and a file that exists were both true of the initramfs that panicked.
IRD="$LIVE/boot/initramfs-live-$KVER.img"
sz=$(stat -c %s "$IRD" 2>/dev/null || echo 0)
if [ "$sz" -lt 4000000 ]; then
    echo "mkiso: the live initramfs is only $sz bytes -- it is not a real image" >&2
    echo "dracut said:" >&2; tail -25 "$DLOG" >&2
    exit 1
fi
# ⚠ Size alone would pass an initramfs with no live-boot support at all, which
# boots to a dracut shell rather than a desktop.
if ! lsinitrd "$IRD" 2>/dev/null | grep -q dmsquash; then
    echo "mkiso: the live initramfs carries no dmsquash-live hooks" >&2
    exit 1
fi
echo "inside: live initramfs $((sz / 1024 / 1024)) MB, dmsquash-live present"

cp "$LIVE/boot/vmlinuz-$KVER" "$BUILD/isolinux/vmlinuz"
cp "$LIVE/boot/initramfs-live-$KVER.img" "$BUILD/isolinux/initrd.img"
rm -f "$LIVE/boot/initramfs-live-$KVER.img"
umount "$LIVE/var/tmp/ember-dracut" 2>/dev/null || true
for d in dev proc sys; do umount "$LIVE/$d"; done
echo "inside: kernel + live initramfs staged"

# ── prove the tree is a configured Ember before spending 20 minutes on it ───
#
# ⛔ THIS IS THE CHECK THAT WAS MISSING. Every one of these was absent from the
# first ISO and nothing noticed. They are cheap; the squash is not.
fail=0
grep -q '^ember:' "$LIVE/etc/passwd" || { echo "mkiso: no ember account" >&2; fail=1; }
case $(awk -F: '$1=="ember"{print $2}' "$LIVE/etc/shadow") in
    \$6\$*) : ;;
    *) echo "mkiso: ember has no usable password hash" >&2; fail=1 ;;
esac
# ⛔ -L AND NOT -e. Every entry here is a SYMLINK to an ABSOLUTE path
# (/etc/sv/lightdm). -e follows it, and the target is resolved against the
# CONTAINER's root, not this mounted tree -- where /etc/sv does not exist. So
# -e reports every enabled service as missing. Testing the link itself is the
# only correct check on a tree you are looking at from outside.
for s in lightdm elogind polkitd dbus; do
    [ -L "$LIVE/etc/runit/runsvdir/default/$s" ] || [ -e "$LIVE/etc/runit/runsvdir/default/$s" ] || {
        echo "mkiso: service $s is not enabled" >&2; fail=1; }
done
for f in usr/bin/ember-install usr/bin/ember-swap usr/bin/ember-zram \
         etc/X11/xorg.conf.d/20-modesetting.conf \
         usr/bin/ember-gpu usr/bin/ember-gpu-detect usr/bin/ember-gpu-apply \
         usr/libexec/ember-xserver usr/share/ember/nvidia304-supported.ids \
         etc/runit/core-services/08-ember-gpu.sh \
         etc/X11/xinit/xinitrc.d/50-ember-gl.sh; do
    [ -e "$LIVE/$f" ] || [ -L "$LIVE/$f" ] || { echo "mkiso: missing $f" >&2; fail=1; }
done
# ⛔ Without this line lightdm starts the SYSTEM X server whatever the card is,
# which on a 304 machine is a login loop -- and the seatless-session bug that
# made polkit demand a password for reboot comes straight back.
grep -q '^xserver-command=/usr/libexec/ember-xserver' \
     "$LIVE/etc/lightdm/lightdm.conf" 2>/dev/null || {
    echo "mkiso: lightdm is not starting X through ember-xserver" >&2; fail=1; }
for d in proc sys dev; do
    [ -d "$LIVE/$d" ] || { echo "mkiso: mount point /$d is missing" >&2; fail=1; }
done
[ "$fail" = 0 ] || { echo "mkiso: the source tree is not a configured Ember" >&2; exit 1; }
echo "inside: tree verified — account, services, installer, mount points"

# ── the tree, squashed ──────────────────────────────────────────────────────
#
# ⛔ NOTHING IS EXCLUDED, AND THAT IS DELIBERATE. An earlier version passed
# `-e proc sys dev/pts dev/shm`, which does not exclude their CONTENTS — it
# excludes the DIRECTORIES. The ISO then booted all the way to runit stage 2
# with no /proc to mount onto:
#
#     cannot create /proc/sys/kernel/hostname: Directory nonexistent
#     cat: /proc/cmdline: No such file or directory
#
# and every sysctl in 05-misc.sh failed. ⚠ Only a real boot showed this — the
# ISO passed every structural check with the directories missing.
echo "inside: squashing the tree (this is the slow part)"
mksquashfs "$LIVE" "$BUILD/LiveOS/squashfs.img" \
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

cleanup; trap - EXIT
rm -rf "$BUILD" "$WORK" "$LIVE"
echo "inside: iso written, $(du -h "$ISO" | cut -f1)"
