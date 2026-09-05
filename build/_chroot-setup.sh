#!/bin/bash
#
# _chroot-setup.sh — everything that is true of an Ember system regardless of
# how it boots. Runs INSIDE the chroot, on both the PC and the Pi paths.
#
# ⛔ SHARED ON PURPOSE. The accounts, the password method, the sudoers rule and
# the service set are identical on a Pentium 4 and a Raspberry Pi; only the
# bootloader differs, and that is the caller's job. Two copies of this would be
# two copies of the chpasswd trap below, free to be fixed in one and not the
# other — which is exactly the drift that produces "it works on the PC image".
#
# Environment in: USERNAME, PASSWORD, TIER, BOOTLOADER (grub|none), LOOP.
#
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail

# ⛔ NOT `2>/dev/null || true`. If the account cannot be created there is no
# point continuing to build an image nobody can log into.
useradd -m -G wheel,audio,video,input -s /bin/bash "$USERNAME"

# ⛔ -c SHA512, AND IT IS THE WHOLE BUG. This rootfs has no ENCRYPT_METHOD line
# in /etc/login.defs, so shadow 4.8.1 falls back to a crypt method modern
# libxcrypt will not produce — and `chpasswd` then EXITS 0 HAVING WRITTEN
# NOTHING. The first image built and booted perfectly and no password on earth
# would open it: /etc/shadow held "x" for root and "!" for the user, which is a
# locked account. Nothing anywhere said so.
#
# The method is written into login.defs as well, or the same trap springs on the
# machine itself the first time somebody runs `passwd`.
printf 'ENCRYPT_METHOD SHA512\n' >> /etc/login.defs
printf '%s:%s\n' "$USERNAME" "$PASSWORD" | chpasswd -c SHA512
printf 'root:%s\n' "$PASSWORD" | chpasswd -c SHA512

# ⚠ VERIFIED, BECAUSE THE FAILURE MODE IS SILENCE. A shadow field that is not a
# real hash means an account nobody can enter, and the only symptom is a login
# prompt that says the password is wrong — on a machine in another room.
for acct in root "$USERNAME"; do
    h=$(awk -F: -v a="$acct" '$1 == a {print $2}' /etc/shadow)
    case "$h" in
        \$6\$*) : ;;
        *) echo "chroot-setup: $acct has no usable password hash (got '$h')" >&2
           exit 1 ;;
    esac
done

mkdir -p /etc/sudoers.d
echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/wheel
chmod 440 /etc/sudoers.d/wheel

# ── the bootloader, which is the ONLY part that differs ─────────────────────
case "$BOOTLOADER" in
grub)
    # ⛔ REGENERATED --no-hostonly. The initramfs already in the rootfs was built
    # inside a container against the CONTAINER's hardware; a hostonly image made
    # there carries that machine's storage drivers and not the target's, and the
    # failure is a kernel panic on a box with no serial console.
    dracut --force --no-hostonly

    # ⚠ A SERIAL CONSOLE, ON PURPOSE AND SHIPPED. tty0 stays first so a monitor
    # still shows everything; ttyS0 mirrors it. On hardware of this era that is
    # a debugging lifeline, and it is what makes the image testable in qemu with
    # no display at all.
    sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="loglevel=4 console=tty0 console=ttyS0,115200"/' /etc/default/grub
    grep -q '^GRUB_TERMINAL' /etc/default/grub || echo 'GRUB_TERMINAL_OUTPUT="console serial"' >> /etc/default/grub
    echo 'GRUB_SERIAL_COMMAND="serial --speed=115200 --unit=0"' >> /etc/default/grub

    grub-install --target=i386-pc --boot-directory=/boot "$LOOP"
    grub-mkconfig -o /boot/grub/grub.cfg
    ;;
none)
    # ⚠ THE PI HAS NO BOOTLOADER TO INSTALL. Its firmware reads the FAT
    # partition directly — start4.elf loads kernel8.img and the device tree, and
    # there is no GRUB, no MBR boot code and no initramfs in the chain at all.
    # dracut is deliberately NOT run: the Pi kernel mounts its root directly
    # from what cmdline.txt names, and a generated initramfs would simply be
    # ignored unless config.txt were told to load it.
    :
    ;;
*)  echo "chroot-setup: unknown BOOTLOADER '$BOOTLOADER'" >&2; exit 1 ;;
esac

# ⛔ NEVER BOTH NetworkManager AND dhcpcd. They each want the interface and
# fight over it; enabling the pair is the classic way to get a machine that has
# an address for ten seconds at a time.
cd /etc/runit/runsvdir/default
ln -sf /etc/sv/dbus  .
ln -sf /etc/sv/udevd .
# ⚠ A getty on the serial line, or the console is write-only. Void's six agettys
# are all on VGA tty1-6. On the Pi the serial line is ttyAMA0, not ttyS0.
[ -d /etc/sv/agetty-ttyS0 ]  && ln -sf /etc/sv/agetty-ttyS0  . || true
[ -d /etc/sv/agetty-ttyAMA0 ] && ln -sf /etc/sv/agetty-ttyAMA0 . || true
if [ "$TIER" = desktop ]; then
    ln -sf /etc/sv/elogind        .
    ln -sf /etc/sv/polkitd        .
    ln -sf /etc/sv/NetworkManager .
    ln -sf /etc/sv/lightdm        .
    # ⛔ INSTALLING avahi IS NOT ENABLING IT. The package was added and the
    # service left off, so the machine still announced nothing and ember.local
    # still did not resolve — the same shape as the udisks2 gap above.
    [ -d /etc/sv/avahi-daemon ] && ln -sf /etc/sv/avahi-daemon . || true
    # ⚠ NO udisks2 SERVICE, and that is correct: Void D-Bus activates it, so
    # there is nothing to enable. The line that used to be here was
    # `[ -d ... ] && ln -sf ...` as the LAST command, and a false test as the
    # last command becomes the exit status under set -e — the image build
    # reported FAILURE after completing successfully.
else
    ln -sf /etc/sv/dhcpcd .
fi
# ⚠ nss-mdns DOES NOTHING UNTIL nsswitch.conf ASKS FOR IT. The library being
# installed is not the same as glibc consulting it, so .local lookups keep going
# to DNS and failing. mdns_minimal goes BEFORE dns and carries
# [NOTFOUND=return], or every miss on a .local name waits for a DNS timeout
# first — which is the difference between "not found" and "hangs for ten
# seconds".
if [ -f /etc/nsswitch.conf ] && ! grep -q mdns /etc/nsswitch.conf; then
    sed -i 's/^\(hosts:.*\)files\(.*\)$/\1files mdns_minimal [NOTFOUND=return]\2/' /etc/nsswitch.conf
fi

# ⛔ An explicit success. Nothing below may be a bare `test && command`.
exit 0
