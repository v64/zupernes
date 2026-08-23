# Subscreen OBJ rendering

Commit `13d28e9` extends the scanline renderer's shared line-buffer path to
OBJ selected only on the subscreen. This closes the castle-entrance composite
gap recorded in ZuperWorld's `docs/castle-entrance-spec.md`: the entrance uses
`TM=$04`, `TS=$13`, and `CGADSUB=$20`, so BG1, BG2, and OBJ must be composed as
the color-math operand behind main-screen BG3/backdrop.

## Hardware contract

- [Anomie's Register Doc](https://github.com/gilligan/snesdev/blob/master/docs/snes_registers.txt)
  gives `TM`/`TS` the same `---o4321` layout: bit 4 enables OBJ and bits 0-3
  enable BG1-BG4 on the main or sub screen. It separately gives `TMW`/`TSW`
  that layout for per-screen window masking. A `TMW` OBJ mask therefore cannot
  suppress a TS-selected OBJ; `TSW` bit 4 owns that decision.
- [fullsnes: PPU control](https://problemkaputt.de/fullsnes.htm#snesppucontrol)
  likewise defines `$212C/$212D` bit 4 as OBJ enable and describes the
  subscreen as the color-math screen.
- [fullsnes: PPU color math](https://problemkaputt.de/fullsnes.htm#snesppucolormath)
  says main/sub BG and OBJ are selected by `$212C/$212D`, independently
  window-disabled by `$212E/$212F`, and resolved to each screen's frontmost
  non-transparent pixel. `CGWSEL` bit 1 selects that BG/OBJ subscreen result as
  the second operand. `CGADSUB` bits 0-5 designate which winning **main-screen**
  layers receive math.
- The same fullsnes color-math table limits main-screen OBJ math eligibility to
  OBJ palettes 4-7; palettes 0-3 always show raw when OBJ wins the main screen.
  This restriction does not remove a palette 0-3 OBJ from the composed
  subscreen. The castle gate uses palette 0 and must still be the second
  operand.

The implementation consequently builds one physical OBJ line whenever either
`TM.OBJ` or `TS.OBJ` is set. Main and sub compositors then independently apply
their enable and window bits, use the existing BG/OBJ priority function, and
retain the palette 4-7 gate only when OBJ is the main-screen source selected by
`CGADSUB`.

## Focused test

`zig build test` includes `TS OBJ is composited as the color-math operand and
obeys TSW`. It constructs the real castle register scene (`TM=$04`, `TS=$13`,
`CGADSUB=$20`, `CGWSEL=$02`) with transparent BG1-BG3 and one palette-0 OBJ.
The assertions distinguish three cases:

1. `TMW.OBJ=1`, `TSW.OBJ=0`: the sprite remains the subscreen operand, proving
   that main-screen window designation does not leak across screens.
2. `TSW.OBJ=1` inside window 1: the sprite is transparent there and color math
   falls back to `COLDATA`.
3. Outside that window: the palette-0 sprite remains the subscreen operand,
   proving the main-screen palette 4-7 eligibility rule was not misapplied.

## Staged validation (2026-08-23)

Baseline is `4c877ff`; implementation is `13d28e9`. All screenshots were made
with ReleaseFast builds.

- `zig build test`: pass after implementation.
- All 29 ROMs in `test/snes-test-roms` ran for 120 frames before and after;
  **0 screenshots changed**. These are HDMA/INIDISP/DMA timing ROMs and none of
  their captured fields selects OBJ on the subscreen, so neutrality is the
  expected result. The focused unit scene and castle capture provide the
  positive coverage the timing corpus cannot.
- The 2,900-frame SMW run with the seven inputs in `NEXTSTEPS.md` is
  byte-identical before/after:
  - WRAM SHA-256:
    `597aaad6015ea9272111a836bc023ac3d21d59daa0a3c6584a9f5806c29426a6`
  - screenshot SHA-256:
    `ce5a479e62feb4c3017bd21620b2cab681f21adeaaef90abc15f29d19e831e2d`

That SMW path has `TS.OBJ` off, so any movement would have meant the shared OBJ
line changed ordinary main-screen rendering; none occurred.

### Castle-entrance composite

The on-foot power-on movie is
`/Users/v64/Repos/zuperworld/test/movies/iggy-castle-entrance-on-foot.zmov`.
ZuperNES captures were aligned by the scenario's source-frame mapping against
ZuperWorld engine revision `8ff8ec06`. Engine RGB15 checkpoints were converted
directly against the PPM's reversible 5-bit channels (`R/G/B >> 3`); the
playfield comparison excludes only rows 0-31, the status bar.

| ROM source frame | scenario checkpoint | pixels restored vs `4c877ff` | restored bbox | new vs engine playfield | full-frame residual |
| ---: | ---: | ---: | --- | ---: | --- |
| 18580 | 222 | 1,790 | `(170,145)-(231,207)` | **0** | 182 HUD pixels, `(99,17)-(175,31)` |
| 18628 | 270 | 584 | `(170,146)-(231,207)` | **0** | 185 HUD pixels, `(99,17)-(175,31)` |

At frame 18580 the restored rectangle visibly contains Mario at the gate and
the twelve-tile portcullis. By frame 18628 the gate has risen behind the
high-priority castle facade, so fewer OBJ pixels remain visible. The old
renderer produced the same frozen background hash at both fields; the new
renderer changes with the OAM state and is pixel-identical to ZuperWorld over
the entire castle playfield. The remaining HUD-only difference is outside the
field and predates this PPU change.
