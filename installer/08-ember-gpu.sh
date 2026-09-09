# vim: set ts=4 sw=4 et:
#
# Ember: select the graphics stack before anything tries to draw on it.
#
# ⛔ THIS FILE IS SOURCED BY /etc/runit/1, NOT EXECUTED -- `for f in
# core-services/*.sh; do . $f; done`. An `exit` here would terminate stage 1 and
# the machine would not boot. So it does nothing but call a real script, which
# may exit as it likes, and then `return 0` whatever happened.
#
# Placed at 08: after the filesystems, swap and zram are up, and well before
# stage 2 starts lightdm -- which reads the result through ember-xserver.

[ -n "$IS_CONTAINER" ] && return 0

if [ -x /usr/bin/ember-gpu-apply ]; then
    msg "Selecting the graphics stack..."
    /usr/bin/ember-gpu-apply || true
fi
return 0
