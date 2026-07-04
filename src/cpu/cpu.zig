// =============================================================================
// 65816 CPU EMULATION (Ricoh 5A22)
// =============================================================================
// The SNES CPU is a Ricoh 5A22, which is a 65C816 core with additional features:
// - 16-bit accumulator and index registers (switchable to 8-bit)
// - 24-bit address bus (16MB address space)
// - Two modes: Emulation (6502 compatible) and Native (full 65816)
// - Hardware multiplication and division
// - DMA and HDMA controllers (handled in dma.zig)
//
// The 5A22 runs at 3.58 MHz (NTSC) or 3.55 MHz (PAL) in "fast" mode,
// and 2.68/2.66 MHz in "slow" mode depending on memory region accessed.
// =============================================================================

const std = @import("std");
const Bus = @import("../bus.zig").Bus;
const dbg = @import("../debug.zig");

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
    // Effective-address bank for the last data addressing-mode resolution.
    // The 65816's DBR-relative indexed modes (abs,X abs,Y (dp),Y [dp],Y
    // (sr,S),Y) form a full 24-bit address: DBR:addr + index CARRIES INTO
    // THE BANK BYTE rather than wrapping within the bank (verified by the
    // SingleStepTests vectors). The addr* helpers set this; data accesses
    // use it instead of DBR directly.
    ea_bank: u8,
    pbr: u8, // Program bank register
    dp: u16, // Direct page register
    p: Flags, // Processor status

    // Emulation mode flag (separate from P register)
    emulation_mode: bool,

    // Bus reference
    bus: *Bus,

    // Cycle counter for current instruction
    cycles: u8,

    // =========================================================================
    // PER-ACCESS MASTER-CYCLE ACCOUNTING
    // =========================================================================
    // On real hardware a "CPU cycle" is not a fixed length: each bus access
    // takes 6, 8, or 12 master-clock cycles depending on the memory region
    // (see Bus.memSpeed), and pure internal cycles take 6. Most SNES code
    // runs from SlowROM (8) and uses WRAM (8), so a flat 6-per-cycle model
    // makes the CPU ~30% too fast relative to the PPU/APU/DSP - enough to
    // break cycle-tuned code (Super Mario Kart writes DSP-1 parameters in a
    // blind loop timed to the uPD77C25's consume rate; at 6/cycle the writes
    // arrive before the previous parameter was consumed and the whole
    // conversation shifts by one word).
    //
    // The memory-access helpers below accumulate the true master-cycle cost
    // of every bus access here (mem_masters) and count the accesses
    // (mem_accesses); Emulator.step() then computes
    //   masters = mem_masters + (cycles - mem_accesses) * 6
    // so internal cycles cost 6 and accesses cost their real price.
    // `cycles` itself stays in untimed units - the SingleStepTests vectors
    // validate those counts and they remain the CPU-facing contract.
    mem_masters: u32,
    mem_accesses: u8,
    // Internal cycles already flushed to the DSP clock by accountAccess
    // (see there); Emulator.step ticks the DSP for the remainder.
    internal_flushed: u32,

    // For debugging/tracing
    total_cycles: u64,
    instruction_count: u64,

    // Interrupt flags
    nmi_pending: bool,
    irq_pending: bool,

    // WAI (wait for interrupt) state
    waiting: bool,

    pub fn init(bus: *Bus) Cpu {
        return Cpu{
            .a = 0,
            .x = 0,
            .y = 0,
            .sp = 0x01FF,
            .pc = 0,
            .dbr = 0,
            .ea_bank = 0,
            .pbr = 0,
            .dp = 0,
            .p = Flags{},
            .emulation_mode = true,
            .bus = bus,
            .cycles = 0,
            .mem_masters = 0,
            .mem_accesses = 0,
            .internal_flushed = 0,
            .total_cycles = 0,
            .instruction_count = 0,
            .nmi_pending = false,
            .irq_pending = false,
            .waiting = false,
        };
    }

    /// Trigger NMI (called at start of VBlank if NMI is enabled)
    pub fn triggerNmi(self: *Cpu) void {
        self.nmi_pending = true;
        self.waiting = false; // Wake from WAI
    }

    /// Trigger IRQ
    pub fn triggerIrq(self: *Cpu) void {
        self.irq_pending = true;
        self.waiting = false; // Wake from WAI
    }

    pub fn reset(self: *Cpu) void {
        self.emulation_mode = true;
        self.p = Flags{ .i = true, .x = true, .m = true };
        self.sp = 0x01FF;
        self.dbr = 0;
        self.pbr = 0;
        self.dp = 0;
        self.nmi_pending = false;
        self.irq_pending = false;
        self.waiting = false;
        self.instruction_count = 0;
        self.total_cycles = 0;

        const low = self.bus.read(0, 0xFFFC);
        const high = self.bus.read(0, 0xFFFD);
        self.pc = @as(u16, high) << 8 | low;
    }

    pub fn step(self: *Cpu) u8 {
        self.cycles = 0;
        self.mem_masters = 0;
        self.mem_accesses = 0;
        self.internal_flushed = 0;

        // =====================================================================
        // INTERRUPT HANDLING
        // =====================================================================
        // Interrupts are checked before each instruction. Priority: RESET > NMI > IRQ
        // NMI (Non-Maskable Interrupt): Triggered at VBlank start, cannot be disabled
        // IRQ (Interrupt Request): Can be disabled via I flag in status register
        // =====================================================================
        if (self.nmi_pending) {
            self.nmi_pending = false;
            self.handleNmi();
            self.total_cycles += self.cycles;
            return self.cycles;
        }

        if (self.irq_pending and !self.p.i) {
            self.irq_pending = false;
            self.handleIrq();
            self.total_cycles += self.cycles;
            return self.cycles;
        }

        // WAI instruction puts CPU to sleep until next interrupt
        if (self.waiting) {
            self.cycles = 1;
            self.total_cycles += self.cycles;
            return self.cycles;
        }

        // =====================================================================
        // INSTRUCTION FETCH AND TRACE
        // =====================================================================
        const trace_pc = self.pc;
        const opcode = self.fetchByte();

        // CPU trace controlled by debug.zig configuration
        if (comptime dbg.trace_cpu) {
            std.debug.print("[{d:0>6}] ${x:0>2}:{x:0>4} op=${x:0>2} A=${x:0>4} X=${x:0>4} Y=${x:0>4} S=${x:0>4} P=${x:0>2}\n", .{
                self.instruction_count,
                self.pbr,
                trace_pc,
                opcode,
                self.a,
                self.x,
                self.y,
                self.sp,
                self.p.toByte(),
            });
        }

        self.instruction_count += 1;
        // In emulation mode SPH physically doesn't exist at REST: between
        // instructions the stack pointer reads as $01xx no matter what was
        // loaded into it (SingleStepTests vectors seed rogue SPH values and
        // expect final SP pinned). DURING execution two behaviors coexist:
        // the original instruction set wraps within page 1
        // (pushByte/pullByte), while the eight "new" 65816 stack
        // instructions (PEA/PEI/PER/PHD/PLD/PLB/JSL/RTL) run full 16-bit SP
        // arithmetic - their stack ACCESSES can walk out of page 1 (e.g.
        // RTL from SP=$01FD reads $01FE/$01FF/$0200) even though the SP
        // they leave behind still pins back to $01xx at rest. Hence: pin
        // before AND after executing (before = defensive for externally
        // seeded state; after = the architectural rest state the vectors
        // verify).
        if (self.emulation_mode) {
            self.sp = 0x0100 | (self.sp & 0xFF);
        }
        self.executeOpcode(opcode);
        if (self.emulation_mode) {
            self.sp = 0x0100 | (self.sp & 0xFF);
        }
        self.total_cycles += self.cycles;
        return self.cycles;
    }

    fn handleNmi(self: *Cpu) void {
        self.cycles = 7;

        if (self.emulation_mode) {
            // Emulation mode: push PC and P
            self.pushByte(@truncate(self.pc >> 8));
            self.pushByte(@truncate(self.pc));
            self.pushByte(self.p.toByte() & 0xEF); // Clear B flag in pushed value
        } else {
            // Native mode: push PBR, PC, and P
            self.pushByte(self.pbr);
            self.pushByte(@truncate(self.pc >> 8));
            self.pushByte(@truncate(self.pc));
            self.pushByte(self.p.toByte());
        }

        self.p.i = true; // Disable IRQ
        self.p.d = false; // Clear decimal mode
        self.pbr = 0; // NMI vector is in bank 0

        // Read NMI vector
        const vector_addr: u16 = if (self.emulation_mode) 0xFFFA else 0xFFEA;
        const low = self.bus.read(0, vector_addr);
        const high = self.bus.read(0, vector_addr + 1);
        self.pc = @as(u16, high) << 8 | low;
    }

    fn handleIrq(self: *Cpu) void {
        self.cycles = 7;

        if (self.emulation_mode) {
            self.pushByte(@truncate(self.pc >> 8));
            self.pushByte(@truncate(self.pc));
            self.pushByte(self.p.toByte() & 0xEF);
        } else {
            self.pushByte(self.pbr);
            self.pushByte(@truncate(self.pc >> 8));
            self.pushByte(@truncate(self.pc));
            self.pushByte(self.p.toByte());
        }

        self.p.i = true;
        self.p.d = false;
        self.pbr = 0;

        const vector_addr: u16 = if (self.emulation_mode) 0xFFFE else 0xFFEE;
        const low = self.bus.read(0, vector_addr);
        const high = self.bus.read(0, vector_addr + 1);
        self.pc = @as(u16, high) << 8 | low;
    }

    // ==================== Memory Access ====================

    /// Record the true master-clock cost of one bus access (region-dependent
    /// 6/8/12 - see the mem_masters field docs and Bus.memSpeed), and bring
    /// the DSP coprocessor up to "now" BEFORE the access happens.
    ///
    /// The DSP must be ticked mid-instruction, not per-instruction: a bus
    /// access takes effect at the END of its cycle, after all the fetch/
    /// index cycles that preceded it within the same instruction. Super
    /// Mario Kart's blind DSP-1 parameter loop leaves only ~7 DSP
    /// instructions of slack between consecutive writes - batching a whole
    /// STA's cycles until after its write robs the DSP of ~3 instructions
    /// and the handshake slips a full station (the game overwrites each
    /// parameter before the microcode consumed it).
    fn accountAccess(self: *Cpu, bank: u8, addr: u16) void {
        const speed = self.bus.memSpeed(bank, addr);
        // Internal (non-access) cycles elapsed since the last flush: total
        // counted cycles minus one per completed access minus what was
        // already flushed. Everything up to and including this access's
        // own bus cycle happens-before its side effect.
        const internal: u32 = @as(u32, self.cycles) - self.mem_accesses - self.internal_flushed;
        self.bus.tickDsp(internal * 6 + speed);
        self.internal_flushed += internal;
        self.mem_masters += speed;
        self.mem_accesses +%= 1;
    }

    fn fetchByte(self: *Cpu) u8 {
        self.accountAccess(self.pbr, self.pc);
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

    fn fetchLong(self: *Cpu) u24 {
        const low = self.fetchByte();
        const mid = self.fetchByte();
        const high = self.fetchByte();
        return @as(u24, high) << 16 | @as(u24, mid) << 8 | low;
    }

    fn readByte(self: *Cpu, bank: u8, addr: u16) u8 {
        self.accountAccess(bank, addr);
        self.cycles += 1;
        return self.bus.read(bank, addr);
    }

    fn readWord(self: *Cpu, bank: u8, addr: u16) u16 {
        const low = self.readByte(bank, addr);
        const high = self.readByte(bank, addr +% 1);
        return @as(u16, high) << 8 | low;
    }

    fn writeByte(self: *Cpu, bank: u8, addr: u16, value: u8) void {
        self.accountAccess(bank, addr);
        self.cycles += 1;
        // Low-RAM watchpoint (see dbg.trace_watch): report which
        // instruction writes the watched address, in any of its mirrors.
        if (comptime dbg.trace_watch) {
            const low_ram_hit = addr == dbg.watch_addr and
                ((bank & 0x7F) < 0x40 or bank == 0x7E);
            // Also watch DSP-1 DR writes (HiROM window) so the SNES-side
            // sender of a DSP conversation can be located and disassembled.
            const dsp_hit = dbg.watch_dsp_writes and
                (bank & 0x7F) < 0x20 and addr >= 0x6000 and addr < 0x7000;
            if (low_ram_hit or dsp_hit) {
                std.debug.print("[WATCH] wr ${x:0>2}:{x:0>4} = ${x:0>2} from pc={x:0>2}:{x:0>4} instr#{d}\n", .{
                    bank, addr, value, self.pbr, self.pc, self.instruction_count,
                });
            }
        }
        self.bus.write(bank, addr, value);
    }

    fn writeWord(self: *Cpu, bank: u8, addr: u16, value: u16) void {
        self.writeByte(bank, addr, @truncate(value));
        self.writeByte(bank, addr +% 1, @truncate(value >> 8));
    }

    fn pushByte(self: *Cpu, value: u8) void {
        self.accountAccess(0, self.sp);
        self.bus.write(0, self.sp, value);
        self.sp -%= 1;
        if (self.emulation_mode) {
            self.sp = 0x0100 | (self.sp & 0xFF);
        }
        self.cycles += 1;
    }

    fn pushWord(self: *Cpu, value: u16) void {
        self.pushByte(@truncate(value >> 8));
        self.pushByte(@truncate(value));
    }

    fn pullByte(self: *Cpu) u8 {
        self.sp +%= 1;
        if (self.emulation_mode) {
            self.sp = 0x0100 | (self.sp & 0xFF);
        }
        self.accountAccess(0, self.sp);
        self.cycles += 1;
        return self.bus.read(0, self.sp);
    }

    fn pullWord(self: *Cpu) u16 {
        const low = self.pullByte();
        const high = self.pullByte();
        return @as(u16, high) << 8 | low;
    }

    // The "new" 65816 stack instructions - PEA, PEI, PER, PHD, PLD, PLB,
    // JSL, RTL - use the full 16-bit stack pointer even in emulation mode:
    // SP is NOT pinned to page 1 and can permanently walk out of it
    // (verified by the SingleStepTests vectors; also documented in the WDC
    // datasheet errata and Bruce Clark's 65816 notes). Original-6502
    // instructions (PHA/PLA/JSR/RTS/BRK/...) keep the page-1 wrap above.
    fn pushByteRaw(self: *Cpu, value: u8) void {
        self.accountAccess(0, self.sp);
        self.bus.write(0, self.sp, value);
        self.sp -%= 1;
        self.cycles += 1;
    }

    fn pushWordRaw(self: *Cpu, value: u16) void {
        self.pushByteRaw(@truncate(value >> 8));
        self.pushByteRaw(@truncate(value));
    }

    fn pullByteRaw(self: *Cpu) u8 {
        self.sp +%= 1;
        self.accountAccess(0, self.sp);
        self.cycles += 1;
        return self.bus.read(0, self.sp);
    }

    fn pullWordRaw(self: *Cpu) u16 {
        const low = self.pullByteRaw();
        const high = self.pullByteRaw();
        return @as(u16, high) << 8 | low;
    }

    // ==================== Addressing Modes ====================

    /// Direct Page addressing: dp
    fn addrDirect(self: *Cpu) u16 {
        const offset = self.fetchByte();
        if (self.dp & 0xFF != 0) self.cycles += 1; // Extra cycle if DP not page-aligned
        return self.dp +% offset;
    }

    /// Direct Page Indexed X: dp,X
    fn addrDirectX(self: *Cpu) u16 {
        const offset = self.fetchByte();
        if (self.dp & 0xFF != 0) self.cycles += 1;
        // Emulation mode with DL=0: the indexed sum wraps WITHIN the page
        // (8-bit add), reproducing 6502 zero-page indexing. With DL!=0 (or
        // in native mode) the full 16-bit sum is used.
        if (self.emulation_mode and (self.dp & 0xFF) == 0) {
            return self.dp | @as(u16, offset +% @as(u8, @truncate(self.x)));
        }
        if (self.p.x) {
            return self.dp +% offset +% @as(u16, @truncate(self.x));
        } else {
            return self.dp +% offset +% self.x;
        }
    }

    /// Direct Page Indexed Y: dp,Y
    fn addrDirectY(self: *Cpu) u16 {
        const offset = self.fetchByte();
        if (self.dp & 0xFF != 0) self.cycles += 1;
        // Same DL=0 page wrap as dp,X (see addrDirectX).
        if (self.emulation_mode and (self.dp & 0xFF) == 0) {
            return self.dp | @as(u16, offset +% @as(u8, @truncate(self.y)));
        }
        if (self.p.x) {
            return self.dp +% offset +% @as(u16, @truncate(self.y));
        } else {
            return self.dp +% offset +% self.y;
        }
    }

    /// Absolute addressing: addr
    fn addrAbsolute(self: *Cpu) u16 {
        self.ea_bank = self.dbr;
        return self.fetchWord();
    }

    /// Absolute Indexed X: addr,X
    fn addrAbsoluteX(self: *Cpu, check_page: bool) u16 {
        const base = self.fetchWord();
        const idx = if (self.p.x) @as(u16, @truncate(self.x)) else self.x;
        if (check_page and (base & 0xFF00) != ((base +% idx) & 0xFF00)) {
            self.cycles += 1; // Page crossing
        }
        const ea: u32 = (@as(u32, self.dbr) << 16) + base + idx; // carries into bank
        self.ea_bank = @truncate(ea >> 16);
        return @truncate(ea);
    }

    /// Absolute Indexed Y: addr,Y
    fn addrAbsoluteY(self: *Cpu, check_page: bool) u16 {
        const base = self.fetchWord();
        const idx = if (self.p.x) @as(u16, @truncate(self.y)) else self.y;
        if (check_page and (base & 0xFF00) != ((base +% idx) & 0xFF00)) {
            self.cycles += 1;
        }
        const ea: u32 = (@as(u32, self.dbr) << 16) + base + idx; // carries into bank
        self.ea_bank = @truncate(ea >> 16);
        return @truncate(ea);
    }

    /// Absolute Long: long
    fn addrAbsoluteLong(self: *Cpu) struct { bank: u8, addr: u16 } {
        const addr = self.fetchWord();
        const bank = self.fetchByte();
        return .{ .bank = bank, .addr = addr };
    }

    /// Absolute Long Indexed X: long,X
    fn addrAbsoluteLongX(self: *Cpu) struct { bank: u8, addr: u16 } {
        const addr = self.fetchWord();
        const bank = self.fetchByte();
        const idx = if (self.p.x) @as(u16, @truncate(self.x)) else self.x;
        const full: u24 = (@as(u24, bank) << 16) | addr;
        const result = full +% idx;
        return .{ .bank = @truncate(result >> 16), .addr = @truncate(result) };
    }

    /// Direct Page Indirect: (dp)
    ///
    /// NOTE on a quirk we deliberately DON'T have: one might expect the
    /// classic 6502 ($FF) pointer-wrap bug in emulation mode with DL=0
    /// (pointer at $xxFF reading its high byte from $xx00). The
    /// SingleStepTests vectors prove the 65816 does NOT do this - e.g.
    /// vector "e1 e 8669" (SBC (dp,X), D=$F400, pointer at $F4FF) reads
    /// the high byte from $F500. Only the INDEXED ADDRESS computation
    /// wraps with DL=0 (see addrDirectX); pointer fetches are 16-bit.
    fn addrDirectIndirect(self: *Cpu) u16 {
        const dp_addr = self.addrDirect();
        self.ea_bank = self.dbr;
        return self.readWord(0, dp_addr);
    }

    /// Direct Page Indirect Long: [dp]
    fn addrDirectIndirectLong(self: *Cpu) struct { bank: u8, addr: u16 } {
        const dp_addr = self.addrDirect();
        const addr = self.readWord(0, dp_addr);
        const bank = self.readByte(0, dp_addr +% 2);
        return .{ .bank = bank, .addr = addr };
    }

    /// Direct Page Indexed Indirect: (dp,X)
    fn addrDirectIndexedIndirect(self: *Cpu) u16 {
        const dp_addr = self.addrDirectX();
        self.ea_bank = self.dbr;
        return self.readWord(0, dp_addr);
    }

    /// Direct Page Indirect Indexed: (dp),Y
    fn addrDirectIndirectIndexed(self: *Cpu, check_page: bool) u16 {
        const dp_addr = self.addrDirect();
        const base = self.readWord(0, dp_addr);
        const idx = if (self.p.x) @as(u16, @truncate(self.y)) else self.y;
        if (check_page and (base & 0xFF00) != ((base +% idx) & 0xFF00)) {
            self.cycles += 1;
        }
        const ea: u32 = (@as(u32, self.dbr) << 16) + base + idx; // carries into bank
        self.ea_bank = @truncate(ea >> 16);
        return @truncate(ea);
    }

    /// Direct Page Indirect Long Indexed: [dp],Y
    fn addrDirectIndirectLongIndexed(self: *Cpu) struct { bank: u8, addr: u16 } {
        const dp_addr = self.addrDirect();
        const addr = self.readWord(0, dp_addr);
        const bank = self.readByte(0, dp_addr +% 2);
        const idx = if (self.p.x) @as(u16, @truncate(self.y)) else self.y;
        const full: u24 = (@as(u24, bank) << 16) | addr;
        const result = full +% idx;
        return .{ .bank = @truncate(result >> 16), .addr = @truncate(result) };
    }

    /// Stack Relative: sr,S
    fn addrStackRelative(self: *Cpu) u16 {
        const offset = self.fetchByte();
        return self.sp +% offset;
    }

    /// Stack Relative Indirect Indexed: (sr,S),Y
    fn addrStackRelativeIndirectIndexed(self: *Cpu) u16 {
        const sr_addr = self.addrStackRelative();
        const base = self.readWord(0, sr_addr);
        const idx = if (self.p.x) @as(u16, @truncate(self.y)) else self.y;
        const ea: u32 = (@as(u32, self.dbr) << 16) + base + idx; // carries into bank
        self.ea_bank = @truncate(ea >> 16);
        return @truncate(ea);
    }

    /// 16-bit DATA read at a 24-bit effective address: unlike pointer
    /// fetches (which wrap within their bank), data accesses continue into
    /// the next bank when the low byte sits at $xx:FFFF.
    fn readWordData(self: *Cpu, bank: u8, addr: u16) u16 {
        const lo: u16 = self.readByte(bank, addr);
        const hi_bank = if (addr == 0xFFFF) bank +% 1 else bank;
        const hi: u16 = self.readByte(hi_bank, addr +% 1);
        return lo | (hi << 8);
    }

    fn writeWordData(self: *Cpu, bank: u8, addr: u16, value: u16) void {
        self.writeByte(bank, addr, @truncate(value));
        const hi_bank = if (addr == 0xFFFF) bank +% 1 else bank;
        self.writeByte(hi_bank, addr +% 1, @truncate(value >> 8));
    }

    /// Applied whenever the X flag becomes 1 (SEP/PLP/RTI/XCE or any P
    /// byte write): the index registers' high bytes are cleared in
    /// hardware - the bits physically cease to exist.
    fn truncateIndexRegs(self: *Cpu) void {
        if (self.p.x) {
            self.x &= 0xFF;
            self.y &= 0xFF;
        }
    }

    // ==================== Flag Operations ====================

    fn setNZ8(self: *Cpu, value: u8) void {
        self.p.z = value == 0;
        self.p.n = (value & 0x80) != 0;
    }

    fn setNZ16(self: *Cpu, value: u16) void {
        self.p.z = value == 0;
        self.p.n = (value & 0x8000) != 0;
    }

    // ==================== ALU Operations ====================

    // =========================================================================
    // ADC/SBC - including 65816 decimal (BCD) mode
    // =========================================================================
    // Decimal mode follows the hardware's nibble-cascade exactly (verified
    // against the SingleStepTests vectors): each nibble is summed with the
    // incoming carry and decimal-adjusted (+6 on a >9 digit for ADC; -6 on
    // a non-carrying digit for SBC, which is computed as A + ~value + C).
    // Flag subtleties the vectors pin down:
    //   - V is computed from the intermediate result BEFORE the final
    //     top-nibble decimal adjustment
    //   - C, N, Z come from the fully adjusted result
    //   - SBC's V uses the INVERTED operand (it's an ADC of ~value)

    fn adc8(self: *Cpu, value: u8) void {
        const a: i32 = @as(u8, @truncate(self.a));
        const v: i32 = value;
        const c: i32 = if (self.p.c) 1 else 0;

        var result: i32 = undefined;
        if (self.p.d) {
            result = (a & 0x0F) + (v & 0x0F) + c;
            if (result > 0x09) result += 0x06;
            const c0: i32 = if (result > 0x0F) 1 else 0;
            result = (a & 0xF0) + (v & 0xF0) + (c0 << 4) + (result & 0x0F);
        } else {
            result = a + v + c;
        }
        self.p.v = (~(a ^ v) & (a ^ result) & 0x80) != 0;
        if (self.p.d and result > 0x9F) result += 0x60;
        self.p.c = result > 0xFF;
        const r8: u8 = @truncate(@as(u32, @bitCast(result)));
        self.a = (self.a & 0xFF00) | r8;
        self.setNZ8(r8);
    }

    fn adc16(self: *Cpu, value: u16) void {
        const a: i32 = self.a;
        const v: i32 = value;
        const c: i32 = if (self.p.c) 1 else 0;

        var result: i32 = undefined;
        if (self.p.d) {
            result = (a & 0x000F) + (v & 0x000F) + c;
            if (result > 0x0009) result += 0x0006;
            var cn: i32 = if (result > 0x000F) 1 else 0;
            result = (a & 0x00F0) + (v & 0x00F0) + (cn << 4) + (result & 0x000F);
            if (result > 0x009F) result += 0x0060;
            cn = if (result > 0x00FF) 1 else 0;
            result = (a & 0x0F00) + (v & 0x0F00) + (cn << 8) + (result & 0x00FF);
            if (result > 0x09FF) result += 0x0600;
            cn = if (result > 0x0FFF) 1 else 0;
            result = (a & 0xF000) + (v & 0xF000) + (cn << 12) + (result & 0x0FFF);
        } else {
            result = a + v + c;
        }
        self.p.v = (~(a ^ v) & (a ^ result) & 0x8000) != 0;
        if (self.p.d and result > 0x9FFF) result += 0x6000;
        self.p.c = result > 0xFFFF;
        self.a = @truncate(@as(u32, @bitCast(result)));
        self.setNZ16(self.a);
    }

    fn sbc8(self: *Cpu, value: u8) void {
        const a: i32 = @as(u8, @truncate(self.a));
        const v: i32 = @as(u8, value) ^ 0xFF; // SBC = ADC of the inverted operand
        const c: i32 = if (self.p.c) 1 else 0;

        var result: i32 = undefined;
        if (self.p.d) {
            result = (a & 0x0F) + (v & 0x0F) + c;
            if (result <= 0x0F) result -= 0x06;
            const c0: i32 = if (result > 0x0F) 1 else 0;
            result = (a & 0xF0) + (v & 0xF0) + (c0 << 4) + (result & 0x0F);
        } else {
            result = a + v + c;
        }
        self.p.v = (~(a ^ v) & (a ^ result) & 0x80) != 0;
        if (self.p.d and result <= 0xFF) result -= 0x60;
        self.p.c = result > 0xFF;
        const r8: u8 = @truncate(@as(u32, @bitCast(result)));
        self.a = (self.a & 0xFF00) | r8;
        self.setNZ8(r8);
    }

    fn sbc16(self: *Cpu, value: u16) void {
        const a: i32 = self.a;
        const v: i32 = @as(i32, value) ^ 0xFFFF;
        const c: i32 = if (self.p.c) 1 else 0;

        var result: i32 = undefined;
        if (self.p.d) {
            result = (a & 0x000F) + (v & 0x000F) + c;
            if (result <= 0x000F) result -= 0x0006;
            var cn: i32 = if (result > 0x000F) 1 else 0;
            result = (a & 0x00F0) + (v & 0x00F0) + (cn << 4) + (result & 0x000F);
            if (result <= 0x00FF) result -= 0x0060;
            cn = if (result > 0x00FF) 1 else 0;
            result = (a & 0x0F00) + (v & 0x0F00) + (cn << 8) + (result & 0x00FF);
            if (result <= 0x0FFF) result -= 0x0600;
            cn = if (result > 0x0FFF) 1 else 0;
            result = (a & 0xF000) + (v & 0xF000) + (cn << 12) + (result & 0x0FFF);
        } else {
            result = a + v + c;
        }
        self.p.v = (~(a ^ v) & (a ^ result) & 0x8000) != 0;
        if (self.p.d and result <= 0xFFFF) result -= 0x6000;
        self.p.c = result > 0xFFFF;
        self.a = @truncate(@as(u32, @bitCast(result)));
        self.setNZ16(self.a);
    }

    fn cmp8(self: *Cpu, reg: u8, value: u8) void {
        const result: i16 = @as(i16, reg) - @as(i16, value);
        self.p.c = reg >= value;
        self.setNZ8(@truncate(@as(u16, @bitCast(result))));
    }

    fn cmp16(self: *Cpu, reg: u16, value: u16) void {
        const result: i32 = @as(i32, reg) - @as(i32, value);
        self.p.c = reg >= value;
        self.setNZ16(@truncate(@as(u32, @bitCast(result))));
    }

    fn and8(self: *Cpu, value: u8) void {
        self.a = (self.a & 0xFF00) | (self.a & value);
        self.setNZ8(@truncate(self.a));
    }

    fn and16(self: *Cpu, value: u16) void {
        self.a &= value;
        self.setNZ16(self.a);
    }

    fn ora8(self: *Cpu, value: u8) void {
        self.a = (self.a & 0xFF00) | ((self.a & 0xFF) | value);
        self.setNZ8(@truncate(self.a));
    }

    fn ora16(self: *Cpu, value: u16) void {
        self.a |= value;
        self.setNZ16(self.a);
    }

    fn eor8(self: *Cpu, value: u8) void {
        self.a = (self.a & 0xFF00) | ((self.a & 0xFF) ^ value);
        self.setNZ8(@truncate(self.a));
    }

    fn eor16(self: *Cpu, value: u16) void {
        self.a ^= value;
        self.setNZ16(self.a);
    }

    fn bit8(self: *Cpu, value: u8) void {
        self.p.z = ((@as(u8, @truncate(self.a)) & value) == 0);
        self.p.n = (value & 0x80) != 0;
        self.p.v = (value & 0x40) != 0;
    }

    fn bit16(self: *Cpu, value: u16) void {
        self.p.z = ((self.a & value) == 0);
        self.p.n = (value & 0x8000) != 0;
        self.p.v = (value & 0x4000) != 0;
    }

    fn asl8(self: *Cpu, value: u8) u8 {
        self.p.c = (value & 0x80) != 0;
        const result = value << 1;
        self.setNZ8(result);
        return result;
    }

    fn asl16(self: *Cpu, value: u16) u16 {
        self.p.c = (value & 0x8000) != 0;
        const result = value << 1;
        self.setNZ16(result);
        return result;
    }

    fn lsr8(self: *Cpu, value: u8) u8 {
        self.p.c = (value & 0x01) != 0;
        const result = value >> 1;
        self.setNZ8(result);
        return result;
    }

    fn lsr16(self: *Cpu, value: u16) u16 {
        self.p.c = (value & 0x0001) != 0;
        const result = value >> 1;
        self.setNZ16(result);
        return result;
    }

    fn rol8(self: *Cpu, value: u8) u8 {
        const carry: u8 = if (self.p.c) 1 else 0;
        self.p.c = (value & 0x80) != 0;
        const result = (value << 1) | carry;
        self.setNZ8(result);
        return result;
    }

    fn rol16(self: *Cpu, value: u16) u16 {
        const carry: u16 = if (self.p.c) 1 else 0;
        self.p.c = (value & 0x8000) != 0;
        const result = (value << 1) | carry;
        self.setNZ16(result);
        return result;
    }

    fn ror8(self: *Cpu, value: u8) u8 {
        const carry: u8 = if (self.p.c) 0x80 else 0;
        self.p.c = (value & 0x01) != 0;
        const result = (value >> 1) | carry;
        self.setNZ8(result);
        return result;
    }

    fn ror16(self: *Cpu, value: u16) u16 {
        const carry: u16 = if (self.p.c) 0x8000 else 0;
        self.p.c = (value & 0x0001) != 0;
        const result = (value >> 1) | carry;
        self.setNZ16(result);
        return result;
    }

    // ==================== Instruction Execution ====================

    fn executeOpcode(self: *Cpu, opcode: u8) void {
        switch (opcode) {
            // ===== ADC - Add with Carry =====
            0x69 => { // ADC #imm
                if (self.p.m) {
                    self.adc8(self.fetchByte());
                } else {
                    self.adc16(self.fetchWord());
                }
            },
            0x65 => { // ADC dp
                const addr = self.addrDirect();
                if (self.p.m) {
                    self.adc8(self.readByte(0, addr));
                } else {
                    self.adc16(self.readWord(0, addr));
                }
            },
            0x75 => { // ADC dp,X
                const addr = self.addrDirectX();
                if (self.p.m) {
                    self.adc8(self.readByte(0, addr));
                } else {
                    self.adc16(self.readWord(0, addr));
                }
            },
            0x6D => { // ADC addr
                const addr = self.addrAbsolute();
                if (self.p.m) {
                    self.adc8(self.readByte(self.ea_bank, addr));
                } else {
                    self.adc16(self.readWordData(self.ea_bank, addr));
                }
            },
            0x7D => { // ADC addr,X
                const addr = self.addrAbsoluteX(true);
                if (self.p.m) {
                    self.adc8(self.readByte(self.ea_bank, addr));
                } else {
                    self.adc16(self.readWordData(self.ea_bank, addr));
                }
            },
            0x79 => { // ADC addr,Y
                const addr = self.addrAbsoluteY(true);
                if (self.p.m) {
                    self.adc8(self.readByte(self.ea_bank, addr));
                } else {
                    self.adc16(self.readWordData(self.ea_bank, addr));
                }
            },
            0x6F => { // ADC long
                const loc = self.addrAbsoluteLong();
                if (self.p.m) {
                    self.adc8(self.readByte(loc.bank, loc.addr));
                } else {
                    self.adc16(self.readWord(loc.bank, loc.addr));
                }
            },
            0x7F => { // ADC long,X
                const loc = self.addrAbsoluteLongX();
                if (self.p.m) {
                    self.adc8(self.readByte(loc.bank, loc.addr));
                } else {
                    self.adc16(self.readWord(loc.bank, loc.addr));
                }
            },
            0x72 => { // ADC (dp)
                const addr = self.addrDirectIndirect();
                if (self.p.m) {
                    self.adc8(self.readByte(self.ea_bank, addr));
                } else {
                    self.adc16(self.readWordData(self.ea_bank, addr));
                }
            },
            0x61 => { // ADC (dp,X)
                const addr = self.addrDirectIndexedIndirect();
                if (self.p.m) {
                    self.adc8(self.readByte(self.ea_bank, addr));
                } else {
                    self.adc16(self.readWordData(self.ea_bank, addr));
                }
            },
            0x71 => { // ADC (dp),Y
                const addr = self.addrDirectIndirectIndexed(true);
                if (self.p.m) {
                    self.adc8(self.readByte(self.ea_bank, addr));
                } else {
                    self.adc16(self.readWordData(self.ea_bank, addr));
                }
            },
            0x67 => { // ADC [dp]
                const loc = self.addrDirectIndirectLong();
                if (self.p.m) {
                    self.adc8(self.readByte(loc.bank, loc.addr));
                } else {
                    self.adc16(self.readWord(loc.bank, loc.addr));
                }
            },
            0x77 => { // ADC [dp],Y
                const loc = self.addrDirectIndirectLongIndexed();
                if (self.p.m) {
                    self.adc8(self.readByte(loc.bank, loc.addr));
                } else {
                    self.adc16(self.readWord(loc.bank, loc.addr));
                }
            },
            0x63 => { // ADC sr,S
                const addr = self.addrStackRelative();
                if (self.p.m) {
                    self.adc8(self.readByte(0, addr));
                } else {
                    self.adc16(self.readWord(0, addr));
                }
            },
            0x73 => { // ADC (sr,S),Y
                const addr = self.addrStackRelativeIndirectIndexed();
                if (self.p.m) {
                    self.adc8(self.readByte(self.ea_bank, addr));
                } else {
                    self.adc16(self.readWordData(self.ea_bank, addr));
                }
            },

            // ===== SBC - Subtract with Carry =====
            0xE9 => { // SBC #imm
                if (self.p.m) {
                    self.sbc8(self.fetchByte());
                } else {
                    self.sbc16(self.fetchWord());
                }
            },
            0xE5 => { // SBC dp
                const addr = self.addrDirect();
                if (self.p.m) {
                    self.sbc8(self.readByte(0, addr));
                } else {
                    self.sbc16(self.readWord(0, addr));
                }
            },
            0xF5 => { // SBC dp,X
                const addr = self.addrDirectX();
                if (self.p.m) {
                    self.sbc8(self.readByte(0, addr));
                } else {
                    self.sbc16(self.readWord(0, addr));
                }
            },
            0xED => { // SBC addr
                const addr = self.addrAbsolute();
                if (self.p.m) {
                    self.sbc8(self.readByte(self.ea_bank, addr));
                } else {
                    self.sbc16(self.readWordData(self.ea_bank, addr));
                }
            },
            0xFD => { // SBC addr,X
                const addr = self.addrAbsoluteX(true);
                if (self.p.m) {
                    self.sbc8(self.readByte(self.ea_bank, addr));
                } else {
                    self.sbc16(self.readWordData(self.ea_bank, addr));
                }
            },
            0xF9 => { // SBC addr,Y
                const addr = self.addrAbsoluteY(true);
                if (self.p.m) {
                    self.sbc8(self.readByte(self.ea_bank, addr));
                } else {
                    self.sbc16(self.readWordData(self.ea_bank, addr));
                }
            },
            0xEF => { // SBC long
                const loc = self.addrAbsoluteLong();
                if (self.p.m) {
                    self.sbc8(self.readByte(loc.bank, loc.addr));
                } else {
                    self.sbc16(self.readWord(loc.bank, loc.addr));
                }
            },
            0xFF => { // SBC long,X
                const loc = self.addrAbsoluteLongX();
                if (self.p.m) {
                    self.sbc8(self.readByte(loc.bank, loc.addr));
                } else {
                    self.sbc16(self.readWord(loc.bank, loc.addr));
                }
            },
            0xF2 => { // SBC (dp)
                const addr = self.addrDirectIndirect();
                if (self.p.m) {
                    self.sbc8(self.readByte(self.ea_bank, addr));
                } else {
                    self.sbc16(self.readWordData(self.ea_bank, addr));
                }
            },
            0xE1 => { // SBC (dp,X)
                const addr = self.addrDirectIndexedIndirect();
                if (self.p.m) {
                    self.sbc8(self.readByte(self.ea_bank, addr));
                } else {
                    self.sbc16(self.readWordData(self.ea_bank, addr));
                }
            },
            0xF1 => { // SBC (dp),Y
                const addr = self.addrDirectIndirectIndexed(true);
                if (self.p.m) {
                    self.sbc8(self.readByte(self.ea_bank, addr));
                } else {
                    self.sbc16(self.readWordData(self.ea_bank, addr));
                }
            },
            0xE7 => { // SBC [dp]
                const loc = self.addrDirectIndirectLong();
                if (self.p.m) {
                    self.sbc8(self.readByte(loc.bank, loc.addr));
                } else {
                    self.sbc16(self.readWord(loc.bank, loc.addr));
                }
            },
            0xF7 => { // SBC [dp],Y
                const loc = self.addrDirectIndirectLongIndexed();
                if (self.p.m) {
                    self.sbc8(self.readByte(loc.bank, loc.addr));
                } else {
                    self.sbc16(self.readWord(loc.bank, loc.addr));
                }
            },
            0xE3 => { // SBC sr,S
                const addr = self.addrStackRelative();
                if (self.p.m) {
                    self.sbc8(self.readByte(0, addr));
                } else {
                    self.sbc16(self.readWord(0, addr));
                }
            },
            0xF3 => { // SBC (sr,S),Y
                const addr = self.addrStackRelativeIndirectIndexed();
                if (self.p.m) {
                    self.sbc8(self.readByte(self.ea_bank, addr));
                } else {
                    self.sbc16(self.readWordData(self.ea_bank, addr));
                }
            },

            // ===== AND - Logical AND =====
            0x29 => { // AND #imm
                if (self.p.m) {
                    self.and8(self.fetchByte());
                } else {
                    self.and16(self.fetchWord());
                }
            },
            0x25 => { // AND dp
                const addr = self.addrDirect();
                if (self.p.m) {
                    self.and8(self.readByte(0, addr));
                } else {
                    self.and16(self.readWord(0, addr));
                }
            },
            0x35 => { // AND dp,X
                const addr = self.addrDirectX();
                if (self.p.m) {
                    self.and8(self.readByte(0, addr));
                } else {
                    self.and16(self.readWord(0, addr));
                }
            },
            0x2D => { // AND addr
                const addr = self.addrAbsolute();
                if (self.p.m) {
                    self.and8(self.readByte(self.ea_bank, addr));
                } else {
                    self.and16(self.readWordData(self.ea_bank, addr));
                }
            },
            0x3D => { // AND addr,X
                const addr = self.addrAbsoluteX(true);
                if (self.p.m) {
                    self.and8(self.readByte(self.ea_bank, addr));
                } else {
                    self.and16(self.readWordData(self.ea_bank, addr));
                }
            },
            0x39 => { // AND addr,Y
                const addr = self.addrAbsoluteY(true);
                if (self.p.m) {
                    self.and8(self.readByte(self.ea_bank, addr));
                } else {
                    self.and16(self.readWordData(self.ea_bank, addr));
                }
            },
            0x2F => { // AND long
                const loc = self.addrAbsoluteLong();
                if (self.p.m) {
                    self.and8(self.readByte(loc.bank, loc.addr));
                } else {
                    self.and16(self.readWord(loc.bank, loc.addr));
                }
            },
            0x3F => { // AND long,X
                const loc = self.addrAbsoluteLongX();
                if (self.p.m) {
                    self.and8(self.readByte(loc.bank, loc.addr));
                } else {
                    self.and16(self.readWord(loc.bank, loc.addr));
                }
            },
            0x32 => { // AND (dp)
                const addr = self.addrDirectIndirect();
                if (self.p.m) {
                    self.and8(self.readByte(self.ea_bank, addr));
                } else {
                    self.and16(self.readWordData(self.ea_bank, addr));
                }
            },
            0x21 => { // AND (dp,X)
                const addr = self.addrDirectIndexedIndirect();
                if (self.p.m) {
                    self.and8(self.readByte(self.ea_bank, addr));
                } else {
                    self.and16(self.readWordData(self.ea_bank, addr));
                }
            },
            0x31 => { // AND (dp),Y
                const addr = self.addrDirectIndirectIndexed(true);
                if (self.p.m) {
                    self.and8(self.readByte(self.ea_bank, addr));
                } else {
                    self.and16(self.readWordData(self.ea_bank, addr));
                }
            },
            0x27 => { // AND [dp]
                const loc = self.addrDirectIndirectLong();
                if (self.p.m) {
                    self.and8(self.readByte(loc.bank, loc.addr));
                } else {
                    self.and16(self.readWord(loc.bank, loc.addr));
                }
            },
            0x37 => { // AND [dp],Y
                const loc = self.addrDirectIndirectLongIndexed();
                if (self.p.m) {
                    self.and8(self.readByte(loc.bank, loc.addr));
                } else {
                    self.and16(self.readWord(loc.bank, loc.addr));
                }
            },
            0x23 => { // AND sr,S
                const addr = self.addrStackRelative();
                if (self.p.m) {
                    self.and8(self.readByte(0, addr));
                } else {
                    self.and16(self.readWord(0, addr));
                }
            },
            0x33 => { // AND (sr,S),Y
                const addr = self.addrStackRelativeIndirectIndexed();
                if (self.p.m) {
                    self.and8(self.readByte(self.ea_bank, addr));
                } else {
                    self.and16(self.readWordData(self.ea_bank, addr));
                }
            },

            // ===== ORA - Logical OR =====
            0x09 => { // ORA #imm
                if (self.p.m) {
                    self.ora8(self.fetchByte());
                } else {
                    self.ora16(self.fetchWord());
                }
            },
            0x05 => { // ORA dp
                const addr = self.addrDirect();
                if (self.p.m) {
                    self.ora8(self.readByte(0, addr));
                } else {
                    self.ora16(self.readWord(0, addr));
                }
            },
            0x15 => { // ORA dp,X
                const addr = self.addrDirectX();
                if (self.p.m) {
                    self.ora8(self.readByte(0, addr));
                } else {
                    self.ora16(self.readWord(0, addr));
                }
            },
            0x0D => { // ORA addr
                const addr = self.addrAbsolute();
                if (self.p.m) {
                    self.ora8(self.readByte(self.ea_bank, addr));
                } else {
                    self.ora16(self.readWordData(self.ea_bank, addr));
                }
            },
            0x1D => { // ORA addr,X
                const addr = self.addrAbsoluteX(true);
                if (self.p.m) {
                    self.ora8(self.readByte(self.ea_bank, addr));
                } else {
                    self.ora16(self.readWordData(self.ea_bank, addr));
                }
            },
            0x19 => { // ORA addr,Y
                const addr = self.addrAbsoluteY(true);
                if (self.p.m) {
                    self.ora8(self.readByte(self.ea_bank, addr));
                } else {
                    self.ora16(self.readWordData(self.ea_bank, addr));
                }
            },
            0x0F => { // ORA long
                const loc = self.addrAbsoluteLong();
                if (self.p.m) {
                    self.ora8(self.readByte(loc.bank, loc.addr));
                } else {
                    self.ora16(self.readWord(loc.bank, loc.addr));
                }
            },
            0x1F => { // ORA long,X
                const loc = self.addrAbsoluteLongX();
                if (self.p.m) {
                    self.ora8(self.readByte(loc.bank, loc.addr));
                } else {
                    self.ora16(self.readWord(loc.bank, loc.addr));
                }
            },
            0x12 => { // ORA (dp)
                const addr = self.addrDirectIndirect();
                if (self.p.m) {
                    self.ora8(self.readByte(self.ea_bank, addr));
                } else {
                    self.ora16(self.readWordData(self.ea_bank, addr));
                }
            },
            0x01 => { // ORA (dp,X)
                const addr = self.addrDirectIndexedIndirect();
                if (self.p.m) {
                    self.ora8(self.readByte(self.ea_bank, addr));
                } else {
                    self.ora16(self.readWordData(self.ea_bank, addr));
                }
            },
            0x11 => { // ORA (dp),Y
                const addr = self.addrDirectIndirectIndexed(true);
                if (self.p.m) {
                    self.ora8(self.readByte(self.ea_bank, addr));
                } else {
                    self.ora16(self.readWordData(self.ea_bank, addr));
                }
            },
            0x07 => { // ORA [dp]
                const loc = self.addrDirectIndirectLong();
                if (self.p.m) {
                    self.ora8(self.readByte(loc.bank, loc.addr));
                } else {
                    self.ora16(self.readWord(loc.bank, loc.addr));
                }
            },
            0x17 => { // ORA [dp],Y
                const loc = self.addrDirectIndirectLongIndexed();
                if (self.p.m) {
                    self.ora8(self.readByte(loc.bank, loc.addr));
                } else {
                    self.ora16(self.readWord(loc.bank, loc.addr));
                }
            },
            0x03 => { // ORA sr,S
                const addr = self.addrStackRelative();
                if (self.p.m) {
                    self.ora8(self.readByte(0, addr));
                } else {
                    self.ora16(self.readWord(0, addr));
                }
            },
            0x13 => { // ORA (sr,S),Y
                const addr = self.addrStackRelativeIndirectIndexed();
                if (self.p.m) {
                    self.ora8(self.readByte(self.ea_bank, addr));
                } else {
                    self.ora16(self.readWordData(self.ea_bank, addr));
                }
            },

            // ===== EOR - Exclusive OR =====
            0x49 => { // EOR #imm
                if (self.p.m) {
                    self.eor8(self.fetchByte());
                } else {
                    self.eor16(self.fetchWord());
                }
            },
            0x45 => { // EOR dp
                const addr = self.addrDirect();
                if (self.p.m) {
                    self.eor8(self.readByte(0, addr));
                } else {
                    self.eor16(self.readWord(0, addr));
                }
            },
            0x55 => { // EOR dp,X
                const addr = self.addrDirectX();
                if (self.p.m) {
                    self.eor8(self.readByte(0, addr));
                } else {
                    self.eor16(self.readWord(0, addr));
                }
            },
            0x4D => { // EOR addr
                const addr = self.addrAbsolute();
                if (self.p.m) {
                    self.eor8(self.readByte(self.ea_bank, addr));
                } else {
                    self.eor16(self.readWordData(self.ea_bank, addr));
                }
            },
            0x5D => { // EOR addr,X
                const addr = self.addrAbsoluteX(true);
                if (self.p.m) {
                    self.eor8(self.readByte(self.ea_bank, addr));
                } else {
                    self.eor16(self.readWordData(self.ea_bank, addr));
                }
            },
            0x59 => { // EOR addr,Y
                const addr = self.addrAbsoluteY(true);
                if (self.p.m) {
                    self.eor8(self.readByte(self.ea_bank, addr));
                } else {
                    self.eor16(self.readWordData(self.ea_bank, addr));
                }
            },
            0x4F => { // EOR long
                const loc = self.addrAbsoluteLong();
                if (self.p.m) {
                    self.eor8(self.readByte(loc.bank, loc.addr));
                } else {
                    self.eor16(self.readWord(loc.bank, loc.addr));
                }
            },
            0x5F => { // EOR long,X
                const loc = self.addrAbsoluteLongX();
                if (self.p.m) {
                    self.eor8(self.readByte(loc.bank, loc.addr));
                } else {
                    self.eor16(self.readWord(loc.bank, loc.addr));
                }
            },
            0x52 => { // EOR (dp)
                const addr = self.addrDirectIndirect();
                if (self.p.m) {
                    self.eor8(self.readByte(self.ea_bank, addr));
                } else {
                    self.eor16(self.readWordData(self.ea_bank, addr));
                }
            },
            0x41 => { // EOR (dp,X)
                const addr = self.addrDirectIndexedIndirect();
                if (self.p.m) {
                    self.eor8(self.readByte(self.ea_bank, addr));
                } else {
                    self.eor16(self.readWordData(self.ea_bank, addr));
                }
            },
            0x51 => { // EOR (dp),Y
                const addr = self.addrDirectIndirectIndexed(true);
                if (self.p.m) {
                    self.eor8(self.readByte(self.ea_bank, addr));
                } else {
                    self.eor16(self.readWordData(self.ea_bank, addr));
                }
            },
            0x47 => { // EOR [dp]
                const loc = self.addrDirectIndirectLong();
                if (self.p.m) {
                    self.eor8(self.readByte(loc.bank, loc.addr));
                } else {
                    self.eor16(self.readWord(loc.bank, loc.addr));
                }
            },
            0x57 => { // EOR [dp],Y
                const loc = self.addrDirectIndirectLongIndexed();
                if (self.p.m) {
                    self.eor8(self.readByte(loc.bank, loc.addr));
                } else {
                    self.eor16(self.readWord(loc.bank, loc.addr));
                }
            },
            0x43 => { // EOR sr,S
                const addr = self.addrStackRelative();
                if (self.p.m) {
                    self.eor8(self.readByte(0, addr));
                } else {
                    self.eor16(self.readWord(0, addr));
                }
            },
            0x53 => { // EOR (sr,S),Y
                const addr = self.addrStackRelativeIndirectIndexed();
                if (self.p.m) {
                    self.eor8(self.readByte(self.ea_bank, addr));
                } else {
                    self.eor16(self.readWordData(self.ea_bank, addr));
                }
            },

            // ===== BIT - Bit Test =====
            0x89 => { // BIT #imm
                if (self.p.m) {
                    const value = self.fetchByte();
                    self.p.z = ((@as(u8, @truncate(self.a)) & value) == 0);
                    // Note: N and V not affected for immediate mode
                } else {
                    const value = self.fetchWord();
                    self.p.z = ((self.a & value) == 0);
                }
            },
            0x24 => { // BIT dp
                const addr = self.addrDirect();
                if (self.p.m) {
                    self.bit8(self.readByte(0, addr));
                } else {
                    self.bit16(self.readWord(0, addr));
                }
            },
            0x34 => { // BIT dp,X
                const addr = self.addrDirectX();
                if (self.p.m) {
                    self.bit8(self.readByte(0, addr));
                } else {
                    self.bit16(self.readWord(0, addr));
                }
            },
            0x2C => { // BIT addr
                const addr = self.addrAbsolute();
                if (self.p.m) {
                    self.bit8(self.readByte(self.ea_bank, addr));
                } else {
                    self.bit16(self.readWordData(self.ea_bank, addr));
                }
            },
            0x3C => { // BIT addr,X
                const addr = self.addrAbsoluteX(true);
                if (self.p.m) {
                    self.bit8(self.readByte(self.ea_bank, addr));
                } else {
                    self.bit16(self.readWordData(self.ea_bank, addr));
                }
            },

            // ===== CMP - Compare Accumulator =====
            0xC9 => { // CMP #imm
                if (self.p.m) {
                    self.cmp8(@truncate(self.a), self.fetchByte());
                } else {
                    self.cmp16(self.a, self.fetchWord());
                }
            },
            0xC5 => { // CMP dp
                const addr = self.addrDirect();
                if (self.p.m) {
                    self.cmp8(@truncate(self.a), self.readByte(0, addr));
                } else {
                    self.cmp16(self.a, self.readWord(0, addr));
                }
            },
            0xD5 => { // CMP dp,X
                const addr = self.addrDirectX();
                if (self.p.m) {
                    self.cmp8(@truncate(self.a), self.readByte(0, addr));
                } else {
                    self.cmp16(self.a, self.readWord(0, addr));
                }
            },
            0xCD => { // CMP addr
                const addr = self.addrAbsolute();
                if (self.p.m) {
                    self.cmp8(@truncate(self.a), self.readByte(self.ea_bank, addr));
                } else {
                    self.cmp16(self.a, self.readWordData(self.ea_bank, addr));
                }
            },
            0xDD => { // CMP addr,X
                const addr = self.addrAbsoluteX(true);
                if (self.p.m) {
                    self.cmp8(@truncate(self.a), self.readByte(self.ea_bank, addr));
                } else {
                    self.cmp16(self.a, self.readWordData(self.ea_bank, addr));
                }
            },
            0xD9 => { // CMP addr,Y
                const addr = self.addrAbsoluteY(true);
                if (self.p.m) {
                    self.cmp8(@truncate(self.a), self.readByte(self.ea_bank, addr));
                } else {
                    self.cmp16(self.a, self.readWordData(self.ea_bank, addr));
                }
            },
            0xCF => { // CMP long
                const loc = self.addrAbsoluteLong();
                if (self.p.m) {
                    self.cmp8(@truncate(self.a), self.readByte(loc.bank, loc.addr));
                } else {
                    self.cmp16(self.a, self.readWord(loc.bank, loc.addr));
                }
            },
            0xDF => { // CMP long,X
                const loc = self.addrAbsoluteLongX();
                if (self.p.m) {
                    self.cmp8(@truncate(self.a), self.readByte(loc.bank, loc.addr));
                } else {
                    self.cmp16(self.a, self.readWord(loc.bank, loc.addr));
                }
            },
            0xD2 => { // CMP (dp)
                const addr = self.addrDirectIndirect();
                if (self.p.m) {
                    self.cmp8(@truncate(self.a), self.readByte(self.ea_bank, addr));
                } else {
                    self.cmp16(self.a, self.readWordData(self.ea_bank, addr));
                }
            },
            0xC1 => { // CMP (dp,X)
                const addr = self.addrDirectIndexedIndirect();
                if (self.p.m) {
                    self.cmp8(@truncate(self.a), self.readByte(self.ea_bank, addr));
                } else {
                    self.cmp16(self.a, self.readWordData(self.ea_bank, addr));
                }
            },
            0xD1 => { // CMP (dp),Y
                const addr = self.addrDirectIndirectIndexed(true);
                if (self.p.m) {
                    self.cmp8(@truncate(self.a), self.readByte(self.ea_bank, addr));
                } else {
                    self.cmp16(self.a, self.readWordData(self.ea_bank, addr));
                }
            },
            0xC7 => { // CMP [dp]
                const loc = self.addrDirectIndirectLong();
                if (self.p.m) {
                    self.cmp8(@truncate(self.a), self.readByte(loc.bank, loc.addr));
                } else {
                    self.cmp16(self.a, self.readWord(loc.bank, loc.addr));
                }
            },
            0xD7 => { // CMP [dp],Y
                const loc = self.addrDirectIndirectLongIndexed();
                if (self.p.m) {
                    self.cmp8(@truncate(self.a), self.readByte(loc.bank, loc.addr));
                } else {
                    self.cmp16(self.a, self.readWord(loc.bank, loc.addr));
                }
            },
            0xC3 => { // CMP sr,S
                const addr = self.addrStackRelative();
                if (self.p.m) {
                    self.cmp8(@truncate(self.a), self.readByte(0, addr));
                } else {
                    self.cmp16(self.a, self.readWord(0, addr));
                }
            },
            0xD3 => { // CMP (sr,S),Y
                const addr = self.addrStackRelativeIndirectIndexed();
                if (self.p.m) {
                    self.cmp8(@truncate(self.a), self.readByte(self.ea_bank, addr));
                } else {
                    self.cmp16(self.a, self.readWordData(self.ea_bank, addr));
                }
            },

            // ===== CPX - Compare X =====
            0xE0 => { // CPX #imm
                if (self.p.x) {
                    self.cmp8(@truncate(self.x), self.fetchByte());
                } else {
                    self.cmp16(self.x, self.fetchWord());
                }
            },
            0xE4 => { // CPX dp
                const addr = self.addrDirect();
                if (self.p.x) {
                    self.cmp8(@truncate(self.x), self.readByte(0, addr));
                } else {
                    self.cmp16(self.x, self.readWord(0, addr));
                }
            },
            0xEC => { // CPX addr
                const addr = self.addrAbsolute();
                if (self.p.x) {
                    self.cmp8(@truncate(self.x), self.readByte(self.ea_bank, addr));
                } else {
                    self.cmp16(self.x, self.readWordData(self.ea_bank, addr));
                }
            },

            // ===== CPY - Compare Y =====
            0xC0 => { // CPY #imm
                if (self.p.x) {
                    self.cmp8(@truncate(self.y), self.fetchByte());
                } else {
                    self.cmp16(self.y, self.fetchWord());
                }
            },
            0xC4 => { // CPY dp
                const addr = self.addrDirect();
                if (self.p.x) {
                    self.cmp8(@truncate(self.y), self.readByte(0, addr));
                } else {
                    self.cmp16(self.y, self.readWord(0, addr));
                }
            },
            0xCC => { // CPY addr
                const addr = self.addrAbsolute();
                if (self.p.x) {
                    self.cmp8(@truncate(self.y), self.readByte(self.ea_bank, addr));
                } else {
                    self.cmp16(self.y, self.readWordData(self.ea_bank, addr));
                }
            },

            // ===== ASL - Arithmetic Shift Left =====
            0x0A => { // ASL A
                if (self.p.m) {
                    const result = self.asl8(@truncate(self.a));
                    self.a = (self.a & 0xFF00) | result;
                } else {
                    self.a = self.asl16(self.a);
                }
            },
            0x06 => { // ASL dp
                const addr = self.addrDirect();
                if (self.p.m) {
                    const value = self.readByte(0, addr);
                    self.writeByte(0, addr, self.asl8(value));
                } else {
                    const value = self.readWord(0, addr);
                    self.writeWord(0, addr, self.asl16(value));
                }
            },
            0x16 => { // ASL dp,X
                const addr = self.addrDirectX();
                if (self.p.m) {
                    const value = self.readByte(0, addr);
                    self.writeByte(0, addr, self.asl8(value));
                } else {
                    const value = self.readWord(0, addr);
                    self.writeWord(0, addr, self.asl16(value));
                }
            },
            0x0E => { // ASL addr
                const addr = self.addrAbsolute();
                if (self.p.m) {
                    const value = self.readByte(self.ea_bank, addr);
                    self.writeByte(self.ea_bank, addr, self.asl8(value));
                } else {
                    const value = self.readWordData(self.ea_bank, addr);
                    self.writeWordData(self.ea_bank, addr, self.asl16(value));
                }
            },
            0x1E => { // ASL addr,X
                const addr = self.addrAbsoluteX(false);
                if (self.p.m) {
                    const value = self.readByte(self.ea_bank, addr);
                    self.writeByte(self.ea_bank, addr, self.asl8(value));
                } else {
                    const value = self.readWordData(self.ea_bank, addr);
                    self.writeWordData(self.ea_bank, addr, self.asl16(value));
                }
            },

            // ===== LSR - Logical Shift Right =====
            0x4A => { // LSR A
                if (self.p.m) {
                    const result = self.lsr8(@truncate(self.a));
                    self.a = (self.a & 0xFF00) | result;
                } else {
                    self.a = self.lsr16(self.a);
                }
            },
            0x46 => { // LSR dp
                const addr = self.addrDirect();
                if (self.p.m) {
                    const value = self.readByte(0, addr);
                    self.writeByte(0, addr, self.lsr8(value));
                } else {
                    const value = self.readWord(0, addr);
                    self.writeWord(0, addr, self.lsr16(value));
                }
            },
            0x56 => { // LSR dp,X
                const addr = self.addrDirectX();
                if (self.p.m) {
                    const value = self.readByte(0, addr);
                    self.writeByte(0, addr, self.lsr8(value));
                } else {
                    const value = self.readWord(0, addr);
                    self.writeWord(0, addr, self.lsr16(value));
                }
            },
            0x4E => { // LSR addr
                const addr = self.addrAbsolute();
                if (self.p.m) {
                    const value = self.readByte(self.ea_bank, addr);
                    self.writeByte(self.ea_bank, addr, self.lsr8(value));
                } else {
                    const value = self.readWordData(self.ea_bank, addr);
                    self.writeWordData(self.ea_bank, addr, self.lsr16(value));
                }
            },
            0x5E => { // LSR addr,X
                const addr = self.addrAbsoluteX(false);
                if (self.p.m) {
                    const value = self.readByte(self.ea_bank, addr);
                    self.writeByte(self.ea_bank, addr, self.lsr8(value));
                } else {
                    const value = self.readWordData(self.ea_bank, addr);
                    self.writeWordData(self.ea_bank, addr, self.lsr16(value));
                }
            },

            // ===== ROL - Rotate Left =====
            0x2A => { // ROL A
                if (self.p.m) {
                    const result = self.rol8(@truncate(self.a));
                    self.a = (self.a & 0xFF00) | result;
                } else {
                    self.a = self.rol16(self.a);
                }
            },
            0x26 => { // ROL dp
                const addr = self.addrDirect();
                if (self.p.m) {
                    const value = self.readByte(0, addr);
                    self.writeByte(0, addr, self.rol8(value));
                } else {
                    const value = self.readWord(0, addr);
                    self.writeWord(0, addr, self.rol16(value));
                }
            },
            0x36 => { // ROL dp,X
                const addr = self.addrDirectX();
                if (self.p.m) {
                    const value = self.readByte(0, addr);
                    self.writeByte(0, addr, self.rol8(value));
                } else {
                    const value = self.readWord(0, addr);
                    self.writeWord(0, addr, self.rol16(value));
                }
            },
            0x2E => { // ROL addr
                const addr = self.addrAbsolute();
                if (self.p.m) {
                    const value = self.readByte(self.ea_bank, addr);
                    self.writeByte(self.ea_bank, addr, self.rol8(value));
                } else {
                    const value = self.readWordData(self.ea_bank, addr);
                    self.writeWordData(self.ea_bank, addr, self.rol16(value));
                }
            },
            0x3E => { // ROL addr,X
                const addr = self.addrAbsoluteX(false);
                if (self.p.m) {
                    const value = self.readByte(self.ea_bank, addr);
                    self.writeByte(self.ea_bank, addr, self.rol8(value));
                } else {
                    const value = self.readWordData(self.ea_bank, addr);
                    self.writeWordData(self.ea_bank, addr, self.rol16(value));
                }
            },

            // ===== ROR - Rotate Right =====
            0x6A => { // ROR A
                if (self.p.m) {
                    const result = self.ror8(@truncate(self.a));
                    self.a = (self.a & 0xFF00) | result;
                } else {
                    self.a = self.ror16(self.a);
                }
            },
            0x66 => { // ROR dp
                const addr = self.addrDirect();
                if (self.p.m) {
                    const value = self.readByte(0, addr);
                    self.writeByte(0, addr, self.ror8(value));
                } else {
                    const value = self.readWord(0, addr);
                    self.writeWord(0, addr, self.ror16(value));
                }
            },
            0x76 => { // ROR dp,X
                const addr = self.addrDirectX();
                if (self.p.m) {
                    const value = self.readByte(0, addr);
                    self.writeByte(0, addr, self.ror8(value));
                } else {
                    const value = self.readWord(0, addr);
                    self.writeWord(0, addr, self.ror16(value));
                }
            },
            0x6E => { // ROR addr
                const addr = self.addrAbsolute();
                if (self.p.m) {
                    const value = self.readByte(self.ea_bank, addr);
                    self.writeByte(self.ea_bank, addr, self.ror8(value));
                } else {
                    const value = self.readWordData(self.ea_bank, addr);
                    self.writeWordData(self.ea_bank, addr, self.ror16(value));
                }
            },
            0x7E => { // ROR addr,X
                const addr = self.addrAbsoluteX(false);
                if (self.p.m) {
                    const value = self.readByte(self.ea_bank, addr);
                    self.writeByte(self.ea_bank, addr, self.ror8(value));
                } else {
                    const value = self.readWordData(self.ea_bank, addr);
                    self.writeWordData(self.ea_bank, addr, self.ror16(value));
                }
            },

            // ===== INC - Increment Memory =====
            0xE6 => { // INC dp
                const addr = self.addrDirect();
                if (self.p.m) {
                    const value = self.readByte(0, addr) +% 1;
                    self.writeByte(0, addr, value);
                    self.setNZ8(value);
                } else {
                    const value = self.readWord(0, addr) +% 1;
                    self.writeWord(0, addr, value);
                    self.setNZ16(value);
                }
            },
            0xF6 => { // INC dp,X
                const addr = self.addrDirectX();
                if (self.p.m) {
                    const value = self.readByte(0, addr) +% 1;
                    self.writeByte(0, addr, value);
                    self.setNZ8(value);
                } else {
                    const value = self.readWord(0, addr) +% 1;
                    self.writeWord(0, addr, value);
                    self.setNZ16(value);
                }
            },
            0xEE => { // INC addr
                const addr = self.addrAbsolute();
                if (self.p.m) {
                    const value = self.readByte(self.ea_bank, addr) +% 1;
                    self.writeByte(self.ea_bank, addr, value);
                    self.setNZ8(value);
                } else {
                    const value = self.readWordData(self.ea_bank, addr) +% 1;
                    self.writeWordData(self.ea_bank, addr, value);
                    self.setNZ16(value);
                }
            },
            0xFE => { // INC addr,X
                const addr = self.addrAbsoluteX(false);
                if (self.p.m) {
                    const value = self.readByte(self.ea_bank, addr) +% 1;
                    self.writeByte(self.ea_bank, addr, value);
                    self.setNZ8(value);
                } else {
                    const value = self.readWordData(self.ea_bank, addr) +% 1;
                    self.writeWordData(self.ea_bank, addr, value);
                    self.setNZ16(value);
                }
            },

            // ===== DEC - Decrement Memory =====
            0xC6 => { // DEC dp
                const addr = self.addrDirect();
                if (self.p.m) {
                    const value = self.readByte(0, addr) -% 1;
                    self.writeByte(0, addr, value);
                    self.setNZ8(value);
                } else {
                    const value = self.readWord(0, addr) -% 1;
                    self.writeWord(0, addr, value);
                    self.setNZ16(value);
                }
            },
            0xD6 => { // DEC dp,X
                const addr = self.addrDirectX();
                if (self.p.m) {
                    const value = self.readByte(0, addr) -% 1;
                    self.writeByte(0, addr, value);
                    self.setNZ8(value);
                } else {
                    const value = self.readWord(0, addr) -% 1;
                    self.writeWord(0, addr, value);
                    self.setNZ16(value);
                }
            },
            0xCE => { // DEC addr
                const addr = self.addrAbsolute();
                if (self.p.m) {
                    const value = self.readByte(self.ea_bank, addr) -% 1;
                    self.writeByte(self.ea_bank, addr, value);
                    self.setNZ8(value);
                } else {
                    const value = self.readWordData(self.ea_bank, addr) -% 1;
                    self.writeWordData(self.ea_bank, addr, value);
                    self.setNZ16(value);
                }
            },
            0xDE => { // DEC addr,X
                const addr = self.addrAbsoluteX(false);
                if (self.p.m) {
                    const value = self.readByte(self.ea_bank, addr) -% 1;
                    self.writeByte(self.ea_bank, addr, value);
                    self.setNZ8(value);
                } else {
                    const value = self.readWordData(self.ea_bank, addr) -% 1;
                    self.writeWordData(self.ea_bank, addr, value);
                    self.setNZ16(value);
                }
            },

            // ===== LDA - Load Accumulator =====
            0xA9 => { // LDA #imm
                if (self.p.m) {
                    const value = self.fetchByte();
                    self.a = (self.a & 0xFF00) | value;
                    self.setNZ8(@truncate(self.a));
                } else {
                    self.a = self.fetchWord();
                    self.setNZ16(self.a);
                }
            },
            0xA5 => { // LDA dp
                const addr = self.addrDirect();
                if (self.p.m) {
                    const value = self.readByte(0, addr);
                    self.a = (self.a & 0xFF00) | value;
                    self.setNZ8(value);
                } else {
                    self.a = self.readWord(0, addr);
                    self.setNZ16(self.a);
                }
            },
            0xB5 => { // LDA dp,X
                const addr = self.addrDirectX();
                if (self.p.m) {
                    const value = self.readByte(0, addr);
                    self.a = (self.a & 0xFF00) | value;
                    self.setNZ8(value);
                } else {
                    self.a = self.readWord(0, addr);
                    self.setNZ16(self.a);
                }
            },
            0xAD => { // LDA addr
                const addr = self.addrAbsolute();
                if (self.p.m) {
                    const value = self.readByte(self.ea_bank, addr);
                    self.a = (self.a & 0xFF00) | value;
                    self.setNZ8(value);
                } else {
                    self.a = self.readWordData(self.ea_bank, addr);
                    self.setNZ16(self.a);
                }
            },
            0xBD => { // LDA addr,X
                const addr = self.addrAbsoluteX(true);
                if (self.p.m) {
                    const value = self.readByte(self.ea_bank, addr);
                    self.a = (self.a & 0xFF00) | value;
                    self.setNZ8(value);
                } else {
                    self.a = self.readWordData(self.ea_bank, addr);
                    self.setNZ16(self.a);
                }
            },
            0xB9 => { // LDA addr,Y
                const addr = self.addrAbsoluteY(true);
                if (self.p.m) {
                    const value = self.readByte(self.ea_bank, addr);
                    self.a = (self.a & 0xFF00) | value;
                    self.setNZ8(value);
                } else {
                    self.a = self.readWordData(self.ea_bank, addr);
                    self.setNZ16(self.a);
                }
            },
            0xAF => { // LDA long
                const loc = self.addrAbsoluteLong();
                if (self.p.m) {
                    const value = self.readByte(loc.bank, loc.addr);
                    self.a = (self.a & 0xFF00) | value;
                    self.setNZ8(value);
                } else {
                    self.a = self.readWord(loc.bank, loc.addr);
                    self.setNZ16(self.a);
                }
            },
            0xBF => { // LDA long,X
                const loc = self.addrAbsoluteLongX();
                if (self.p.m) {
                    const value = self.readByte(loc.bank, loc.addr);
                    self.a = (self.a & 0xFF00) | value;
                    self.setNZ8(value);
                } else {
                    self.a = self.readWord(loc.bank, loc.addr);
                    self.setNZ16(self.a);
                }
            },
            0xB2 => { // LDA (dp)
                const addr = self.addrDirectIndirect();
                if (self.p.m) {
                    const value = self.readByte(self.ea_bank, addr);
                    self.a = (self.a & 0xFF00) | value;
                    self.setNZ8(value);
                } else {
                    self.a = self.readWordData(self.ea_bank, addr);
                    self.setNZ16(self.a);
                }
            },
            0xA1 => { // LDA (dp,X)
                const addr = self.addrDirectIndexedIndirect();
                if (self.p.m) {
                    const value = self.readByte(self.ea_bank, addr);
                    self.a = (self.a & 0xFF00) | value;
                    self.setNZ8(value);
                } else {
                    self.a = self.readWordData(self.ea_bank, addr);
                    self.setNZ16(self.a);
                }
            },
            0xB1 => { // LDA (dp),Y
                const addr = self.addrDirectIndirectIndexed(true);
                if (self.p.m) {
                    const value = self.readByte(self.ea_bank, addr);
                    self.a = (self.a & 0xFF00) | value;
                    self.setNZ8(value);
                } else {
                    self.a = self.readWordData(self.ea_bank, addr);
                    self.setNZ16(self.a);
                }
            },
            0xA7 => { // LDA [dp]
                const loc = self.addrDirectIndirectLong();
                if (self.p.m) {
                    const value = self.readByte(loc.bank, loc.addr);
                    self.a = (self.a & 0xFF00) | value;
                    self.setNZ8(value);
                } else {
                    self.a = self.readWord(loc.bank, loc.addr);
                    self.setNZ16(self.a);
                }
            },
            0xB7 => { // LDA [dp],Y
                const loc = self.addrDirectIndirectLongIndexed();
                if (self.p.m) {
                    const value = self.readByte(loc.bank, loc.addr);
                    self.a = (self.a & 0xFF00) | value;
                    self.setNZ8(value);
                } else {
                    self.a = self.readWord(loc.bank, loc.addr);
                    self.setNZ16(self.a);
                }
            },
            0xA3 => { // LDA sr,S
                const addr = self.addrStackRelative();
                if (self.p.m) {
                    const value = self.readByte(0, addr);
                    self.a = (self.a & 0xFF00) | value;
                    self.setNZ8(value);
                } else {
                    self.a = self.readWord(0, addr);
                    self.setNZ16(self.a);
                }
            },
            0xB3 => { // LDA (sr,S),Y
                const addr = self.addrStackRelativeIndirectIndexed();
                if (self.p.m) {
                    const value = self.readByte(self.ea_bank, addr);
                    self.a = (self.a & 0xFF00) | value;
                    self.setNZ8(value);
                } else {
                    self.a = self.readWordData(self.ea_bank, addr);
                    self.setNZ16(self.a);
                }
            },

            // ===== LDX - Load X Register =====
            0xA2 => { // LDX #imm
                if (self.p.x) {
                    self.x = self.fetchByte();
                    self.setNZ8(@truncate(self.x));
                } else {
                    self.x = self.fetchWord();
                    self.setNZ16(self.x);
                }
            },
            0xA6 => { // LDX dp
                const addr = self.addrDirect();
                if (self.p.x) {
                    self.x = self.readByte(0, addr);
                    self.setNZ8(@truncate(self.x));
                } else {
                    self.x = self.readWord(0, addr);
                    self.setNZ16(self.x);
                }
            },
            0xB6 => { // LDX dp,Y
                const addr = self.addrDirectY();
                if (self.p.x) {
                    self.x = self.readByte(0, addr);
                    self.setNZ8(@truncate(self.x));
                } else {
                    self.x = self.readWord(0, addr);
                    self.setNZ16(self.x);
                }
            },
            0xAE => { // LDX addr
                const addr = self.addrAbsolute();
                if (self.p.x) {
                    self.x = self.readByte(self.ea_bank, addr);
                    self.setNZ8(@truncate(self.x));
                } else {
                    self.x = self.readWordData(self.ea_bank, addr);
                    self.setNZ16(self.x);
                }
            },
            0xBE => { // LDX addr,Y
                const addr = self.addrAbsoluteY(true);
                if (self.p.x) {
                    self.x = self.readByte(self.ea_bank, addr);
                    self.setNZ8(@truncate(self.x));
                } else {
                    self.x = self.readWordData(self.ea_bank, addr);
                    self.setNZ16(self.x);
                }
            },

            // ===== LDY - Load Y Register =====
            0xA0 => { // LDY #imm
                if (self.p.x) {
                    self.y = self.fetchByte();
                    self.setNZ8(@truncate(self.y));
                } else {
                    self.y = self.fetchWord();
                    self.setNZ16(self.y);
                }
            },
            0xA4 => { // LDY dp
                const addr = self.addrDirect();
                if (self.p.x) {
                    self.y = self.readByte(0, addr);
                    self.setNZ8(@truncate(self.y));
                } else {
                    self.y = self.readWord(0, addr);
                    self.setNZ16(self.y);
                }
            },
            0xB4 => { // LDY dp,X
                const addr = self.addrDirectX();
                if (self.p.x) {
                    self.y = self.readByte(0, addr);
                    self.setNZ8(@truncate(self.y));
                } else {
                    self.y = self.readWord(0, addr);
                    self.setNZ16(self.y);
                }
            },
            0xAC => { // LDY addr
                const addr = self.addrAbsolute();
                if (self.p.x) {
                    self.y = self.readByte(self.ea_bank, addr);
                    self.setNZ8(@truncate(self.y));
                } else {
                    self.y = self.readWordData(self.ea_bank, addr);
                    self.setNZ16(self.y);
                }
            },
            0xBC => { // LDY addr,X
                const addr = self.addrAbsoluteX(true);
                if (self.p.x) {
                    self.y = self.readByte(self.ea_bank, addr);
                    self.setNZ8(@truncate(self.y));
                } else {
                    self.y = self.readWordData(self.ea_bank, addr);
                    self.setNZ16(self.y);
                }
            },

            // ===== STA - Store Accumulator =====
            0x85 => { // STA dp
                const addr = self.addrDirect();
                if (self.p.m) {
                    self.writeByte(0, addr, @truncate(self.a));
                } else {
                    self.writeWord(0, addr, self.a);
                }
            },
            0x95 => { // STA dp,X
                const addr = self.addrDirectX();
                if (self.p.m) {
                    self.writeByte(0, addr, @truncate(self.a));
                } else {
                    self.writeWord(0, addr, self.a);
                }
            },
            0x8D => { // STA addr
                const addr = self.addrAbsolute();
                if (self.p.m) {
                    self.writeByte(self.ea_bank, addr, @truncate(self.a));
                } else {
                    self.writeWordData(self.ea_bank, addr, self.a);
                }
            },
            0x9D => { // STA addr,X
                const addr = self.addrAbsoluteX(false);
                if (self.p.m) {
                    self.writeByte(self.ea_bank, addr, @truncate(self.a));
                } else {
                    self.writeWordData(self.ea_bank, addr, self.a);
                }
            },
            0x99 => { // STA addr,Y
                const addr = self.addrAbsoluteY(false);
                if (self.p.m) {
                    self.writeByte(self.ea_bank, addr, @truncate(self.a));
                } else {
                    self.writeWordData(self.ea_bank, addr, self.a);
                }
            },
            0x8F => { // STA long
                const loc = self.addrAbsoluteLong();
                if (self.p.m) {
                    self.writeByte(loc.bank, loc.addr, @truncate(self.a));
                } else {
                    self.writeWord(loc.bank, loc.addr, self.a);
                }
            },
            0x9F => { // STA long,X
                const loc = self.addrAbsoluteLongX();
                if (self.p.m) {
                    self.writeByte(loc.bank, loc.addr, @truncate(self.a));
                } else {
                    self.writeWord(loc.bank, loc.addr, self.a);
                }
            },
            0x92 => { // STA (dp)
                const addr = self.addrDirectIndirect();
                if (self.p.m) {
                    self.writeByte(self.ea_bank, addr, @truncate(self.a));
                } else {
                    self.writeWordData(self.ea_bank, addr, self.a);
                }
            },
            0x81 => { // STA (dp,X)
                const addr = self.addrDirectIndexedIndirect();
                if (self.p.m) {
                    self.writeByte(self.ea_bank, addr, @truncate(self.a));
                } else {
                    self.writeWordData(self.ea_bank, addr, self.a);
                }
            },
            0x91 => { // STA (dp),Y
                const addr = self.addrDirectIndirectIndexed(false);
                if (self.p.m) {
                    self.writeByte(self.ea_bank, addr, @truncate(self.a));
                } else {
                    self.writeWordData(self.ea_bank, addr, self.a);
                }
            },
            0x87 => { // STA [dp]
                const loc = self.addrDirectIndirectLong();
                if (self.p.m) {
                    self.writeByte(loc.bank, loc.addr, @truncate(self.a));
                } else {
                    self.writeWord(loc.bank, loc.addr, self.a);
                }
            },
            0x97 => { // STA [dp],Y
                const loc = self.addrDirectIndirectLongIndexed();
                if (self.p.m) {
                    self.writeByte(loc.bank, loc.addr, @truncate(self.a));
                } else {
                    self.writeWord(loc.bank, loc.addr, self.a);
                }
            },
            0x83 => { // STA sr,S
                const addr = self.addrStackRelative();
                if (self.p.m) {
                    self.writeByte(0, addr, @truncate(self.a));
                } else {
                    self.writeWord(0, addr, self.a);
                }
            },
            0x93 => { // STA (sr,S),Y
                const addr = self.addrStackRelativeIndirectIndexed();
                if (self.p.m) {
                    self.writeByte(self.ea_bank, addr, @truncate(self.a));
                } else {
                    self.writeWordData(self.ea_bank, addr, self.a);
                }
            },

            // ===== STX - Store X Register =====
            0x86 => { // STX dp
                const addr = self.addrDirect();
                if (self.p.x) {
                    self.writeByte(0, addr, @truncate(self.x));
                } else {
                    self.writeWord(0, addr, self.x);
                }
            },
            0x96 => { // STX dp,Y
                const addr = self.addrDirectY();
                if (self.p.x) {
                    self.writeByte(0, addr, @truncate(self.x));
                } else {
                    self.writeWord(0, addr, self.x);
                }
            },
            0x8E => { // STX addr
                const addr = self.addrAbsolute();
                if (self.p.x) {
                    self.writeByte(self.ea_bank, addr, @truncate(self.x));
                } else {
                    self.writeWordData(self.ea_bank, addr, self.x);
                }
            },

            // ===== STY - Store Y Register =====
            0x84 => { // STY dp
                const addr = self.addrDirect();
                if (self.p.x) {
                    self.writeByte(0, addr, @truncate(self.y));
                } else {
                    self.writeWord(0, addr, self.y);
                }
            },
            0x94 => { // STY dp,X
                const addr = self.addrDirectX();
                if (self.p.x) {
                    self.writeByte(0, addr, @truncate(self.y));
                } else {
                    self.writeWord(0, addr, self.y);
                }
            },
            0x8C => { // STY addr
                const addr = self.addrAbsolute();
                if (self.p.x) {
                    self.writeByte(self.ea_bank, addr, @truncate(self.y));
                } else {
                    self.writeWordData(self.ea_bank, addr, self.y);
                }
            },

            // ===== STZ - Store Zero =====
            0x64 => { // STZ dp
                const addr = self.addrDirect();
                if (self.p.m) {
                    self.writeByte(0, addr, 0);
                } else {
                    self.writeWord(0, addr, 0);
                }
            },
            0x74 => { // STZ dp,X
                const addr = self.addrDirectX();
                if (self.p.m) {
                    self.writeByte(0, addr, 0);
                } else {
                    self.writeWord(0, addr, 0);
                }
            },
            0x9C => { // STZ addr
                const addr = self.addrAbsolute();
                if (self.p.m) {
                    self.writeByte(self.ea_bank, addr, 0);
                } else {
                    self.writeWordData(self.ea_bank, addr, 0);
                }
            },
            0x9E => { // STZ addr,X
                const addr = self.addrAbsoluteX(false);
                if (self.p.m) {
                    self.writeByte(self.ea_bank, addr, 0);
                } else {
                    self.writeWordData(self.ea_bank, addr, 0);
                }
            },

            // ===== Transfer Instructions =====
            0xAA => { // TAX
                if (self.p.x) {
                    self.x = self.a & 0xFF;
                    self.setNZ8(@truncate(self.x));
                } else {
                    self.x = self.a;
                    self.setNZ16(self.x);
                }
            },
            0xA8 => { // TAY
                if (self.p.x) {
                    self.y = self.a & 0xFF;
                    self.setNZ8(@truncate(self.y));
                } else {
                    self.y = self.a;
                    self.setNZ16(self.y);
                }
            },
            0x8A => { // TXA
                if (self.p.m) {
                    self.a = (self.a & 0xFF00) | (self.x & 0xFF);
                    self.setNZ8(@truncate(self.a));
                } else {
                    self.a = self.x;
                    self.setNZ16(self.a);
                }
            },
            0x98 => { // TYA
                if (self.p.m) {
                    self.a = (self.a & 0xFF00) | (self.y & 0xFF);
                    self.setNZ8(@truncate(self.a));
                } else {
                    self.a = self.y;
                    self.setNZ16(self.a);
                }
            },
            0xBA => { // TSX
                if (self.p.x) {
                    self.x = self.sp & 0xFF;
                    self.setNZ8(@truncate(self.x));
                } else {
                    self.x = self.sp;
                    self.setNZ16(self.x);
                }
            },
            0x9A => { // TXS
                if (self.emulation_mode) {
                    self.sp = 0x0100 | (self.x & 0xFF);
                } else {
                    self.sp = self.x;
                }
            },
            0x9B => { // TXY
                if (self.p.x) {
                    self.y = self.x & 0xFF;
                    self.setNZ8(@truncate(self.y));
                } else {
                    self.y = self.x;
                    self.setNZ16(self.y);
                }
            },
            0xBB => { // TYX
                if (self.p.x) {
                    self.x = self.y & 0xFF;
                    self.setNZ8(@truncate(self.x));
                } else {
                    self.x = self.y;
                    self.setNZ16(self.x);
                }
            },
            0x5B => { // TCD - Transfer C (A) to Direct Page
                self.dp = self.a;
                self.setNZ16(self.dp);
            },
            0x7B => { // TDC - Transfer Direct Page to C (A)
                self.a = self.dp;
                self.setNZ16(self.a);
            },
            0x1B => { // TCS - Transfer C (A) to Stack Pointer
                // In emulation mode the stack high byte is hardwired to $01
                self.sp = if (self.emulation_mode) 0x0100 | (self.a & 0xFF) else self.a;
            },
            0x3B => { // TSC - Transfer Stack Pointer to C (A)
                self.a = self.sp;
                self.setNZ16(self.a);
            },

            // ===== Increment/Decrement =====
            0x1A => { // INC A
                if (self.p.m) {
                    self.a = (self.a & 0xFF00) | ((self.a +% 1) & 0xFF);
                    self.setNZ8(@truncate(self.a));
                } else {
                    self.a +%= 1;
                    self.setNZ16(self.a);
                }
            },
            0x3A => { // DEC A
                if (self.p.m) {
                    self.a = (self.a & 0xFF00) | ((self.a -% 1) & 0xFF);
                    self.setNZ8(@truncate(self.a));
                } else {
                    self.a -%= 1;
                    self.setNZ16(self.a);
                }
            },
            0xE8 => { // INX
                if (self.p.x) {
                    self.x = (self.x +% 1) & 0xFF;
                    self.setNZ8(@truncate(self.x));
                } else {
                    self.x +%= 1;
                    self.setNZ16(self.x);
                }
            },
            0xCA => { // DEX
                if (self.p.x) {
                    self.x = (self.x -% 1) & 0xFF;
                    self.setNZ8(@truncate(self.x));
                } else {
                    self.x -%= 1;
                    self.setNZ16(self.x);
                }
            },
            0xC8 => { // INY
                if (self.p.x) {
                    self.y = (self.y +% 1) & 0xFF;
                    self.setNZ8(@truncate(self.y));
                } else {
                    self.y +%= 1;
                    self.setNZ16(self.y);
                }
            },
            0x88 => { // DEY
                if (self.p.x) {
                    self.y = (self.y -% 1) & 0xFF;
                    self.setNZ8(@truncate(self.y));
                } else {
                    self.y -%= 1;
                    self.setNZ16(self.y);
                }
            },

            // ===== Stack Operations =====
            0x48 => { // PHA
                if (self.p.m) {
                    self.pushByte(@truncate(self.a));
                } else {
                    self.pushWord(self.a);
                }
            },
            0x68 => { // PLA
                if (self.p.m) {
                    self.a = (self.a & 0xFF00) | self.pullByte();
                    self.setNZ8(@truncate(self.a));
                } else {
                    self.a = self.pullWord();
                    self.setNZ16(self.a);
                }
            },
            0xDA => { // PHX
                if (self.p.x) {
                    self.pushByte(@truncate(self.x));
                } else {
                    self.pushWord(self.x);
                }
            },
            0xFA => { // PLX
                if (self.p.x) {
                    self.x = self.pullByte();
                    self.setNZ8(@truncate(self.x));
                } else {
                    self.x = self.pullWord();
                    self.setNZ16(self.x);
                }
            },
            0x5A => { // PHY
                if (self.p.x) {
                    self.pushByte(@truncate(self.y));
                } else {
                    self.pushWord(self.y);
                }
            },
            0x7A => { // PLY
                if (self.p.x) {
                    self.y = self.pullByte();
                    self.setNZ8(@truncate(self.y));
                } else {
                    self.y = self.pullWord();
                    self.setNZ16(self.y);
                }
            },
            0x08 => { // PHP
                self.pushByte(self.p.toByte());
            },
            0x28 => { // PLP
                self.p = Flags.fromByte(self.pullByte());
                if (self.emulation_mode) {
                    self.p.m = true;
                    self.p.x = true;
                }
                self.truncateIndexRegs();
                if (self.emulation_mode) {
                    self.p.x = true;
                    self.p.m = true;
                }
            },
            0x8B => { // PHB - Push Data Bank Register
                self.pushByte(self.dbr);
            },
            0xAB => { // PLB - Pull Data Bank Register
                self.dbr = self.pullByteRaw();
                self.setNZ8(self.dbr);
            },
            0x0B => { // PHD - Push Direct Page Register
                self.pushWordRaw(self.dp);
            },
            0x2B => { // PLD - Pull Direct Page Register
                self.dp = self.pullWordRaw();
                self.setNZ16(self.dp);
            },
            0x4B => { // PHK - Push Program Bank Register
                self.pushByte(self.pbr);
            },
            0xF4 => { // PEA - Push Effective Absolute Address
                const addr = self.fetchWord();
                self.pushWordRaw(addr);
            },
            0xD4 => { // PEI - Push Effective Indirect Address
                const dp_addr = self.addrDirect();
                const addr = self.readWord(0, dp_addr);
                self.pushWordRaw(addr);
            },
            0x62 => { // PER - Push Effective PC Relative
                const offset: i16 = @bitCast(self.fetchWord());
                const addr: u16 = @bitCast(@as(i16, @bitCast(self.pc)) +% offset);
                self.pushWordRaw(addr);
            },

            // ===== Branch Instructions =====
            0x80 => { // BRA
                const offset: i8 = @bitCast(self.fetchByte());
                self.pc = @bitCast(@as(i16, @bitCast(self.pc)) +% offset);
            },
            0x82 => { // BRL - Branch Long
                const offset: i16 = @bitCast(self.fetchWord());
                self.pc = @bitCast(@as(i16, @bitCast(self.pc)) +% offset);
            },
            0xF0 => { // BEQ
                const offset: i8 = @bitCast(self.fetchByte());
                if (self.p.z) {
                    self.pc = @bitCast(@as(i16, @bitCast(self.pc)) +% offset);
                    self.cycles += 1;
                }
            },
            0xD0 => { // BNE
                const offset: i8 = @bitCast(self.fetchByte());
                if (!self.p.z) {
                    self.pc = @bitCast(@as(i16, @bitCast(self.pc)) +% offset);
                    self.cycles += 1;
                }
            },
            0xB0 => { // BCS
                const offset: i8 = @bitCast(self.fetchByte());
                if (self.p.c) {
                    self.pc = @bitCast(@as(i16, @bitCast(self.pc)) +% offset);
                    self.cycles += 1;
                }
            },
            0x90 => { // BCC
                const offset: i8 = @bitCast(self.fetchByte());
                if (!self.p.c) {
                    self.pc = @bitCast(@as(i16, @bitCast(self.pc)) +% offset);
                    self.cycles += 1;
                }
            },
            0x30 => { // BMI
                const offset: i8 = @bitCast(self.fetchByte());
                if (self.p.n) {
                    self.pc = @bitCast(@as(i16, @bitCast(self.pc)) +% offset);
                    self.cycles += 1;
                }
            },
            0x10 => { // BPL
                const offset: i8 = @bitCast(self.fetchByte());
                if (!self.p.n) {
                    self.pc = @bitCast(@as(i16, @bitCast(self.pc)) +% offset);
                    self.cycles += 1;
                }
            },
            0x70 => { // BVS
                const offset: i8 = @bitCast(self.fetchByte());
                if (self.p.v) {
                    self.pc = @bitCast(@as(i16, @bitCast(self.pc)) +% offset);
                    self.cycles += 1;
                }
            },
            0x50 => { // BVC
                const offset: i8 = @bitCast(self.fetchByte());
                if (!self.p.v) {
                    self.pc = @bitCast(@as(i16, @bitCast(self.pc)) +% offset);
                    self.cycles += 1;
                }
            },

            // ===== Jump Instructions =====
            0x4C => { // JMP addr
                self.pc = self.fetchWord();
            },
            0x5C => { // JMP long (JML)
                // IMPORTANT: Fetch all operand bytes BEFORE updating PC/PBR!
                // Otherwise fetchByte for bank would read from wrong address.
                const addr = self.fetchWord();
                const bank = self.fetchByte();
                self.pc = addr;
                self.pbr = bank;
            },
            0x6C => { // JMP (addr)
                const ptr = self.fetchWord();
                self.pc = self.readWord(0, ptr);
            },
            0x7C => { // JMP (addr,X)
                const ptr = self.fetchWord() +% (if (self.p.x) @as(u16, @truncate(self.x)) else self.x);
                self.pc = self.readWord(self.pbr, ptr);
            },
            0xDC => { // JMP [addr]
                const ptr = self.fetchWord();
                self.pc = self.readWord(0, ptr);
                self.pbr = self.readByte(0, ptr +% 2);
            },
            0x20 => { // JSR addr
                const addr = self.fetchWord();
                self.pushWord(self.pc -% 1);
                self.pc = addr;
            },
            0x22 => { // JSL long
                const addr = self.fetchWord();
                const bank = self.fetchByte();
                self.pushByteRaw(self.pbr);
                self.pushWordRaw(self.pc -% 1);
                self.pc = addr;
                self.pbr = bank;
            },
            0xFC => { // JSR (addr,X)
                const ptr = self.fetchWord() +% (if (self.p.x) @as(u16, @truncate(self.x)) else self.x);
                self.pushWord(self.pc -% 1);
                self.pc = self.readWord(self.pbr, ptr);
            },
            0x60 => { // RTS
                self.pc = self.pullWord() +% 1;
            },
            0x6B => { // RTL
                self.pc = self.pullWordRaw() +% 1;
                self.pbr = self.pullByteRaw();
            },
            0x40 => { // RTI
                self.p = Flags.fromByte(self.pullByte());
                if (self.emulation_mode) {
                    self.p.m = true;
                    self.p.x = true;
                }
                self.truncateIndexRegs();
                self.pc = self.pullWord();
                if (!self.emulation_mode) {
                    self.pbr = self.pullByte();
                }
            },

            // ===== Flag Instructions =====
            0x18 => self.p.c = false, // CLC
            0x38 => self.p.c = true, // SEC
            0x58 => self.p.i = false, // CLI
            0x78 => self.p.i = true, // SEI
            0xD8 => self.p.d = false, // CLD
            0xF8 => self.p.d = true, // SED
            0xB8 => self.p.v = false, // CLV
            0xC2 => { // REP
                const mask = self.fetchByte();
                const current = self.p.toByte();
                self.p = Flags.fromByte(current & ~mask);
                if (self.emulation_mode) {
                    self.p.x = true;
                    self.p.m = true;
                }
            },
            0xE2 => { // SEP
                const mask = self.fetchByte();
                const current = self.p.toByte();
                self.p = Flags.fromByte(current | mask);
                self.truncateIndexRegs();
            },
            0xFB => { // XCE
                const old_c = self.p.c;
                self.p.c = self.emulation_mode;
                self.emulation_mode = old_c;
                if (self.emulation_mode) {
                    self.p.x = true;
                    self.p.m = true;
                    self.truncateIndexRegs();
                    self.sp = 0x0100 | (self.sp & 0xFF);
                }
            },

            // ===== Misc Instructions =====
            0xEA => {}, // NOP
            0x42 => _ = self.fetchByte(), // WDM (2-byte NOP)
            0xDB => self.cycles += 2, // STP
            0xCB => self.cycles += 2, // WAI
            0x00 => { // BRK
                self.pc +%= 1;
                if (!self.emulation_mode) {
                    self.pushByte(self.pbr);
                }
                self.pushWord(self.pc);
                self.pushByte(self.p.toByte());
                self.p.i = true;
                self.p.d = false;
                self.pbr = 0;
                self.pc = self.readWord(0, if (self.emulation_mode) @as(u16, 0xFFFE) else 0xFFE6);
            },
            0x02 => { // COP
                _ = self.fetchByte();
                if (!self.emulation_mode) {
                    self.pushByte(self.pbr);
                }
                self.pushWord(self.pc);
                self.pushByte(self.p.toByte());
                self.p.i = true;
                self.p.d = false;
                self.pbr = 0;
                self.pc = self.readWord(0, if (self.emulation_mode) @as(u16, 0xFFF4) else 0xFFE4);
            },
            0xEB => { // XBA - Exchange B and A
                const low: u8 = @truncate(self.a);
                const high: u8 = @truncate(self.a >> 8);
                self.a = (@as(u16, low) << 8) | high;
                self.setNZ8(high); // Flags set based on new low byte
            },
            0x44 => { // MVP - Block Move Positive (one byte per execution;
                // PC rewinds to the opcode until A wraps to $FFFF, so
                // interrupts can fire between bytes like real hardware)
                const dst_bank = self.fetchByte();
                const src_bank = self.fetchByte();
                self.dbr = dst_bank;
                const xi = if (self.p.x) self.x & 0xFF else self.x;
                const yi = if (self.p.x) self.y & 0xFF else self.y;
                const src = self.readByte(src_bank, xi);
                self.writeByte(dst_bank, yi, src);
                self.a -%= 1;
                self.x = if (self.p.x) (self.x -% 1) & 0xFF else self.x -% 1;
                self.y = if (self.p.x) (self.y -% 1) & 0xFF else self.y -% 1;
                if (self.a != 0xFFFF) {
                    self.pc -%= 3;
                }
            },
            0x54 => { // MVN - Block Move Negative (see MVP)
                const dst_bank = self.fetchByte();
                const src_bank = self.fetchByte();
                self.dbr = dst_bank;
                const xi = if (self.p.x) self.x & 0xFF else self.x;
                const yi = if (self.p.x) self.y & 0xFF else self.y;
                const src = self.readByte(src_bank, xi);
                self.writeByte(dst_bank, yi, src);
                self.a -%= 1;
                self.x = if (self.p.x) (self.x +% 1) & 0xFF else self.x +% 1;
                self.y = if (self.p.x) (self.y +% 1) & 0xFF else self.y +% 1;
                if (self.a != 0xFFFF) {
                    self.pc -%= 3;
                }
            },
            0x04 => { // TSB dp - Test and Set Bits
                const addr = self.addrDirect();
                if (self.p.m) {
                    const value = self.readByte(0, addr);
                    self.p.z = ((@as(u8, @truncate(self.a)) & value) == 0);
                    self.writeByte(0, addr, value | @as(u8, @truncate(self.a)));
                } else {
                    const value = self.readWord(0, addr);
                    self.p.z = ((self.a & value) == 0);
                    self.writeWord(0, addr, value | self.a);
                }
            },
            0x0C => { // TSB addr
                const addr = self.addrAbsolute();
                if (self.p.m) {
                    const value = self.readByte(self.ea_bank, addr);
                    self.p.z = ((@as(u8, @truncate(self.a)) & value) == 0);
                    self.writeByte(self.ea_bank, addr, value | @as(u8, @truncate(self.a)));
                } else {
                    const value = self.readWordData(self.ea_bank, addr);
                    self.p.z = ((self.a & value) == 0);
                    self.writeWordData(self.ea_bank, addr, value | self.a);
                }
            },
            0x14 => { // TRB dp - Test and Reset Bits
                const addr = self.addrDirect();
                if (self.p.m) {
                    const value = self.readByte(0, addr);
                    self.p.z = ((@as(u8, @truncate(self.a)) & value) == 0);
                    self.writeByte(0, addr, value & ~@as(u8, @truncate(self.a)));
                } else {
                    const value = self.readWord(0, addr);
                    self.p.z = ((self.a & value) == 0);
                    self.writeWord(0, addr, value & ~self.a);
                }
            },
            0x1C => { // TRB addr
                const addr = self.addrAbsolute();
                if (self.p.m) {
                    const value = self.readByte(self.ea_bank, addr);
                    self.p.z = ((@as(u8, @truncate(self.a)) & value) == 0);
                    self.writeByte(self.ea_bank, addr, value & ~@as(u8, @truncate(self.a)));
                } else {
                    const value = self.readWordData(self.ea_bank, addr);
                    self.p.z = ((self.a & value) == 0);
                    self.writeWordData(self.ea_bank, addr, value & ~self.a);
                }
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
    try std.testing.expect(restored.c == true);
    try std.testing.expect(restored.z == true);
}

test "adc 8-bit" {
    var ppu = @import("../ppu/ppu.zig").Ppu.init();
    var bus = Bus.init(&ppu);
    var cpu = Cpu.init(&bus);
    cpu.p.m = true; // 8-bit accumulator
    cpu.p.c = false;
    cpu.a = 0x50;
    cpu.adc8(0x10);
    try std.testing.expectEqual(@as(u16, 0x60), cpu.a & 0xFF);
    try std.testing.expect(!cpu.p.c);
    try std.testing.expect(!cpu.p.v);
}

test "adc 8-bit overflow" {
    var ppu = @import("../ppu/ppu.zig").Ppu.init();
    var bus = Bus.init(&ppu);
    var cpu = Cpu.init(&bus);
    cpu.p.m = true;
    cpu.p.c = false;
    cpu.a = 0x7F;
    cpu.adc8(0x01);
    try std.testing.expectEqual(@as(u16, 0x80), cpu.a & 0xFF);
    try std.testing.expect(!cpu.p.c);
    try std.testing.expect(cpu.p.v); // Overflow: positive + positive = negative
}
