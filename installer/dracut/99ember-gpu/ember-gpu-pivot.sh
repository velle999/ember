#!/bin/sh
#
# ember-gpu-pivot — carry the initramfs's decision across switch_root.
#
# ⛔ THE BLACKLIST HAS TO SURVIVE THE HANDOVER, or the real root's coldplug
# loads nouveau a second later and undoes the whole point: /etc/modprobe.d in
# the initramfs stops applying the moment the root filesystem changes.
#
# ⛔ AND IT MUST NOT OUTLIVE THE BOOT. Writing into $NEWROOT/etc would leave a
# permanent blacklist on an INSTALLED system, decided by one boot's hardware --
# so this writes /run/modprobe.d, which kmod reads exactly like /etc/modprobe.d
# and which is a tmpfs that is empty again on the next boot. `ember-gpu nvidia`
# is the thing that makes a choice permanent, and it writes GRUB, not this.
#
# SPDX-License-Identifier: GPL-2.0-or-later

SRC=${EMBER_GPU_MODPROBE_D:-/etc/modprobe.d}/ember-gpu-nouveau.conf
DST_ROOT=${NEWROOT:-/sysroot}
LOG=${EMBER_GPU_LOG:-/run/ember-gpu-early.log}

[ -f "$SRC" ] || return 0 2>/dev/null || exit 0

if mkdir -p "$DST_ROOT/run/modprobe.d" 2>/dev/null &&
   cp "$SRC" "$DST_ROOT/run/modprobe.d/ember-gpu-nouveau.conf" 2>/dev/null; then
    echo "ember-gpu-early: blacklist carried into $DST_ROOT/run/modprobe.d" >> "$LOG" 2>/dev/null || true
else
    # ⚠ Not fatal, and it says so rather than failing the boot: the worst case
    # is nouveau binding the card in the real root, which is a working desktop
    # on the open driver -- exactly where the machine would have been anyway.
    echo "ember-gpu-early: could not carry the blacklist into $DST_ROOT" >> "$LOG" 2>/dev/null || true
fi
return 0 2>/dev/null || exit 0
