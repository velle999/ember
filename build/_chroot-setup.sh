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
    # ⛔ THE AGP CHIPSET BACKENDS MUST BE IN THE INITRAMFS, or an AGP card runs
    # at PCI speed for ever. nouveau is loaded FROM the initramfs, and dracut
    # includes agpgart (the core) but none of the per-chipset backends — so on
    # the reference machine nouveau probed at 4.3s, found no AGP bridge and fell
    # back to PCI, and via-agp only turned up at 6.8s from the root filesystem,
    # two and a half seconds too late to be of any use.
    #
    # The measured difference on a VIA PT890 with a GeForce 7600 GS:
    #     before   nouveau: pci: failed to acquire agp     GART: 128 MiB
    #     after    nouveau: putting AGP V3 device into 8x mode   GART: 512 MiB
    # which is roughly 133 MB/s against 2.1 GB/s to the card, and it presented
    # as CPU-bound stutter in games that should have run fine.
    #
    # ⚠ A softdep in /etc/modprobe.d does NOT fix this. The root filesystem is
    # not consulted by the initramfs, so the ordering has to be solved by what
    # is IN the initramfs. Tried that first; it changed nothing.
    #
    # All four backends are named because the right one depends on the board and
    # loading a non-matching one is harmless — it simply does not bind.
    mkdir -p /etc/dracut.conf.d
    printf 'add_drivers+=" via-agp intel-agp sis-agp amd64-agp "\n' \
        > /etc/dracut.conf.d/50-ember-agp.conf

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

# ⛔ ENABLE ONLY WHAT EXISTS. `ln -sf /etc/sv/foo .` succeeds whether or not the
# target exists, so a package that was never installed still produced a
# confident-looking symlink: udevd appeared in every listing of enabled services
# while no udev daemon was present at all. runit mentions it once, as "unable to
# change to service directory", in a log nobody reads. This turns that into a
# build failure.
enable_sv() {
    for _s in "$@"; do
        if [ -d "/etc/sv/$_s" ]; then
            ln -sf "/etc/sv/$_s" .
        else
            echo "chroot-setup: /etc/sv/$_s is missing — is its package installed?" >&2
            exit 1
        fi
    done
}

enable_sv dbus udevd
# ⛔ sshd, ON BOTH TARGETS. It was enabled on the Pi image and NOT on the PC one,
# and neither was deliberate: Void's rpi4-base package enables sshd, dhcpcd and
# ntpd on the ARM side, so the asymmetry came from a dependency rather than from
# a decision. The consequence was a Pentium 4 sitting on the network, pinging in
# 1.3 ms, with no way in — on a machine whose whole purpose is being debugged
# remotely because its own display is what we are fixing.
#
# ⚠ THE DEFAULT PASSWORD IS KNOWN. ember/ember with sshd listening is fine on a
# home LAN and is NOT fine anywhere else; anyone putting one of these on a
# network they do not control should change it first. Stated here because a
# default that ships open should say so out loud.
enable_sv sshd
# ⚠ A getty on the serial line, or the console is write-only. Void's six agettys
# are all on VGA tty1-6. On the Pi the serial line is ttyAMA0, not ttyS0.
[ -d /etc/sv/agetty-ttyS0 ]  && ln -sf /etc/sv/agetty-ttyS0  . || true
[ -d /etc/sv/agetty-ttyAMA0 ] && ln -sf /etc/sv/agetty-ttyAMA0 . || true
if [ "$TIER" = desktop ]; then
    # ⛔ REMOVE dhcpcd BEFORE ENABLING NetworkManager, and removing is the
    # operative word — the warning above was already written and it still
    # happened, because Void's rpi4-base package enables dhcpcd on the ARM side
    # without being asked. Enabling NM beside it produced exactly the documented
    # failure: NetworkManager marks every interface another manager holds as
    # "unmanaged", so eth0 was unmanaged, wlan0 was never brought up at all, and
    # a Pi with correct credentials on the card never joined the network.
    #
    # ⚠ A comment is not a guard. This is the second default a dependency has
    # set behind my back (sshd was the first), so the safe assumption is that
    # the service set is whatever the packages decided, not whatever this script
    # enabled — and anything that must be OFF has to be turned off explicitly.
    rm -f /etc/runit/runsvdir/default/dhcpcd \
          /etc/runit/runsvdir/default/dhcpcd-eth0
    enable_sv elogind polkitd NetworkManager lightdm
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
    enable_sv dhcpcd
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

# ⛔ PROVE THE CONFLICT IS GONE. Two network managers is silent — you get a
# machine that looks configured and never joins anything.
if [ "$TIER" = desktop ]; then
    if [ -e /etc/runit/runsvdir/default/dhcpcd ] && \
       [ -e /etc/runit/runsvdir/default/NetworkManager ]; then
        echo "chroot-setup: BOTH dhcpcd and NetworkManager are enabled" >&2
        exit 1
    fi
fi

# ⛔ An explicit success. Nothing below may be a bare `test && command`.
exit 0
