# PPU campaign results (modes 0-4 palette + priority)

Outcome: 380/380 exact Mesen RGB15 cases pass, up from the 305/380
baseline. All four behavioral targets were accepted by the campaign
controller's own check + checkpoint (frozen-file guard, all 380
comparisons, preservation cases, unit tests, whitespace).

## Commit-to-task mapping

The work does not map one-commit-per-task; it was split by mechanism:

- `c8487cf` - task 1 (Mode 0 CGRAM palette banks, both screens).
- `21537ec` - tasks 2 AND 3 together: the rank-based composition rewrite
  covers Mode 0 BG/OBJ ordering on both screens (task 2) and, through the
  same `spritePriorityWins` tables, Modes 2-4 main-screen OBJ priority
  (task 3). The checkpoint 2 run already showed modes 2-4-main at
  31/31 (377/380 overall).
- `1997753` + `5d71099` - task 4 spread over two commits: Mode 1/9
  subscreen BG priority (including $2105 bit 3 promotion) first, then
  Modes 2-6 subscreen. Both were required for the 77 non-Mode-0
  subscreen cases.
- `21f1ebc` - results doc (this file).

## Measured compatibility

The acceptance surface is the 4x4 interior patch of solid 8x8 tiles
over two settled frames, compared with zero RGB tolerance against
local Mesen 3b058f9. This is palette/priority coverage for modes 0-4,
not full-frame, timing, or Modes 5-7 accuracy - see the limitations
below.

## Mechanisms

1. **Mode 0 CGRAM banking.** Each Mode 0 layer owns a 32-entry CGRAM
   slice (BG1 0-31, BG2 32-63, BG3 64-95, BG4 96-127). A tilemap
   palette field on BG2 indexes colors 32 + palette*4 + index, not
   palette*4 + index. Implemented in both `renderBgLine` and the
   `renderBgPixel` reference, gated on BGMODE bits 0-2 clear paired
   with 2bpp depth.

2. **Absolute per-mode priority ranks.** The tilemap priority bit is
   not a z value; each mode assigns (layer, bit-pair) absolute ranks
   (Mesen SnesPpu.cpp RenderModeN):
   - Mode 0: BG4 1/4, BG3 2/5, BG2 7/10, BG1 8/11; OBJ 3/6/9/12.
     So BG2 HIGH (10) covers BG1 LOW (8).
   - Mode 1: BG3 1/3, BG2 5/8, BG1 6/9; OBJ 2/4/7/10; $2105 bit 3
     promotes BG3 high-priority tiles to 11 (ahead of every BG/OBJ
     level).
   - Modes 2-5: BG2 1/5, BG1 3/7; OBJ 2/4/6/8.
   Each screen keeps the pixel with the strictly greatest rank; equal
   ranks keep the already-drawn (more backward) pixel. Implemented as
   layer-ID walks with rank compares in `renderScanlineRange`, rank
   compares in `renderSubscreenPixel` (TS-driven), and rank tables in
   `spritePriorityWins`, with `bg_tile_prio` threading the winning
   pixel's tile bit into the OBJ comparison separately from the
   composite rank.

3. **Subscreen ordering.** `renderSubscreenPixel` previously took the
   last-drawn opaque layer; it now applies the same rank tables so
   "add subscreen" color math blends the ordered pixel.

## Known limitations (documented, not fixed here)

- **Mode 6 priority.** Mesen RenderMode6 uses BG1 1/5 with OBJ ranks
  2/3/4/6 - not the modes 2-5 table. The modes 2-6 arms
  (`spritePriorityWins` else-branch, and both composite blocks)
  implement only the modes 2-5 tables; Mode 6's OBJ0-vs-BG1L tie-break
  is therefore wrong and predates this campaign. Mode 6 was outside
  the campaign scope (no atlas cases) and was deliberately not
  broadened in this work.
- Mode 5 is hires/interlace-free lo-res here, Mode 7 uses its own
  per-pixel path; neither is exercised by these tests.
- Subscreen OBJ are not implemented (tracked on a separate branch).

## Regression tests

- Pre-campaign: "renderBgLine matches renderBgPixel reference",
  "Mode 1 BG3 priority bit puts BG3 high ahead of BG1 BG2 and OBJ3",
  "lower OAM index wins overlapping OBJ pixels".
- **Palette closeout:** "Mode 0 reserves a 32-color CGRAM bank per
  background layer".
- **Priority closeout:** "Mode 0 OBJ priority beats BG by rank not
  tile bit"; "Mode 1 BG low sits behind BG2 high and modes 2-4 OBJ
  use 2/4/6/8"; "subscreen BG priority drives color math on modes
  1-4" (subscreen color-math composition with losing/backdrop
  controls). Old-code-fails evidence for these groups:
  `.zig-cache/ppu-closeout-evidence/`.

## Evidence

Controller runs under the project-local campaign reports folder
(runs/20260920T*-*/), raw comparisons in fresh
.zig-cache/ppu-campaign/run-*/result.json per invocation.
