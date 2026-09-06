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

# ── The Pi's display, which cannot be autodetected on a panel with no EDID ──
#
# vc4 KMS works on this target: it binds every component, registers a DRM
# device, and X runs on `modesetting` with glamor and full RandR.
#
# ⛔ THIS FILE USED TO SAY THE OPPOSITE — that vc4 "binds only the hvs and
# never registers a display device", so X had to run on fbdev with no RandR
# and a blank XFCE Display panel. That was wrong, and it was wrong because of
# a fault I had introduced myself: the legacy `hdmi_cvt` / `hdmi_force_hotplug`
# settings written below prevented vc4 from initialising, and I read the
# resulting half-bound driver as a hardware limit. Removing them fixed it.
#
# EMBER_PI_MODE: "auto" trusts the monitor's EDID, which is right for a TV or
# a monitor. A small HDMI panel usually publishes none at all, and then KMS
# invents a CVT timing for whatever mode is asked for, the panel does not
# recognise it, and it shows "not support" or blinks — telling you nothing
# about which of the resolution or the timing is at fault. Setting this to
# "<w> <h> [hz]" builds a real EDID (build/mkedid.py) and hands it to the
# kernel, which makes the panel's mode the preferred and only one.
#
# ⛔ GIVE THE PANEL'S *NATIVE* MODE, WHICH IS NOT ALWAYS THE ADVERTISED ONE.
# The 4" panel this was developed against is sold as "800x480" but is
# physically a 480x800 portrait panel that the vendor's config rotated; the
# vendor script's own line is `hdmi_cvt 480 800 65`. Naming the rotated size
# here asks for a mode the panel has never had, and no amount of adjusting it
# can work. Rotate with EMBER_PI_ROTATE, not by transposing this.
#   Miuzei/goodtft MPI4009 4" IPS:  EMBER_PI_MODE="480 800 65" EMBER_PI_ROTATE=ccw
EMBER_PI_MODE="${EMBER_PI_MODE:-auto}"

# EMBER_PI_DIAG: panel diagonal in inches, used only for the physical size in
# the generated EDID (and so for the desktop's DPI). Cosmetic; leave it unset
# and the size is derived at 96 DPI.
EMBER_PI_DIAG="${EMBER_PI_DIAG:-}"

# EMBER_PI_ROTATE: none | cw | ccw | ud. Applied in TWO places, because they
# are genuinely separate: X gets a modesetting Rotate option, and the kernel
# console gets fbcon=rotate so the boot messages match. Setting only the first
# leaves you booting sideways and then snapping upright when X starts.
EMBER_PI_ROTATE="${EMBER_PI_ROTATE:-none}"

# The container that supplies xbps. Building a Void rootfs needs Void's own
# package manager, which is not packaged for the host distributions this is
# developed on.
VOID_IMAGE="ghcr.io/void-linux/void-linux:latest-full-x86_64"
