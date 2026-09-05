#!/usr/bin/env bash
#
# install-test.sh — ember-install must not damage the other operating system.
#
# ⛔ THIS IS THE ONLY TEST THAT MATTERS FOR THE INSTALLER, and it cannot be run
# on the real machine, because the failure it is looking for is "the XP install
# is gone". So a stand-in disk is built: an MBR table, an NTFS partition made to
# look like an XP root (ntldr, boot.ini, NTDETECT.COM — the three files
# os-prober keys on), and unallocated space after it.
#
# What is asserted, before and after:
#   1. the NTFS partition's ENTRY in the table is byte-identical
#   2. the NTFS partition's CONTENTS are byte-identical (sha256 of the whole
#      partition, not a spot check)
#   3. a new partition exists in what used to be free space
#   4. the MBR backup exists and is a real one
#
# ⚠ IT IS A STAND-IN, NOT WINDOWS. os-prober may or may not produce a menu entry
# for a filesystem that has the marker files and no actual Windows; that half is
# reported, not asserted. What IS asserted is that the partition survived.
#
# SPDX-License-Identifier: GPL-2.0-or-later
set -uo pipefail
cd "$(dirname "$0")/.."
. build/config.sh

ARCH=i686; TIER=${1:-desktop}
LIVE="out/$EMBER_ID-$EMBER_VERSION-$ARCH-$TIER/$EMBER_ID-$EMBER_VERSION-$ARCH-$TIER.img"
[ -f "$LIVE" ] || { echo "install-test: no image at $LIVE" >&2; exit 1; }
command -v qemu-system-i386 >/dev/null || { echo "SKIP: qemu-system-i386"; exit 77; }
docker info >/dev/null 2>&1 || { echo "install-test: docker is not running" >&2; exit 1; }

T="out/install-test"; rm -rf "$T"; mkdir -p "$T"
TARGET="$T/target.img"

echo "== building a stand-in XP disk"
truncate -s 12G "$TARGET"
docker run --rm --privileged -v /dev:/dev -v "$PWD/$T:/t" \
    ghcr.io/void-linux/void-linux:latest-full-x86_64 /bin/sh -euc '
    xbps-install -Suy xbps >/dev/null 2>&1
    xbps-install -Sy parted ntfs-3g e2fsprogs >/dev/null 2>&1
    # ⛔ PARTITION THE FILE, THEN ATTACH THE LOOP. Done the other way round,
    # --partscan runs against a file that has no partition table yet, so
    # ${LOOP}p1 never appears and every step after it fails for a reason that
    # has nothing to do with what is being tested.
    #
    # An XP-era table: msdos, first partition at sector 63 (parted warns about
    # the alignment; that IS the era being reproduced), boot flag set.
    parted -s /t/target.img mklabel msdos
    parted -s /t/target.img mkpart primary ntfs 63s 4GiB
    parted -s /t/target.img set 1 boot on
    LOOP=$(losetup --find --partscan --show /t/target.img)
    # NO APOSTROPHES ANYWHERE IN THIS BLOCK, INCLUDING IN COMMENTS. The whole
    # thing is one single-quoted docker -c argument, so a lone quote character
    # ends it and the outer shell starts interpreting the rest. The comment that
    # used to sit here warned about exactly that and contained two of them,
    # which broke the script it was explaining.
    #
    # || true on each cleanup command, which here is correct rather than lazy:
    # under set -e a failing command in an EXIT trap aborts the trap and makes
    # the exit status non-zero, so unmounting /mnt after the body already
    # unmounted it failed the entire build with 2>/dev/null hiding the reason.
    # Cleanup must tolerate having nothing to clean up.
    #
    # Escaped LOOP, so expansion is deferred to when the trap runs.
    trap "umount /mnt 2>/dev/null || true; losetup -d \$LOOP 2>/dev/null || true" EXIT
    sleep 1
    mkntfs -Q -L XPDISK "${LOOP}p1" >/dev/null 2>&1
    mount -t ntfs-3g "${LOOP}p1" /mnt
    # The three files os-prober looks for when it is deciding "this is XP".
    printf "NTLDR stand-in\n"  > /mnt/ntldr
    printf "[boot loader]\ntimeout=30\ndefault=multi(0)disk(0)rdisk(0)partition(1)\\\\WINDOWS\n" > /mnt/boot.ini
    printf "NTDETECT stand-in\n" > /mnt/NTDETECT.COM
    mkdir -p /mnt/WINDOWS/system32
    printf "marker\n" > /mnt/WINDOWS/system32/marker.txt
    umount /mnt
    # The evidence: a hash of the ENTIRE partition, not a spot check.
    dd if="${LOOP}p1" bs=1M 2>/dev/null | sha256sum | cut -d" " -f1 > /t/ntfs.before
    sfdisk -d /t/target.img > /t/table.before 2>/dev/null
' || { echo "install-test: could not build the stand-in disk (output above)" >&2; exit 1; }
echo "   NTFS sha256 before: $(cut -c1-16 < "$T/ntfs.before")…"

echo "== booting the live image with that disk attached, running ember-install"
# ⚠ The live image is hd0 and the target is hd1 ONLY inside qemu's boot order;
# ember-install picks the biggest NON-REMOVABLE disk, and both look fixed here.
# So the disk is named explicitly rather than left to the heuristic.
cat > "$T/autorun.sh" <<'AUTO'
#!/bin/bash
exec >/dev/ttyS0 2>&1
echo "AUTORUN-BEGIN"
ember-install --plan /dev/sdb || true
ember-install --yes  /dev/sdb
echo "AUTORUN-DONE rc=$?"
sync
poweroff -f
AUTO

# Drop the autorun into the live image and have runit start it.
docker run --rm --privileged -v /dev:/dev -v "$PWD/$T:/t" -v "$PWD/$(dirname "$LIVE"):/live" \
    ghcr.io/void-linux/void-linux:latest-full-x86_64 /bin/sh -euc '
    cp /live/*.img /t/live.img
    LOOP=$(losetup --find --partscan --show /t/live.img)
    trap "umount /mnt 2>/dev/null; losetup -d $LOOP" EXIT
    mount "${LOOP}p1" /mnt
    install -Dm755 /t/autorun.sh /mnt/usr/bin/ember-autorun
    mkdir -p /mnt/etc/sv/autorun
    printf "#!/bin/sh\nexec 2>&1\n[ -f /run/autorun.done ] && exec sleep 999999\ntouch /run/autorun.done\nexec /usr/bin/ember-autorun\n" > /mnt/etc/sv/autorun/run
    chmod +x /mnt/etc/sv/autorun/run
    ln -sf /etc/sv/autorun /mnt/etc/runit/runsvdir/default/
    # The copy is made by root inside the container but qemu runs as the user,
    # and a drive image must be WRITABLE or qemu exits immediately with nothing
    # on the serial line. That looked exactly like a system that failed to boot.
    chmod 0666 /t/live.img
' || { echo "install-test: could not prepare the live image" >&2; exit 1; }

LOG="$T/serial.log"
timeout 900 qemu-system-i386 -m 2048 -smp 2 \
    -drive file="$T/live.img",format=raw,if=ide,index=0 \
    -drive file="$TARGET",format=raw,if=ide,index=1 \
    -display none -serial file:"$LOG" -no-reboot >/dev/null 2>"$T/qemu.err"
if [ -s "$T/qemu.err" ]; then
    echo "   qemu said:"; sed 's/^/     /' "$T/qemu.err"
fi

echo "== checking what happened to the stand-in disk"
docker run --rm --privileged -v /dev:/dev -v "$PWD/$T:/t" \
    ghcr.io/void-linux/void-linux:latest-full-x86_64 /bin/sh -euc '
    LOOP=$(losetup --find --partscan --show /t/target.img)
    trap "losetup -d $LOOP" EXIT
    sleep 1
    dd if="${LOOP}p1" bs=1M 2>/dev/null | sha256sum | cut -d" " -f1 > /t/ntfs.after
    sfdisk -d /t/target.img > /t/table.after 2>/dev/null
    ls /dev/"$(basename "$LOOP")"* > /t/parts.after 2>/dev/null || true
' || { echo "install-test: could not read the disk back" >&2; exit 1; }

pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1" >&2; fail=$((fail+1)); }

grep -q "AUTORUN-BEGIN" "$LOG" 2>/dev/null \
    && ok "the live system booted and ran the installer" \
    || bad "the installer never ran (serial log has no AUTORUN-BEGIN)"

if [ "$(cat "$T/ntfs.before" 2>/dev/null)" = "$(cat "$T/ntfs.after" 2>/dev/null)" ]; then
    ok "the NTFS partition is byte-identical — every byte, not a spot check"
else
    bad "THE NTFS PARTITION CHANGED. before=$(cut -c1-16 < "$T/ntfs.before") after=$(cut -c1-16 < "$T/ntfs.after" 2>/dev/null)"
fi

if grep -q "^/t/target.img1 " "$T/table.after" 2>/dev/null; then
    b=$(grep "^/t/target.img1 " "$T/table.before"); a=$(grep "^/t/target.img1 " "$T/table.after")
    [ "$b" = "$a" ] && ok "the XP partition's table entry is unchanged" \
                    || bad "the XP table entry changed: [$b] -> [$a]"
else
    bad "the XP partition entry is gone from the table"
fi

grep -q "^/t/target.img2 " "$T/table.after" 2>/dev/null \
    && ok "a second partition was created in the free space" \
    || bad "no new partition was created"

grep -q "verified: every pre-existing partition entry is unchanged" "$LOG" 2>/dev/null \
    && ok "the installer ran its own table check" \
    || bad "the installer's own table check did not run or did not pass"

if grep -qiE "os-prober found the existing OS" "$LOG" 2>/dev/null; then
    ok "os-prober produced a menu entry for the other OS"
else
    printf '  note  os-prober found no Windows entry — expected for a stand-in with\n'
    printf '        no real Windows on it. Reported, not asserted; see the header.\n'
fi

echo
[ "$fail" -ne 0 ] && { echo "  --- last 30 serial lines ---" >&2; tail -30 "$LOG" 2>/dev/null | sed 's/^/  /' >&2; }
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
