# ZuperNES

An SNES emulator vibe coded by Claude Opus 4.5 in Zig.

This project exists as both a functional emulator and a learning document—the code is heavily commented to explain how the Super Nintendo hardware actually works under the hood.

## Tech Stack

- **Language:** Zig 0.15.2
- **Graphics:** sokol-zig with Metal backend
- **Platform:** macOS Apple Silicon

## Current Features

### CPU (Ricoh 5A22 / 65816) - 95% Complete

- All 256 opcodes implemented
- Native and emulation mode switching (CLC + XCE)
- 24-bit address bus (16MB via 256 banks)
- 16-bit accumulator and index registers
- NMI/IRQ interrupt handling
- WAI instruction for CPU sleep
- Hardware multiply/divide units

### PPU (Picture Processing Unit) - 70% Complete

**Working Graphics Modes:**
| Mode | BG Layers | Status |
|------|-----------|--------|
| 0 | 4× 2bpp | Fully working |
| 1 | 2× 4bpp + 2bpp | Fully working (incl. BG3 priority extension) |
| 2-6 | Various | Main screen working |
| 7 | Affine transform | Not implemented |

**Rendering Features:**
- 2bpp, 4bpp, and 8bpp tile rendering
- 8×8 and 16×16 tile sizes
- 128 sprites with all size configurations
- Sprite flipping and 4 priority levels
- Complex sprite-to-background priority ordering
- Window masking (W1/W2) with OR/AND/XOR/XNOR logic
- Color math (addition/subtraction/half-color blending)
- Fixed color and subscreen blending
- Master brightness control (INIDISP)
- Main/sub screen designation

### APU (Audio Processing Unit) - 40% Complete

**SPC700 CPU:**
- All 255 opcodes implemented
- 8-bit registers (A, X, Y, SP) + 16-bit PC
- YA register pair for 16-bit operations
- 3 programmable timers
- 4 bidirectional I/O ports for CPU communication

**Not Working:**
- S-DSP (Digital Signal Processor) - no audio output yet
- BRR sample decompression

### DMA/HDMA - 95% Complete

- 8 independent DMA channels
- All 8 transfer patterns (modes 0-7)
- Increment/decrement/fixed address modes
- Bidirectional transfers (CPU↔PPU)
- Per-scanline HDMA for real-time effects
- Indirect addressing mode

### Memory & Cartridge

- 128KB WRAM
- LoROM cartridge format
- SRAM support for saves
- Complete memory mapping

### Debug Infrastructure

- Comprehensive CPU/PPU/APU/DMA tracing
- All debug code comptime-gated (zero overhead in release)
- Frame counter overlay
- Per-scanline state dumps

## What's Missing

### High Priority
- **Mode 7** - Affine transformation for rotation/scaling effects (F-Zero, Mario Kart, etc.)
- **Audio output** - S-DSP emulation for actual sound
- **Controller input** - Joypad not yet connected

### Medium Priority
- HiROM cartridge support
- Enhancement chip support (SuperFX, SA-1, DSP-1, etc.)
- PAL timing (currently NTSC only)
- Interlace modes

### Lower Priority
- Cycle-accurate timing for edge cases
- DMA/HDMA timing glitches
- Mouse/Super Scope support

## Building

```bash
# Build
zig build

# Run with ROM
zig build run -- path/to/game.sfc

# Run with debug output
zig build -Ddebug=true run -- path/to/game.sfc

# Run tests
zig build test
```

## Game Compatibility

The emulator can run many SNES games that use Modes 0-1 graphics without Mode 7 or audio requirements. Super Mario World's title screen renders correctly including the spotlight effect (HDMA-driven window masking).

Games requiring Mode 7 (F-Zero, Pilotwings, Super Mario Kart) will not display correctly.

## Project Philosophy

This emulator prioritizes:
1. **Readable, documented code** over micro-optimizations
2. **Learning and understanding** over compatibility percentages
3. **Comprehensive debug tooling** for development
4. **Clean architecture** that maps to real hardware

Every component is documented with explanations of what the real SNES hardware does and why.

## Resources

- [emudev.de SNES guide](https://emudev.de/q00-snes/65816-the-cpu/)
- [wiki.superfamicom.org](https://wiki.superfamicom.org/65816-reference)
- [copetti.org SNES Architecture](https://www.copetti.org/writings/consoles/super-nintendo/)
- [SNESdev Wiki](https://snes.nesdev.org/wiki/)
