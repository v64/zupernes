# DSP-1 / Super Mario Kart Mode 7 — Debugging State

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
