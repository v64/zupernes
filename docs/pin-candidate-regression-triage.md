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

The same trace does find a later, transition-local difference: after the second
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

Pending representative classification and corpus-wide anchor audit.

## Re-derivation recipe

Pending attribution result.
