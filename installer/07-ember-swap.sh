# vim: set ts=4 sw=4 et:
#
# Ember: create a swapfile on first boot, once the root has been grown.
#
# ⛔ THIS FILE IS SOURCED BY /etc/runit/1, NOT EXECUTED — an `exit` here would
# terminate stage 1 and the machine would not boot. Same contract as
# 06-ember-expand.sh: call a real script, let that exit as it likes, return 0.
#
# 07 and not 04: Void's own 04-swap activates what fstab already names, and on
# first boot there is nothing to activate yet. The file cannot be made before
# 06-ember-expand.sh has grown the filesystem, or it would be sized against the
# image's original few hundred MB of slack.

[ -n "$IS_CONTAINER" ] && return 0

if [ -x /usr/bin/ember-swap ]; then
    msg "Creating a swapfile if there is room..."
    /usr/bin/ember-swap || true
fi
return 0
