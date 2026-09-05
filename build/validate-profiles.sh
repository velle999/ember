#!/usr/bin/env bash
#
# validate-profiles.sh — every package named in profiles/ exists, for the
# architecture that will be asked to install it.
#
# ⚠ THIS IS THE CHEAP HALF OF A BUILD. A misspelt or since-renamed package name
# is invisible until xbps refuses it, which on a rootfs build is several minutes
# and a network download away — and on a rolling base like Void a name that was
# right last month can simply be gone. This asks the live repodata and needs no
# root, no container and no disk.
#
# ⛔ IT CHECKS PER ARCHITECTURE, NOT ONCE. i686 and aarch64 are separately built
# ports with separately drifting package sets; "it exists" is not a property of
# a name, it is a property of a name AND an architecture.
#
# Usage: build/validate-profiles.sh [--offline <cachedir>]
set -euo pipefail
cd "$(dirname "$0")/.."
. build/config.sh

cache=${EMBER_REPODATA_CACHE:-$(mktemp -d)}
keep=0
[ -n "${EMBER_REPODATA_CACHE:-}" ] && keep=1
trap '[ "$keep" = 1 ] || rm -rf "$cache"' EXIT

fetch() {  # fetch <arch> <repo-url>
    local arch=$1 url=$2 d="$cache/$1"
    [ -f "$d/index.plist" ] && return 0
    mkdir -p "$d"
    curl -fsS --max-time 180 -o "$d/repodata" "$url/$arch-repodata" ||
        { echo "validate: cannot reach $url for $arch" >&2; return 1; }
    tar --zstd -xf "$d/repodata" -C "$d"
}

fetch i686    "$VOID_REPO_I686"
fetch aarch64 "$VOID_REPO_AARCH64"

python3 - "$cache" <<'PY'
import plistlib, sys, os
cache = sys.argv[1]
idx = {a: plistlib.load(open(f"{cache}/{a}/index.plist", "rb"))
       for a in ("i686", "aarch64")}

def names(f):
    with open(f) as fh:
        return [l.strip() for l in fh if l.strip() and not l.startswith("#")]

# Which profiles each architecture can be asked for. Both desktop tiers are
# listed against both architectures on purpose: the tier is chosen per MACHINE
# (a 1 GB Pi 4 wants the small one too), so both have to resolve on both.
sets = {
    "i686":    ["base", "desktop-min", "desktop", "arch-i686"],
    "aarch64": ["base", "desktop-min", "desktop", "arch-aarch64"],
}
bad = 0
for arch, profs in sets.items():
    n = 0
    for p in profs:
        for pkg in names(f"profiles/{p}.pkgs"):
            n += 1
            if pkg not in idx[arch]:
                print(f"  MISSING  {arch:8} {pkg:28} profiles/{p}.pkgs")
                bad += 1
    print(f"  ok       {arch:8} {n} package name(s) across {len(profs)} profile(s)")

# The per-model Pi packages are named in config.sh rather than a profile, so
# they are checked here too or they are checked nowhere.
for pkg in ("rpi4-base", "rpi4-kernel", "rpi-base", "rpi5-kernel"):
    if pkg not in idx["aarch64"]:
        print(f"  MISSING  aarch64  {pkg:28} build/config.sh")
        bad += 1

print(f"\n{bad} missing name(s)")
sys.exit(1 if bad else 0)
PY
