# config.sh — the whole of Ember's identity and target list.
#
# ⛔ THE NAME LIVES HERE AND NOWHERE ELSE. "Ember" is a working name; renaming
# the project is this one variable plus the README's title. Nothing else in the
# tree spells it.
EMBER_NAME="Ember"
EMBER_ID="ember"                # hostname, /etc/os-release ID, image filenames
EMBER_VERSION="0.1.0"

# Void's repositories. i686 and x86_64 live at the root of current/; every other
# architecture is in a subdirectory named for itself.
VOID_REPO_I686="https://repo-default.voidlinux.org/current"
VOID_REPO_AARCH64="https://repo-default.voidlinux.org/current/aarch64"

# ⚠ THE PI KERNEL IS PER MODEL. Void ships rpi4-kernel and rpi5-kernel as
# separate packages and there is no rpi5-base — a Pi 5 image takes rpi-base with
# rpi5-kernel, a Pi 4 takes rpi4-base with rpi4-kernel. Getting this wrong builds
# an image that installs cleanly and does not boot.
RPI_MODEL="${RPI_MODEL:-4}"

case "$RPI_MODEL" in
    4) RPI_PKGS="rpi4-base rpi4-kernel" ;;
    5) RPI_PKGS="rpi-base rpi5-kernel" ;;
    *) echo "config.sh: RPI_MODEL must be 4 or 5 (got '$RPI_MODEL')" >&2; return 1 2>/dev/null || exit 1 ;;
esac

# ⛔ THE i686 KERNEL IS PINNED BY NAME, AND THAT IS DELIBERATE. The obvious
# choice is Void's `linux` metapackage — but it depends on `linux-base`, and
# `linux-base` is `dracut` plus EVERY firmware set plus one 1-line script.
# On this target that is 668 MB of blobs for hardware that cannot exist in an
# AGP Pentium 4: 174 MB of modern Intel, 102 MB of Mellanox datacentre NICs,
# and 108 MB of NVIDIA GSP firmware which is for Turing and later — the exact
# opposite end of history from a GeForce 7600.
#
# So the kernel is named directly and dracut is asked for separately. The cost
# is that this pin goes stale when Void moves on, which is why
# build/validate-profiles.sh checks it: it fails loudly with the name to bump
# rather than silently at build time.
KERNEL_I686="linux6.18"

# Wine is 791 MB and it is the single biggest thing in an i686 image — but
# running legacy software is a stated requirement of this project, so it is on
# by default and switched off with EMBER_WINE=0 rather than being opt-in.
EMBER_WINE="${EMBER_WINE:-1}"

# The container that supplies xbps. Building a Void rootfs needs Void's own
# package manager, which is not packaged for the host distributions this is
# developed on.
VOID_IMAGE="ghcr.io/void-linux/void-linux:latest-full-x86_64"
