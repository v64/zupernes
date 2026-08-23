# HDMA transfer timing

## Scope and measured deviation

Parent `189a823` initialized and ran HDMA only after `Ppu.tick()` crossed a
scanline boundary. A visible-line transfer therefore started near H=0 of the
line whose registers it changed. Hardware starts the transfer at H=278 of the
preceding line: the old call site was nominally 278 dots, or 1,112 master
clocks, early and assigned the write to the wrong render-journal line. Frame
initialization likewise ran at the V=0 transition instead of approximately
H=6, 24 master clocks early.

`Emulator.advancePpuWithHdma()` now splits the PPU/APU timeline at V=0/H=6 and
at H=278 on visible lines 0-224. It runs the synchronous HDMA operation at that
point, immediately advances the independent clocks through the stolen time,
and then resumes the elapsed CPU-instruction time. PPU writes continue through
`Bus.writePpuDma()` and `Ppu.writeRegister()`, so the existing render journal
receives the end-of-byte beam position on the correct absolute line.

The CPU core remains instruction-granular. It does not yet expose the
individual CPU-cycle boundary at which hardware pauses an instruction, so CPU
state mutation still completes as one `Cpu.step()` call while the PPU/APU
timeline is split at the hardware point. Exact pause alignment within an
instruction, and HDMA priority in the middle of a general-DMA byte stream,
remain scheduler refinements rather than claims of this stage.

## Timing charged

The implemented nominal costs are:

| Operation | Master clocks |
| --- | ---: |
| Frame initialization, any enabled channels | 18 |
| Frame initialization, direct channel | 8 |
| Frame initialization, indirect channel | 24 (8 + 16) |
| Visible-line operation, any active channels | 18 |
| Visible-line operation, each non-terminated channel | 8 |
| Reload an indirect address | 16 |
| Transfer one byte | 8 (pre-existing) |

The 18-clock values are documented as approximate hardware overhead; this
stage uses the nominal value rather than inventing an alignment formula. The
sources agree that initialization occurs near V=0/H=6, transfer begins at
H=278 (or just after the current CPU cycle), every active channel pays its
line overhead even when its repeat state suppresses a byte, and an indirect
pointer reload costs two additional byte fetches:

- [Anomie's SNES Timing Doc](https://github.com/naffnuff/SnesEmulator/blob/master/doc/Anomie%27s%20SNES%20Timing%20Doc)
- [fullsnes: SNES DMA and HDMA registers](https://problemkaputt.de/fullsnes.htm#snesdmaandhdmastartenableregisters)
- [SNESdev DMA register reference](https://snes.nesdev.org/wiki/DMA_registers)
- [Super Famicom Development Wiki: DMA & HDMA](https://wiki.superfamicom.org/dma-and-hdma)

Focused tests distinguish the costs by beam position. One direct frame init
starts at H=6 and ends at H=12.5 (18 + 8 clocks). A no-transfer direct line
starts at H=278 and ends at H=284.5 (18 + 8). One mode-0 direct byte is
journaled at H=286.5 (18 + 8 + 8). A no-transfer line that reloads an indirect
descriptor ends at H=288.5 (18 + 8 + 16).

## Staged validation (2026-08-23)

All screenshots used ReleaseFast executables and 120 frames for each of the 29
ROMs in `test/snes-test-roms`. Super Mario World used the seven-input,
2,900-frame script in `NEXTSTEPS.md` and the ROM was read from the pinned live
tree without modifying it.

### Baseline: `189a823`

- `zig build test`: pass.
- Savestate resume on `hdma-2100-glitch-2ch-0a.sfc`: byte-identical for 60
  resumed frames across all 555,568 serialized bytes.
- SMW WRAM SHA-256:
  `6171408c5de1dc1d7240ce9bcb44529995bb73869d110c96c094febb2dbb4533`.
- SMW screenshot SHA-256:
  `ce5a479e62feb4c3017bd21620b2cab681f21adeaaef90abc15f29d19e831e2d`.

### Stage 1: hardware beam points (`f0d49a4`)

- `zig build test`: pass.
- All 29 ROMs ran; 18 screenshots were byte-identical to `189a823` and the 11
  per-line INIDISP HDMA cases changed.
- Savestate resume: byte-identical for the same 60 frames / 555,568 bytes.
- SMW WRAM SHA-256:
  `b91adf43a4349a450b39ad65ea2e13a8e38d76c2034edb055769c47989acc5e9`.
  It differs from baseline only at physical WRAM `$01DD`, in the 65816 stack
  page; this is a stale stack-slot difference at the fixed frame cutoff.
- SMW screenshot SHA-256 stayed byte-identical:
  `ce5a479e62feb4c3017bd21620b2cab681f21adeaaef90abc15f29d19e831e2d`.

### Stage 2: HDMA overhead and indirect fetches

- `zig build test`: pass.
- All 29 ROMs ran; the same 18 screenshots are byte-identical to `189a823`.
  Relative to stage 1, only nine `scpu-a-dma-bug-*` stress images move; the
  two two-channel brightness images do not. This isolates cycle theft from
  the already-corrected H-blank line placement.
- Savestate resume: byte-identical for the same 60 frames / 555,568 bytes.
- SMW WRAM SHA-256:
  `597aaad6015ea9272111a836bc023ac3d21d59daa0a3c6584a9f5806c29426a6`.
  It differs from baseline only at `$01DD` and `$01E3-$01E5`, all in the
  65816 stack page; gameplay WRAM is byte-identical.
- SMW screenshot SHA-256 stayed byte-identical, so no focused crop was needed:
  `ce5a479e62feb4c3017bd21620b2cab681f21adeaaef90abc15f29d19e831e2d`.

### Final timing-ROM impact versus `189a823`

The changed images are exactly the ROMs whose visible result is driven by
per-line INIDISP HDMA. Bounding boxes are inclusive pixel coordinates.

| ROM | Changed pixels | Bounding box | Final SHA-256 |
| --- | ---: | --- | --- |
| `hdma-2100-glitch-2ch-0a` | 57,088 | `(0,1)-(255,223)` | `361da0698bc46ba950eb3c501534ad928d6e63fc4d3bcd9d414b9c8a5feb7bb1` |
| `hdma-2100-glitch-2ch-81` | 57,088 | `(0,1)-(255,223)` | `91c1c953ef937519c0c003611371965c1e3591954e2d89bf5e5bdfce1cdbeca9` |
| `scpu-a-dma-bug-1` | 25,600 | `(0,1)-(255,201)` | `a3e23d379fc2e4026aae1ef47de01de994e306ab65cf8b27fa7a0ed2837c7328` |
| `scpu-a-dma-bug-2` | 28,160 | `(0,2)-(255,220)` | `bd9854e03779f7138aad621562f4cd211dbcd019bccc440b67fc2c97193e7894` |
| `scpu-a-dma-bug-3` | 26,112 | `(0,1)-(255,200)` | `501c45cf65ba8429fe65400525205cf5a328913228465028aea55f9f982cb7f3` |
| `scpu-a-dma-bug-5` | 25,344 | `(0,1)-(255,217)` | `975bdc41205a815d5fda2a2a864f24df5c5490d658b60f2957f27531a7f257a5` |
| `scpu-a-dma-bug-ch0` | 28,160 | `(0,2)-(255,220)` | `bd9854e03779f7138aad621562f4cd211dbcd019bccc440b67fc2c97193e7894` |
| `scpu-a-dma-bug-fix2` | 28,160 | `(0,2)-(255,220)` | `bd9854e03779f7138aad621562f4cd211dbcd019bccc440b67fc2c97193e7894` |
| `scpu-a-dma-bug-r2` | 25,600 | `(0,1)-(255,201)` | `a3e23d379fc2e4026aae1ef47de01de994e306ab65cf8b27fa7a0ed2837c7328` |
| `scpu-a-dma-bug-strange` | 25,600 | `(0,1)-(255,201)` | `a3e23d379fc2e4026aae1ef47de01de994e306ab65cf8b27fa7a0ed2837c7328` |
| `scpu-a-dma-bug-two-regs` | 27,648 | `(0,2)-(255,220)` | `703044adae8ed304f10e035fb44d73fcb0b8649b217c489b556e0077eda7be30` |

The remaining 18 timing-ROM screenshots are byte-identical to the baseline.
Moving these effects by one scanline is hardware-correct: H=278 is after the
active pixels of the current line, so the new register state is carried into
the following visible line instead of being applied retroactively at its H=0
transition.
