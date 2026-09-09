#!/usr/bin/env bash
#
# tests/gpu-detect-test.sh — exercise ember-gpu-detect against fabricated PCI
# trees, because the decision it makes is not observable until a machine either
# boots to a desktop or does not.
#
# ⚠ Runs anywhere; touches nothing outside its temp dir.
#
# SPDX-License-Identifier: GPL-2.0-or-later
set -uo pipefail
cd "$(dirname "$0")/.."
DET=installer/ember-gpu-detect
IDS=installer/nvidia304-supported.ids
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0

# build a fake /sys/bus/pci/devices with one boot-VGA card
mkpci() { # vendor device -> dir
    local d="$T/pci$RANDOM"; mkdir -p "$d/0000:01:00.0"
    printf '%s\n' "$1" > "$d/0000:01:00.0/vendor"
    printf '%s\n' "$2" > "$d/0000:01:00.0/device"
    printf '1\n'       > "$d/0000:01:00.0/boot_vga"
    printf '0x030000\n'> "$d/0000:01:00.0/class"
    echo "$d"
}
check() { # name expected -- rest: env assignments
    local name=$1 want=$2; shift 2
    local got; got=$(env "$@" "$DET" 2>/dev/null)
    if [ "$got" = "$want" ]; then
        printf '  ok    %-46s -> %s\n' "$name" "$got"; pass=$((pass+1))
    else
        printf '  FAIL  %-46s -> %s (wanted %s)\n' "$name" "$got" "$want"; fail=$((fail+1))
    fi
}

touch "$T/ko"; : > "$T/empty-cmdline"

echo "== autodetection by card =="
check "GeForce 7600 GS (10de:02e1, supported)" nvidia304 \
      EMBER_GPU_PCI="$(mkpci 0x10de 0x02e1)" EMBER_GPU_IDS="$IDS" EMBER_GPU_KO="$T/ko" \
      EMBER_GPU_CMDLINE="$T/empty-cmdline" EMBER_GPU_CONF=/nonexistent
# ⛔ the FX is the trap: it is in the driver's own docs, under the 173.14.xx
# branch, which is a different driver this project does not ship.
check "GeForce FX 5200 (10de:0322, NOT supported)" nouveau \
      EMBER_GPU_PCI="$(mkpci 0x10de 0x0322)" EMBER_GPU_IDS="$IDS" EMBER_GPU_KO="$T/ko" \
      EMBER_GPU_CMDLINE="$T/empty-cmdline" EMBER_GPU_CONF=/nonexistent
check "Radeon (1002:5b60)" radeon \
      EMBER_GPU_PCI="$(mkpci 0x1002 0x5b60)" EMBER_GPU_IDS="$IDS" EMBER_GPU_KO="$T/ko" \
      EMBER_GPU_CMDLINE="$T/empty-cmdline" EMBER_GPU_CONF=/nonexistent
check "Intel (8086:2772)" intel \
      EMBER_GPU_PCI="$(mkpci 0x8086 0x2772)" EMBER_GPU_IDS="$IDS" EMBER_GPU_KO="$T/ko" \
      EMBER_GPU_CMDLINE="$T/empty-cmdline" EMBER_GPU_CONF=/nonexistent
check "unknown vendor (1234:1111)" modesetting \
      EMBER_GPU_PCI="$(mkpci 0x1234 0x1111)" EMBER_GPU_IDS="$IDS" EMBER_GPU_KO="$T/ko" \
      EMBER_GPU_CMDLINE="$T/empty-cmdline" EMBER_GPU_CONF=/nonexistent

echo "== the 304 stack is absent from the image =="
check "supported NVIDIA but no nvidia.ko" nouveau \
      EMBER_GPU_PCI="$(mkpci 0x10de 0x02e1)" EMBER_GPU_IDS="$IDS" EMBER_GPU_KO=/nonexistent \
      EMBER_GPU_CMDLINE="$T/empty-cmdline" EMBER_GPU_CONF=/nonexistent

echo "== overrides, most specific first =="
printf 'radeon\n' > "$T/conf"
check "/etc/ember/gpu beats autodetection" radeon \
      EMBER_GPU_PCI="$(mkpci 0x10de 0x02e1)" EMBER_GPU_IDS="$IDS" EMBER_GPU_KO="$T/ko" \
      EMBER_GPU_CMDLINE="$T/empty-cmdline" EMBER_GPU_CONF="$T/conf"
printf 'auto\n' > "$T/auto"
check "'auto' falls through to autodetection" nvidia304 \
      EMBER_GPU_PCI="$(mkpci 0x10de 0x02e1)" EMBER_GPU_IDS="$IDS" EMBER_GPU_KO="$T/ko" \
      EMBER_GPU_CMDLINE="$T/empty-cmdline" EMBER_GPU_CONF="$T/auto"
# ⛔ the escape hatch: this is what you get to type at the GRUB prompt when the
# proprietary stack has left you with no desktop.
printf 'root=UUID=x ro ember.gpu=nouveau quiet\n' > "$T/cmd"
check "ember.gpu= on the cmdline beats the file" nouveau \
      EMBER_GPU_PCI="$(mkpci 0x10de 0x02e1)" EMBER_GPU_IDS="$IDS" EMBER_GPU_KO="$T/ko" \
      EMBER_GPU_CMDLINE="$T/cmd" EMBER_GPU_CONF="$T/conf"
printf 'root=UUID=x ember.gpu=nvidia\n' > "$T/cmd2"
check "'nvidia' is an alias for nvidia304" nvidia304 \
      EMBER_GPU_PCI="$(mkpci 0x1002 0x5b60)" EMBER_GPU_IDS="$IDS" EMBER_GPU_KO="$T/ko" \
      EMBER_GPU_CMDLINE="$T/cmd2" EMBER_GPU_CONF=/nonexistent
printf 'root=UUID=x ember.gpu=banana\n' > "$T/cmd3"
check "a bogus mode is ignored, not obeyed" radeon \
      EMBER_GPU_PCI="$(mkpci 0x1002 0x5b60)" EMBER_GPU_IDS="$IDS" EMBER_GPU_KO="$T/ko" \
      EMBER_GPU_CMDLINE="$T/cmd3" EMBER_GPU_CONF=/nonexistent

echo
echo "  $pass passed, $fail failed"
[ "$fail" = 0 ]
