#!/bin/sh
#
# ember-gpu-early — choose the graphics stack BEFORE udev can bind nouveau.
#
# ⛔ WHY THIS HAS TO BE IN THE INITRAMFS AT ALL. 304 cannot take over a GPU that
# nouveau has already initialised: it fails with RmInitAdapter, /dev/nvidia0
# never appears and X exits with "no screens found" (measured on the reference
# GeForce 7600 AGP; the log is quoted in ember-gpu-apply). nouveau is bound
# during coldplug, so by the time anything in the real root runs -- including
# ember-gpu-detect, which knows perfectly well which driver this card wants --
# the decision has already been made and cannot be unmade.
#
# So the ONE thing this does is stop nouveau claiming a card that 304 should
# drive. Nothing else changes: ember-gpu-detect and ember-gpu-apply then reach
# their own conclusion in stage 1 and find the card free to take.
#
# ⚠ SILENCE IS THE SAFE ANSWER. Every failure path here leaves nouveau alone,
# because a machine on the open driver is a working machine and a machine with
# neither driver is a black screen. This never blacklists on a guess.
#
# SPDX-License-Identifier: GPL-2.0-or-later

# ⚠ Overridable so the whole thing can be exercised on a host with no NVIDIA
# card in it -- the same seam ember-gpu-detect uses, and for the same reason.
IDS=${EMBER_GPU_IDS:-/usr/share/ember/nvidia304-supported.ids}
PCI=${EMBER_GPU_PCI:-/sys/bus/pci/devices}
MODPROBE_D=${EMBER_GPU_MODPROBE_D:-/etc/modprobe.d}
CMDLINE=${EMBER_GPU_CMDLINE:-/proc/cmdline}
LOG=${EMBER_GPU_LOG:-/run/ember-gpu-early.log}

log() { echo "ember-gpu-early: $*" >> "$LOG" 2>/dev/null || true; }

blacklist_nouveau() {
    mkdir -p "$MODPROBE_D" 2>/dev/null || return 1
    # ⚠ `install ... /bin/false` as well as `blacklist`, because blacklist alone
    # only stops the ALIAS path -- udev asking for a modalias. A dependency pull
    # or an explicit modprobe still loads it, and either is enough to lose the
    # card. ⛔ insmod by path is deliberately still possible: that is how
    # ember-gpu-apply recovers if 304 turns out not to load.
    {
        echo "# Written by ember-gpu-early in the initramfs: this card is one"
        echo "# the 304 driver can drive, and 304 cannot take a card nouveau has"
        echo "# already initialised. Remove ember.gpu=auto, or pass"
        echo "# ember.gpu=nouveau, to keep the open driver instead."
        echo "blacklist nouveau"
        echo "install nouveau /bin/false"
    } > "$MODPROBE_D/ember-gpu-nouveau.conf" 2>/dev/null || return 1
    return 0
}

# ── an explicit choice always wins ──────────────────────────────────────────
want=""
for w in $(cat "$CMDLINE" 2>/dev/null || true); do
    case "$w" in ember.gpu=*) want=${w#ember.gpu=} ;; esac
done
case "$want" in
    nouveau|radeon|intel|modesetting)
        log "ember.gpu=$want on the command line -- leaving nouveau alone"
        return 0 2>/dev/null || exit 0 ;;
    nvidia|nvidia304)
        # The ISO's proprietary entry already blacklists on the command line;
        # doing it here too costs nothing and covers somebody who typed only
        # ember.gpu=nvidia at the prompt.
        blacklist_nouveau && log "ember.gpu=$want -- nouveau blacklisted"
        return 0 2>/dev/null || exit 0 ;;
esac

# ── otherwise, ask the card ─────────────────────────────────────────────────
#
# ⚠ boot_vga is the card the firmware initialised, i.e. the one with the console
# on it. A box with a dead onboard chip and a real AGP card lists both.
dev=""
for d in "$PCI"/*; do
    [ -r "$d/boot_vga" ] || continue
    [ "$(cat "$d/boot_vga" 2>/dev/null)" = 1 ] && { dev=$d; break; }
done
[ -n "$dev" ] || for d in "$PCI"/*; do
    case "$(cat "$d/class" 2>/dev/null || echo)" in 0x0300*) dev=$d; break ;; esac
done
[ -n "$dev" ] || { log "no display device found -- leaving nouveau alone"; return 0 2>/dev/null || exit 0; }

vendor=$(cat "$dev/vendor" 2>/dev/null || echo)
device=$(cat "$dev/device" 2>/dev/null || echo)
device=$(printf '%s' "$device" | sed 's/^0x//' | tr 'A-Z' 'a-z')

[ "$vendor" = 0x10de ] || { log "display is $vendor, not NVIDIA -- nothing to do"; return 0 2>/dev/null || exit 0; }

# ⛔ THE LIST IS CHECKED, NEVER ASSUMED. 304 refuses plenty of NVIDIA cards --
# a GeForce FX 5200 belongs to the 173.14.xx branch, and everything from the
# GeForce 8 on is far too new. Blacklisting nouveau for one of those would leave
# the machine with no driver at all, which is the exact failure this must not
# cause. No list, no blacklist.
if [ ! -r "$IDS" ]; then
    log "no $IDS in the initramfs -- leaving nouveau alone"
    return 0 2>/dev/null || exit 0
fi
if grep -qx "$device" "$IDS" 2>/dev/null; then
    if blacklist_nouveau; then
        log "10de:$device is a 304 card -- nouveau blacklisted for this boot"
    else
        log "10de:$device is a 304 card but the blacklist could not be written"
    fi
else
    log "10de:$device is not in the 304 list -- staying on nouveau"
fi
return 0 2>/dev/null || exit 0
