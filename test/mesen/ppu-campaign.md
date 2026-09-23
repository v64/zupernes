# PPU comparison campaign

This campaign targets general palette selection and layer composition in modes
0–4. It changes neither CPU scheduling nor the canonical oracle checkout.
The branch starts at a51c724; the concurrent direct-page CPU experiment remains
separate and is not a prerequisite for these native-mode ROMs.

## Fast check

```
node test/mesen/ppu_campaign.mjs check all
node test/mesen/ppu_campaign.mjs check mode0-main
```

The full warm check takes approximately 2.5 seconds. It builds the headless
runner, generates original LoROMs, checks their completion marker, captures two
settled frames, and compares exact RGB15 values against frozen Mesen references.
A selector is one of mode0/1/9/2/3/4 followed by -main or -sub. Mode9 means
Mode 1 with the BG3 priority bit set, not a ninth graphics mode.

The baseline has 305/380 passing cases. Every result, including known failures,
is retained in fresh `.zig-cache/ppu-campaign/run-*/result.json` files. Overall
exit 1 means comparison failures; a runner/build error also exits nonzero and
must not be confused with valid comparison evidence.

## Tasks, in order

1. **Mode 0 palette selection.** Each background's Mode 0 palette bank must
   contribute to the CGRAM address. Audit the line renderer and the per-pixel
   renderer; keep their semantics equivalent. Require all 24 palette cells
   across mode0-main and mode0-sub. Preserve other modes' palette behavior.
2. **Mode 0 priority.** Correct BG-vs-BG selection on main and sub screens and
   main-screen OBJ-vs-BG ordering. Require all 110 Mode 0 cases. Depends on #1.
3. **Modes 2–4 main-screen OBJ priority.** Correct layer-specific priority
   ordering. Require all 93 cases across mode2/3/4-main. Preserve Mode 1 and
   its BG3-priority variant (already 100/100 on the main screen).
4. **Modes 1–4 subscreen BG priority.** Respect tile and layer ordering,
   including Mode 1 BG3 promotion. Require all 77 non-Mode-0 subscreen cases.
   Combined with the earlier milestones, final success is 380/380.

Scope includes source-derived regression tests with different colors or tile
configurations from the supplied atlas. One coherent commit per completed task.
No game-dependent branches or constants, PPU timing rewrite, hires/interlace,
offset-per-tile implementation, Mode 7/EXTBG work, window redesign, or new
subscreen OBJ implementation. A separate existing `subscreen-obj` branch holds
work on that last topic; do not duplicate or merge it in this campaign.

## Evidence and limits

The ROMs program every tilemap/CHR/CGRAM/OAM region used by their cases, disable
interrupts and HDMA, force blank during setup, then latch a completion marker
and loop. All inputs are original generated data. The atlas contains explicit
transparent, single-BG, and OBJ-only controls so invisible/misconfigured layers
cannot make a priority comparison pass accidentally. The setup reviewer checked
all 380 Mesen result patches against the priority tables and programmed colors,
not merely against another saved output.

Each case compares a 4x4 interior patch of a solid 8x8 tile. This deliberate
scope isolates palette/priority from tile-edge geometry and scanline timing.
Pixels outside those declared patches are not an acceptance surface; this is
not a full-frame or timing-accuracy claim. There is no RGB tolerance. Each
selected patch must be stable across two completed frames; two engines may
finish setup at different times, but they must both reach the latched steady
state before their results are compared.

Subscreen cases use black main backdrop plus full-intensity addition of the
subscreen to expose its selected BG color without saturation. They do not test
subscreen sprites or general color-math arithmetic. Main-screen OBJ cases stay
below sprite/scanline limits and use distinct, explicitly populated OBJ colors.
Modes 2/4 have zero offset-per-tile data. Modes 5–7 are intentionally outside
this campaign, rather than silently approximated.

The reference is certified local Mesen `atomic-snapshot` at
3b058f9fbf6f446028eab3a83c5a3db35b1b960a. Source and executable provenance are
in `fixtures/ppu-campaign.json`. Captures came from an isolated portable app;
RAM initialization is AllZeros and the canonical app was not modified.
The repository guard and sandbox helper beside the generator were reused from
ZuperWorld's existing tooling, so iteration does not depend on its project.

Primary source for these cases:
`/Users/v64/Repos/mesen-src/Core/SNES/SnesPpu.cpp`, RenderMode0 through
RenderMode4 (approximately lines 790–835), plus RenderTilemap's palette-offset
parameter and sprite priority handling. Source tables are evidence; implement
ZuperNES-native composition rather than importing another emulator's code.

Relevant ZuperNES locations are all in `src/ppu/ppu.zig`:
`spritePriorityWins`, `mode1BgPixelWins`, `renderScanlineRange`, `renderBgLine`,
`renderBgPixel`, and `renderSubscreenPixel`. Read those bounded sections, not
repeated full-file dumps. The existing line-vs-pixel renderer equivalence tests
are especially useful for task 1.

During task 1, Mode 0 priority cells remain unfinished: correcting a palette
can expose an already-wrong layer that previously produced the same color.
The milestone checker explicitly defers that group until task 2; it still
reports every result and requires the complete group at task 2 and completion.
All baseline-passing cases outside that one deferred group are preservation
requirements, as are the acceptance cases of every completed milestone.
