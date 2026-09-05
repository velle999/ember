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

## Where this is uncertain

⚠ **The Pentium 4 is not yet proven to run a graphical desktop.** It has SSE2,
which is Mesa's llvmpipe floor, so software GL *can* run — but "can run" and
"is usable on a single-core P4" are different claims and only one of them has
been measured. The older laptop is a bigger question: pre-2001 x86 has no SSE2
at all, which is a hard blocker for any GL path.

**Run `tools/hw-probe.sh` on both machines before any more of this is built.**
It is POSIX sh with no dependencies, so it runs from any live USB, and it
reports the four things that decide the design: SSE2, RAM, whether there is a
real KMS driver or only a framebuffer, and BIOS vs UEFI.

```sh
sh tools/hw-probe.sh          # readable
sh tools/hw-probe.sh --tsv    # to paste back
```

## Layout

```
tools/hw-probe.sh    what will this machine actually run
profiles/            package sets, per architecture and per weight tier
build/               rootfs and image builders
docs/                design notes
```

## Licence

GPL-2.0-or-later.
