# Mid-scanline PPU register replay

## Scope

The CPU still executes one instruction at a time and the PPU still renders a
scanline after the beam has crossed it. Render-control writes are now journaled
at their projected end-of-access beam position, however, so deferred rendering
can reconstruct each constant-register horizontal span instead of sampling the
final register state once for the whole line.

The journal captures decoded state after a write. This is important for the
write-twice BG/Mode 7 scroll latches and component-select COLDATA writes: replay
does not perform the raw register write a second time or disturb CPU-visible
latches. CPU accesses use their cumulative 6/8/12-master-clock timings, and DMA
adds eight master clocks per byte. Events projected across a scanline or frame
boundary use a monotonic absolute line number.

OAM, VRAM, and CGRAM address/data ports are intentionally outside this stage.
Their active-display behavior involves memory-port contention, redirection, and
corruption rather than only replaying a render latch. Hardware-specific
one/few-dot register latch delays are also not modeled: all covered registers
currently share the low-resolution active-display boundary at PPU dot 22.
Likewise, HDMA still runs at the emulator's existing scanline-transition point;
moving it to the hardware H-blank position remains scheduler/HDMA-timing work.

The line-start state, queued events, dropped-event diagnostic, and transient
write offset are explicit savestate fields. Savestate format version 3 therefore
rejects older layouts rather than restoring a journal-less mid-frame state.

## Validation (2026-08-23)

All captures below used ReleaseFast executables built from parent `9b5270c`
(before) and the completed `mid-scanline` tree (after). Test-ROM screenshots
were captured after 120 frames.

- `zig build test`: pass.
- `zig build test-roms`: 29/29 ROMs ran for 60 frames. The existing harness
  still reports its leaked result-name allocations and does not compare golden
  images, so this is a crash/run check only.
- `savestate-verify` on `hdma-2100-glitch-2ch-0a.sfc`, 120 frames with a
  frame-60 restore: byte-identical for 60 resumed frames across all 555,568
  serialized bytes.
- 2900-frame Super Mario World run with the exact NEXTSTEPS input sequence:
  before/after WRAM dumps are byte-identical, SHA-256
  `6171408c5de1dc1d7240ce9bcb44529995bb73869d110c96c094febb2dbb4533`.
  Screenshots are also byte-identical, SHA-256
  `ce5a479e62feb4c3017bd21620b2cab681f21adeaaef90abc15f29d19e831e2d`.

### Corpus impact inventory

Of 29 ROMs in `test/snes-test-roms`, 17 final screenshots are byte-identical.
The 12 changes are confined to ROMs that deliberately write INIDISP during the
visible field:

| ROM | Changed pixels | Bounding box | Interpretation |
| --- | ---: | --- | --- |
| `hdma-2100-glitch-2ch-0a` | 57,088 (99.55%) | `(0,1)-(255,223)` | HDMA brightness on 223 visible rows |
| `hdma-2100-glitch-2ch-81` | 57,088 (99.55%) | `(0,1)-(255,223)` | HDMA brightness on 223 visible rows |
| `inidisp_enable_display_mid_frame` | 226 (0.39%) | `(30,89)-(255,89)` | IRQ handler enables the remainder of one line |
| `scpu-a-dma-bug-1` | 25,600 (44.64%) | `(0,5)-(255,223)` | Per-line INIDISP HDMA table |
| `scpu-a-dma-bug-2` | 12,800 (22.32%) | `(0,5)-(255,222)` | Per-line INIDISP HDMA table |
| `scpu-a-dma-bug-3` | 7,936 (13.84%) | `(0,12)-(255,222)` | Per-line INIDISP HDMA table |
| `scpu-a-dma-bug-5` | 4,864 (8.48%) | `(0,19)-(255,222)` | Per-line INIDISP HDMA table |
| `scpu-a-dma-bug-ch0` | 12,800 (22.32%) | `(0,5)-(255,222)` | Per-line INIDISP HDMA table |
| `scpu-a-dma-bug-fix2` | 12,800 (22.32%) | `(0,5)-(255,222)` | Per-line INIDISP HDMA table |
| `scpu-a-dma-bug-r2` | 25,600 (44.64%) | `(0,5)-(255,223)` | Repeating INIDISP HDMA table |
| `scpu-a-dma-bug-strange` | 25,600 (44.64%) | `(0,5)-(255,223)` | Repeating INIDISP HDMA table |
| `scpu-a-dma-bug-two-regs` | 12,288 (21.43%) | `(0,5)-(255,222)` | Two-register HDMA beginning at INIDISP |

The other 17 ROMs have no changed pixels. In particular, the force-blank
hammer/early-read glitch ROMs remain unchanged because this stage replays the
value the emulator received; it does not emulate the separate PPU early-data-
bus-read or analog brightness-delay hardware bugs.
