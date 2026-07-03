// =============================================================================
// NEC uPD7725 / uPD77C25 DIGITAL SIGNAL PROCESSOR (Low-Level Emulation)
// =============================================================================
// The DSP-1 cartridge coprocessor (Super Mario Kart, Pilotwings, ...) is not
// custom silicon: it is an off-the-shelf NEC uPD77C25 DSP running an 8KB
// Nintendo-written microcode program. Rather than reimplementing that
// program's math command-by-command (high-level emulation, forever chasing
// bit-exactness), we emulate the DSP CPU itself and run the REAL microcode
// dump. Whatever the real chip computes, we compute - which is exactly the
// pixel-exact standard this project aims for. The same core also runs the
// DSP-2/3/4 microcodes unchanged, since those cartridges use the same CPU
// with different program ROMs.
//
// Architecture (a classic early-80s Harvard DSP):
//   - Program ROM:  2048 x 24-bit instructions (all execute in ONE cycle)
//   - Data ROM:     1024 x 16-bit constants (sine tables, reciprocals...)
//   - Data RAM:      256 x 16-bit words
//   - Two 16-bit accumulators A and B, each with its own flag set
//   - A hardware 16x16 signed multiplier that runs EVERY cycle: whatever is
//     in K and L is multiplied and the product latched into M (high) and
//     N (low) - multiplication is free, you just load K/L and read M/N
//   - DP: data RAM pointer with nibble-wise post-modify baked into every
//     ALU instruction; RP: data ROM pointer with optional post-decrement
//   - Host interface: DR (data register) + SR (status register), the only
//     two registers the SNES CPU can see
//
// Instruction word (24 bits), type in the top 2 bits:
//   00 OP  - ALU operation + register move + pointer adjust, all in one word
//   01 RT  - same as OP, then return (pop PC from call stack)
//   10 JP  - conditional/unconditional jumps and calls (50+ conditions)
//   11 LD  - load 16-bit immediate into any destination
//
// The instruction-set semantics below follow the MAME uPD7725 core
// (src/devices/cpu/upd7725/upd7725.cpp, BSD-3-Clause, R. Belmont - itself a
// conversion of byuu's public-domain implementation, the one validated
// bit-exact against real DSP-1 hardware). This file is an original Zig
// implementation written from that reference.
//
// Timing: 8.192MHz crystal, 4 clocks per instruction cycle = 2.048 MIPS.
// The emulator steps us at that rate from the master clock (see root.zig).
// =============================================================================

const std = @import("std");
const dbg = @import("../debug.zig");

pub const Upd7725 = struct {
    // ==========================================================================
    // MEMORIES
    // ==========================================================================
    /// 2048 24-bit instruction words (stored in u32 for convenience)
    program: [2048]u32,
    /// 1024 16-bit constant words (coefficient tables etc.)
    data_rom: [1024]u16,
    /// 256 16-bit working RAM words
    ram: [256]u16,

    // ==========================================================================
    // REGISTERS
    // ==========================================================================
    pc: u16, // program counter (11 bits used)
    stack: [16]u16, // call stack (real chip has 4 levels; mask keeps us safe)
    sp: u8, // stack pointer

    a: u16, // accumulator A
    b: u16, // accumulator B
    flaga: Flags, // flags for A
    flagb: Flags, // flags for B

    tr: u16, // temporary register
    trb: u16, // temporary register B
    dp: u8, // data RAM pointer (4-bit "column" + 4-bit "row")
    rp: u16, // data ROM pointer (10 bits used)

    k: u16, // multiplier input 1 } K*L runs every single
    l: u16, // multiplier input 2 } instruction cycle,
    m: u16, // product high (sign + top 15 bits) } results latched
    n: u16, // product low (low 15 bits << 1) } into M and N

    dr: u16, // host-visible data register
    sr: u16, // status register (host reads the high byte)
    so: u16, // serial out (unused by DSP-1 boards, kept for completeness)
    si: u16, // serial in (unused by DSP-1 boards)

    idb: u16, // internal data bus latch (the "move" value in OP instructions)

    /// Per-accumulator ALU flags. Note S1/OV1 are "sticky" overflow tracking:
    /// they let the microcode detect overflow across a CHAIN of additions,
    /// not just the last one (see the ov1 update rule in aluOp).
    const Flags = struct {
        c: bool = false, // carry / borrow
        z: bool = false, // zero
        s0: bool = false, // sign of last result
        s1: bool = false, // "true" sign tracking through overflows
        ov0: bool = false, // overflow of last add/sub
        ov1: bool = false, // sticky overflow parity
    };

    // Status register bit positions (16-bit SR; the SNES sees bits 15-8):
    //   bit 15 RQM  - "request for master": the DSP wants the host to
    //                 read/write DR. THE handshake bit games poll.
    //   bit 14 USF1, bit 13 USF0 - user flags (microcode-defined)
    //   bit 12 DRS  - DR transfer state: which half of a 16-bit transfer
    //                 comes next (0 = low byte, 1 = high byte)
    //   bit 11 DMA  - DMA-enabled transfer mode
    //   bit 10 DRC  - DR control: 0 = 16-bit transfers (two bus accesses),
    //                 1 = 8-bit transfers
    //   bit 9 SOC, bit 8 SIC - serial output/input control
    //   bit 7 EI   - interrupt enable
    //   bits 1,0 P1,P0 - general-purpose output pins
    const SR_RQM: u16 = 0x8000;
    const SR_DRS: u16 = 0x1000;
    const SR_DRC: u16 = 0x0400;

    pub fn init() Upd7725 {
        return .{
            .program = [_]u32{0} ** 2048,
            .data_rom = [_]u16{0} ** 1024,
            .ram = [_]u16{0} ** 256,
            .pc = 0,
            .stack = [_]u16{0} ** 16,
            .sp = 0,
            .a = 0,
            .b = 0,
            .flaga = .{},
            .flagb = .{},
            .tr = 0,
            .trb = 0,
            .dp = 0,
            .rp = 0,
            .k = 0,
            .l = 0,
            .m = 0,
            .n = 0,
            .dr = 0,
            .sr = 0,
            .so = 0,
            .si = 0,
            .idb = 0,
        };
    }

    /// Load an 8192-byte combined microcode dump (bsnes/higan ".rom" layout):
    /// 2048 x 3-byte little-endian program words, then 1024 x 2-byte
    /// little-endian data ROM words.
    pub fn loadRom(self: *Upd7725, bytes: []const u8) !void {
        if (bytes.len != 8192) return error.BadDspRomSize;
        for (0..2048) |i| {
            self.program[i] = @as(u32, bytes[i * 3]) |
                (@as(u32, bytes[i * 3 + 1]) << 8) |
                (@as(u32, bytes[i * 3 + 2]) << 16);
        }
        for (0..1024) |i| {
            self.data_rom[i] = @as(u16, bytes[6144 + i * 2]) |
                (@as(u16, bytes[6144 + i * 2 + 1]) << 8);
        }
    }

    pub fn reset(self: *Upd7725) void {
        // Preserve the loaded ROMs; clear all execution state.
        self.pc = 0;
        self.sp = 0;
        self.a = 0;
        self.b = 0;
        self.flaga = .{};
        self.flagb = .{};
        self.tr = 0;
        self.trb = 0;
        self.dp = 0;
        self.rp = 0;
        self.k = 0;
        self.l = 0;
        self.m = 0;
        self.n = 0;
        self.dr = 0;
        self.sr = 0;
        self.so = 0;
        self.si = 0;
        self.idb = 0;
        @memset(&self.ram, 0);
    }

    // ==========================================================================
    // HOST (SNES CPU) INTERFACE
    // ==========================================================================

    /// SR read: the SNES sees the high byte (RQM in bit 7 of the byte).
    pub fn readStatus(self: *const Upd7725) u8 {
        return @truncate(self.sr >> 8);
    }

    /// DR read. In 16-bit mode (DRC=0) two consecutive reads deliver low
    /// then high byte; the handshake bit RQM clears when the transfer
    /// completes, telling the microcode it may proceed.
    pub fn readData(self: *Upd7725) u8 {
        if ((self.sr & SR_DRC) == 0) {
            // 16-bit transfer: DRS tracks which half is next
            if ((self.sr & SR_DRS) == 0) {
                self.sr |= SR_DRS;
                return @truncate(self.dr);
            } else {
                self.sr &= ~(SR_RQM | SR_DRS);
                return @truncate(self.dr >> 8);
            }
        } else {
            // 8-bit transfer
            self.sr &= ~SR_RQM;
            return @truncate(self.dr);
        }
    }

    /// DR write (same half-tracking as readData).
    pub fn writeData(self: *Upd7725, value: u8) void {
        if ((self.sr & SR_DRC) == 0) {
            if ((self.sr & SR_DRS) == 0) {
                self.sr |= SR_DRS;
                self.dr = (self.dr & 0xFF00) | value;
            } else {
                self.sr &= ~(SR_RQM | SR_DRS);
                self.dr = (@as(u16, value) << 8) | (self.dr & 0x00FF);
            }
        } else {
            self.sr &= ~SR_RQM;
            self.dr = (self.dr & 0xFF00) | value;
        }
    }

    // ==========================================================================
    // EXECUTION CORE
    // ==========================================================================

    /// Execute one instruction (one 4-clock DSP cycle).
    pub fn step(self: *Upd7725) void {
        const opcode = self.program[self.pc & 0x7FF];
        self.pc = (self.pc + 1) & 0x7FF;

        switch (@as(u2, @truncate(opcode >> 22))) {
            0 => self.execOp(opcode),
            1 => { // RT: OP body, then return
                self.execOp(opcode);
                self.sp = (self.sp -% 1) & 0xF;
                self.pc = self.stack[self.sp] & 0x7FF;
            },
            2 => self.execJp(opcode),
            3 => self.execLd(opcode),
        }

        // The multiplier is combinational and always on: every cycle
        // M:N = K * L (signed). M gets sign + top 15 bits, N gets the low
        // 15 bits shifted left once (bit 0 always reads zero).
        const product = @as(i32, @as(i16, @bitCast(self.k))) * @as(i32, @as(i16, @bitCast(self.l)));
        self.m = @truncate(@as(u32, @bitCast(product >> 15)));
        self.n = @truncate(@as(u32, @bitCast(product)) << 1);
    }

    /// OP/RT instruction: in a single cycle the chip can (a) route any
    /// register onto the internal data bus, (b) run an ALU op on A or B
    /// against a selectable second operand, (c) store the bus value to any
    /// destination, and (d) post-adjust the RAM/ROM pointers. This is why
    /// DSP microcode is so dense: one word does the work of 3-4
    /// conventional-CPU instructions.
    fn execOp(self: *Upd7725, opcode: u32) void {
        const pselect: u2 = @truncate(opcode >> 20); // ALU operand P source
        const alu: u4 = @truncate(opcode >> 16); // ALU operation
        const asl: u1 = @truncate(opcode >> 15); // accumulator select
        const dpl: u2 = @truncate(opcode >> 13); // DP low-nibble adjust
        const dphm: u4 = @truncate(opcode >> 9); // DP high-nibble XOR mask
        const rpdcr: u1 = @truncate(opcode >> 8); // RP post-decrement
        const src: u4 = @truncate(opcode >> 4); // bus source
        const dst: u4 = @truncate(opcode); // bus destination

        // ---- Source: drive the internal data bus ----
        self.idb = switch (src) {
            0 => self.trb,
            1 => self.a,
            2 => self.b,
            3 => self.tr,
            4 => self.dp,
            5 => self.rp,
            6 => self.data_rom[self.rp & 0x3FF],
            // SGN: 0x8000 or 0x7FFF depending on the "true sign" flag -
            // used to saturate after an overflowed addition chain
            7 => 0x8000 -% @as(u16, @intFromBool(self.flaga.s1)),
            8 => blk: { // DR read, requesting the next host transfer
                self.sr |= SR_RQM;
                break :blk self.dr;
            },
            9 => self.dr, // DR read without handshake
            10 => self.sr,
            11 => self.si, // serial in, MSB-first (unused on DSP-1)
            12 => @bitReverse(self.si), // serial in, LSB-first
            13 => self.k,
            14 => self.l,
            15 => self.ram[self.dp & 0xFF],
        };

        // ---- ALU (operation 0 = none) ----
        if (alu != 0) {
            self.aluOp(alu, pselect, asl);
        }

        // ---- Destination: consume the bus value ----
        self.loadDest(dst, self.idb);

        // ---- Pointer post-modify ----
        // DP adjustments are suppressed when DP itself was the move
        // destination this cycle (the explicit load wins); same for RP.
        if (dst != 4) {
            switch (dpl) {
                0 => {}, // no change
                1 => self.dp = (self.dp & 0xF0) | ((self.dp +% 1) & 0x0F), // DPINC
                2 => self.dp = (self.dp & 0xF0) | ((self.dp -% 1) & 0x0F), // DPDEC
                3 => self.dp = self.dp & 0xF0, // DPCLR
            }
            self.dp ^= @as(u8, dphm) << 4;
        }
        if (rpdcr == 1 and dst != 5) {
            self.rp = (self.rp -% 1) & 0x3FF; // RP is physically 10 bits
        }
    }

    /// The 15 ALU operations, operating on accumulator `asl` against
    /// operand P. Flag behavior is the subtle part - see comments.
    fn aluOp(self: *Upd7725, alu: u4, pselect: u2, asl: u1) void {
        var p: u16 = switch (pselect) {
            0 => self.ram[self.dp & 0xFF],
            1 => self.idb,
            2 => self.m,
            3 => self.n,
        };

        // Carry-in comes from the OTHER accumulator's carry flag. This
        // hardware quirk is what makes 32-bit math work: you ADD the low
        // words into A, then ADC the high words into B, which consumes
        // A's carry.
        const q: u16 = if (asl == 0) self.a else self.b;
        var flag: Flags = if (asl == 0) self.flaga else self.flagb;
        const c_in: u16 = @intFromBool(if (asl == 0) self.flagb.c else self.flaga.c);

        const r: u16 = switch (alu) {
            0 => unreachable, // NOP handled by caller
            1 => q | p, // OR
            2 => q & p, // AND
            3 => q ^ p, // XOR
            4 => q -% p, // SUB
            5 => q +% p, // ADD
            6 => q -% p -% c_in, // SBB
            7 => q +% p +% c_in, // ADC
            8 => blk: { // DEC (p forced to 1 so overflow math below works)
                p = 1;
                break :blk q -% 1;
            },
            9 => blk: { // INC
                p = 1;
                break :blk q +% 1;
            },
            10 => ~q, // CMP (one's complement)
            11 => (q >> 1) | (q & 0x8000), // SHR1: arithmetic shift right
            12 => (q << 1) | c_in, // SHL1: rotate left through carry
            13 => (q << 2) | 3, // SHL2 (ones shifted in!)
            14 => (q << 4) | 15, // SHL4 (ones shifted in!)
            15 => (q << 8) | (q >> 8), // XCHG: byte swap
        };

        flag.s0 = (r & 0x8000) != 0;
        flag.z = r == 0;
        // S1 is the "true sign": it follows S0 only while no overflow has
        // been recorded, so after an overflowing add it still reports the
        // mathematically correct sign (used by the SGN saturation source).
        if (!flag.ov1) flag.s1 = flag.s0;

        switch (alu) {
            1, 2, 3, 10, 13, 14, 15 => {
                // Logical ops clear carry and both overflow trackers
                flag.c = false;
                flag.ov0 = false;
                flag.ov1 = false;
            },
            4, 5, 6, 7, 8, 9 => {
                if (alu & 1 == 1) {
                    // additions (ADD/ADC/INC)
                    flag.ov0 = ((q ^ r) & ~(q ^ p) & 0x8000) != 0;
                    flag.c = r < q;
                } else {
                    // subtractions (SUB/SBB/DEC)
                    flag.ov0 = ((q ^ r) & (q ^ p) & 0x8000) != 0;
                    flag.c = r > q;
                }
                // OV1 parity rule: overflows toggle it, EXCEPT that a new
                // overflow while OV1 is already set only keeps it set when
                // the sign didn't actually recover (s1 == s0). This tracks
                // whether the accumulated value is currently "wrapped".
                flag.ov1 = if (flag.ov0 and flag.ov1)
                    (flag.s1 == flag.s0)
                else
                    (flag.ov0 or flag.ov1);
            },
            11 => {
                flag.c = (q & 1) != 0; // bit shifted out
                flag.ov0 = false;
                flag.ov1 = false;
            },
            12 => {
                flag.c = (q >> 15) != 0; // bit shifted out
                flag.ov0 = false;
                flag.ov1 = false;
            },
            else => unreachable,
        }

        if (asl == 0) {
            self.a = r;
            self.flaga = flag;
        } else {
            self.b = r;
            self.flagb = flag;
        }
    }

    /// JP instruction: 9-bit condition code + 11-bit target address.
    fn execJp(self: *Upd7725, opcode: u32) void {
        const brch: u9 = @truncate(opcode >> 13); // branch condition
        const na: u16 = @truncate((opcode >> 2) & 0x7FF); // next address

        const cond: bool = switch (brch) {
            0x000 => { // JMPSO: computed jump via serial-out register
                self.pc = self.so & 0x7FF;
                return;
            },
            0x080 => !self.flaga.c, // JNCA
            0x082 => self.flaga.c, // JCA
            0x084 => !self.flagb.c, // JNCB
            0x086 => self.flagb.c, // JCB
            0x088 => !self.flaga.z, // JNZA
            0x08A => self.flaga.z, // JZA
            0x08C => !self.flagb.z, // JNZB
            0x08E => self.flagb.z, // JZB
            0x090 => !self.flaga.ov0, // JNOVA0
            0x092 => self.flaga.ov0, // JOVA0
            0x094 => !self.flagb.ov0, // JNOVB0
            0x096 => self.flagb.ov0, // JOVB0
            0x098 => !self.flaga.ov1, // JNOVA1
            0x09A => self.flaga.ov1, // JOVA1
            0x09C => !self.flagb.ov1, // JNOVB1
            0x09E => self.flagb.ov1, // JOVB1
            0x0A0 => !self.flaga.s0, // JNSA0
            0x0A2 => self.flaga.s0, // JSA0
            0x0A4 => !self.flagb.s0, // JNSB0
            0x0A6 => self.flagb.s0, // JSB0
            0x0A8 => !self.flaga.s1, // JNSA1
            0x0AA => self.flaga.s1, // JSA1
            0x0AC => !self.flagb.s1, // JNSB1
            0x0AE => self.flagb.s1, // JSB1
            0x0B0 => (self.dp & 0x0F) == 0x00, // JDPL0
            0x0B1 => (self.dp & 0x0F) != 0x00, // JDPLN0
            0x0B2 => (self.dp & 0x0F) == 0x0F, // JDPLF
            0x0B3 => (self.dp & 0x0F) != 0x0F, // JDPLNF
            // Serial ack flags: no serial port is wired on SNES cartridge
            // boards, so the ack lines are permanently 0 - "not acked"
            // jumps are always taken, "acked" jumps never are.
            0x0B4 => true, // JNSIAK
            0x0B6 => false, // JSIAK
            0x0B8 => true, // JNSOAK
            0x0BA => false, // JSOAK
            0x0BC => (self.sr & SR_RQM) == 0, // JNRQM
            0x0BE => (self.sr & SR_RQM) != 0, // JRQM
            0x100 => { // LJMP: unconditional
                self.pc = na;
                return;
            },
            0x140 => { // LCALL
                self.stack[self.sp & 0xF] = self.pc;
                self.sp = (self.sp +% 1) & 0xF;
                self.pc = na;
                return;
            },
            // HJMP (0x101) / HCALL (0x141) target the upper program bank,
            // which only exists on the bigger uPD96050 (ST010/ST011); the
            // 7725's PC is 11 bits so they alias onto LJMP/LCALL here.
            0x101 => {
                self.pc = na;
                return;
            },
            0x141 => {
                self.stack[self.sp & 0xF] = self.pc;
                self.sp = (self.sp +% 1) & 0xF;
                self.pc = na;
                return;
            },
            else => false, // undefined condition: fall through (no jump)
        };
        if (cond) {
            self.pc = na;
        }
    }

    /// LD instruction (also used internally to route OP move destinations).
    fn execLd(self: *Upd7725, opcode: u32) void {
        const id: u16 = @truncate(opcode >> 6);
        const dst: u4 = @truncate(opcode);
        self.idb = id;
        self.loadDest(dst, id);
    }

    fn loadDest(self: *Upd7725, dst: u4, value: u16) void {
        switch (dst) {
            0 => {}, // NON: discard
            1 => self.a = value,
            2 => self.b = value,
            3 => self.tr = value,
            4 => self.dp = @truncate(value),
            5 => self.rp = value & 0x3FF, // RP is physically 10 bits
            6 => { // DR load + request host transfer
                if (comptime dbg.trace_dsp) {
                    std.debug.print("[DSP1] present DR=${x:0>4} (pc={x:0>3})\n", .{ value, self.pc });
                }
                self.dr = value;
                self.sr |= SR_RQM;
            },
            7 => {
                // SR: the microcode cannot directly write RQM (bit 15),
                // DRS (bit 12), or bits 6-2 - those are hardware-managed.
                self.sr = (self.sr & 0x907C) | (value & ~@as(u16, 0x907C));
            },
            8 => self.so = @bitReverse(value), // serial out, LSB-first
            9 => self.so = value, // serial out, MSB-first
            10 => self.k = value,
            11 => { // K + ROM-addressed L: one-cycle table-lookup multiply setup
                self.k = value;
                self.l = self.data_rom[self.rp & 0x3FF];
            },
            12 => { // L + RAM-row-0x40-addressed K
                self.l = value;
                self.k = self.ram[(self.dp & 0xFF) | 0x40];
            },
            13 => self.l = value,
            14 => self.trb = value,
            15 => self.ram[self.dp & 0xFF] = value,
        }
    }
};

// =============================================================================
// TESTS
// =============================================================================

test "upd7725 multiplier runs every cycle" {
    var dsp = Upd7725.init();
    // Program: LD K,0x4000 ; LD L,0x2000 ; NOP(OP with alu=0)
    // LD encoding: type=3(<<22) | id<<6 | dst
    dsp.program[0] = (3 << 22) | (@as(u32, 0x4000) << 6) | 10; // K
    dsp.program[1] = (3 << 22) | (@as(u32, 0x2000) << 6) | 13; // L
    dsp.program[2] = 0; // OP nop
    dsp.step();
    dsp.step();
    dsp.step();
    // 0x4000 * 0x2000 = 0x08000000; M = product>>15 = 0x1000, N = low<<1 = 0
    try std.testing.expectEqual(@as(u16, 0x1000), dsp.m);
    try std.testing.expectEqual(@as(u16, 0), dsp.n);
}

test "upd7725 alu add sets carry and overflow" {
    var dsp = Upd7725.init();
    // LD A,0x7FFF ; OP A = A + A (pselect=1 idb, src=1 A -> idb, alu=5 ADD, asl=0)
    dsp.program[0] = (3 << 22) | (@as(u32, 0x7FFF) << 6) | 1;
    dsp.program[1] = (@as(u32, 1) << 20) | (@as(u32, 5) << 16) | (1 << 4);
    dsp.step();
    dsp.step();
    try std.testing.expectEqual(@as(u16, 0xFFFE), dsp.a);
    try std.testing.expect(dsp.flaga.ov0); // 0x7FFF+0x7FFF overflows signed
    try std.testing.expect(!dsp.flaga.c); // no unsigned carry
    try std.testing.expect(dsp.flaga.s0); // result negative as bits
    // S1 copies from S0 BEFORE OV1 latches, so the FIRST overflow does set
    // S1 = 1. That's not a bug - it's what makes the SGN saturation source
    // work: SGN = 0x8000 - S1 = 0x7FFF, the correct positive clamp for a
    // positive addition that overflowed. S1 freezes on SUBSEQUENT ops while
    // OV1 stays set.
    try std.testing.expect(dsp.flaga.s1);
    try std.testing.expect(dsp.flaga.ov1);
}

test "dsp1 microcode executes multiply command" {
    // End-to-end validation: boot the REAL DSP-1 microcode and drive its
    // simplest command, $00 Multiply: out = (a * b) >> 15 in 1.15 signed
    // fixed point. If this works, the interpreter, ROM decode, and host
    // protocol all agree with the actual chip's program.
    // Skipped when the (copyrighted, gitignored) microcode dump is absent.
    var buf: [8192]u8 = undefined;
    const data = std.fs.cwd().readFile("test/dsp/dsp1b.rom", &buf) catch
        return error.SkipZigTest;

    var dsp = Upd7725.init();
    try dsp.loadRom(data);

    const runner = struct {
        /// Run until the DSP requests a host transfer (RQM set), then a
        /// little longer. The extra steps model real bus latency: on
        /// hardware the SNES needs microseconds between the SR poll that
        /// observes RQM and its next DR access, during which the microcode
        /// keeps running (e.g. it raises RQM at $005 but only switches DR
        /// to 16-bit mode at $007 - acting instantly would hit a mode the
        /// real chip never exposes to the host).
        fn waitRqm(d: *Upd7725) !void {
            var steps: u32 = 0;
            while ((d.sr & Upd7725.SR_RQM) == 0) : (steps += 1) {
                if (steps > 1_000_000) return error.DspHung;
                d.step();
            }
            for (0..16) |_| d.step();
        }
        /// Write a 16-bit value LSB-first, honoring RQM before EACH byte
        /// like a real host: in 8-bit DR mode (DRC=1) the microcode must
        /// consume each byte and re-raise RQM before the next one; in
        /// 16-bit mode RQM stays set mid-pair so the second wait is free.
        fn write16(d: *Upd7725, v: u16) !void {
            try waitRqm(d);
            d.writeData(@truncate(v));
            try waitRqm(d);
            d.writeData(@truncate(v >> 8));
        }
        fn read16(d: *Upd7725) !u16 {
            try waitRqm(d);
            const lo: u16 = d.readData();
            try waitRqm(d);
            const hi: u16 = d.readData();
            return (hi << 8) | lo;
        }
    };

    // Command byte, then two 1.15 parameters: 0.5 * 0.5 = 0.25
    try runner.waitRqm(&dsp);
    dsp.writeData(0x00); // Multiply
    try runner.write16(&dsp, 0x4000); // 0.5
    // The microcode's multiply handler ($1ac in the DSP-1B program) moves
    // param 1 into K and re-raises RQM; checking K here pinpoints protocol
    // bugs (byte order, DRS phase) separately from ALU/multiplier bugs.
    try runner.waitRqm(&dsp);
    try std.testing.expectEqual(@as(u16, 0x4000), dsp.k);
    try runner.write16(&dsp, 0x4000); // 0.5
    try runner.waitRqm(&dsp);
    try std.testing.expectEqual(@as(u16, 0x4000), dsp.l);
    try std.testing.expectEqual(@as(u16, 0x2000), try runner.read16(&dsp)); // 0.25

    // And a signed case: 0.5 * -0.5 = -0.25 (0xC000 = -0.5, 0xE000 = -0.25)
    try runner.waitRqm(&dsp);
    dsp.writeData(0x00);
    try runner.write16(&dsp, 0x4000);
    try runner.write16(&dsp, 0xC000);
    try std.testing.expectEqual(@as(u16, 0xE000), try runner.read16(&dsp));
}

test "dsp1 microcode executes parameter command" {
    // Drive command $02 (Parameter - the projection setup Super Mario Kart
    // issues every frame) with inputs captured from an actual SMK race
    // frame, and require that the DSP produces four REAL result words. The
    // known failure mode this guards: a core bug making the handler bail
    // back to the command loop without loading results, which the host
    // observes as its own last parameter echoed back from a stale DR.
    var buf: [8192]u8 = undefined;
    const data = std.fs.cwd().readFile("test/dsp/dsp1b.rom", &buf) catch
        return error.SkipZigTest;

    var dsp = Upd7725.init();
    try dsp.loadRom(data);

    const runner = struct {
        fn waitRqm(d: *Upd7725) !void {
            var steps: u32 = 0;
            while ((d.sr & Upd7725.SR_RQM) == 0) : (steps += 1) {
                if (steps > 1_000_000) return error.DspHung;
                d.step();
            }
            for (0..16) |_| d.step();
        }
        fn write16(d: *Upd7725, v: u16) !void {
            try waitRqm(d);
            d.writeData(@truncate(v));
            try waitRqm(d);
            d.writeData(@truncate(v >> 8));
        }
        fn read16(d: *Upd7725) !u16 {
            try waitRqm(d);
            const lo: u16 = d.readData();
            try waitRqm(d);
            const hi: u16 = d.readData();
            return (hi << 8) | lo;
        }
    };

    // Parameter inputs captured from SMK Mario Circuit 1 (frame ~5395):
    // Fx=0x0880 Fy=0x27a0 Fz=0x0000 Lfe=0x0040 Les=0x0100 Aas=0x0000 Azs=0x3400
    try runner.waitRqm(&dsp);
    dsp.writeData(0x02);
    const params = [7]u16{ 0x0880, 0x27A0, 0x0000, 0x0040, 0x0100, 0x0000, 0x3400 };
    for (params) |p| try runner.write16(&dsp, p);

    const vof = try runner.read16(&dsp);
    const vva = try runner.read16(&dsp);
    const cx = try runner.read16(&dsp);
    const cy = try runner.read16(&dsp);

    // The stale-DR failure echoes Azs (0x3400) into every output. Real
    // results must differ from each other (Vof/Vva are raster numbers,
    // Cx/Cy screen coordinates - they can't all be equal).
    const all_same = vof == vva and vva == cx and cx == cy;
    if (all_same) {
        std.debug.print("parameter outputs stuck at {x:0>4} - DSP never presented results\n", .{vof});
        return error.ParameterCommandFailed;
    }
}

test "dsp1 boot conversation as captured from super mario kart" {
    // Replay the exact byte sequence SMK sends at race load (captured with
    // dbg.trace_dsp), including the $80 sync spam that precedes the first
    // command, at the coarse pacing our emulator integration provides
    // (a handful of DSP instructions between host accesses). This is the
    // conversation that builds the Mode 7 raster tables; if it desyncs,
    // the track renders flat.
    var buf: [8192]u8 = undefined;
    const data = std.fs.cwd().readFile("test/dsp/dsp1b.rom", &buf) catch
        return error.SkipZigTest;

    var dsp = Upd7725.init();
    try dsp.loadRom(data);

    const runner = struct {
        /// Game-speed pacing: an SR poll iteration on the SNES is ~10 CPU
        /// cycles ~= 6 DSP instructions. Poll RQM like the game does.
        fn pollRqm(d: *Upd7725) !void {
            var polls: u32 = 0;
            while (true) : (polls += 1) {
                if (polls > 100_000) return error.DspHung;
                for (0..6) |_| d.step();
                if ((d.readStatus() & 0x80) != 0) return;
            }
        }
        fn wr(d: *Upd7725, byte: u8) !void {
            try pollRqm(d);
            for (0..3) |_| d.step(); // poll-exit to STA latency
            d.writeData(byte);
        }
        fn rd(d: *Upd7725) !u8 {
            try pollRqm(d);
            for (0..3) |_| d.step();
            return d.readData();
        }
    };

    // $80 sync spam (game writes until the DSP is in a known state)
    for (0..14) |_| try runner.wr(&dsp, 0x80);

    // Command $02 Parameter, 7 params (values captured from the SMK trace)
    try runner.wr(&dsp, 0x02);
    const params = [_]u8{ 0x80, 0x08, 0xa0, 0x27, 0x00, 0x00, 0x40, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x34 };
    for (params) |p| try runner.wr(&dsp, p);

    // Read the 4 result words (Vof, Vva, Cx, Cy)
    var results: [4]u16 = undefined;
    for (&results) |*r| {
        const lo: u16 = try runner.rd(&dsp);
        const hi: u16 = try runner.rd(&dsp);
        r.* = (hi << 8) | lo;
    }

    // The observed in-game failure: all four outputs echo the last param
    // (0x3400) because the DSP never presented results.
    std.debug.print("parameter results: {x:0>4} {x:0>4} {x:0>4} {x:0>4}\n", .{ results[0], results[1], results[2], results[3] });
    const all_same = results[0] == results[1] and results[1] == results[2] and results[2] == results[3];
    try std.testing.expect(!all_same);
}

test "upd7725 16-bit host transfer protocol" {
    var dsp = Upd7725.init();
    dsp.dr = 0xBEEF;
    dsp.sr |= Upd7725.SR_RQM;
    // 16-bit mode (DRC=0): two reads, low byte then high, RQM clears at end
    try std.testing.expectEqual(@as(u8, 0xEF), dsp.readData());
    try std.testing.expectEqual(@as(u16, Upd7725.SR_RQM), dsp.sr & Upd7725.SR_RQM);
    try std.testing.expectEqual(@as(u8, 0xBE), dsp.readData());
    try std.testing.expectEqual(@as(u16, 0), dsp.sr & Upd7725.SR_RQM);
}
