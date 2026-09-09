#!/bin/sh
#
# _nvidia304-inside.sh — the container half of mk-nvidia304.sh. Split out for
# the same reason as _image-inside.sh: otherwise it is a shell string inside a
# docker -c string, and the quoting is where the bugs live.
#
# ⚠ POSIX sh. The Void container ships dash and no bash.
#
# SPDX-License-Identifier: GPL-2.0-or-later
set -eu

# ⛔ The container image is older than the repository. Without a full update the
# transaction fails on `libuuid in transaction breaks installed pkg util-linux`,
# which reads like a dependency bug and is really just a stale image.
xbps-install -Suy xbps >/dev/null 2>&1 || true
xbps-install -Suy >/dev/null 2>&1 || true

echo "   deps"
xbps-install -Sy base-devel git curl tar xz patch automake autoconf libtool \
  pkg-config xkbcomp flex bison MesaLib-devel libXaw-devel libXfont2-devel \
  libXres-devel libXtst-devel libxkbfile-devel libpciaccess-devel pixman-devel \
  libepoxy-devel libunwind-devel xtrans xorgproto libxshmfence-devel \
  libXv-devel libXmu-devel libXrender-devel libXi-devel libXext-devel \
  xcb-util-devel xcb-util-image-devel xcb-util-renderutil-devel \
  xcb-util-wm-devel xcb-util-keysyms-devel libgcrypt-devel elogind-devel \
  dbus-devel libdrm-devel eudev-libudev-devel font-util xorg-util-macros \
  >/dev/null 2>&1
xbps-install -y --repository=/emberrepo linux6.18-headers >/dev/null 2>&1
KSRC=$(ls -d /usr/src/kernel-headers-* | head -1)

# ⛔ Void's kernel headers omit arch/x86/entry/syscalls, and without it the
# kernel's own archheaders target fails before any out-of-tree module compiles.
# This hits ANY external module built against these headers, not just nvidia.
if [ ! -f "$KSRC/arch/x86/entry/syscalls/Makefile" ]; then
    echo "   repairing the headers tree (archheaders inputs are missing)"
    cd /work
    tar -xf /work/linux-src/linux-*.tar.xz --wildcards '*/arch/x86/entry/syscalls/*' 2>/dev/null || true
    D=$(find /work -type d -path '*/arch/x86/entry/syscalls' | head -1)
    [ -n "$D" ] && { mkdir -p "$KSRC/arch/x86/entry/syscalls"; cp -a "$D/." "$KSRC/arch/x86/entry/syscalls/"; }
fi

# ── the kernel module ───────────────────────────────────────────────────────
echo "   kernel module"
cd /work && rm -rf NVIDIA-Linux-x86-304.137
sh NVIDIA-Linux-x86-304.137.run --extract-only >/dev/null 2>&1
cd NVIDIA-Linux-x86-304.137 && chmod -R u+w .
for p in $(ls /work/kpatches/0*.patch | sort); do
    case "$(basename "$p")" in 0028*|0029*) continue ;; esac
    patch -Np1 -s -r /dev/null < "$p" >/dev/null 2>&1 || echo "     unexpected: $(basename "$p")"
done
patch -Np1 -s -r /dev/null < /work/kpatches/0029-kernel-6.15.patch >/dev/null 2>&1 || true

# ⛔ The two makefile hunks the fork ships are cut against the x86_64 tarball and
# carry -mno-red-zone -mcmodel=kernel, which the 32-bit file does not have. This
# is that change, ported: ccflags-y, -std=gnu17, ldflags-y, and the objtool
# bypass Linux 6.15+ needs because the blob does not pass objtool.
M=kernel/Makefile.kbuild
grep -q "objtool-enabled" $M || sed -i 's|^MODULE_OBJECT := $(MODULE_NAME).ko|MODULE_OBJECT := $(MODULE_NAME).ko\n\n$(MODULE_NAME).o: override objtool-enabled =|' $M
sed -i 's|^EXTRA_CFLAGS += -D__KERNEL__ -DMODULE -DNVRM|ccflags-y += -std=gnu17 -D__KERNEL__ -DMODULE -DNVRM|' $M
sed -i 's|^EXTRA_CFLAGS +=|ccflags-y +=|; s|\$(EXTRA_LDFLAGS)|$(ldflags-y)|' $M
cd kernel && make SYSSRC="$KSRC" module >/work/kmod.log 2>&1
[ -f nvidia.ko ] || { echo "MODULE BUILD FAILED"; tail -20 /work/kmod.log; exit 1; }
cp nvidia.ko /out/
echo "     nvidia.ko $(du -h nvidia.ko | cut -f1), vermagic $(sed -n 's/.*vermagic=\([^ ]*\).*/\1/p' <<EOF
$(strings -a nvidia.ko | grep '^vermagic=' | head -1)
EOF
)"

# ── the X server it needs ───────────────────────────────────────────────────
echo "   xorg-server 1.19"
cd /work
[ -d xserver/.git ] || git clone --depth 50 -q -b server-1.19-branch \
    https://gitlab.freedesktop.org/xorg/xserver.git xserver
cd xserver && git checkout -q . && git clean -qfd
while read -r p; do
    patch -Np1 -s -r /dev/null -i "/work/xpatches/$p" >/dev/null 2>&1 || true
done < /work/xpatches/order.txt
autoreconf -vfi >/work/autoreconf.log 2>&1

# ⛔ gcc 14 turned four long-standing warnings into errors. On i686 the one that
# bites — CARD32 (unsigned long) vs uint32_t (unsigned int) — is a difference of
# name, not representation, so demoting is correct rather than a papering-over.
CFLAGS="-O2 -Wno-error=incompatible-pointer-types -Wno-error=implicit-function-declaration -Wno-error=int-conversion -Wno-error=implicit-int -Wno-error=return-mismatch" \
./configure --prefix=/opt/x11-19 --enable-glamor --enable-dri2 --enable-dri3 \
  --enable-glx --enable-xorg --disable-xwayland --disable-xnest --disable-xephyr \
  --disable-xvfb --enable-systemd-logind --with-xkb-path=/usr/share/X11/xkb \
  --with-xkb-output=/var/lib/xkb --disable-docs --disable-devel-docs \
  >/work/configure.log 2>&1
make -j"$(nproc)" >/work/make.log 2>&1 || { echo "XSERVER BUILD FAILED"; grep -nE "error:" /work/make.log | head -10; exit 1; }
rm -rf /work/stage && make install DESTDIR=/work/stage >/dev/null 2>&1

P=/work/stage/opt/x11-19
N=/work/NVIDIA-Linux-x86-304.137
mkdir -p "$P/lib/nvidia" "$P/lib/xorg/modules/drivers" "$P/etc"
cp "$N/nvidia_drv.so" "$P/lib/xorg/modules/drivers/"

# ⛔ NVIDIA's libglx REPLACES the server's, or the server loads its own and says
# "Failed to initialize the GLX module".
mv "$P/lib/xorg/modules/extensions/libglx.so" "$P/lib/xorg/modules/extensions/libglx.so.xorg-orig"
cp "$N/libglx.so.304.137" "$P/lib/xorg/modules/extensions/libglx.so"

# ⛔ THE tls/ COPY, NOT THE TOP-LEVEL ONE. The .run ships both and the installer
# probes to choose; the wrong one segfaults the server at _nv015tls on sight.
cp "$N/tls/libnvidia-tls.so.304.137" "$P/lib/nvidia/"
for l in libGL.so.304.137 libnvidia-glcore.so.304.137 libnvidia-cfg.so.304.137; do
    cp "$N/$l" "$P/lib/nvidia/"
done
ln -sf libGL.so.304.137 "$P/lib/nvidia/libGL.so.1"
ln -sf libGL.so.1 "$P/lib/nvidia/libGL.so"

# ⛔ 1.19's own xkbcomp cannot compile against current XKB data — "XKB: Couldn't
# compile keymap", and the fallback fails too, so the server exits. Use the
# system one, which is present on every Ember install.
mv "$P/bin/xkbcomp" "$P/bin/xkbcomp.1-19" 2>/dev/null || true
ln -sf /usr/bin/xkbcomp "$P/bin/xkbcomp"

cat > "$P/etc/xorg.conf" <<'EOF'
Section "ServerLayout"
    Identifier "l"
    Screen 0 "s"
EndSection
Section "Device"
    Identifier "nv"
    Driver     "nvidia"
EndSection
Section "Screen"
    Identifier "s"
    Device     "nv"
    DefaultDepth 24
EndSection
Section "Files"
    ModulePath "/opt/x11-19/lib/xorg/modules"
    ModulePath "/opt/x11-19/lib/xorg/modules/drivers"
EndSection
EOF

cd /work/stage && tar czf /out/x11-19.tar.gz opt
echo "     x11-19.tar.gz $(du -h /out/x11-19.tar.gz | cut -f1)"
