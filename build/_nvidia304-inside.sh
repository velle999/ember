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
# ⛔ PIN THE HEADERS TO THE KERNEL THIS IMAGE ACTUALLY SHIPS. This used to be an
# unpinned `xbps-install linux6.18-headers`, running AFTER the -Suy above has
# synced Void's remote repos -- so if upstream ever carries a newer revision than
# the locally built kernel, xbps picks the remote one on version and ignores the
# mounted local repo. The build then succeeds and produces an nvidia.ko whose
# vermagic can never match the running kernel, with nothing anywhere saying so.
: "${KVER_PKG:?KVER_PKG must be set by mk-nvidia304.sh}"
if ! xbps-install -y --repository=/emberrepo "linux6.18-headers-${KVER_PKG}" >/tmp/hdr.log 2>&1; then
    echo "nvidia304: could not install linux6.18-headers-${KVER_PKG} from /emberrepo" >&2
    tail -15 /tmp/hdr.log >&2
    exit 1
fi
# ⚠ Verify what actually got installed, not what was asked for.
HDRV=$(xbps-query -p pkgver linux6.18-headers 2>/dev/null || echo "?")
case "$HDRV" in
    *"$KVER_PKG"*) echo "   headers $HDRV (pinned)" ;;
    *) echo "nvidia304: headers are $HDRV, expected $KVER_PKG -- the module would not load" >&2
       exit 1 ;;
esac
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
# ⛔ NAMED FILE FROM A THIRD-PARTY FORK -- assert it is there. `|| true` hid both
# a rename and a failed apply, and the module build then died later with the
# generic "MODULE BUILD FAILED" tail instead of naming the missing patch.
K615=/work/kpatches/0029-kernel-6.15.patch
[ -f "$K615" ] || { echo "nvidia304: $K615 is missing -- the fork has renamed its patches" >&2; exit 1; }
# ⛔ ONE HUNK OF THIS PATCH IS EXPECTED TO FAIL ON i686, AND THAT IS NOT AN
# ERROR. Hunk 2 of kernel/Makefile.kbuild is cut against the x86_64 tarball --
# it carries -mno-red-zone -mcmodel=kernel, which the 32-bit Makefile does not
# have -- and the sed block below ports that same change for this architecture
# on purpose. Asserting on patch(1)'s exit status therefore stopped a 45-minute
# build on the one hunk the script goes on to do by hand:
#     nvidia304: 0029-kernel-6.15.patch did not apply:
#     1 out of 3 hunks FAILED
# ⚠ The assert is still here, because a patch that silently stops arriving is
# what `|| true` used to hide. It just asks the right question: did the C half
# -- the timer_delete_sync/timer_container_of shims Linux 6.15 needs -- land?
# Content, not exit status.
patch -Np1 -s -r /dev/null --forward < "$K615" >/tmp/k615.log 2>&1 || true
grep -q 'timer_container_of' kernel/nv.c && grep -q 'timer_delete_sync' kernel/nv-linux.h || {
    echo "nvidia304: 0029-kernel-6.15.patch did not deliver its 6.15 shims:" >&2
    tail -10 /tmp/k615.log >&2
    echo "  (the Makefile hunk failing is expected on i686; the nv.c ones are not)" >&2
    exit 1; }

# ⛔ The two makefile hunks the fork ships are cut against the x86_64 tarball and
# carry -mno-red-zone -mcmodel=kernel, which the 32-bit file does not have. This
# is that change, ported: ccflags-y, -std=gnu17, ldflags-y, and the objtool
# bypass Linux 6.15+ needs because the blob does not pass objtool.
M=kernel/Makefile.kbuild
grep -q "objtool-enabled" $M || sed -i 's|^MODULE_OBJECT := $(MODULE_NAME).ko|MODULE_OBJECT := $(MODULE_NAME).ko\n\n$(MODULE_NAME).o: override objtool-enabled =|' $M
sed -i 's|^EXTRA_CFLAGS += -D__KERNEL__ -DMODULE -DNVRM|ccflags-y += -std=gnu17 -D__KERNEL__ -DMODULE -DNVRM|' $M
sed -i 's|^EXTRA_CFLAGS +=|ccflags-y +=|; s|\$(EXTRA_LDFLAGS)|$(ldflags-y)|' $M
# ⛔ AND THE PORTED CHANGE IS CHECKED TOO. It replaces a hunk that is allowed to
# fail above, so nothing else would notice if a future tarball spelled these
# lines differently and the seds matched nothing.
grep -q 'objtool-enabled' $M || { echo "nvidia304: the objtool bypass did not reach $M" >&2; exit 1; }
grep -q '^ccflags-y' $M      || { echo "nvidia304: EXTRA_CFLAGS was never converted in $M" >&2; exit 1; }

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
  --disable-libunwind \
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

# ⛔ 304 SHIPS NO EGL AT ALL, AND THAT IS NOT A COSMETIC GAP. Anything that asks
# for EGL -- wine 11 by default, and plenty else -- finds Mesa's, Mesa looks for
# a DRM device that a blacklisted-nouveau box does not have, and the app renders
# in llvmpipe on a machine whose X server is driving the GPU. ember-egl-glx is an
# EGL that performs the calls with GLX against this same libGL. It lives here,
# beside libGL, so it is on the path exactly when 50-ember-gl.sh puts the 304
# directory there -- never on a nouveau boot.
cc -O2 -Wall -fPIC -shared -o "$P/lib/nvidia/libEGL.so.1" /work/ember-egl-glx.c \
   -Wl,-soname,libEGL.so.1 -ldl \
   || { echo "EGL SHIM BUILD FAILED"; exit 1; }
ln -sf libEGL.so.1 "$P/lib/nvidia/libEGL.so"

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

# ⛔ WITHOUT THIS THE DRIVER IS PRESENT AND UNUSED. The server finds every
# device through udev and says "No input driver specified, ignoring this
# device", because the rules that normally assign libinput live in
# /usr/share/X11/xorg.conf.d/40-libinput.conf and this server reads its own
# prefix, not the system's. Shipping the driver is not enough; it has to be
# asked for.
Section "InputClass"
    Identifier  "libinput all"
    MatchDevicePath "/dev/input/event*"
    Driver      "libinput"
EndSection
EOF

# ── the input driver ────────────────────────────────────────────────────────
#
# ⛔ WITHOUT THIS THERE IS NO MOUSE AND NO KEYBOARD. The server finds the
# devices through udev and then says "No input driver specified, ignoring this
# device" for every one of them, because an input driver is ABI-locked and the
# system's libinput_drv.so is built for xorg-server 21.1. This server is ABI
# XInput 24.1. The Arch instructions say the same thing in the form "downgrade
# xf86-input-libinput or the keyboard and mouse did not work".
#
# ⚠ Built against the SDK we just staged, not the system one — PKG_CONFIG_PATH
# points at /work/stage/opt/x11-19/lib/pkgconfig so xorg-server.pc resolves to
# the 1.19 tree and the module lands in its own modules/input directory.
echo "   input driver"
# ⚠ THE SYSTEM PATH MUST STAY ON PKG_CONFIG_PATH. Setting it to the 1.19 tree
# alone makes xorg-server.pc resolve and then fail on its own dependency:
# "Package pixman-1, required by xorg-server, not found".
xbps-install -Sy libinput-devel libevdev-devel mtdev-devel pixman-devel libdrm-devel >/dev/null 2>&1
cd /work
# ⚠ .tar.bz2 — x.org only switched this driver to .tar.xz at 1.2.1, and 1.1.0
# is the last version the fork pairs with 1.19.
LIBIN=xf86-input-libinput-1.1.0
[ -f "$LIBIN.tar.bz2" ] || curl -fsSL -O \
  "https://www.x.org/releases/individual/driver/$LIBIN.tar.bz2"
rm -rf "$LIBIN" && tar xf "$LIBIN.tar.bz2" && cd "$LIBIN"
# ⛔ NOT PKG_CONFIG_PATH. 1.19's xorg-server.pc has Requires.private naming the
# old split protocol packages AND dri.pc, which modern Mesa does not ship — so
# pkg-config can never resolve it, whatever the path. X input modules are
# dlopened and link nothing from the server, so the SDK headers alone suffice,
# which is what configure itself suggests when it fails.
XORG_CFLAGS="-I/work/stage/opt/x11-19/include/xorg $(pkg-config --cflags pixman-1 libdrm)" \
XORG_LIBS=" " \
CFLAGS="-O2 -Wno-error=incompatible-pointer-types -Wno-error=int-conversion" \
./configure --prefix=/opt/x11-19 \
  --with-xorg-module-dir=/opt/x11-19/lib/xorg/modules \
  >/work/input-configure.log 2>&1 || { echo "INPUT CONFIGURE FAILED"; tail -15 /work/input-configure.log; exit 1; }
make -j"$(nproc)" >/work/input-make.log 2>&1 || { echo "INPUT BUILD FAILED"; grep -nE "error:" /work/input-make.log | head -8; exit 1; }
make install DESTDIR=/work/stage >/dev/null 2>&1
ls /work/stage/opt/x11-19/lib/xorg/modules/input/libinput_drv.so >/dev/null 2>&1 \
  && echo "     libinput_drv.so built against ABI 24.1" \
  || { echo "INPUT DRIVER MISSING AFTER INSTALL"; exit 1; }

cd /work/stage && tar czf /out/x11-19.tar.gz opt
echo "     x11-19.tar.gz $(du -h /out/x11-19.tar.gz | cut -f1)"
