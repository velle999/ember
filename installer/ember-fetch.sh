#!/bin/sh
# fetch — Ember's console mark.
#
# ⛔ BRAILLE IS NOT IN THE VGA CONSOLE FONT. The flame is drawn with U+28xx
# glyphs, which every terminal emulator has and the bare TTY does not: on
# TERM=linux they come out as blanks or boxes, and that is precisely where
# somebody is most likely to be looking (a failed boot, the installer, a
# machine with no X yet). So the console gets a half-block flame instead of a
# hole in the screen.
#
# SPDX-License-Identifier: GPL-2.0-or-later
case "${TERM:-}" in
    linux|vt*|dumb) exec fastfetch --logo /usr/share/ember/logo-console.txt "$@" ;;
esac
exec fastfetch "$@"
