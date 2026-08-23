# Pin-candidate corpus regression triage

This document records evidence only. It does not advance a pin or propose an
emulator fix.

## Scope and provenance

The candidate under test is `52f4b812fcb706ed669739d7eb7da3340c5314d0`
on `pin-candidate`. The live baseline is
`9b5270ca3498a92ac082ed820510f87e91ecc42b`. The regression set below is copied
verbatim from `docs/pin-candidate-evidence.md`:

1. `chocolate-island-4-carrot-top-lift`
2. `dark-room-back-door-switch`
3. `foi1-exploding-block-seeded`
4. `foi1-goomba-carry-pose`
5. `gameplay-foi1-wiggler`
6. `gameplay-yellow-switch-palace-natural`
7. `gameplay-yi1-goal`
8. `gameplay-yi4-entry`
9. `gameplay-yoshi-mounted-goal`
10. `gameplay-yoshis-house`
11. `loader-equivalent-ci4-entry`
12. `overworld-clear-reveal`
13. `overworld-switch-palace-beat`
14. `overworld-yi1-to-ysp-pan`
15. `regression-chuck-head-flip`
16. `roys-castle-creating-eating-block`
17. `vanilla-fortress-ball-chain-swing`
18. `vanilla-fortress-roster`
19. `wall-follow-urchin-seeded`

The three requested representatives exercise different anchor classes:

| scenario | anchor recorded under the live pin |
| --- | --- |
| `gameplay-yi1-goal` | natural power-on movie, source/movie offset 5594 |
| `overworld-clear-reveal` | natural power-on movie after the YI1 goal, source/movie offset 6267 |
| `foi1-exploding-block-seeded` | source frame 400, loader epoch at first mode-$14 source frame 362, plus measured player/RNG seed |

## Load-cadence measurement

Both revisions replayed the same `yi1-overworld-reveal.zmov` from power-on in
the headless runner. A temporary diagnostic sampled physical WRAM `$7E:0100`
after every completed video frame. The diagnostic was not retained in either
source tree. The result was repeated both with a ReleaseFast emulator core and
with the core's default optimization used by the fidelity build. Here, "frame
index" is zero-based and "frames from power-on" is the number of calls to
`runFrame` which have completed when the new mode is first observable.

| milestone | live `9b5270c` | candidate `52f4b81` | candidate minus live |
| --- | ---: | ---: | ---: |
| first file-select mode `$08` | index 701 / 702 completed | index 701 / 702 completed | **0 frames** |
| first gameplay mode `$14` | index 1025 / 1026 completed | index 1025 / 1026 completed | **0 frames** |

Every `$0100` transition from power-on through that first `$14` is at the same
frame on the two builds. Thus the proposed 14--26-frame-per-load cadence shift
does **not** occur at either requested boot/load milestone and cannot explain a
corpus-wide constant re-anchoring requirement.

The same ReleaseFast trace does find a later, transition-local difference: after the second
entry to mode `$14` at index 2705 on both builds, the live build leaves `$14`
for `$0C` after frame 6172 (6173 completed), while the candidate leaves after
frame 6179 (6180 completed). The candidate therefore remains in the YI1
gameplay/goal sequence **7 frames longer**; subsequent `$0C->$0D->$0E`
transitions retain the same +7 displacement. This is not boot-prefix
consumption and points the representative analysis at the goal/exit transition
itself.

## Representative first-divergence analysis

The exact candidate bundles were regenerated with ZuperNES `52f4b812` and the
evidence-flight ZuperWorld tree `075584380`. The original evidence run used
ZuperNES `7615d782`; only evidence documents differ between that revision and
`52f4b812`, so the emulator tree is the same. The retained bundles were then
walked frame by frame. "Aligned" below means every non-excluded state field in
the scenario, not merely the field which made the comparator stop.

### `gameplay-yi1-goal`: REAL behavior change

Candidate and engine are exact at the declared state surface for scenario
frames 0--504. The first divergence is frame 505 / source 6099:

| field | candidate oracle | engine/live behavior |
| --- | ---: | ---: |
| `effective_frame` | 239 | 240 |
| `logic_frame` | 227 | 228 |
| `goal.end_timer` | 4 | 3 |
| `goal.wipe` | 236 | 232 |

This is not fixed by moving the 5594 anchor. The exact alignment required
during the wipe grows over time: candidate `+1` matches engine frames 504--507,
then `+2` matches 507--510, `+3` matches 510--513, `+4` matches 513--519,
`+5` matches 519--522, `+6` matches 522--526, and `+7` matches 526--572. At
frame 579 the candidate is still in mode `$14` while the engine/live sequence
has reached `$0C`. A single re-derived movie offset therefore cannot make the
row pass; the goal/wipe schedule itself has changed.

In the fidelity build, `189a823` first makes this row red only at the later
frame-531 iris pixel; `60daac8` moves the first divergence to frame 505 with
the exact counter/end-timer/wipe tuple above. In a standalone all-ReleaseFast
build the stage result is layout-sensitive: `189a823`, `60daac8`, `4c877ff`,
and the BG3 parent `be488ef` all leave mode `$14` at frame 6172, while the
merged tree `1e38c6b` leaves it at 6179. Neither merge parent alone produces
the +7 result. This triage does not infer a cause from that optimization/merge
interaction; it records that the observable change is real and not an anchor.

### `overworld-clear-reveal`: REAL behavior change with inherited drift

The first divergence is frame 0 / source 6267. The candidate is still in mode
`$0D`, with logic/effective clocks 56/42 and event state 0; the engine/live
sequence is already in mode `$0E`, at clocks 63/44 and event state 2. The
initial displacement is inherited directly from the preceding goal: moving
the candidate by +7 makes every declared state field exact for engine frames
0--30.

That offset does not remain constant. Candidate `+8` is the exact alignment
for engine frames 29--68 and `+10` for frames 69--80. Thus the row has two
facts: its source-6267 anchor is seven frames stale, and the event itself then
accumulates another three frames of displacement. It is classified REAL
because fixing the initial anchor does not fix the row. The row passes at
`189a823` and has the candidate frame-zero tuple by `4c877ff`; the preceding
goal's state divergence already appears at `60daac8`.

### `foi1-exploding-block-seeded`: ANCHOR DRIFT

The first divergence is frame 0 / source 400 and is only `logic_frame`: 101 in
the candidate oracle versus 102 in the engine/live-calibrated row. All other
declared content stays exact at the same indices through frame 170. When the
death animation begins moving, candidate frame `f+1` is byte-for-byte equal on
all declared fields to engine frame `f` for engine frames 128--317. This is a
constant one-frame displacement, including the complete moving death tail,
not different gameplay at aligned states.

The stage test is equally sharp: the full 319-frame row passes at `189a823`
and turns red at `60daac8` with the same frame-zero 101/102 counter tuple. This
is the measured loader/anchor class the scenario's live-pin
`mode14_source_frame`, source-400 offset, and post-warmup anchor state did not
re-land for the candidate.

## Per-row attribution

The 19 rows split into **12 anchor drifts and 7 real behavior changes**. A REAL
classification here means the candidate changes an in-scope observable at
aligned states; it is not a judgment that the old emulator behavior was more
hardware-accurate.

| scenario | attribution | evidence and required candidate re-measurement |
| --- | --- | --- |
| `chocolate-island-4-carrot-top-lift` | **ANCHOR DRIFT** | Frame 0 is the one-pass loader tuple: clocks 92/43 vs 93/44, player (155,147) vs (157,149), and camera (30,21) vs (34,23). The loader entry passes at `189a823` and turns red at `60daac8`. Re-measure the candidate semantic start/movie offset and the complete `loader_epoch` tuple. |
| `dark-room-back-door-switch` | **REAL** | All 27 declared state fields are exact for all 460 frames. Only the projected dark-mask raster diverges, at frame 431. This presentation change already exists at `189a823` (there its first pixel is frame 427). No seed or offset is stale. |
| `foi1-exploding-block-seeded` | **ANCHOR DRIFT** | Representative proof above: frame-zero `$13` is one behind and the moving death tail is an exact constant +1 shift. Re-measure source/movie offset, all three `loader_epoch` values, and the measured post-warmup `anchor_state`. |
| `foi1-goomba-carry-pose` | **ANCHOR DRIFT** | Frame 0 differs only in logic/effective clocks 101/52 vs 102/53; later pose/actor phase follows that one-pass displacement. Re-measure source/movie offset, warmup and both counter seeds, then re-capture the measured player/RNG anchor. |
| `gameplay-foi1-wiggler` | **ANCHOR DRIFT** | Frame 0 already shows the same -1 clocks plus Wiggler x/animation/animation-counter one pass apart. Re-measure source/movie offset and the direct-room warmup/logic/effective arrival tuple. |
| `gameplay-yellow-switch-palace-natural` | **ANCHOR DRIFT** | The first comparator difference is only the natural-route counter epoch: candidate 14/33 vs engine 31/17 at source 7155. Re-scan `yellow-switch-palace-completion.zmov` at the candidate and re-measure start/movie offset, warmup, and logic/effective seeds. |
| `gameplay-yi1-goal` | **REAL** | Exact through frame 504, then the goal schedule requires a growing +1 to +7 alignment. First state divergence is frame 505. No constant offset or seed can repair it. Candidate first-state-divergence class appears at `60daac8`. |
| `gameplay-yi4-entry` | **REAL** | All 198 declared state fields are exact for all 280 frames; the sole first difference is the rendered frame at 167. It is already red at `189a823` (frame 168 there). No anchor re-measurement applies. |
| `gameplay-yoshi-mounted-goal` | **REAL** | Exact through frame 537, then frame 538 differs in clocks, player speed, end timer, and wipe; the required alignment grows to +7 just like YI1 goal. This is the goal-transition class, not its 5903 anchor. |
| `gameplay-yoshis-house` | **REAL** | All 199 declared state fields are exact for all 640 frames. The candidate first differs only in the frame-300 OBJ `chimney-smoke` crop. Presentation changes in this row already exist at `189a823`. No seed or offset is stale. |
| `loader-equivalent-ci4-entry` | **ANCHOR DRIFT** | Its only row differs by the same one-pass CI4 tuple: clocks 92/43 vs 93/44, player (139,131) vs (140,132), camera y 6 vs 7. It passes at `189a823` and first turns red at `60daac8`. Re-measure start/movie offset and `loader_epoch`. |
| `overworld-clear-reveal` | **REAL (plus inherited anchor drift)** | Source 6267 is initially +7 stale, but exact alignment then grows +7 -> +8 -> +10 during the event. Re-anchoring alone fixes only the first 31 frames. It passes at `189a823`; the preceding goal's changed state schedule appears at `60daac8`. |
| `overworld-switch-palace-beat` | **ANCHOR DRIFT** | Candidate content at `f+1` equals engine content at `f` for all 177 overlapping frames; only the independently seeded clocks remain different. The candidate content boundary is therefore source 9620, not 9619. Set both offsets to the measured boundary and re-measure overworld global/effective clocks and the palace phase/timer/slot seed. |
| `overworld-yi1-to-ysp-pan` | **ANCHOR DRIFT** | Candidate `f+17` equals engine `f` on every declared field for all 103 overlapping frames. The measured candidate boundary is source **6656**, not 6639. Set both offsets to 6656 and re-read the overworld global/effective seeds there. |
| `regression-chuck-head-flip` | **ANCHOR DRIFT** | Frame 0 clocks are 114/65 vs 115/66; the occasional head-animation difference is the resulting parity phase. Re-measure the source/movie boundary, warmup/counter seeds, and the measured player/sprite anchor. |
| `roys-castle-creating-eating-block` | **ANCHOR DRIFT** | Frame 0 clocks are 91/42 vs 92/43 and the candidate retains the prior loader-pass raw slot-9 values. Re-measure the source/movie boundary and direct-room warmup/counter tuple rather than treating the stale slot as block behavior. |
| `vanilla-fortress-ball-chain-swing` | **ANCHOR DRIFT** | Every non-clock declared field is exact for all 256 frames; only logic/effective clocks are a constant -1. Re-measure only the direct-room counter epoch. Preserve the deliberately synthetic ball-chain anchor; do not relabel it measured. |
| `vanilla-fortress-roster` | **ANCHOR DRIFT** | Frame 0 has the -1 clocks, player y 338 vs 339, and prior-pass slot-9 residue. Re-measure source/movie boundary and warmup/counter tuple at the candidate. |
| `wall-follow-urchin-seeded` | **REAL** | All 40 declared state fields are exact for all 384 frames. Only the frame-32 OBJ `urchin-face` crop differs. The exact same crop red already exists at `189a823`; changing loader/RNG/player seeds would move correct state to hide a presentation change. |

The stage checks make the two dominant mechanisms explicit. Mid-scanline
register replay (`189a823`) creates the state-aligned raster differences.
HDMA scheduling/accounting through `60daac8` creates the measured one-pass
loader and goal-state class. Later interrupt commits retain those results.
The standalone all-ReleaseFast goal transition additionally exposes the merge
interaction described above.

## Re-derivation recipe

Drift is the numerical majority, but it is not one global constant. Re-derive
only the 12 rows marked ANCHOR DRIFT and leave the seven REAL rows unchanged as
decision evidence.

1. Build the candidate oracle and record retained full traces for the affected
   movies. For natural course-entry anchors, run `tools/fidelity/align.mjs` on
   `yellow-switch-palace-completion.zmov`; it mechanically reports candidate
   mode-$14 boundaries and `$13/$14` seeds. For the arbitrary overworld event
   boundaries, scan the retained `trace.ndjson` for the declared semantic
   state. The measured scans here already establish 6656 for
   `overworld-yi1-to-ysp-pan` and 9620 for the palace content boundary.

2. For every loader-equivalent drift row
   (`chocolate-island-4-carrot-top-lift`,
   `foi1-exploding-block-seeded`, and `loader-equivalent-ci4-entry`), re-read
   the first top-of-pass mode-$14 row and replace all of
   `oracle.loader_epoch.{mode14_source_frame,logic_frame,effective_frame}`.
   Locate the candidate's equivalent semantic comparison boundary and set
   `oracle.start_frame` and `engine.movie_offset` to that same measured row.
   Do not add scenario-local engine warmup/counter values: the loader harness
   derives them from `loader_epoch` and the validator forbids duplicates.

3. Re-measure the legacy direct-room arrival tuple—source/movie offset,
   `warmup_frames`, `logic_frame`, and `effective_frame`—for
   `foi1-goomba-carry-pose`, `gameplay-foi1-wiggler`,
   `regression-chuck-head-flip`, `roys-castle-creating-eating-block`,
   `vanilla-fortress-ball-chain-swing`, and `vanilla-fortress-roster`.
   The observed +1 class is a search bound, not permission for a blanket +1:
   each semantic boundary and top-of-pass counter pair must be read from its
   candidate trace.

4. After correcting a measured boundary, run
   `tools/fidelity/rederive-anchor-seeds.mjs --scenario <name> --write` for
   `foi1-exploding-block-seeded`, `foi1-goomba-carry-pose`, and
   `regression-chuck-head-flip`. That recorder mechanically re-reads every
   anchor key already declared, including player subpixels, RNG, and sprite
   continuation fields. Do not run it on the synthetic
   `vanilla-fortress-ball-chain-swing` anchor.

5. Re-measure `gameplay-yellow-switch-palace-natural`'s natural start/movie
   offset and warmup/counter seeds from the candidate course trace. For
   `overworld-switch-palace-beat`, use source/movie offset 9620 as the measured
   content boundary and re-read the global/effective and palace phase seeds.
   For `overworld-yi1-to-ysp-pan`, use source/movie offset 6656 and re-read the
   global/effective seeds. Do not "re-derive" either goal row or
   `overworld-clear-reveal`: their offsets change within the compared window.

6. Regenerate each adjusted bundle and run
   `tools/fidelity/sweep.mjs ... --regen --json`. The sweep uses the same
   comparator as the gate and mechanically reports every divergent range, so
   it is the correct proof that a re-landed row is clean rather than merely
   past its former first red. Then run the normal active board.

The existing machinery is therefore **partially mechanical, not a bulk
re-anchor command**. `align.mjs` derives course-entry boundaries;
`rederive-anchor-seeds.mjs` rewrites declared measured anchor state; and
`sweep.mjs` diagnoses/verifies the entire trace. None of them searches and
rewrites arbitrary event `movie_offset` values, none re-derives
`loader_epoch`, and `sweep.mjs` itself never edits a scenario. Those boundaries
still require a semantic trace signature and a human-reviewed scenario edit.

## Decision summary

The proposed global explanation is rejected. Boot-prefix cadence is identical
at both requested milestones (0-frame delta), 12 rows are genuinely stale
anchors/epochs, and 7 rows contain real aligned-state or aligned-presentation
changes. In particular, only one of the three representatives is pure anchor
drift. Re-deriving the 12 drift rows is well-scoped evidence work, but it cannot
turn the candidate board green without separately accepting, rejecting, or
investigating the seven real changes.
