# vim: set ts=4 sw=4 et:
#
# Ember: leave a full picture of the boot on disk, every boot.
#
# ⛔ Void's own 97-dmesg.sh captures the ring buffer at the END OF STAGE 1, so
# /var/log/dmesg.log stops before the display driver finishes, before udev has
# settled and long before X is attempted. On a machine whose only symptom is a
# blank screen that is precisely the wrong half of the boot to keep, and it has
# already cost several round trips of carrying an SD card between rooms.
#
# ⚠ SOURCED, NOT EXECUTED — see 06-ember-expand.sh. No `exit` may appear here.
# It backgrounds a sleep so the dump happens after stage 2 has had time to bring
# services up, and it cannot delay the boot.

[ -n "$IS_CONTAINER" ] && return 0

( sleep 25
  O=/var/log/ember-boot.txt
  {
    echo "=== $(date -u +%FT%TZ) ==="
    echo "--- kernel cmdline ---";      cat /proc/cmdline
    echo "--- dri devices ---";         ls -l /dev/dri/ 2>&1
    echo "--- drm cards ---";           for c in /sys/class/drm/card*; do
                                            [ -e "$c" ] && echo "$c -> $(readlink -f "$c/device/driver" 2>/dev/null)"
                                        done
    echo "--- framebuffers ---";        for f in /sys/class/graphics/fb*/name; do
                                            [ -e "$f" ] && echo "$f = $(cat "$f")"
                                        done
    echo "--- modules ---";             lsmod
    echo "--- network ---";             ip -o addr show scope global 2>&1
    echo "--- nm devices ---";          nmcli -t -f DEVICE,TYPE,STATE device 2>&1
    echo "--- services ---";            sv status /var/service/* 2>&1
    echo "--- FULL dmesg ---";          dmesg
  } > "$O" 2>&1
  chmod 0644 "$O"
) &
return 0
