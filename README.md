# Ember

A small graphical desktop for machines the rest of the world has stopped
building for: 32-bit x86 of the Pentium 4 era, and the Raspberry Pi 4/5.

It boots, it installs itself beside Windows XP without touching it, and it runs
Wine. **x86_64 is deliberately not a target.**

| | |
|---|---|
| **Targets** | `i686` (Pentium 4 and later 32-bit x86), `aarch64` (Raspberry Pi 4 / 5) |
| **Base** | Void Linux — glibc, runit, rolling |
| **Desktop** | XFCE, or an IceWM tier for ~1 GB machines |
| **Status** | i686 and aarch64 both **run on real hardware** — see [Verified](#verified-on-real-hardware) |

Not a distribution from scratch: a package set, a desktop configuration, an
image builder and an installer, on top of a base that already does the hard
part.

## Why Void, and not the obvious answers

Decided by measurement on 2026-09-05, recorded so it can be re-argued later
against facts rather than memory.

**Debian is out, and this is the decisive fact.** Debian 13 "trixie" dropped
i386 entirely — no kernel, no installer. Its remaining i386 packages are built
*requiring SSE2* and intended only for multiarch on an amd64 host, so they will
not run on much of the hardware Debian 12 supported. Debian 12 has a real i386
port, but it is on LTS until June 2028 and then gone.

**Arch is out.** It dropped i686 in 2017; `archlinux32` lags badly and lacks the
modern graphics stack.

**Alpine is out**, despite fitting the hardware beautifully — it is musl, and
the requirement here is *running legacy software*, which means glibc.

**Void is in**, empirically:

| | i686 | aarch64 |
|---|---|---|
| repodata rebuilt | **2026-09-05** | **2026-09-05** |
| packages | **14,436** | **14,154** |
| kernel | 6.18 | 6.18, plus `rpi4-kernel` / `rpi5-kernel` |
| glibc / Mesa / Xorg | 2.41 / 26.1.8 / 21.1.24 | same |
| Wine | **11.16** | — |

Both ports were rebuilt the same day this was written, within twenty minutes of
x86_64. That is a live port, not an archive. Void also brings **runit** rather
than systemd, which on a 1 GB machine is not a philosophical preference.

## The reference machine

A **3.0 GHz hyper-threaded Pentium 4, 2 GB DDR400, GeForce 7600 GS AGP**.

The card gets a real hardware GL driver — nouveau's `nv30`, verified present in
Mesa 26.1.8 by reading the symbols out of `libgallium`, not assumed. The
proprietary route is closed: 304.xx was the last branch to support GeForce 6/7
and does not build against a 6.x kernel.

**AGP works, and it matters.** On a VIA VT3314 (P4M800CE) the card negotiates
AGP 3.5 at **8x with a 512 MiB GART**, which is what the desktop and every game
run on. The chipset backend has to be in the initramfs for that — without
`via-agp` nouveau reports `pci: failed to acquire agp` and falls back to PCI DMA
with a **128 MiB** GART. That is not merely slower: on a 2 GB machine the
shortfall lands in system RAM and the OOM killer eventually takes Xorg, which
presents as a hard freeze with a still-moving mouse cursor.

⚠ The `nouveau.agpmode=` advice every forum gives **no longer exists** — the
kernel answers `unknown parameter 'agpmode' ignored`. AGP self-configures.
`blacklist via_agp` is also not enough to disable it, because the initramfs
modprobes it directly; that needs `install via_agp /bin/true`. The real
acceleration fallback is `nouveau.noaccel=1`. See
[docs/target-p4.md](docs/target-p4.md).

⚠ `nouveau ... DMA_VTX_PROTECTION / PROTECTION_FAULT` is logged at **every** GL
context creation, including by `glxgears`, and is benign — the driver recovers
and renders at full speed. It is not an AGP fault and not worth chasing.

### Verified on real hardware

| | |
|---|---|
| **P4 / GeForce 7600 GS AGP** | hardware GL — `Accelerated: yes`, `NV4B`, 502 MB, `glxgears` 60 FPS vsync-locked |
| **AGP** | AGP 3.5 @ 8x, GART 512 MiB, VIA VT3314 |
| **Native 3D** | SuperTuxKart |
| **Wine on hardware GL** | Return to Castle Wolfenstein (`GL_RENDERER: NV4B`), Quake II, Unreal Tournament 99 |
| **Dual boot** | installs beside Windows XP; the NTFS partition mounts read-only for its game library |
| **Raspberry Pi 4** | image boots to XFCE, ethernet + wifi, and drives a 4" 480x800 panel that publishes no EDID |

Unsure what your machine can take? `tools/hw-probe.sh` is POSIX sh with no
dependencies, so it runs from any live USB and reports the things that decide
the design — SSE2, RAM, whether there is a real KMS driver or only a
framebuffer, the GPU, and BIOS vs UEFI.

```sh
sh tools/hw-probe.sh --tsv
```

## Building

Needs docker (for xbps), and qemu to test. Building the **aarch64** image additionally needs `qemu-user-static` registered with `binfmt_misc` — see [Building for the Raspberry Pi](#building-for-the-raspberry-pi).

```sh
build/validate-profiles.sh        # every package name still exists, per arch
build/fetch-cores.sh i686         # libretro cores (once; see below)
build/fetch-assets.sh            # RetroArch menu assets + joypad profiles
build/mkrootfs.sh i686 desktop    # 4.7 GB rootfs    (EMBER_WINE=0 saves ~790 MB)
build/mkimage.sh  i686 desktop    # 6.2 GB bootable MBR/BIOS disk image
sudo build/write-usb.sh           # write it to a stick, safely
```

`write-usb.sh` addresses the stick by its `/dev/disk/by-id` path and refuses
anything that is not a real, removable, unmounted block device — because `dd` to
a device letter that has moved does not fail, it creates a file in `/dev`, which
is RAM.

### Building for the Raspberry Pi

Same two scripts, different architecture — but the ARM path needs one thing
first. **The chroot runs the target's own binaries**, and unlike i686 (which an
x86_64 host executes natively) ARM binaries need `qemu-user-static` registered
with `binfmt_misc`. Both scripts refuse to run without it rather than produce a
rootfs whose package scriptlets all silently failed:

```sh
docker run --privileged --rm tonistiigi/binfmt --install arm64   # any host
sudo pacman -S qemu-user-static qemu-user-static-binfmt          # Arch
sudo apt install qemu-user-static binfmt-support                 # Debian
```

Then:

```sh
build/fetch-cores.sh aarch64        # 424 libretro cores
build/fetch-assets.sh               # menu assets (shared with i686)
build/mkrootfs.sh aarch64 desktop
build/mkimage.sh  aarch64 desktop   # FAT firmware partition + ext4 root
sudo build/write-usb.sh             # same guard rails, for the SD card
```

`RPI_MODEL` selects the board (default `4`). The output is not a BIOS disk image
but a FAT firmware partition carrying `config.txt` and the Pi's own bootloader
files, plus an ext4 root — which is why it needs its own image script rather
than the i686 one.

For a small panel with no EDID, add `EMBER_PI_MODE` / `EMBER_PI_ROTATE` /
`EMBER_PI_DIAG` — see [A panel with no EDID](#a-panel-with-no-edid):

```sh
EMBER_PI_MODE="480 800 65" EMBER_PI_ROTATE=ccw EMBER_PI_DIAG=4 \
    build/mkimage.sh aarch64 desktop
```

### Emulation and old games

Void packages **essentially no libretro cores** — the whole i686 set is
`mupen64plus`, one of the heaviest cores there is. RetroArch can download cores
itself at runtime, which is exactly what a machine with no network cannot do, so
they are fetched at build time and baked into the image:

```sh
build/fetch-cores.sh i686        # 31 cores from libretro's buildbot → cores/i686
```

They install to `/usr/lib/libretro` with `retroarch.cfg` pointed at it, so
RetroArch works offline out of the box. `cores/` is gitignored — those are
downloaded binaries, not source.

⛔ **Cores are not the only thing Void's `retroarch` omits.** The package ships
nothing under `share/libretro`, and both gaps fail silently in ways that look
like a broken install rather than a missing download:

| missing | what you see |
|---|---|
| menu assets | Ozone/XMB draw with no icons and no fonts |
| joypad profiles | every controller is "not configured" and does nothing |

`build/fetch-assets.sh` bakes both in (~90 MB) and points `retroarch.cfg` at
them. It is architecture-independent — PNGs, fonts and text profiles — so one
download serves both targets. The 213 MB upstream assets repo is trimmed to the
menu drivers usable on Linux; `src/` alone is 62 MB of build-time SVGs that
nothing reads at runtime.

⚠ **Standalone MAME is deliberately not installed.** It is 555 MB and MAME 0.282
chases accuracy on hardware two decades newer than a Pentium 4. Arcade is
covered by the **`mame2003_plus`** core instead — MAME 0.78-era, from when MAME
still targeted machines like this — with `fbalpha2012` beside it.
`xbps-install mame` puts the full thing back on a machine that can drive it.

Beyond RetroArch: **`dosbox-staging`**, **`scummvm`**, **`mednafen`**, and
**Wine** with `winetricks`. Reach for the right one — Wine cannot run a DOS
binary at all, and ScummVM reads original LucasArts/Sierra data files without
needing either.

#### Two traps with DirectDraw-era Windows games

Both cost hours on Unreal Tournament 99 and apply to anything of that vintage.

**Wine enumerates no DirectDraw drivers.** A 1999 game that asks DirectDraw to
list display modes gets an empty list and aborts in its window-creation code —
UT99 dies in `UWindowsClient::UWindowsClient` before writing a single line of
its own log, which reads like a broken installation. Many such games have a
switch for it; UT99's is one line:

```ini
[WinDrv.WindowsClient]
UseDirectDraw=False
```

**A crash marker can lock a game out permanently.** UT99 writes an empty
`System/Running.ini` at startup and deletes it on a clean exit. Crash once and
it survives, and every later launch opens a modal "Recovery Mode" window — which
under Wine never even paints, so it looks like a hang rather than a prompt.
Deleting the marker before launch means one crash cannot trap the install.

⚠ Debugging these over ssh is its own trap: `pkill -x UnrealTournament.exe`
never matches, because Linux truncates a process name to 15 characters
(`UnrealTournamen`). A "killed" instance survives and later tests read its stale
windows.

### Steam on a 32-bit host

Steam's client binaries are still 32-bit i386 — `ubuntu12_32/steam` and
`steamui.so` both are. What stops it on a 32-bit-only machine is narrower than
that: `Is64BitOS()` in `steamui.so` reads `uname(2)` and asserts when
`utsname.machine` is not `x86_64`.

Everything else works. On the reference P4 the client downloads, extracts,
loads the 32-bit `steamui.so` and reports `Running Steam on void  32-bit`,
given two packages that are easy to miss:

- **`gtk+`** (GTK2) — without it `steamui.so` fails with
  `libgtk-x11-2.0.so.0: cannot open shared object file`
- **`xz`** — without it the runtime never unpacks and the failure surfaces much
  later as missing files inside the runtime

`tools/steam64shim.c` answers just that one check:

```sh
gcc -shared -fPIC -O2 -o ~/.local/lib/steam64shim.so tools/steam64shim.c -ldl
LD_PRELOAD=~/.local/lib/steam64shim.so ./steam.sh
```

⚠ **It does not make the machine 64-bit.** Steam's `ubuntu12_64` helpers
(`gldriverquery`, `vulkandriverquery`) still cannot execute — they fail as
`Syntax error: ")" unexpected`, which is a shell trying to interpret a 64-bit
ELF — and no 64-bit game will run. This gets the client up; it is not a route
to 64-bit titles.

⚠ Valve's archived `.deb`s are **bootstrappers, not clients**. An old launcher
still downloads today's client, so there is no "install the 2023 version"
shortcut; and Valve does not publish standalone archived clients.

### Disc images, from the file manager

Six Thunar right-click actions ship in `/etc/xdg/Thunar/uca.xml`: mount and
eject ISOs, convert BIN/CUE with `bchunk`, load BIN/CUE into a virtual optical
drive with `cdemu`, run an `.exe` under Wine, and extract an installer's
contents with `innoextract` without running it.

⛔ **BIN/CUE cannot be mounted**, and the menu says so by omission — "Mount disc
image" does not appear for them. A `.bin` holds raw 2352-byte sectors including
headers and error correction where a filesystem expects 2048-byte blocks, so
`mount(8)` sees noise. Convert it, or hand it to `cdemu`, which presents a real
`/dev/sr0` and is usually the better answer for a game that polls for a CD drive
rather than reading a path.

Mounting goes through `udisksctl`, not `sudo mount -o loop`: it runs as the
user with polkit deciding, appears in Thunar's sidebar like any other volume,
and ejects by clicking eject.

### Getting software onto a machine with no network

```sh
build/mkrepo.sh i686 gimp vlc mc     # full dependency closure into out/ember-repo-i686
```

Copy that directory to a stick, then on the offline machine:

```sh
sudo xbps-install -R /path/to/ember-repo-i686 gimp vlc mc
```

### The test rigs

```sh
build/boot-test.sh       # does it boot?              6 checks, qemu + serial
build/desktop-test.sh    # does a desktop draw?       3 checks, framebuffer
build/install-test.sh    # does it damage the other OS?  9 checks
```

`install-test.sh` is the one that matters. It builds a stand-in XP disk — MBR
table, a partition starting at sector 63 as XP-era tools leave it, NTFS carrying
the files os-prober keys on — then installs onto it twice and compares a
**sha256 of the entire NTFS partition** before and after, plus every line of the
partition table. All three rigs are green.

## Installing

Boot the USB and look before you leap:

```sh
sudo ember-install --plan          # prints the disk, the free space, the plan
sudo ember-install /dev/sda        # asks you to type INSTALL
sudo ember-install --reuse         # reinstall over an existing Ember partition
```

It creates **one** partition in unallocated space, never touching an existing
one, and verifies every pre-existing partition entry is unchanged before it
continues. The MBR and partition table are backed up **before any write**, to
`/root/ember-install-backup/`, and the one line that undoes the bootloader
change entirely is printed at the end and in every failure path:

```sh
dd if=/root/ember-install-backup/mbr.bin of=/dev/sda bs=512 count=1
```

`--reuse` accepts only a partition that is provably a previous install — ext4
labelled `ember` — and refuses NTFS, unlabelled, or anything else.

⚠ MBR allows only four primary partitions. The installer refuses if the disk
already has four, rather than failing halfway through a table rewrite.

## Reaching the Windows partition

```sh
sudo ember-mount-windows           # read-only, always safe
sudo ember-mount-windows --rw      # read-write ONLY if the volume is clean
sudo ember-mount-windows --fstab   # print a permanent fstab line
```

⛔ **This is the part that destroys data if you get it wrong.** A Windows volume
that was hibernated or fast-shut-down is left dirty — mid-transaction, with
Windows expecting to resume into it. Writing to that from Linux corrupts it, and
the advice everywhere is to force the mount, which is exactly how the corruption
happens. The helper asks `ntfs-3g.probe`, mounts read-only unless writing is
provably safe, and names the reason when it refuses.

## What is on it

XFCE with Thunar, Firefox ESR, `gvfs`/`udisks2` so disks appear and mount,
NetworkManager, PipeWire, **Wine 11.16**, fastfetch, SuperTuxKart and SuperTux.

Wine hides itself from the application menu by design — upstream ships its
`.desktop` as a file-type handler with `NoDisplay=true`, so double-clicking an
`.exe` works but there is no "Wine" icon. Start with `winecfg`.

⚠ SuperTuxKart needs OpenGL 3.3 for its normal renderer and a GeForce 7 gives
2.1. It ships a 2.1 fallback, so it runs — without the effects.

## Defaults

Login `ember` / `ember`; root shares the password. There is a **serial console
on ttyS0 with a getty on it** — on a machine of this era, being able to watch a
boot and log in without a monitor attached is the difference between debugging
it and carrying it to a desk.

## Layout

```
tools/hw-probe.sh    what will this machine actually run
profiles/            package sets, per architecture and per weight tier
build/               rootfs and image builders, the USB writer, three qemu rigs,
                     the core fetcher and the offline-repo builder
installer/           ember-install, ember-mount-windows, ember-disc, Thunar actions
cores/               libretro cores, fetched not committed (gitignored)
docs/                design notes
```

## Two traps in the build system itself

⛔ **`mkrootfs.sh` stamps the tree only when it is finished** — after xbps
returns AND after every ELF in it has been checked for the right architecture —
and `mkimage.sh` refuses a tree without that stamp. Without it, building an
image from a rootfs that is still downloading produces one that boots, looks
entirely normal, and is missing whatever had not arrived yet. Nothing reports an
error, because nothing failed.

⛔ **Never edit a shell script while an instance of it is running.** bash reads
scripts by byte offset, so an insertion shifts everything after it and the
running shell resumes mid-token — here it re-entered a cleanup branch and
deleted a rootfs that 650 packages had just been installed into. The error names
a command nobody wrote.

## The Raspberry Pi's display

vc4 KMS works: it binds every component, registers a DRM device, and X runs on
`modesetting` with glamor and full RandR. XFCE's Display settings panel works.

> ⛔ **This section used to say the opposite** — that vc4 "binds only
> `fe400000.hvs`, never registers a DRM device", and was therefore blacklisted.
> That was wrong. The half-bound driver was caused by the legacy `hdmi_cvt` and
> `hdmi_force_hotplug` settings this builder itself wrote: they stop vc4
> initialising. Removing them fixed it, and the blacklist had been costing the
> image its hardware acceleration and its Display panel for nothing.

### A panel with no EDID

Most small HDMI panels publish no EDID at all. KMS then invents a CVT timing
for whatever mode you name, the panel does not recognise it, and it shows
"not support" or blinks — which tells you nothing about whether the resolution
or the timing is at fault. `EMBER_PI_MODE` builds a real EDID
(`build/mkedid.py`, whose timings reproduce `cvt(1)` exactly) and hands it to
the kernel, making the panel's mode the preferred and only one:

```sh
EMBER_PI_MODE="480 800 65" EMBER_PI_ROTATE=ccw EMBER_PI_DIAG=4 \
    build/mkimage.sh aarch64 desktop
```

⛔ **Give the panel's *native* mode, which is not always the advertised one.**
The 4" panel this was developed against (Miuzei / goodtft `MPI4009`) is sold as
"800x480" but is physically a **480x800 portrait** panel that the vendor's
config rotated — its own install script says `hdmi_cvt 480 800 65`. Naming the
rotated size asks for a mode the panel has never had, and no amount of
adjusting it can work. Rotate with `EMBER_PI_ROTATE`, not by transposing this.

If a vendor shipped a driver for your panel, its install script is the fastest
source of truth for these numbers — read it before measuring anything.

`EMBER_PI_ROTATE` (`none|cw|ccw|ud`) applies in two places, a modesetting
`Rotate` option for X and `fbcon=rotate:` for the console, so the boot messages
and the desktop agree. `EMBER_PI_DIAG` is the diagonal in inches and only sets
the physical size in the EDID, and so the desktop's DPI.

To check it took, on the running Pi:

```sh
cat /sys/class/drm/card1-HDMI-A-1/modes   # exactly one line = the EDID loaded
```

## Not done yet

- **Unreal Tournament's native Linux build** segfaults inside Mesa's `nv30`
  driver during `SDL_GL_CreateContext`, upstream of every UT setting, so no
  configuration avoids it. The Windows build under Wine is unaffected and is
  what the reference machine runs. Only Mesa 26.1.8 is packaged, so there is no
  older driver to fall back to.
- **Extreme Tux Racer** is not packaged by Void for any architecture; it would
  need an xbps-src template.

## Licence

GPL-2.0-or-later.
