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
| **Status** | both targets run on real hardware |

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

- **Hardware OpenGL** on the GeForce — `glxgears` at a vsync-locked 60 FPS
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

## Known: the GeForce 7's 3D driver is broken, and the desktop survives it

On the reference Pentium 4 (GeForce 7600 GS, `nouveau`'s `nv30`/nv4x driver),
sustained 3D faults the graphics engine and it stops retiring fences. Every
waiter then blocks forever, so the desktop appears frozen with the mouse still
moving. It is **not** the hardware — the same card is stable under Windows XP on
the same machine.

**Narrowed to indexed VBO draws.** Bisected with mesa-demos: immediate mode,
client vertex arrays, indexed client arrays and non-indexed VBOs are all clean;
`vbo-drawelements` faults on every run. That is also why the symptom shows up in
menus and file browsing rather than in games — glamor, the X server's 2D
acceleration, draws through indexed VBOs.

**The cause is in Mesa, not the kernel and not the card.** A pushbuf dump of a
faulting draw carries relocations for every GPU address in the submission except
the index buffer's: `IDXBUF_OFFSET` reaches the engine as a bare `0x100`, an
address too small and too misaligned to be a real buffer. The engine reads
indices out of unrelated video memory, and those indices send vertex fetches past
the end of the vertex array — the protection fault.

`nv30_draw_elements()` binds the index buffer through the buffer context, which is
what defers its relocation to pushbuf validation. But the only validation an
indexed draw gets runs earlier, inside `nv30_state_validate()`, so by the time the
index buffer is bound the relocation for that draw has already been emitted and it
misses it. The vertex and fragment-program bindings are registered during state
validation and are covered by it, which is why they alone come back correctly
relocated in the very same command buffer.

Validating once more after the binding, before the draw is emitted, is enough.
`patches/mesa-nv30-idxbuf-reloc-dropped.patch` does that. Measured on the reference
machine: stock Mesa puts 16 relocations in the faulting command buffer, none of them
for the index buffer, and faults on every run; patched it emits 20 — the two extra
pairs being the index buffer's — and ran twelve consecutive times with no fault and
no kernel error.

**`patches/nouveau-nv4x-kill-hung-channel.patch` stops the machine dying with
it.** The engine still faults; the driver now notices a fence past its deadline,
marks the channel dead and returns `-ENODEV`, so the GL program takes the error
and the desktop keeps running. Verified over 34 firings with no kernel oops.

⚠ It is containment, not a cure. There is no engine reset, so once 3D has faulted
it stays dead until reboot. Ordinary 2D use — desktop, menus, file manager,
browser — is unaffected.

## Not done yet

- **Getting the index-buffer fix in front of the X server.** The patch is verified
  against `vbo-drawelements`, but the X server's own 2D acceleration still loads
  the distribution's unpatched Mesa, so the desktop can still fault. That needs a
  rebuilt Mesa package rather than the test tree, which is nouveau-only and carries
  no software-rendering fallback.
- **Unreal Tournament's native Linux build** crashes inside Mesa's `nv30`
  driver. The Windows build under Wine is unaffected and is what the reference
  machine runs.
- **Extreme Tux Racer** is not packaged by Void for any architecture.

---

## Licence

GPL-2.0-or-later. See [LICENSE](LICENSE).
