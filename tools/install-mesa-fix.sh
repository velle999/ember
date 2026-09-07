#!/bin/sh
# install-mesa-fix.sh — install the patched Mesa package set on the P4.
#
# Builds nothing. Expects the .xbps files produced by:
#   ./xbps-src pkg mesa   (srcpkgs/mesa + mesa-nv30-idxbuf-reloc-dropped.patch)
#
# ROLLBACK, if anything goes wrong:
#   sudo xbps-install -fy mesa-26.1.8_1 mesa-dri-26.1.8_1 \
#                         mesa-libgallium-26.1.8_1 libgbm-26.1.8_1
# The stock revision _1 is still in Void's repo, so this is fully revertible
# with the package manager — which is why we ship a package and never overwrite
# /usr/lib/libgallium-26.1.8.so by hand.
set -e
HOST="${1:-ember@192.168.40.31}"
PKGDIR="${2:-/mnt/synapse-fast/voidbuild/void-packages/hostdir/binpkgs}"

echo "== packages to ship =="
find "$PKGDIR" -name 'mesa-26.1.8_2*.xbps' -o -name 'mesa-dri-26.1.8_2*.xbps' \
     -o -name 'mesa-libgallium-26.1.8_2*.xbps' -o -name 'libgbm-26.1.8_2*.xbps' | sort

echo "== copying =="
ssh "$HOST" 'mkdir -p /tmp/mesafix'
find "$PKGDIR" \( -name 'mesa-26.1.8_2*.xbps' -o -name 'mesa-dri-26.1.8_2*.xbps' \
     -o -name 'mesa-libgallium-26.1.8_2*.xbps' -o -name 'libgbm-26.1.8_2*.xbps' \) \
     -exec scp -q {} "$HOST:/tmp/mesafix/" \;

echo "== installing =="
ssh "$HOST" 'bash -s' <<'EOF'
set -e
cd /tmp/mesafix
ls -la
# repository-style install so xbps records them properly
sudo -n xbps-rindex -a /tmp/mesafix/*.xbps
sudo -n xbps-install -y --repository=/tmp/mesafix -f mesa mesa-dri mesa-libgallium libgbm
echo "-- installed versions --"
xbps-query -l | grep -iE "mesa|libgbm"
EOF

echo "== verifying GL still initialises BEFORE anything restarts X =="
ssh "$HOST" 'bash -s' <<'EOF'
X=$(pgrep -x Xorg|head -1); XA=$(ps -o args= -p $X)
D=$(echo "$XA"|tr ' ' '\n'|grep -m1 '^:[0-9]'); A=$(echo "$XA"|tr ' ' '\n'|grep -A1 '^-auth'|tail -1)
sudo -n env DISPLAY=$D XAUTHORITY=$A glxinfo -B 2>/dev/null | grep -E "Accelerated|OpenGL renderer|OpenGL version" \
  || echo "  ⛔ GL FAILED — roll back with the command in this script's header"
EOF
