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

✅ **GATE 2 — THE X SERVER — ALSO PASSES.** Proven 2026-09-09 on the reference
machine: xorg-server 1.19.7 built from source on current Void, running NVIDIA
304.137 on the GeForce 7600 with hardware GL.

```
X.Org X Server 1.19.7                     built today from 2017 sources, gcc 14.2.1
(II) NVIDIA GLX Module  304.137
OpenGL renderer string: GeForce 7600 GS/AGP/SSE2
OpenGL version string:  2.1.2 NVIDIA 304.137
direct rendering: Yes     AGP: Enabled, AGPGART, 8x, SBA Enabled
```

⚠ **Six things beyond the fork's recipe**, every one of them because this tree is
past the ground that fork tests on (Arch, gcc 12/13, kernel ≤6.15):

1. **gcc 14 rejects what gcc 12 warned about.** `dixfonts.c` fails on
   `CARD32 (*)(void)` vs `uint32_t (*)(void)`. On i686 both are 32-bit and the
   mismatch is in name only, so the fix is four `-Wno-error=` flags rather than
   patching dozens of sites: `incompatible-pointer-types`,
   `implicit-function-declaration`, `int-conversion`, `implicit-int`.
2. **`gl >= 9.2.0` can never be satisfied.** Modern Mesa's `gl.pc` reports the
   OpenGL API version (1.2), not Mesa's. The fork's `libglvnd-glx.patch` rewrites
   the check — which is why `autoreconf -vfi` is mandatory, it touches configure.ac.
3. **`libnvidia-tls`: use the `tls/` copy, not the top-level one.** The `.run`
   ships both and the installer probes to choose. The wrong one segfaults the
   server instantly at `_nv015tls`.
4. **NVIDIA's `libglx.so` must replace the server's**, in
   `lib/xorg/modules/extensions/`. Otherwise the server loads its own 397 KB
   module and reports `Failed to initialize the GLX module`.
5. **1.19's bundled `xkbcomp` cannot compile against current XKB data** —
   `XKB: Couldn't compile keymap`, fatal. Symlink the system one.
6. **`libunwind` is a runtime dependency** the server links but Void does not
   install by default.

⛔ **2 of the fork's 100 patches do not apply** to its own branch head:
`0018_CVE-2021-3472` and `0067_CVE-2025-49177`. Both are security patches. If
this route is ever taken for real, that is not a detail to skip past.

✅ **AND IT IS FASTER — MEASURED THE ONLY WAY THAT MATTERS.** 2026-09-09, on the
reference machine, in real use rather than a benchmark: **YouTube playback holds
sync at 360p under 304, where nouveau managed only 144p.** That is a
user-visible capability change on the workload this machine exists for, and it
is the first evidence that the reason to want 304 is real rather than assumed.
It is consistent with the mechanism: nouveau has no working reclocking for nv4x,
so the GPU sits at boot clocks; 304 clocks it properly.

⚠ **The synthetic numbers, by contrast, were a trap and are not evidence.**
glxgears read 3.5 FPS with the console blanked and 54 FPS awake, and
`__GL_SYNC_TO_VBLANK=0` did not take, so it was vsync-capped throughout — with
glxgears at 96% CPU and Xorg at 0.7%, the P4's CPU was the bottleneck, not the
GPU. Comparing any of that against the nouveau baseline of ~1100 unthrottled FPS
would be worthless. Comparing them would have been worthless — and would have
said 304 was *slower*, which the real workload shows it is not. A synthetic
number taken carelessly is worse than no number.

⛔ **AND SHIPPING IT ARMS A KERNEL BUG THIS PROJECT ALREADY FOUND.** `nvidia.ko`
is an unsigned out-of-tree module, and on this machine that is exactly the
condition under which reading `/proc/modules` NULL-derefs in `m_show` — see
`docs/development-notes.md` ("lsmod takes this machine down"). Once the module is loaded, `lsmod`
kills the box and so does anything invoking `dracut`. It is why `mk-kernel.sh`
builds the nouveau patches in-tree rather than shipping a loose `.ko`.

⚠ **This was the argument for keeping 304 opt-in, and it was overruled on
2026-09-09 — deliberately, not by forgetting it.** The hazard is unchanged and
is now armed on every boot of an NVIDIA machine: `lsmod` and anything invoking
`dracut` — *including a kernel upgrade* — take the box down. What changed is the
weight on the other side: 304 is measurably faster on this card (360p video
sync against nouveau's 144p) and does not show the intermittent drawing
artefacts nouveau produces on nv4x. The mitigation is that neither escape hatch
needs a desktop: `ember.gpu=nouveau` appended at the GRUB prompt, or
`ember-gpu nouveau` from a text console. Run one before upgrading a kernel.

### The old text, kept because it was wrong in an instructive way

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

### Where this landed

⚠ **DECIDED 2026-09-09, then revised the same day.** The first decision was to
stay on nouveau because considerable work was banked there — the nv4x freeze
fix, the patched kernel, two Mesa patches — and switching looked like trading a
working stack for rebuilding graphics from the driver up.

⛔ **THE REVISION DID NOT REQUIRE THAT TRADE, WHICH IS WHY IT WAS AFFORDABLE.**
Both stacks ship. `ember-gpu-detect` reads the boot VGA device and picks one at
boot: an NVIDIA card in 304's supported list gets the proprietary stack, and
everything else — unsupported NVIDIA, Radeon, Intel — gets the in-kernel driver
and the system X server. The kernel stays `linux6.18` and every nouveau and Mesa
patch stays in it, because they are what the fallback path runs on. Nothing was
deleted to make room.

⛔ **THE SUPPORTED-ID LIST IS NOT OPTIONAL AND NOT GUESSABLE.** 304 drives NV4x
through GT2xx. The driver's own `html/supportedchips.html` documents that, but
it *also* lists the GPUs belonging to the 173.14.xx, 96.43.xx and 71.86.xx
branches in the same appendix — in 2-column tables rather than 3-column ones. A
sweep of every `0x####` in that page picks up a GeForce FX 5200 and sends every
FX card down a path where the X server exits at startup. `mk-nvidia304.sh`
generates the list from the 3-column tables only and refuses to write a list
that contains `0x0322` or omits `0x02e1`.

⛔ **AND IF IT IS EVER TAKEN, DROP THE KERNEL IN THE SAME MOVE.** The two
choices are coupled and the current pairing is the awkward one:

- 6.18 was never chosen for the GPU. `KERNEL_I686` is pinned **by name** to
  dodge `linux-base`'s 668 MB of firmware, and **by version** only so the
  rebuilt nouveau matches vermagic. The series itself is just "what Void ships".
- *"Rolling, so the kernel is new enough for modern hardware quirks"* is an
  argument that serves **modern** hardware. This target is a fixed 2006
  machine, and every nouveau patch here exists because a 2025 kernel's nouveau
  is fighting a GeForce 7600. Staying current means re-verifying that patch set
  on every series bump.
- The fork targets **6.12-LTS** natively; Void packages `linux6.12` (6.12.108)
  and `linux6.6`. Reaching 6.18 needed a hand-ported makefile hunk. Going back
  deletes that work instead of adding to it.

So the coherent fallback is a **period-matched stack**: 304.137 + `linux6.12`
LTS + xorg-server 1.19, all three of which the fork already tests together.

⚠ **The counterweights, which are real.** Newer kernels still help the
*non-GPU* modern parts — USB, SATA, the storage that is actually booted from —
and the **Pi 4/5 tier genuinely wants a current kernel**, so this means
different kernel policy per architecture. `config.sh` is already arch-split for
the Pi packages, so it is not new machinery, but it is new complexity.

**Order of work, if it is taken:**

1. `linux6.12` for i686, Pi stays current. Re-check `validate-profiles.sh`.
2. 304.137 module — 29 patches apply, the 2 makefile hunks are ported above,
   and against 6.12 they should not need porting at all.
3. `xorg-server` 1.19 and `xf86-input-libinput` 1.1.0 for i686, from the fork's
   PKGBUILDs into xbps-src. **This is the actual cost.**
4. Delete the nouveau patch set and both Mesa patches for the i686 tier.

⚠ **Why it is worth answering.** On this card the proprietary driver very
likely wins, and not marginally: nouveau has no working reclocking for nv4x, so
the GPU sits at boot clocks, while 304 clocks it properly. And nv30 in Mesa is
lightly maintained code — this project has now patched an index-buffer
relocation bug and a surface refcount leak in it, on top of kernel-side fence
and pushbuf work. Security is not a counter-argument here: the reference
machine does not need to be online.

The cheap first step is a container build of 304.137 against 6.18 headers. It
answers gate 1 with no risk to the machine, and costs nothing but build time.

⚠ That step was taken, both gates passed, and 304 is now the default on a
supported NVIDIA card. nouveau remains what Ember ships on everything else, and
remains the fallback whenever `nvidia.ko` is absent or will not load — a case
`ember-gpu-apply` handles by loading nouveau and recording that it did, so the X
wrapper starts the server matching the driver that is actually running.

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
