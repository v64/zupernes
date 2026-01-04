# SNES HDMA Window Effects

Sources:
- https://snes.nesdev.org/wiki/HDMA_examples
- https://snes.nesdev.org/wiki/Drawing_window_shapes
- https://sneslab.net/wiki/HDMA
- https://wiki.superfamicom.org/grog's-guide-to-dma-and-hdma-on-the-snes

## Overview

HDMA (H-Blank Direct Memory Access) performs one transfer during each horizontal blanking period,
enabling per-scanline effects like gradient fills and dynamic window masks. Unlike standard DMA
which halts the CPU immediately, HDMA allows concurrent operation.

## Window Registers

The SNES has two windows that can mask BG/OBJ layers. Window positions are set by:

- **$2126 (WH0)** - Window 1 Left Position (X1)
- **$2127 (WH1)** - Window 1 Right Position (X2)
- **$2128 (WH2)** - Window 2 Left Position
- **$2129 (WH3)** - Window 2 Right Position

The "inside-window" region extends from X1 to X2 (inclusive), so window width is X2-X1+1.
If width is zero or negative, the entire screen is treated as "outside-window".

**Note:** There are NO vertical window boundaries - these must be implemented via HDMA
by changing window positions on each scanline.

## Window Masking Registers

- **$2123 (W12SEL)** - Window Mask Settings for BG1/BG2
- **$2124 (W34SEL)** - Window Mask Settings for BG3/BG4
- **$2125 (WOBJSEL)** - Window Mask Settings for OBJ/Color
- **$212A (WBGLOG)** - Window 1/2 Mask Logic for BG1-4
- **$212B (WOBJLOG)** - Window 1/2 Mask Logic for OBJ/Color
- **$212E (TMW)** - Window Mask Designation for Main Screen
- **$212F (TSW)** - Window Mask Designation for Sub Screen

## HDMA Table Format

The HDMA table consists of entries:

**LineCount Byte (N):**
- Values 1-127: Write once, then skip N-1 lines
- Values 128-255 ($80-$FF): Write every HBlank for (N & $7F) lines
- $80: Write every HBlank for 128 lines
- $00: Terminates the table

**Data Bytes:**
Number depends on HDMA mode (1, 2, or 4 bytes).

Example:
```assembly
; Mode 1 (2 bytes): write to WH0 and WH1
.db $01, $40, $C0    ; 1 line: left=$40, right=$C0
.db $81, $38, $C8    ; 1 line repeat: left=$38, right=$C8
.db $81, $30, $D0    ; 1 line repeat: left=$30, right=$D0
; ... continues for each scanline
.db $00              ; End table
```

## HDMA Transfer Modes (DMAPx bits 0-2)

- **000**: 1 byte → $21XX
- **001**: 2 bytes → $21XX, $21XX+1 (perfect for WH0+WH1)
- **010**: 2 bytes → $21XX, $21XX (same register twice)
- **011**: 4 bytes → $21XX (2x), $21XX+1 (2x)
- **100**: 4 bytes → $21XX, $21XX+1, $21XX+2, $21XX+3 (all 4 window regs)

## Creating Spotlight/Circle Effects

For SMW's title screen circle effect:
1. HDMA channel 7 writes to WH0 ($2126) and WH1 ($2127) using mode 1
2. Each scanline, the HDMA table specifies left/right window positions
3. For a circle centered at (cx, cy) with radius r:
   - At scanline y, calculate: dx = sqrt(r² - (y-cy)²)
   - Left position = cx - dx
   - Right position = cx + dx
4. Areas outside the window are masked (show black or backdrop)
5. As the circle radius grows each frame, more of the title screen is revealed

## HDMA Register Setup

| Register | Function |
|----------|----------|
| $420C | HDMA Enable (bit per channel 0-7) |
| $43x0 | DMAPx - DMA/HDMA Parameters |
| $43x1 | BBADx - PPU register (low byte, ORed with $2100) |
| $43x2-4 | A1Tx - 24-bit HDMA table address |
| $43x5-6 | DASx - Indirect HDMA address (modes with indirect bit) |
| $43x7 | DASBx - Indirect bank |

## SMW Circle Effect Implementation

From the SMW disassembly, the circle effect:
1. Uses HDMA channel 7 ($80 = bit 7 set in $0D9F/$420C)
2. Builds table at $04A0 in WRAM
3. Uses $1433 as the "circle size" variable (grows by 4 each frame)
4. Calculates window positions per scanline using CircleCoords lookup table at $07F7DB
5. When $1433 >= $F0, the circle is fully open and transitions to title screen

The HDMA table format for SMW's circle:
- Each entry is 2 bytes: [scanline_count] [left_pos, right_pos]
- Uses repeat mode ($80+) to write every scanline
- Window positions calculated from circle radius and scanline distance from center
