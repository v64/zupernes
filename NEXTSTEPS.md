# Next Steps

State of the project as of this session, and where to go next.
See OPTIMIZATIONS.md for the performance-specific backlog and
DSP1-DEBUG-NOTES.md for the (now RESOLVED) Super Mario Kart Mode 7
investigation.

## 2026-07-04 session: SMK Mode 7 WORKS + master-cycle timing overhaul

- **Super Mario Kart races render correctly** (start grid, road,
  8 karts, course map - `test/movies/smk-mc1.zmov` frame 4310 matches
  Mesen2's scene). Three timing fixes did it, full story in
  DSP1-DEBUG-NOTES.md: per-access memory speeds (Bus.memSpeed 6/8/12 +
  FastROM), sub-instruction DSP ticking (Cpu.accountAccess), and the
  DSP-1's true rate (7.6MHz, one instruction per clock - not 2.048
  MIPS).
- **Mesen2 frame alignment collapsed from 14-26 frames per level load
  to +/-1..10 over a 2900-frame SMW run** (mode-transition table in the
  notes). Remaining gap: DMA setup overhead per channel, interrupt
  timing, mid-instruction PPU events - the rest of OPTIMIZATIONS.md.
- **Cold-boot state fixes** (found by WRAM-diffing against Mesen2):
  WRAM + SRAM now power on $FF-filled, port 2 reads as disconnected.
  SMK's menu now defaults to 1P GAME like hardware.
- **New cross-emulator tooling**: `screenshot --dump-wram`,
  `dbg.trace_watch` write watchpoint (+ `watch_dsp_writes`),
  test/mesen/make_screenshot_script.py (Mesen screenshot at frame N
  from a .zmov), test/mesen/bk2_to_zmov.py (BizHawk import, untested
  against a real .bk2 yet). Mesen2 needs Firmware/dsp1b.rom copied from
  test/dsp/ to run DSP games.
- **Real-TAS benchmark (task: run a published SMW TAS)**: converted
  the TASVideos SMW "warps" run (#4928, lsnes .lsmv - downloads via
  tasvideos.org/4928S?handler=Download; converter
  test/mesen/lsmv_to_zmov.py; ROM sha256 matches ours) and ran it in
  both emulators. zupernes: syncs through title/file-select/intro/
  overworld, enters Yoshi's Island 2 at frame 1624, and plays ~330
  frames of frame-perfect gameplay before missing the first bounce of
  the eight-Rex chain (death at f1830, x=$0194). Mesen2: desyncs
  EARLIER - its menu path diverges and it enters the wrong level
  (Yoshi's House) at f1799. Neither finishes: the movie is tuned to
  lsnes/bsnes-core timing. "zupernes frames-to-desync on the warps
  TAS" (currently 1830) is the new cycle-accuracy regression metric.
  (Converted movie not committed - TASVideos input data; regenerate
  with the converter.)
- **Continue next session**: (1) SMK race timer bar missing at top of
  screen; (2) SMW yi1-walk Mario sprite looks wrong at YI1 entry
  (f2990) - appear-pose or OAM regression? compare vs Mesen at same
  $13; (3) run a real SMW TAS (.bk2 from TASVideos userfile
  34596240540209273 - the BizHawk port of the warps run - importer is
  ready); (4) movies recorded before this session have shifted
  timing - re-record if they misbehave (yi1-walk still reaches YI1).

## Long-term goals (the vision, in rough order)

The core focus remains: **cycle, frame, and pixel accuracy first.**
Everything below builds on a correct emulator.

1. **TAS-format input recording/playback.** Record inputs to a file and
   play them back deterministically, frame by frame, exactly as on
   hardware. Use an established tool-assisted-speedrun format (not a
   custom one) so movies recorded here play back in other emulators and
   vice versa - BizHawk `.bk2` (a zip whose `Input Log.txt` is
   human-readable lines like `|..|UDLRsSYBXAlr|`) and/or Snes9x `.smv`
   are the candidates to evaluate. This subsumes the current ad-hoc
   `--input F:BTNS` flags.
2. **The self-playing demo:** once input recording and SMK's Mode 7 work,
   get an agent loop going that plays Super Mario Kart by examining
   frames, choosing buttons for the next frame(s), recording them, and
   iterating - then see how well it can do in a race. (The screenshot
   harness already supports look-at-frame; this adds record/extend/replay
   ergonomics.)
3. **Ultimate debugging tool.** A gdb-style CLI mode: breakpoints,
   single-stepping through ROM instructions, register/memory inspection.
   Plus sprite/tile/tilemap viewers in both command-line and visual forms.
   Game Genie / cheat code support is a stretch goal in this bucket.
4. **Library refactor ("libzupernes").** Restructure so the emulator core
   is a library with a single big amalgamated header you can drop into any
   project to embed a cycle-accurate SNES you can introspect frame by
   frame (the ghostty -> libghostty model). The CLI emulator/debugger
   becomes a client of that library.
5. **WebAssembly target** compiling the core to wasm for running the
   emulator in a browser.

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
