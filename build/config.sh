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

# The container that supplies xbps. Building a Void rootfs needs Void's own
# package manager, which is not packaged for the host distributions this is
# developed on.
VOID_IMAGE="ghcr.io/void-linux/void-linux:latest-full-x86_64"
