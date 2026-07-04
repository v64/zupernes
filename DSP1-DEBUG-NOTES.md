# DSP-1 / Super Mario Kart Mode 7 — Debugging State

## RESOLVED (2026-07-04): Mode 7 races render. Three timing fixes.

The desync was not in the DSP core's semantics at all. The game writes
its 7 Parameter words **blind** (no RQM polling between params — the
loop is `LDA dp,X / STA $00:6000` straight-line code at $81:F9E8,
cycle-tuned to hardware). The microcode's consume chain needs ~7 DSP
instructions per param (JRQM gate → `MEM<-DR` with-request → walk to the
next gate). Three separate emulation-timing errors each starved the DSP
below that budget; each param then arrived one JRQM station early,
overwrote the previous one in DR, and the whole conversation shifted by
one word. The "spurious RQM" the game saw before its blind result reads
was $28b's *request for param 7* (which the game had already sent).

1. **Per-access memory timing** — flat 6 master cycles per CPU cycle ran
   SlowROM/WRAM code ~30% fast. Fix: `Bus.memSpeed` (the 6/8/12 map incl.
   FastROM MEMSEL), `Cpu.mem_masters/mem_accesses` accumulated in the
   access helpers, `Emulator.step` clocks PPU/APU with
   `mem_masters + internal*6`; DMA/HDMA bill 8/byte via
   `Bus.tickDmaByte`. Side effect: the Mesen2 frame-alignment gap
   (+17 boot, 14-26/level-load) collapsed to ±1..10 over 2900 frames.
2. **Sub-instruction DSP ticking** — a bus write takes effect at the END
   of its instruction; batching the whole instruction's cycles after the
   write robbed the DSP of ~3 instructions per STA. Fix:
   `Cpu.accountAccess` brings the DSP up to "now" before every bus
   access (`internal_flushed` bookkeeping); root ticks only the trailing
   internal cycles.
3. **The DSP instruction rate itself** — we ran 8.192MHz/4 = 2.048 MIPS
   per the datasheet's cycles-per-instruction reading. bsnes/Mesen2 (and
   working hardware behavior) use **7.6MHz, ONE instruction per clock**.
   SMK's FastROM inter-write gap is only ~66 master cycles ≈ 23 DSP
   instructions at the real rate — at 2.048 MIPS it was 6, one short of
   the consume chain even after fixes 1-2. `Bus.tickDsp` now runs 7600
   instructions per 21477 master cycles.

Verified: boot conversation byte-exact (game reads real results
`0000 ffb2 0880 27a3`, matching the unit test), race-load raster streams
fill $7E:4000-$FFFF with real perspective tables (was solid $80 echoes),
and **frame 4310 of test/movies/smk-mc1.zmov shows the same start-grid
scene as Mesen2**: road, 8 karts, Lakitu, course map. All 29 test ROMs
and all unit tests still pass.

Related fixes found on the way (cross-validating menus vs Mesen2):
- WRAM now powers on $FF-filled (was zeroed): SMK range-validates a
  settings block that survives soft-reset in WRAM; zeros passed as a
  phantom "remembered 2P GAME" selection. $FF fails validation like real
  garbage does, and stays deterministic for TAS.
- SRAM now $FF-filled for the same reason (fresh battery reads ~$FF).
- Port 2 models a DISCONNECTED controller (reads 0s; no 1-padding
  "connected" signature) until a frontend maps 2P input.
- Mesen2 needs `Firmware/dsp1b.rom` (copied from test/dsp/) to run SMK.

Remaining SMK polish (next session):
- Timer bar at screen top not rendered during the race (Mesen shows
  "1 00'00\"00"; we show horizon there) — likely a window/HDMA nuance on
  the top strip.
- Races start ~65 frames apart between the emulators (menu-phase
  accumulation); countdown scene itself matches.
- SMW yi1-walk movie re-run: Mario at YI1 entry renders as a small
  partial sprite at f2990 — determine whether that's the level-entry
  appear-pose (the movie enters the level later on the new timing, so
  old frame indices show earlier game states) or an OAM regression from
  the timing overhaul. Compare against Mesen at the same $13.

Diagnosis artifacts (all comptime-gated, kept):
- `[DSPPC]` per-instruction pc+sr stream in `Bus.tickDsp`
  (`dbg.trace_frame_min..trace_pc_frame_max`), frame-stamped DR/SR lines.
- `dbg.trace_watch`/`watch_addr` low-RAM write watchpoint +
  `watch_dsp_writes` (prints writing PBR:PC) in `Cpu.writeByte`.
- `screenshot --dump-wram` + Mesen Lua WRAM dump → diff → watchpoint is
  the cross-emulator state-divergence workflow that found the WRAM-init
  bug (cursor byte $0085 ← settings word $2E ← boot validation at
  $81:E477).
- SMK's boot conversation happens at **frame 85** of
  test/movies/smk-mc1.zmov.

The sections below are the original investigation log, kept for the
methodology and the microcode/protocol reference material.

---

Paused mid-investigation. This file is the resume point; read it top to
bottom before touching anything.

## What works (verified)

- **uPD77C25 LLE core** (`src/coproc/upd7725.zig`) runs the real DSP-1B
  microcode (`test/dsp/dsp1b.rom`, sha256 `d789cb3c...` — gitignored,
  fetch the `snesdsp` archive from caitsith2.com/snes/dsp/).
  Instruction-set semantics from MAME `upd7725.cpp` (BSD-3-Clause, orig.
  byuu public domain) — a copy is in the session scratchpad; re-fetch from
  github.com/mamedev/mame if needed.
- Program ROM = 2048 x 3-byte **little-endian** words, then data ROM =
  1024 x 2-byte LE words. Both byte orders verified (first program word
  decodes as a sensible `JRQM 000` guard; data ROM word 278+ is the
  ascending quarter sine table `0000 0324 0647 096a...`).
- Mapping (confirmed by tracing SMK's poll loop): HiROM DSP-1 boards, banks
  $00-$1F: DR = $6000-$6FFF, SR = $7000-$7FFF. LoROM variant (banks
  $30-$3F, DR $8000-$BFFF / SR $C000-$FFFF) is wired but untested
  (Pilotwings is the test case).
- Clocking: 2.048 MIPS = 2 instructions per 21 master cycles, accumulator
  lives on the Bus (`Bus.tickDsp`) so both root.zig (per CPU instruction)
  and dma.zig (8 master cycles per DMA/HDMA byte) advance it. The
  DSP-runs-during-DMA part is load-bearing in principle (hardware truth),
  though it did NOT fix the bug below.
- Unit tests all pass, including three that drive the REAL microcode:
  multiply ($00) fine+signed, Parameter ($02) with SMK's captured inputs,
  and a boot-conversation replay at coarse pacing. All use RQM polling.
- **SMK boots, title/menus/driver select all work, race starts.** Known-good
  input script into a race:
  `--input 500:S --input 800:U --input 1100:S --input 1500:S --input
   1900:S --input 2300:S --input 2700:S --input 3100:S --input 4100:S`
  (the 800:U matters - menu cursor defaults to 2P GAME).
- In-race DSP traffic is healthy: Project ($06) and Parameter ($02)
  commands flow constantly with correct RQM handshakes and plausible data.

## The remaining bug

**The Mode 7 track renders flat green.** The perspective matrix HDMA
(channels 1-4, indirect from WRAM bank $7E; table-of-pointers at
$00:0640/064d/065a/0667 -> $211B/C/D/E, mode 2; ch5 drives $2105
mode-switching, ch6 $212C, ch7 window) delivers mostly `$8080` because the
WRAM raster tables contain `$80` bytes.

Root cause chain (all evidence in this file's "how to reproduce"):

1. The game builds those tables **once at game boot** (~1s in, right after
   its first DSP conversation), NOT at race load. `$80` is what the DSP
   presents in its command-wait loop — the table got filled with
   command-wait echoes, i.e. the conversation desynced and the game
   blind-read garbage.
2. Traced conversation (all bytes): game syncs with `$80` spam ✓, sends
   Parameter($02) with `0880 27a0 0000 0040 0100 0000 3400` — microcode
   consumes all 7 params correctly (pc walks the handler at $27b-$28f) ✓.
3. Game then polls SR **once**, sees RQM=1, and reads the 4 result words
   **back-to-back without polling between them** — getting `$3400` (stale
   DR = last param) every time, because the DSP is still hundreds of
   cycles from presenting (its pc is in compute subroutines
   $13x/$14x/$16x-$18x at read time).
4. Game then sends Raster($0a) with Vs=$cbb5 (likely garbage derived from
   the bad Parameter outputs). The raster stream DOES work briefly — core
   presents $0000, $0000, $23d3, $0127 and the game captures exactly those
   into the table (they're visible as scanlines 24/25 matrix values in the
   HDMA trace) — then the microcode returns to command-wait after ~5 words
   and the game blind-reads 750+ bytes of `$80`.

## Prime hypothesis for next session

The game does **cycle-counted blind reads** (no polling between result
words). On hardware, the DSP has deterministic latency — Parameter takes
892 DSP cycles (~117us) and the game's delay loop is tuned to that. In our
emulator the interleave granularity or effective rate makes the DSP appear
SLOWER at that moment, so the game's reads arrive before results exist.

That single SR poll returning RQM=1 mid-compute (step 3 above) also needs
explaining — it may be legitimately set by the microcode's own `DRrq`
consume of param 6 (src=8 raises RQM to request param 7) and... no, param
7's write clears it. Something re-raised RQM between param 7 and pc=$17a.
**First action on resume: view `boot3.log` UNFILTERED** (SR reads
interleaved with DR events + presents) around the first conversation —
I had filtered SR polls out of the final view before pausing.

Next actions, in order:

1. Regenerate the boot trace (flip `trace_dsp`/`trace_mode7` in
   src/debug.zig to true, window `trace_frame_min/max` = 0..120, build
   `-Doptimize=ReleaseFast -Ddebug=true`, run SMK 130 frames headless) and
   read the full interleaved conversation including SR polls. Find what
   raised RQM early.
2. Add a counter: DSP instructions executed between the param-7 write and
   the first result read. Hardware needs ~892 for Parameter. If we grant
   far fewer, the game's timing loop is running too fast relative to the
   DSP: check where the game burns time (WAI? DMA? timed loop) and whether
   we under-tick the DSP there. Note NMI/frame activity can interleave.
3. Write a unit test replicating BLIND reads: after param 7, step exactly
   N DSP instructions, then read 4 words without polling. Find minimum N
   that works; compare with what the integration actually grants.
4. If the raster stream's early termination (back to command-wait after 5
   words) is still there once Parameter results are right, disassemble the
   raster loop (handler dispatch: cmd $0a -> follow tree from $008; use
   the disassembler snippets below) and look for an ALU/flag edge case.
   The stream termination condition (host WRITE mid-stream stops it) and
   the line counter logic are the suspects.
5. Once the track renders: byte-identical regression check on SMW +
   All-Stars captures (DSP changes shouldn't touch them, but verify),
   update NEXTSTEPS.md, commit, and celebrate with the Mode 7 screenshot.

## How to reproduce / tooling

- Traces (all comptime-gated, zero release cost):
  - `dbg.trace_dsp` — every DR/SR access with DSP pc+sr, plus every
    microcode DR presentation (`[DSP1] present`), plus `[DSPPC]`
    per-instruction pc stream (in `Bus.tickDsp`, gated to
    `trace_frame_min`).
  - `dbg.trace_mode7` — $2105/$211A-$2120 writes with frame/line/dot
    (ppu.zig) + HDMA channel configs (`[M7-HDMA]`, dma.zig).
  - Window: `dbg.trace_frame_min/max`.
- Capture: `zig build -Doptimize=ReleaseFast -Ddebug=true screenshot -- <rom> <frames> out.ppm 2> trace.log`
- Microcode disassembler: inline Python in the session transcript; the
  field layout is (op>>22)=type, OP/RT: pselect(20-21) alu(16-19) asl(15)
  dpl(13-14) dphm(9-12) rpdcr(8) src(4-7) dst(0-3); JP: brch(13-21)
  na(2-12); LD: id(6-21) dst(0-3).
- Useful microcode landmarks (DSP-1B): $000 boot/command-wait loop
  (presents $0080), $005 command consume, $008+ dispatch tree (SHR1A on
  command bits), $1ac Multiply, $27b Parameter (params at $27d/f/281/
  284/287/28b/28f — note param 6 consumed with-request at $28b, param 7
  without at $28f), $34d-$35e raster present sequence.

## Longer-term (moved to NEXTSTEPS.md)

TAS-format input recording/playback, the "Claude plays Mario Kart"
frame-by-frame loop, debugger mode, sprite viewers, library/wasm refactor
— see NEXTSTEPS.md "Long-term goals".
