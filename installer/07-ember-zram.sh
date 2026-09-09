# vim: set ts=4 sw=4 et:
#
# Ember: compressed swap in RAM, when there was no room for a swapfile.
#
# ⛔ THIS FILE IS SOURCED BY /etc/runit/1, NOT EXECUTED — an `exit` here would
# terminate stage 1 and the machine would not boot. Same contract as
# 06-ember-expand.sh and 07-ember-swap.sh: call a real script, let that exit as
# it likes, return 0.
#
# ⚠ 07 AND AFTER 07-ember-swap.sh, WHICH IS WHAT THE NAME BUYS: the glob in
# /etc/runit/1 is sorted, "swap" sorts before "zram", so the swapfile gets its
# go first and ember-zram stands down whenever it succeeded. A disk swapfile is
# the better answer wherever there is room for one; this is for the medium where
# there is not, which is every live stick — see ember-zram for the measurement.
#
# ⚠ AND EVERY BOOT, NOT JUST THE FIRST. Unlike the swapfile, a zram device does
# not persist: it has to be created again on each boot, so there is deliberately
# no first-boot guard here.

[ -n "$IS_CONTAINER" ] && return 0

if [ -x /usr/bin/ember-zram ]; then
    msg "Setting up compressed swap if there is no swapfile..."
    /usr/bin/ember-zram || true
fi
return 0
