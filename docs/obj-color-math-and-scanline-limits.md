# OBJ color math (palettes 4–7) and OBJ per-scanline limits

Independent hardware evidence for two landed PPU corrections:

- `00ff2ed` — *ppu: count OBJ scanline limits by sprites and tiles*
- `9fcf2ee` — *ppu: gate OBJ color math to palettes 4 through 7*

Both commits originally shipped with only "zig build test passes". Under the
oracle-motion rule (a ZuperNES change that can alter observable output must
carry hardware references plus a Mesen2 reproduction of the changed observable,
never agreement with a downstream port), this note records those two
independent surfaces. It is append-only: the two commits above are already
consumed by SHA in downstream history and are **not** amended.

Oracle used: Mesen2 at `~/Repos/Mesen2/Mesen.app`, headless
`--testrunner <rom> <lua>`. SMW USA ROM used only as a live PPU vehicle for the
color-math scene; the scanline-limit reproduction is ROM-content-independent
(it drives the PPU's OBJ evaluation directly through OAM). Mesen2 exposes the
PPU state to Lua via `emu.getState()` (flat keys, e.g. `st["ppu.rangeOver"]`,
`st["ppu.timeOver"]`, `st["ppu.colorMathEnabled"]`), the rendered framebuffer
via `emu.getPixel(x,y)` (`0x00RRGGBB`), and OAM/CGRAM via
`emu.read(addr, emu.memType.snesSpriteRam|snesCgRam, false)`.

---

## 1. OBJ per-scanline limits — `00ff2ed`

### Hardware reference (fullsnes, problemkaputt.de)

`STAT77` (`$213Eh`) reports two OBJ overflow flags, cleared at V-Blank end
(not during forced blank):

- bit 6 — "OBJ Range overflow (0=Okay, 1=More than 32 OBJs per scanline)"
- bit 7 — "OBJ Time overflow (0=Okay, 1=More than 8x34 OBJ pixels per scanline)"

`8x34` = 34 eight-pixel tiles = 272 pixels. On range overflow the lower-indexed
OAM sprites win and higher-indexed ones are dropped; on time overflow the last
sprite that crosses the 34-tile budget is rendered partially/incompletely.
These are exactly the budgets `00ff2ed` installs, replacing the accidental
256-opaque-pixel cutoff: `if (sprites_on_line == 32) break;` and
`tiles_to_render = @min(sprite_tiles, 34 - tiles_on_line)`.

### Mesen2 reproduction (synthetic, ROM-content-independent)

Test sprites are written directly into OAM (`snesSpriteRam`) on one scanline;
all unused sprites are parked fully off-screen (Y=240, no wrap) so only the test
line drives the flags. Reading `st["ppu.rangeOver"]` / `st["ppu.timeOver"]` at
`endFrame`:

| setup                                   | tiles | rangeOver | timeOver |
|-----------------------------------------|-------|-----------|----------|
| baseline (parked only)                  | 0     | false     | false    |
| 32 × 8×8 on one line                    | 32    | **false** | false    |
| 33 × 8×8 on one line                    | 33    | **true**  | false    |
| 17 × 16×16 on one line                  | 34    | false     | **false**|
| 18 × 16×16 on one line                  | 36    | false     | **true** |
| 1 × 8×8 + 17 × 16×16 (straddle)         | 35    | false     | **true** |

- **Range over** flips true at exactly the 33rd sprite (> 32), matching STAT77
  bit 6 and the commit's 32-sprite cap.
- **Time over** flips true only past 34 tiles (34 → false, 36 → true), matching
  STAT77 bit 7 and the commit's 34-tile cap.
- The **35-tile straddle** (one 8×8 then 17 × 16×16: cumulative tile 34 is the
  first tile of the 18th sprite and fits, tile 35 is its second tile and does
  not) sets time-over — the "last sprite rendered partially" case fullsnes
  describes and the commit implements via `@min(sprite_tiles, 34 - tiles_on_line)`.
- With 40 × 8×8 on a line, range-over engages first (32-sprite cap → 32 tiles),
  so time-over stays false — the correct hardware ordering (range limits the
  sprite set before the tile budget is reached).

Note: no scene in the SMW attract demo (~2400 frames) or the full
`yi1-bonus-game.zmov` (10714 frames) trips either flag — SMW stays under budget
in normal play. The commit's real defect was the *old* engine wrongly dropping
under-budget cells (SMW's isolated Big Boo composite) via the 256-opaque-pixel
cap; the correct 34-tile budget leaves that composite intact. The synthetic
test above verifies the budgets themselves against the independent oracle.

---

## 2. OBJ color math gated to palettes 4–7 — `9fcf2ee`

### Hardware reference (fullsnes, problemkaputt.de)

`CGADSUB` (`$2131h`) documents the OBJ color-math designation as two distinct
cases:

- "Color Math when Main Screen = OBJ/Palette4..7 (0=Off, 1=On)"
- "Color Math when Main Screen = OBJ/Palette0..3 (Always=Off)"

That is: the `$2131` OBJ bit (bit 4) only ever enables color math for sprite
palettes 4–7; OBJ palettes 0–3 are permanently excluded from color math. This
is exactly what `9fcf2ee` installs: it tracks the winning OBJ pixel's CGRAM
palette row and allows the CGADSUB OBJ designation only for rows 12–15
(OBJ palettes 4–7): `obj_math_eligible = sprite.palette >= 12`.

### Mesen2 reproduction (bypass side, live SMW overworld)

The SMW overworld renders with color math designating OBJ and backdrop and
adding the BG2 subscreen — read from Mesen2 as `colorMathEnabled = 0x30`
(bit 4 OBJ + bit 5 backdrop), `colorMathAddSubscreen = true`,
`mainScreenLayers = 0x15` (BG1+BG3+OBJ), `subScreenLayers = 0x02` (BG2).
Every OBJ present on the overworld uses palette 0–3 (measured palette
histogram at the Yoshi's-House map frame: pal0×5, pal2×4, pal3×16, pal4..7×0).

Setting OBJ palette 0's CGRAM to magenta `0x7C1F` (BGR555 = R31,G0,B31) and
reading the rendered player-marker pixels (`emu.getPixel`): **all 140 marker
pixels render exactly `0xFF00FF`** — the raw palette color with zero subscreen
addition, despite CGADSUB designating OBJ (bit 4 set) and add-subscreen being
active. A non-gated OBJ pixel under add-subscreen math would carry the BG2
contribution; palette 0 does not. This is the "OBJ/Palette0..3 (Always=Off)"
rule holding in the independent oracle. (The overworld marker being a palette
0–3 OBJ is precisely why the gate matters: before `9fcf2ee` the engine
color-mathed it; hardware and Mesen2 do not.)

### Named limitation

The positive side ("OBJ/Palette4..7 = On") is fullsnes-explicit but is **not**
reproduced in the same headless capture: no scene in the available SMW movie
corpus renders a palette 4–7 OBJ under OBJ-designated color math (SMW's
overworld OBJs are all palette 0–3), and OAM sprites injected via Lua in
`--testrunner` affect Mesen2's range/time-over *evaluation* but do not render
pixels, so a synthetic palette-4-7 blend cannot be observed headlessly. The
palette-4-7 blend is covered by the fullsnes citation above and is exercised
downstream by the seeded Big Boo (OBJ palette 6, CGADSUB $34) scenario.
