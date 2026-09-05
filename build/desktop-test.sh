#!/usr/bin/env bash
#
# desktop-test.sh — does a desktop actually draw?
#
# ⛔ boot-test.sh PROVES A LOGIN PROMPT AND NOTHING MORE. A machine that reaches
# a getty on the serial line has proved the kernel, the initramfs, the root
# filesystem and init — and has proved nothing whatsoever about X, lightdm, the
# video driver or whether anything is on the screen. This project's entire point
# is a graphical desktop, so that gap is the one worth a rig of its own.
#
# It reads the framebuffer rather than a log: qemu's monitor can dump the guest's
# screen to a PPM, which is the only evidence that does not depend on some
# component being polite enough to say what it did.
#
# ⚠ THE VIDEO PATH IS NOT THE TARGET'S. qemu gives a Bochs/std VGA and Mesa will
# software-render onto it; the Pentium 4 has a GeForce 7600 and nouveau. So a
# pass here means "X, lightdm and the session are correctly configured", NOT
# "nouveau works on that card" — which only the machine can answer.
#
# Usage: build/desktop-test.sh [i686] [desktop] [seconds-to-wait]
set -uo pipefail
cd "$(dirname "$0")/.."
. build/config.sh

ARCH=${1:-i686}; TIER=${2:-desktop}; WAIT=${3:-300}
IMG="out/$EMBER_ID-$EMBER_VERSION-$ARCH-$TIER/$EMBER_ID-$EMBER_VERSION-$ARCH-$TIER.img"
[ -f "$IMG" ] || { echo "desktop-test: no image at $IMG" >&2; exit 1; }
command -v qemu-system-i386 >/dev/null || { echo "SKIP: qemu-system-i386 not installed"; exit 77; }
python3 -c 'import PIL' 2>/dev/null || { echo "SKIP: python3 PIL not installed"; exit 77; }

T=$(mktemp -d); trap 'kill "${QP:-0}" 2>/dev/null; rm -rf "$T"' EXIT
LOG="$T/serial.log"; MON="$T/mon.sock"; SHOT="$T/screen.ppm"

echo "== booting $IMG for a screenshot (up to ${WAIT}s, TCG)"
qemu-system-i386 \
    -m 2048 -smp 2 \
    -drive file="$IMG",format=raw,if=ide \
    -vga std -display none \
    -serial file:"$LOG" \
    -monitor "unix:$MON,server,nowait" \
    -no-reboot >/dev/null 2>&1 &
QP=$!

# Wait for the login prompt, then keep waiting: lightdm starts well after the
# getty does, and a screenshot taken at the prompt catches a black screen and
# calls it a failure.
deadline=$(( $(date +%s) + WAIT ))
booted=0
while [ "$(date +%s)" -lt "$deadline" ]; do
    kill -0 "$QP" 2>/dev/null || break
    if grep -qi "login:" "$LOG" 2>/dev/null; then booted=1; break; fi
    sleep 3
done
[ "$booted" = 1 ] && echo "  reached a login prompt; giving the display manager 60s more"
sleep 60

python3 - "$MON" "$SHOT" <<'ENDPY'
import socket, sys, time
mon, shot = sys.argv[1], sys.argv[2]
s = socket.socket(socket.AF_UNIX); s.connect(mon); time.sleep(0.5)
s.recv(65536)
s.sendall(f"screendump {shot}\n".encode()); time.sleep(3)
try: s.recv(65536)
except Exception: pass
s.close()
ENDPY

kill "$QP" 2>/dev/null; wait "$QP" 2>/dev/null

pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1" >&2; fail=$((fail+1)); }

[ -s "$SHOT" ] && ok "captured the guest framebuffer" \
               || { bad "no screenshot — qemu's monitor did not answer"; echo "  0 passed, 1 failed"; exit 1; }

OUTDIR="out/$EMBER_ID-$EMBER_VERSION-$ARCH-$TIER"
cp "$SHOT" "$OUTDIR/screen.ppm" 2>/dev/null || true
# A PNG beside it, because nothing on a modern desktop opens a PPM.
python3 -c "from PIL import Image; Image.open('$SHOT').save('$OUTDIR/screen.png')" 2>/dev/null || true

python3 - "$SHOT" <<'ENDPY'
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB")
w, h = im.size
# ⚠ tobytes(), not getdata() — Pillow deprecated the latter, and a warning
# printed on every run of a test is a warning people stop reading.
raw = im.tobytes()
px = [tuple(raw[i:i+3]) for i in range(0, len(raw), 3)]
n = len(px)
nonblack = sum(1 for p in px if sum(p) > 40)
colours = len(set(px))
print(f"  screen {w}x{h}, {100*nonblack//n}% of pixels lit, {colours} distinct colours")
fails = 0
def check(c, m):
    global fails
    print(("  ok    " if c else "  FAIL  ") + m)
    if not c: fails += 1

# ⛔ "PERCENT OF THE SCREEN LIT" IS THE WRONG MEASURE, and this rig failed a
# perfectly good image before saying so. The first version demanded 20% lit; the
# real greeter is a small white card centred on a black desktop and comes to 9%.
# Dark UIs are not broken UIs.
#
# What actually separates a text console from a desktop:
#   · the MODE — qemu's VGA text console is 720x400; X brings up 1024x768+
#   · the COLOUR COUNT — character cells have sixteen, a themed widget has
#     hundreds (this greeter: 803)
#   · a BRIGHT REGION — a real widget has a solid pale area. A cursor does not.
check(w >= 1024 and h >= 768, f"a graphical mode is set, not VGA text ({w}x{h})")
check(colours > 64, f"it is a rendered UI, not character cells ({colours} colours)")
bright = sum(1 for p in px if sum(p) > 600)
check(bright * 1000 // n > 5, f"a real widget is drawn, not just a cursor "
                              f"({100*bright/n:.1f}% of the screen is a pale surface)")
sys.exit(1 if fails else 0)
ENDPY
rc=$?
echo
[ "$rc" = 0 ] && echo "  screenshot saved to out/$EMBER_ID-$EMBER_VERSION-$ARCH-$TIER/screen.ppm"
exit $rc
