# Next Steps

State of the project as of this session, and where to go next.
See OPTIMIZATIONS.md for the performance-specific backlog.

## What was done this session

**Harness** (how to verify anything from here on):
- `zig build screenshot -- <rom> <frames> <out.ppm> [options]` runs any ROM
  headless and dumps the framebuffer. Options:
  - `--input F:BTNS` presses buttons at frame F, held 30 frames
    (S=Start, s=Select, A/B/X/Y, U/D/L/R dpad, l/r shoulders) - chain
    several to script a path into gameplay
  - `--every N DIR` dumps a screenshot every N frames
  - `--dump FILE` writes PPU registers + VRAM + CGRAM + OAM for offline
    analysis (text header + raw binary; see test/tools usage in git log)
  - `--wav FILE` captures S-DSP output as a 32kHz stereo WAV
  - Convert PPM for viewing: `sips -s format png out.ppm --out out.png`
- Known-good input script for SMW into level gameplay:
  `--input 700:S --input 800:A --input 900:A --input 1400:A --input 2000:A
   --input 2450:L --input 2550:A`
- All-Stars into SMB1 gameplay:
  `--input 700:S --input 1000:A --input 1300:A --input 1600:S --input
   1900:S --input 2400:S`
- Mode 7 test ROMs in test/mode7/ (generator: test/tools/make_mode7_rom.py)

**Fixed bugs**: joypad (was fully stubbed - $4016/$4017 serial +
auto-joypad $4218-$421B), WRAM data port $2180 (unreachable routing, CPU
and DMA), DMA A-bus step field (bit 3 = fixed, not decrement - was
corrupting every DMA fill), RDNMI/TIMEUP latch semantics, VRAM word
address mirroring, master-clock timing (CPU was getting 85 instead of
~227 cycles per scanline), color math COLDATA fallback when subscreen is
transparent (black skies in SMW levels + All-Stars).

**New features**: keyboard input in the frontend (arrows + Z/X/A/S/Q/W +
Enter/RShift, Esc quits), HiROM cartridges (All-Stars boots and plays),
H/V timer IRQ, Mode 7 (verified with test ROMs; main+sub screens), BG2 in
modes 2-6, S-DSP audio (BRR, 8 voices, ADSR/GAIN, gaussian interpolation,
noise, echo+FIR, pitch modulation) with sokol-audio output in the
frontend and WAV capture in the harness.

## Immediate next steps (verification)

1. **Listen to the audio.** The waveform statistics look right (SMW title
   music structure matches: jingle at ~1s, music from ~3s), but nobody
   has listened yet:
   `zig build screenshot -- "test/games/Super Mario World (USA).sfc" 900
    /tmp/x.ppm --wav /tmp/smw.wav && afplay /tmp/smw.wav`
   Expect envelope/mixing bugs to be audible before they're measurable.
   Check the gaussian table against a reference dump (snes_spc) - it was
   written from memory and entries may be off by ±2.
2. **Play it.** `zig build run -- rom.sfc` now has input + sound. Watch
   for audio drift/underruns (frontend push loop is throttled by
   saudio.expect(), drift produces silence gaps, not pops).
3. **DSP timer register gaps**: KON re-trigger while a voice plays, ENDX
   read-clear edge cases, and the 5-sample key-on delay are simplified;
   compare against snes_spc behavior when a game audibly misbehaves.

## Feature backlog (rough priority order)

1. **Offset-per-tile** (modes 2/4/6) - BG3 tilemap supplies per-column
   scroll values. All-Stars SMB3 and many games use it.
2. **EXTBG** ($2133 bit 6) - Mode 7 BG2 with per-pixel priority from the
   sample's high bit.
3. **Sprite limits** - 32 sprites / 34 tiles per scanline with the
   time-over/range-over flags in $213E. Games rely on flicker.
4. **Mosaic** ($2106) - registers latched but not rendered.
5. **Hires modes 5/6** and pseudo-hires - currently drawn lo-res.
6. **Open bus behavior** - unmapped reads return 0; should return the
   last bus value (PPU1/PPU2 open bus for $2134-$213F bits). Some games
   depend on it.
7. **DSP-1 coprocessor** - blocks Super Mario Kart (hangs at Nintendo
   logo waiting for it). Big: it's a NEC uPD77C25 with its own program.
8. **SPC700 timer edge cases + IPL ROM timing** - upload protocol works,
   but timer glitch behaviors aren't modeled.
9. **PAL timing** (312 lines, 50Hz) - only NTSC now.

## Cycle accuracy roadmap

The goal is pixel-per-pixel and sample-per-sample identical output to
hardware. Current model: instruction-granularity CPU, scanline-
granularity PPU rendering, dot-granularity PPU counters. The path:

1. **Per-access memory timing**: CPU cycles are counted per instruction
   table and multiplied by 6 master cycles; real accesses cost 6/8/12
   depending on region (and MEMSEL). Requires the CPU to report memory
   accesses, not just cycle counts. This is the prerequisite for
   everything below.
2. **DMA cycle accounting**: runDma returns cycles but the caller
   discards them (bus.zig $420B write). DMA also has 8-cycle-per-byte +
   per-channel overhead and syncs to whole CPU cycles.
3. **Mid-scanline register changes**: renderScanline() samples registers
   once per line. Games that write PPU registers mid-line (via HDMA or
   tight IRQ loops - the inidisp/hdma test ROMs in test/snes-test-roms
   exercise exactly this) need either dot-based rendering or a
   change-log replayed during line rendering.
4. **HDMA timing**: currently fires at scanline start; hardware runs it
   at H≈278 with specific per-channel costs.
5. **NMI/IRQ jitter**: interrupts are polled between instructions;
   hardware delays them by specific cycle counts after the trigger dot.
6. **Golden-image regression suite**: the harness + test/snes-test-roms
   are ready for this - capture known-good screenshots per test ROM
   (compare against bsnes/Mesen output or hardware photos) and wire
   `zig build test-roms` to diff against them. Do this BEFORE starting
   timing work so regressions are caught immediately.

## Housekeeping

- README.md feature list is out of date after this session (joypad,
  HiROM, Mode 7, IRQ, audio all landed; "What's Missing" shrunk).
- test_harness.zig still marks every non-crashing ROM as PASS; fold the
  golden-image comparison into it (item 6 above).
- The `caps/` reference screenshots predate several fixes; recapture.
