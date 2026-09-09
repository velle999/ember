# Target: the Pentium 4 + GeForce 7600 GS

The first real machine. Everything here was verified on 2026-09-05 against the
packages Ember would actually install, not from memory.

## The machine

| | |
|---|---|
| CPU | **Pentium 4 3.0 GHz**, hyper-threaded (2 logical cores) |
| RAM | **2 GB DDR400** |
| GPU | **GeForce 7600 GS, AGP** — G73, the GeForce 7 family |
| VRAM | 512 MB |

**Tier: `desktop`** — XFCE, not the cut-down IceWM tier. 2 GB is comfortably
above where that choice gets difficult; on this machine the scarce resource is
the CPU, not memory, and no window manager fixes that.

### The CPU baseline is not a concern

Void's i686 port is built `-mtune=i686` — **tune, not march**, so the
instruction selection is a true Pentium Pro baseline with no SSE assumed at all.
A 3 GHz P4 is far above the floor; there is no compatibility question here.

The flip side is that nothing is *optimised* for this chip either: every package
is scheduled for generic i686. Void ships `xbps-src`, so rebuilding a few hot
packages with `-march=prescott` is available later if it ever seems worth the
build time. It is not a prerequisite for anything.

⚠ **Whether this is a Northwood or a Prescott is still unknown**, and the probe
answers it in passing: Prescott has SSE3, Northwood does not. It changes nothing
about the target, but it is the difference between two quite different chips.

## The graphics stack, which was the real worry

⚠ **THE PROPRIETARY ROUTE IS NOT CLOSED, AND THIS SECTION USED TO SAY IT WAS.**
The original wording — "it does not build against a 6.x kernel" — is wrong, and
being stated as a closed door meant nobody re-examined it for four days of
nouveau bug-hunting. What is actually true:

- Void packages no legacy NVIDIA driver for i686 — **correct**. There is no
  `nvidia304` srcpkg; `nvidia390` exists and starts at Fermi, so it does not
  cover a GeForce 7.
- Stock 304.137 does not build on 6.x — **correct**.
- Nothing builds on 6.x — **WRONG**. `github.com/flydiscohuebr/nvidia-304`
  carries patched 304.137 to Arch's 6.14 and 6.12-LTS, maintained as recently
  as 2025-03.

✅ **GATE 1 — THE KERNEL MODULE — PASSES.** Tested 2026-09-09 in a container
against Ember's own patched headers: `nvidia.ko`, 14.5 MB, `elf_i386`, linked
against `kernel-headers-6.18.49_99`. It took three things, all now known:

- **29 of the fork's 31 patches apply unmodified**, including every kernel-6.15
  C change to `nv.c` and `nv-linux.h`.
- **Two hunks need porting**, both in `kernel/Makefile.kbuild`, both because
  that PKGBUILD's `source_x86_64` is cut against the **64-bit** tarball — the
  hunks carry `-mno-red-zone -mcmodel=kernel`, which do not exist in the 32-bit
  file. The port is: `EXTRA_CFLAGS` → `ccflags-y`, add `-std=gnu17`,
  `EXTRA_LDFLAGS` → `ldflags-y`, and the objtool bypass 6.15+ needs because the
  blob fails objtool — `$(MODULE_NAME).o: override objtool-enabled =`.
- ⛔ **Void's `linux6.18-headers` is missing `arch/x86/entry/syscalls/`** —
  `Makefile`, `syscall_32.tbl`, `syscall_64.tbl`. Without them the kernel's own
  `archheaders` target dies before nvidia compiles anything. Copied out of
  `linux-6.18.tar.xz` to get past it. ⚠ **This is a fact about Ember's kernel
  package, not about nvidia** — any out-of-tree module built this way against
  these headers hits it.

⚠ **Builds is not loads.** It has not been `modprobe`d on the P4, has not bound
the card, and has not rendered a frame. No BTF was generated either (no
`vmlinux` in the headers tree), so it is not byte-identical to a full dkms
build.

⛔ **GATE 2 — THE X SERVER — IS NOW THE WHOLE DECISION, AND IT IS UNCHANGED.**
The fork ships an entire `xorg-server1.19-git-edit` tree because 304.137 needs a
2017 X server; Ember runs **21.1.24**. Arch's instructions also pin
`xf86-input-libinput` to **1.1.0** or the keyboard and mouse stop working, and
the maintainer carries a stack of CVE backports for 1.19 precisely because it is
long past end of life.

⚠ The X ABI binds **video and input drivers**, not clients — XFCE, RetroArch and
Wine do not care what version the server is. So the blast radius is the driver
set, not the desktop. For a distribution targeting machines nobody builds for,
carrying its own X server for the i686 tier is a legitimate choice rather than
an absurd one. It is a project-direction call, and it is the only thing left in
the way.

⚠ **Why it is worth answering.** On this card the proprietary driver very
likely wins, and not marginally: nouveau has no working reclocking for nv4x, so
the GPU sits at boot clocks, while 304 clocks it properly. And nv30 in Mesa is
lightly maintained code — this project has now patched an index-buffer
relocation bug and a surface refcount leak in it, on top of kernel-side fence
and pushbuf work. Security is not a counter-argument here: the reference
machine does not need to be online.

The cheap first step is a container build of 304.137 against 6.18 headers. It
answers gate 1 with no risk to the machine, and costs nothing but build time.

Until that is done, nouveau is what Ember ships — by measurement, not because
the alternative was ruled out.

**nouveau is three drivers wearing one name**, and which one a card lands on is
the whole question:

| driver | cards | in Mesa 26.1.8? |
|---|---|---|
| `nv30` | GeForce FX / 6 / **7** | **yes — verified** |
| `nv50` | GeForce 8 / 9 / 200 / 300 | yes |
| `nvc0` | GeForce 400+ | yes |
| *(pre-NV30)* | GeForce 1–4 | **gone** — no Gallium driver any more |

A GeForce 7600 GS is `nv30`. That was worth checking rather than assuming,
because Mesa has been shedding old drivers to its Amber branch for years and a
`nouveau_dri.so` on disk proves nothing — modern Mesa ships one loader that
dispatches internally. The evidence is inside `libgallium-26.1.8.so`:

```
nv30_screen_create
%s:%d - nv30_screen_init failed: %d
```

plus 11 further `nv3x`/`nv4x` internal symbols. **The card gets a real hardware
GL driver**, roughly OpenGL 2.1. Not fast, lightly maintained, but not llvmpipe.

### AGP: the forum advice you will find is stale

Searching this problem turns up `nouveau.agpmode=1` and `agpmode=0` everywhere.
**That parameter no longer exists.** Current mainline `nouveau_drm.c` exposes
only `config`, `debug`, `noaccel`, `modeset`, `atomic` and `runpm` — checked
against the source, not remembered.

AGP is now configured automatically in `nvkm/subdev/pci/agp.c`, which disables
AGP fast-writes on its own and carries a hardcoded quirk table of exactly **two**
entries (a VIA Apollo PRO133x pairing, and SiS 761 forced to PCI mode). There is
no runtime knob. So if this card proves unstable on this board:

1. `nouveau.noaccel=1` — keeps modesetting, drops acceleration. The real fallback.
2. `nouveau.modeset=0` — turns nouveau off entirely; `xf86-video-vesa` takes over.
3. A quirk-table entry, which is a kernel patch, not a setting.

### What this means for the desktop

**Xorg, not Wayland, on this machine.** `nv30` is the weakest of the three
nouveau drivers and wlroots wants a solid GLES2; the combination is a poor bet
when a well-trodden X11 path exists. Void's i686 port carries `wlroots` 0.20, so
Wayland stays available to try later — it is just not what the first image
should stake itself on.

## Still open

- Whether `nv30` on this board is **stable**, which no amount of reading
  settles. This is now the only real unknown, and only the machine can answer it.
- Northwood or Prescott (the probe's `sse3` line says).
- Whether XFCE's compositor is worth having on `nv30`, or whether it should be
  off by default here.
