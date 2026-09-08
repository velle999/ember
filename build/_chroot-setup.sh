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
    # ⚠ nouveau accel_move=1 fence_sema=0 — SET ONLY IF THE MODULE HAS THEM.
    #
    # fence_sema=0 is LOAD-BEARING, not an optimisation. Measured on the
    # reference machine, same kernel and Mesa and vram_pushbuf=0 either way:
    #
    #     fence_sema=0   10 rounds of 45s unthrottled glxgears, ZERO errors
    #     fence_sema=1   two channels dead 16 SECONDS into round 1, Xorg's
    #                    among them
    #
    # ⛔ These parameters exist ONLY on the patched module, and modprobe REFUSES
    # a module given an unknown parameter — writing them unconditionally into an
    # image built without the patched kernel leaves the machine with NO graphics
    # driver at all. So ask the module rather than assuming either way.
    #
    # ⚠ THIS MUST RUN BEFORE dracut BELOW. The initramfs carries its own copy of
    # /etc/modprobe.d, frozen at the moment dracut runs, and nouveau loads FROM
    # the initramfs — so a file written after dracut has no effect on the next
    # boot, and editing it on the installed system later has none either.
    #
    # ⛔ THIS BLOCK USED TO SKIP THEM UNCONDITIONALLY, with a comment saying the
    # patched module "does not ship in the image yet". That was true when it was
    # written and false three hours later, and the result was an image that
    # booted the patched kernel with fence_sema at its default of 1 — which
    # crashed the installer's own UI. A condition that reads the module cannot
    # go stale the way a comment about the future can.
    KMOD=$(find /usr/lib/modules /lib/modules -name 'nouveau.ko*' 2>/dev/null | head -1)
    if [ -n "$KMOD" ] && modinfo -p "$KMOD" 2>/dev/null | grep -q '^fence_sema'; then
        printf 'options nouveau accel_move=1 fence_sema=0\n' > /etc/modprobe.d/nouveau-fix.conf
        echo "chroot: patched nouveau detected - accel_move=1 fence_sema=0 set"
        grep -q 'fence_sema=0' /etc/modprobe.d/nouveau-fix.conf || {
            echo "chroot: nouveau-fix.conf did not take" >&2; exit 1; }
    else
        echo "chroot: stock nouveau - accel_move/fence_sema NOT set (they would refuse to load)"
    fi

    dracut --force --no-hostonly

    # ⚠ A SERIAL CONSOLE, ON PURPOSE AND SHIPPED. tty0 stays first so a monitor
    # still shows everything; ttyS0 mirrors it. On hardware of this era that is
    # a debugging lifeline, and it is what makes the image testable in qemu with
    # no display at all.
    # ⛔ nouveau.vram_pushbuf=0 — DMA push buffers in GART, NOT VRAM. This one
    # parameter is the difference between a desktop that dies every few minutes
    # and one that does not.
    #
    # With the push buffers in VRAM the engine intermittently executes garbage
    # at the FIRST dwords of a freshly created channel's buffer — `get` still at
    # offset 0 — and the channel is dead from birth:
    #
    #     nouveau: fifo: DMA_PUSHER - ch 2 [glxinfo] get 1ceec000 put 1ceec090
    #                    state 80000000 (err: INVALID_CMD)
    #     nouveau: channel 2 stopped retiring fences - marking it dead
    #
    # Every GL client was exposed: Xorg, zenity dialogs, RetroArch, Wine. In
    # GART the CPU writes the buffer through ordinary system memory and the
    # problem disappears. Measured on the reference machine over one boot:
    #
    #                              vram_pushbuf=1   vram_pushbuf=0
    #     DMA_PUSHER                     40                0
    #     channel stopped retiring       13                0
    #     gr BAD_ARGUMENT                22                0
    #     oom-killer                      9                0
    #
    # under 10 rounds of 45s unthrottled glxgears at ~1100 FPS, 66 glxinfo runs
    # and repeated ISO mounts — the workload that used to kill it.
    #
    # ⚠ It is the COMBINATION that is stable: this plus fence_sema=0 and
    # accel_move=1 in /etc/modprobe.d. An earlier test of vram_pushbuf=0 alone,
    # without those, wedged — do not read that as a verdict on this setting.
    # ⚠ Still NOT a substitute for the AGP backends above: without via-agp the
    # GART is 128 MiB and the shortfall lands in system RAM until the OOM killer
    # takes Xorg.
    sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="loglevel=4 console=tty0 console=ttyS0,115200 nouveau.vram_pushbuf=0"/' /etc/default/grub
    grep -q '^GRUB_TERMINAL' /etc/default/grub || echo 'GRUB_TERMINAL_OUTPUT="console serial"' >> /etc/default/grub
    echo 'GRUB_SERIAL_COMMAND="serial --speed=115200 --unit=0"' >> /etc/default/grub

    grep -q "nouveau.vram_pushbuf=0" /etc/default/grub || {
        echo "chroot: vram_pushbuf missing from the kernel cmdline" >&2; exit 1; }

    # ⚠ ttm.dma32_pages_limit — the low-memory brake that never engages.
    # TTM allocates GFP_DMA32; a 32-bit kernel has no ZONE_DMA32, so those pages
    # come only from the ~838 MB low zone, and the default limit is roughly that
    # whole zone — so the brake exists but can never apply. TTM allocates until
    # the kernel starts killing processes, and on the reference machine it took
    # Xorg and the whole desktop session with it:
    #
    #     Xorg invoked oom-killer: gfp_mask=GFP_USER|GFP_DMA32
    #       __ttm_pool_alloc -> nouveau_ttm_tt_populate -> ttm_bo_evict
    #
    # 65536 pages caps it at 256 MB. Applies to ANY 32-bit host running TTM,
    # not just this card.
    printf 'options ttm dma32_pages_limit=65536\n' > /etc/modprobe.d/ttm-lowmem.conf



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

    # ⛔ AND LIGHTDM MUST WAIT FOR elogind, or elogind respawns once a second
    # for the life of the boot.
    #
    # elogind has TWO owners: runit's service, and D-Bus activation
    # (/usr/share/dbus-1/system-services/org.freedesktop.login1.service, which
    # is `Exec=elogind --daemon`). Whichever loses the race then thrashes —
    # runit restarts a service whose run script exits, and elogind.wrapper
    # exits immediately when it finds a daemon already up:
    #
    #   elogind[18058]: elogind is already running as PID 636
    #
    # With a manual login runit wins easily and nobody notices. With autologin
    # lightdm brings a session up about twelve seconds into boot, that session
    # asks D-Bus for login1, and activation wins EVERY time: 2368 restarts in
    # forty minutes on the reference machine, ~19000 PIDs against a pid_max of
    # 32768, constant fork/exec on a 3 GHz Pentium 4. It presents as a desktop
    # that feels unstable and occasionally drops to the login screen, which
    # sends you looking at the GPU.
    #
    # One line, and it is the idiom /etc/sv/elogind/run already uses to wait
    # for dbus. ⚠ /etc/sv/lightdm/run is Void's file, so an upgrade drops a
    # .pacnew and reverts this; the check below fails the build rather than
    # letting a future image ship without it.
    #
    # ⚠ @ as the sed delimiter, NOT |. The line being matched contains `||`,
    # which closes a |-delimited expression early — sed then rejects it and
    # the substitution silently does nothing.
    if [ -f /etc/sv/lightdm/run ] && ! grep -q "sv check elogind" /etc/sv/lightdm/run; then
        sed -i "s@^sv check dbus >/dev/null || exit 1\$@&\n# Wait for runit's elogind too: lightdm's first session otherwise\n# D-Bus-activates a second elogind and the supervised copy respawns\n# once a second forever. Worst with autologin, which logs in at boot.\nsv check elogind >/dev/null || exit 1@" /etc/sv/lightdm/run
    fi
    grep -q "sv check elogind" /etc/sv/lightdm/run || {
        echo "chroot: lightdm run script does not wait for elogind" >&2; exit 1; }

    # ── audio ───────────────────────────────────────────────────────────────
    # ⛔ INSTALLING pipewire WIRES UP NOTHING ON VOID. The package ships the
    # daemons, the autostart .desktop files and the config fragments, and then
    # leaves every one of them unlinked — so a desktop with pipewire installed
    # comes up with NO audio at all and no error anywhere. The symptom is a
    # lone "Dummy Output" sink in `wpctl status` with an empty device list,
    # which reads like broken hardware rather than a missing symlink.
    #
    # ⛔ EXACTLY ONE STARTUP MECHANISM. There are two ways to start wireplumber
    # and pipewire-pulse — the conf.d drop-ins, where pipewire spawns them
    # itself in the right order, and separate XDG autostart entries. Wiring up
    # BOTH starts wireplumber TWICE, and two session managers race until
    # neither owns the devices:
    #
    #     $ pw-cli ls Device        ->  0
    #     $ pactl info              ->  Connection failure: Timeout   (30.0s)
    #     $ wpctl status            ->  hangs, then nothing
    #
    # PipeWire's own protocol stays healthy throughout (`pw-cli info 0` answers
    # instantly), so it reads as a PulseAudio bug rather than a duplicate
    # daemon. Every pulse client then blocks for 30s on startup — which is what
    # made RetroArch appear to open a black window with a dead menu.
    #
    # Keep the drop-ins, autostart ONLY pipewire.
    mkdir -p /etc/pipewire/pipewire.conf.d /etc/xdg/autostart
    for f in /usr/share/examples/pipewire/20-pipewire-pulse.conf \
             /usr/share/examples/wireplumber/10-wireplumber.conf; do
        [ -f "$f" ] && ln -sf "$f" /etc/pipewire/pipewire.conf.d/
    done
    ln -sf /usr/share/applications/pipewire.desktop /etc/xdg/autostart/pipewire.desktop
    rm -f /etc/xdg/autostart/pipewire-pulse.desktop /etc/xdg/autostart/wireplumber.desktop
    # Prove it rather than trusting the lines above: one autostart entry, two drop-ins.
    n=$(ls /etc/xdg/autostart/ 2>/dev/null | grep -cE 'pipewire|wireplumber')
    [ "$n" = 1 ] || { echo "chroot: $n pipewire autostart entries, expected exactly 1" >&2; exit 1; }
    d=$(ls /etc/pipewire/pipewire.conf.d/ 2>/dev/null | wc -l)
    [ "$d" = 2 ] || { echo "chroot: $d pipewire conf.d drop-ins, expected 2" >&2; exit 1; }

    # ⚠ pipewire must run in the user's SEATED session. Started from an ssh
    # session (no seat) wireplumber claims no devices and produces the same
    # Dummy Output — the daemons are fine, the session is wrong. `loginctl
    # list-sessions` showing an empty SEAT column is the tell.
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
