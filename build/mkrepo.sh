#!/usr/bin/env bash
#
# mkrepo.sh — an offline package repository on a stick.
#
# ⛔ THE MACHINE THIS EXISTS FOR HAS NO NETWORK. A Pentium 4 in a workshop, a Pi
# on a bench — `xbps-install foo` is not available to them, and rebuilding and
# rewriting a 6 GB image to add one package is absurd. xbps can install from a
# DIRECTORY, so the answer is to carry the directory.
#
# On this machine:
#     build/mkrepo.sh i686 gimp vlc mc
# copy the resulting directory to a stick, and on the offline machine:
#     sudo xbps-install -R /media/usb/ember-repo-i686 gimp vlc mc
#
# ⚠ DEPENDENCIES COME TOO. -D downloads the full transaction, not just the names
# you asked for, which is the entire difference between this working and it
# failing on the target with "unresolved dependencies" and no way to fetch them.
#
# ⚠ THE REPOSITORY IS UNSIGNED, and xbps will say so on the target. That is
# expected for a local directory: signing needs a private key the target would
# then have to trust. The packages themselves were fetched from Void's signed
# repository and their integrity checked at download time by -D.
#
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail
cd "$(dirname "$0")/.."
. build/config.sh

ARCH=${1:-}; shift || true
case "$ARCH" in
    i686)    REPO="$VOID_REPO_I686" ;;
    aarch64) REPO="$VOID_REPO_AARCH64" ;;
    *) echo "usage: $0 <i686|aarch64> <package>..." >&2; exit 2 ;;
esac
[ $# -gt 0 ] || { echo "usage: $0 $ARCH <package>..." >&2; exit 2; }

OUT="out/${EMBER_ID}-repo-$ARCH"
mkdir -p "$OUT"
echo "== offline repository for $ARCH"
echo "   packages: $*"
echo "   into:     $OUT"

docker info >/dev/null 2>&1 || { echo "mkrepo: the docker daemon is not running" >&2; exit 1; }

docker run --rm \
    -v "$PWD/$OUT:/repo" \
    -e XBPS_ARCH="$ARCH" \
    "$VOID_IMAGE" /bin/sh -euc "
        xbps-install -Suy xbps >/dev/null 2>&1
        # -c puts the .xbps files where we want them; -D fetches the whole
        # transaction and verifies each package, then does nothing else.
        xbps-install -y -S -R '$REPO' -c /repo -D $* 
        # An index is what makes a directory a repository. Without it xbps sees
        # a pile of files and refuses to resolve anything.
        xbps-rindex -a /repo/*.xbps
    "

echo
n=$(ls "$OUT"/*.xbps 2>/dev/null | wc -l)
echo "   $n package(s), $(du -sh "$OUT" | cut -f1)"
echo
echo "Copy $OUT to a stick, then on the offline machine:"
echo "    sudo xbps-install -R /path/to/$(basename "$OUT") $*"
