#!/usr/bin/env bash
#
# fetch-cores.sh — libretro cores, baked into the image.
#
# ⛔ VOID PACKAGES ESSENTIALLY NO CORES. The whole libretro set in the i686
# repository is mupen64plus — an N64 emulator, which is among the heaviest cores
# there is and will not run on the hardware this project targets. So `retroarch`
# from the repository is an emulator front-end with nothing to emulate with.
#
# RetroArch can download cores itself, from this same buildbot, at runtime — and
# THAT IS EXACTLY WHAT THE TARGET MACHINE CANNOT DO, having no network. Hence
# fetching them here and shipping them inside the image.
#
# ⚠ TWO TIERS, AND THE SECOND ONE IS NOT A PROMISE. Everything up to the fourth
# generation runs comfortably on a 3 GHz Pentium 4. The fifth and sixth are a
# question the MACHINE answers, not this file — and an earlier version of it
# omitted them on the grounds that they would stutter, which was overconfident:
# N64 emulation ran on ~1 GHz machines in 2001 and Dreamcast on a 2.4 GHz P4 in
# 2004. At two to eight megabytes a core it is far cheaper to ship them and let
# the hardware decide than to decide on its behalf.
#
# What is genuinely known rather than guessed:
#   · PlayStation is the SAFEST of the heavy set — it ran on Pentium IIIs.
#   · Saturn is the hardest console here to emulate, by some distance, and
#     `kronos` wants OpenGL 4 which an nv30 GPU does not have. beetle_saturn is
#     not built for 32-bit x86 at all.
#   · PSP (ppsspp) was written for 2012 hardware and is the least likely to
#     please, but it is 8 MB and costs nothing to try.
#
# Usage: build/fetch-cores.sh [i686|aarch64]
set -euo pipefail
cd "$(dirname "$0")/.."
. build/config.sh

ARCH=${1:-i686}
case "$ARCH" in
    i686)    BB=linux/x86/latest ;;
    aarch64) BB=linux/arm64/latest ;;
    *) echo "usage: $0 <i686|aarch64>" >&2; exit 2 ;;
esac
BASE="https://buildbot.libretro.com/nightly/$BB"
OUT="cores/$ARCH"
mkdir -p "$OUT"

# ⚠ mame2003_plus IS THE POINT for arcade on this hardware. It is MAME 0.78-era,
# from when MAME still targeted machines like this one; standalone MAME is 0.282
# and chases accuracy on hardware two decades newer. fbalpha2012 is beside it
# for the same reason and covers a different set of boards.
CORES="
fceumm nestopia quicknes
snes9x2010 snes9x
genesis_plus_gx picodrive
gambatte mgba
stella prosystem handy
mame2003_plus fbalpha2012
bluemsx cap32 fuse
vice_x64 vice_x128
o2em vecx
atari800 puae
"

# The fifth and sixth generations — see the note above. Missing ones are
# reported and skipped, not treated as an error.
CORES="$CORES
swanstation pcsx_rearmed
parallel_n64 mupen64plus_next
flycast
yabause kronos
ppsspp
"

echo "== libretro cores for $ARCH"
echo "   from: $BASE"
ok=0; miss=0
for c in $CORES; do
    f="${c}_libretro.so"
    if [ -f "$OUT/$f" ]; then ok=$((ok+1)); continue; fi
    if curl -fsS --max-time 180 -o "$OUT/$f.zip" "$BASE/${f}.zip" 2>/dev/null; then
        # ⚠ Unzipped here, not on the target: RetroArch loads a .so, and shipping
        # zips would need something on the machine to expand them at first run.
        ( cd "$OUT" && unzip -qo "$f.zip" && rm -f "$f.zip" )
        printf '   + %s\n' "$c"; ok=$((ok+1))
    else
        printf '   - %s (not built for %s)\n' "$c" "$ARCH"; miss=$((miss+1))
        rm -f "$OUT/$f.zip"
    fi
done
echo
echo "   $ok core(s), $miss unavailable, $(du -sh "$OUT" 2>/dev/null | cut -f1) total"
