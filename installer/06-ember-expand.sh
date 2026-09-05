# vim: set ts=4 sw=4 et:
#
# Ember: grow the root filesystem to fill its device on first boot.
#
# ⛔ THIS FILE IS SOURCED BY /etc/runit/1, NOT EXECUTED — `for f in
# core-services/*.sh; do . $f; done`. An `exit` here would terminate stage 1 and
# the machine would not boot. So it does nothing but call a real script, which
# may exit as it likes, and then `return 0` whatever happened.
#
# Placed at 06 deliberately: after 03-filesystems.sh has remounted the root
# read-write (it cannot be grown read-only) and after 04-swap, before sysctl.

[ -n "$IS_CONTAINER" ] && return 0

if [ -x /usr/bin/ember-expand-root ]; then
    msg "Expanding the root filesystem if there is room..."
    /usr/bin/ember-expand-root || true
fi
return 0
