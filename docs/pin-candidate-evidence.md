# Pin-candidate evidence

This document records evidence only.  It does not advance a pin.

## Provenance and commands

The live baseline was the protected ZuperNES revision
`9b5270ca3498a92ac082ed820510f87e91ecc42b`.  Its complete, per-scenario
transcript is committed as `docs/pin-candidate-live-fidelity.txt`.

The candidate was built from `7615d782489534e4579e9bf9ab21e9d1eb648f0a`
(`pin-candidate`) with `zig build -Doptimize=ReleaseFast`.  The temporary
ZuperWorld checkout used its explicit `ZUPERNES_ORACLE_PATH` guard override,
which certified every candidate bundle to that revision.  Both boards ran:

```
node tools/fidelity/run-active.mjs \
  '/Users/v64/Repos/zupernes/test/games/Super Mario World (USA).sfc'
```

in fast-OAM mode (the runner's default).

## Fidelity board

| build | matched | diverged | not compared |
| --- | ---: | ---: | ---: |
| live pin `9b5270c` | 121 | 10 | 1 |
| candidate `7615d78` | 101 | 29 | 2 |

The live summary is verbatim: `131/132 active scenarios compared (121
matched, 10 diverged, 1 not compared)`.  The candidate summary is verbatim:
`130/132 active scenarios compared (101 matched, 29 diverged, 2 not
compared)`.

### Red-set delta (verbatim rows)

| disposition | scenarios |
| --- | --- |
| identical | `overworld-arrival-forest-of-illusion`, `overworld-arrival-main-map`, `overworld-arrival-special-zone`, `overworld-arrival-star-world`, `overworld-arrival-valley-of-bowser`, `overworld-arrival-vanilla-dome`, `overworld-arrival-yoshis-island`, `overworld-idle-animation`, `regression-iggy-castle-entrance-mounted`, `regression-iggy-castle-entrance-on-foot` |
| improved | _none_ |
| regressed | `chocolate-island-4-carrot-top-lift`, `dark-room-back-door-switch`, `foi1-exploding-block-seeded`, `foi1-goomba-carry-pose`, `gameplay-foi1-wiggler`, `gameplay-yellow-switch-palace-natural`, `gameplay-yi1-goal`, `gameplay-yi4-entry`, `gameplay-yoshi-mounted-goal`, `gameplay-yoshis-house`, `loader-equivalent-ci4-entry`, `overworld-clear-reveal`, `overworld-switch-palace-beat`, `overworld-yi1-to-ysp-pan`, `regression-chuck-head-flip`, `roys-castle-creating-eating-block`, `vanilla-fortress-ball-chain-swing`, `vanilla-fortress-roster`, `wall-follow-urchin-seeded` |

The live board's sole not-compared scenario was
`overworld-widescreen-center` (exit 3).  The candidate retained that
infrastructure result and additionally could not compare
`gameplay-yi1-bonus-game` (exit 3).  These are not fidelity reds.

## TAS ceiling: zupernes-side warps replay

**No desync was observed through the current ZuperNES ceiling.**  This
replaces the previous `1830` desync claim with the following verbatim
candidate report fields:

```
"frames_to_desync": null,
"covered_rows": 206,
"zupernes_ceiling": 1830,
"frames_to_desync_lower_bound": 1831,
"censored_at_zupernes_ceiling": true
```

The run used `warps.zmov` and 1831 video frames to obtain the final boundary:

```
zig build tas-replay-trace -Doptimize=ReleaseFast -- <rom> warps.zmov 1831 <trace>
node tools/tas-replay/phase-b.mjs <rom> warps.zmov <trace> <out-dir>
```

All 206 closed compared rows passed; the eight one-call GetRand transitions
also verified.  Therefore the precise TAS number is **`>1830`** (censored
lower bound **1831**), not a newly observed desync frame.
