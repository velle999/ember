# vim: set ts=4 sw=4 et:
#
# Ember: a D-Bus machine ID that belongs to this machine and no other.
#
# ⛔ THIS FILE IS SOURCED BY /etc/runit/1, NOT EXECUTED — an `exit` here would
# terminate stage 1 and the machine would not boot. Same contract as
# 06-ember-expand.sh: return 0.
#
# ⚠ THE IMAGE SHIPS WITHOUT AN ID, ON PURPOSE. Void's dbus package writes
# /var/lib/dbus/machine-id when it is installed, which for an image is BUILD
# time, and nothing on a runit system ever writes another. So every machine
# installed from one disc shared a single ID. _image-inside.sh deletes it, and
# ember-install does not copy the live system's, so this makes one on the first
# boot that finds none. `--ensure` leaves an existing ID alone, so an installed
# machine keeps its own from then on. On the live disc the root is a RAM
# overlay and each boot gets a fresh one, like everything else it forgets.
#
# ⚠ 05: after 03-filesystems has remounted the root read-write, and in stage 1,
# so it exists before stage 2 starts dbus.

if [ -x /usr/bin/dbus-uuidgen ]; then
    /usr/bin/dbus-uuidgen --ensure || true
fi
return 0
