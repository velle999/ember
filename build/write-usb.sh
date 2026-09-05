#!/usr/bin/env bash
#
# write-usb.sh — put an image on a USB stick, and refuse every way of getting
# it wrong that has actually happened.
#
# ⛔ dd of=/dev/sdX IS A LOADED GUN AND THE SAFETY CATCH IS SPELLING. Three ways
# it goes wrong, all of them silent:
#
#   1. THE DEVICE NODE DOES NOT EXIST. Device letters are not stable — a stick
#      replugged, or enumerated after a reboot, moves from sde to sdd. dd then
#      CREATES A REGULAR FILE at /dev/sde, /dev is a RAM filesystem, and 5 GB
#      goes into memory at 3.1 GB/s while reporting complete success. This
#      happened. It is the reason this script exists.
#   2. THE LETTER NOW BELONGS TO SOMETHING ELSE — a data disk, and the write
#      lands on it. Nothing warns you.
#   3. THE STICK IS MOUNTED, so the kernel writes cached blocks over the image
#      afterwards and the result boots erratically or not at all.
#
# So the target is addressed by /dev/disk/by-id where possible, must be a real
# block device, must be REMOVABLE, and must not be mounted.
#
# Usage:
#   build/write-usb.sh                     # find the one removable disk
#   build/write-usb.sh /dev/disk/by-id/... # name it explicitly
#   build/write-usb.sh --list              # show candidates and stop
#
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail
cd "$(dirname "$0")/.."
. build/config.sh

ARCH=${ARCH:-i686}; TIER=${TIER:-desktop}
IMG="out/$EMBER_ID-$EMBER_VERSION-$ARCH-$TIER/$EMBER_ID-$EMBER_VERSION-$ARCH-$TIER.img"

TARGET=""; LIST=0
for a in "$@"; do
    case "$a" in
        --list|-l) LIST=1 ;;
        /dev/*) TARGET=$a ;;
        *.img) IMG=$a ;;
        *) echo "write-usb: unknown argument $a" >&2; exit 2 ;;
    esac
done
[ -f "$IMG" ] || { echo "write-usb: no image at $IMG" >&2; exit 1; }

# Candidates: block devices that are disks AND removable.
mapfile -t CANDS < <(lsblk -dnro NAME,RM,TYPE | awk '$2=="1" && $3=="disk" {print $1}')

if [ "$LIST" = 1 ] || [ -z "$TARGET" ]; then
    echo "removable disks:"
    for c in "${CANDS[@]:-}"; do
        [ -n "$c" ] || continue
        byid=$(find /dev/disk/by-id -lname "*/$c" 2>/dev/null | head -1)
        printf '   /dev/%-5s %-8s %s\n     by-id: %s\n' \
            "$c" "$(lsblk -dno SIZE "/dev/$c")" "$(lsblk -dno MODEL "/dev/$c")" "${byid:-none}"
    done
    [ "$LIST" = 1 ] && exit 0
fi

if [ -z "$TARGET" ]; then
    [ "${#CANDS[@]}" -eq 1 ] || {
        echo "write-usb: ${#CANDS[@]} removable disks — name one explicitly (preferably its by-id path)" >&2
        exit 1; }
    byid=$(find /dev/disk/by-id -lname "*/${CANDS[0]}" 2>/dev/null | head -1)
    TARGET=${byid:-/dev/${CANDS[0]}}
fi

# ── the three refusals ──────────────────────────────────────────────────────

# ⛔ 1. A REAL BLOCK DEVICE. This is the check that would have caught the 5 GB
# written into RAM: a path that does not exist is not an error to dd, it is a
# new file, and /dev is memory.
if [ ! -b "$TARGET" ]; then
    echo "write-usb: $TARGET is not a block device." >&2
    if [ -f "$TARGET" ]; then
        echo "           It is a REGULAR FILE — almost certainly created by an" >&2
        echo "           earlier dd to a device letter that had moved. If it is" >&2
        echo "           under /dev it is occupying that much RAM; delete it." >&2
    else
        echo "           It does not exist. Device letters change between replugs;" >&2
        echo "           use the /dev/disk/by-id path, which does not." >&2
    fi
    exit 1
fi

REAL=$(readlink -f "$TARGET")
NAME=$(basename "$REAL")

# ⛔ 2. REMOVABLE. Refuses to write over a fixed disk however it was named.
[ "$(lsblk -dno RM "$REAL")" = 1 ] || {
    echo "write-usb: $REAL is NOT removable — refusing. This is a fixed disk." >&2
    lsblk -dno NAME,SIZE,MODEL "$REAL" | sed 's/^/           /' >&2
    exit 1; }

# ⛔ 3. NOT MOUNTED, anywhere, including its partitions.
mounted=$(lsblk -nro MOUNTPOINTS "$REAL" | grep -v '^$' || true)
if [ -n "$mounted" ]; then
    echo "write-usb: $REAL has mounted partitions:" >&2
    printf '           %s\n' $mounted >&2
    echo "           Unmount them first:  sudo umount /dev/${NAME}*" >&2
    exit 1
fi

SIZE=$(lsblk -dno SIZE "$REAL"); MODEL=$(lsblk -dno MODEL "$REAL")
IMGSZ=$(stat -c%s "$IMG"); DEVSZ=$(blockdev --getsize64 "$REAL")
[ "$IMGSZ" -le "$DEVSZ" ] || {
    echo "write-usb: the image ($((IMGSZ/1024/1024)) MiB) is larger than $REAL ($((DEVSZ/1024/1024)) MiB)" >&2
    exit 1; }

cat <<PLAN

   image:  $IMG  ($((IMGSZ/1024/1024)) MiB)
   target: $TARGET
           → $REAL   $SIZE  $MODEL

   EVERYTHING ON THAT DEVICE WILL BE DESTROYED.

PLAN
lsblk -o NAME,SIZE,FSTYPE,LABEL "$REAL" | sed 's/^/   /'
echo
printf '   Type ERASE to proceed: '
read -r reply
[ "$reply" = ERASE ] || { echo "   aborted."; exit 1; }

# ⚠ A USB 2.0 stick writes at tens of MB/s. Anything in the hundreds means the
# data is not reaching the device, so the rate is reported back at the end for
# the operator to sanity-check rather than buried in dd's own output.
start=$(date +%s)
dd if="$IMG" of="$REAL" bs=4M status=progress oflag=direct conv=fsync
sync
elapsed=$(( $(date +%s) - start )); [ "$elapsed" -lt 1 ] && elapsed=1
rate=$(( IMGSZ / elapsed / 1024 / 1024 ))

echo
echo "   wrote $((IMGSZ/1024/1024)) MiB in ${elapsed}s — ${rate} MB/s"
if [ "$rate" -gt 200 ]; then
    echo "   ⚠ THAT IS TOO FAST FOR A USB STICK. The data probably did not reach" >&2
    echo "     the device. Check the target and try again." >&2
    exit 1
fi
echo "   verifying the first 64 MiB reads back identical..."
cmp -n $((64*1024*1024)) "$IMG" "$REAL" && echo "   verified."
lsblk -o NAME,SIZE,FSTYPE,LABEL "$REAL" | sed 's/^/   /'
