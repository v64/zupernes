// 65816 CPU Emulation (Ricoh 5A22)
const Bus = @import("../bus.zig").Bus;

/// Status register flags
pub const Flags = packed struct {
    c: bool = false, // Carry
    z: bool = false, // Zero
    i: bool = true, // IRQ disable (set on reset)
    d: bool = false, // Decimal mode
    x: bool = true, // Index register size (1=8bit, 0=16bit) - emulation mode default
    m: bool = true, // Accumulator size (1=8bit, 0=16bit) - emulation mode default
    v: bool = false, // Overflow
    n: bool = false, // Negative

    pub fn toByte(self: Flags) u8 {
        return @bitCast(self);
    }

    pub fn fromByte(byte: u8) Flags {
        return @bitCast(byte);
    }
};

pub const Cpu = struct {
    // Registers
    a: u16, // Accumulator (16-bit, but can be 8-bit in some modes)
    x: u16, // X index register
    y: u16, // Y index register
    sp: u16, // Stack pointer
    pc: u16, // Program counter
    dbr: u8, // Data bank register
    pbr: u8, // Program bank register
    dp: u16, // Direct page register
    p: Flags, // Processor status

    // Emulation mode flag (separate from P register)
    emulation_mode: bool,

    // Bus reference
    bus: *Bus,

    // Cycle counter for current instruction
    cycles: u8,

    // For debugging/tracing
    total_cycles: u64,

    pub fn init(bus: *Bus) Cpu {
        return Cpu{
            .a = 0,
            .x = 0,
            .y = 0,
            .sp = 0x01FF, // Stack starts at $01FF in emulation mode
            .pc = 0,
            .dbr = 0,
            .pbr = 0,
            .dp = 0,
            .p = Flags{},
            .emulation_mode = true, // CPU starts in emulation mode
            .bus = bus,
            .cycles = 0,
            .total_cycles = 0,
        };
    }

    pub fn reset(self: *Cpu) void {
        self.emulation_mode = true;
        self.p = Flags{ .i = true, .x = true, .m = true };
        self.sp = 0x01FF;
        self.dbr = 0;
        self.pbr = 0;
        self.dp = 0;

        // Read reset vector from $00:FFFC-FFFD
        const low = self.bus.read(0, 0xFFFC);
        const high = self.bus.read(0, 0xFFFD);
        self.pc = @as(u16, high) << 8 | low;
    }

    /// Execute one instruction, return cycles consumed
    pub fn step(self: *Cpu) u8 {
        self.cycles = 0;

        const opcode = self.fetchByte();
        self.executeOpcode(opcode);

        self.total_cycles += self.cycles;
        return self.cycles;
    }

    fn fetchByte(self: *Cpu) u8 {
        const value = self.bus.read(self.pbr, self.pc);
        self.pc +%= 1;
        self.cycles += 1;
        return value;
    }

    fn fetchWord(self: *Cpu) u16 {
        const low = self.fetchByte();
        const high = self.fetchByte();
        return @as(u16, high) << 8 | low;
    }

    fn pushByte(self: *Cpu, value: u8) void {
        self.bus.write(0, self.sp, value);
        self.sp -%= 1;
        if (self.emulation_mode) {
            self.sp = 0x0100 | (self.sp & 0xFF);
        }
    }

    fn pullByte(self: *Cpu) u8 {
        self.sp +%= 1;
        if (self.emulation_mode) {
            self.sp = 0x0100 | (self.sp & 0xFF);
        }
        return self.bus.read(0, self.sp);
    }

    fn setNZ8(self: *Cpu, value: u8) void {
        self.p.z = value == 0;
        self.p.n = (value & 0x80) != 0;
    }

    fn setNZ16(self: *Cpu, value: u16) void {
        self.p.z = value == 0;
        self.p.n = (value & 0x8000) != 0;
    }

    fn executeOpcode(self: *Cpu, opcode: u8) void {
        switch (opcode) {
            // NOP
            0xEA => self.cycles += 1,

            // CLC - Clear carry
            0x18 => {
                self.p.c = false;
                self.cycles += 1;
            },

            // SEC - Set carry
            0x38 => {
                self.p.c = true;
                self.cycles += 1;
            },

            // CLI - Clear interrupt disable
            0x58 => {
                self.p.i = false;
                self.cycles += 1;
            },

            // SEI - Set interrupt disable
            0x78 => {
                self.p.i = true;
                self.cycles += 1;
            },

            // CLD - Clear decimal mode
            0xD8 => {
                self.p.d = false;
                self.cycles += 1;
            },

            // SED - Set decimal mode
            0xF8 => {
                self.p.d = true;
                self.cycles += 1;
            },

            // CLV - Clear overflow
            0xB8 => {
                self.p.v = false;
                self.cycles += 1;
            },

            // XCE - Exchange carry and emulation
            0xFB => {
                const old_c = self.p.c;
                self.p.c = self.emulation_mode;
                self.emulation_mode = old_c;
                if (self.emulation_mode) {
                    self.p.x = true;
                    self.p.m = true;
                    self.sp = 0x0100 | (self.sp & 0xFF);
                }
                self.cycles += 1;
            },

            // REP - Reset processor status bits
            0xC2 => {
                const mask = self.fetchByte();
                const current = self.p.toByte();
                self.p = Flags.fromByte(current & ~mask);
                if (self.emulation_mode) {
                    self.p.x = true;
                    self.p.m = true;
                }
                self.cycles += 1;
            },

            // SEP - Set processor status bits
            0xE2 => {
                const mask = self.fetchByte();
                const current = self.p.toByte();
                self.p = Flags.fromByte(current | mask);
                self.cycles += 1;
            },

            // LDA immediate
            0xA9 => {
                if (self.p.m) {
                    const value = self.fetchByte();
                    self.a = (self.a & 0xFF00) | value;
                    self.setNZ8(@truncate(self.a));
                } else {
                    const value = self.fetchWord();
                    self.a = value;
                    self.setNZ16(self.a);
                }
                self.cycles += 1;
            },

            // LDX immediate
            0xA2 => {
                if (self.p.x) {
                    const value = self.fetchByte();
                    self.x = value;
                    self.setNZ8(@truncate(self.x));
                } else {
                    const value = self.fetchWord();
                    self.x = value;
                    self.setNZ16(self.x);
                }
                self.cycles += 1;
            },

            // LDY immediate
            0xA0 => {
                if (self.p.x) {
                    const value = self.fetchByte();
                    self.y = value;
                    self.setNZ8(@truncate(self.y));
                } else {
                    const value = self.fetchWord();
                    self.y = value;
                    self.setNZ16(self.y);
                }
                self.cycles += 1;
            },

            // STA absolute
            0x8D => {
                const addr = self.fetchWord();
                if (self.p.m) {
                    self.bus.write(self.dbr, addr, @truncate(self.a));
                } else {
                    self.bus.write(self.dbr, addr, @truncate(self.a));
                    self.bus.write(self.dbr, addr +% 1, @truncate(self.a >> 8));
                }
                self.cycles += 2;
            },

            // STX absolute
            0x8E => {
                const addr = self.fetchWord();
                if (self.p.x) {
                    self.bus.write(self.dbr, addr, @truncate(self.x));
                } else {
                    self.bus.write(self.dbr, addr, @truncate(self.x));
                    self.bus.write(self.dbr, addr +% 1, @truncate(self.x >> 8));
                }
                self.cycles += 2;
            },

            // STY absolute
            0x8C => {
                const addr = self.fetchWord();
                if (self.p.x) {
                    self.bus.write(self.dbr, addr, @truncate(self.y));
                } else {
                    self.bus.write(self.dbr, addr, @truncate(self.y));
                    self.bus.write(self.dbr, addr +% 1, @truncate(self.y >> 8));
                }
                self.cycles += 2;
            },

            // STZ absolute (store zero)
            0x9C => {
                const addr = self.fetchWord();
                self.bus.write(self.dbr, addr, 0);
                if (!self.p.m) {
                    self.bus.write(self.dbr, addr +% 1, 0);
                }
                self.cycles += 2;
            },

            // TAX - Transfer A to X
            0xAA => {
                if (self.p.x) {
                    self.x = self.a & 0xFF;
                    self.setNZ8(@truncate(self.x));
                } else {
                    self.x = self.a;
                    self.setNZ16(self.x);
                }
                self.cycles += 1;
            },

            // TAY - Transfer A to Y
            0xA8 => {
                if (self.p.x) {
                    self.y = self.a & 0xFF;
                    self.setNZ8(@truncate(self.y));
                } else {
                    self.y = self.a;
                    self.setNZ16(self.y);
                }
                self.cycles += 1;
            },

            // TXA - Transfer X to A
            0x8A => {
                if (self.p.m) {
                    self.a = (self.a & 0xFF00) | (self.x & 0xFF);
                    self.setNZ8(@truncate(self.a));
                } else {
                    self.a = self.x;
                    self.setNZ16(self.a);
                }
                self.cycles += 1;
            },

            // TYA - Transfer Y to A
            0x98 => {
                if (self.p.m) {
                    self.a = (self.a & 0xFF00) | (self.y & 0xFF);
                    self.setNZ8(@truncate(self.a));
                } else {
                    self.a = self.y;
                    self.setNZ16(self.a);
                }
                self.cycles += 1;
            },

            // TSX - Transfer SP to X
            0xBA => {
                if (self.p.x) {
                    self.x = self.sp & 0xFF;
                    self.setNZ8(@truncate(self.x));
                } else {
                    self.x = self.sp;
                    self.setNZ16(self.x);
                }
                self.cycles += 1;
            },

            // TXS - Transfer X to SP
            0x9A => {
                if (self.emulation_mode) {
                    self.sp = 0x0100 | (self.x & 0xFF);
                } else {
                    self.sp = self.x;
                }
                self.cycles += 1;
            },

            // INX - Increment X
            0xE8 => {
                if (self.p.x) {
                    self.x = (self.x & 0xFF00) | ((self.x +% 1) & 0xFF);
                    self.setNZ8(@truncate(self.x));
                } else {
                    self.x +%= 1;
                    self.setNZ16(self.x);
                }
                self.cycles += 1;
            },

            // INY - Increment Y
            0xC8 => {
                if (self.p.x) {
                    self.y = (self.y & 0xFF00) | ((self.y +% 1) & 0xFF);
                    self.setNZ8(@truncate(self.y));
                } else {
                    self.y +%= 1;
                    self.setNZ16(self.y);
                }
                self.cycles += 1;
            },

            // DEX - Decrement X
            0xCA => {
                if (self.p.x) {
                    self.x = (self.x & 0xFF00) | ((self.x -% 1) & 0xFF);
                    self.setNZ8(@truncate(self.x));
                } else {
                    self.x -%= 1;
                    self.setNZ16(self.x);
                }
                self.cycles += 1;
            },

            // DEY - Decrement Y
            0x88 => {
                if (self.p.x) {
                    self.y = (self.y & 0xFF00) | ((self.y -% 1) & 0xFF);
                    self.setNZ8(@truncate(self.y));
                } else {
                    self.y -%= 1;
                    self.setNZ16(self.y);
                }
                self.cycles += 1;
            },

            // INC A - Increment accumulator
            0x1A => {
                if (self.p.m) {
                    self.a = (self.a & 0xFF00) | ((self.a +% 1) & 0xFF);
                    self.setNZ8(@truncate(self.a));
                } else {
                    self.a +%= 1;
                    self.setNZ16(self.a);
                }
                self.cycles += 1;
            },

            // DEC A - Decrement accumulator
            0x3A => {
                if (self.p.m) {
                    self.a = (self.a & 0xFF00) | ((self.a -% 1) & 0xFF);
                    self.setNZ8(@truncate(self.a));
                } else {
                    self.a -%= 1;
                    self.setNZ16(self.a);
                }
                self.cycles += 1;
            },

            // JMP absolute
            0x4C => {
                self.pc = self.fetchWord();
                self.cycles += 1;
            },

            // JMP absolute long
            0x5C => {
                self.pc = self.fetchWord();
                self.pbr = self.fetchByte();
                self.cycles += 1;
            },

            // JSR absolute
            0x20 => {
                const addr = self.fetchWord();
                const return_addr = self.pc -% 1;
                self.pushByte(@truncate(return_addr >> 8));
                self.pushByte(@truncate(return_addr));
                self.pc = addr;
                self.cycles += 2;
            },

            // RTS - Return from subroutine
            0x60 => {
                const low = self.pullByte();
                const high = self.pullByte();
                self.pc = (@as(u16, high) << 8 | low) +% 1;
                self.cycles += 4;
            },

            // RTL - Return from subroutine long
            0x6B => {
                const low = self.pullByte();
                const high = self.pullByte();
                self.pbr = self.pullByte();
                self.pc = (@as(u16, high) << 8 | low) +% 1;
                self.cycles += 4;
            },

            // BRA - Branch always
            0x80 => {
                const offset: i8 = @bitCast(self.fetchByte());
                self.pc = @bitCast(@as(i16, @bitCast(self.pc)) +% offset);
                self.cycles += 1;
            },

            // BEQ - Branch if equal (Z=1)
            0xF0 => {
                const offset: i8 = @bitCast(self.fetchByte());
                if (self.p.z) {
                    self.pc = @bitCast(@as(i16, @bitCast(self.pc)) +% offset);
                    self.cycles += 1;
                }
            },

            // BNE - Branch if not equal (Z=0)
            0xD0 => {
                const offset: i8 = @bitCast(self.fetchByte());
                if (!self.p.z) {
                    self.pc = @bitCast(@as(i16, @bitCast(self.pc)) +% offset);
                    self.cycles += 1;
                }
            },

            // BCS - Branch if carry set (C=1)
            0xB0 => {
                const offset: i8 = @bitCast(self.fetchByte());
                if (self.p.c) {
                    self.pc = @bitCast(@as(i16, @bitCast(self.pc)) +% offset);
                    self.cycles += 1;
                }
            },

            // BCC - Branch if carry clear (C=0)
            0x90 => {
                const offset: i8 = @bitCast(self.fetchByte());
                if (!self.p.c) {
                    self.pc = @bitCast(@as(i16, @bitCast(self.pc)) +% offset);
                    self.cycles += 1;
                }
            },

            // BMI - Branch if minus (N=1)
            0x30 => {
                const offset: i8 = @bitCast(self.fetchByte());
                if (self.p.n) {
                    self.pc = @bitCast(@as(i16, @bitCast(self.pc)) +% offset);
                    self.cycles += 1;
                }
            },

            // BPL - Branch if plus (N=0)
            0x10 => {
                const offset: i8 = @bitCast(self.fetchByte());
                if (!self.p.n) {
                    self.pc = @bitCast(@as(i16, @bitCast(self.pc)) +% offset);
                    self.cycles += 1;
                }
            },

            // BVS - Branch if overflow set (V=1)
            0x70 => {
                const offset: i8 = @bitCast(self.fetchByte());
                if (self.p.v) {
                    self.pc = @bitCast(@as(i16, @bitCast(self.pc)) +% offset);
                    self.cycles += 1;
                }
            },

            // BVC - Branch if overflow clear (V=0)
            0x50 => {
                const offset: i8 = @bitCast(self.fetchByte());
                if (!self.p.v) {
                    self.pc = @bitCast(@as(i16, @bitCast(self.pc)) +% offset);
                    self.cycles += 1;
                }
            },

            // PHA - Push accumulator
            0x48 => {
                if (self.p.m) {
                    self.pushByte(@truncate(self.a));
                } else {
                    self.pushByte(@truncate(self.a >> 8));
                    self.pushByte(@truncate(self.a));
                }
                self.cycles += 1;
            },

            // PLA - Pull accumulator
            0x68 => {
                if (self.p.m) {
                    self.a = (self.a & 0xFF00) | self.pullByte();
                    self.setNZ8(@truncate(self.a));
                } else {
                    const low = self.pullByte();
                    const high = self.pullByte();
                    self.a = @as(u16, high) << 8 | low;
                    self.setNZ16(self.a);
                }
                self.cycles += 2;
            },

            // PHX - Push X
            0xDA => {
                if (self.p.x) {
                    self.pushByte(@truncate(self.x));
                } else {
                    self.pushByte(@truncate(self.x >> 8));
                    self.pushByte(@truncate(self.x));
                }
                self.cycles += 1;
            },

            // PLX - Pull X
            0xFA => {
                if (self.p.x) {
                    self.x = self.pullByte();
                    self.setNZ8(@truncate(self.x));
                } else {
                    const low = self.pullByte();
                    const high = self.pullByte();
                    self.x = @as(u16, high) << 8 | low;
                    self.setNZ16(self.x);
                }
                self.cycles += 2;
            },

            // PHY - Push Y
            0x5A => {
                if (self.p.x) {
                    self.pushByte(@truncate(self.y));
                } else {
                    self.pushByte(@truncate(self.y >> 8));
                    self.pushByte(@truncate(self.y));
                }
                self.cycles += 1;
            },

            // PLY - Pull Y
            0x7A => {
                if (self.p.x) {
                    self.y = self.pullByte();
                    self.setNZ8(@truncate(self.y));
                } else {
                    const low = self.pullByte();
                    const high = self.pullByte();
                    self.y = @as(u16, high) << 8 | low;
                    self.setNZ16(self.y);
                }
                self.cycles += 2;
            },

            // PHP - Push processor status
            0x08 => {
                self.pushByte(self.p.toByte());
                self.cycles += 1;
            },

            // PLP - Pull processor status
            0x28 => {
                self.p = Flags.fromByte(self.pullByte());
                if (self.emulation_mode) {
                    self.p.x = true;
                    self.p.m = true;
                }
                self.cycles += 2;
            },

            // WDM - Reserved (treated as 2-byte NOP)
            0x42 => {
                _ = self.fetchByte();
                self.cycles += 1;
            },

            // STP - Stop the processor
            0xDB => {
                // Halt - in a real implementation, we'd stop until reset
                self.cycles += 3;
            },

            // WAI - Wait for interrupt
            0xCB => {
                // In a real implementation, we'd wait for an interrupt
                self.cycles += 3;
            },

            else => {
                // Unimplemented opcode - treat as NOP for now
                self.cycles += 2;
            },
        }
    }
};

test "cpu init" {
    var ppu = @import("../ppu/ppu.zig").Ppu.init();
    var bus = Bus.init(&ppu);
    const cpu = Cpu.init(&bus);
    _ = cpu;
}

test "cpu flags" {
    var flags = Flags{};
    flags.c = true;
    flags.z = true;
    const byte = flags.toByte();
    const restored = Flags.fromByte(byte);
    try @import("std").testing.expect(restored.c == true);
    try @import("std").testing.expect(restored.z == true);
}
