#!/usr/bin/env bash
#
# gpu-early-test.sh — the initramfs GPU decision, without an initramfs.
#
# ⛔ THE DANGEROUS DIRECTION IS THE FALSE POSITIVE. Blacklisting nouveau for a
# card 304 cannot drive leaves a machine with NO driver at all -- a black screen
# on the one medium that meets hardware nobody has tested. So the cases that
# matter most here are the ones where nothing must happen: a GeForce the list
# does not name, a non-NVIDIA card, a missing list, an explicit ember.gpu=.
#
# Driven against a fake /sys and a fake command line, because the real thing
# needs the initramfs of a machine with the right card in it.
#
# SPDX-License-Identifier: GPL-2.0-or-later
set -u
cd "$(dirname "$0")/.."

HOOK=installer/dracut/99ember-gpu/ember-gpu-early.sh
PIVOT=installer/dracut/99ember-gpu/ember-gpu-pivot.sh
IDS=installer/nvidia304-supported.ids
[ -x "$HOOK" ] || { echo "ABORT no $HOOK"; exit 2; }
[ -r "$IDS" ]  || { echo "ABORT no $IDS"; exit 2; }

pass=0 fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1" >&2; fail=$((fail+1)); }

T=$(mktemp -d /tmp/embergpu.XXXXXX); trap 'rm -rf "$T"' EXIT

# a fake PCI device: card <slot> <vendor> <device> <boot_vga> [class]
card() {
    local d="$T/sys/$1"; mkdir -p "$d"
    printf '%s\n' "$2" > "$d/vendor"
    printf '%s\n' "$3" > "$d/device"
    printf '%s\n' "$4" > "$d/boot_vga"
    printf '%s\n' "${5:-0x030000}" > "$d/class"
}

# run <cmdline> ; prints nothing, leaves $T/modprobe.d populated or not
run() {
    rm -rf "$T/modprobe.d" "$T/log"; mkdir -p "$T/modprobe.d"
    printf '%s\n' "${1:-}" > "$T/cmdline"
    EMBER_GPU_IDS="$T/ids" EMBER_GPU_PCI="$T/sys" EMBER_GPU_MODPROBE_D="$T/modprobe.d" \
    EMBER_GPU_CMDLINE="$T/cmdline" EMBER_GPU_LOG="$T/log" sh "$HOOK" >/dev/null 2>&1
}
blacklisted() { [ -f "$T/modprobe.d/ember-gpu-nouveau.conf" ]; }

cp "$IDS" "$T/ids"
echo "ember-gpu-early"

# ── the card 304 exists for ────────────────────────────────
# 0x0391 is the GeForce 7600 GT in the reference machine; it is in the list.
rm -rf "$T/sys"; card 0000:06:00.0 0x10de 0x0391 1
run ""
blacklisted && ok "a 304-supported GeForce blacklists nouveau" \
             || bad "the reference card was left to nouveau"
grep -q '^install nouveau /bin/false' "$T/modprobe.d/ember-gpu-nouveau.conf" 2>/dev/null \
    && ok "...with the install line, not just blacklist" \
    || bad "blacklist alone still lets a dependency pull load it"

# ── every case where nothing must happen ───────────────────
rm -rf "$T/sys"; card 0000:06:00.0 0x10de 0x0322 1        # FX 5200: 173.14.xx branch
run ""
blacklisted && bad "⛔ an FX 5200 was blacklisted -- that machine has no driver now" \
             || ok "a GeForce the list does not name is left on nouveau"

rm -rf "$T/sys"; card 0000:00:02.0 0x8086 0x0126 1        # Intel
run ""
blacklisted && bad "a non-NVIDIA card was blacklisted" || ok "an Intel card is left alone"

rm -rf "$T/sys"; card 0000:06:00.0 0x10de 0x0391 1
rm -f "$T/ids"; run ""
blacklisted && bad "blacklisted with no ID list to check against" \
             || ok "no ID list means no blacklist, even on the right card"
cp "$IDS" "$T/ids"

rm -rf "$T/sys"; run ""
blacklisted && bad "blacklisted with no display device at all" \
             || ok "a machine with no display device is left alone"

# ── an explicit choice always wins ─────────────────────────
rm -rf "$T/sys"; card 0000:06:00.0 0x10de 0x0391 1
run "root=live:CDLABEL=EMBER ember.gpu=nouveau loglevel=4"
blacklisted && bad "ember.gpu=nouveau was overridden by autodetection" \
             || ok "ember.gpu=nouveau keeps the open driver on a 304 card"

run "root=live:CDLABEL=EMBER ember.gpu=nvidia"
blacklisted && ok "ember.gpu=nvidia blacklists even without the cmdline blacklist" \
             || bad "ember.gpu=nvidia did nothing"

# ── boot_vga decides which card, not order ─────────────────
#
# ⚠ The onboard chip enumerates FIRST. Keying on "the first display device"
# would pick the dead one on exactly the machines this project targets.
rm -rf "$T/sys"
card 0000:00:02.0 0x8086 0x0126 0                          # onboard, not the console
card 0000:06:00.0 0x10de 0x0391 1                          # the AGP card, boot_vga
run ""
blacklisted && ok "boot_vga picks the console's card, not the first one listed" \
             || bad "the onboard chip won and the real card was ignored"

# ...and the other way round: NVIDIA present but not the display.
rm -rf "$T/sys"
card 0000:00:02.0 0x8086 0x0126 1
card 0000:06:00.0 0x10de 0x0391 0
run ""
blacklisted && bad "blacklisted for a card that is not driving the console" \
             || ok "an NVIDIA card that is not the console leaves nouveau alone"

# ── the handover ───────────────────────────────────────────
rm -rf "$T/sys"; card 0000:06:00.0 0x10de 0x0391 1; run ""
mkdir -p "$T/newroot"
NEWROOT="$T/newroot" EMBER_GPU_MODPROBE_D="$T/modprobe.d" EMBER_GPU_LOG="$T/log" \
    sh "$PIVOT" >/dev/null 2>&1
[ -f "$T/newroot/run/modprobe.d/ember-gpu-nouveau.conf" ] \
    && ok "the blacklist is carried into the real root" \
    || bad "the real root's coldplug will load nouveau anyway"
# ⛔ /run, NOT /etc: a permanent blacklist decided by one boot's hardware would
# outlive the card it was chosen for.
[ -f "$T/newroot/etc/modprobe.d/ember-gpu-nouveau.conf" ] \
    && bad "it wrote a PERMANENT blacklist into the installed system" \
    || ok "...into /run, so it does not outlive the boot"

echo ""
if [ "$fail" -eq 0 ]; then echo "all $pass ember-gpu-early checks passed"; else echo "$fail of $((pass+fail)) failed"; fi
exit $(( fail > 0 ))
