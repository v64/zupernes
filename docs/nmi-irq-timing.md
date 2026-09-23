# NMI and IRQ timing

## Baseline and scope

Parent `60daac8` detected VBlank and H/V timer crossings only after a complete
`Cpu.step()`. Interrupts were polled before the next instruction, but every
edge crossed by an instruction was treated alike: CPU acceptance had no
pre-final-cycle sample, `$4210`/`$4211` accesses inside the instruction saw the
old beam state, IRQ asserted at `HTIME` rather than after the timer circuit's
output delay, and a `$4200` NMI enable during VBlank could not create an edge.

The completed stages retain the instruction-granular CPU while projecting the
CPU-visible interrupt circuitry to each 6/8/12-clock access and splitting the
committed PPU/APU advance at the interrupt sample before the instruction's
last CPU cycle. An edge before that sample is serviced at the next boundary;
an edge in the final cycle is retained and lets one more instruction execute.
This produces instruction-length-dependent jitter without allowing an
interrupt to be taken mid-instruction.

## Hardware rules and implementation

The timing model follows these references:

- [Anomie's SNES Timing Doc](https://github.com/naffnuff/SnesEmulator/blob/master/doc/Anomie%27s%20SNES%20Timing%20Doc)
  measures NMI low at VBlank H=0.5, IRQ output at `14 + HTIME*4`
  master clocks (`HTIME != 0`) or clock 10 for H=0/V-only, and the CPU check
  immediately before an instruction's final cycle. It also documents the old
  I-flag behavior of CLI, SEI, PLP, REP, and SEP and the two-cycle WAI wake.
- [fullsnes: SNES PPU Interrupts](https://problemkaputt.de/fullsnes.htm#snesppuinterrupts)
  documents the RDNMI/TIMEUP read-clear latches, the timer compare modes, the
  four-to-eight-clock TIMEUP set window, and the internal NMI edge when
  `$4200.7 AND $4210.7` changes from zero to one.
- Mesen2 independently models the RDNMI set at H-clock 2, prevents a read from
  clearing it until H-clock 6, delays the timer output after its counter
  comparison, and triggers NMI when enabled during VBlank
  ([InternalRegisters.h](https://github.com/SourMesen/Mesen2/blob/master/Core/SNES/InternalRegisters.h),
  [InternalRegisters.cpp](https://github.com/SourMesen/Mesen2/blob/master/Core/SNES/InternalRegisters.cpp)).

Implemented behavior:

| Circuit | Implemented timing |
| --- | --- |
| RDNMI set | V=225, two master clocks after H=0 (H=0.5) |
| RDNMI exact-edge read | Returns bit 7 set; cannot clear during the first four clocks, clears from H-clock 6 |
| NMI CPU edge | Rising edge of `$4200.7 AND RDNMI.7`, retained across a later RDNMI clear |
| CPU acceptance | Immediately before the final 6/8/12-clock CPU cycle |
| H/HV IRQ output | `14 + HTIME*4` clocks from target line start for nonzero HTIME |
| H=0/V-only IRQ output | Clock 10 of the target line |
| TIMEUP exact-edge read | Returns bit 7 set and cannot clear during the nominal four-clock output pulse |
| I-flag sample | CLI/SEI/PLP/REP/SEP use pre-final-cycle I; RTI/BRK/COP use their updated value |
| WAI wake | IRQ wakes even when I is set; two internal cycles / 12 master clocks before service or resume |
| Mid-VBlank enable | A zero-to-one `$4200.7` write immediately creates an NMI edge only while RDNMI remains set |

Savestate format 5 adds the late NMI edge latch, the IRQ set-hold deadline,
and the WAI resume countdown. Per-instruction IRQ transitions and NMI edge
timestamps are transient journals: every `Emulator.step()` consumes them
before a snapshot can be taken, so they are reset at the next instruction
rather than serialized.

## Staged validation (2026-08-23)

All test-ROM images used ReleaseFast executables and 120 frames. Super Mario
World used the seven-input, 2,900-frame script in `NEXTSTEPS.md`; its ROM was
read from the pinned live tree without modifying that tree.

### Baseline: `60daac8`

- `zig build test`: pass.
- `zig build test-roms`: 29/29 ran for 60 frames.
- Savestate resume on `hdma-2100-glitch-2ch-0a.sfc`: 60 resumed frames were
  byte-identical across all 555,568 state bytes.
- SMW WRAM SHA-256:
  `597aaad6015ea9272111a836bc023ac3d21d59daa0a3c6584a9f5806c29426a6`.
- SMW screenshot SHA-256:
  `ce5a479e62feb4c3017bd21620b2cab681f21adeaaef90abc15f29d19e831e2d`.

### Stage 1: NMI flag, read race, and boundary jitter (`6e84543`)

- Focused tests place the edge six clocks into a 16-clock instruction (before
  its sample) and ten clocks in (inside the final cycle); the latter executes
  one additional instruction before NMI entry.
- `zig build test`: pass; 29/29 ROMs ran and all 29 screenshots were
  byte-identical to `60daac8`.
- Savestate resume: byte-identical for 60 frames / 555,569 bytes.
- Both SMW hashes remained exactly equal to baseline; WRAM had no drift.

### Stage 2: timer output, I sampling, and WAI (`1bc1235`)

- Focused tests cover H IRQ at H=`HTIME+3.5`, V-only at H=2.5, the four-clock
  TIMEUP race, early/late instruction samples, CLI followed by SEI, and a
  masked IRQ waking WAI with a 12-clock resume delay.
- `zig build test`: pass; 29/29 ROMs ran. Twenty-eight screenshots were
  byte-identical to stage 1. `inidisp_enable_display_mid_frame` changed only
  five pixels at `(30,89)-(34,89)`, delaying its H-IRQ-driven display enable.
- Savestate resume: byte-identical for 60 frames / 555,578 bytes.
- Both SMW hashes remained exactly equal to baseline; WRAM had no drift.

### Stage 3: `$4200` enable during VBlank (`f4d4957`)

- Focused tests prove redundant enable writes do not retrigger, disable does
  not acknowledge RDNMI, a `$4210` read prevents a later enable edge, and an
  enable performed by the final cycle of `STA $4200` waits through the next
  instruction sample.
- `zig build test`: pass; 29/29 ROMs ran. Nineteen screenshots were
  byte-identical to stage 2. The ten changes are the IRQ image plus nine
  `scpu-a-dma-bug-*` images. Their upstream shared routine deliberately
  enables NMI before WAI and can do so with RDNMI already set
  ([pinned source](https://github.com/undisbeliever/snes-test-roms/blob/ac6ef8006809c0ff5dabc8ff137a4623967697fe/src/hardware-glitch-tests/scpu-a-dma-bug/dma-test.inc#L488-L510));
  the additional edge is the behavior under test, and the images remain the
  patterned test output rather than the ROM's half-bright crash screen.
- Savestate resume: byte-identical for 60 frames / 555,578 bytes.
- Both SMW hashes remained exactly equal to baseline; WRAM had no drift.

### Final timing-ROM impact versus `60daac8`

Nineteen final images are byte-identical. Bounding boxes are inclusive.

| ROM | Changed pixels | Bounding box | Final SHA-256 |
| --- | ---: | --- | --- |
| `inidisp_enable_display_mid_frame` | 10 | `(30,89)-(39,89)` | `0720f0986185d5e606a77669e3bd752d1999c056306d32fb11d8a3a490e2dfb9` |
| `scpu-a-dma-bug-1` | 35,328 | `(0,6)-(255,223)` | `89c6ec515c9611325f83193952f6bb31e27b3e5875471a8214f19fdf57515cb0` |
| `scpu-a-dma-bug-2` | 40,448 | `(0,2)-(255,223)` | `69cd1d8546e3464e70209923f976289c106f74a59860d8c1744bb98b9ab0914c` |
| `scpu-a-dma-bug-3` | 41,984 | `(0,2)-(255,223)` | `e96d32dec8a123a6e949ffabb175cce67ec80a9753dc19097dd7c77c347452d1` |
| `scpu-a-dma-bug-5` | 25,856 | `(0,2)-(255,220)` | `2dd06c6604e0ae99d50ead06be117222e4d12691bbec93fffa676fa573c15fc9` |
| `scpu-a-dma-bug-ch0` | 40,448 | `(0,2)-(255,223)` | `69cd1d8546e3464e70209923f976289c106f74a59860d8c1744bb98b9ab0914c` |
| `scpu-a-dma-bug-fix2` | 40,448 | `(0,2)-(255,223)` | `69cd1d8546e3464e70209923f976289c106f74a59860d8c1744bb98b9ab0914c` |
| `scpu-a-dma-bug-r2` | 35,328 | `(0,6)-(255,223)` | `89c6ec515c9611325f83193952f6bb31e27b3e5875471a8214f19fdf57515cb0` |
| `scpu-a-dma-bug-strange` | 35,328 | `(0,6)-(255,223)` | `89c6ec515c9611325f83193952f6bb31e27b3e5875471a8214f19fdf57515cb0` |
| `scpu-a-dma-bug-two-regs` | 20,224 | `(0,2)-(255,223)` | `b0e833b24d733101f8a5344fe74c96abf2ec76d6e3eb437bd85bc59816cf42f1` |

Final SMW evidence is byte-identical to `60daac8`, not merely visually equal:

- WRAM SHA-256:
  `597aaad6015ea9272111a836bc023ac3d21d59daa0a3c6584a9f5806c29426a6`.
- Screenshot SHA-256:
  `ce5a479e62feb4c3017bd21620b2cab681f21adeaaef90abc15f29d19e831e2d`.

## Scheduler boundary

The CPU still mutates one instruction per `Cpu.step()`. Access-visible
interrupt flags and service eligibility now use their correct projected
sub-instruction clocks, and WAI has its measured wake delay. The separate
known scheduler limitation remains for a CPU paused inside general DMA/HDMA:
exact pause-cycle alignment and Anomie's 24-30-clock post-general-DMA NMI
sequence require the same future mid-instruction scheduler already identified
in `docs/hdma-transfer-timing.md`; this stage does not claim that unrelated
DMA scheduler refinement.
