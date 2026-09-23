# T3 ordered-timing report (branch `arch/timing-t3`)

Research line for ZuperWorld's T3 timing work, continued from the banked
2026-09-12 checkpoint (`zuperworld/docs/timing-checkpoint-20260912.md`).
**Nothing here is promoted**: the ZuperWorld oracle stays pinned at
`39935fa`, and this branch is not merged. Promotion is the owner's
decision.

## What the ordered profile is

`Emulator.enableOrderedClockFromPowerOn()` (and `screenshot --ordered`,
`timing-trace`) runs the machine on one execution-ordered wall owner
(`src/refresh_timing.zig`). Every CPU cycle, DMA/HDMA byte, DRAM refresh
stall and line boundary advances the PPU, APU and DSP in order. The default
runtime still uses the pin's aggregate clock; only the CPU cycle
corrections below apply to both paths.

## Result: exact agreement with Mesen2 on every probe

The certified Mesen2 3b058f9 build runs in a sandbox
(`test/timing/mesen_timing_path.mjs`). ZuperNES runs the same
copyright-free ROMs from power-on (`zig build timing-trace`), and
`test/timing/cross_oracle.mjs` compares absolute master / scanline /
H-clock for every event.

**143 / 143 event streams agree exactly:**

| probe | streams |
|---|---|
| general DMA: normal, refresh-crossing, B->A, two-channel (trigger, every source, every destination) | 12 |
| 5,000 consecutive CLC opcode starts across DRAM refresh | 1 |
| field lengths 357368 / 357364 / 357368 / 357364 | 1 |
| HDMA: $420C write, frame-init table read, data read, destination | 3 |
| IRQ into a NOP loop | 2 |
| IRQ sweep, 21 H positions x (4 entries, 4 writes) | 42 |
| WAI sweep, 21 H positions | 42 |
| NMI sweep, NOP and WAI loops x 10 alignments x 4 frames | 40 |

At the pin's timing, 5 of the original 7 probes disagreed.

## Result: Super Mario World tracks Mesen2

These use `test/timing/frame_log.zig` (built against any tree) and
`test/timing/mesen_frame_log.mjs`, with both sides on $FF power-on WRAM
and no input. The run is the attract loop, 3,000 frames.

| build | first frame whose game mode ($0100) or logic frame ($13) differs from Mesen | mode-transition error |
|---|---|---|
| pin `39935fa` | 67 | up to 26 frames early |
| this branch, default path | 191 | 0-5 frames early |
| this branch, ordered profile | **none in 3,000** | **0** |

Full 128 KiB WRAM at the first instruction of SMW's NMI handler (an instant
identical in both emulators), every 300 NMIs:

- The ordered profile is byte-identical at 6 of 9 checkpoints.
- The other 3 differ only in `$01FD`, the stacked return address: the NMI
  interrupts the `LDA $10 / BEQ` wait loop one instruction apart.
- For reference, the pin differs by 8-229 bytes at every frame checkpoint.

Donkey Kong Country, Chrono Trigger and Final Fantasy III show the same
residual WRAM differences under the pin and the ordered profile. Their
divergence from Mesen is outside this timing work (see *Open*).

## What changed (commits on top of `39935fa`)

1. `93f1fb0`: certified Mesen runner; default-path equivalence gate.
2. `16206a2`: merged `arch/hvbjoy-access-time-sol` ($4212 at the read
   handler).
3. `470e006`: **CPU cycle composition is vector-exact.** The
   SingleStepTests 65816 audit (`cpu-vectors <dir> --cycles`) went from
   2,989,479 / 5,120,000 to 5,059,960 matching sequences. Remaining,
   documented:
   - WDM follows Mesen.
   - WAI/STP: the ordered profile models Mesen's halted state.
   - 40 speed differences in the (dp,X) pointer-wrap divergence.

   Final state is unchanged (the same 247 known vectors). Applies to both
   paths.
4. `405e437`: ordered DMA controller (Mesen `SnesDmaController`):
   - `$420B` only raises a request, serviced at CPU cycle boundaries.
   - Start delay, reset-relative 8-master sync, 8 global + 8 per
     channel, 4 / source / 4 / destination, end sync.

   Also in this commit: the 186-master power-on origin, the
   `Bus.TimingProbe` hook, `timing-trace`, and the cross-oracle.
5. `14c66df`: hardware interrupt entry reads PC and idles before the
   pushes (both paths).
6. `dae409f`: ordered HDMA through the same controller. It is raised at
   line 0 H=12+(start&7) for init, and at H=1104 per visible line.
7. `6750f2b`: NTSC short scanline: line 240 of odd fields is 1360
   masters.
   - The PPU tracks real field starts, and all absolute-time math uses
     them.
   - The bus NMI/IRQ projections walk real field boundaries.
   - Savestate v8.
8. `9bd8962`: game-level Mesen comparison tools; `screenshot --ordered`.
9. `73fe2df`: conditional IdleOrRead (a real read when an interrupt is
   imminent), IrqLock after DMA/HDMA, and the Mesen timer delays.
   - H/HV: the flag rises at 14+4h and the CPU input 4 masters later.
   - V-only: the flag rises at H=10 (H=6 on line 0).
10. `be41044`: WAI halts and wakes in two stages like Mesen (the pin never
   halted).
11. `786cf56`: CPU NMI edge at H=6 of line 225 (RDNMI at H=2).

The earlier `arch/nop-cycle` fold-in is superseded: NOP is AddrMode_Imp,
i.e. the same IdleOrRead phase. The four redundant research branches are
kept as tags `archive/*`.

## Verification at the final head

| check | result |
|---|---|
| `zig build test` Debug / ReleaseSafe | 114 / 114, 114 / 114 |
| Mesen cross-oracle | 143 / 143 |
| PPU campaign vs Mesen | 380 / 380 |
| dp-indirect vs Mesen | 80 / 80 |
| SingleStepTests final state | 5,119,753 / 5,120,000 (the known 247) |
| SingleStepTests cycle sequences | 5,059,960 / 5,120,000 (documented remainder) |
| default path vs pin (35 ROMs, 1200 frames) | 17 identical, 18 differ; the CPU cycle fixes apply to both paths |
| speed, SMW 3000 frames | default 442 fps; ordered 314 fps |

## Open

- **SMW NMI phase jitter.** 943 of 3,000 NMIs interrupt the wait loop one
  instruction away from Mesen, in both directions, from NMI 4 on. Game
  state is identical, so a frame's CPU work differs by a few masters in
  some frames. The cause has not been found. Next suspects:
  - APU/SPC700 port handshake timing;
  - HDMA corner cases (indirect, multi-channel, HDMA preempting DMA,
    $2180 transfers);
  - open-bus values.
- **Other games** (DKC, Chrono Trigger, FF III) diverge from Mesen
  identically under the pin and the ordered profile. The divergence is
  therefore not CPU/DMA/refresh timing.
- **Not modeled:** interlace and 263-line fields, overscan HDMA lines,
  and the `$4200` mid-vblank NMI's two-cycle counter (still the pin's
  immediate edge). Also the DMA `$2180`<->WRAM special cases, and
  open-bus values of `$4212` / `$2137` (timing-exact, value-inexact).
- **Savestate v8 restore is not yet atomic.** A malformed refresh schedule
  is still rejected only after the machine was partly written.
- **Promotion** means making the ordered profile the runtime default,
  then re-running ZuperWorld's gates against a candidate pin. ZuperWorld's
  port was written against the pin's timing, so expect it to need its own
  A/B.

## Reproduce

```sh
zig build -Doptimize=ReleaseFast
node test/timing/mesen_timing_path.mjs .oracle/run/mesen    # certified Mesen, sandboxed
node test/timing/cross_oracle.mjs .oracle/run/mesen         # expect 143/143
zig build cpu-vectors -- <SingleStepTests 65816 v1 dir> --cycles
```
