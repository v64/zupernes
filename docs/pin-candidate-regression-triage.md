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
the ReleaseFast headless runner. A temporary diagnostic sampled physical WRAM
`$7E:0100` after every completed video frame. The diagnostic was not retained
in either source tree. Here, "frame index" is zero-based and "frames from
power-on" is the number of calls to `runFrame` which have completed when the
new mode is first observable.

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

Pending trace extraction and aligned-state comparison.

## Per-row attribution

Pending representative classification and corpus-wide anchor audit.

## Re-derivation recipe

Pending attribution result.
