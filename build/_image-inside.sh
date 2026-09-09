#!/bin/sh
#
# _image-inside.sh — the half of mkimage.sh that runs as root inside the
# container. Split out because it is three levels of quoting otherwise: a shell
# string, inside a docker -c string, inside a chroot -c string. That nesting is
# not a style objection — the first version of this file would not parse, and a
# version that parses but escapes one quote wrongly builds a subtly wrong image.
#
# Everything it needs arrives in the environment. Not invoked directly.
#
# ⚠ POSIX sh, and `set -eu` WITHOUT pipefail. The Void container ships dash as
# /bin/sh and no bash at all — the first run of this died on `stat /bin/bash: no
# such file or directory` before executing a line. The script inside the CHROOT
# is a different matter and may use bash, because the rootfs being built has it.
#
# SPDX-License-Identifier: GPL-2.0-or-later
set -eu

IMG="/out/$IMGNAME"

# ⛔ NOT `>/dev/null 2>&1 || true`. That is what this line was, and it turned a
# failed install into `parted: not found` twenty lines later with the actual
# reason discarded. If the image cannot be partitioned, say so here.
# ⚠ xbps UPDATES ITSELF FIRST OR REFUSES TO WORK AT ALL. The container image is
# older than the repository it is pointed at, and xbps will not install anything
# while it is behind: "The 'xbps' package must be updated". It is a hard stop,
# not a warning.
xbps-install -Suy xbps
xbps-install -Sy parted e2fsprogs util-linux
for t in parted mkfs.ext4 losetup blkid; do
    command -v "$t" >/dev/null || { echo "mkimage: $t missing after install" >&2; exit 1; }
done

# One bootable primary partition, msdos table. The 1 MiB start leaves the gap
# GRUB embeds its core image into; without it grub-install refuses.
parted -s "$IMG" mklabel msdos
parted -s "$IMG" mkpart primary ext4 1MiB 100%
parted -s "$IMG" set 1 boot on

LOOP=$(losetup --find --partscan --show "$IMG")
cleanup() {
    umount -R /mnt 2>/dev/null || true
    losetup -d "$LOOP" 2>/dev/null || true
}
trap cleanup EXIT

# ⚠ CONSERVATIVE ext4 FEATURES. metadata_csum_seed and orphan_file are both
# newer than plenty of bootloaders and rescue tools, and the cost of being wrong
# is a trip to a machine that will not boot rather than an error message.
# Nothing is gained by having them on a 2 GB root.
mkfs.ext4 -q -O ^metadata_csum_seed,^orphan_file -L "$HOSTNAME_" "${LOOP}p1"
mount "${LOOP}p1" /mnt
cp -a /out/rootfs/. /mnt/

# The installer travels in the image, because the image IS the installer: you
# boot it from a USB stick and it puts itself on a disk.
install -Dm755 /installer/ember-install /mnt/usr/bin/ember-install
install -Dm755 /installer/ember-mount-windows /mnt/usr/bin/ember-mount-windows
install -Dm755 /installer/ember-disc /mnt/usr/bin/ember-disc
install -Dm755 /installer/ember-expand-root /mnt/usr/bin/ember-expand-root
install -Dm755 /installer/ember-xorg-oom-reset /mnt/usr/libexec/ember-xorg-oom-reset
# ⚠ OPTIONAL AND GITIGNORED. Drop a NetworkManager keyfile at
# installer/wifi.nmconnection and every image built afterwards joins the network
# on first boot — which is the difference between a headless machine you can ssh
# to and one you must carry a monitor to. It holds a PSK, so it is in .gitignore
# and must never be committed.
#
# ⛔ 0600 root:root OR NETWORKMANAGER IGNORES IT ENTIRELY, logging "ignoring
# insecure configuration file" and behaving exactly as though no connection had
# been configured at all.
if [ -f /installer/wifi.nmconnection ]; then
    install -Dm600 -o 0 -g 0 /installer/wifi.nmconnection \
        /mnt/etc/NetworkManager/system-connections/wifi.nmconnection
    echo "inside: wifi connection pre-seeded"
fi
install -Dm644 /installer/06-ember-expand.sh /mnt/etc/runit/core-services/06-ember-expand.sh
install -Dm755 /installer/ember-swap /mnt/usr/bin/ember-swap
install -Dm644 /installer/07-ember-swap.sh /mnt/etc/runit/core-services/07-ember-swap.sh
# ⚠ THE OTHER HALF OF THE SWAP STORY, AND THE ONE THE BOOT MEDIUM ACTUALLY GETS.
# ember-swap declines on a live stick — 2 x RAM plus slack does not fit in the
# free space on an 8 GB device — so the image boots a 2 GB desktop with no swap
# at all and the session is OOM-killed back to the login screen. ember-zram runs
# after it and only when it declined. See installer/ember-zram.
install -Dm755 /installer/ember-zram /mnt/usr/bin/ember-zram
install -Dm644 /installer/07-ember-zram.sh /mnt/etc/runit/core-services/07-ember-zram.sh

# ── graphics stack selection ────────────────────────────────────────────────
#
# ⚠ THE CARD DECIDES, AT BOOT. ember-gpu-detect reads the boot VGA device:
# NVIDIA in 304's supported list -> the proprietary stack; anything else ->
# the in-kernel driver (nouveau for unsupported NVIDIA, radeon, i915, ...).
# ember-gpu-apply loads the module, ember-xserver picks the matching X server,
# and `ember-gpu <mode>` overrides the lot.
#
# ⛔ ON NVIDIA THE DEFAULT IS NOW PROPRIETARY, WHICH ARMS A KERNEL BUG. With
# nvidia.ko loaded, reading /proc/modules NULL-derefs on this hardware: `lsmod`
# and anything invoking dracut take the machine down, and that now includes a
# KERNEL UPGRADE on a machine that boots this way by default. The way out needs
# no desktop — `e` at the GRUB menu, append ember.gpu=nouveau — and is spelled
# out in installer/ember-gpu. This is a deliberate trade for a card where
# nouveau is measurably slower and shows drawing artefacts.
#
# ⚠ THE 304 STACK ITSELF IS STILL OPTIONAL, like the wifi keyfile. Built by
# build/mk-nvidia304.sh; without it the detector finds no nvidia.ko and answers
# nouveau, so an image built without it is simply an open-driver image.
install -Dm755 /installer/ember-gpu        /mnt/usr/bin/ember-gpu
install -Dm755 /installer/ember-gpu-detect /mnt/usr/bin/ember-gpu-detect
install -Dm755 /installer/ember-gpu-apply  /mnt/usr/bin/ember-gpu-apply
install -Dm755 /installer/ember-xserver    /mnt/usr/libexec/ember-xserver
install -Dm644 /installer/08-ember-gpu.sh  /mnt/etc/runit/core-services/08-ember-gpu.sh
# ⚠ Sourced by /etc/lightdm/Xsession out of xinitrc.d, so GL CLIENTS get the
# proprietary libGL too — the server having it is not enough.
install -Dm644 /installer/50-ember-gl.sh   /mnt/etc/X11/xinit/xinitrc.d/50-ember-gl.sh
install -Dm644 /installer/nvidia304-supported.ids \
               /mnt/usr/share/ember/nvidia304-supported.ids
# ⛔ Without this rule the 304 desktop never starts: no DRM device means seat0
# is not graphical and lightdm waits for ever. See the rule for the full story.
install -Dm644 /installer/71-ember-nvidia-seat.rules \
               /mnt/etc/udev/rules.d/71-ember-nvidia-seat.rules
# ⛔ TEST BOTH HALVES. This used to check only nvidia.ko -- but the module is
# copied out BEFORE the X server is built, and _nvidia304-inside.sh has an
# explicit "XSERVER BUILD FAILED; exit 1" path. So a partial 304 build leaves
# exactly the state the old guard accepted, tar then fails under set -eu, and
# mkimage.sh aborts with the loop device still attached -- on every run, until
# somebody deletes the output directory by hand.
if [ -d /nvidia304 ] && [ -f /nvidia304/nvidia.ko ] && [ -f /nvidia304/x11-19.tar.gz ]; then
    tar xzf /nvidia304/x11-19.tar.gz -C /mnt
    install -Dm644 /nvidia304/nvidia.ko /mnt/opt/x11-19/nvidia.ko
    # ⛔ THIS IS THE ONLY PLACE THE MODULE AND THE KERNEL MEET. mk-nvidia304.sh
    # builds nvidia.ko against whatever headers it was given and prints a
    # vermagic nobody compares to anything; the rootfs carries the kernel. A
    # mismatch produces a module that can never insmod on the image it rides,
    # and the only symptom is a silent fallback to nouveau on the target.
    KMOD_KVER=$(ls /mnt/usr/lib/modules 2>/dev/null | head -1)
    # ⚠ grep, NOT modinfo: kmod is not installed in this container, so a modinfo
    # check silently produced an empty string and the gate never fired -- a
    # check that cannot run is worse than no check, because it reads as passing.
    NV_VERMAGIC=$(grep -aom1 'vermagic=[^ ]*' /nvidia304/nvidia.ko 2>/dev/null | cut -d= -f2)
    if [ -z "$NV_VERMAGIC" ]; then
        echo "inside: ⚠ could not read vermagic from nvidia.ko — not verifying it" >&2
    elif [ -n "$KMOD_KVER" ] && [ "$KMOD_KVER" != "$NV_VERMAGIC" ]; then
        echo "inside: ⛔ nvidia.ko vermagic '$NV_VERMAGIC' != kernel '$KMOD_KVER'" >&2
        echo "        The 304 module cannot load on this image. Rebuild it:" >&2
        echo "        build/mk-nvidia304.sh" >&2
        exit 1
    fi
    echo "inside: NVIDIA 304 stack included, vermagic $NV_VERMAGIC matches the kernel"
elif [ -f /nvidia304/nvidia.ko ] || [ -f /nvidia304/x11-19.tar.gz ]; then
    # ⚠ Half a stack is a build that died in the middle, not an image built
    # without 304. Say so rather than silently shipping the open drivers.
    echo "inside: ⚠ INCOMPLETE NVIDIA 304 stack — module and X server must BOTH" >&2
    echo "        be present. Re-run build/mk-nvidia304.sh. Shipping open drivers." >&2
else
    echo "inside: no NVIDIA 304 stack — open drivers only (build/mk-nvidia304.sh builds it)"
fi

install -Dm644 /installer/99-ember-diag.sh /mnt/etc/runit/core-services/99-ember-diag.sh
install -Dm644 /installer/thunar-uca.xml /mnt/etc/xdg/Thunar/uca.xml
# ⛔ VOID'S cdemu-daemon PACKAGE SHIPS NO D-BUS SERVICE FILE. It installs the
# binary, a man page and locales -- nothing else -- so the session bus has no
# way to start it and `cdemu load` fails with
#
#     GDBus.Error:org.freedesktop.DBus.Error.ServiceUnknown:
#     The name net.sf.cdemu.CDEmuDaemon was not provided by any .service files
#
# which reads as "the daemon crashed" rather than "nothing can ever start it".
# Upstream ships this file; we supply it because the package does not.
install -Dm644 /installer/net.sf.cdemu.CDEmuDaemon.service \
               /mnt/usr/share/dbus-1/services/net.sf.cdemu.CDEmuDaemon.service

# ── greeter branding ────────────────────────────────────────────────────────
#
# ⚠ Without this the login screen shows lightdm-gtk-greeter's stock placeholder
# avatar -- a grey silhouette in a circle -- which reads as an unfinished
# desktop rather than as a distribution. default-user-image is the fallback the
# greeter uses for an account with no face of its own, which is exactly ours.
install -Dm644 /installer/ember-logo.png /mnt/usr/share/ember/ember-logo.png
GCONF=/mnt/etc/lightdm/lightdm-gtk-greeter.conf
if [ -f "$GCONF" ]; then
    sed -i '/^default-user-image=/d' "$GCONF"
    sed -i 's|^\[greeter\]|&\ndefault-user-image=/usr/share/ember/ember-logo.png|' "$GCONF"
    grep -q '^default-user-image=/usr/share/ember/ember-logo.png' "$GCONF" || {
        echo "inside: greeter image not set" >&2; exit 1; }
    echo "inside: greeter branded"
else
    echo "inside: no lightdm-gtk-greeter.conf — greeter not branded" >&2
fi
# ⚠ ONE X CONFIG, LIVE AND INSTALLED. There were briefly two, because the live
# medium ran AccelMethod "none" while the nv30 pixmap leak was open; that is
# fixed in Mesa now (patches/mesa-nv30-surface-del-leaks-resource-ref.patch) and
# the split is gone with it. See installer/20-modesetting.conf.
install -Dm644 /installer/20-modesetting.conf /mnt/etc/X11/xorg.conf.d/20-modesetting.conf

# ── libretro cores ──────────────────────────────────────────────────────────
# ⚠ /usr/lib/libretro is where RetroArch looks by default on Linux, and the
# config below says so explicitly rather than relying on that default: a
# retroarch.cfg that names no core directory sends a first-time user to the
# online updater, which is the one thing this machine cannot use.
if [ -d /cores ] && [ -n "$(ls -A /cores 2>/dev/null)" ]; then
    mkdir -p /mnt/usr/lib/libretro
    cp -a /cores/. /mnt/usr/lib/libretro/
    chmod 0644 /mnt/usr/lib/libretro/*.so 2>/dev/null || true
    mkdir -p /mnt/etc
    if [ -f /mnt/etc/retroarch.cfg ]; then
        sed -i 's|^libretro_directory =.*|libretro_directory = "/usr/lib/libretro"|' /mnt/etc/retroarch.cfg
        grep -q '^libretro_directory' /mnt/etc/retroarch.cfg || \
            echo 'libretro_directory = "/usr/lib/libretro"' >> /mnt/etc/retroarch.cfg
    else
        echo 'libretro_directory = "/usr/lib/libretro"' > /mnt/etc/retroarch.cfg
    fi
    echo "inside: $(ls /mnt/usr/lib/libretro/*.so 2>/dev/null | wc -l) libretro cores installed"
fi

# ── RetroArch menu assets and joypad profiles ───────────────────────────────
# ⛔ Void's retroarch package ships NEITHER, and the failure of each is silent
# and misleading: with no assets the Ozone/XMB menus draw without icons or
# fonts and look like a corrupt install, and with no joypad profiles every
# controller is "not configured" and simply does nothing. RetroArch downloads
# both from its Online Updater, which is the one thing this machine cannot do.
if [ -d /ra-assets ] && [ -n "$(ls -A /ra-assets 2>/dev/null)" ]; then
    mkdir -p /mnt/usr/share/libretro
    cp -a /ra-assets/. /mnt/usr/share/libretro/
    chown -R 0:0 /mnt/usr/share/libretro
    # ⚠ The defaults point into ~/.config/retroarch, which is empty on a new
    # user, so shipping the files is not enough — the config has to name them.
    # ⛔ THREE PATHS, NOT TWO. libretro_info_path is the one that decides
    # whether "Load Content" shows any games at all: RetroArch filters the
    # browser by the extensions a core declares, and it reads those from the
    # core's .info file. With no info path the browser lists directories and
    # nothing else, so a full ROM folder looks empty and the file browser looks
    # broken. Setting it is not optional just because the menu renders without it.
    if [ -f /mnt/etc/retroarch.cfg ]; then
        set_cfg() {   # key, value — replace whether commented, present, or absent
            sed -i "s|^# *$1 =.*|$1 = \"$2\"|" /mnt/etc/retroarch.cfg
            sed -i "s|^$1 =.*|$1 = \"$2\"|" /mnt/etc/retroarch.cfg
            grep -q "^$1 =" /mnt/etc/retroarch.cfg || echo "$1 = \"$2\"" >> /mnt/etc/retroarch.cfg
        }
        set_cfg assets_directory     /usr/share/libretro/assets
        set_cfg joypad_autoconfig_dir /usr/share/libretro/autoconfig
        set_cfg libretro_info_path   /usr/share/libretro/info
    fi
    # ⚠ Prove all three arrived. The assets check used to stand alone, which is
    # how info files went missing without anything noticing.
    n_info=$(ls /mnt/usr/share/libretro/info/*.info 2>/dev/null | wc -l)
    echo "inside: retroarch assets + $(find /mnt/usr/share/libretro/autoconfig -name '*.cfg' 2>/dev/null | wc -l) joypad profiles + $n_info core info files installed"
    [ "$n_info" -ge 100 ] || echo "inside: WARNING only $n_info core info files - the content browser will show no games" >&2
fi


UUID=$(blkid -s UUID -o value "${LOOP}p1")
printf 'UUID=%s\t/\text4\tdefaults,noatime\t0 1\n' "$UUID" > /mnt/etc/fstab
printf '%s\n' "$HOSTNAME_" > /mnt/etc/hostname

mount --bind /dev  /mnt/dev
mount --bind /proc /mnt/proc
mount --bind /sys  /mnt/sys

# ⛔ THE CHROOT SCRIPT IS SHARED WITH THE PI PATH — see build/_chroot-setup.sh.
# It used to be a heredoc here, which meant the Pi builder would have needed its
# own copy of the accounts, the chpasswd trap and the service set. One of those
# copies would eventually have been fixed and the other not.
install -Dm755 /chroot-setup.sh /mnt/tmp/setup.sh
chroot /mnt env USERNAME="$USERNAME" PASSWORD="$PASSWORD" \
                TIER="$TIER" LOOP="$LOOP" BOOTLOADER=grub /tmp/setup.sh
rm -f /mnt/tmp/setup.sh

# ── optional developer ssh key ──────────────────────────────────────────────
#
# ⛔ OFF UNLESS ASKED FOR, AND IT MUST NEVER BE ON FOR A RELEASE. An image with
# somebody's key baked in lets that person into every machine installed from it.
# So this needs BOTH a key file AND EMBER_DEV_SSH_KEY=1 on the command line;
# either alone does nothing. installer/authorized_keys is gitignored.
#
# ⚠ It exists because sshd IS enabled by default (see _chroot-setup.sh) but no
# key is, so a freshly installed machine can only be reached by typing the
# password at its own keyboard — which is the one thing you cannot do when the
# thing you are debugging is the display.
if [ "${DEV_SSH_KEY:-0}" = 1 ] && [ -f /installer/authorized_keys ]; then
    install -d -m 700 -o 1000 -g 1000 /mnt/home/"$USERNAME"/.ssh
    install -Dm600 -o 1000 -g 1000 /installer/authorized_keys \
        /mnt/home/"$USERNAME"/.ssh/authorized_keys
    echo "inside: ⚠ DEVELOPER SSH KEY BAKED IN — do not release this image"
fi

# ── verify by content, not by exit status ───────────────────────────────────
#
# grub-mkconfig inside a chroot on a loop device happily writes
# root=/dev/loop0p1 into grub.cfg. That is correct in here and meaningless on
# the target, and nothing else would notice until the machine failed to boot.
if grep -q '/dev/loop' /mnt/boot/grub/grub.cfg; then
    echo "mkimage: grub.cfg names a loop device — it would not boot" >&2
    grep -n '/dev/loop' /mnt/boot/grub/grub.cfg | head -5 >&2
    exit 1
fi
if ! grep -q "$UUID" /mnt/boot/grub/grub.cfg; then
    echo "mkimage: grub.cfg does not reference the root UUID $UUID" >&2
    exit 1
fi
if ! dd if="$IMG" bs=512 count=1 status=none | grep -qa GRUB; then
    echo "mkimage: no GRUB signature in the MBR — nothing would load" >&2
    exit 1
fi
# ⚠ Counted, not tested with a glob: `[ -s /mnt/boot/initramfs-*.img ]` passes
# the expansion straight to `[`, which errors on "too many arguments" the moment
# there is more than one kernel installed.
if [ "$(find /mnt/boot -maxdepth 1 -name 'initramfs-*.img' -size +1M | wc -l)" -lt 1 ]; then
    echo "mkimage: no initramfs of any size in /boot" >&2
    exit 1
fi

echo "inside: root UUID $UUID, grub.cfg and MBR both verified"
sync
