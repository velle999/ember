#!/bin/sh
# hw-probe.sh — what will this machine actually run?
#
# For sizing a SynapseOS port to old or small hardware. Run it on the candidate
# (a live USB of anything is fine) and it prints the handful of facts that decide
# whether the desktop can work there at all, each with the reason it matters.
#
# ⚠ POSIX sh, /proc and coreutils ONLY. No bash, no lspci, no glxinfo, no python.
# The machines this is for are the ones where none of that is installed, and a
# probe that needs a package manager to answer "can this box run anything" is no
# probe. Everything optional is used only when it happens to be there.
#
# ⛔ IT ANSWERS, IT DOES NOT ADVISE. Every line is a measurement and the label
# beside it says what that measurement blocks. "Probably fine" is not a finding.
#
# Usage:  sh hw-probe.sh            # human
#         sh hw-probe.sh --tsv      # one key<TAB>value per line, for a table
#
# SynapseOS Project — GPL-2.0-or-later
# SPDX-License-Identifier: GPL-2.0-or-later
# https://github.com/velle999/SYNAPSE

TSV=0
[ "${1:-}" = "--tsv" ] && TSV=1

emit() {  # emit <key> <value> [why it matters]
    if [ "$TSV" = 1 ]; then
        printf '%s\t%s\n' "$1" "$2"
    else
        printf '  %-22s %s\n' "$1" "$2"
        [ -n "${3:-}" ] && printf '  %-22s   ↳ %s\n' "" "$3"
    fi
    # ⛔ ALWAYS 0. Without this the last command above is a `[ -n ... ]` that
    # FAILS whenever the optional third argument is absent — so every caller
    # written `flag x && emit x yes || emit x no` printed BOTH lines. Caught by
    # running this on a Ryzen and watching it report sse4_1 as yes and no.
    return 0
}
head_() { [ "$TSV" = 1 ] || printf '\n%s\n' "$1"; }

flag() { grep -qm1 "^flags.*[ 	]$1[ 	]" /proc/cpuinfo 2>/dev/null; }
cpufield() { sed -n "s/^$1[ 	]*: *//p" /proc/cpuinfo 2>/dev/null | head -1; }

[ "$TSV" = 1 ] || echo "hw-probe — $(uname -s) $(uname -r) $(uname -m)"

# ── CPU ─────────────────────────────────────────────────────────────────────
head_ "CPU"
emit model    "$(cpufield 'model name')"
emit arch     "$(uname -m)"
emit cores    "$(grep -c '^processor' /proc/cpuinfo 2>/dev/null)"
emit mhz      "$(cpufield 'cpu MHz')"

# 64-bit is `lm` in the flags, which is present even when a 32-bit kernel is
# booted — so this reports what the SILICON can do, not what is running.
if flag lm; then
    emit bits "64-bit capable" "the x86_64 build can run here; no 32-bit port needed"
else
    emit bits "32-bit ONLY" "needs an i686 build — Arch dropped i686 in 2017, so this means archlinux32"
fi

# ⛔ SSE2 IS THE FLOOR AND IT IS NOT NEGOTIABLE. Mesa's llvmpipe — the software
# GL renderer every machine without a supported GPU falls back to — requires it,
# and wlroots needs a GL or Vulkan renderer to start at all. A CPU without SSE2
# (Pentium III, Athlon XP and older) cannot run this desktop by any route that
# does not involve writing a new renderer.
if flag sse2; then
    emit sse2 "yes" "llvmpipe (software GL) can run — the fallback when there is no GPU driver"
else
    emit sse2 "NO — BLOCKER" "llvmpipe requires SSE2; a Wayland compositor has no renderer without it"
fi
# ⚠ SSE3 IS SPELLED `pni` IN /proc/cpuinfo — "Prescott New Instructions", the
# kernel's name for it. Asking for "sse3" reports every CPU since 2004 as not
# having SSE3, which on a probe whose whole job is to classify old hardware is
# the worst possible way to be wrong.
for f in pni ssse3 sse4_1 sse4_2 avx pae nx; do
    name=$f; [ "$f" = pni ] && name=sse3
    if flag "$f"; then emit "$name" yes; else emit "$name" no; fi
done

# ── memory ──────────────────────────────────────────────────────────────────
head_ "Memory"
memkb=$(sed -n 's/^MemTotal: *\([0-9]*\).*/\1/p' /proc/meminfo 2>/dev/null)
memmb=$(( ${memkb:-0} / 1024 ))
emit total "${memmb} MiB"
# The numbers are measured elsewhere, not guessed here: the full desktop's own
# ISO carries a 1.2 GiB AI pet and a 600 MiB Wine, which is what these tiers are
# about — not the compositor, which is 25 MiB.
if   [ "$memmb" -lt 512 ];  then emit ram_verdict "TOO SMALL for a Wayland desktop" "under 512 MiB, expect the compositor alone to swap"
elif [ "$memmb" -lt 1024 ]; then emit ram_verdict "minimal only" "compositor + one app; no browser, no AI stack"
elif [ "$memmb" -lt 2048 ]; then emit ram_verdict "tiny profile" "desktop + light apps; the AI stack and Wine are out"
else                             emit ram_verdict "full profile possible"; fi

# ── graphics ────────────────────────────────────────────────────────────────
head_ "Graphics"
# ⚠ THE DRM NODE IS THE QUESTION, not the PCI id. wlroots talks to KMS through
# /dev/dri/card*, and a GPU the kernel has no KMS driver for is, to a Wayland
# compositor, no GPU at all — the card being listed by the BIOS says nothing.
cards=$(ls /dev/dri/card* 2>/dev/null | tr '\n' ' ')
rnodes=$(ls /dev/dri/renderD* 2>/dev/null | tr '\n' ' ')
emit drm_cards  "${cards:-none}"      "wlroots needs a KMS card node to drive a display"
emit drm_render "${rnodes:-none}"     "a render node means hardware GL is at least possible"
if [ -z "$cards" ]; then
    emit gl_path "NO KMS — BLOCKER for a real session" "the compositor can still run headless/nested for testing"
elif [ -z "$rnodes" ]; then
    emit gl_path "KMS but no render node — software GL (llvmpipe)" "works; effects and animation will be slow"
else
    emit gl_path "KMS + render node — hardware GL possible" "confirm the driver below is a real one, not vgem/simpledrm"
fi
for d in /sys/class/drm/card*/device/driver; do
    [ -e "$d" ] || continue
    emit kms_driver "$(basename "$(readlink -f "$d")")"
done

# ── WHICH CHIP, WHICH DRIVER GENERATION ─────────────────────────────────────
#
# ⛔ THE ANSWER TO "WILL THIS ACCELERATE" IS THE CHIP, NOT THE VENDOR. On NVIDIA
# especially: nouveau is three drivers wearing one name, and which one a card
# lands on decides whether Mesa has anything for it —
#
#   nv30  GeForce FX / 6 / 7 (NV30-G7x)   — present in Mesa 26, OpenGL 2.1-ish
#   nv50  GeForce 8 / 9 / 200 / 300       — the best-supported old generation
#   nvc0  GeForce 400 and later
#
# and anything older than NV30 has no Gallium driver at all any more. The
# proprietary legacy blobs (304.xx for GeForce 6/7, 340.xx for 8/9/200) do not
# build against a 6.x kernel, so nouveau is not a preference here, it is the
# only option.
#
# Read from sysfs rather than lspci, which these machines do not have installed.
for u in /sys/class/drm/card*/device/uevent; do
    [ -e "$u" ] || continue
    pciid=$(sed -n 's/^PCI_ID=//p' "$u" | head -1)
    [ -n "$pciid" ] && emit gpu_pci_id "$pciid" "vendor:device — 10DE is NVIDIA, 8086 Intel, 1002 AMD/ATI"
done
# The kernel names the chip itself when nouveau binds; that line is worth more
# than any id lookup because it is the driver's own answer.
if command -v dmesg >/dev/null 2>&1; then
    chip=$(dmesg 2>/dev/null | grep -iom1 'NVIDIA NV[0-9A-F]*' | head -1)
    [ -n "$chip" ] && emit nouveau_chip "$chip" "the kernel's own identification of the silicon"
fi
# And if there is a running GL stack, its renderer string ends the argument.
if command -v glxinfo >/dev/null 2>&1; then
    r=$(glxinfo -B 2>/dev/null | sed -n 's/^ *OpenGL renderer string: *//p' | head -1)
    v=$(glxinfo -B 2>/dev/null | sed -n 's/^ *OpenGL version string: *//p' | head -1)
    [ -n "$r" ] && emit gl_renderer "$r" "if this says llvmpipe, GL is running on the CPU"
    [ -n "$v" ] && emit gl_version  "$v"
fi
# simpledrm/efifb is the kernel's generic framebuffer: a display, no acceleration.
grep -qs simpledrm /proc/modules && \
    emit note "simpledrm is loaded — that is the generic framebuffer, not a GPU driver"

# ── storage and firmware ────────────────────────────────────────────────────
head_ "Storage and firmware"
if [ -d /sys/firmware/efi ]; then
    emit firmware "UEFI"
else
    emit firmware "BIOS (legacy)" "the installer must write a BIOS bootloader; limine/syslinux, not systemd-boot"
fi
if command -v df >/dev/null 2>&1; then
    emit disk_free "$(df -h / 2>/dev/null | awk 'NR==2{print $4" free of "$2}')"
fi
[ "$TSV" = 1 ] || printf '\n'
