#!/bin/bash
#
# 99ember-gpu — decide between nouveau and the proprietary 304 driver before
# udev binds either of them. See ember-gpu-early.sh for why it cannot wait.
#
# SPDX-License-Identifier: GPL-2.0-or-later

check() {
    # Only worth including when the ID list was built; without it the hook can
    # only ever decide "leave nouveau alone".
    [ -f "$moddir/nvidia304-supported.ids" ] || return 1
    return 0
}

depends() {
    echo ""
}

install() {
    # ⚠ pre-udev, NOT pre-mount: udev's coldplug is what loads nouveau, so the
    # decision has to be written before udevd is started.
    inst_hook pre-udev 20 "$moddir/ember-gpu-early.sh"
    # ⚠ pre-pivot, so the blacklist reaches the real root before its own
    # coldplug runs.
    inst_hook pre-pivot 20 "$moddir/ember-gpu-pivot.sh"
    inst_simple "$moddir/nvidia304-supported.ids" /usr/share/ember/nvidia304-supported.ids
    # ⛔ NAMED, NOT ASSUMED. The hook is /bin/sh and uses exactly these; a
    # dracut base that happens not to carry one of them would make the hook
    # fail silently and the card would quietly go to nouveau.
    inst_multiple grep sed tr cat mkdir
}
