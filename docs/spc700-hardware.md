# SPC700 Audio Processor Technical Reference

Source: https://emudev.de/q00-snes/spc700-the-audio-processor/

## Overview

The SNES APU (Audio Processing Unit) consists of:
- **S-SMP**: Contains the SPC700 CPU (1.024 MHz, 8-bit)
- **S-DSP**: 8-channel digital signal processor (32 kHz, 16-bit audio)
- **64KB PSRAM**: Shared between SPC700 and DSP
- **IPL ROM**: 64-byte boot ROM for initial program loading

The SPC700 runs completely separate from the 65816 main CPU and handles all audio
processing independently after the sound driver is uploaded.

## Registers

| Register | Width | Purpose |
|----------|-------|---------|
| A | 8-bit | Accumulator |
| X, Y | 8-bit | Index registers |
| SP | 8-bit | Stack pointer (page 1: $0100-$01FF) |
| PC | 16-bit | Program counter |
| PSW | 8-bit | Program status word (flags) |

## Program Status Word (PSW) Flags

```
Bit:  7   6   5   4   3   2   1   0
      N   V   P   B   H   I   Z   C
```

| Bit | Flag | Name | Description |
|-----|------|------|-------------|
| 7 | N | Negative | Set if result bit 7 is set |
| 6 | V | Overflow | Set on signed overflow |
| 5 | P | Direct Page | Selects direct page ($00 or $01) |
| 4 | B | Break | Set by BRK instruction |
| 3 | H | Half-carry | Set on carry from bit 3 to 4 |
| 2 | I | Interrupt | Interrupt enable (unused on SNES) |
| 1 | Z | Zero | Set if result is zero |
| 0 | C | Carry | Set on unsigned overflow/borrow |

## Memory Map

```
$0000-$00EF  Direct Page (when P=0) / Zero Page RAM
$00F0-$00FF  Hardware I/O Registers
$0100-$01FF  Stack Page
$0200-$FFBF  General Purpose RAM
$FFC0-$FFFF  IPL Boot ROM (or RAM when disabled)
```

## I/O Registers ($F0-$FF)

| Address | R/W | Name | Description |
|---------|-----|------|-------------|
| $F0 | W | TEST | Undocumented test register |
| $F1 | W | CONTROL | Timer/IPL/Port control |
| $F2 | RW | DSPADDR | DSP register address |
| $F3 | RW | DSPDATA | DSP register data |
| $F4 | RW | PORT0 | CPU I/O port 0 |
| $F5 | RW | PORT1 | CPU I/O port 1 |
| $F6 | RW | PORT2 | CPU I/O port 2 |
| $F7 | RW | PORT3 | CPU I/O port 3 |
| $F8 | RW | - | Normal RAM |
| $F9 | RW | - | Normal RAM |
| $FA | W | T0TARGET | Timer 0 target |
| $FB | W | T1TARGET | Timer 1 target |
| $FC | W | T2TARGET | Timer 2 target |
| $FD | R | T0OUT | Timer 0 output (4-bit) |
| $FE | R | T1OUT | Timer 1 output (4-bit) |
| $FF | R | T2OUT | Timer 2 output (4-bit) |

### CONTROL Register ($F1)

```
Bit:  7   6   5   4   3   2   1   0
      R   -   B   A   -   T2  T1  T0
```

| Bit | Name | Description |
|-----|------|-------------|
| 7 | R | IPL ROM enable (1=ROM at $FFC0, 0=RAM) |
| 5 | B | Clear ports $F6-$F7 (write 1 to clear) |
| 4 | A | Clear ports $F4-$F5 (write 1 to clear) |
| 2 | T2 | Timer 2 enable |
| 1 | T1 | Timer 1 enable |
| 0 | T0 | Timer 0 enable |

### CPU I/O Ports ($F4-$F7)

These are **bidirectional** with separate read/write buffers:

**From SPC700 perspective:**
- Reading $F4-$F7 returns what the **main CPU wrote** to $2140-$2143
- Writing $F4-$F7 sets what the **main CPU will read** from $2140-$2143

**From Main CPU perspective:**
- Reading $2140-$2143 returns what the **SPC700 wrote** to $F4-$F7
- Writing $2140-$2143 sets what the **SPC700 will read** from $F4-$F7

This allows both processors to communicate simultaneously without bus conflicts.

## Timers

The SPC700 has three independent timers with different base rates:

| Timer | Base Rate | Frequency | Use Case |
|-------|-----------|-----------|----------|
| T0 | 128 cycles | ~8,000 Hz | General timing |
| T1 | 128 cycles | ~8,000 Hz | General timing |
| T2 | 16 cycles | ~64,000 Hz | High-precision timing |

### Timer Operation

Each timer has three stages:

1. **Stage 1**: Internal divider (always counting at base rate)
2. **Stage 2**: 8-bit counter, increments when Stage 1 overflows AND timer enabled
3. **Stage 3**: 4-bit output counter, increments when Stage 2 == TnTARGET

Reading TnOUT returns the 4-bit output and clears it to 0.
A TnTARGET value of $00 means count to 256.

## IPL Boot ROM

The 64-byte IPL ROM at $FFC0-$FFFF handles the initial CPU-APU handshake:

```
$FFC0: CD EF     MOV X, #$EF        ; X = $EF (stack pointer)
$FFC2: BD        MOV SP, X          ; Set stack
$FFC3: E8 00     MOV A, #$00        ; A = 0
$FFC5: C6        MOV (X), A         ; Clear RAM at (X)
$FFC6: 1D        DEC X              ; X--
$FFC7: D0 FC     BNE $FFC5          ; Loop until X wraps
$FFC9: 8F AA F4  MOV $F4, #$AA      ; Write $AA to port 0 (ready signal)
$FFCC: 8F BB F5  MOV $F5, #$BB      ; Write $BB to port 1 (ready signal)
$FFCF: 78 CC F4  CMP $F4, #$CC      ; Wait for CPU to write $CC
$FFD2: D0 FB     BNE $FFCF          ; Loop until $CC received
...
```

### Boot Protocol

1. SPC700 clears RAM ($00-$EF)
2. SPC700 writes $AA to port 0, $BB to port 1 (ready signal)
3. Main CPU waits for $AA/$BB, then writes $CC to port 0
4. SPC700 sees $CC, echoes it back, begins receiving data
5. Data blocks are transferred with address/size headers
6. Final block with address in $FFC0-$FFFF triggers jump to entry point

## Sound Driver Main Loop

After upload, the sound driver typically runs a main loop that:

1. Polls port 0 ($F4) for new commands from CPU
2. Compares with last command value to detect changes
3. If same value, loops back (no new command)
4. If different, processes the command

**Example polling loop pattern (Super Mario World at $0549):**
```asm
MainLoop:
    $0549: MOV Y, !$00F4   ; Read port 0 into Y ($EC opcode)
    $054C: BEQ MainLoop    ; If zero, no command, keep waiting ($F0 opcode)
    ; Process command...
```

**IMPORTANT:** When the sound driver is "stuck" in this BEQ loop, it is
actually working correctly! This is the driver's idle state waiting for
the main CPU to send audio commands via $2140. The driver will exit this
loop when the game writes a non-zero value to port 0.

Debug trace example showing correct idle behavior:
```
[SPC] $0549: $ec A=$00 X=$02 Y=$00 SP=$cf PSW=$0a  ; MOV Y, !$00F4
[SPC] $054c: $f0 A=$00 X=$02 Y=$00 SP=$cf PSW=$0a  ; BEQ (Z=1, loops)
```
PSW=$0A means Z=1 (zero flag set), so BEQ branches back to $0549.

## DSP Interface

The DSP is accessed indirectly through $F2/$F3:

1. Write DSP register number to $F2 (DSPADDR)
2. Read/write DSP data through $F3 (DSPDATA)

The DSP has 128 registers controlling 8 voices, effects, and mixing.
