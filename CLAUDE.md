# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Zupernes is a SNES (Super Nintendo Entertainment System) emulator written in Zig, targeting macOS on Apple Silicon with Metal graphics.

**Tech Stack:**
- Language: Zig 0.15.2
- Graphics: sokol-zig (cross-platform with Metal backend)
- Platform: macOS Apple Silicon (Metal)

## Build Commands

```bash
zig build              # Build the project
zig build run          # Build and run emulator
zig build run -- <rom.sfc>  # Run with a ROM file
zig build test         # Run unit tests
zig build test-roms    # Run ROM test harness
```

## Architecture

### SNES Hardware Components to Emulate

1. **CPU (Ricoh 5A22)** - Custom 65816 processor
   - 16-bit accumulator and index registers (native mode)
   - 24-bit address bus (16MB address space via 256 banks of 64KB)
   - Starts in 6502 emulation mode, must switch to native mode via CLC + XCE
   - No multiply/divide instructions (handled by separate hardware)

2. **PPU (Picture Processing Unit)** - Two chips: PPU1 and PPU2
   - VRAM, CGRAM (palette), OAM (sprites)
   - 8 graphics modes (modes 0-7)
   - HDMA for scanline effects

3. **APU (Audio Processing Unit)** - Sony SPC700
   - Separate 8-bit processor with own RAM

4. **DMA/HDMA** - Direct Memory Access controllers

### Test Harness Strategy

The test ROMs output visual results. Our test harness should:
1. Run ROM in headless mode for N frames
2. Capture final framebuffer state
3. Compare against known-good reference screenshots (golden images)
4. Report pass/fail based on image diff threshold

## Repository Structure

- `test/snes-test-roms/` - Hardware accuracy test ROMs:
  - `scpu-a-dma-bug-*.sfc` - DMA timing bug tests
  - `hdma-*.sfc` - HDMA (H-blank DMA) glitch tests
  - `inidisp_*.sfc` - INIDISP ($2100) display register tests

## Key Resources

- [emudev.de SNES guide](https://emudev.de/q00-snes/65816-the-cpu/) - CPU emulation tutorials
- [wiki.superfamicom.org](https://wiki.superfamicom.org/65816-reference) - 65816 reference
- [undisbeliever.net opcodes](https://undisbeliever.net/snesdev/65816-opcodes.html) - Opcode pseudo-code
- [copetti.org SNES](https://www.copetti.org/writings/consoles/super-nintendo/) - Architecture analysis
- [SNESdev Wiki tests](https://snes.nesdev.org/wiki/Emulator_tests) - Test ROM resources
