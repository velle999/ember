# Ember

A small graphical desktop for machines the rest of the world has stopped
building for: 32-bit x86 (Pentium 4 era) and the Raspberry Pi 4/5.

**`Ember` is a working name.** It appears in exactly one place —
`build/config.sh` — so changing it is one line.

## What it is

A Void Linux derivative. Not a new distribution from scratch: a package set, a
desktop configuration, and an image builder on top of a base that already does
the hard part.

| | |
|---|---|
| **Targets** | `i686` (Pentium 4 and later 32-bit x86), `aarch64` (Raspberry Pi 4 / 5) |
| **Base** | Void Linux — glibc, runit, rolling |
| **Not a target** | x86_64. Deliberately. |

## Why Void, and not the obvious answers

This was decided by measurement, on 2026-09-05. The numbers are here so the
decision can be re-argued later against facts rather than memory.

**Debian is out, and this is the decisive fact.** Debian 13 "trixie" dropped
i386 entirely — no kernel, no installer. Worse, its remaining i386 packages are
built *requiring SSE2* and are intended only for multiarch on an amd64 host, so
they will not run on much of the 32-bit hardware Debian 12 supported. Debian 12
"bookworm" still has a real i386 port, but it is on LTS until June 2028 and then
gone. Starting a new project on it means starting on a two-year fuse.

**Arch is out.** Arch dropped i686 in 2017. `archlinux32` exists, but it lags
upstream badly and does not carry the modern graphics stack.

**Alpine is out**, despite fitting the hardware beautifully — it is musl, and
the requirement here is *running legacy software*, which means glibc.

**Void is in**, and the case is empirical:

| | i686 | aarch64 |
|---|---|---|
| repodata rebuilt | **2026-09-05** | **2026-09-05** |
| packages | **14,436** | **14,154** |
| kernel | 6.18 | 6.18, plus `rpi4-kernel` / `rpi5-kernel` 6.12 |
| glibc / Mesa / Xorg | 2.41 / 26.1.8 / 21.1.24 | same |
| Wine | **11.16** | — |

Both ports were rebuilt *the same day this was written*, within twenty minutes
of x86_64. That is a live port, not an archive. i686 carries current Mesa, a
current Xorg, XFCE, LXQt, MATE, i3, IceWM, Firefox — and `wlroots`, so even
Wayland is available on 32-bit if the hardware turns out to take it.

Void also brings **runit** instead of systemd, which on a 1 GB machine is not a
philosophical preference.

## The machines

**The Pentium 4** — 3.0 GHz hyper-threaded, **2 GB DDR400**, with a **GeForce
7600 GS AGP** (512 MB). Better than feared on both counts: the card gets a real
hardware GL driver (nouveau's `nv30`, verified present in Mesa 26.1.8), and 2 GB
puts it in the full XFCE tier rather than the cut-down one. The scarce resource
here is the CPU. See [docs/target-p4.md](docs/target-p4.md) for the graphics
analysis and the AGP caveats.

**A 1992 Compaq is out of scope.** It is not currently powering on, and 386/486
era hardware has no SSE2 and therefore no path to any GL desktop; supporting it
would be a different project with a framebuffer UI.

**Run `tools/hw-probe.sh` on the P4 before any more of this is built.**
It is POSIX sh with no dependencies, so it runs from any live USB, and it
reports the four things that decide the design: SSE2, RAM, whether there is a
real KMS driver or only a framebuffer, and BIOS vs UEFI.

```sh
sh tools/hw-probe.sh          # readable
sh tools/hw-probe.sh --tsv    # to paste back
```

## Building

Needs docker (for xbps) and, to test, qemu.

```sh
build/validate-profiles.sh          # every package name still exists, per arch
build/mkrootfs.sh i686 desktop      # ~2.7 GB rootfs  (EMBER_WINE=0 → ~1.9 GB)
build/mkimage.sh  i686 desktop      # bootable MBR/BIOS disk image
build/boot-test.sh                  # does it boot?      (qemu, serial console)
build/desktop-test.sh               # does a desktop draw? (qemu, framebuffer)
```

**Status: the i686 image boots to a working lightdm greeter**, verified in qemu
with an IDE disk — 6/6 on the boot rig and 3/3 on the desktop rig. It has not
yet run on the real machine, and the one thing qemu cannot tell us is whether
nouveau is happy on that GeForce: qemu renders on a Bochs VGA in software, so a
pass proves X, lightdm and the session are configured correctly and proves
nothing about the actual card.

Write it to a disk or USB stick with the `dd` line `mkimage.sh` prints. Default
login is `ember` / `ember`, root shares the password, and there is a serial
console on ttyS0 with a getty on it — on a machine of this era that is the
difference between debugging it and carrying it to a desk.

The Pi image is not built yet: it is not a BIOS disk image but a FAT firmware
partition plus `config.txt`, and it needs qemu-user-static for the ARM chroot.

## Layout

```
tools/hw-probe.sh    what will this machine actually run
profiles/            package sets, per architecture and per weight tier
build/               rootfs and image builders, and the two qemu rigs
docs/                design notes
```

## Licence

GPL-2.0-or-later.
