# Optimization Notes

Running list of performance opportunities noticed during development.
The goal is cycle accuracy with pixel-perfect output, which costs speed —
so wasted work needs to be reclaimed everywhere else. None of these should
change observable behavior; each is a pure speed win to bank when needed.

## PPU

### `tick()` iterates one master cycle at a time (ppu.zig)
`while (remaining > 0) { remaining -= 1; self.dot += 1; ... }` burns a loop
iteration per master cycle (~5.4M/frame) just to count dots. Advance `dot`
arithmetically: `dot += cycles`, then handle scanline crossings in a small
loop (at most 2 iterations for any realistic instruction length). When we
move to dot-accurate rendering this loop gets real work per dot, so the
cheap version matters even more as the baseline.

### Per-pixel tile refetch in `renderBgPixel()` (DONE - 30% whole-emulator win)
Every screen pixel re-read scroll registers, recomputed the tilemap
address, refetched the tilemap entry, and re-decoded CHR bitplanes - even
though 8 consecutive pixels share one tile. Fixed with the line-buffer
renderer (`renderBgLine` in ppu.zig): each BG enabled on main OR sub
screen renders once per scanline into a `BgLine` buffer, walking the line
in 8-pixel tile runs - one tilemap fetch and one `decodeTileRow` (via the
comptime PLANE_SPREAD table) per run. Compositing then just reads buffers,
and the subscreen shares them (it shows the same layers, selected by TS).

**Measured (SMW, 2000 frames, ReleaseFast): 4.05s -> 2.82s, a 30% speedup
of the ENTIRE emulator** - CPU/APU/DSP included, so the PPU render path
itself shrank several-fold. Verified byte-identical over 57 captures
(SMW title->overworld->level, All-Stars into SMB1, both Mode 7 ROMs), and
a property test pins `renderBgLine` to the retained per-pixel reference
implementation (`renderBgPixel`) over randomized VRAM/register state.

Still per-pixel and worth revisiting later: sprite tile fetches in
`renderSprites` (already line-buffered, but calls getTilePixel per pixel),
and Mode 7 (inherently per-pixel - affine - but the two VRAM byte reads
per pixel could skip the tilemap re-read when u/v stays in one tile).

### Per-pixel layer dispatch in `renderScanline()` (ppu.zig)
The mode switch, TM tests, and window mask checks run per pixel. All of
these are constant across a scanline (windows change per pixel only in
value, not configuration). Hoist configuration out of the pixel loop;
precompute window intervals per scanline (the window is just 1-2 spans —
resolve to a per-line boolean array or span list once).

### Brightness scaling division (DONE - measured neutral)
`(component * brightness) / 15` per channel per pixel, replaced with the
comptime-generated `BRIGHTNESS_LUT` in ppu.zig (row hoisted per scanline,
branch-free pixel write). Also `getTilePixel` bitplane extraction now goes
through the comptime `PLANE_SPREAD` table.

**Measured result (SMW, 2000 frames, ReleaseFast, M-series): 4.0s before,
4.0s after — no change.** Two lessons worth recording:
1. LLVM already strength-reduces division by a *constant* (`/15`) into a
   multiply-shift at ReleaseFast, so the divides we "eliminated" were
   never real divides in the optimized binary. Constant divisors are cheap;
   only *variable* divisors deserve LUT treatment on speed grounds.
2. The render loop's time is dominated by the per-pixel tile refetch item
   above, so nothing downstream of it can move the total. That item is
   THE next performance lever for the PPU.
The LUT versions are kept anyway: output is proven byte-identical, the
code is branch-free and simpler, and `PLANE_SPREAD` is the building block
the line-buffer renderer needs (it yields all 8 pixels of a plane-pair row
in one lookup pair - decode-per-row instead of decode-per-pixel).

## Frontend

### Framebuffer conversion loop (main.zig `frame()`)
Converts 57K pixels BGR555 -> RGBA8 on the CPU every frame. Either upload
the raw 16-bit buffer as an R16UI texture and decode in the fragment
shader, or at least build a 32K-entry u16 -> u32 lookup table (fits in L1
half the time) instead of per-channel shifts.

## Bus / CPU

### DMA consumes zero emulated time (bus.zig `writeSystemRegister` $420B)
`runDma` returns a cycle count but the caller discards it, so the PPU/APU
don't advance during transfers. This is an *accuracy* bug that also skews
any future cycle-budget scheduling: a 64KB DMA takes ~8 master cycles/byte
(~0.5M cycles) during which NMI/IRQ/HDMA timing shifts. Plumb the returned
cycles into the main step loop when doing the timing rework.

### Bus `read()`/`write()` cascade of range compares (bus.zig)
Every memory access walks an if/else chain. A 256-entry bank descriptor
table (kind: wram / rom / mmio / sram) collapses most accesses to one
indexed branch. Do this after the memory map is feature-complete (HiROM,
open bus) so the table encodes the final truth.

### `step()` scanline-transition detection (root.zig)
Compares `prev_scanline != scanline` after every instruction — fine now,
but once PPU tick is cheap, consider having the PPU return events (or
expose next-event distance) so the emulator can run the CPU in larger
batches between PPU-visible events. This is the standard
"catch-up/scheduler" architecture and is the single biggest structural
speed lever available while keeping cycle accuracy.

## General

- Debug traces are comptime-gated (good - keep it that way; never replace
  with runtime flags on hot paths).
- Build releases with `-Doptimize=ReleaseFast` for play; keep ReleaseSafe
  for regression runs so index/overflow bugs still trap.
