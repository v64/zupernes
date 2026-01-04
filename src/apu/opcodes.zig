// =============================================================================
// SPC700 OPCODE TABLE
// =============================================================================
// Complete opcode definitions for the SPC700 processor.
// Each opcode includes:
//   - Mnemonic and addressing mode
//   - Byte length (1-3 bytes)
//   - Cycle count
//   - Flags affected
//
// REFERENCES:
// -----------------------------------------------------------------------------
// - https://snes.nesdev.org/wiki/SPC-700_instruction_set
// - https://wiki.superfamicom.org/spc700-reference
// - https://emudev.de/q00-snes/spc700-the-audio-processor/
//
// NOTATION:
// -----------------------------------------------------------------------------
// #imm     - Immediate 8-bit value
// dp       - Direct page address (8-bit, zero page or page 1)
// dp+X     - Direct page + X register
// dp+Y     - Direct page + Y register
// !abs     - Absolute 16-bit address
// !abs+X   - Absolute + X register
// !abs+Y   - Absolute + Y register
// [dp+X]   - Indirect through (dp+X), load 16-bit pointer
// [dp]+Y   - Indirect through (dp), then add Y
// (X)      - Indirect through X (direct page + X)
// (X)+     - Indirect through X with auto-increment
// rel      - PC-relative signed 8-bit offset (for branches)
// dp.bit   - Direct page address with bit number (0-7)
// mem.bit  - 13-bit address + 3-bit bit number
//
// FLAGS:
// -----------------------------------------------------------------------------
// N = Negative (bit 7 of result)
// V = Overflow (signed arithmetic overflow)
// H = Half-carry (carry from bit 3 to 4, for BCD)
// Z = Zero (result is zero)
// C = Carry (unsigned overflow)
// - = Flag not affected
// =============================================================================

const std = @import("std");

/// Addressing mode for an instruction
pub const AddrMode = enum {
    implied, // No operand
    accumulator, // Operates on A register
    immediate, // #imm
    direct, // dp
    direct_x, // dp+X
    direct_y, // dp+Y
    absolute, // !abs
    absolute_x, // !abs+X
    absolute_y, // !abs+Y
    indirect_x, // [dp+X]
    indirect_y, // [dp]+Y
    x_indirect, // (X)
    x_indirect_inc, // (X)+
    y_indirect, // (Y) - used for MOV (X),(Y) style
    relative, // rel (8-bit signed offset)
    direct_direct, // dp,dp (two direct page addresses)
    direct_imm, // dp,#imm
    direct_x_rel, // dp+X,rel (CBNE)
    direct_rel, // dp,rel (CBNE, DBNZ)
    bit_direct, // dp.bit (SET1, CLR1, BBS, BBC)
    bit_absolute, // mem.bit (AND1, OR1, EOR1, etc.)
    pcall, // $FFxx (8-bit operand)
    tcall, // Table call (no operand, index in opcode)
};

/// Instruction mnemonic
pub const Mnemonic = enum {
    // Data transfer
    MOV,
    MOVW,
    PUSH,
    POP,

    // Arithmetic
    ADC,
    SBC,
    CMP,
    INC,
    DEC,
    ADDW,
    SUBW,
    CMPW,
    INCW,
    DECW,
    MUL,
    DIV,

    // Logical
    AND,
    OR,
    EOR,

    // Shift/Rotate
    ASL,
    LSR,
    ROL,
    ROR,
    XCN,

    // Bit manipulation
    SET1,
    CLR1,
    TSET1,
    TCLR1,
    AND1,
    OR1,
    EOR1,
    NOT1,
    MOV1,

    // Branching
    BRA,
    BEQ,
    BNE,
    BCS,
    BCC,
    BVS,
    BVC,
    BMI,
    BPL,
    BBS,
    BBC,
    CBNE,
    DBNZ,
    JMP,

    // Subroutines
    CALL,
    PCALL,
    TCALL,
    RET,
    RETI,
    BRK,

    // Flag control
    CLRC,
    SETC,
    NOTC,
    CLRV,
    CLRP,
    SETP,
    EI,
    DI,

    // BCD
    DAA,
    DAS,

    // Misc
    NOP,
    SLEEP,
    STOP,
};

/// Opcode definition
pub const Opcode = struct {
    mnemonic: Mnemonic,
    mode: AddrMode,
    bytes: u8, // Instruction length in bytes
    cycles: u8, // Base cycle count
    // Note: Some instructions have variable cycles (branches taken/not taken)
};

// =============================================================================
// COMPLETE OPCODE TABLE
// =============================================================================
// Indexed by opcode byte (0x00-0xFF)
// Based on: https://snes.nesdev.org/wiki/SPC-700_instruction_set

pub const OPCODES: [256]Opcode = init_opcodes();

fn init_opcodes() [256]Opcode {
    var ops: [256]Opcode = undefined;

    // Initialize all to NOP as fallback
    for (&ops) |*op| {
        op.* = .{ .mnemonic = .NOP, .mode = .implied, .bytes = 1, .cycles = 2 };
    }

    // ==========================================================================
    // ROW 0x (0x00-0x0F)
    // ==========================================================================
    ops[0x00] = .{ .mnemonic = .NOP, .mode = .implied, .bytes = 1, .cycles = 2 };
    ops[0x01] = .{ .mnemonic = .TCALL, .mode = .tcall, .bytes = 1, .cycles = 8 }; // TCALL 0
    ops[0x02] = .{ .mnemonic = .SET1, .mode = .bit_direct, .bytes = 2, .cycles = 4 }; // SET1 dp.0
    ops[0x03] = .{ .mnemonic = .BBS, .mode = .bit_direct, .bytes = 3, .cycles = 5 }; // BBS dp.0,rel
    ops[0x04] = .{ .mnemonic = .OR, .mode = .direct, .bytes = 2, .cycles = 3 }; // OR A,dp
    ops[0x05] = .{ .mnemonic = .OR, .mode = .absolute, .bytes = 3, .cycles = 4 }; // OR A,!abs
    ops[0x06] = .{ .mnemonic = .OR, .mode = .x_indirect, .bytes = 1, .cycles = 3 }; // OR A,(X)
    ops[0x07] = .{ .mnemonic = .OR, .mode = .indirect_x, .bytes = 2, .cycles = 6 }; // OR A,[dp+X]
    ops[0x08] = .{ .mnemonic = .OR, .mode = .immediate, .bytes = 2, .cycles = 2 }; // OR A,#imm
    ops[0x09] = .{ .mnemonic = .OR, .mode = .direct_direct, .bytes = 3, .cycles = 6 }; // OR dp,dp
    ops[0x0A] = .{ .mnemonic = .OR1, .mode = .bit_absolute, .bytes = 3, .cycles = 5 }; // OR1 C,mem.bit
    ops[0x0B] = .{ .mnemonic = .ASL, .mode = .direct, .bytes = 2, .cycles = 4 }; // ASL dp
    ops[0x0C] = .{ .mnemonic = .ASL, .mode = .absolute, .bytes = 3, .cycles = 5 }; // ASL !abs
    ops[0x0D] = .{ .mnemonic = .PUSH, .mode = .implied, .bytes = 1, .cycles = 4 }; // PUSH PSW
    ops[0x0E] = .{ .mnemonic = .TSET1, .mode = .absolute, .bytes = 3, .cycles = 6 }; // TSET1 !abs
    ops[0x0F] = .{ .mnemonic = .BRK, .mode = .implied, .bytes = 1, .cycles = 8 }; // BRK

    // ==========================================================================
    // ROW 1x (0x10-0x1F)
    // ==========================================================================
    ops[0x10] = .{ .mnemonic = .BPL, .mode = .relative, .bytes = 2, .cycles = 2 }; // BPL rel (4 if taken)
    ops[0x11] = .{ .mnemonic = .TCALL, .mode = .tcall, .bytes = 1, .cycles = 8 }; // TCALL 1
    ops[0x12] = .{ .mnemonic = .CLR1, .mode = .bit_direct, .bytes = 2, .cycles = 4 }; // CLR1 dp.0
    ops[0x13] = .{ .mnemonic = .BBC, .mode = .bit_direct, .bytes = 3, .cycles = 5 }; // BBC dp.0,rel
    ops[0x14] = .{ .mnemonic = .OR, .mode = .direct_x, .bytes = 2, .cycles = 4 }; // OR A,dp+X
    ops[0x15] = .{ .mnemonic = .OR, .mode = .absolute_x, .bytes = 3, .cycles = 5 }; // OR A,!abs+X
    ops[0x16] = .{ .mnemonic = .OR, .mode = .absolute_y, .bytes = 3, .cycles = 5 }; // OR A,!abs+Y
    ops[0x17] = .{ .mnemonic = .OR, .mode = .indirect_y, .bytes = 2, .cycles = 6 }; // OR A,[dp]+Y
    ops[0x18] = .{ .mnemonic = .OR, .mode = .direct_imm, .bytes = 3, .cycles = 5 }; // OR dp,#imm
    ops[0x19] = .{ .mnemonic = .OR, .mode = .x_indirect, .bytes = 1, .cycles = 5 }; // OR (X),(Y)
    ops[0x1A] = .{ .mnemonic = .DECW, .mode = .direct, .bytes = 2, .cycles = 6 }; // DECW dp
    ops[0x1B] = .{ .mnemonic = .ASL, .mode = .direct_x, .bytes = 2, .cycles = 5 }; // ASL dp+X
    ops[0x1C] = .{ .mnemonic = .ASL, .mode = .accumulator, .bytes = 1, .cycles = 2 }; // ASL A
    ops[0x1D] = .{ .mnemonic = .DEC, .mode = .implied, .bytes = 1, .cycles = 2 }; // DEC X
    ops[0x1E] = .{ .mnemonic = .CMP, .mode = .absolute, .bytes = 3, .cycles = 4 }; // CMP X,!abs
    ops[0x1F] = .{ .mnemonic = .JMP, .mode = .indirect_x, .bytes = 3, .cycles = 6 }; // JMP [!abs+X]

    // ==========================================================================
    // ROW 2x (0x20-0x2F)
    // ==========================================================================
    ops[0x20] = .{ .mnemonic = .CLRP, .mode = .implied, .bytes = 1, .cycles = 2 }; // CLRP
    ops[0x21] = .{ .mnemonic = .TCALL, .mode = .tcall, .bytes = 1, .cycles = 8 }; // TCALL 2
    ops[0x22] = .{ .mnemonic = .SET1, .mode = .bit_direct, .bytes = 2, .cycles = 4 }; // SET1 dp.1
    ops[0x23] = .{ .mnemonic = .BBS, .mode = .bit_direct, .bytes = 3, .cycles = 5 }; // BBS dp.1,rel
    ops[0x24] = .{ .mnemonic = .AND, .mode = .direct, .bytes = 2, .cycles = 3 }; // AND A,dp
    ops[0x25] = .{ .mnemonic = .AND, .mode = .absolute, .bytes = 3, .cycles = 4 }; // AND A,!abs
    ops[0x26] = .{ .mnemonic = .AND, .mode = .x_indirect, .bytes = 1, .cycles = 3 }; // AND A,(X)
    ops[0x27] = .{ .mnemonic = .AND, .mode = .indirect_x, .bytes = 2, .cycles = 6 }; // AND A,[dp+X]
    ops[0x28] = .{ .mnemonic = .AND, .mode = .immediate, .bytes = 2, .cycles = 2 }; // AND A,#imm
    ops[0x29] = .{ .mnemonic = .AND, .mode = .direct_direct, .bytes = 3, .cycles = 6 }; // AND dp,dp
    ops[0x2A] = .{ .mnemonic = .OR1, .mode = .bit_absolute, .bytes = 3, .cycles = 5 }; // OR1 C,/mem.bit
    ops[0x2B] = .{ .mnemonic = .ROL, .mode = .direct, .bytes = 2, .cycles = 4 }; // ROL dp
    ops[0x2C] = .{ .mnemonic = .ROL, .mode = .absolute, .bytes = 3, .cycles = 5 }; // ROL !abs
    ops[0x2D] = .{ .mnemonic = .PUSH, .mode = .implied, .bytes = 1, .cycles = 4 }; // PUSH A
    ops[0x2E] = .{ .mnemonic = .CBNE, .mode = .direct_rel, .bytes = 3, .cycles = 5 }; // CBNE dp,rel
    ops[0x2F] = .{ .mnemonic = .BRA, .mode = .relative, .bytes = 2, .cycles = 4 }; // BRA rel

    // ==========================================================================
    // ROW 3x (0x30-0x3F)
    // ==========================================================================
    ops[0x30] = .{ .mnemonic = .BMI, .mode = .relative, .bytes = 2, .cycles = 2 }; // BMI rel
    ops[0x31] = .{ .mnemonic = .TCALL, .mode = .tcall, .bytes = 1, .cycles = 8 }; // TCALL 3
    ops[0x32] = .{ .mnemonic = .CLR1, .mode = .bit_direct, .bytes = 2, .cycles = 4 }; // CLR1 dp.1
    ops[0x33] = .{ .mnemonic = .BBC, .mode = .bit_direct, .bytes = 3, .cycles = 5 }; // BBC dp.1,rel
    ops[0x34] = .{ .mnemonic = .AND, .mode = .direct_x, .bytes = 2, .cycles = 4 }; // AND A,dp+X
    ops[0x35] = .{ .mnemonic = .AND, .mode = .absolute_x, .bytes = 3, .cycles = 5 }; // AND A,!abs+X
    ops[0x36] = .{ .mnemonic = .AND, .mode = .absolute_y, .bytes = 3, .cycles = 5 }; // AND A,!abs+Y
    ops[0x37] = .{ .mnemonic = .AND, .mode = .indirect_y, .bytes = 2, .cycles = 6 }; // AND A,[dp]+Y
    ops[0x38] = .{ .mnemonic = .AND, .mode = .direct_imm, .bytes = 3, .cycles = 5 }; // AND dp,#imm
    ops[0x39] = .{ .mnemonic = .AND, .mode = .x_indirect, .bytes = 1, .cycles = 5 }; // AND (X),(Y)
    ops[0x3A] = .{ .mnemonic = .INCW, .mode = .direct, .bytes = 2, .cycles = 6 }; // INCW dp
    ops[0x3B] = .{ .mnemonic = .ROL, .mode = .direct_x, .bytes = 2, .cycles = 5 }; // ROL dp+X
    ops[0x3C] = .{ .mnemonic = .ROL, .mode = .accumulator, .bytes = 1, .cycles = 2 }; // ROL A
    ops[0x3D] = .{ .mnemonic = .INC, .mode = .implied, .bytes = 1, .cycles = 2 }; // INC X
    ops[0x3E] = .{ .mnemonic = .CMP, .mode = .direct, .bytes = 2, .cycles = 3 }; // CMP X,dp
    ops[0x3F] = .{ .mnemonic = .CALL, .mode = .absolute, .bytes = 3, .cycles = 8 }; // CALL !abs

    // ==========================================================================
    // ROW 4x (0x40-0x4F)
    // ==========================================================================
    ops[0x40] = .{ .mnemonic = .SETP, .mode = .implied, .bytes = 1, .cycles = 2 }; // SETP
    ops[0x41] = .{ .mnemonic = .TCALL, .mode = .tcall, .bytes = 1, .cycles = 8 }; // TCALL 4
    ops[0x42] = .{ .mnemonic = .SET1, .mode = .bit_direct, .bytes = 2, .cycles = 4 }; // SET1 dp.2
    ops[0x43] = .{ .mnemonic = .BBS, .mode = .bit_direct, .bytes = 3, .cycles = 5 }; // BBS dp.2,rel
    ops[0x44] = .{ .mnemonic = .EOR, .mode = .direct, .bytes = 2, .cycles = 3 }; // EOR A,dp
    ops[0x45] = .{ .mnemonic = .EOR, .mode = .absolute, .bytes = 3, .cycles = 4 }; // EOR A,!abs
    ops[0x46] = .{ .mnemonic = .EOR, .mode = .x_indirect, .bytes = 1, .cycles = 3 }; // EOR A,(X)
    ops[0x47] = .{ .mnemonic = .EOR, .mode = .indirect_x, .bytes = 2, .cycles = 6 }; // EOR A,[dp+X]
    ops[0x48] = .{ .mnemonic = .EOR, .mode = .immediate, .bytes = 2, .cycles = 2 }; // EOR A,#imm
    ops[0x49] = .{ .mnemonic = .EOR, .mode = .direct_direct, .bytes = 3, .cycles = 6 }; // EOR dp,dp
    ops[0x4A] = .{ .mnemonic = .AND1, .mode = .bit_absolute, .bytes = 3, .cycles = 4 }; // AND1 C,mem.bit
    ops[0x4B] = .{ .mnemonic = .LSR, .mode = .direct, .bytes = 2, .cycles = 4 }; // LSR dp
    ops[0x4C] = .{ .mnemonic = .LSR, .mode = .absolute, .bytes = 3, .cycles = 5 }; // LSR !abs
    ops[0x4D] = .{ .mnemonic = .PUSH, .mode = .implied, .bytes = 1, .cycles = 4 }; // PUSH X
    ops[0x4E] = .{ .mnemonic = .TCLR1, .mode = .absolute, .bytes = 3, .cycles = 6 }; // TCLR1 !abs
    ops[0x4F] = .{ .mnemonic = .PCALL, .mode = .pcall, .bytes = 2, .cycles = 6 }; // PCALL up

    // ==========================================================================
    // ROW 5x (0x50-0x5F)
    // ==========================================================================
    ops[0x50] = .{ .mnemonic = .BVC, .mode = .relative, .bytes = 2, .cycles = 2 }; // BVC rel
    ops[0x51] = .{ .mnemonic = .TCALL, .mode = .tcall, .bytes = 1, .cycles = 8 }; // TCALL 5
    ops[0x52] = .{ .mnemonic = .CLR1, .mode = .bit_direct, .bytes = 2, .cycles = 4 }; // CLR1 dp.2
    ops[0x53] = .{ .mnemonic = .BBC, .mode = .bit_direct, .bytes = 3, .cycles = 5 }; // BBC dp.2,rel
    ops[0x54] = .{ .mnemonic = .EOR, .mode = .direct_x, .bytes = 2, .cycles = 4 }; // EOR A,dp+X
    ops[0x55] = .{ .mnemonic = .EOR, .mode = .absolute_x, .bytes = 3, .cycles = 5 }; // EOR A,!abs+X
    ops[0x56] = .{ .mnemonic = .EOR, .mode = .absolute_y, .bytes = 3, .cycles = 5 }; // EOR A,!abs+Y
    ops[0x57] = .{ .mnemonic = .EOR, .mode = .indirect_y, .bytes = 2, .cycles = 6 }; // EOR A,[dp]+Y
    ops[0x58] = .{ .mnemonic = .EOR, .mode = .direct_imm, .bytes = 3, .cycles = 5 }; // EOR dp,#imm
    ops[0x59] = .{ .mnemonic = .EOR, .mode = .x_indirect, .bytes = 1, .cycles = 5 }; // EOR (X),(Y)
    ops[0x5A] = .{ .mnemonic = .CMPW, .mode = .direct, .bytes = 2, .cycles = 4 }; // CMPW YA,dp
    ops[0x5B] = .{ .mnemonic = .LSR, .mode = .direct_x, .bytes = 2, .cycles = 5 }; // LSR dp+X
    ops[0x5C] = .{ .mnemonic = .LSR, .mode = .accumulator, .bytes = 1, .cycles = 2 }; // LSR A
    ops[0x5D] = .{ .mnemonic = .MOV, .mode = .implied, .bytes = 1, .cycles = 2 }; // MOV X,A
    ops[0x5E] = .{ .mnemonic = .CMP, .mode = .absolute, .bytes = 3, .cycles = 4 }; // CMP Y,!abs
    ops[0x5F] = .{ .mnemonic = .JMP, .mode = .absolute, .bytes = 3, .cycles = 3 }; // JMP !abs

    // ==========================================================================
    // ROW 6x (0x60-0x6F)
    // ==========================================================================
    ops[0x60] = .{ .mnemonic = .CLRC, .mode = .implied, .bytes = 1, .cycles = 2 }; // CLRC
    ops[0x61] = .{ .mnemonic = .TCALL, .mode = .tcall, .bytes = 1, .cycles = 8 }; // TCALL 6
    ops[0x62] = .{ .mnemonic = .SET1, .mode = .bit_direct, .bytes = 2, .cycles = 4 }; // SET1 dp.3
    ops[0x63] = .{ .mnemonic = .BBS, .mode = .bit_direct, .bytes = 3, .cycles = 5 }; // BBS dp.3,rel
    ops[0x64] = .{ .mnemonic = .CMP, .mode = .direct, .bytes = 2, .cycles = 3 }; // CMP A,dp
    ops[0x65] = .{ .mnemonic = .CMP, .mode = .absolute, .bytes = 3, .cycles = 4 }; // CMP A,!abs
    ops[0x66] = .{ .mnemonic = .CMP, .mode = .x_indirect, .bytes = 1, .cycles = 3 }; // CMP A,(X)
    ops[0x67] = .{ .mnemonic = .CMP, .mode = .indirect_x, .bytes = 2, .cycles = 6 }; // CMP A,[dp+X]
    ops[0x68] = .{ .mnemonic = .CMP, .mode = .immediate, .bytes = 2, .cycles = 2 }; // CMP A,#imm
    ops[0x69] = .{ .mnemonic = .CMP, .mode = .direct_direct, .bytes = 3, .cycles = 6 }; // CMP dp,dp
    ops[0x6A] = .{ .mnemonic = .AND1, .mode = .bit_absolute, .bytes = 3, .cycles = 4 }; // AND1 C,/mem.bit
    ops[0x6B] = .{ .mnemonic = .ROR, .mode = .direct, .bytes = 2, .cycles = 4 }; // ROR dp
    ops[0x6C] = .{ .mnemonic = .ROR, .mode = .absolute, .bytes = 3, .cycles = 5 }; // ROR !abs
    ops[0x6D] = .{ .mnemonic = .PUSH, .mode = .implied, .bytes = 1, .cycles = 4 }; // PUSH Y
    ops[0x6E] = .{ .mnemonic = .DBNZ, .mode = .direct_rel, .bytes = 3, .cycles = 5 }; // DBNZ dp,rel
    ops[0x6F] = .{ .mnemonic = .RET, .mode = .implied, .bytes = 1, .cycles = 5 }; // RET

    // ==========================================================================
    // ROW 7x (0x70-0x7F)
    // ==========================================================================
    ops[0x70] = .{ .mnemonic = .BVS, .mode = .relative, .bytes = 2, .cycles = 2 }; // BVS rel
    ops[0x71] = .{ .mnemonic = .TCALL, .mode = .tcall, .bytes = 1, .cycles = 8 }; // TCALL 7
    ops[0x72] = .{ .mnemonic = .CLR1, .mode = .bit_direct, .bytes = 2, .cycles = 4 }; // CLR1 dp.3
    ops[0x73] = .{ .mnemonic = .BBC, .mode = .bit_direct, .bytes = 3, .cycles = 5 }; // BBC dp.3,rel
    ops[0x74] = .{ .mnemonic = .CMP, .mode = .direct_x, .bytes = 2, .cycles = 4 }; // CMP A,dp+X
    ops[0x75] = .{ .mnemonic = .CMP, .mode = .absolute_x, .bytes = 3, .cycles = 5 }; // CMP A,!abs+X
    ops[0x76] = .{ .mnemonic = .CMP, .mode = .absolute_y, .bytes = 3, .cycles = 5 }; // CMP A,!abs+Y
    ops[0x77] = .{ .mnemonic = .CMP, .mode = .indirect_y, .bytes = 2, .cycles = 6 }; // CMP A,[dp]+Y
    ops[0x78] = .{ .mnemonic = .CMP, .mode = .direct_imm, .bytes = 3, .cycles = 5 }; // CMP dp,#imm
    ops[0x79] = .{ .mnemonic = .CMP, .mode = .x_indirect, .bytes = 1, .cycles = 5 }; // CMP (X),(Y)
    ops[0x7A] = .{ .mnemonic = .ADDW, .mode = .direct, .bytes = 2, .cycles = 5 }; // ADDW YA,dp
    ops[0x7B] = .{ .mnemonic = .ROR, .mode = .direct_x, .bytes = 2, .cycles = 5 }; // ROR dp+X
    ops[0x7C] = .{ .mnemonic = .ROR, .mode = .accumulator, .bytes = 1, .cycles = 2 }; // ROR A
    ops[0x7D] = .{ .mnemonic = .MOV, .mode = .implied, .bytes = 1, .cycles = 2 }; // MOV A,X
    ops[0x7E] = .{ .mnemonic = .CMP, .mode = .direct, .bytes = 2, .cycles = 3 }; // CMP Y,dp
    ops[0x7F] = .{ .mnemonic = .RETI, .mode = .implied, .bytes = 1, .cycles = 6 }; // RETI

    // ==========================================================================
    // ROW 8x (0x80-0x8F)
    // ==========================================================================
    ops[0x80] = .{ .mnemonic = .SETC, .mode = .implied, .bytes = 1, .cycles = 2 }; // SETC
    ops[0x81] = .{ .mnemonic = .TCALL, .mode = .tcall, .bytes = 1, .cycles = 8 }; // TCALL 8
    ops[0x82] = .{ .mnemonic = .SET1, .mode = .bit_direct, .bytes = 2, .cycles = 4 }; // SET1 dp.4
    ops[0x83] = .{ .mnemonic = .BBS, .mode = .bit_direct, .bytes = 3, .cycles = 5 }; // BBS dp.4,rel
    ops[0x84] = .{ .mnemonic = .ADC, .mode = .direct, .bytes = 2, .cycles = 3 }; // ADC A,dp
    ops[0x85] = .{ .mnemonic = .ADC, .mode = .absolute, .bytes = 3, .cycles = 4 }; // ADC A,!abs
    ops[0x86] = .{ .mnemonic = .ADC, .mode = .x_indirect, .bytes = 1, .cycles = 3 }; // ADC A,(X)
    ops[0x87] = .{ .mnemonic = .ADC, .mode = .indirect_x, .bytes = 2, .cycles = 6 }; // ADC A,[dp+X]
    ops[0x88] = .{ .mnemonic = .ADC, .mode = .immediate, .bytes = 2, .cycles = 2 }; // ADC A,#imm
    ops[0x89] = .{ .mnemonic = .ADC, .mode = .direct_direct, .bytes = 3, .cycles = 6 }; // ADC dp,dp
    ops[0x8A] = .{ .mnemonic = .EOR1, .mode = .bit_absolute, .bytes = 3, .cycles = 5 }; // EOR1 C,mem.bit
    ops[0x8B] = .{ .mnemonic = .DEC, .mode = .direct, .bytes = 2, .cycles = 4 }; // DEC dp
    ops[0x8C] = .{ .mnemonic = .DEC, .mode = .absolute, .bytes = 3, .cycles = 5 }; // DEC !abs
    ops[0x8D] = .{ .mnemonic = .MOV, .mode = .immediate, .bytes = 2, .cycles = 2 }; // MOV Y,#imm
    ops[0x8E] = .{ .mnemonic = .POP, .mode = .implied, .bytes = 1, .cycles = 4 }; // POP PSW
    ops[0x8F] = .{ .mnemonic = .MOV, .mode = .direct_imm, .bytes = 3, .cycles = 5 }; // MOV dp,#imm

    // ==========================================================================
    // ROW 9x (0x90-0x9F)
    // ==========================================================================
    ops[0x90] = .{ .mnemonic = .BCC, .mode = .relative, .bytes = 2, .cycles = 2 }; // BCC rel
    ops[0x91] = .{ .mnemonic = .TCALL, .mode = .tcall, .bytes = 1, .cycles = 8 }; // TCALL 9
    ops[0x92] = .{ .mnemonic = .CLR1, .mode = .bit_direct, .bytes = 2, .cycles = 4 }; // CLR1 dp.4
    ops[0x93] = .{ .mnemonic = .BBC, .mode = .bit_direct, .bytes = 3, .cycles = 5 }; // BBC dp.4,rel
    ops[0x94] = .{ .mnemonic = .ADC, .mode = .direct_x, .bytes = 2, .cycles = 4 }; // ADC A,dp+X
    ops[0x95] = .{ .mnemonic = .ADC, .mode = .absolute_x, .bytes = 3, .cycles = 5 }; // ADC A,!abs+X
    ops[0x96] = .{ .mnemonic = .ADC, .mode = .absolute_y, .bytes = 3, .cycles = 5 }; // ADC A,!abs+Y
    ops[0x97] = .{ .mnemonic = .ADC, .mode = .indirect_y, .bytes = 2, .cycles = 6 }; // ADC A,[dp]+Y
    ops[0x98] = .{ .mnemonic = .ADC, .mode = .direct_imm, .bytes = 3, .cycles = 5 }; // ADC dp,#imm
    ops[0x99] = .{ .mnemonic = .ADC, .mode = .x_indirect, .bytes = 1, .cycles = 5 }; // ADC (X),(Y)
    ops[0x9A] = .{ .mnemonic = .SUBW, .mode = .direct, .bytes = 2, .cycles = 5 }; // SUBW YA,dp
    ops[0x9B] = .{ .mnemonic = .DEC, .mode = .direct_x, .bytes = 2, .cycles = 5 }; // DEC dp+X
    ops[0x9C] = .{ .mnemonic = .DEC, .mode = .accumulator, .bytes = 1, .cycles = 2 }; // DEC A
    ops[0x9D] = .{ .mnemonic = .MOV, .mode = .implied, .bytes = 1, .cycles = 2 }; // MOV X,SP
    ops[0x9E] = .{ .mnemonic = .DIV, .mode = .implied, .bytes = 1, .cycles = 12 }; // DIV YA,X
    ops[0x9F] = .{ .mnemonic = .XCN, .mode = .accumulator, .bytes = 1, .cycles = 5 }; // XCN A

    // ==========================================================================
    // ROW Ax (0xA0-0xAF)
    // ==========================================================================
    ops[0xA0] = .{ .mnemonic = .EI, .mode = .implied, .bytes = 1, .cycles = 3 }; // EI
    ops[0xA1] = .{ .mnemonic = .TCALL, .mode = .tcall, .bytes = 1, .cycles = 8 }; // TCALL 10
    ops[0xA2] = .{ .mnemonic = .SET1, .mode = .bit_direct, .bytes = 2, .cycles = 4 }; // SET1 dp.5
    ops[0xA3] = .{ .mnemonic = .BBS, .mode = .bit_direct, .bytes = 3, .cycles = 5 }; // BBS dp.5,rel
    ops[0xA4] = .{ .mnemonic = .SBC, .mode = .direct, .bytes = 2, .cycles = 3 }; // SBC A,dp
    ops[0xA5] = .{ .mnemonic = .SBC, .mode = .absolute, .bytes = 3, .cycles = 4 }; // SBC A,!abs
    ops[0xA6] = .{ .mnemonic = .SBC, .mode = .x_indirect, .bytes = 1, .cycles = 3 }; // SBC A,(X)
    ops[0xA7] = .{ .mnemonic = .SBC, .mode = .indirect_x, .bytes = 2, .cycles = 6 }; // SBC A,[dp+X]
    ops[0xA8] = .{ .mnemonic = .SBC, .mode = .immediate, .bytes = 2, .cycles = 2 }; // SBC A,#imm
    ops[0xA9] = .{ .mnemonic = .SBC, .mode = .direct_direct, .bytes = 3, .cycles = 6 }; // SBC dp,dp
    ops[0xAA] = .{ .mnemonic = .MOV1, .mode = .bit_absolute, .bytes = 3, .cycles = 4 }; // MOV1 C,mem.bit
    ops[0xAB] = .{ .mnemonic = .INC, .mode = .direct, .bytes = 2, .cycles = 4 }; // INC dp
    ops[0xAC] = .{ .mnemonic = .INC, .mode = .absolute, .bytes = 3, .cycles = 5 }; // INC !abs
    ops[0xAD] = .{ .mnemonic = .CMP, .mode = .immediate, .bytes = 2, .cycles = 2 }; // CMP Y,#imm
    ops[0xAE] = .{ .mnemonic = .POP, .mode = .implied, .bytes = 1, .cycles = 4 }; // POP A
    ops[0xAF] = .{ .mnemonic = .MOV, .mode = .x_indirect_inc, .bytes = 1, .cycles = 4 }; // MOV (X)+,A

    // ==========================================================================
    // ROW Bx (0xB0-0xBF)
    // ==========================================================================
    ops[0xB0] = .{ .mnemonic = .BCS, .mode = .relative, .bytes = 2, .cycles = 2 }; // BCS rel
    ops[0xB1] = .{ .mnemonic = .TCALL, .mode = .tcall, .bytes = 1, .cycles = 8 }; // TCALL 11
    ops[0xB2] = .{ .mnemonic = .CLR1, .mode = .bit_direct, .bytes = 2, .cycles = 4 }; // CLR1 dp.5
    ops[0xB3] = .{ .mnemonic = .BBC, .mode = .bit_direct, .bytes = 3, .cycles = 5 }; // BBC dp.5,rel
    ops[0xB4] = .{ .mnemonic = .SBC, .mode = .direct_x, .bytes = 2, .cycles = 4 }; // SBC A,dp+X
    ops[0xB5] = .{ .mnemonic = .SBC, .mode = .absolute_x, .bytes = 3, .cycles = 5 }; // SBC A,!abs+X
    ops[0xB6] = .{ .mnemonic = .SBC, .mode = .absolute_y, .bytes = 3, .cycles = 5 }; // SBC A,!abs+Y
    ops[0xB7] = .{ .mnemonic = .SBC, .mode = .indirect_y, .bytes = 2, .cycles = 6 }; // SBC A,[dp]+Y
    ops[0xB8] = .{ .mnemonic = .SBC, .mode = .direct_imm, .bytes = 3, .cycles = 5 }; // SBC dp,#imm
    ops[0xB9] = .{ .mnemonic = .SBC, .mode = .x_indirect, .bytes = 1, .cycles = 5 }; // SBC (X),(Y)
    ops[0xBA] = .{ .mnemonic = .MOVW, .mode = .direct, .bytes = 2, .cycles = 5 }; // MOVW YA,dp
    ops[0xBB] = .{ .mnemonic = .INC, .mode = .direct_x, .bytes = 2, .cycles = 5 }; // INC dp+X
    ops[0xBC] = .{ .mnemonic = .INC, .mode = .accumulator, .bytes = 1, .cycles = 2 }; // INC A
    ops[0xBD] = .{ .mnemonic = .MOV, .mode = .implied, .bytes = 1, .cycles = 2 }; // MOV SP,X
    ops[0xBE] = .{ .mnemonic = .DAS, .mode = .implied, .bytes = 1, .cycles = 3 }; // DAS
    ops[0xBF] = .{ .mnemonic = .MOV, .mode = .x_indirect_inc, .bytes = 1, .cycles = 4 }; // MOV A,(X)+

    // ==========================================================================
    // ROW Cx (0xC0-0xCF)
    // ==========================================================================
    ops[0xC0] = .{ .mnemonic = .DI, .mode = .implied, .bytes = 1, .cycles = 3 }; // DI
    ops[0xC1] = .{ .mnemonic = .TCALL, .mode = .tcall, .bytes = 1, .cycles = 8 }; // TCALL 12
    ops[0xC2] = .{ .mnemonic = .SET1, .mode = .bit_direct, .bytes = 2, .cycles = 4 }; // SET1 dp.6
    ops[0xC3] = .{ .mnemonic = .BBS, .mode = .bit_direct, .bytes = 3, .cycles = 5 }; // BBS dp.6,rel
    ops[0xC4] = .{ .mnemonic = .MOV, .mode = .direct, .bytes = 2, .cycles = 4 }; // MOV dp,A
    ops[0xC5] = .{ .mnemonic = .MOV, .mode = .absolute, .bytes = 3, .cycles = 5 }; // MOV !abs,A
    ops[0xC6] = .{ .mnemonic = .MOV, .mode = .x_indirect, .bytes = 1, .cycles = 4 }; // MOV (X),A
    ops[0xC7] = .{ .mnemonic = .MOV, .mode = .indirect_x, .bytes = 2, .cycles = 7 }; // MOV [dp+X],A
    ops[0xC8] = .{ .mnemonic = .CMP, .mode = .immediate, .bytes = 2, .cycles = 2 }; // CMP X,#imm
    ops[0xC9] = .{ .mnemonic = .MOV, .mode = .absolute, .bytes = 3, .cycles = 5 }; // MOV !abs,X
    ops[0xCA] = .{ .mnemonic = .MOV1, .mode = .bit_absolute, .bytes = 3, .cycles = 6 }; // MOV1 mem.bit,C
    ops[0xCB] = .{ .mnemonic = .MOV, .mode = .direct, .bytes = 2, .cycles = 4 }; // MOV dp,Y
    ops[0xCC] = .{ .mnemonic = .MOV, .mode = .absolute, .bytes = 3, .cycles = 5 }; // MOV !abs,Y
    ops[0xCD] = .{ .mnemonic = .MOV, .mode = .immediate, .bytes = 2, .cycles = 2 }; // MOV X,#imm
    ops[0xCE] = .{ .mnemonic = .POP, .mode = .implied, .bytes = 1, .cycles = 4 }; // POP X
    ops[0xCF] = .{ .mnemonic = .MUL, .mode = .implied, .bytes = 1, .cycles = 9 }; // MUL YA

    // ==========================================================================
    // ROW Dx (0xD0-0xDF)
    // ==========================================================================
    ops[0xD0] = .{ .mnemonic = .BNE, .mode = .relative, .bytes = 2, .cycles = 2 }; // BNE rel
    ops[0xD1] = .{ .mnemonic = .TCALL, .mode = .tcall, .bytes = 1, .cycles = 8 }; // TCALL 13
    ops[0xD2] = .{ .mnemonic = .CLR1, .mode = .bit_direct, .bytes = 2, .cycles = 4 }; // CLR1 dp.6
    ops[0xD3] = .{ .mnemonic = .BBC, .mode = .bit_direct, .bytes = 3, .cycles = 5 }; // BBC dp.6,rel
    ops[0xD4] = .{ .mnemonic = .MOV, .mode = .direct_x, .bytes = 2, .cycles = 5 }; // MOV dp+X,A
    ops[0xD5] = .{ .mnemonic = .MOV, .mode = .absolute_x, .bytes = 3, .cycles = 6 }; // MOV !abs+X,A
    ops[0xD6] = .{ .mnemonic = .MOV, .mode = .absolute_y, .bytes = 3, .cycles = 6 }; // MOV !abs+Y,A
    ops[0xD7] = .{ .mnemonic = .MOV, .mode = .indirect_y, .bytes = 2, .cycles = 7 }; // MOV [dp]+Y,A
    ops[0xD8] = .{ .mnemonic = .MOV, .mode = .direct, .bytes = 2, .cycles = 4 }; // MOV dp,X
    ops[0xD9] = .{ .mnemonic = .MOV, .mode = .direct_y, .bytes = 2, .cycles = 5 }; // MOV dp+Y,X
    ops[0xDA] = .{ .mnemonic = .MOVW, .mode = .direct, .bytes = 2, .cycles = 5 }; // MOVW dp,YA
    ops[0xDB] = .{ .mnemonic = .MOV, .mode = .direct_x, .bytes = 2, .cycles = 5 }; // MOV dp+X,Y
    ops[0xDC] = .{ .mnemonic = .DEC, .mode = .implied, .bytes = 1, .cycles = 2 }; // DEC Y
    ops[0xDD] = .{ .mnemonic = .MOV, .mode = .implied, .bytes = 1, .cycles = 2 }; // MOV A,Y
    ops[0xDE] = .{ .mnemonic = .CBNE, .mode = .direct_x_rel, .bytes = 3, .cycles = 6 }; // CBNE dp+X,rel
    ops[0xDF] = .{ .mnemonic = .DAA, .mode = .implied, .bytes = 1, .cycles = 3 }; // DAA

    // ==========================================================================
    // ROW Ex (0xE0-0xEF)
    // ==========================================================================
    ops[0xE0] = .{ .mnemonic = .CLRV, .mode = .implied, .bytes = 1, .cycles = 2 }; // CLRV
    ops[0xE1] = .{ .mnemonic = .TCALL, .mode = .tcall, .bytes = 1, .cycles = 8 }; // TCALL 14
    ops[0xE2] = .{ .mnemonic = .SET1, .mode = .bit_direct, .bytes = 2, .cycles = 4 }; // SET1 dp.7
    ops[0xE3] = .{ .mnemonic = .BBS, .mode = .bit_direct, .bytes = 3, .cycles = 5 }; // BBS dp.7,rel
    ops[0xE4] = .{ .mnemonic = .MOV, .mode = .direct, .bytes = 2, .cycles = 3 }; // MOV A,dp
    ops[0xE5] = .{ .mnemonic = .MOV, .mode = .absolute, .bytes = 3, .cycles = 4 }; // MOV A,!abs
    ops[0xE6] = .{ .mnemonic = .MOV, .mode = .x_indirect, .bytes = 1, .cycles = 3 }; // MOV A,(X)
    ops[0xE7] = .{ .mnemonic = .MOV, .mode = .indirect_x, .bytes = 2, .cycles = 6 }; // MOV A,[dp+X]
    ops[0xE8] = .{ .mnemonic = .MOV, .mode = .immediate, .bytes = 2, .cycles = 2 }; // MOV A,#imm
    ops[0xE9] = .{ .mnemonic = .MOV, .mode = .absolute, .bytes = 3, .cycles = 4 }; // MOV X,!abs
    ops[0xEA] = .{ .mnemonic = .NOT1, .mode = .bit_absolute, .bytes = 3, .cycles = 5 }; // NOT1 mem.bit
    ops[0xEB] = .{ .mnemonic = .MOV, .mode = .direct, .bytes = 2, .cycles = 3 }; // MOV Y,dp
    ops[0xEC] = .{ .mnemonic = .MOV, .mode = .absolute, .bytes = 3, .cycles = 4 }; // MOV Y,!abs
    ops[0xED] = .{ .mnemonic = .NOTC, .mode = .implied, .bytes = 1, .cycles = 3 }; // NOTC
    ops[0xEE] = .{ .mnemonic = .POP, .mode = .implied, .bytes = 1, .cycles = 4 }; // POP Y
    ops[0xEF] = .{ .mnemonic = .SLEEP, .mode = .implied, .bytes = 1, .cycles = 3 }; // SLEEP

    // ==========================================================================
    // ROW Fx (0xF0-0xFF)
    // ==========================================================================
    ops[0xF0] = .{ .mnemonic = .BEQ, .mode = .relative, .bytes = 2, .cycles = 2 }; // BEQ rel
    ops[0xF1] = .{ .mnemonic = .TCALL, .mode = .tcall, .bytes = 1, .cycles = 8 }; // TCALL 15
    ops[0xF2] = .{ .mnemonic = .CLR1, .mode = .bit_direct, .bytes = 2, .cycles = 4 }; // CLR1 dp.7
    ops[0xF3] = .{ .mnemonic = .BBC, .mode = .bit_direct, .bytes = 3, .cycles = 5 }; // BBC dp.7,rel
    ops[0xF4] = .{ .mnemonic = .MOV, .mode = .direct_x, .bytes = 2, .cycles = 4 }; // MOV A,dp+X
    ops[0xF5] = .{ .mnemonic = .MOV, .mode = .absolute_x, .bytes = 3, .cycles = 5 }; // MOV A,!abs+X
    ops[0xF6] = .{ .mnemonic = .MOV, .mode = .absolute_y, .bytes = 3, .cycles = 5 }; // MOV A,!abs+Y
    ops[0xF7] = .{ .mnemonic = .MOV, .mode = .indirect_y, .bytes = 2, .cycles = 6 }; // MOV A,[dp]+Y
    ops[0xF8] = .{ .mnemonic = .MOV, .mode = .direct, .bytes = 2, .cycles = 3 }; // MOV X,dp
    ops[0xF9] = .{ .mnemonic = .MOV, .mode = .direct_y, .bytes = 2, .cycles = 4 }; // MOV X,dp+Y
    ops[0xFA] = .{ .mnemonic = .MOV, .mode = .direct_direct, .bytes = 3, .cycles = 5 }; // MOV dp,dp
    ops[0xFB] = .{ .mnemonic = .MOV, .mode = .direct_x, .bytes = 2, .cycles = 4 }; // MOV Y,dp+X
    ops[0xFC] = .{ .mnemonic = .INC, .mode = .implied, .bytes = 1, .cycles = 2 }; // INC Y
    ops[0xFD] = .{ .mnemonic = .MOV, .mode = .implied, .bytes = 1, .cycles = 2 }; // MOV Y,A
    ops[0xFE] = .{ .mnemonic = .DBNZ, .mode = .relative, .bytes = 2, .cycles = 4 }; // DBNZ Y,rel
    ops[0xFF] = .{ .mnemonic = .STOP, .mode = .implied, .bytes = 1, .cycles = 3 }; // STOP

    return ops;
}

// =============================================================================
// OPCODE HELPER FUNCTIONS
// =============================================================================

/// Get opcode info for a given opcode byte
pub fn getOpcode(opcode: u8) Opcode {
    return OPCODES[opcode];
}

/// Get the bit number from an opcode (for SET1/CLR1/BBS/BBC)
/// The bit number is encoded in the upper 3 bits of the opcode
pub fn getBitNumber(opcode: u8) u3 {
    return @truncate(opcode >> 5);
}

/// Get the TCALL index from an opcode
/// TCALL opcodes are x1 where x is 0-F (0x01, 0x11, 0x21, ..., 0xF1)
pub fn getTcallIndex(opcode: u8) u4 {
    return @truncate(opcode >> 4);
}

// =============================================================================
// TESTS
// =============================================================================

test "opcode table size" {
    try std.testing.expectEqual(@as(usize, 256), OPCODES.len);
}

test "nop opcode" {
    const nop = OPCODES[0x00];
    try std.testing.expectEqual(Mnemonic.NOP, nop.mnemonic);
    try std.testing.expectEqual(AddrMode.implied, nop.mode);
    try std.testing.expectEqual(@as(u8, 1), nop.bytes);
    try std.testing.expectEqual(@as(u8, 2), nop.cycles);
}

test "mov a,#imm opcode" {
    const mov = OPCODES[0xE8];
    try std.testing.expectEqual(Mnemonic.MOV, mov.mnemonic);
    try std.testing.expectEqual(AddrMode.immediate, mov.mode);
    try std.testing.expectEqual(@as(u8, 2), mov.bytes);
    try std.testing.expectEqual(@as(u8, 2), mov.cycles);
}

test "mul opcode" {
    const mul = OPCODES[0xCF];
    try std.testing.expectEqual(Mnemonic.MUL, mul.mnemonic);
    try std.testing.expectEqual(@as(u8, 9), mul.cycles);
}

test "div opcode" {
    const div = OPCODES[0x9E];
    try std.testing.expectEqual(Mnemonic.DIV, div.mnemonic);
    try std.testing.expectEqual(@as(u8, 12), div.cycles);
}

test "bit number extraction" {
    // SET1 dp.0 = 0x02
    try std.testing.expectEqual(@as(u3, 0), getBitNumber(0x02));
    // SET1 dp.7 = 0xE2
    try std.testing.expectEqual(@as(u3, 7), getBitNumber(0xE2));
}

test "tcall index extraction" {
    try std.testing.expectEqual(@as(u4, 0), getTcallIndex(0x01));
    try std.testing.expectEqual(@as(u4, 15), getTcallIndex(0xF1));
}
