# Old games: per-title notes

`profiles/oldgames.pkgs` names the tools. This file records the traps that cost
real time on the reference Pentium 4, and what fixed each one. Everything here
was measured on that machine, not inferred.

Read `README.md`'s "Graphics drivers" section first. Two facts underpin most of
what follows: the NVIDIA 304 stack caps at **OpenGL 2.1**, and Wine 11.17 needs
the patch from `build/mk-wine.sh` before any Direct3D or DirectDraw game runs at
all.

## Wine exposes Shader Model 2, even though the card has 3.0

The GeForce 7600 supports Shader Model 3.0 in hardware, and under Windows a game
sees it. Under Wine it does not: wined3d derives shader caps from OpenGL, 304
gives GL 2.1 with GLSL 1.20, and that maps to `vs_2_0` / `ps_2_a`.

Games of this era pick a render path from those caps and load a matching data
file. A game that ships only its Shader Model 3 data therefore breaks under Wine
on this hardware while working on the same card under Windows. Fallout 3 below is
one case; expect others.

## Fallout 3: a missing shader package, not a Wine bug

**Symptom.** The game starts, renders its first frames, then dies about twelve
seconds in:

```
wine: Unhandled page fault on read access to 00000000 at address 00B4DE75
```

**Cause.** `Fallout3.exe+0x74de75` reads a subsystem pointer from a global table
and dereferences it without checking. Retail ships `Data/Shaders/shaderpackage001`
through `019`; the ElAmigos repack installed here ships only 14 of the 19, leaving
out `001`, `005` and `008` — which are precisely the small, low-end packages
(209-678 KB, against ~1.3 MB for the rest). Those are the Shader Model 2 paths,
the only ones Wine can select here. The game writes the missing package's slot as
NULL and crashes at its first use. `RendererInfo.txt`, written beside the ini in
`My Games/Fallout3`, names the chosen path: `BSSM_SV_2_A96`, `PSversion 200`,
`3.0 Support: no`.

**Fix.** Supply `shaderpackage005.sdp`. That one file is sufficient — tested
individually: `008` alone still crashes, `005` alone runs. Genuine copies are not
available from the media here (the GOG-labelled ISO in `~/Games/installers` is the
same repack, with the files stripped from its compressed payload), so the working
file is a **copy of `shaderpackage006.sdp` renamed**, which is the long-standing
community workaround for cards that land on these paths:

```
cd ".../Fallout 3 Game of the Year Edition/Data/Shaders"
cp shaderpackage006.sdp shaderpackage005.sdp
```

With it in place the game reaches its main menu and renders correctly.
`Data/Shaders/_ember-test-copies.txt` on the box records which files are copies,
because a renamed shader package is not visibly different from a real one.

⚠ If a complete copy of the game ever turns up, replace the stand-in with the real
`shaderpackage005.sdp`. The shaders in `006` are for a different path, and only the
menu and early frames have been checked.

⛔ These were ruled out by measurement before the shader packages were found, and
none of them is the cause: audio (DirectSound initialises and mixes normally),
`d3dx9_38` (Wine's builtin loads and logs no failure), the `xlive` GFWL stub (loads
as native), the threading keys `bUseThreadedAI` / `iNumHWThreads` (already correct),
and the ini as a whole (freshly generated inis crash identically).

## Doom 3

**Doom 3 BFG Edition cannot run on this hardware at all.** Its executable refuses
to start without `GL_ARB_uniform_buffer_object`, which arrived with the GeForce 8;
a 7600 exposes `ARB_map_buffer_range` and `ARB_vertex_array_object` but not that.
This is a hardware wall, not a Wine or driver setting.

**The original Doom 3 runs natively instead**, through `dhewm3`, which is in
`oldgames.pkgs`. It needs `base/pak000.pk4` through `pak008.pk4`; a CD install
provides only `pak000`-`pak004`, and `pak005`-`pak008` come from id's freely
distributed Linux 1.3.1 patch:

```
sh doom3-linux-1.3.1.1304.x86.run --tar xf --wildcards 'base/pak*'
dhewm3 +set fs_basepath /path/containing/base
```

Keeping dhewm3's `base/` separate — symlinks to the existing `pak000`-`pak004`
plus the four patch files — costs no disk and leaves a Windows install of the same
game working, which adding 1.3.1 files to its own `base/` would not.

## Multi-disc installers: the drive letter, not the disc

udisks mounts each disc at a path named after its label, so Wine gives every disc
its **own** drive letter:

```
F: -> /run/media/<user>/DOOM3_1
G: -> /run/media/<user>/DOOM3_2
```

An installer started from F: keeps asking F: for disc 2 and keeps finding disc 1,
and unmounting and remounting changes nothing, because disc 1 returns to the same
path. Repoint the letter the installer is watching:

```
ln -sfn /run/media/<user>/DOOM3_2 ~/.wine/dosdevices/f:
```

## Stardew Valley 1.6.8 will not run

The exe is 64-bit. A 32-bit Wine prefix on an i686 host cannot load it under any
configuration. The last 32-bit Windows build was 1.5.6.

## A game that changes resolution can leave the desktop at 640x480

Wine restores the mode when a game exits cleanly, but not when it is killed, and
`xrandr -s 1280x1024` then answers "Size not found in available modes" because it
takes screen sizes rather than that output's modes. The connected output on the
reference machine is `DVI-I-1`:

```
xrandr --output DVI-I-1 --mode 1280x1024 --rate 60.02
```

Any script that launches Wine games unattended should restore the mode this way.
