# Development notes

Things that cost real time to work out on this hardware, kept so they are not
worked out twice. This is a debugging record, not documentation — if you only
want to build or use Ember, the [README](../README.md) is the whole story.

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

### The freeze is a wedged GPU channel, and it is NOT the OOM (2026-09-06)

The netconsole capture caught the kill five times, and the whole story above
turned out to be two separate things that were being read as one.

**What the freeze actually is.** Under GL load the desktop reproduces in about a
minute, and `Xorg` goes into **`D` state** — uninterruptible sleep. That is why
the mouse still moves: the cursor is drawn by the GPU and keeps working while
the server is stuck in the kernel. `/proc/<xorg>/stack` says exactly where:

```
nouveau_fence_wait_legacy+0xa4/0x1d0 [nouveau]
dma_fence_wait_timeout → dma_resv_wait_timeout
nouveau_gem_ioctl_pushbuf+0xbd8/0x1000 [nouveau]
drm_ioctl → nouveau_drm_ioctl → __ia32_sys_ioctl
```

Xorg is waiting on a GPU fence that never signals. The order in `dmesg` is
consistent every time: a GL client faults the graphics engine —

```
nouveau: gr: intr … nsource [DMA_VTX_PROTECTION] nstatus [PROTECTION_FAULT]
         ch 3 [… glxgears[1013]] subc 7 class 4097
```

— the FIFO then fills with `CACHE_ERROR` (1555 lines in one session, most of
them `ch N [unknown]`, the channel already gone), the engine stops retiring
fences, and Xorg's next pushbuf blocks forever. Every 15 s the retry logs

```
nouveau: Xorg[1240]: reloc wait_idle failed: -16      (-EBUSY)
nouveau: Xorg[1240]: failed to idle channel 1
```

⛔ **Both documented mitigations are already in place and neither prevents it.**
`nouveau.vram_pushbuf=1` is on the command line *and genuinely in effect* — the
parameter exists in this kernel (`/sys/module/nouveau/parameters/vram_pushbuf`,
and `modinfo` lists it), so this is **not** another `agpmode`-style silently
ignored option. `PageFlip false` is in `20-modesetting.conf`. The wedge happens
anyway.

⚠ The faults originate in a **client's** channel and the casualty is **Xorg's**.
That matches the note above that these faults are benign from `glxgears` alone —
they are, right up until the engine stops retiring fences for everyone.

### ⛔ The AGP explanation above is wrong, and so was my first correction of it

The OOM kills are real and they are **lowmem** exhaustion, not memory
exhaustion: Xorg is killed at ~380 MB of address space and ~90 MB resident while
~870 MiB of highmem sits free, because this is a HIGHMEM i686 kernel where
everything the kernel allocates must come from an 838 MiB zone.

⛔ **But the 512 MiB AGP GART is not what consumes it.** Measured across three
boots, at the greeter:

| configuration | GART | LowFree |
|---|---|---|
| `modprobe.blacklist=nouveau` | — | 750 MiB |
| nouveau + AGP | 512 MiB | 739 MiB |
| nouveau, `install via_agp /bin/true` | 128 MiB | 745 MiB |

The GART size makes **no difference at boot**. Nor is it a GL client leak:
six `glxgears` runs moved `LowFree` by 0.1 MiB, a full XFCE session by nothing
over three minutes, and stopping Xorg outright returned 0.5 MiB.

⚠ **A number that looked conclusive because the boots were not comparable.**
An earlier pass here recorded 588 MiB "pinned by a driver" and put the GART next
to it. That figure came from a machine 2½ hours into a session; the boots it was
compared against were fresh. The consumption is real and still unexplained — it
appears over hours of use and nothing yet reproduces it on demand — but nothing
supports blaming the GART, and the fallback the section above warns against
neither helps nor hurts.

`/var/service/lowmem-watch` samples ZONE_NORMAL every minute to
`/var/log/lowmem-watch.log`, with a column for the part no counter accounts for,
so the ramp can be read after the fact rather than guessed at.

⚠ `kernel.printk = 7` is now set in `/etc/sysctl.d/60-ember-oom-verbose.conf`.
At `loglevel=4` netconsole carried the `Killed process` line but **not** the
`Mem-Info` dump naming the exhausted zone, which is the difference between a
diagnosis and an inference.

### It is nouveau's nv4x GL, and nothing tunable fixes it (2026-09-06)

The desktop wedges under **any sustained GL load**, and every candidate cause has
now been eliminated by measurement rather than reasoning. Reproducer is
`/usr/local/sbin/wedge-test` on the box; it verdicts on Xorg's process **state**,
because the failure is Xorg blocking forever rather than anything a benchmark
number would show.

**The failure.** A GL client faults the graphics engine
(`gr: intr … DMA_VTX_PROTECTION / PROTECTION_FAULT`), the FIFO fills with
`CACHE_ERROR`, the channel reports `DMA_PUSHER … INVALID_CMD`, the engine stops
retiring fences, and Xorg's next pushbuf blocks forever in
`nouveau_fence_wait_legacy` — process state **`D`**, uninterruptible. The mouse
keeps moving because the cursor is drawn by the GPU. Every 15 s the retry logs
`reloc wait_idle failed: -16`. It sometimes escalates to an OOM kill, and twice
it took the whole machine down hard enough to need a power cycle.

**What was ruled out, each with a soak rather than one pass:**

| suspect | test | result |
|---|---|---|
| lowmem / TTM | capped `ttm.pages_limit` etc. to 256 MiB | **still wedges**, 729 MiB lowmem free |
| AGP transport | `install via_agp /bin/true`, GART 128 MiB | **still wedges**, 747 MiB free |
| submission rate | `/etc/drirc` `vblank_mode=3`, verified 60.02 FPS | **still wedges** |
| XFCE compositor | already `use_compositing: false` | not a factor |
| 2D / glamor | 90 s window churn, no GL client | clean, **0** errors |
| `AccelMethod "none"` | — | ⛔ `Accelerated: no`, llvmpipe. Not acceptable |

⛔ **The OOM is downstream, not the cause.** The netconsole trace shows the
allocation failing inside `ttm_bo_evict → nouveau_ttm_tt_populate →
__ttm_pool_alloc` with `gfp_mask=GFP_USER|GFP_DMA32`, and on i686 there is no
ZONE_DMA32, so those pages can only come from the 838 MiB lowmem zone. That is a
real second-order problem — TTM's own `dma32_pages_limit` defaults to 214381
pages, **exactly the whole lowmem zone**, so its brake can never engage before
the zone is gone. But capping it does not stop the wedge, so it is a consequence
of the GPU dying, not the reason.

⚠ **Two conclusions in this file were reached from single runs and were wrong** —
"AGP off fixes it" (8 errors in a short run, 498 and a wedge in a full one) and
"throttled GL survives" (fine for 90 s, wedged on the next soak). On hardware
this marginal, one clean pass means nothing. Soak it.

**So the open question at the top of `target-p4.md` has an answer: `nv30`/nv4x is
NOT stable on this board.** 2D is fine; the desktop is usable; GL is what breaks
it, and there is nothing left to turn off.

### The vertex path is most of it — `NV30_SWTNL=1` buys 4 soaks, then fails too

`nsource` on the faults is `DMA_VTX_PROTECTION`: the **vertex** DMA object
pointing somewhere invalid. (`class 4097` is printed in hex — `0x4097` is
`NV40_3D`.) Mesa's nv30 driver has `NV30_SWTNL=1`, which moves vertex transform
onto the CPU and bypasses that path, and it is by far the best result of
anything tried:

| | soaks survived |
|---|---|
| stock | wedges on run **1** |
| `NV30_SWTNL=1` | survived **4**, wedged on the 5th |

Zero new nouveau errors during the surviving soaks, hardware GL retained
(`Accelerated: yes`, NV4B). So the hardware vertex path is where most of the
damage comes from — but not all of it, and this is a mitigation, not a fix.

⚠ **Three mitigations now have survived several passes and then failed** (AGP
off, forced vsync, SWTNL). That pattern is itself the finding: the driver is
marginal everywhere, so any change shifts timing and buys a few runs. Nothing
here is a fix until it survives a long soak, and a handful of clean passes is
not evidence.

⚠ **A retracted observation, kept because it was convincing.** Mid-soak,
`glxinfo` — a one-shot query — was logging ~490 `CACHE_ERROR`s, which looked
like proof the driver was broken at rest. It is not: on a clean boot `glxinfo`
produces **zero** errors, twice over. Those errors were glxinfo running against
a GPU already degraded by the preceding soaks. Once the engine has faulted,
*everything* GL faults, which makes any measurement taken after the first wedge
worthless. Reboot between tests.

### ⛔ Do not buy an HD 2600 Pro AGP — `r600` is gone from this Mesa

Checked the way `nv30` was checked, by reading the driver list out of
`libgallium-26.1.8.so` rather than trusting a file's presence:

```
crocus i915 iris llvmpipe nouveau r300 radeonsi softpipe virtio_gpu
```

**`r600` is absent.** Mesa has retired R600/R700/Evergreen to Amber, so an
HD 2600 (RV630) would fall to **llvmpipe** — strictly worse than the card that is
in the machine. `radeon.ko` still exists in the kernel and the RV630 firmware is
not installed either (`linux-firmware-amd`), but that is moot.

⚠ **`r300` IS still present** — that covers AGP-era Radeon 9500–X1950. It is the
only non-NVIDIA AGP path left with a real Gallium driver in this Mesa, and it is
far more shaken-out code than nv4x. OpenGL 2.0 rather than 2.1, and slower
silicon than a 7600 GS, so it would be a trade of capability for stability, not
an upgrade. ⚠ `r300` is old enough to be an Amber candidate itself — check the
libgallium list again before buying anything.

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


## The Raspberry Pi's display

vc4 KMS works: it binds every component, registers a DRM device, and X runs on
`modesetting` with glamor and full RandR. XFCE's Display settings panel works.

> ⛔ **This section used to say the opposite** — that vc4 "binds only
> `fe400000.hvs`, never registers a DRM device", and was therefore blacklisted.
> That was wrong. The half-bound driver was caused by the legacy `hdmi_cvt` and
> `hdmi_force_hotplug` settings this builder itself wrote: they stop vc4
> initialising. Removing them fixed it, and the blacklist had been costing the
> image its hardware acceleration and its Display panel for nothing.

## A panel with no EDID

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


## Emulation and old games

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


## Steam on a 32-bit host — it does not work

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

## Steam on the Raspberry Pi — it runs, and it is not usable

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
- ⛔ **`-DBUILD_THUNKS=True`, which the build above omits.** Without thunks
  there is **no hardware GL under FEX at all**, and the failure is quiet — the
  guest is x86_64, so it looks for an x86_64 `vc4_dri.so`, and Mesa's x86_64
  build has no such thing because vc4 is an ARM GPU. Steam logs

  ```
  vc4: driver missing
  glx: failed to create dri3 screen
  failed to load driver: vc4
  ```

  and carries on without acceleration. Thunks are what forward guest GL calls
  to the **host's** native `vc4_dri.so`. `ThunksDB.json` is installed either
  way, which makes it look configured when it is not — check
  `BUILD_THUNKS` in `Build/CMakeCache.txt`, not the presence of that file.

### Building the thunks off-host: four things in the way (2026-09-06)

Turning `-DBUILD_THUNKS=True` on is not the end of it. The guest half of every
thunk is an **x86_64 (and i686) shared library**, so it is a cross-build, and
the Pi is not a machine FEX expects to cross-build from. Four separate things
had to be fixed, and each one only appears once the previous is out of the way.

⛔ **1. `lld` is not installed, and the thunk build forces it.**
`Data/CMake/toolchain_x86_64.cmake` sets `-fuse-ld=lld` into all three linker
flag variables the moment `ENABLE_CLANG_THUNKS` is on, printing *"Force enabling
LLD as well"*. Void splits the linker out of the LLVM meta package, so `clang21`
is installed and `ld.lld` is not:

```
clang++: error: invalid linker name in argument '-fuse-ld=lld'
```

⚠ It surfaces as CMake's *"is not able to compile a simple test program"*, which
reads like a broken compiler. Install `lld21` — match the clang version, not the
meta package. One package, no dependency churn.

⛔ **2. There is no x86 sysroot, and the FEX RootFS is not one.**
`Ubuntu_24_04` is a *runtime* rootfs: 1.9 GB extracted, and `/usr/include` holds
three entries (`X11`, `gnumake.h`, `renderdoc_app.h`). No `stdio.h`, no
`crt1.o`, no `libc.so`. Pointing `X86_DEV_ROOTFS` at it looks reasonable and
fails identically to pointing it at `/`.

`tools/mk-x86-sysroot.py` builds a real one out of Ubuntu debs — index, resolve,
unpack, no `apt` and no chroot. **Both architectures**, because FEX adds
`guest-libs` *and* `guest-libs-32` unconditionally; a 64-bit-only sysroot fails
at the 32-bit ExternalProject after everything else has already built. ~200
packages per architecture. What it had to get right:

- ⛔ **Absolute symlinks.** A deb ships
  `libGL.so -> /usr/lib/x86_64-linux-gnu/libGL.so.1` as an *absolute* link.
  Unpacked into a sysroot that resolves against the **host** root, where the
  path is either missing or is the aarch64 library.
- ⛔ **usrmerge.** `libc.so` is a linker *script* naming
  `/lib/x86_64-linux-gnu/libc.so.6`, and `/lib -> usr/lib` comes from
  `base-files`, which a sysroot has no reason to install. Without it lld reports
  a missing libc that is sitting right there.
- ⛔ **Python's `tar` filter rejects a deb with an absolute symlink** —
  `OutsideDestinationError` naming a path that is not outside anything. The fix
  is not `filter=None`, which drops the traversal check on debs fetched over
  plain http; rewrite the link target relative and hand it to the real filter.
- ⚠ `ar` **will not read an archive from stdin.** `ar t -` exits 9 saying
  nothing useful.
- ⚠ `xz` and `zstd` are not installed on Void by default, and are what modern
  `.deb` payloads are compressed with.

⛔ **3. `X86_DEV_ROOTFS` never reaches the compiler.**
`ThunkLibs/GuestLibs/CMakeLists.txt` passes it to **thunkgen** as `--sysroot` so
the generator can parse x86 headers. Nothing puts it on the compile or link
line. That is fine upstream, where the host is x86_64 or a multiarch Debian with
real cross libs at `/` — and invisible here until the guest sub-build's own
compiler test fails. `tools/fex-thunks-crossbuild.patch` sets `CMAKE_SYSROOT` in
both toolchain files, which is the variable that reaches every command.

⛔ **4. And then CMake runs the sysroot's binaries on the host.**
With `CMAKE_SYSROOT` set and nothing else, `find_package(PkgConfig)` locates
`<sysroot>/usr/bin/pkg-config` — an x86_64 ELF — and executes it on aarch64:

```
<sysroot>/usr/bin/pkg-config: 1: Syntax error: "(" unexpected
CMake Error: Could NOT find PkgConfig (missing: PKG_CONFIG_EXECUTABLE)
```

⚠ Reported as a *missing package*, which sends you installing pkg-config that is
already there. Headers and libraries must come from the sysroot; **tools must
not** — `CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER`, the rest `ONLY`. And then the
host pkg-config needs `PKG_CONFIG_LIBDIR`/`PKG_CONFIG_SYSROOT_DIR` pointed at
the sysroot's 72 `.pc` files, or it answers with aarch64 paths that link
nothing. Both are in the same patch.

**The recipe, once all four are in:**

```sh
sudo xbps-install -y lld21 xz zstd
tools/mk-x86-sysroot.py ~/x86_64-sysroot          # ~400 debs, both arches
patch -d ~/FEX -p1 < tools/fex-thunks-crossbuild.patch
cd ~/FEX/BuildThunks
cmake -DBUILD_THUNKS=True -DX86_DEV_ROOTFS=$HOME/x86_64-sysroot .
ninja -j2
```

⚠ **Verify the cross-toolchain before starting an 8-hour build**, because every
failure above appears *after* the host half has built:

```sh
clang -target x86_64-linux-gnu --sysroot=$S -fuse-ld=lld t.c -lGL -lX11 -o t
clang -target i686-linux-gnu   --sysroot=$S -fuse-ld=lld t.c -lGL -lX11 -o t
```

`readelf -h` should say `ELF64 … X86-64` and `ELF32 … Intel 80386`.

⚠ **There is no `tmux` or `screen` on the Pi**, so a build started from a
terminal dies with the terminal — that is what stopped the first attempt at 349
targets. `setsid nohup ninja -j2 </dev/null >log 2>&1 &`.

⚠ Whether thunks make Steam *usable* on a Pi 4 rather than merely accelerated is
still untested — see the RAM and ARMv8.0 arithmetic above.

⛔ **Void ships no `erofsfuse`**, so FEXServer cannot mount the `.ero` rootfs and
dies with a bare `terminate called without an active exception`. Extract it
instead — `fsck.erofs --extract=DIR --overwrite img.ero` — and point
`~/.fex-emu/Config.json` at the directory. That avoids FUSE at runtime too.

⚠ `FEXInterpreter` and `FEXLoader` no longer exist; the binary is `FEX`, and
`FEXBash` is the convenient entry point. And `pgrep -x steam` finds nothing
while Steam is running perfectly well — the processes are `steamwebhelper`.

⛔ **It is not usable, and that is the honest summary.** It runs — the client
starts, the UI renders, it reaches a login — and then it is too slow to
actually use, and crashes when a game is installed. Treat this as a
demonstration that the emulation works, not as a way to play anything.

⚠ Part of that is self-inflicted and fixable: the build above was made
**without thunks**, so there is no hardware GL and everything above is
software-rendered under emulation. Whether thunks make it *usable* on a Pi 4
rather than merely faster is untested.

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

## The test rigs

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

