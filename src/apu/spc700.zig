// =============================================================================
// SPC700 - SNES AUDIO PROCESSING UNIT CPU
// =============================================================================
// The SPC700 is the CPU inside the SNES Audio Processing Unit (APU), officially
// called the S-SMP (Sony Sound and Music Processor). It's an independent 8-bit
// processor that runs audio code completely separately from the main 65816 CPU.
//
// ARCHITECTURE OVERVIEW:
// -----------------------------------------------------------------------------
// - 8-bit CPU running at 1.024 MHz (2.048 MHz clock, 2 clocks per cycle)
// - 64KB dedicated audio RAM (shared with DSP for sample data)
// - 64-byte IPL Boot ROM at $FFC0-$FFFF (can be mapped out after boot)
// - 8-channel S-DSP (Digital Signal Processor) for audio synthesis
// - 3 programmable timers
// - 4 bidirectional I/O ports for communication with main CPU
//
// The SPC700 design is similar to the 6502 but with significant extensions:
// - Direct page can be relocated (page $00 or $01 via P flag)
// - 16-bit YA register pair for 16-bit operations
// - Hardware multiply/divide instructions
// - Bit manipulation instructions
// - Enhanced loop/branch instructions (CBNE, DBNZ)
//
// REFERENCES:
// -----------------------------------------------------------------------------
// - https://wiki.superfamicom.org/spc700-reference
// - https://snes.nesdev.org/wiki/SPC-700_instruction_set
// - https://emudev.de/q00-snes/spc700-the-audio-processor/
// - https://www.copetti.org/writings/consoles/super-nintendo/
// =============================================================================

const std = @import("std");
const dbg = @import("../debug.zig");
const Dsp = @import("dsp.zig").Dsp;

// =============================================================================
// SPC700 REGISTERS
// =============================================================================
// The SPC700 has a small register set, similar to the 6502:
//
//   A  - 8-bit Accumulator: Primary arithmetic/logic register
//   X  - 8-bit Index X: Used for indexing and loops
//   Y  - 8-bit Index Y: Used for indexing; pairs with A as "YA" for 16-bit ops
//   SP - 8-bit Stack Pointer: Points into page 1 ($0100-$01FF)
//   PC - 16-bit Program Counter: Current instruction address
//   PSW - 8-bit Program Status Word: CPU flags
//
// SPECIAL REGISTER COMBINATIONS:
// -----------------------------------------------------------------------------
// YA - 16-bit register pair (Y=high byte, A=low byte)
//      Used by: MOVW, ADDW, SUBW, CMPW, INCW, DECW, MUL, DIV
//
// Unlike the 65816, there are NO 16-bit modes - the SPC700 is purely 8-bit
// with explicit 16-bit instructions when needed.
// =============================================================================

// =============================================================================
// PROGRAM STATUS WORD (PSW) FLAGS
// =============================================================================
// The PSW register contains 8 flags that control CPU operation and reflect
// the results of operations:
//
//   Bit 7 - N (Negative): Set if result's bit 7 is 1
//   Bit 6 - V (Overflow): Set on signed arithmetic overflow
//   Bit 5 - P (Direct Page): 0 = page $00, 1 = page $01
//   Bit 4 - B (Break): Set by BRK instruction (similar to 6502)
//   Bit 3 - H (Half-Carry): Set on carry from bit 3 to bit 4 (for BCD)
//   Bit 2 - I (Interrupt Enable): UNUSED on SNES - interrupts not implemented
//   Bit 1 - Z (Zero): Set if result is zero
//   Bit 0 - C (Carry): Set on unsigned overflow/borrow
//
// FLAG MANIPULATION:
// -----------------------------------------------------------------------------
// C flag: SETC, CLRC, NOTC, and affected by arithmetic/rotate ops
// V flag: Cannot be set directly, only by arithmetic; CLRV clears both V and H
// H flag: Cannot be set directly, only by arithmetic; CLRV clears both V and H
// P flag: SETP, CLRP (affects direct page addressing)
// I flag: EI, DI (no effect on SNES - no external interrupts)
// =============================================================================

/// PSW flag bit positions
pub const PSW = struct {
    pub const N: u8 = 0x80; // Negative
    pub const V: u8 = 0x40; // Overflow
    pub const P: u8 = 0x20; // Direct Page select
    pub const B: u8 = 0x10; // Break
    pub const H: u8 = 0x08; // Half-carry
    pub const I: u8 = 0x04; // Interrupt enable (unused)
    pub const Z: u8 = 0x02; // Zero
    pub const C: u8 = 0x01; // Carry
};

// =============================================================================
// MEMORY MAP
// =============================================================================
// The SPC700 has a 16-bit address space (64KB), organized as follows:
//
//   $0000-$00EF  - Page 0 (Zero Page / Direct Page when P=0)
//                  Fast single-byte addressing
//
//   $00F0-$00FF  - Hardware I/O Registers
//                  See I/O REGISTERS section below
//
//   $0100-$01FF  - Page 1 (Stack / Direct Page when P=1)
//                  Stack pointer (SP) indexes into this page
//                  Also used as direct page when P flag = 1
//
//   $0200-$FFBF  - General Purpose RAM
//                  Used for sound driver code and sample data
//                  DSP reads sample data from here
//
//   $FFC0-$FFFF  - IPL Boot ROM / RAM
//                  At boot: Contains 64-byte IPL ROM
//                  After boot: Can be remapped to show underlying RAM
//                  Controlled by bit 7 of $F1 (CONTROL register)
//
// MEMORY WRAPPING:
// -----------------------------------------------------------------------------
// - Execution wraps from $FFFF to $0000
// - Direct page accesses wrap within the selected page ($00 or $01)
// - Stack always wraps within page 1 ($0100-$01FF)
// =============================================================================

// =============================================================================
// I/O REGISTERS ($00F0-$00FF)
// =============================================================================
// The SPC700 has 16 I/O registers mapped at $F0-$FF. These control timers,
// DSP access, CPU-APU communication, and system configuration.
//
//   $F0 - TEST: Undocumented test register (don't touch)
//
//   $F1 - CONTROL: System control register
//         Bit 7: IPL ROM enable (1=ROM visible at $FFC0-$FFFF, 0=RAM visible)
//         Bit 6-5: Unused
//         Bit 4: Reset ports 2&3 input latches (write 1 to clear)
//         Bit 3: Reset ports 0&1 input latches (write 1 to clear)
//         Bit 2: Timer 2 enable
//         Bit 1: Timer 1 enable
//         Bit 0: Timer 0 enable
//
//   $F2 - DSPADDR: DSP register address
//         Write the DSP register number here before accessing $F3
//
//   $F3 - DSPDATA: DSP register data
//         Read/write the DSP register selected by $F2
//         Both $F2 and $F3 can be written in a single 16-bit store
//
//   $F4 - PORT0: I/O Port 0 (CPU communication)
//   $F5 - PORT1: I/O Port 1 (CPU communication)
//   $F6 - PORT2: I/O Port 2 (CPU communication)
//   $F7 - PORT3: I/O Port 3 (CPU communication)
//         Each port has separate input and output latches:
//         - Reading returns what the main CPU wrote to $2140+n
//         - Writing sets the value the main CPU reads from $2140+n
//
//   $F8 - AUXIO4: Auxiliary I/O (normal RAM, no special function)
//   $F9 - AUXIO5: Auxiliary I/O (normal RAM, no special function)
//
//   $FA - T0DIV: Timer 0 divisor (write-only)
//   $FB - T1DIV: Timer 1 divisor (write-only)
//   $FC - T2DIV: Timer 2 divisor (write-only)
//         When timer counter reaches this value, it resets and
//         increments the corresponding output counter.
//         Value 0 is treated as 256.
//
//   $FD - T0OUT: Timer 0 output counter (read-only, clears on read)
//   $FE - T1OUT: Timer 1 output counter (read-only, clears on read)
//   $FF - T2OUT: Timer 2 output counter (read-only, clears on read)
//         4-bit counters (0-15), increment when timer fires
//         Reading returns the count and resets it to 0
// =============================================================================

pub const IoReg = struct {
    pub const TEST: u8 = 0xF0; // Test register (don't use)
    pub const CONTROL: u8 = 0xF1; // System control
    pub const DSPADDR: u8 = 0xF2; // DSP address
    pub const DSPDATA: u8 = 0xF3; // DSP data
    pub const PORT0: u8 = 0xF4; // I/O port 0
    pub const PORT1: u8 = 0xF5; // I/O port 1
    pub const PORT2: u8 = 0xF6; // I/O port 2
    pub const PORT3: u8 = 0xF7; // I/O port 3
    pub const AUXIO4: u8 = 0xF8; // Auxiliary I/O 4
    pub const AUXIO5: u8 = 0xF9; // Auxiliary I/O 5
    pub const T0DIV: u8 = 0xFA; // Timer 0 divisor
    pub const T1DIV: u8 = 0xFB; // Timer 1 divisor
    pub const T2DIV: u8 = 0xFC; // Timer 2 divisor
    pub const T0OUT: u8 = 0xFD; // Timer 0 output
    pub const T1OUT: u8 = 0xFE; // Timer 1 output
    pub const T2OUT: u8 = 0xFF; // Timer 2 output
};

// =============================================================================
// TIMER SYSTEM
// =============================================================================
// The SPC700 has three independent timers useful for tempo control:
//
// TIMER FREQUENCIES:
// -----------------------------------------------------------------------------
// - Timer 0 & 1: Run at 8 kHz (128 CPU cycles per tick, 1.024 MHz / 128)
// - Timer 2: Runs at 64 kHz (16 CPU cycles per tick, 1.024 MHz / 64)
//
// Timer 2 is 8x faster, useful for precise timing.
//
// TIMER OPERATION:
// -----------------------------------------------------------------------------
// Each timer has three components:
//
// 1. Internal Cycle Counter (not directly accessible)
//    - Counts CPU cycles (128 for T0/T1, 16 for T2)
//    - When it reaches the threshold, the prescaler increments
//
// 2. Prescaler Counter (internal, 8-bit)
//    - Counts from 0 to TnDIV value (or 256 if TnDIV=0)
//    - When it matches TnDIV, the output counter increments
//
// 3. Output Counter (TnOUT at $FD-$FF, 4-bit, read-only)
//    - Counts from 0 to 15
//    - Reading returns the value AND resets it to 0
//    - Overflows silently if not read in time
//
// ENABLING TIMERS:
// -----------------------------------------------------------------------------
// Timers are enabled via CONTROL register ($F1) bits 0-2.
// Writing 1 to enable bit starts the timer AND resets all its counters.
// Writing 0 to enable bit stops the timer but preserves counts.
//
// TYPICAL USE:
// -----------------------------------------------------------------------------
// Sound drivers use timers for tempo:
//   - Set T0DIV to control tick rate
//   - Enable timer 0
//   - Poll T0OUT and process when non-zero
//   - Each read automatically clears the counter
// =============================================================================

// =============================================================================
// DSP INTERFACE
// =============================================================================
// The S-DSP (Sony Digital Signal Processor) handles audio synthesis.
// It's accessed indirectly through $F2 (address) and $F3 (data).
//
// DSP REGISTER MAP (128 registers, $00-$7F):
// -----------------------------------------------------------------------------
// Per-voice registers (8 voices, x = voice number 0-7):
//   ${x}0 - VOL_L: Left channel volume (-128 to +127)
//   ${x}1 - VOL_R: Right channel volume (-128 to +127)
//   ${x}2 - PITCH_L: Pitch low byte (14-bit pitch, lower 8 bits)
//   ${x}3 - PITCH_H: Pitch high byte (upper 6 bits)
//   ${x}4 - SRCN: Sample source number (0-255, indexes source directory)
//   ${x}5 - ADSR1: ADSR envelope settings 1
//   ${x}6 - ADSR2: ADSR envelope settings 2
//   ${x}7 - GAIN: Manual envelope control (when ADSR disabled)
//   ${x}8 - ENVX: Current envelope value (read-only, updated by DSP)
//   ${x}9 - OUTX: Current waveform output (read-only, updated by DSP)
//
// Global registers:
//   $0C - MVOL_L: Main volume left
//   $1C - MVOL_R: Main volume right
//   $2C - EVOL_L: Echo volume left
//   $3C - EVOL_R: Echo volume right
//   $4C - KON: Key on (write 1 to start voices)
//   $5C - KOF: Key off (write 1 to release voices)
//   $6C - FLG: Flags (reset, mute, echo, noise clock)
//   $7C - ENDX: Voice end flags (read-only, bit set when sample ends)
//
// Echo registers:
//   $0D - EFB: Echo feedback volume
//   $2D - PMON: Pitch modulation enable (per-voice bits)
//   $3D - NON: Noise enable (per-voice bits)
//   $4D - EON: Echo enable (per-voice bits)
//   $5D - DIR: Sample directory page ($xx00 in APU RAM)
//   $6D - ESA: Echo buffer start address ($xx00 in APU RAM)
//   $7D - EDL: Echo delay (0-15, each unit = 16ms, 2KB of RAM)
//
// FIR filter coefficients (for echo):
//   $0F, $1F, $2F, $3F, $4F, $5F, $6F, $7F - COEF0-7
//
// SAMPLE PLAYBACK:
// -----------------------------------------------------------------------------
// 1. Load sample data (BRR compressed) into APU RAM
// 2. Set up source directory at (DIR * 256)
//    - Each entry is 4 bytes: start_addr (16-bit), loop_addr (16-bit)
// 3. Set voice's SRCN to point to directory entry
// 4. Set PITCH for playback rate (0x1000 = 32kHz base rate)
// 5. Configure ADSR or GAIN envelope
// 6. Write to KON to start playback
//
// BRR COMPRESSION:
// -----------------------------------------------------------------------------
// BRR (Bit Rate Reduction) compresses 16 samples into 9 bytes:
// - 1 byte header: range (4 bits), filter (2 bits), loop flag, end flag
// - 8 bytes data: 16 nibbles, each a signed delta value
// =============================================================================

// =============================================================================
// ADDRESSING MODES
// =============================================================================
// The SPC700 supports various addressing modes, similar to 6502 with additions:
//
// IMMEDIATE: #imm
//   Operand is the next byte in instruction stream
//   Example: MOV A,#$12   ; A = $12
//
// DIRECT PAGE: dp
//   Operand is at address (P_flag ? $0100 : $0000) + next_byte
//   Single byte addressing into page 0 or page 1
//   Example: MOV A,$10    ; A = memory[direct_page + $10]
//
// DIRECT PAGE INDEXED: dp+X, dp+Y
//   Address is direct_page + operand + index register
//   Wraps within the direct page
//   Example: MOV A,$10+X  ; A = memory[direct_page + $10 + X]
//
// ABSOLUTE: !abs
//   Full 16-bit address
//   Example: MOV A,!$1234 ; A = memory[$1234]
//
// ABSOLUTE INDEXED: !abs+X, !abs+Y
//   Full 16-bit address plus index register
//   Example: MOV A,!$1234+X ; A = memory[$1234 + X]
//
// INDIRECT: [dp+X]
//   Address is read from (direct_page + operand + X)
//   Two bytes at that location form the actual address
//   Example: MOV A,[dp+X] ; ptr = memory[dp + X]; A = memory[ptr]
//
// INDIRECT INDEXED: [dp]+Y
//   Address is read from (direct_page + operand), then Y is added
//   Example: MOV A,[dp]+Y ; ptr = memory[dp]; A = memory[ptr + Y]
//
// DIRECT PAGE TO DIRECT PAGE: dp,dp
//   Two direct page addresses (for MOV dp,dp, CMP dp,dp, etc.)
//   Example: MOV $10,$20  ; memory[dp+$10] = memory[dp+$20]
//
// IMMEDIATE TO DIRECT PAGE: dp,#imm
//   Store immediate to direct page
//   Example: MOV $10,#$FF ; memory[dp+$10] = $FF
//
// X/Y INDIRECT: (X), (Y)
//   Address is direct_page + register value
//   Example: MOV A,(X)    ; A = memory[direct_page + X]
//
// X INDIRECT AUTO-INCREMENT: (X)+
//   Like (X), but X is incremented after access
//
// BIT ADDRESSING: mem.bit
//   13-bit address + 3-bit bit number
//   Used by SET1, CLR1, BBS, BBC, etc.
//   Example: SET1 $20.3   ; Set bit 3 of memory[$20]
//
// RELATIVE: rel
//   PC-relative signed 8-bit offset for branches
//   Example: BEQ $+5      ; Branch 5 bytes forward if Z=1
// =============================================================================

// =============================================================================
// INSTRUCTION SET OVERVIEW
// =============================================================================
// The SPC700 has approximately 183 instructions. Key categories:
//
// DATA TRANSFER:
// -----------------------------------------------------------------------------
// MOV   - Move data (many addressing mode variants)
// MOVW  - Move word (16-bit, uses YA register pair)
// PUSH  - Push register to stack (A, X, Y, PSW)
// POP   - Pop register from stack (A, X, Y, PSW)
//
// ARITHMETIC (8-bit):
// -----------------------------------------------------------------------------
// ADC   - Add with carry
// SBC   - Subtract with borrow
// CMP   - Compare (subtract without storing result)
// INC   - Increment
// DEC   - Decrement
//
// ARITHMETIC (16-bit):
// -----------------------------------------------------------------------------
// ADDW  - Add word to YA
// SUBW  - Subtract word from YA
// CMPW  - Compare word with YA
// INCW  - Increment word in memory
// DECW  - Decrement word in memory
// MUL   - Multiply: YA = Y * A (9 cycles)
// DIV   - Divide: A = YA / X, Y = remainder (12 cycles)
//
// LOGICAL:
// -----------------------------------------------------------------------------
// AND   - Bitwise AND
// OR    - Bitwise OR
// EOR   - Bitwise XOR (exclusive or)
//
// SHIFT/ROTATE:
// -----------------------------------------------------------------------------
// ASL   - Arithmetic shift left (bit 0 = 0, bit 7 -> C)
// LSR   - Logical shift right (bit 7 = 0, bit 0 -> C)
// ROL   - Rotate left through carry
// ROR   - Rotate right through carry
// XCN   - Exchange nibbles in A (swap high/low 4 bits)
//
// BIT MANIPULATION:
// -----------------------------------------------------------------------------
// SET1  - Set bit in memory
// CLR1  - Clear bit in memory
// TSET1 - Test and set bits (A OR memory, set N/Z from A AND memory)
// TCLR1 - Test and clear bits (~A AND memory, set N/Z from A AND memory)
// AND1  - AND carry with memory bit
// OR1   - OR carry with memory bit
// EOR1  - XOR carry with memory bit
// NOT1  - Complement memory bit
// MOV1  - Move between carry and memory bit
//
// BRANCHING:
// -----------------------------------------------------------------------------
// BRA   - Branch always
// BEQ   - Branch if Z=1 (equal)
// BNE   - Branch if Z=0 (not equal)
// BCS   - Branch if C=1 (carry set)
// BCC   - Branch if C=0 (carry clear)
// BVS   - Branch if V=1 (overflow set)
// BVC   - Branch if V=0 (overflow clear)
// BMI   - Branch if N=1 (minus/negative)
// BPL   - Branch if N=0 (plus/positive)
// BBS   - Branch if bit set
// BBC   - Branch if bit clear
// CBNE  - Compare and branch if not equal
// DBNZ  - Decrement and branch if not zero (loop instruction)
//
// JUMPS/CALLS:
// -----------------------------------------------------------------------------
// JMP   - Jump to absolute address
// CALL  - Call subroutine (push PC+3, jump to address)
// PCALL - Page call (call to $FFxx, 1-byte operand)
// TCALL - Table call (call through vector at $FFDE - n*2)
// RET   - Return from subroutine (pop PC)
// RETI  - Return from interrupt (pop PSW, then PC)
// BRK   - Software break (push PC+1 and PSW, set B/I, jump to [$FFDE])
//
// FLAG MANIPULATION:
// -----------------------------------------------------------------------------
// CLRC  - Clear carry (C=0)
// SETC  - Set carry (C=1)
// NOTC  - Complement carry
// CLRV  - Clear overflow AND half-carry (V=0, H=0)
// CLRP  - Clear direct page flag (P=0, direct page at $0000)
// SETP  - Set direct page flag (P=1, direct page at $0100)
// EI    - Enable interrupts (I=1, no effect on SNES)
// DI    - Disable interrupts (I=0, no effect on SNES)
//
// MISCELLANEOUS:
// -----------------------------------------------------------------------------
// NOP   - No operation (2 cycles)
// SLEEP - Wait for interrupt (stalls CPU, not useful on SNES)
// STOP  - Stop CPU until reset (don't use)
// DAA   - Decimal adjust after addition (for BCD)
// DAS   - Decimal adjust after subtraction (for BCD)
// =============================================================================

// =============================================================================
// INSTRUCTION TIMING
// =============================================================================
// Instruction cycle counts (1 cycle = 2 clocks = ~0.977 microseconds):
//
// FAST (2 cycles):
//   - Register moves: MOV A,X / MOV X,A / etc.
//   - Flag operations: CLRC, SETC, CLRV, etc.
//   - NOP
//
// TYPICAL (3-5 cycles):
//   - Most memory access instructions
//   - Branches (2 if not taken, 4 if taken)
//   - Direct page operations
//
// SLOW (8+ cycles):
//   - CALL: 8 cycles
//   - PCALL: 6 cycles
//   - TCALL: 8 cycles
//   - MUL: 9 cycles
//   - DIV: 12 cycles
//
// Every cycle is either a read or a write (like 6502).
// No "internal" cycles exist - apparent internal operations
// are actually re-reads of previously accessed addresses.
// =============================================================================

// =============================================================================
// IPL BOOT ROM
// =============================================================================
// The SPC700 contains a 64-byte mask ROM at $FFC0-$FFFF that executes at
// power-on. This "IPL" (Initial Program Loader) ROM:
//
// 1. Initializes stack pointer to $EF
// 2. Clears zero page memory
// 3. Signals "ready" by writing $AA to port 0, $BB to port 1
// 4. Waits for main CPU to write $CC to port 0 (start transfer)
// 5. Receives destination address in ports 2-3
// 6. Receives data bytes with index handshake via ports 0-1
// 7. Detects "execute" command (port 0 jumps by 2+, port 1 = $00)
// 8. Jumps to uploaded code with A=0, X=0, Y=0
//
// After the sound driver is uploaded and running, bit 7 of CONTROL ($F1)
// can be cleared to unmap the IPL ROM and reveal RAM at $FFC0-$FFFF.
// This gives games an extra 64 bytes of usable RAM.
//
// The IPL ROM code is well-documented and can be found in various
// SNES technical documents.
// =============================================================================

// =============================================================================
// SPC700 CPU STATE
// =============================================================================

pub const Spc700 = struct {
    // CPU Registers
    a: u8, // Accumulator
    x: u8, // Index X
    y: u8, // Index Y
    sp: u8, // Stack pointer (page 1: $0100-$01FF)
    pc: u16, // Program counter
    psw: u8, // Program status word (flags)

    // Memory
    ram: [65536]u8, // 64KB audio RAM (shared with the DSP for BRR samples and echo)

    // The S-DSP lives "inside" the SPC700 from the memory map's point of
    // view (reached only through $F2/$F3), and it shares our RAM, so we
    // own it directly - no pointer setup needed.
    dsp: Dsp,

    // I/O Ports (bidirectional communication with main CPU)
    // These are the SPC700's view of the ports:
    // - port_in: What the main CPU wrote (SPC700 reads these)
    // - port_out: What the SPC700 writes (main CPU reads these)
    port_in: [4]u8, // Input from main CPU ($F4-$F7 reads)
    port_out: [4]u8, // Output to main CPU ($F4-$F7 writes)

    // Timers
    timer_enable: [3]bool, // Timer 0, 1, 2 enable flags
    timer_div: [3]u8, // Timer divisor values ($FA-$FC)
    timer_counter: [3]u8, // Internal prescaler counters
    timer_output: [3]u4, // 4-bit output counters ($FD-$FF)
    timer_cycles: [3]u16, // Cycle counters for timer base rate

    // DSP interface
    dsp_addr: u8, // DSP register address ($F2)

    // System state
    ipl_rom_enabled: bool, // True = IPL ROM visible at $FFC0-$FFFF
    cycles: u64, // Total cycles executed

    /// TEST-VECTOR MODE (SingleStepTests/spc700 harness only): the
    /// vectors model the whole 64KB as plain RAM - no I/O registers at
    /// $F0-$FF, no IPL ROM overlay at $FFC0 - because they verify the
    /// CPU CORE in isolation (register/memory semantics per opcode),
    /// not the peripherals. With this set, read()/write() skip the I/O
    /// dispatch and the IPL mapping so the core sees exactly the flat
    /// memory the vectors describe. Never set outside the harness.
    test_flat_ram: bool = false,

    // IPL Boot ROM (64 bytes, read-only)
    // This is the actual boot ROM that runs at power-on
    ipl_rom: [64]u8,

    pub fn init() Spc700 {
        var spc = Spc700{
            // Registers initialized as per IPL ROM behavior
            .a = 0,
            .x = 0,
            .y = 0,
            .sp = 0xEF, // IPL ROM sets this
            .pc = 0xFFC0, // Start at IPL ROM
            .psw = 0x00, // All flags clear

            .ram = [_]u8{0} ** 65536,
            .dsp = Dsp.init(),

            // Ports - start at 0, IPL ROM will write $AA/$BB after RAM clear
            // Do NOT pre-initialize to $AA/$BB - the IPL ROM must write these
            // so the CPU properly waits for the APU to be ready
            .port_in = [_]u8{ 0, 0, 0, 0 },
            .port_out = [_]u8{ 0, 0, 0, 0 },

            // Timers disabled at boot
            .timer_enable = [_]bool{ false, false, false },
            .timer_div = [_]u8{ 0, 0, 0 },
            .timer_counter = [_]u8{ 0, 0, 0 },
            .timer_output = [_]u4{ 0, 0, 0 },
            .timer_cycles = [_]u16{ 0, 0, 0 },

            .dsp_addr = 0,
            .ipl_rom_enabled = true, // IPL ROM visible at boot
            .cycles = 0,

            // Initialize with actual IPL ROM code
            .ipl_rom = undefined,
        };

        // Copy IPL ROM code (see IPL_ROM constant below)
        @memcpy(&spc.ipl_rom, &IPL_ROM);

        return spc;
    }

    // =========================================================================
    // FLAG HELPERS
    // =========================================================================

    /// Get the N (negative) flag
    pub fn flagN(self: *const Spc700) bool {
        return (self.psw & PSW.N) != 0;
    }

    /// Get the V (overflow) flag
    pub fn flagV(self: *const Spc700) bool {
        return (self.psw & PSW.V) != 0;
    }

    /// Get the P (direct page) flag
    pub fn flagP(self: *const Spc700) bool {
        return (self.psw & PSW.P) != 0;
    }

    /// Get the H (half-carry) flag
    pub fn flagH(self: *const Spc700) bool {
        return (self.psw & PSW.H) != 0;
    }

    /// Get the Z (zero) flag
    pub fn flagZ(self: *const Spc700) bool {
        return (self.psw & PSW.Z) != 0;
    }

    /// Get the C (carry) flag
    pub fn flagC(self: *const Spc700) bool {
        return (self.psw & PSW.C) != 0;
    }

    /// Set or clear the N and Z flags based on a value
    pub fn setNZ(self: *Spc700, value: u8) void {
        self.psw = (self.psw & ~(PSW.N | PSW.Z)) |
            (if (value & 0x80 != 0) PSW.N else 0) |
            (if (value == 0) PSW.Z else 0);
    }

    /// Get the direct page base address (0 or 256 based on P flag)
    pub fn directPage(self: *const Spc700) u16 {
        return if (self.flagP()) 0x0100 else 0x0000;
    }

    /// Get the YA register pair as a 16-bit value
    pub fn getYA(self: *const Spc700) u16 {
        return (@as(u16, self.y) << 8) | self.a;
    }

    /// Set the YA register pair from a 16-bit value
    pub fn setYA(self: *Spc700, value: u16) void {
        self.a = @truncate(value);
        self.y = @truncate(value >> 8);
    }

    // =========================================================================
    // MEMORY ACCESS
    // =========================================================================

    /// Read a byte from SPC700 memory
    pub fn read(self: *Spc700, addr: u16) u8 {
        const addr_u8: u8 = @truncate(addr);

        // Vector harness: the whole 64KB is plain RAM (see the field doc)
        if (self.test_flat_ram) return self.ram[addr];

        // I/O registers at $00F0-$00FF
        if (addr >= 0x00F0 and addr <= 0x00FF) {
            return self.readIo(addr_u8);
        }

        // IPL ROM at $FFC0-$FFFF (when enabled)
        if (addr >= 0xFFC0 and self.ipl_rom_enabled) {
            return self.ipl_rom[addr - 0xFFC0];
        }

        return self.ram[addr];
    }

    /// Write a byte to SPC700 memory
    pub fn write(self: *Spc700, addr: u16, value: u8) void {
        const addr_u8: u8 = @truncate(addr);

        // Vector harness: the whole 64KB is plain RAM (see the field doc)
        if (self.test_flat_ram) {
            self.ram[addr] = value;
            return;
        }

        // I/O registers at $00F0-$00FF
        if (addr >= 0x00F0 and addr <= 0x00FF) {
            self.writeIo(addr_u8, value);
            return;
        }

        // RAM is always writable (even under IPL ROM)
        self.ram[addr] = value;
    }

    /// Read from I/O register ($F0-$FF)
    fn readIo(self: *Spc700, addr: u8) u8 {
        switch (addr) {
            IoReg.TEST => return 0, // Undocumented test register
            IoReg.CONTROL => return 0, // Write-only (mostly)
            IoReg.DSPADDR => return self.dsp_addr,
            IoReg.DSPDATA => return self.readDsp(self.dsp_addr),
            IoReg.PORT0 => {
                const val = self.port_in[0];
                if (comptime dbg.trace_apu) {
                    std.debug.print("[SPC] Read port0 = ${x:0>2} (waiting for $CC)\n", .{val});
                }
                return val;
            },
            IoReg.PORT1 => return self.port_in[1],
            IoReg.PORT2 => return self.port_in[2],
            IoReg.PORT3 => return self.port_in[3],
            IoReg.AUXIO4 => return self.ram[0xF8],
            IoReg.AUXIO5 => return self.ram[0xF9],
            IoReg.T0DIV, IoReg.T1DIV, IoReg.T2DIV => return 0, // Write-only
            IoReg.T0OUT => {
                const val = self.timer_output[0];
                self.timer_output[0] = 0; // Reading clears it
                return val;
            },
            IoReg.T1OUT => {
                const val = self.timer_output[1];
                self.timer_output[1] = 0;
                return val;
            },
            IoReg.T2OUT => {
                const val = self.timer_output[2];
                self.timer_output[2] = 0;
                return val;
            },
            else => return self.ram[addr],
        }
    }

    /// Write to I/O register ($F0-$FF)
    fn writeIo(self: *Spc700, addr: u8, value: u8) void {
        switch (addr) {
            IoReg.TEST => {}, // Ignore test register writes
            IoReg.CONTROL => {
                // Timer enables
                const t0_was_enabled = self.timer_enable[0];
                const t1_was_enabled = self.timer_enable[1];
                const t2_was_enabled = self.timer_enable[2];

                self.timer_enable[0] = (value & 0x01) != 0;
                self.timer_enable[1] = (value & 0x02) != 0;
                self.timer_enable[2] = (value & 0x04) != 0;

                // Reset timers when enabled
                if (!t0_was_enabled and self.timer_enable[0]) {
                    self.timer_counter[0] = 0;
                    self.timer_output[0] = 0;
                    self.timer_cycles[0] = 0;
                }
                if (!t1_was_enabled and self.timer_enable[1]) {
                    self.timer_counter[1] = 0;
                    self.timer_output[1] = 0;
                    self.timer_cycles[1] = 0;
                }
                if (!t2_was_enabled and self.timer_enable[2]) {
                    self.timer_counter[2] = 0;
                    self.timer_output[2] = 0;
                    self.timer_cycles[2] = 0;
                }

                // Port reset bits (bits 4-5)
                if (value & 0x10 != 0) {
                    self.port_in[0] = 0;
                    self.port_in[1] = 0;
                }
                if (value & 0x20 != 0) {
                    self.port_in[2] = 0;
                    self.port_in[3] = 0;
                }

                // IPL ROM enable (bit 7)
                self.ipl_rom_enabled = (value & 0x80) != 0;
            },
            IoReg.DSPADDR => self.dsp_addr = value,
            IoReg.DSPDATA => self.writeDsp(self.dsp_addr, value),
            IoReg.PORT0 => {
                if (comptime dbg.trace_apu) {
                    std.debug.print("[SPC] Write port0 = ${x:0>2} (echo)\n", .{value});
                }
                self.port_out[0] = value;
            },
            IoReg.PORT1 => {
                if (comptime dbg.trace_apu) {
                    std.debug.print("[SPC] Write port1 = ${x:0>2}\n", .{value});
                }
                self.port_out[1] = value;
            },
            IoReg.PORT2 => self.port_out[2] = value,
            IoReg.PORT3 => self.port_out[3] = value,
            IoReg.AUXIO4 => self.ram[0xF8] = value,
            IoReg.AUXIO5 => self.ram[0xF9] = value,
            IoReg.T0DIV => self.timer_div[0] = value,
            IoReg.T1DIV => self.timer_div[1] = value,
            IoReg.T2DIV => self.timer_div[2] = value,
            IoReg.T0OUT, IoReg.T1OUT, IoReg.T2OUT => {}, // Read-only
            else => self.ram[addr] = value,
        }
    }

    // =========================================================================
    // INSTRUCTION EXECUTION
    // =========================================================================
    // Execute one instruction and return the number of cycles consumed.
    // This is the main CPU loop - fetch opcode, decode, execute.

    /// Fetch the next byte from PC and advance PC
    fn fetch(self: *Spc700) u8 {
        const value = self.read(self.pc);
        self.pc +%= 1;
        return value;
    }

    /// Fetch a 16-bit value (little-endian) from PC
    fn fetch16(self: *Spc700) u16 {
        const low = self.fetch();
        const high = self.fetch();
        return (@as(u16, high) << 8) | low;
    }

    /// Read from direct page address
    fn readDp(self: *Spc700, offset: u8) u8 {
        return self.read(self.directPage() | offset);
    }

    /// Write to direct page address
    fn writeDp(self: *Spc700, offset: u8, value: u8) void {
        self.write(self.directPage() | offset, value);
    }

    /// Read 16-bit value from direct page (little-endian)
    fn readDp16(self: *Spc700, offset: u8) u16 {
        const low = self.readDp(offset);
        const high = self.readDp(offset +% 1);
        return (@as(u16, high) << 8) | low;
    }

    /// Write 16-bit value to direct page (little-endian)
    fn writeDp16(self: *Spc700, offset: u8, value: u16) void {
        self.writeDp(offset, @truncate(value));
        self.writeDp(offset +% 1, @truncate(value >> 8));
    }

    /// Execute one instruction, return cycles consumed
    pub fn step(self: *Spc700) u8 {
        const opcode = self.fetch();

        // Trace instruction if debug enabled
        if (comptime dbg.enabled and dbg.trace_cpu) {
            std.debug.print("[SPC] ${x:0>4}: ${x:0>2} A=${x:0>2} X=${x:0>2} Y=${x:0>2} SP=${x:0>2} PSW=${x:0>2}\n", .{
                self.pc -% 1,
                opcode,
                self.a,
                self.x,
                self.y,
                self.sp,
                self.psw,
            });
        }

        const cycles: u8 = switch (opcode) {
            // =================================================================
            // NOP
            // =================================================================
            0x00 => 2, // NOP

            // =================================================================
            // MOV - Register to Register
            // =================================================================
            0x7D => blk: { // MOV A,X
                self.a = self.x;
                self.setNZ(self.a);
                break :blk 2;
            },
            0x5D => blk: { // MOV X,A
                self.x = self.a;
                self.setNZ(self.x);
                break :blk 2;
            },
            0xDD => blk: { // MOV A,Y
                self.a = self.y;
                self.setNZ(self.a);
                break :blk 2;
            },
            0xFD => blk: { // MOV Y,A
                self.y = self.a;
                self.setNZ(self.y);
                break :blk 2;
            },
            0x9D => blk: { // MOV X,SP
                self.x = self.sp;
                self.setNZ(self.x);
                break :blk 2;
            },
            0xBD => blk: { // MOV SP,X
                self.sp = self.x;
                break :blk 2;
            },

            // =================================================================
            // MOV - Immediate
            // =================================================================
            0xE8 => blk: { // MOV A,#imm
                self.a = self.fetch();
                self.setNZ(self.a);
                break :blk 2;
            },
            0xCD => blk: { // MOV X,#imm
                self.x = self.fetch();
                self.setNZ(self.x);
                break :blk 2;
            },
            0x8D => blk: { // MOV Y,#imm
                self.y = self.fetch();
                self.setNZ(self.y);
                break :blk 2;
            },

            // =================================================================
            // MOV - Direct Page Read
            // =================================================================
            0xE4 => blk: { // MOV A,dp
                const dp = self.fetch();
                self.a = self.readDp(dp);
                self.setNZ(self.a);
                break :blk 3;
            },
            0xF8 => blk: { // MOV X,dp
                const dp = self.fetch();
                self.x = self.readDp(dp);
                self.setNZ(self.x);
                break :blk 3;
            },
            0xEB => blk: { // MOV Y,dp
                const dp = self.fetch();
                self.y = self.readDp(dp);
                self.setNZ(self.y);
                break :blk 3;
            },
            0xF4 => blk: { // MOV A,dp+X
                const dp = self.fetch();
                self.a = self.readDp(dp +% self.x);
                self.setNZ(self.a);
                break :blk 4;
            },
            0xF9 => blk: { // MOV X,dp+Y
                const dp = self.fetch();
                self.x = self.readDp(dp +% self.y);
                self.setNZ(self.x);
                break :blk 4;
            },
            0xFB => blk: { // MOV Y,dp+X
                const dp = self.fetch();
                self.y = self.readDp(dp +% self.x);
                self.setNZ(self.y);
                break :blk 4;
            },

            // =================================================================
            // MOV - Direct Page Write
            // =================================================================
            0xC4 => blk: { // MOV dp,A
                const dp = self.fetch();
                self.writeDp(dp, self.a);
                break :blk 4;
            },
            0xD8 => blk: { // MOV dp,X
                const dp = self.fetch();
                self.writeDp(dp, self.x);
                break :blk 4;
            },
            0xCB => blk: { // MOV dp,Y
                const dp = self.fetch();
                self.writeDp(dp, self.y);
                break :blk 4;
            },
            0xD4 => blk: { // MOV dp+X,A
                const dp = self.fetch();
                self.writeDp(dp +% self.x, self.a);
                break :blk 5;
            },
            0xD9 => blk: { // MOV dp+Y,X
                const dp = self.fetch();
                self.writeDp(dp +% self.y, self.x);
                break :blk 5;
            },
            0xDB => blk: { // MOV dp+X,Y
                const dp = self.fetch();
                self.writeDp(dp +% self.x, self.y);
                break :blk 5;
            },
            0x8F => blk: { // MOV dp,#imm
                const imm = self.fetch();
                const dp = self.fetch();
                self.writeDp(dp, imm);
                break :blk 5;
            },
            0xFA => blk: { // MOV dp,dp (destination first in encoding)
                const src = self.fetch();
                const dst = self.fetch();
                const value = self.readDp(src);
                self.writeDp(dst, value);
                break :blk 5;
            },

            // =================================================================
            // MOV - Absolute
            // =================================================================
            0xE5 => blk: { // MOV A,!abs
                const addr = self.fetch16();
                self.a = self.read(addr);
                self.setNZ(self.a);
                break :blk 4;
            },
            0xE9 => blk: { // MOV X,!abs
                const addr = self.fetch16();
                self.x = self.read(addr);
                self.setNZ(self.x);
                break :blk 4;
            },
            // -----------------------------------------------------------------
            // MOV Y, !abs ($EC) - Load Y from absolute address
            // -----------------------------------------------------------------
            // 3 bytes: $EC, addr_lo, addr_hi
            // 4 cycles
            // Flags: N, Z (set based on loaded value)
            //
            // This instruction is commonly used in sound driver main loops to
            // poll I/O ports for commands from the main CPU. For example:
            //   $0549: EC F4 00   MOV Y, $00F4  ; Read port 0 into Y
            //   $054C: F0 FB      BEQ $0549     ; If zero, no command, loop
            //
            // The sound driver waits in this loop until the main CPU writes
            // a non-zero command value to port $2140 (maps to SPC700's $F4).
            // -----------------------------------------------------------------
            0xEC => blk: { // MOV Y,!abs
                const addr = self.fetch16();
                self.y = self.read(addr);
                self.setNZ(self.y);
                if (comptime dbg.trace_apu) {
                    // Log when polling I/O ports (useful for debugging stuck loops)
                    if (addr >= 0x00F4 and addr <= 0x00F7) {
                        std.debug.print("[SPC] MOV Y,!${x:0>4} = ${x:0>2} (polling port {d})\n", .{ addr, self.y, addr - 0x00F4 });
                    }
                }
                break :blk 4;
            },
            0xF5 => blk: { // MOV A,!abs+X
                const addr = self.fetch16();
                self.a = self.read(addr +% self.x);
                self.setNZ(self.a);
                break :blk 5;
            },
            0xF6 => blk: { // MOV A,!abs+Y
                const addr = self.fetch16();
                self.a = self.read(addr +% self.y);
                self.setNZ(self.a);
                break :blk 5;
            },
            0xC5 => blk: { // MOV !abs,A
                const addr = self.fetch16();
                self.write(addr, self.a);
                break :blk 5;
            },
            0xC9 => blk: { // MOV !abs,X
                const addr = self.fetch16();
                self.write(addr, self.x);
                break :blk 5;
            },
            0xCC => blk: { // MOV !abs,Y
                const addr = self.fetch16();
                self.write(addr, self.y);
                break :blk 5;
            },
            0xD5 => blk: { // MOV !abs+X,A
                const addr = self.fetch16();
                self.write(addr +% self.x, self.a);
                break :blk 6;
            },
            0xD6 => blk: { // MOV !abs+Y,A
                const addr = self.fetch16();
                self.write(addr +% self.y, self.a);
                break :blk 6;
            },

            // =================================================================
            // MOV - Indirect
            // =================================================================
            0xE6 => blk: { // MOV A,(X)
                self.a = self.readDp(self.x);
                self.setNZ(self.a);
                break :blk 3;
            },
            0xC6 => blk: { // MOV (X),A
                self.writeDp(self.x, self.a);
                break :blk 4;
            },
            0xBF => blk: { // MOV A,(X)+
                self.a = self.readDp(self.x);
                self.x +%= 1;
                self.setNZ(self.a);
                break :blk 4;
            },
            0xAF => blk: { // MOV (X)+,A
                self.writeDp(self.x, self.a);
                self.x +%= 1;
                break :blk 4;
            },
            0xE7 => blk: { // MOV A,[dp+X]
                const dp = self.fetch();
                const ptr = self.readDp16(dp +% self.x);
                self.a = self.read(ptr);
                self.setNZ(self.a);
                break :blk 6;
            },
            0xF7 => blk: { // MOV A,[dp]+Y
                const dp = self.fetch();
                const ptr = self.readDp16(dp);
                self.a = self.read(ptr +% self.y);
                self.setNZ(self.a);
                break :blk 6;
            },
            0xC7 => blk: { // MOV [dp+X],A
                const dp = self.fetch();
                const ptr = self.readDp16(dp +% self.x);
                self.write(ptr, self.a);
                break :blk 7;
            },
            0xD7 => blk: { // MOV [dp]+Y,A
                const dp = self.fetch();
                const ptr = self.readDp16(dp);
                self.write(ptr +% self.y, self.a);
                break :blk 7;
            },

            // =================================================================
            // MOVW - 16-bit moves
            // =================================================================
            0xBA => blk: { // MOVW YA,dp
                const dp = self.fetch();
                const value = self.readDp16(dp);
                self.setYA(value);
                // N/Z from the full 16-bit word: N = bit 15, Z = the
                // WHOLE word is zero. (The old setNZ(Y)-then-patch-Z
                // version could never CLEAR Z for Y=0, A!=0 - the four
                // vectors that caught it were exactly that shape.)
                self.psw = (self.psw & ~(PSW.N | PSW.Z)) |
                    (if (value & 0x8000 != 0) PSW.N else 0) |
                    (if (value == 0) PSW.Z else 0);
                break :blk 5;
            },
            0xDA => blk: { // MOVW dp,YA
                const dp = self.fetch();
                self.writeDp16(dp, self.getYA());
                break :blk 5;
            },

            // =================================================================
            // INC/DEC - Register
            // =================================================================
            0xBC => blk: { // INC A
                self.a +%= 1;
                self.setNZ(self.a);
                break :blk 2;
            },
            0x3D => blk: { // INC X
                self.x +%= 1;
                self.setNZ(self.x);
                break :blk 2;
            },
            0xFC => blk: { // INC Y
                self.y +%= 1;
                self.setNZ(self.y);
                break :blk 2;
            },
            0x9C => blk: { // DEC A
                self.a -%= 1;
                self.setNZ(self.a);
                break :blk 2;
            },
            0x1D => blk: { // DEC X
                self.x -%= 1;
                self.setNZ(self.x);
                break :blk 2;
            },
            0xDC => blk: { // DEC Y
                self.y -%= 1;
                self.setNZ(self.y);
                break :blk 2;
            },

            // =================================================================
            // INC/DEC - Memory
            // =================================================================
            0xAB => blk: { // INC dp
                const dp = self.fetch();
                const value = self.readDp(dp) +% 1;
                self.writeDp(dp, value);
                self.setNZ(value);
                break :blk 4;
            },
            0xAC => blk: { // INC !abs
                const addr = self.fetch16();
                const value = self.read(addr) +% 1;
                self.write(addr, value);
                self.setNZ(value);
                break :blk 5;
            },
            0xBB => blk: { // INC dp+X
                const dp = self.fetch();
                const value = self.readDp(dp +% self.x) +% 1;
                self.writeDp(dp +% self.x, value);
                self.setNZ(value);
                break :blk 5;
            },
            0x8B => blk: { // DEC dp
                const dp = self.fetch();
                const value = self.readDp(dp) -% 1;
                self.writeDp(dp, value);
                self.setNZ(value);
                break :blk 4;
            },
            0x8C => blk: { // DEC !abs
                const addr = self.fetch16();
                const value = self.read(addr) -% 1;
                self.write(addr, value);
                self.setNZ(value);
                break :blk 5;
            },
            0x9B => blk: { // DEC dp+X
                const dp = self.fetch();
                const value = self.readDp(dp +% self.x) -% 1;
                self.writeDp(dp +% self.x, value);
                self.setNZ(value);
                break :blk 5;
            },

            // =================================================================
            // INCW/DECW - 16-bit memory
            // =================================================================
            0x3A => blk: { // INCW dp
                const dp = self.fetch();
                const value = self.readDp16(dp) +% 1;
                self.writeDp16(dp, value);
                self.psw &= ~(PSW.N | PSW.Z);
                if (value == 0) self.psw |= PSW.Z;
                if (value & 0x8000 != 0) self.psw |= PSW.N;
                break :blk 6;
            },
            0x1A => blk: { // DECW dp
                const dp = self.fetch();
                const value = self.readDp16(dp) -% 1;
                self.writeDp16(dp, value);
                self.psw &= ~(PSW.N | PSW.Z);
                if (value == 0) self.psw |= PSW.Z;
                if (value & 0x8000 != 0) self.psw |= PSW.N;
                break :blk 6;
            },

            // =================================================================
            // CMP - Compare
            // =================================================================
            0x68 => blk: { // CMP A,#imm
                const imm = self.fetch();
                self.compare(self.a, imm);
                break :blk 2;
            },
            0xC8 => blk: { // CMP X,#imm
                const imm = self.fetch();
                self.compare(self.x, imm);
                break :blk 2;
            },
            0xAD => blk: { // CMP Y,#imm
                const imm = self.fetch();
                self.compare(self.y, imm);
                break :blk 2;
            },
            0x64 => blk: { // CMP A,dp
                const dp = self.fetch();
                self.compare(self.a, self.readDp(dp));
                break :blk 3;
            },
            0x3E => blk: { // CMP X,dp
                const dp = self.fetch();
                self.compare(self.x, self.readDp(dp));
                break :blk 3;
            },
            0x7E => blk: { // CMP Y,dp
                const dp = self.fetch();
                self.compare(self.y, self.readDp(dp));
                break :blk 3;
            },
            0x74 => blk: { // CMP A,dp+X
                const dp = self.fetch();
                self.compare(self.a, self.readDp(dp +% self.x));
                break :blk 4;
            },
            0x65 => blk: { // CMP A,!abs
                const addr = self.fetch16();
                self.compare(self.a, self.read(addr));
                break :blk 4;
            },
            0x1E => blk: { // CMP X,!abs
                const addr = self.fetch16();
                self.compare(self.x, self.read(addr));
                break :blk 4;
            },
            0x5E => blk: { // CMP Y,!abs
                const addr = self.fetch16();
                self.compare(self.y, self.read(addr));
                break :blk 4;
            },
            0x75 => blk: { // CMP A,!abs+X
                const addr = self.fetch16();
                self.compare(self.a, self.read(addr +% self.x));
                break :blk 5;
            },
            0x76 => blk: { // CMP A,!abs+Y
                const addr = self.fetch16();
                self.compare(self.a, self.read(addr +% self.y));
                break :blk 5;
            },
            0x66 => blk: { // CMP A,(X)
                self.compare(self.a, self.readDp(self.x));
                break :blk 3;
            },
            0x67 => blk: { // CMP A,[dp+X]
                const dp = self.fetch();
                const ptr = self.readDp16(dp +% self.x);
                self.compare(self.a, self.read(ptr));
                break :blk 6;
            },
            0x77 => blk: { // CMP A,[dp]+Y
                const dp = self.fetch();
                const ptr = self.readDp16(dp);
                self.compare(self.a, self.read(ptr +% self.y));
                break :blk 6;
            },
            0x69 => blk: { // CMP dp,dp
                const src = self.fetch();
                const dst = self.fetch();
                self.compare(self.readDp(dst), self.readDp(src));
                break :blk 6;
            },
            0x78 => blk: { // CMP dp,#imm
                const imm = self.fetch();
                const dp = self.fetch();
                self.compare(self.readDp(dp), imm);
                break :blk 5;
            },
            0x79 => blk: { // CMP (X),(Y)
                self.compare(self.readDp(self.x), self.readDp(self.y));
                break :blk 5;
            },

            // =================================================================
            // CMPW - 16-bit compare
            // =================================================================
            0x5A => blk: { // CMPW YA,dp
                const dp = self.fetch();
                const value = self.readDp16(dp);
                const ya = self.getYA();
                const result = ya -% value;
                self.psw &= ~(PSW.N | PSW.Z | PSW.C);
                if (ya >= value) self.psw |= PSW.C;
                if (result == 0) self.psw |= PSW.Z;
                if (result & 0x8000 != 0) self.psw |= PSW.N;
                break :blk 4;
            },

            // =================================================================
            // ADC - Add with carry
            // =================================================================
            0x88 => blk: { // ADC A,#imm
                const imm = self.fetch();
                self.a = self.adc(self.a, imm);
                break :blk 2;
            },
            0x84 => blk: { // ADC A,dp
                const dp = self.fetch();
                self.a = self.adc(self.a, self.readDp(dp));
                break :blk 3;
            },
            0x94 => blk: { // ADC A,dp+X
                const dp = self.fetch();
                self.a = self.adc(self.a, self.readDp(dp +% self.x));
                break :blk 4;
            },
            0x85 => blk: { // ADC A,!abs
                const addr = self.fetch16();
                self.a = self.adc(self.a, self.read(addr));
                break :blk 4;
            },
            0x95 => blk: { // ADC A,!abs+X
                const addr = self.fetch16();
                self.a = self.adc(self.a, self.read(addr +% self.x));
                break :blk 5;
            },
            0x96 => blk: { // ADC A,!abs+Y
                const addr = self.fetch16();
                self.a = self.adc(self.a, self.read(addr +% self.y));
                break :blk 5;
            },
            0x86 => blk: { // ADC A,(X)
                self.a = self.adc(self.a, self.readDp(self.x));
                break :blk 3;
            },
            0x87 => blk: { // ADC A,[dp+X]
                const dp = self.fetch();
                const ptr = self.readDp16(dp +% self.x);
                self.a = self.adc(self.a, self.read(ptr));
                break :blk 6;
            },
            0x97 => blk: { // ADC A,[dp]+Y
                const dp = self.fetch();
                const ptr = self.readDp16(dp);
                self.a = self.adc(self.a, self.read(ptr +% self.y));
                break :blk 6;
            },
            0x89 => blk: { // ADC dp,dp
                const src = self.fetch();
                const dst = self.fetch();
                const result = self.adc(self.readDp(dst), self.readDp(src));
                self.writeDp(dst, result);
                break :blk 6;
            },
            0x98 => blk: { // ADC dp,#imm
                const imm = self.fetch();
                const dp = self.fetch();
                const result = self.adc(self.readDp(dp), imm);
                self.writeDp(dp, result);
                break :blk 5;
            },
            0x99 => blk: { // ADC (X),(Y)
                const result = self.adc(self.readDp(self.x), self.readDp(self.y));
                self.writeDp(self.x, result);
                break :blk 5;
            },

            // =================================================================
            // SBC - Subtract with borrow
            // =================================================================
            0xA8 => blk: { // SBC A,#imm
                const imm = self.fetch();
                self.a = self.sbc(self.a, imm);
                break :blk 2;
            },
            0xA4 => blk: { // SBC A,dp
                const dp = self.fetch();
                self.a = self.sbc(self.a, self.readDp(dp));
                break :blk 3;
            },
            0xB4 => blk: { // SBC A,dp+X
                const dp = self.fetch();
                self.a = self.sbc(self.a, self.readDp(dp +% self.x));
                break :blk 4;
            },
            0xA5 => blk: { // SBC A,!abs
                const addr = self.fetch16();
                self.a = self.sbc(self.a, self.read(addr));
                break :blk 4;
            },
            0xB5 => blk: { // SBC A,!abs+X
                const addr = self.fetch16();
                self.a = self.sbc(self.a, self.read(addr +% self.x));
                break :blk 5;
            },
            0xB6 => blk: { // SBC A,!abs+Y
                const addr = self.fetch16();
                self.a = self.sbc(self.a, self.read(addr +% self.y));
                break :blk 5;
            },
            0xA6 => blk: { // SBC A,(X)
                self.a = self.sbc(self.a, self.readDp(self.x));
                break :blk 3;
            },
            0xA7 => blk: { // SBC A,[dp+X]
                const dp = self.fetch();
                const ptr = self.readDp16(dp +% self.x);
                self.a = self.sbc(self.a, self.read(ptr));
                break :blk 6;
            },
            0xB7 => blk: { // SBC A,[dp]+Y
                const dp = self.fetch();
                const ptr = self.readDp16(dp);
                self.a = self.sbc(self.a, self.read(ptr +% self.y));
                break :blk 6;
            },
            0xA9 => blk: { // SBC dp,dp
                const src = self.fetch();
                const dst = self.fetch();
                const result = self.sbc(self.readDp(dst), self.readDp(src));
                self.writeDp(dst, result);
                break :blk 6;
            },
            0xB8 => blk: { // SBC dp,#imm
                const imm = self.fetch();
                const dp = self.fetch();
                const result = self.sbc(self.readDp(dp), imm);
                self.writeDp(dp, result);
                break :blk 5;
            },
            0xB9 => blk: { // SBC (X),(Y)
                const result = self.sbc(self.readDp(self.x), self.readDp(self.y));
                self.writeDp(self.x, result);
                break :blk 5;
            },

            // =================================================================
            // ADDW/SUBW - 16-bit arithmetic
            // =================================================================
            // The 16-bit adds are TWO chained 8-bit ALU passes on real
            // hardware (A gets the low half, Y the high half) - which
            // pins down the "complex" flags exactly (vector-verified):
            //   C = carry out of the HIGH byte (i.e. out of bit 15)
            //   V = signed overflow of the HIGH-byte add (== 16-bit
            //       signed overflow, since the low half only feeds a
            //       carry in)
            //   H = half-carry of the HIGH-byte add - carry from bit
            //       11 of the word, NOT bit 3
            //   N = bit 15, Z = the whole 16-bit result
            0x7A => blk: { // ADDW YA,dp
                const dp = self.fetch();
                const value = self.readDp16(dp);
                const ya = self.getYA();
                // low half: A + operand.low (no carry in)
                const lo: u16 = @as(u16, ya & 0xFF) + @as(u16, value & 0xFF);
                const carry_lo: u16 = lo >> 8;
                // high half: Y + operand.high + carry
                const yh: u16 = ya >> 8;
                const vh: u16 = value >> 8;
                const hi: u16 = yh + vh + carry_lo;
                const result: u16 = ((hi & 0xFF) << 8) | (lo & 0xFF);
                self.setYA(result);
                self.psw &= ~(PSW.N | PSW.Z | PSW.C | PSW.V | PSW.H);
                if (hi > 0xFF) self.psw |= PSW.C;
                // signed overflow of the high-byte add: operands agree
                // in sign, result disagrees
                if (((yh ^ hi) & (vh ^ hi) & 0x80) != 0) self.psw |= PSW.V;
                // half-carry out of bit 3 of the high-byte add
                if (((yh & 0x0F) + (vh & 0x0F) + carry_lo) > 0x0F) self.psw |= PSW.H;
                if (result == 0) self.psw |= PSW.Z;
                if (result & 0x8000 != 0) self.psw |= PSW.N;
                break :blk 5;
            },
            0x9A => blk: { // SUBW YA,dp
                const dp = self.fetch();
                const value = self.readDp16(dp);
                const ya = self.getYA();
                // low half: A - operand.low (borrow out)
                const lo: i32 = @as(i32, ya & 0xFF) - @as(i32, value & 0xFF);
                const borrow_lo: i32 = if (lo < 0) 1 else 0;
                // high half: Y - operand.high - borrow
                const yh: i32 = ya >> 8;
                const vh: i32 = value >> 8;
                const hi: i32 = yh - vh - borrow_lo;
                const result: u16 = @intCast(((hi & 0xFF) << 8) | (lo & 0xFF));
                self.setYA(result);
                self.psw &= ~(PSW.N | PSW.Z | PSW.C | PSW.V | PSW.H);
                // C = no borrow out of the high byte (SPC700 subtract
                // carry is inverted-borrow, like the 6502)
                if (hi >= 0) self.psw |= PSW.C;
                if ((((yh ^ vh) & (yh ^ hi)) & 0x80) != 0) self.psw |= PSW.V;
                // H = no borrow out of bit 3 of the high-byte subtract
                if ((yh & 0x0F) - (vh & 0x0F) - borrow_lo >= 0) self.psw |= PSW.H;
                if (result == 0) self.psw |= PSW.Z;
                if (result & 0x8000 != 0) self.psw |= PSW.N;
                break :blk 5;
            },

            // =================================================================
            // AND/OR/EOR - Logical operations
            // =================================================================
            0x28 => blk: { // AND A,#imm
                self.a &= self.fetch();
                self.setNZ(self.a);
                break :blk 2;
            },
            0x24 => blk: { // AND A,dp
                const dp = self.fetch();
                self.a &= self.readDp(dp);
                self.setNZ(self.a);
                break :blk 3;
            },
            0x34 => blk: { // AND A,dp+X
                const dp = self.fetch();
                self.a &= self.readDp(dp +% self.x);
                self.setNZ(self.a);
                break :blk 4;
            },
            0x25 => blk: { // AND A,!abs
                const addr = self.fetch16();
                self.a &= self.read(addr);
                self.setNZ(self.a);
                break :blk 4;
            },
            0x35 => blk: { // AND A,!abs+X
                const addr = self.fetch16();
                self.a &= self.read(addr +% self.x);
                self.setNZ(self.a);
                break :blk 5;
            },
            0x36 => blk: { // AND A,!abs+Y
                const addr = self.fetch16();
                self.a &= self.read(addr +% self.y);
                self.setNZ(self.a);
                break :blk 5;
            },
            0x26 => blk: { // AND A,(X)
                self.a &= self.readDp(self.x);
                self.setNZ(self.a);
                break :blk 3;
            },
            0x27 => blk: { // AND A,[dp+X]
                const dp = self.fetch();
                const ptr = self.readDp16(dp +% self.x);
                self.a &= self.read(ptr);
                self.setNZ(self.a);
                break :blk 6;
            },
            0x37 => blk: { // AND A,[dp]+Y
                const dp = self.fetch();
                const ptr = self.readDp16(dp);
                self.a &= self.read(ptr +% self.y);
                self.setNZ(self.a);
                break :blk 6;
            },
            0x29 => blk: { // AND dp,dp
                const src = self.fetch();
                const dst = self.fetch();
                const result = self.readDp(dst) & self.readDp(src);
                self.writeDp(dst, result);
                self.setNZ(result);
                break :blk 6;
            },
            0x38 => blk: { // AND dp,#imm
                const imm = self.fetch();
                const dp = self.fetch();
                const result = self.readDp(dp) & imm;
                self.writeDp(dp, result);
                self.setNZ(result);
                break :blk 5;
            },
            0x39 => blk: { // AND (X),(Y)
                const result = self.readDp(self.x) & self.readDp(self.y);
                self.writeDp(self.x, result);
                self.setNZ(result);
                break :blk 5;
            },
            0x08 => blk: { // OR A,#imm
                self.a |= self.fetch();
                self.setNZ(self.a);
                break :blk 2;
            },
            0x04 => blk: { // OR A,dp
                const dp = self.fetch();
                self.a |= self.readDp(dp);
                self.setNZ(self.a);
                break :blk 3;
            },
            0x14 => blk: { // OR A,dp+X
                const dp = self.fetch();
                self.a |= self.readDp(dp +% self.x);
                self.setNZ(self.a);
                break :blk 4;
            },
            0x05 => blk: { // OR A,!abs
                const addr = self.fetch16();
                self.a |= self.read(addr);
                self.setNZ(self.a);
                break :blk 4;
            },
            0x15 => blk: { // OR A,!abs+X
                const addr = self.fetch16();
                self.a |= self.read(addr +% self.x);
                self.setNZ(self.a);
                break :blk 5;
            },
            0x16 => blk: { // OR A,!abs+Y
                const addr = self.fetch16();
                self.a |= self.read(addr +% self.y);
                self.setNZ(self.a);
                break :blk 5;
            },
            0x06 => blk: { // OR A,(X)
                self.a |= self.readDp(self.x);
                self.setNZ(self.a);
                break :blk 3;
            },
            0x07 => blk: { // OR A,[dp+X]
                const dp = self.fetch();
                const ptr = self.readDp16(dp +% self.x);
                self.a |= self.read(ptr);
                self.setNZ(self.a);
                break :blk 6;
            },
            0x17 => blk: { // OR A,[dp]+Y
                const dp = self.fetch();
                const ptr = self.readDp16(dp);
                self.a |= self.read(ptr +% self.y);
                self.setNZ(self.a);
                break :blk 6;
            },
            0x09 => blk: { // OR dp,dp
                const src = self.fetch();
                const dst = self.fetch();
                const result = self.readDp(dst) | self.readDp(src);
                self.writeDp(dst, result);
                self.setNZ(result);
                break :blk 6;
            },
            0x18 => blk: { // OR dp,#imm
                const imm = self.fetch();
                const dp = self.fetch();
                const result = self.readDp(dp) | imm;
                self.writeDp(dp, result);
                self.setNZ(result);
                break :blk 5;
            },
            0x19 => blk: { // OR (X),(Y)
                const result = self.readDp(self.x) | self.readDp(self.y);
                self.writeDp(self.x, result);
                self.setNZ(result);
                break :blk 5;
            },
            0x48 => blk: { // EOR A,#imm
                self.a ^= self.fetch();
                self.setNZ(self.a);
                break :blk 2;
            },
            0x44 => blk: { // EOR A,dp
                const dp = self.fetch();
                self.a ^= self.readDp(dp);
                self.setNZ(self.a);
                break :blk 3;
            },
            0x54 => blk: { // EOR A,dp+X
                const dp = self.fetch();
                self.a ^= self.readDp(dp +% self.x);
                self.setNZ(self.a);
                break :blk 4;
            },
            0x45 => blk: { // EOR A,!abs
                const addr = self.fetch16();
                self.a ^= self.read(addr);
                self.setNZ(self.a);
                break :blk 4;
            },
            0x55 => blk: { // EOR A,!abs+X
                const addr = self.fetch16();
                self.a ^= self.read(addr +% self.x);
                self.setNZ(self.a);
                break :blk 5;
            },
            0x56 => blk: { // EOR A,!abs+Y
                const addr = self.fetch16();
                self.a ^= self.read(addr +% self.y);
                self.setNZ(self.a);
                break :blk 5;
            },
            0x46 => blk: { // EOR A,(X)
                self.a ^= self.readDp(self.x);
                self.setNZ(self.a);
                break :blk 3;
            },
            0x47 => blk: { // EOR A,[dp+X]
                const dp = self.fetch();
                const ptr = self.readDp16(dp +% self.x);
                self.a ^= self.read(ptr);
                self.setNZ(self.a);
                break :blk 6;
            },
            0x57 => blk: { // EOR A,[dp]+Y
                const dp = self.fetch();
                const ptr = self.readDp16(dp);
                self.a ^= self.read(ptr +% self.y);
                self.setNZ(self.a);
                break :blk 6;
            },
            0x49 => blk: { // EOR dp,dp
                const src = self.fetch();
                const dst = self.fetch();
                const result = self.readDp(dst) ^ self.readDp(src);
                self.writeDp(dst, result);
                self.setNZ(result);
                break :blk 6;
            },
            0x58 => blk: { // EOR dp,#imm
                const imm = self.fetch();
                const dp = self.fetch();
                const result = self.readDp(dp) ^ imm;
                self.writeDp(dp, result);
                self.setNZ(result);
                break :blk 5;
            },
            0x59 => blk: { // EOR (X),(Y)
                const result = self.readDp(self.x) ^ self.readDp(self.y);
                self.writeDp(self.x, result);
                self.setNZ(result);
                break :blk 5;
            },

            // =================================================================
            // ASL/LSR/ROL/ROR - Shifts and rotates
            // =================================================================
            0x1C => blk: { // ASL A
                self.psw = (self.psw & ~PSW.C) | ((self.a >> 7) & PSW.C);
                self.a <<= 1;
                self.setNZ(self.a);
                break :blk 2;
            },
            0x0B => blk: { // ASL dp
                const dp = self.fetch();
                var value = self.readDp(dp);
                self.psw = (self.psw & ~PSW.C) | ((value >> 7) & PSW.C);
                value <<= 1;
                self.writeDp(dp, value);
                self.setNZ(value);
                break :blk 4;
            },
            0x1B => blk: { // ASL dp+X
                const dp = self.fetch();
                var value = self.readDp(dp +% self.x);
                self.psw = (self.psw & ~PSW.C) | ((value >> 7) & PSW.C);
                value <<= 1;
                self.writeDp(dp +% self.x, value);
                self.setNZ(value);
                break :blk 5;
            },
            0x0C => blk: { // ASL !abs
                const addr = self.fetch16();
                var value = self.read(addr);
                self.psw = (self.psw & ~PSW.C) | ((value >> 7) & PSW.C);
                value <<= 1;
                self.write(addr, value);
                self.setNZ(value);
                break :blk 5;
            },
            0x5C => blk: { // LSR A
                self.psw = (self.psw & ~PSW.C) | (self.a & PSW.C);
                self.a >>= 1;
                self.setNZ(self.a);
                break :blk 2;
            },
            0x4B => blk: { // LSR dp
                const dp = self.fetch();
                var value = self.readDp(dp);
                self.psw = (self.psw & ~PSW.C) | (value & PSW.C);
                value >>= 1;
                self.writeDp(dp, value);
                self.setNZ(value);
                break :blk 4;
            },
            0x5B => blk: { // LSR dp+X
                const dp = self.fetch();
                var value = self.readDp(dp +% self.x);
                self.psw = (self.psw & ~PSW.C) | (value & PSW.C);
                value >>= 1;
                self.writeDp(dp +% self.x, value);
                self.setNZ(value);
                break :blk 5;
            },
            0x4C => blk: { // LSR !abs
                const addr = self.fetch16();
                var value = self.read(addr);
                self.psw = (self.psw & ~PSW.C) | (value & PSW.C);
                value >>= 1;
                self.write(addr, value);
                self.setNZ(value);
                break :blk 5;
            },
            0x3C => blk: { // ROL A
                const old_c: u8 = self.psw & PSW.C;
                self.psw = (self.psw & ~PSW.C) | ((self.a >> 7) & PSW.C);
                self.a = (self.a << 1) | old_c;
                self.setNZ(self.a);
                break :blk 2;
            },
            0x2B => blk: { // ROL dp
                const dp = self.fetch();
                var value = self.readDp(dp);
                const old_c: u8 = self.psw & PSW.C;
                self.psw = (self.psw & ~PSW.C) | ((value >> 7) & PSW.C);
                value = (value << 1) | old_c;
                self.writeDp(dp, value);
                self.setNZ(value);
                break :blk 4;
            },
            0x3B => blk: { // ROL dp+X
                const dp = self.fetch();
                var value = self.readDp(dp +% self.x);
                const old_c: u8 = self.psw & PSW.C;
                self.psw = (self.psw & ~PSW.C) | ((value >> 7) & PSW.C);
                value = (value << 1) | old_c;
                self.writeDp(dp +% self.x, value);
                self.setNZ(value);
                break :blk 5;
            },
            0x2C => blk: { // ROL !abs
                const addr = self.fetch16();
                var value = self.read(addr);
                const old_c: u8 = self.psw & PSW.C;
                self.psw = (self.psw & ~PSW.C) | ((value >> 7) & PSW.C);
                value = (value << 1) | old_c;
                self.write(addr, value);
                self.setNZ(value);
                break :blk 5;
            },
            0x7C => blk: { // ROR A
                const old_c: u8 = (self.psw & PSW.C) << 7;
                self.psw = (self.psw & ~PSW.C) | (self.a & PSW.C);
                self.a = (self.a >> 1) | old_c;
                self.setNZ(self.a);
                break :blk 2;
            },
            0x6B => blk: { // ROR dp
                const dp = self.fetch();
                var value = self.readDp(dp);
                const old_c: u8 = (self.psw & PSW.C) << 7;
                self.psw = (self.psw & ~PSW.C) | (value & PSW.C);
                value = (value >> 1) | old_c;
                self.writeDp(dp, value);
                self.setNZ(value);
                break :blk 4;
            },
            0x7B => blk: { // ROR dp+X
                const dp = self.fetch();
                var value = self.readDp(dp +% self.x);
                const old_c: u8 = (self.psw & PSW.C) << 7;
                self.psw = (self.psw & ~PSW.C) | (value & PSW.C);
                value = (value >> 1) | old_c;
                self.writeDp(dp +% self.x, value);
                self.setNZ(value);
                break :blk 5;
            },
            0x6C => blk: { // ROR !abs
                const addr = self.fetch16();
                var value = self.read(addr);
                const old_c: u8 = (self.psw & PSW.C) << 7;
                self.psw = (self.psw & ~PSW.C) | (value & PSW.C);
                value = (value >> 1) | old_c;
                self.write(addr, value);
                self.setNZ(value);
                break :blk 5;
            },
            0x9F => blk: { // XCN A - exchange nibbles
                self.a = (self.a << 4) | (self.a >> 4);
                self.setNZ(self.a);
                break :blk 5;
            },

            // =================================================================
            // Branch instructions
            // =================================================================
            0x2F => blk: { // BRA rel
                const offset: i8 = @bitCast(self.fetch());
                self.pc +%= @as(u16, @bitCast(@as(i16, offset)));
                break :blk 4;
            },
            // -----------------------------------------------------------------
            // BEQ rel ($F0) - Branch if Equal (Zero flag set)
            // -----------------------------------------------------------------
            // 2 bytes: $F0, signed_offset
            // 2 cycles (not taken) / 4 cycles (taken)
            // Flags: none affected
            //
            // Commonly paired with MOV instructions to create polling loops:
            //   MOV Y, $00F4   ; Read port 0
            //   BEQ loop       ; If zero, keep waiting
            //
            // When the sound driver is "stuck" in a BEQ loop, it's actually
            // working correctly - waiting for the main CPU to send commands.
            // -----------------------------------------------------------------
            0xF0 => blk: { // BEQ rel
                const offset: i8 = @bitCast(self.fetch());
                if (self.flagZ()) {
                    self.pc +%= @as(u16, @bitCast(@as(i16, offset)));
                    break :blk 4;
                }
                break :blk 2;
            },
            0xD0 => blk: { // BNE rel
                const offset: i8 = @bitCast(self.fetch());
                if (!self.flagZ()) {
                    self.pc +%= @as(u16, @bitCast(@as(i16, offset)));
                    break :blk 4;
                }
                break :blk 2;
            },
            0xB0 => blk: { // BCS rel
                const offset: i8 = @bitCast(self.fetch());
                if (self.flagC()) {
                    self.pc +%= @as(u16, @bitCast(@as(i16, offset)));
                    break :blk 4;
                }
                break :blk 2;
            },
            0x90 => blk: { // BCC rel
                const offset: i8 = @bitCast(self.fetch());
                if (!self.flagC()) {
                    self.pc +%= @as(u16, @bitCast(@as(i16, offset)));
                    break :blk 4;
                }
                break :blk 2;
            },
            0x70 => blk: { // BVS rel
                const offset: i8 = @bitCast(self.fetch());
                if (self.flagV()) {
                    self.pc +%= @as(u16, @bitCast(@as(i16, offset)));
                    break :blk 4;
                }
                break :blk 2;
            },
            0x50 => blk: { // BVC rel
                const offset: i8 = @bitCast(self.fetch());
                if (!self.flagV()) {
                    self.pc +%= @as(u16, @bitCast(@as(i16, offset)));
                    break :blk 4;
                }
                break :blk 2;
            },
            0x30 => blk: { // BMI rel
                const offset: i8 = @bitCast(self.fetch());
                if (self.flagN()) {
                    self.pc +%= @as(u16, @bitCast(@as(i16, offset)));
                    break :blk 4;
                }
                break :blk 2;
            },
            0x10 => blk: { // BPL rel
                const offset: i8 = @bitCast(self.fetch());
                if (!self.flagN()) {
                    self.pc +%= @as(u16, @bitCast(@as(i16, offset)));
                    break :blk 4;
                }
                break :blk 2;
            },

            // =================================================================
            // CBNE - Compare and branch if not equal
            // =================================================================
            0x2E => blk: { // CBNE dp,rel
                const dp = self.fetch();
                const offset: i8 = @bitCast(self.fetch());
                if (self.a != self.readDp(dp)) {
                    self.pc +%= @as(u16, @bitCast(@as(i16, offset)));
                    break :blk 7;
                }
                break :blk 5;
            },
            0xDE => blk: { // CBNE dp+X,rel
                const dp = self.fetch();
                const offset: i8 = @bitCast(self.fetch());
                if (self.a != self.readDp(dp +% self.x)) {
                    self.pc +%= @as(u16, @bitCast(@as(i16, offset)));
                    break :blk 8;
                }
                break :blk 6;
            },

            // =================================================================
            // DBNZ - Decrement and branch if not zero
            // =================================================================
            0x6E => blk: { // DBNZ dp,rel
                const dp = self.fetch();
                const offset: i8 = @bitCast(self.fetch());
                const value = self.readDp(dp) -% 1;
                self.writeDp(dp, value);
                if (value != 0) {
                    self.pc +%= @as(u16, @bitCast(@as(i16, offset)));
                    break :blk 7;
                }
                break :blk 5;
            },
            0xFE => blk: { // DBNZ Y,rel
                const offset: i8 = @bitCast(self.fetch());
                self.y -%= 1;
                if (self.y != 0) {
                    self.pc +%= @as(u16, @bitCast(@as(i16, offset)));
                    break :blk 6;
                }
                break :blk 4;
            },

            // =================================================================
            // JMP - Jump
            // =================================================================
            0x5F => blk: { // JMP !abs
                self.pc = self.fetch16();
                break :blk 3;
            },
            0x1F => blk: { // JMP [!abs+X]
                const addr = self.fetch16() +% self.x;
                const low = self.read(addr);
                const high = self.read(addr +% 1);
                self.pc = (@as(u16, high) << 8) | low;
                break :blk 6;
            },

            // =================================================================
            // CALL/RET - Subroutine
            // =================================================================
            0x3F => blk: { // CALL !abs
                const addr = self.fetch16();
                self.push16(self.pc);
                self.pc = addr;
                break :blk 8;
            },
            0x4F => blk: { // PCALL up
                const offset = self.fetch();
                self.push16(self.pc);
                self.pc = 0xFF00 | @as(u16, offset);
                break :blk 6;
            },
            0x6F => blk: { // RET
                self.pc = self.pop16();
                break :blk 5;
            },
            0x7F => blk: { // RETI
                self.psw = self.pop();
                self.pc = self.pop16();
                break :blk 6;
            },
            0x0F => blk: { // BRK
                self.push16(self.pc);
                self.push(self.psw);
                // B set, I CLEARED (vector-verified): unlike the 6502
                // family (where BRK sets I to mask further IRQs), the
                // SPC700 clears its I flag on BRK - I gates nothing on
                // the S-SMP anyway (no IRQ line is wired), so the flag
                // is just architectural state to get right.
                self.psw = (self.psw | PSW.B) & ~PSW.I;
                const low = self.read(0xFFDE);
                const high = self.read(0xFFDF);
                self.pc = (@as(u16, high) << 8) | low;
                break :blk 8;
            },

            // =================================================================
            // TCALL - Table call (0x01, 0x11, 0x21, ..., 0xF1)
            // =================================================================
            0x01, 0x11, 0x21, 0x31, 0x41, 0x51, 0x61, 0x71, 0x81, 0x91, 0xA1, 0xB1, 0xC1, 0xD1, 0xE1, 0xF1 => blk: {
                const n = (opcode >> 4);
                const vector_addr: u16 = 0xFFDE - (@as(u16, n) * 2);
                self.push16(self.pc);
                const low = self.read(vector_addr);
                const high = self.read(vector_addr + 1);
                self.pc = (@as(u16, high) << 8) | low;
                break :blk 8;
            },

            // =================================================================
            // PUSH/POP
            // =================================================================
            0x2D => blk: { // PUSH A
                self.push(self.a);
                break :blk 4;
            },
            0x4D => blk: { // PUSH X
                self.push(self.x);
                break :blk 4;
            },
            0x6D => blk: { // PUSH Y
                self.push(self.y);
                break :blk 4;
            },
            0x0D => blk: { // PUSH PSW
                self.push(self.psw);
                break :blk 4;
            },
            0xAE => blk: { // POP A
                self.a = self.pop();
                break :blk 4;
            },
            0xCE => blk: { // POP X
                self.x = self.pop();
                break :blk 4;
            },
            0xEE => blk: { // POP Y
                self.y = self.pop();
                break :blk 4;
            },
            0x8E => blk: { // POP PSW
                self.psw = self.pop();
                break :blk 4;
            },

            // =================================================================
            // Flag manipulation
            // =================================================================
            0x60 => blk: { // CLRC
                self.psw &= ~PSW.C;
                break :blk 2;
            },
            0x80 => blk: { // SETC
                self.psw |= PSW.C;
                break :blk 2;
            },
            0xED => blk: { // NOTC
                self.psw ^= PSW.C;
                break :blk 3;
            },
            0xE0 => blk: { // CLRV
                self.psw &= ~(PSW.V | PSW.H);
                break :blk 2;
            },
            0x20 => blk: { // CLRP
                self.psw &= ~PSW.P;
                break :blk 2;
            },
            0x40 => blk: { // SETP
                self.psw |= PSW.P;
                break :blk 2;
            },
            0xA0 => blk: { // EI
                self.psw |= PSW.I;
                break :blk 3;
            },
            0xC0 => blk: { // DI
                self.psw &= ~PSW.I;
                break :blk 3;
            },

            // =================================================================
            // SET1/CLR1 - Bit set/clear
            // =================================================================
            0x02, 0x22, 0x42, 0x62, 0x82, 0xA2, 0xC2, 0xE2 => blk: { // SET1 dp.n
                const dp = self.fetch();
                const bit: u3 = @truncate(opcode >> 5);
                var value = self.readDp(dp);
                value |= (@as(u8, 1) << bit);
                self.writeDp(dp, value);
                break :blk 4;
            },
            0x12, 0x32, 0x52, 0x72, 0x92, 0xB2, 0xD2, 0xF2 => blk: { // CLR1 dp.n
                const dp = self.fetch();
                const bit: u3 = @truncate(opcode >> 5);
                var value = self.readDp(dp);
                value &= ~(@as(u8, 1) << bit);
                self.writeDp(dp, value);
                break :blk 4;
            },

            // =================================================================
            // BBS/BBC - Branch on bit set/clear
            // =================================================================
            0x03, 0x23, 0x43, 0x63, 0x83, 0xA3, 0xC3, 0xE3 => blk: { // BBS dp.n,rel
                const dp = self.fetch();
                const offset: i8 = @bitCast(self.fetch());
                const bit: u3 = @truncate(opcode >> 5);
                const value = self.readDp(dp);
                if ((value & (@as(u8, 1) << bit)) != 0) {
                    self.pc +%= @as(u16, @bitCast(@as(i16, offset)));
                    break :blk 7;
                }
                break :blk 5;
            },
            0x13, 0x33, 0x53, 0x73, 0x93, 0xB3, 0xD3, 0xF3 => blk: { // BBC dp.n,rel
                const dp = self.fetch();
                const offset: i8 = @bitCast(self.fetch());
                const bit: u3 = @truncate(opcode >> 5);
                const value = self.readDp(dp);
                if ((value & (@as(u8, 1) << bit)) == 0) {
                    self.pc +%= @as(u16, @bitCast(@as(i16, offset)));
                    break :blk 7;
                }
                break :blk 5;
            },

            // =================================================================
            // TSET1/TCLR1 - Test and set/clear
            // =================================================================
            // Flag quirk (SingleStepTests-verified, and what fullsnes
            // documents): N/Z come from A - memory, a CMP - NOT from
            // A AND memory as many summaries claim. The hardware runs
            // the same compare for both instructions; only the
            // write-back differs (OR in vs AND out the mask in A).
            0x0E => blk: { // TSET1 !abs
                const addr = self.fetch16();
                const value = self.read(addr);
                self.setNZ(self.a -% value); // N/Z from the CMP A,mem
                self.write(addr, value | self.a); // memory = memory OR A
                break :blk 6;
            },
            0x4E => blk: { // TCLR1 !abs
                const addr = self.fetch16();
                const value = self.read(addr);
                self.setNZ(self.a -% value); // N/Z from the CMP A,mem
                self.write(addr, value & ~self.a); // memory = memory AND (NOT A)
                break :blk 6;
            },

            // =================================================================
            // MUL/DIV
            // =================================================================
            0xCF => blk: { // MUL YA
                const result: u16 = @as(u16, self.y) * @as(u16, self.a);
                self.setYA(result);
                self.setNZ(self.y); // N/Z based on high byte
                break :blk 9;
            },
            0x9E => blk: { // DIV YA,X
                // The hardware divider is a 9-bit non-restoring unit,
                // and its edge behavior is NOT "quotient or saturate":
                //   H = (Y.low_nibble >= X.low_nibble) - a nibble
                //       compare of the ORIGINAL registers, nothing to
                //       do with the division itself;
                //   V = (Y >= X) - i.e. the true quotient won't fit in
                //       8 bits;
                //   if the quotient fits in 9 bits (YA < X<<9) the
                //       result is the ordinary quotient/remainder pair
                //       (A gets the low 8 quotient bits even when V);
                //   otherwise the divider "wraps" mid-algorithm and
                //       produces the strange closed form below (both
                //       X=0 and tiny-X-huge-YA land here).
                // Algorithm from the hardware analysis used by
                // bsnes/higan and Mesen2; every branch vector-verified.
                const ya: u32 = self.getYA();
                const x: u32 = self.x;
                self.psw &= ~(PSW.V | PSW.H);
                if ((self.y & 0x0F) >= (self.x & 0x0F)) self.psw |= PSW.H;
                if (self.y >= self.x) self.psw |= PSW.V;
                if (@as(u32, self.y) < (x << 1)) {
                    // quotient fits in 9 bits: normal division
                    self.a = @truncate(ya / x);
                    self.y = @truncate(ya % x);
                } else {
                    // overflow path: the divider's wrapped closed form
                    self.a = @truncate(255 - (ya - (x << 9)) / (256 - x));
                    self.y = @truncate(x + (ya - (x << 9)) % (256 - x));
                }
                self.setNZ(self.a); // N/Z from the quotient byte only
                break :blk 12;
            },

            // =================================================================
            // DAA/DAS - BCD adjust
            // =================================================================
            0xDF => blk: { // DAA
                if (self.flagC() or self.a > 0x99) {
                    self.a +%= 0x60;
                    self.psw |= PSW.C;
                }
                if (self.flagH() or (self.a & 0x0F) > 0x09) {
                    self.a +%= 0x06;
                }
                self.setNZ(self.a);
                break :blk 3;
            },
            0xBE => blk: { // DAS
                if (!self.flagC() or self.a > 0x99) {
                    self.a -%= 0x60;
                    self.psw &= ~PSW.C;
                }
                if (!self.flagH() or (self.a & 0x0F) > 0x09) {
                    self.a -%= 0x06;
                }
                self.setNZ(self.a);
                break :blk 3;
            },

            // =================================================================
            // Misc
            // =================================================================
            0xEF => blk: { // SLEEP
                // Halt CPU until interrupt (we just do nothing)
                break :blk 3;
            },
            0xFF => blk: { // STOP
                // Halt CPU until reset (we just do nothing)
                break :blk 3;
            },

            // =================================================================
            // Bit manipulation with C flag
            // =================================================================
            0x0A => blk: { // OR1 C,mem.bit
                const addr_bits = self.fetch16();
                const addr = addr_bits & 0x1FFF;
                const bit: u3 = @truncate(addr_bits >> 13);
                const value = self.read(addr);
                if ((value & (@as(u8, 1) << bit)) != 0) {
                    self.psw |= PSW.C;
                }
                break :blk 5;
            },
            0x2A => blk: { // OR1 C,/mem.bit
                const addr_bits = self.fetch16();
                const addr = addr_bits & 0x1FFF;
                const bit: u3 = @truncate(addr_bits >> 13);
                const value = self.read(addr);
                if ((value & (@as(u8, 1) << bit)) == 0) {
                    self.psw |= PSW.C;
                }
                break :blk 5;
            },
            0x4A => blk: { // AND1 C,mem.bit
                const addr_bits = self.fetch16();
                const addr = addr_bits & 0x1FFF;
                const bit: u3 = @truncate(addr_bits >> 13);
                const value = self.read(addr);
                if ((value & (@as(u8, 1) << bit)) == 0) {
                    self.psw &= ~PSW.C;
                }
                break :blk 4;
            },
            0x6A => blk: { // AND1 C,/mem.bit
                const addr_bits = self.fetch16();
                const addr = addr_bits & 0x1FFF;
                const bit: u3 = @truncate(addr_bits >> 13);
                const value = self.read(addr);
                if ((value & (@as(u8, 1) << bit)) != 0) {
                    self.psw &= ~PSW.C;
                }
                break :blk 4;
            },
            0x8A => blk: { // EOR1 C,mem.bit
                const addr_bits = self.fetch16();
                const addr = addr_bits & 0x1FFF;
                const bit: u3 = @truncate(addr_bits >> 13);
                const value = self.read(addr);
                if ((value & (@as(u8, 1) << bit)) != 0) {
                    self.psw ^= PSW.C;
                }
                break :blk 5;
            },
            0xEA => blk: { // NOT1 mem.bit
                const addr_bits = self.fetch16();
                const addr = addr_bits & 0x1FFF;
                const bit: u3 = @truncate(addr_bits >> 13);
                var value = self.read(addr);
                value ^= (@as(u8, 1) << bit);
                self.write(addr, value);
                break :blk 5;
            },
            0xAA => blk: { // MOV1 C,mem.bit
                const addr_bits = self.fetch16();
                const addr = addr_bits & 0x1FFF;
                const bit: u3 = @truncate(addr_bits >> 13);
                const value = self.read(addr);
                if ((value & (@as(u8, 1) << bit)) != 0) {
                    self.psw |= PSW.C;
                } else {
                    self.psw &= ~PSW.C;
                }
                break :blk 4;
            },
            0xCA => blk: { // MOV1 mem.bit,C
                const addr_bits = self.fetch16();
                const addr = addr_bits & 0x1FFF;
                const bit: u3 = @truncate(addr_bits >> 13);
                var value = self.read(addr);
                if (self.flagC()) {
                    value |= (@as(u8, 1) << bit);
                } else {
                    value &= ~(@as(u8, 1) << bit);
                }
                self.write(addr, value);
                break :blk 6;
            },
        };

        self.cycles += cycles;
        self.updateTimers(cycles);
        return cycles;
    }

    // =========================================================================
    // ARITHMETIC HELPERS
    // =========================================================================

    /// Compare two values (sets N, Z, C flags)
    fn compare(self: *Spc700, a: u8, b: u8) void {
        const result = a -% b;
        self.setNZ(result);
        // C is set if a >= b (no borrow)
        if (a >= b) {
            self.psw |= PSW.C;
        } else {
            self.psw &= ~PSW.C;
        }
    }

    /// Add with carry, returns result and sets flags
    fn adc(self: *Spc700, a: u8, b: u8) u8 {
        const carry: u8 = if (self.flagC()) 1 else 0;
        const result16 = @as(u16, a) + @as(u16, b) + @as(u16, carry);
        const result: u8 = @truncate(result16);

        self.psw &= ~(PSW.N | PSW.Z | PSW.C | PSW.V | PSW.H);
        self.setNZ(result);
        if (result16 > 0xFF) self.psw |= PSW.C;

        // Overflow: sign of result differs from signs of both operands
        const overflow = ((a ^ result) & (b ^ result) & 0x80) != 0;
        if (overflow) self.psw |= PSW.V;

        // Half-carry: carry from bit 3 to bit 4
        if ((a & 0x0F) + (b & 0x0F) + carry > 0x0F) self.psw |= PSW.H;

        return result;
    }

    /// Subtract with borrow, returns result and sets flags
    fn sbc(self: *Spc700, a: u8, b: u8) u8 {
        const borrow: u8 = if (self.flagC()) 0 else 1;
        const result16 = @as(i16, a) - @as(i16, b) - @as(i16, borrow);
        const result: u8 = @truncate(@as(u16, @bitCast(result16)));

        self.psw &= ~(PSW.N | PSW.Z | PSW.C | PSW.V | PSW.H);
        self.setNZ(result);
        if (result16 >= 0) self.psw |= PSW.C; // No borrow

        // Overflow: sign of result differs from sign of first operand when signs differ
        const overflow = ((a ^ b) & (a ^ result) & 0x80) != 0;
        if (overflow) self.psw |= PSW.V;

        // Half-carry: no borrow from bit 4 to bit 3
        if ((a & 0x0F) >= (b & 0x0F) + borrow) self.psw |= PSW.H;

        return result;
    }

    // =========================================================================
    // DSP ACCESS
    // =========================================================================
    // The DSP's 128 registers are reached through $F2 (address) / $F3
    // (data). See dsp.zig for the full register map and synthesis logic.

    fn readDsp(self: *Spc700, addr: u8) u8 {
        const value = self.dsp.read(addr);
        if (comptime dbg.trace_apu) {
            std.debug.print("[SPC700] DSP read: ${x:0>2} = ${x:0>2}\n", .{ addr, value });
        }
        return value;
    }

    fn writeDsp(self: *Spc700, addr: u8, value: u8) void {
        if (comptime dbg.trace_apu) {
            std.debug.print("[SPC700] DSP write: ${x:0>2} = ${x:0>2}\n", .{ addr, value });
        }
        self.dsp.write(addr, value);
    }

    // =========================================================================
    // TIMER UPDATE
    // =========================================================================
    // Call this after each instruction to update timer state.
    // cycles_elapsed is the number of CPU cycles the instruction took.

    pub fn updateTimers(self: *Spc700, cycles_elapsed: u8) void {
        // Timer 0 & 1: Tick every 128 CPU cycles (~8 kHz)
        // Timer 2: Tick every 16 CPU cycles (~64 kHz)
        const timer_rates = [3]u16{ 128, 128, 16 };

        inline for (0..3) |i| {
            if (self.timer_enable[i]) {
                self.timer_cycles[i] += cycles_elapsed;

                while (self.timer_cycles[i] >= timer_rates[i]) {
                    self.timer_cycles[i] -= timer_rates[i];
                    self.timer_counter[i] +%= 1;

                    // Check if counter matches divisor (0 = 256)
                    const target: u16 = if (self.timer_div[i] == 0) 256 else self.timer_div[i];
                    if (self.timer_counter[i] >= target) {
                        self.timer_counter[i] = 0;
                        // Increment 4-bit output counter (wraps at 15->0)
                        self.timer_output[i] +%= 1;
                    }
                }
            }
        }
    }

    // =========================================================================
    // STACK OPERATIONS
    // =========================================================================
    // Stack is always in page 1 ($0100-$01FF)

    /// Push a byte onto the stack
    pub fn push(self: *Spc700, value: u8) void {
        self.ram[0x0100 | @as(u16, self.sp)] = value;
        self.sp -%= 1;
    }

    /// Pop a byte from the stack
    pub fn pop(self: *Spc700) u8 {
        self.sp +%= 1;
        return self.ram[0x0100 | @as(u16, self.sp)];
    }

    /// Push a 16-bit value (high byte first, like 6502)
    pub fn push16(self: *Spc700, value: u16) void {
        self.push(@truncate(value >> 8)); // High byte first
        self.push(@truncate(value)); // Low byte second
    }

    /// Pop a 16-bit value
    pub fn pop16(self: *Spc700) u16 {
        const low = self.pop();
        const high = self.pop();
        return (@as(u16, high) << 8) | low;
    }
};

// =============================================================================
// IPL BOOT ROM
// =============================================================================
// This is the actual 64-byte IPL ROM that's present in every SNES.
// It handles initial communication with the main CPU and receives
// the sound driver upload.
//
// Disassembly and explanation:
// FFC0: CD EF      MOV X,#$EF         ; X = $EF (stack pointer init)
// FFC2: BD         MOV SP,X           ; SP = $EF
// FFC3: E8 00      MOV A,#$00         ; A = 0
// FFC5: C6         MOV (X),A          ; Clear memory at $01EF
// FFC6: 1D         DEC X              ; X--
// FFC7: D0 FC      BNE $FFC5          ; Loop until X wraps (clears $0100-$01EF)
// FFC9: 8F AA F4   MOV $F4,#$AA       ; Port 0 = $AA (ready signal)
// FFCC: 8F BB F5   MOV $F5,#$BB       ; Port 1 = $BB (ready signal)
// FFCF: 78 CC F4   CMP $F4,#$CC       ; Wait for CPU to write $CC
// FFD2: D0 FB      BNE $FFCF          ; Loop until $CC received
// FFD4: 2F 19      BRA $FFEF          ; Jump to transfer loop
// FFD6: EB F4      MOV Y,$F4          ; Y = port 0 (index)
// FFD8: D0 FC      BNE $FFD6          ; Wait for index = 0
// FFDA: 7E F4      CMP Y,$F4          ; Compare Y with port 0
// FFDC: D0 0B      BNE $FFE9          ; If changed, check for new transfer
// FFDE: E4 F5      MOV A,$F5          ; A = port 1 (data byte)
// FFE0: CB F4      MOV $F4,Y          ; Echo index to acknowledge
// FFE2: D7 00      MOV [$00]+Y,A      ; Store data at [dest_addr] + Y
// FFE4: FC         INC Y              ; Y++
// FFE5: D0 F3      BNE $FFDA          ; Loop for more data
// FFE7: AB 01      INC $01            ; Increment high byte of dest
// FFE9: 10 EF      BPL $FFDA          ; Continue if port 0 positive
// FFEB: 7E F4      CMP Y,$F4          ; Check if new transfer start
// FFED: 10 EB      BPL $FFDA          ; Continue transfer
// FFEF: BA F6      MOVW YA,$F6        ; YA = ports 2-3 (address)
// FFF1: DA 00      MOVW $00,YA        ; Store destination address
// FFF3: BA F4      MOVW YA,$F4        ; YA = ports 0-1
// FFF5: C4 F4      MOV $F4,A          ; Echo port 0 value
// FFF7: DD         MOV A,Y            ; A = Y (port 1 value)
// FFF8: 5D         MOV X,A            ; X = A
// FFF9: D0 DB      BNE $FFD6          ; If port 1 != 0, continue transfer
// FFFB: 1F 00 00   JMP [$0000+X]      ; Jump to uploaded code
// FFFE: C0 FF      (Reset vector: $FFC0)
// =============================================================================

pub const IPL_ROM = [64]u8{
    0xCD, 0xEF, 0xBD, 0xE8, 0x00, 0xC6, 0x1D, 0xD0, // FFC0-FFC7
    0xFC, 0x8F, 0xAA, 0xF4, 0x8F, 0xBB, 0xF5, 0x78, // FFC8-FFCF
    0xCC, 0xF4, 0xD0, 0xFB, 0x2F, 0x19, 0xEB, 0xF4, // FFD0-FFD7
    0xD0, 0xFC, 0x7E, 0xF4, 0xD0, 0x0B, 0xE4, 0xF5, // FFD8-FFDF
    0xCB, 0xF4, 0xD7, 0x00, 0xFC, 0xD0, 0xF3, 0xAB, // FFE0-FFE7
    0x01, 0x10, 0xEF, 0x7E, 0xF4, 0x10, 0xEB, 0xBA, // FFE8-FFEF
    0xF6, 0xDA, 0x00, 0xBA, 0xF4, 0xC4, 0xF4, 0xDD, // FFF0-FFF7
    0x5D, 0xD0, 0xDB, 0x1F, 0x00, 0x00, 0xC0, 0xFF, // FFF8-FFFF
};

// =============================================================================
// TESTS
// =============================================================================

test "spc700 init" {
    const spc = Spc700.init();

    // Check initial register values
    try std.testing.expectEqual(@as(u8, 0), spc.a);
    try std.testing.expectEqual(@as(u8, 0), spc.x);
    try std.testing.expectEqual(@as(u8, 0), spc.y);
    try std.testing.expectEqual(@as(u8, 0xEF), spc.sp);
    try std.testing.expectEqual(@as(u16, 0xFFC0), spc.pc);
    try std.testing.expectEqual(@as(u8, 0), spc.psw);

    // Ports start at 0 - IPL ROM will write $AA/$BB after RAM clear
    try std.testing.expectEqual(@as(u8, 0), spc.port_out[0]);
    try std.testing.expectEqual(@as(u8, 0), spc.port_out[1]);

    // Check IPL ROM is enabled
    try std.testing.expect(spc.ipl_rom_enabled);
}

test "spc700 ipl rom read" {
    var spc = Spc700.init();

    // Should read from IPL ROM when enabled
    try std.testing.expectEqual(@as(u8, 0xCD), spc.read(0xFFC0));
    try std.testing.expectEqual(@as(u8, 0xEF), spc.read(0xFFC1));

    // Disable IPL ROM
    spc.ipl_rom_enabled = false;

    // Should now read from RAM (which is 0)
    try std.testing.expectEqual(@as(u8, 0), spc.read(0xFFC0));
}

test "spc700 direct page flag" {
    var spc = Spc700.init();

    // P flag clear = direct page at $0000
    try std.testing.expectEqual(@as(u16, 0x0000), spc.directPage());

    // Set P flag
    spc.psw |= PSW.P;
    try std.testing.expectEqual(@as(u16, 0x0100), spc.directPage());
}

test "spc700 ya register" {
    var spc = Spc700.init();

    spc.a = 0x34;
    spc.y = 0x12;
    try std.testing.expectEqual(@as(u16, 0x1234), spc.getYA());

    spc.setYA(0xABCD);
    try std.testing.expectEqual(@as(u8, 0xCD), spc.a);
    try std.testing.expectEqual(@as(u8, 0xAB), spc.y);
}

test "spc700 stack operations" {
    var spc = Spc700.init();

    // Push and pop
    spc.push(0x42);
    try std.testing.expectEqual(@as(u8, 0xEE), spc.sp);
    try std.testing.expectEqual(@as(u8, 0x42), spc.pop());
    try std.testing.expectEqual(@as(u8, 0xEF), spc.sp);

    // Push and pop 16-bit
    spc.push16(0x1234);
    try std.testing.expectEqual(@as(u16, 0x1234), spc.pop16());
}

test "spc700 port io" {
    var spc = Spc700.init();

    // Write to output port
    spc.write(0xF4, 0x55);
    try std.testing.expectEqual(@as(u8, 0x55), spc.port_out[0]);

    // Read from input port
    spc.port_in[1] = 0x77;
    try std.testing.expectEqual(@as(u8, 0x77), spc.read(0xF5));
}

test "spc700 timer output read clears" {
    var spc = Spc700.init();

    // Set timer output
    spc.timer_output[0] = 5;

    // Reading should return value and clear it
    try std.testing.expectEqual(@as(u8, 5), spc.read(0xFD));
    try std.testing.expectEqual(@as(u4, 0), spc.timer_output[0]);
}
