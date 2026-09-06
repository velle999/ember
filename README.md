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
context creation, including by `glxgears`, and is benign on its own — the
driver recovers and renders at full speed. What is NOT benign is the same fault
arriving against **Xorg's** channel under 2D load.

⛔ **`nouveau.vram_pushbuf=1` is required, and it is the other half of the AGP
work.** By default nouveau puts its DMA push buffers in GART — system RAM
reached across the AGP bridge — so every GPU command crosses the least reliable
part of a board of this era. On the reference machine that wedged Xorg's own
channel within ~107 seconds of boot:

```
nouveau: Xorg[657]: reloc wait_idle failed: -16     (-EBUSY)
```

and the desktop froze with the mouse still moving, because the hardware cursor
keeps drawing while the server is blocked in the kernel. It struck during
**menus and file browsing, not games** — the tell, because gameplay is 3D and
this is the 2D path glamor drives through GL. With push buffers in VRAM the
same session logged zero faults.

The two settings are not alternatives. Without `via-agp` the GART is 128 MiB
and the shortfall lands in system RAM until the OOM killer takes Xorg; without
`vram_pushbuf` the AGP path is fast and wedges. Both, or neither works.

### Verified on real hardware

| | |
|---|---|
| **P4 / GeForce 7600 GS AGP** | hardware GL — `Accelerated: yes`, `NV4B`, 502 MB, `glxgears` 60 FPS vsync-locked |
| **AGP** | AGP 3.5 @ 8x, GART 512 MiB, VIA VT3314 |
| **Native 3D** | SuperTuxKart |
| **Wine on hardware GL** | Return to Castle Wolfenstein (`GL_RENDERER: NV4B`), Quake II, Unreal Tournament 99 |
| **Dual boot** | installs beside Windows XP; the NTFS partition mounts read-only for its game library |
| **Raspberry Pi 4** | image boots to XFCE, ethernet + wifi, and drives a 4" 480x800 panel that publishes no EDID |
| **Steam on the Pi** | *runs* under [FEX](#steam-on-the-raspberry-pi--it-runs-and-it-is-not-usable) — x86_64 emulated on ARM64, `steamwebhelper` and all — but is **too slow to use**. A demonstration, not a feature |
| **Stability** | the P4 runs a session without a GPU wedge or an OOM kill, which took `via-agp` + `nouveau.vram_pushbuf=1` + swap + the elogind fix below — see each for why none of them is optional |

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

### Steam on a 32-bit host — it does not work

**Steam cannot run on the i686 target.** This was tested to exhaustion rather
than assumed, so the dead ends are recorded here to stop anyone repeating them.

The client binaries genuinely are still 32-bit — `ubuntu12_32/steam` and
`steamui.so` both are — and it gets impressively far. Given `gtk+` (GTK2, for
`steamui.so`) and `xz` (for the runtime unpack), both now in the package
profiles, the client downloads, extracts, loads the 32-bit `steamui.so` and
reports `Running Steam on void  32-bit`.

Then `Is64BitOS()` in `steamui.so` reads `uname(2)` and asserts, because
`utsname.machine` is `i686`.

Inhibiting the updater does work, for what it is worth — `Steam.cfg` with
`BootStrapperInhibitAll=enable` (plus the narrower `*UpdateOnLaunch`,
`*ClientChecksum`, `*BootstrapperChecksum`, all verified present in
`ubuntu12_32/steam`) stops the client being replaced on each launch. It does
not help, because the client you already have is the one that cannot run.

⛔ **Unshimmed, with updates inhibited, it still fails — in the UI.** The
client starts, `steamwebhelper` spawns, and then:

```
src/common/html/chrome_ipc_client.cpp (305) : Is64BitOS()
src/steamUI/steamuisharedjscontroller.cpp (549) : Failed creating offscreen shared JS context
Connection failure: Timeout
./steam.sh: line 1011: Killed
```

`Is64BitOS()` is checked in the **Chrome IPC** path too, so the CEF context the
UI is built on never gets created. The client retries until the OOM killer
takes it — on a 2 GB machine that takes the desktop session with it. Two
independent code paths (`friendsuihelpers.cpp` and `chrome_ipc_client.cpp`)
gate on the same thing, and there is no non-CEF UI left to fall back to.

⛔ **Answering that check does not help either — it makes things worse.**
`tools/steam64shim.c` is an `LD_PRELOAD` that rewrites `utsname.machine` to
`x86_64`. It works, and Steam gets past the assert, and then tries to launch
the things the check was gating:

```
steamwebhelper.sh: Starting steamwebhelper ... steamrt64/pv-runtime/...
pressure-vessel-wrap: 1: Syntax error: ")" unexpected
steam-runtime-launcher-service: 1: ELF: not found
CSteamEngine::BMainLoop appears to have stalled > 15 seconds
```

Those are 64-bit ELFs a 32-bit kernel cannot execute, so the shell falls back
to parsing them as text. Since the 2023 UI rewrite `steamwebhelper` *is* the
interface, so it never renders and the client hangs — which on the reference
machine presented as a UI crash followed by a freeze. The check is
load-bearing, not cosmetic. The shim is kept only as a documented failure.

⚠ There is no "install the older version" route either. Valve's archived
`.deb`s are **bootstrappers, not clients**: an old launcher still downloads
today's client, and Valve publishes no standalone archived clients.

### Steam on the Raspberry Pi — it runs, and it is not usable

**aarch64 under [FEX-Emu](https://github.com/FEX-Emu/FEX)** is the one target
where Steam runs, because FEX emulates x86_64 and answers `Is64BitOS()`
**honestly** rather than being lied to. On the reference Pi 4 the client reaches
its login screen: `steamwebhelper` running, CEF rendering from
`steamloopback.host`, `wmctrl` reporting `Sign in to Steam`.

FEX ships **no prebuilt binaries** — it is a CMake + LLVM source build, about
8½ hours on a Pi 4. What that build needs:

```sh
git clone --recurse-submodules --depth 1 --branch FEX-2608 \
    https://github.com/FEX-Emu/FEX.git
cmake -G Ninja -DCMAKE_BUILD_TYPE=Release \
      -DENABLE_LTO=False -DBUILD_TESTS=False -DBUILD_FEXCONFIG=False ..
ninja -j2
```

- **`-DENABLE_LTO=False` and `-j2`.** Four `clang++` or an LTO link will not fit
  in 1830 MB even with swap. With these it never touched swap at all.
- **`-DBUILD_FEXCONFIG=False`** skips a Qt GUI config tool that is not needed to
  run anything, and whose absence otherwise fails the configure.
- **Leave `BUILD_STEAM_SUPPORT=FALSE` despite the name** — enabling it *removes*
  `FEXRootFSFetcher`, which is how the x86_64 rootfs is obtained.
- **Pin the tag.** FEX plans to require ARMv8.4-a, which drops *every* Raspberry
  Pi including the Pi 5 (their issue #4120 lists "Raspberry Pi: Everything").
  `FEX-2608` still supports ARMv8.0.

⛔ **Void ships no `erofsfuse`**, so FEXServer cannot mount the `.ero` rootfs and
dies with a bare `terminate called without an active exception`. Extract it
instead — `fsck.erofs --extract=DIR --overwrite img.ero` — and point
`~/.fex-emu/Config.json` at the directory. That avoids FUSE at runtime too.

⚠ `FEXInterpreter` and `FEXLoader` no longer exist; the binary is `FEX`, and
`FEXBash` is the convenient entry point. And `pgrep -x steam` finds nothing
while Steam is running perfectly well — the processes are `steamwebhelper`.

⛔ **It is not usable, and that is the honest summary.** It runs — the client
starts, the UI renders, it reaches a login — and then it is too slow to
actually use. Treat this as a demonstration that the emulation works, not as a
way to play anything.

Why, concretely: 1358 MB RAM and 647 MB swap **just sitting at the login
screen**, on an 1830 MB board, which is most of the machine gone before a game
is involved. The UI is emulated Chromium. And the Pi 4's Cortex-A72 is
ARMv8.0-a, so FEX has none of the extensions that make x86 emulation cheap —
FEAT_LSE atomics, FEAT_FLAGM flags, FEAT_LRCPC ordering. In FEX's own words,
without them "x86 emulation is either slow (atomics) or buggy (TSO emulation
disabled)".

⚠ A Pi 5 does not rescue this. Its A76 is ARMv8.2-a — better, still short of
the ARMv8.4-a FEX is moving to, and still on the list of hardware they intend
to drop.

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

## The elogind respawn loop

⛔ **lightdm must wait for elogind, not just dbus.** elogind has two owners —
runit's service, and D-Bus activation via
`org.freedesktop.login1.service` (`Exec=elogind --daemon`). Whichever loses the
race respawns for the life of the boot, because runit restarts a service whose
run script exits and `elogind.wrapper` exits immediately when it finds a daemon
already running:

```
elogind[18058]: elogind is already running as PID 636
```

With a manual login runit wins easily and nobody notices. **With autologin it
loses every time**: lightdm brings a session up about twelve seconds into boot,
that session asks D-Bus for `login1`, and activation gets there first. On the
reference machine that was 2368 restarts in forty minutes and ~19000 PIDs
against a `pid_max` of 32768 — constant fork/exec on a 3 GHz Pentium 4, which
presents as a desktop that feels unstable and occasionally drops to the login
screen. It sends you looking at the GPU, which is the wrong place.

`build/_chroot-setup.sh` adds one line to `/etc/sv/lightdm/run`, the same idiom
elogind's own script uses to wait for dbus, and fails the build if it is not
there afterwards. ⚠ That file belongs to Void's lightdm package, so an upgrade
drops a `.pacnew` and reverts it on an installed machine.

## Swap

⛔ **Ember's targets do not have enough RAM to run without it**, and both
reference machines proved it doing ordinary things:

- the Pentium 4 (2 GB) lost **Xorg to the OOM killer**, which presents as a
  hard freeze with a still-moving mouse cursor and looks nothing like a memory
  problem
- the Raspberry Pi 4 (1830 MB) **could not link FEX at all** until a swapfile
  existed

So `ember-swap` runs once on first boot and makes one: twice RAM, capped at
4 GB, and skipped entirely unless at least 2 GB would still be free afterwards
— a swapfile that fills the disk trades one unusable failure for another.

⚠ **Not shipped inside the image.** Several GB of zeroes written to a stick for
nothing, on an image sized to fit a nominal 8 GB device. It is created at
`07-ember-swap.sh`, after `06-ember-expand.sh` has grown the root to fill the
disk — before that, "free space" is the image's own few hundred MB of slack.

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
