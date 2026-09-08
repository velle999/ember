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
| **Status** | both targets run on real hardware; the GeForce 7 3D freeze is fixed |

Not a distribution from scratch: a package set, a desktop configuration, an
image builder and an installer, on top of a base that already does the hard
part.

Why Void: it still builds i686 as a first-class target, it is rolling so the
kernel is new enough for modern hardware quirks, and runit starts fast on a
slow disk. Debian dropped i386 outright; the alternatives were either
x86_64-only or too heavy for 2 GB.

---

## What works

Tested on a 3.0 GHz Pentium 4 with 2 GB of RAM and a GeForce 7600 GS, and on a
Raspberry Pi 4:

- **Hardware OpenGL** on the GeForce, and **stable under sustained 3D** — the
  nv4x driver bug that froze the desktop is fixed (see below); ten unthrottled
  `glxgears` rounds at ~1100 FPS with zero kernel errors
- **Windows games under Wine**, accelerated: Return to Castle Wolfenstein,
  Quake II, Unreal Tournament 99
- **Native 3D**: SuperTuxKart
- **Dual boot** beside Windows XP, with the NTFS partition mounted read-only so
  its game library is readable and its links cannot break
- **RetroArch** with 31 cores baked in, plus menu assets and controller
  profiles — all offline
- **Raspberry Pi**: boots to XFCE with ethernet and wifi, and drives a 4"
  480x800 panel that publishes no EDID at all

Not everything landed. **Steam cannot run on 32-bit x86** — its interface is
64-bit since 2023 and the check is not something a 32-bit machine can satisfy.
It *does* run on the Pi under emulation, but too slowly to use. Both are
written up in [development notes](docs/development-notes.md).

---

## Building

Needs docker (for xbps) and qemu to test.

```sh
build/validate-profiles.sh        # every package name still exists, per arch
build/fetch-cores.sh i686         # libretro cores
build/fetch-assets.sh             # RetroArch menu assets + controller profiles
build/mkrootfs.sh i686 desktop    # 4.7 GB rootfs   (EMBER_WINE=0 saves ~790 MB)
build/mkimage.sh  i686 desktop    # 6.2 GB bootable image
sudo build/write-usb.sh           # write it to a stick, safely
```

`write-usb.sh` addresses the stick by its `/dev/disk/by-id` path and refuses
anything that is not a real, removable, unmounted block device.

### For the Raspberry Pi

Same two scripts with a different architecture, but the ARM path needs
`qemu-user-static` registered with `binfmt_misc` first — the build runs the
target's own binaries, and unlike i686 those cannot execute natively:

```sh
docker run --privileged --rm tonistiigi/binfmt --install arm64   # any host
sudo xbps-install qemu-user-static                               # Void
sudo apt install qemu-user-static binfmt-support                 # Debian

build/fetch-cores.sh aarch64
build/fetch-assets.sh
build/mkrootfs.sh aarch64 desktop
build/mkimage.sh  aarch64 desktop
sudo build/write-usb.sh
```

Both scripts refuse to run without the binfmt handler rather than producing a
rootfs whose package scripts all failed silently.

`RPI_MODEL` selects the board (default `4`). The output is a FAT firmware
partition plus an ext4 root, not a BIOS disk image.

**For a small panel with no EDID**, give it the panel's *native* mode — which
is not always the advertised one. The 4" panel this was built against is sold
as "800x480" but is physically a 480x800 portrait panel that the vendor's
config rotated:

```sh
EMBER_PI_MODE="480 800 65" EMBER_PI_ROTATE=ccw EMBER_PI_DIAG=4 \
    build/mkimage.sh aarch64 desktop
```

That builds a real EDID and hands it to the kernel. `EMBER_PI_ROTATE` is
`none|cw|ccw|ud` and rotates both the desktop and the boot console.

---

## Installing

```sh
ember-install --plan            # show what it would do, change nothing
ember-install /dev/sda          # install to a whole disk
ember-install --reuse /dev/sda3 # install into one existing partition
```

`--plan` is not a dry run flag bolted on afterwards; it is how you are expected
to look first. The installer backs up the partition table before touching it
and verifies the result before reporting success.

On first boot the root filesystem grows to fill its disk, and a swapfile is
created — twice RAM, capped at 4 GB, skipped if the disk cannot spare it.
Neither target has enough memory to run comfortably without one.

---

## What is on it

XFCE, Firefox, Thunar, a terminal, and the things this project exists for:

- **Wine**, for Windows software of the era (791 MB; `EMBER_WINE=0` to omit)
- **RetroArch** with 31 libretro cores, working offline
- **DOSBox-staging**, **ScummVM**, **mednafen**
- **`ember-disc`** mounts a disc image from Thunar's right-click menu, and
  converts `.bin`/`.cue` sets
- **`ember-mount-windows`** mounts a Windows partition read-only

`tools/hw-probe.sh` is POSIX sh with no dependencies, so it runs from any live
USB and reports what decides the design on an unknown machine — SSE2, RAM,
whether there is a real KMS driver, the GPU, BIOS or UEFI:

```sh
sh tools/hw-probe.sh --tsv
```

---

## Layout

```
build/        image and rootfs builders, plus the fetchers
profiles/     package sets: base, desktop, desktop-min, extras, per-arch
installer/    what ends up on the installed system
tools/        hw-probe, preflight, publishing
docs/         development notes
```

---

## The GeForce 7 works — what it took, and what you get

**This is the headline result.** `nouveau`'s `nv30`/nv4x driver — the driver for
every NVIDIA card from the GeForce4 era through the GeForce 7 — could not hold a
desktop together on this machine. Sustained 3D faulted the graphics engine, it
stopped retiring fences, and every waiter blocked forever: the desktop froze with
the mouse still moving. It was never the hardware. The same card is stable under
Windows XP on the same board.

It now runs. On the reference Pentium 4 with a GeForce 7600 GS:

| | |
|---|---|
| **Hardware OpenGL** | `Accelerated: yes`, renderer `NV4B`, 502 MB |
| **Unthrottled `glxgears`** | ~1100–1180 FPS, ten consecutive 45-second rounds |
| **Kernel errors across a full boot** | **zero** — no faults, no channel deaths, no OOM |
| **Real workload** | Wine games, RetroArch, disc images, YouTube, SuperTuxKart |

For comparison, the same machine over a single earlier session, before the fix:

```
                             before      after
DMA_PUSHER faults              40          0
channels "stopped retiring"    13          0
graphics-engine BAD_ARGUMENT   22          0
out-of-memory kills             9          0
```

### What it took

Four independent problems, each of which had to be found separately.

**1. The push buffers were in the wrong place.** `nouveau.vram_pushbuf=1` puts the
GPU command buffer in video memory, behind the AGP aperture. Intermittently the
engine would execute garbage from the *first dwords* of a freshly created
channel's buffer — `get` still sitting at offset 0 — so the channel was dead from
birth and its client died with it:

```
fifo: DMA_PUSHER - ch 2 [glxinfo] get 1ceec000 put 1ceec090 (err: INVALID_CMD)
nouveau: channel 2 stopped retiring fences - marking it dead
```

Every GL client was exposed — the X server, GTK dialogs, RetroArch, Wine. Putting
the command buffers in GART instead (`nouveau.vram_pushbuf=0`), where the CPU
writes them through ordinary system memory, ends it. **Ember sets this by
default.**

**2. A cross-channel fence semaphore.** `nv17_fence_sync()` makes one channel
*acquire* a shared GPU semaphore that another must *release*, and
`nouveau_bo_move_m2mf()` calls it on the driver's own buffer-move channel for
every accelerated eviction — so an acquire that is never satisfied wedges a
*kernel* channel. Older cards never had this: `nv10_fence_sync()` returns
`-ENODEV` and waits on the CPU. `nouveau.fence_sema=0` makes the newer path
behave the same way.

**3. A low-memory brake that could never engage.** TTM asks for `GFP_DMA32`
pages, and a 32-bit kernel has no `ZONE_DMA32`, so those pages come only from the
~838 MB low zone — while the default `ttm.dma32_pages_limit` is roughly the size
of that entire zone. TTM allocated until the kernel started killing processes.
`ttm.dma32_pages_limit=65536` caps it at 256 MB. This applies to **any** 32-bit
host running TTM, not just this card. **Ember sets this by default.**

**4. An unthrottled error-message storm.** The FIFO logs one line per cache entry
when it drains after an error, with no rate limit. On a single-core machine that
flood alone is enough to livelock the box —
`patches/nouveau-nv04-fifo-ratelimit-error-storm.patch`.

⚠ **It is the combination that is stable.** An earlier test of `vram_pushbuf=0`
on its own, without the other fixes, still wedged — which is exactly why it was
wrongly written off for a while. No single one of these is carrying the result.

### Which cards this should apply to

The fence-semaphore path is shared by every chipset whose FIFO exposes
`NV17_CHANNEL_DMA` or `NV40_CHANNEL_DMA`:

    NV17 NV18 nForce2 NV20 NV25 NV28 NV2A NV30 NV31 NV34 NV35 NV36
    NV40 NV41 NV42 NV43 NV44 NV44A NV45 G70 G71 G72 G73
    C51 C61 C67 C68 C73

In retail terms: GeForce4 MX and Ti, the GeForce FX series, GeForce 6, GeForce 7,
and the nForce integrated parts. Cards older than that (NV04–NV15) use a
different fence path that never had the problem.

⚠ **Only one has actually been tested** — a GeForce 7600 GS, chipset 0x4b/G73.
The rest share the code, which is a reason to suspect they are affected, not
evidence that they are. The switches are kernel parameters rather than a rebuild,
so anyone with one of the others is in a position to find out cheaply.

⚠ **What "fixed" is worth here.** This is one machine, verified under deliberate
load — ten unthrottled `glxgears` rounds, 66 GL client launches, repeated disc
mounts — not a fleet over months. The patches in `patches/` are not upstream.

### Containment, kept

`patches/nouveau-nv4x-kill-hung-channel.patch` stays in place regardless. If the
engine ever does fault, the driver notices a fence past its deadline, marks the
channel dead and returns `-ENODEV`, so the GL program takes the error and the
desktop keeps running instead of blocking forever. Verified over 34 firings with
no kernel oops. It is a seatbelt, not a cure — there is no engine reset, so 3D
stays dead until reboot.

## Audio: install pipewire, get exactly one session manager

Void ships pipewire's daemons, autostart entries and config fragments all
unlinked, so a desktop with pipewire installed comes up silent. There are two
ways to start `wireplumber` and `pipewire-pulse` — pipewire's own `conf.d`
drop-ins, or separate XDG autostart entries — and wiring up **both** starts
wireplumber twice. Two session managers race, neither ends up owning the
devices, and every PulseAudio client then blocks for 30 seconds before failing:

```
$ pw-cli ls Device    ->  0
$ pactl info          ->  Connection failure: Timeout   (30.0s)
```

PipeWire's native protocol stays healthy the whole time, so it presents as a
PulseAudio problem rather than a duplicate daemon. Ember wires up the drop-ins
and autostarts `pipewire` alone: one session manager, devices present, `pactl
info` in 0.06 s.

## Not done yet

- **The nouveau patches are not upstream**, and the patched module does not ship
  in the image yet — it is built by hand on the reference machine. Until it does,
  a fresh install gets the two kernel parameters and the containment behaviour of
  stock nouveau, not `fence_sema=0`. Wiring the module into the image build is the
  next piece of work.
- **One machine, one card.** The nv4x result is verified on a GeForce 7600 GS
  under deliberate load, not across the card list it should apply to.
- **Unreal Tournament's native Linux build** crashes inside Mesa's `nv30`
  driver. The Windows build under Wine is unaffected and is what the reference
  machine runs.
- **Extreme Tux Racer** is not packaged by Void for any architecture.

---

## Licence

GPL-2.0-or-later. See [LICENSE](LICENSE).
