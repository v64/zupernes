# DRAM refresh scheduler prototype

This branch starts from the canonical ZuperNES pin
`e17dc5e3f68b417db8351b091885c4af921a2b3d`. It adds a copyright-free timing
prototype and independent Mesen probe. It does not wire refresh into the live
default emulator path, change an oracle pin, or claim the broader CPU clock
model is ready. Explicit fixtures run the actual CPU and DMA/HDMA paths through
the candidate owner; normal execution retains the pinned aggregate clock path.

## Required hardware event

The primary timing reference reports a 40-master S-CPU pause once per scanline,
with the reset-aligned first pause at master 538 and later starts aligned to the
nearest eight-master cadence. It distinguishes 6/8/12-master accesses and
six-master internal CPU cycles. See the Super Famicom Development Wiki,
“Clocks & Refresh”: <https://wiki.superfamicom.org/timing>.

Clean Mesen2 source revision
`3b058f9fbf6f446028eab3a83c5a3db35b1b960a` independently implements this in
`Core/SNES/SnesMemoryManager.cpp`:

- `Reset` sets `_dramRefreshPosition = 538 - (_masterClock & 0x07)`;
- `ProcessEvent(DramRefresh)` advances 40 masters;
- `EndOfScanline` recalculates the next line's position with the same formula;
- every CPU and DMA clock advance passes through `Exec`, so a crossing is a
  wall-clock event rather than an opcode-specific surcharge.

In the current fixed 1,364-master, 262-line PPU profile, line starts alternate
modulo eight. Refresh therefore starts at H-clock 538 on even lines and 534 on
odd lines, and the same local pattern repeats next frame. This is a property of
that profile, not a general hardware geometry rule. A 1,360-master short line
changes the following line's local refresh position by four clocks; an
interlace field can also contain 263 lines. The prototype therefore computes
each event from an observed absolute line start rather than a line index or
frame period.

## Executable scheduler

`src/refresh_timing.zig` models the smallest reusable contract. The owner
calls `beginLine(actual_line_start_master)` at each PPU boundary:

```text
Timeline { wall_master, next_refresh_master }
advanceWork(bus_work) -> { wall_elapsed, refresh_masters, refreshes }
```

CPU, DMA, or HDMA consumes `bus_work`; the PPU, APU, and independent
coprocessors consume `wall_elapsed`. Reaching the event exactly triggers the
40-master pause before the bus work completes. The next event is explicit so a
snapshot at an exact boundary cannot confuse an unprocessed refresh with an
event already consumed.

The unit tests establish:

- the current profile's 538/534 schedule, plus a short-line boundary that
  changes the next local H-clock without resetting global wall phase;
- the existing three-`LDA #$00` fixture's 48 work masters become 88 wall
  masters from H-clock 500;
- 38 work masters ending exactly at the first event consume 78 wall masters;
- chunked access projection and whole-instruction projection agree;
- a six-master I/O read distinguishes a refresh before its handler from one in
  its four trailing masters, where the callback is 44 rather than four wall
  masters after the handler;
- a DMA-like span uses the same scheduler and crosses refresh normally;
- restoring `{ wall_master, next_refresh_master }` replays the same decision,
  while a malformed already-past event is rejected in release builds.

These tests falsify a per-frame total, per-instruction flat surcharge, or a
callback-minus-four rule.

## Ordered CPU phase stage

The first clock-ownership stage is now executable without changing the pinned
default runtime. `Timeline.advanceWorkOrdered` is the sole owner of
wall time for its hardware sink. It splits CPU work at the next refresh or at
the PPU sink's observed line rollover and emits ordered `cpu_work` and
`dram_refresh` segments. Every segment advances the same sink, so refresh
cannot become an instruction total that the PPU, APU, or coprocessor misses.
On rollover the timeline derives the next event from the resulting absolute
wall master; it does not assume a fixed frame repeat. Wall-only refresh time
is split at a rollover as well, so even a synthetic short geometry cannot hide
a line boundary inside the stall.

`CpuAccessPhases` exposes the CPU boundaries needed by mapped devices:

- a read advances `access_masters - 4`, runs its handler, then advances four
  trailing masters;
- a write advances its full 6/8/12-master access before its effect;
- internal work advances before its architectural effect.

The pure synthetic sink proves the exact segment order for the 48-work/88-wall
fixture, refresh on either side of a six-master read handler, a write crossing,
an internal cycle crossing, and a 1,360-master short-line rollover.

The same phase boundary is connected to actual `Cpu` execution behind the
fixture-only `enableOrderedClockFixture`. CPU read helpers advance leading
clocks, invoke the real mapped handler, then advance four trailing clocks;
writes advance their complete access first. The callback advances the PPU,
APU, and DSP through each ordered work or refresh segment. In this mode
`Emulator.step` advances only unflushed trailing internal work and returns
without running its aggregate clock path, which proves clocks are not counted
twice. Runtime tests execute the three-`LDA` fixture from wall master 500 and
observe 48 CPU-work masters as wall 588, execute `BIT $4212` across active to
HBlank and observe the returned flag from handler time, and journal a `$2100`
write after its access crosses refresh. Interrupt-enabled execution remains
asserted outside this fixture's scope; DMA is exercised in the next stage.

A separate copyright-free audit at the canonical pin ran 540 cases: 27
implied/register opcodes at SlowROM and FastROM in emulation mode and all four
native M/X modes, with both initial carry values. Every case currently records
only its opcode access. The WDC table and Mesen independently require one
six-master `IdleOrRead` phase before the effect for CLC/SEC/CLI/SEI/CLV/CLD/SED,
the register transfers, INX/DEX/INY/DEY, accumulator INC/DEC, and XCE. XBA
requires that phase plus one unconditional six-master idle. A later CPU patch
now uses the ordered pre-effect API for all 27 rows. A live CLC fixture places
its opcode end at wall 536 and proves the internal phase crosses refresh before
the flag changes, ending at 582; an XBA control consumes both distinct phases.
The transient final-phase width remains six masters for the canonical aggregate
interrupt sampler. Treating the conditional `IdleOrRead` as a universal
six-master idle remains explicitly incomplete when an interrupt can substitute
a next-PC dummy read.

## Independent Mesen execution

`test/mesen/dram_refresh_probe.mjs` generates a 32 KiB copyright-free SlowROM
containing 32 distinct `LDA #imm` instructions in a loop. A Lua callback records
5,000 instruction starts. Consecutive LDA starts are normally 16 masters apart:
one immediate-byte read plus the following opcode read. A refresh crossing
makes that same interval 56 masters.

Run:

```sh
node test/mesen/dram_refresh_probe.mjs .oracle/mesen-dram-refresh 5000
/path/to/Mesen --testrunner .oracle/mesen-dram-refresh/dram-refresh.sfc .oracle/mesen-dram-refresh/dram-refresh.lua
node test/mesen/summarize_dram_refresh.mjs .oracle/mesen-dram-refresh/dram-refresh.tsv
```

The local run used
`/Users/v64/Repos/Mesen2/Mesen.app/Contents/MacOS/Mesen` and produced:

| classified LDA spans | normal 16-master | refresh 56-master | unexpected |
| ---: | ---: | ---: | ---: |
| 4697 | 4640 | 57 | 0 |

The first even-line crossing runs from absolute master 536 to 592 and crosses
the event at 538. The next odd-line crossing starts at line H-clock 524 and
ends at 580, crossing the event at 534. Every observed 56-master span agrees
with the reset-aligned schedule; no expected crossing lacks the 40-master
stall.

| artifact | SHA-256 |
| --- | --- |
| ROM | `2686fa959491940063c1f1e4774565fd97443cd635126859e8d29a0dc499f839` |
| Lua | `33c511b8e9674c8146c1e42632b89303027d70cd08c6472bbf8704d3f0b67e93` |
| trace | `088dcd1a4008dfe5f7886de57a6d2c4c619860cadeca8cdc02f1a41efcf7a646` |

## Approved ownership and remaining live integration

The approved architecture is one serialized wall timeline with
execution-ordered hardware advancement. `Emulator` owns wall time and event
dispatch; CPU access and internal phases request work from that owner; DMA and
HDMA must consume the same timeline; and PPU, APU, DSP, interrupt logic, and
write journals must observe its ordered segments. Aggregate clocks are removed
from each execution path as that path migrates. This ownership decision is
approved; the remaining stages do not await another architecture choice.

The staged scope is:

1. clock ownership and actual CPU access phases with a no-DMA synthetic ROM;
2. general DMA, HDMA, and hardware-event dispatch on the same owner;
3. exact interrupt sampling, audio/state replay, and serialized refresh state.

The first two items are implemented only behind the explicit fixture
connection. The canonical pin remains held until all stages and independent
checks pass.

### DMA/HDMA event stage

The ordered scheduler asks its sink for the next hardware-event distance in
addition to refresh and line rollover. CPU work stops exactly at that event;
the sink marks it consumed before dispatch and DMA advances the same timeline
reentrantly as `dma_work`. Refresh reached during that DMA work advances the
same PPU/APU/DSP sink. No `dma_masters` aggregate remains for root to add later.

Two actual-runtime fixtures exercise the causal order:

- a one-byte general DMA begins at wall 536, reaches refresh at 538 during its
  eight transfer masters, and writes `$2100` at wall 584;
- CPU work reaches the established ZuperNES H=278 HDMA event, the current
  explicit 18+8+8-master transfer executes on the owner, and the `$2100` write
  is journaled at local H-clock 1146 before the interrupted CPU work finishes.

Mesen's `SnesMemoryManager::Exec` is used by CPU and DMA clock advances and
dispatches refresh/HDMA from that common stream. Its DMA controller also calls
`ProcessPendingTransfers` while general DMA runs. This independently supports
the shared, reentrant event shape. These fixtures preserve ZuperNES's existing
DMA/HDMA cost constants; they establish scheduling and refresh crossing, not a
fresh proof that every transfer overhead or arbitration edge is complete.

An exact runtime change is broader than adding 40 to `Emulator.step`.
The current pin executes a complete CPU instruction and its bus side effects
before committing PPU time. Several paths then reconstruct wall order from
aggregates:

1. CPU access helpers supply cumulative CPU work to
   `Bus.setCpuAccessTiming`, which timestamps register effects.
2. `Emulator.step` separately computes total instruction work and locates the
   interrupt sample by subtracting the nominal final cycle.
3. General DMA runs synchronously inside a `$420B` write but leaves only an
   aggregate `dma_masters` count for the later commit.
4. HDMA is discovered and executed later by `advancePpuWithHdma`, while
   projected CPU accesses may already extend past that beam position.
5. APU time is advanced once from the aggregate elapsed value; DSP time is
   split across CPU accesses, DMA bytes, and the instruction tail.

A refresh can occur before an access handler, in its trailing clocks, inside
the CPU's final cycle, or during DMA. Each placement changes a different
observable: register sampling, write timestamp, interrupt eligibility, or DMA
completion. A total `+40` cannot recover those distinctions. Pre-projecting
refresh while leaving HDMA to the later commit can also advance the refresh
scheduler out of event order.

The remaining integration contract is:

- one serialized hardware timeline owns physical wall time and the next
  refresh event, reset to `{0, 538}` before timed execution;
- CPU internal and access phases advance that timeline in execution order,
  exposing exact handler, access-end, and pre-final-cycle wall positions;
- general DMA and HDMA advance the same timeline rather than separate duration
  aggregates;
- PPU, APU, DSP, interrupt edges, and render/write journals consume the same
  ordered wall segments, including refresh stalls;
- savestate magic/length changes and captures `next_refresh_master`; restore
  resumes without deriving whether an exact-boundary event already fired.

The ordered primitive and opt-in CPU/DMA fixtures are the reviewed boundary for
that refactor. Exact pre-final-cycle interrupt sampling and serialized replay
remain before the default runtime can switch over. Until then, the branch is a
research candidate and must not replace the canonical oracle pin.
