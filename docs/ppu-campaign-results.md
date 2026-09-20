# PPU campaign results (modes 0-4 palette + priority)

Outcome: 380/380 exact Mesen RGB15 cases pass, up from the 305/380
baseline. Four commits, one per task, each accepted by the campaign
controller's own check + checkpoint (frozen-file guard, all 380
comparisons, preservation cases, unit tests, whitespace).

## Measured compatibility

The acceptance surface is the 4x4 interior patch of solid 8x8 tiles
across two settled frames, compared with zero RGB tolerance against
local Mesen atomic-snapshot 3b058f9. This is layer-composition
coverage, not a full-frame or physical-hardware claim: tile-edge
geometry, scanline timing, mosaic, windows, hires/interlace,
offset-per-tile, Mode 7/EXTBG and subscreen OBJ stay outside it.

## Root mechanisms found

1. **Mode 0 CGRAM banking.** Each Mode 0 layer owns a 32-entry CGRAM
   slice (BG1 0-31, BG2 32-63, BG3 64-95, BG4 96-127). The renderers
   indexed everything from 0, so every BG2/3/4 tile used the wrong
   palette cells. Fixed in both renderBgLine() and the renderBgPixel()
   reference, gated on the Mode 0 signature (BGMODE bits 0-2 clear)
   paired with 2bpp depth.

2. **Absolute per-mode priority ranks.** The tilemap priority bit is
   not a z value, and per-branch OBJ guesses diverge per mode. The
   hardware tables (Mesen RenderModeN) are:
   - Mode 0: BG4 1/4, BG3 2/5, BG2 7/10, BG1 8/11; OBJ 3/6/9/12.
   - Mode 1: BG3 1/3, BG2 5/8, BG1 6/9; OBJ 2/4/7/10; $2105 bit 3
     promotes BG3 high-priority tiles to 11 (ahead of every BG and
     OBJ level).
   - Modes 2-6: BG2 1/5, BG1 3/7; OBJ 2/4/6/8.
   Each screen keeps the pixel with the strictly greatest rank; equal
   ranks keep the already-drawn (more backward) pixel. Implemented as
   front-to-back walks in renderScanlineRange() and rank compares in
   renderSubscreenPixel() (TS-driven), with bg_tile_prio threaded
   separately into spritePriorityWins() so the OBJ side compares the
   tile bit, not the composite rank.

3. **Subscreen ordering.** renderSubscreenPixel() previously took the
   last-drawn opaque layer per mode; it now applies the same rank
   tables, so "add subscreen" color math blends the ordered pixel.

## Regression tests added

- "Mode 0 reserves a 32-color CGRAM bank per background layer":
  differently-colored same-index cells per layer, non-default
  CHR banks/tilemaps, per-layer TM isolation, line-vs-pixel
  cross-check, and a Mode 1 no-bank tail with palette 7.
- Pre-existing equivalence/OBJ/Mode-1-promotion tests continue to
  pin the rewritten paths.

## Evidence

Controller runs under the project-local campaign reports folder
(runs/20260920T*-*/), raw comparisons in fresh
.zig-cache/ppu-campaign/run-*/result.json per invocation.
