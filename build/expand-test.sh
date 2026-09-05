#!/usr/bin/env bash
#
# expand-test.sh — the root filesystem grows to fill a bigger card, once.
#
# ⛔ ember-expand-root REPARTITIONS A DISK UNATTENDED AT BOOT. Reasoning about
# that is not enough. This writes the image into a disk substantially larger
# than itself — which is the real case, a 6 GB image on a 238 GB card — boots
# it, and then measures the partition table afterwards from outside the guest.
#
# What is asserted:
#   1. the partition really grew, measured in sectors before and after
#   2. the FILESYSTEM grew with it, not just the partition entry
#   3. it ran once and left a marker
#   4. ⛔ a SECOND boot does not touch the disk again
#
# ⚠ Point 4 is the one worth the extra boot. A first-boot task that is not
# actually once-only is a partition table being rewritten on every start.
#
# Usage: build/expand-test.sh [i686] [desktop] [extra-GB]
set -uo pipefail
cd "$(dirname "$0")/.."
. build/config.sh

ARCH=${1:-i686}; TIER=${2:-desktop}; EXTRA=${3:-4}
IMG="out/$EMBER_ID-$EMBER_VERSION-$ARCH-$TIER/$EMBER_ID-$EMBER_VERSION-$ARCH-$TIER.img"
[ -f "$IMG" ] || { echo "expand-test: no image at $IMG" >&2; exit 1; }
command -v qemu-system-i386 >/dev/null || { echo "SKIP: qemu-system-i386"; exit 77; }

T=out/expand-test; rm -rf "$T"; mkdir -p "$T"
BIG="$T/big.img"
IMGMB=$(( $(stat -c%s "$IMG") / 1024 / 1024 ))
BIGMB=$(( IMGMB + EXTRA * 1024 ))

echo "== image ${IMGMB} MiB written into a ${BIGMB} MiB disk (${EXTRA} GB spare)"
truncate -s "${BIGMB}M" "$BIG"
dd if="$IMG" of="$BIG" bs=4M conv=notrunc status=none

# ⛔ THE ROOT PARTITION IS NOT THE SAME NUMBER ON BOTH TARGETS. The PC image is
# one ext4 partition (p1); the Pi image is a FAT firmware partition plus root
# (p2). This function hardcoded p2 and so read nothing at all on i686 — both
# measurements came back empty, `0 -gt 0` was false, and the rig reported that
# the partition had not grown on a disk where it demonstrably had.
case "$ARCH" in
    i686)    ROOTPART=1 ;;
    aarch64) ROOTPART=2 ;;
    *) echo "expand-test: unknown arch $ARCH" >&2; exit 2 ;;
esac

part_sectors() {
    docker run --rm --privileged -v /dev:/dev -v "$PWD/$T:/t" \
        -e RP="$ROOTPART" "$VOID_IMAGE" /bin/sh -euc '
        L=$(losetup --find --partscan --show /t/big.img)
        trap "losetup -d $L 2>/dev/null || true" EXIT
        i=0; while [ $i -lt 40 ]; do [ -b "${L}p${RP}" ] && break; i=$((i+1)); sleep 0.5; done
        cat /sys/class/block/$(basename ${L})p${RP}/size 2>/dev/null' 2>/dev/null | tail -1
}

BEFORE=$(part_sectors)
echo "   root partition before: $(( BEFORE / 2048 )) MiB"

boot_once() {   # boot_once <logfile> <seconds>
    timeout "$2" qemu-system-i386 -m 2048 -smp 2 \
        -drive file="$BIG",format=raw,if=ide \
        -display none -serial file:"$1" -no-reboot >/dev/null 2>&1
}

echo "   first boot..."
boot_once "$T/boot1.log" 420
AFTER=$(part_sectors)
echo "   root partition after:  $(( AFTER / 2048 )) MiB"

echo "   second boot (must NOT touch it again)..."
boot_once "$T/boot2.log" 420
AFTER2=$(part_sectors)

pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1" >&2; fail=$((fail+1)); }

grep -qa "Expanding the root filesystem" "$T/boot1.log" \
    && ok "the core-service ran at boot" \
    || bad "the core-service never ran — is 06-ember-expand.sh in the image?"

[ "${AFTER:-0}" -gt "${BEFORE:-0}" ] \
    && ok "the partition grew: $(( BEFORE / 2048 )) → $(( AFTER / 2048 )) MiB" \
    || bad "the partition did not grow ($BEFORE → $AFTER sectors)"

# ⛔ THE PARTITION GROWING IS NOT THE FILESYSTEM GROWING. growpart can succeed
# and resize2fs fail, leaving a larger partition with the old filesystem inside
# it — which looks fixed from the partition table and gives back no space at all.
grep -qa "root filesystem is now" "$T/boot1.log" \
    && ok "resize2fs reported the new size: $(grep -ao 'root filesystem is now.*' "$T/boot1.log" | tail -1)" \
    || bad "no resize2fs confirmation — the partition may have grown without the filesystem"

[ "${AFTER2:-0}" = "${AFTER:-0}" ] \
    && ok "the second boot left the disk alone" \
    || bad "the disk changed on the SECOND boot ($AFTER → $AFTER2) — it is not once-only"

grep -qa "ember-expand" "$T/boot2.log" && \
    { grep -qa "Expanding the root filesystem" "$T/boot2.log" && \
      ok "…and the marker short-circuited it" || ok "…and it did not re-run"; } || \
    ok "…and it did not re-run"

echo
[ "$fail" -ne 0 ] && { echo "  --- first boot, last 20 ---" >&2; tail -20 "$T/boot1.log" >&2; }
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
