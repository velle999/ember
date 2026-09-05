# Target: the Pentium 4 + GeForce 7600 GS

The first real machine. Everything here was verified on 2026-09-05 against the
packages Ember would actually install, not from memory.

## The machine

| | |
|---|---|
| CPU | Pentium 4, hyper-threaded (2 logical cores) |
| GPU | **GeForce 7600 GS, AGP** — G73, the GeForce 7 family |
| VRAM | 512 MB |
| System RAM | **unknown — this is the open question** |

⚠ **512 MB is the card, not the machine.** System RAM is still unmeasured and it
decides the desktop tier: under a gigabyte means `desktop-min` and no Firefox;
two gigabytes means `desktop` is comfortable. `tools/hw-probe.sh` answers it.

## The graphics stack, which was the real worry

**The proprietary route is closed.** NVIDIA's legacy 304.xx branch was the last
to support GeForce 6/7 and it does not build against a 6.x kernel. Void packages
no legacy NVIDIA driver for i686 at all — checked. So nouveau is not a
preference here, it is the only option.

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

- **System RAM.** Decides the tier. Run the probe.
- Whether `nv30` on this board is *stable*, which no amount of reading settles.
- Whether the P4 is a Northwood or a Prescott — the probe's `lm` flag says. It
  changes nothing here (the target is i686 either way) but it is worth knowing.
