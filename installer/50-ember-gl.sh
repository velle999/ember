# Ember: point GL clients at the proprietary libGL when 304 is the active stack.
#
# ⛔ SOURCED by /etc/lightdm/Xsession out of /etc/X11/xinit/xinitrc.d. No
# shebang, no `exit` -- an exit here ends the session before it starts.
#
# ⚠ THE X SERVER ALREADY HAS THIS (ember-xserver sets it for the server
# process); this is for everything the session then launches. Without it the
# desktop comes up on 304 and every GL client silently links Mesa's libGL
# instead, which cannot talk to the proprietary driver: glxgears reports a
# software renderer on a machine that just loaded a hardware one.
#
# ⚠ Appended, never assigned, so a user's own LD_LIBRARY_PATH survives.
if [ "$(cat /run/ember-gpu 2>/dev/null || echo)" = nvidia304 ] &&
   [ -d /opt/x11-19/lib/nvidia ]; then
    LD_LIBRARY_PATH="/opt/x11-19/lib/nvidia${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    export LD_LIBRARY_PATH
fi
