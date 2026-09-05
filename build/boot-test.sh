#!/usr/bin/env bash
#
# boot-test.sh — does the image actually boot?
#
# ⛔ "IT BUILT" IS NOT "IT BOOTS", and the gap between them is where every hour
# of carrying a disk to another room goes. mkimage.sh verifies that grub.cfg
# names a UUID and that the MBR has a bootloader in it; neither of those has
# ever started a kernel. This does.
#
# The machine is emulated to resemble the target rather than a modern PC: an IDE
# disk, no KVM, i386. TCG emulation is slow — a boot that takes eight seconds on
# real hardware can take a minute here — which is why the timeout is generous
# and why the test watches for a string rather than a wall-clock deadline.
#
# Usage: build/boot-test.sh [i686] [desktop] [timeout-seconds]
set -uo pipefail
cd "$(dirname "$0")/.."
. build/config.sh

ARCH=${1:-i686}; TIER=${2:-desktop}; LIMIT=${3:-240}
IMG="out/$EMBER_ID-$EMBER_VERSION-$ARCH-$TIER/$EMBER_ID-$EMBER_VERSION-$ARCH-$TIER.img"
[ -f "$IMG" ] || { echo "boot-test: no image at $IMG" >&2; exit 1; }
command -v qemu-system-i386 >/dev/null || { echo "SKIP: qemu-system-i386 not installed"; exit 77; }

LOG=$(mktemp -t ember-boot.XXXXXX); trap 'rm -f "$LOG"' EXIT
echo "== booting $IMG (up to ${LIMIT}s, TCG — no KVM)"

# ⚠ if=ide, NOT virtio. The point is to exercise the path the Pentium 4 will
# use; a virtio disk would prove the initramfs can mount a device class that
# machine does not have.
timeout "$LIMIT" qemu-system-i386 \
    -m 2048 -smp 2 \
    -drive file="$IMG",format=raw,if=ide \
    -display none -serial file:"$LOG" \
    -no-reboot >/dev/null 2>&1

pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1" >&2; fail=$((fail+1)); }
saw() { grep -qi -- "$1" "$LOG"; }

echo "  (serial captured $(wc -c < "$LOG") bytes)"

saw "GRUB"                && ok "GRUB loaded and reached its console" \
                          || bad "no sign of GRUB — the MBR or its core image is wrong"
# ⚠ NOT "Linux version". The image ships loglevel=4, so the kernel's own banner
# is KERN_NOTICE and never reaches the console — asserting on it failed against
# an image that had booted perfectly. Void's stage-1 banner is the honest
# equivalent: it cannot print unless the kernel ran, the initramfs handed over,
# and userspace started.
saw "Remounting rootfs"   && ok "the kernel started and userspace took over" \
                          || bad "GRUB never handed over to a working kernel"
if saw "Kernel panic"; then
    bad "KERNEL PANIC"
    grep -i -m3 -A4 "Kernel panic" "$LOG" | sed 's/^/        /' >&2
else
    ok "no kernel panic"
fi
# The root filesystem being found is the single most likely thing to be wrong,
# because it is the one fact that differs between the build host and the target.
if saw "Cannot open root device" || saw "Unable to mount root" || saw "dracut: FATAL"; then
    bad "the root filesystem was not mounted — the initramfs or the UUID is wrong"
else
    ok "root filesystem mounted"
fi
saw "runit"               && ok "runit took over as init" \
                          || bad "init never ran"
(saw "login:" || saw "$EMBER_ID login")                                  \
                          && ok "reached a login prompt" \
                          || bad "never reached a login prompt"

echo
if [ "$fail" -ne 0 ]; then
    echo "  --- last 25 lines of serial ---" >&2
    tail -25 "$LOG" | sed 's/^/  /' >&2
fi
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
