#!/usr/bin/env bash
#
# fetch-assets.sh — RetroArch's menu assets and joypad profiles, baked in.
#
# ⛔ VOID'S retroarch PACKAGE SHIPS NEITHER. It installs the binary and nothing
# under share/libretro, so a fresh image has:
#
#   assets_directory      → empty  → the Ozone/XMB menus render with no icons
#                                    and no fonts, which looks like a broken
#                                    install rather than a missing download
#   joypad_autoconfig_dir → empty  → NO CONTROLLER WORKS out of the box; the log
#                                    says "<pad name> not configured" and the
#                                    pad does nothing in the menu
#
# RetroArch fetches both from its Online Updater at runtime — which is exactly
# what the target machine cannot do. Same reasoning as fetch-cores.sh.
#
# ⚠ These are architecture-independent: PNGs, fonts and text profiles. One
# download serves both i686 and aarch64, so unlike cores/ this is not per-arch.
#
# ⛔ THE ASSETS REPO IS 213 MB AND MOST OF IT IS NOT FOR US. `src/` alone is
# 62 MB of source SVGs that nothing reads at runtime, and there are asset sets
# for the 3DS and for packaging. Only the menu drivers RetroArch can actually
# use on Linux are taken, which brings it to about 90 MB.
#
# Usage: build/fetch-assets.sh
#
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=assets
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fetch() {
    url="https://codeload.github.com/libretro/$1/tar.gz/refs/heads/master"
    echo "  $1"
    curl -fsSL --retry 3 -o "$TMP/$1.tar.gz" "$url" \
        || { echo "fetch-assets: could not download $1" >&2; exit 1; }
}

rm -rf "$OUT"
mkdir -p "$OUT/assets" "$OUT/autoconfig"

fetch retroarch-assets
# Menu drivers usable on a Linux desktop, plus their fonts and sounds. `src` is
# deliberately absent: build-time SVGs, 62 MB, never read at runtime.
tar xzf "$TMP/retroarch-assets.tar.gz" -C "$OUT/assets" --strip-components=1 \
    --wildcards '*/ozone/*' '*/xmb/*' '*/rgui/*' '*/glui/*' \
                '*/sounds/*' '*/wallpapers/*' 2>/dev/null || true

fetch retroarch-joypad-autoconfig
# udev is the joypad driver RetroArch uses on Linux; linuxraw is its fallback.
tar xzf "$TMP/retroarch-joypad-autoconfig.tar.gz" -C "$OUT/autoconfig" --strip-components=1 \
    --wildcards '*/udev/*' '*/linuxraw/*' 2>/dev/null || true

n_menu=$(ls "$OUT/assets" 2>/dev/null | wc -l)
n_pads=$(find "$OUT/autoconfig" -name '*.cfg' 2>/dev/null | wc -l)
[ "$n_menu" -ge 4 ] || { echo "fetch-assets: only $n_menu asset sets extracted" >&2; exit 1; }
[ "$n_pads" -ge 100 ] || { echo "fetch-assets: only $n_pads joypad profiles" >&2; exit 1; }

echo
echo "  $OUT/assets      $(du -sh "$OUT/assets" | cut -f1)  — $n_menu menu asset sets"
echo "  $OUT/autoconfig  $(du -sh "$OUT/autoconfig" | cut -f1)  — $n_pads joypad profiles"
