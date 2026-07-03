// =============================================================================
// MEMORY BUS - SNES Address Space Handler
// =============================================================================
// The SNES has a 24-bit address bus, giving 16MB of addressable space.
// The address space is divided into 256 banks of 64KB each.
//
// Memory Map (LoROM - simplified):
// -----------------------------------------------------------------------------
// Banks $00-$3F:
//   $0000-$1FFF: WRAM mirror (first 8KB of 128KB work RAM)
//   $2100-$21FF: PPU registers (video processor)
//   $2140-$2143: APU I/O ports (audio processor communication)
//   $2180-$2183: WRAM access ports
//   $4200-$43FF: CPU I/O (DMA, interrupts, joypad, math hardware)
//   $8000-$FFFF: Cartridge ROM
//
// Banks $70-$7D:
//   $0000-$7FFF: Cartridge SRAM (battery-backed save RAM)
//   $8000-$FFFF: Cartridge ROM
//
// Banks $7E-$7F:
//   $0000-$FFFF: Full 128KB WRAM access
//
// Banks $80-$FF: Mirror of $00-$7F (but $80-$BF often faster "FastROM")
// =============================================================================

const std = @import("std");
const Ppu = @import("ppu/ppu.zig").Ppu;
const Cartridge = @import("cartridge.zig").Cartridge;
const Dma = @import("dma.zig").Dma;
const Apu = @import("apu/apu.zig").Apu;
const Upd7725 = @import("coproc/upd7725.zig").Upd7725;
const dbg = @import("debug.zig");

pub const Bus = struct {
    // WRAM - 128KB work RAM
    wram: [128 * 1024]u8,

    // Cartridge
    cartridge: ?Cartridge,

    // PPU reference for register access
    ppu: *Ppu,

    // DMA controller
    dma: Dma,

    // WRAM address registers for $2180-$2183
    wram_addr: u24,

    // System registers
    nmitimen: u8, // $4200 - NMI/IRQ enable
    htime: u16, // $4207-$4208 - H-counter IRQ position
    vtime: u16, // $4209-$420A - V-counter IRQ position
    mdmaen: u8, // $420B - DMA enable (triggers DMA)
    hdmaen: u8, // $420C - HDMA enable

    // Multiplication/division hardware
    wrmpya: u8, // $4202 - Multiplicand A
    wrmpyb: u8, // $4203 - Multiplicand B
    wrdiv: u16, // $4204-$4205 - Dividend
    wrdivb: u8, // $4206 - Divisor
    rddiv: u16, // $4214-$4215 - Division result
    rdmpy: u16, // $4216-$4217 - Multiplication result / remainder

    // Memory speed
    memsel: u8, // $420D - FastROM enable

    // =========================================================================
    // JOYPAD (Controller) STATE
    // =========================================================================
    // The SNES supports two ways to read controllers:
    //
    // 1. MANUAL SERIAL READ ($4016/$4017):
    //    Inherited from the NES. Writing 1 then 0 to $4016 latches the
    //    current button state into a shift register in each controller.
    //    Each subsequent read of $4016 (pad 1) or $4017 (pad 2) returns one
    //    button bit in bit 0, in the order:
    //      B, Y, Select, Start, Up, Down, Left, Right, A, X, L, R,
    //    then 4 zero bits (signature), then 1s forever.
    //
    // 2. AUTO-JOYPAD READ ($4218-$421F):
    //    When NMITIMEN ($4200) bit 0 is set, the hardware performs the
    //    serial read automatically at the start of VBlank and stores the
    //    results in $4218/$4219 (pad 1 lo/hi) through $421E/$421F (pad 4).
    //    Register layout (16-bit, JOY1H:JOY1L):
    //      $4219 (high): B Y Select Start Up Down Left Right
    //      $4218 (low):  A X L R 0 0 0 0
    //    Nearly all games (including SMW) use this method.
    //
    // We store the live button state as a 16-bit word in the $4219:$4218
    // layout (B = bit 15 ... R-shoulder = bit 4). The frontend sets this
    // via Emulator.setJoypad() once per frame.
    // =========================================================================
    joypad1: u16, // Live button state for controller 1
    joypad2: u16, // Live button state for controller 2
    joy1_latch: u16, // Auto-read latched value (what $4218/$4219 return)
    joy2_latch: u16,
    joypad_strobe: bool, // $4016 write bit 0 - while high, shift register reloads
    joy1_shift: u32, // Manual-read shift registers (bit 31 = next bit out... we
    joy2_shift: u32, // shift left and return the MSB, padding with 1s)

    // NMI flag for RDNMI ($4210) bit 7. Set when VBlank begins, cleared
    // when the CPU reads $4210 or when VBlank ends. Games spin on this
    // flag to synchronize with the display, so the read-clear behavior
    // matters: without it, a "wait for NMI flag to go low then high"
    // loop would never see it go low during VBlank.
    nmi_flag: bool,

    // IRQ flag for TIMEUP ($4211) bit 7. Set when the H/V timer fires
    // (per NMITIMEN bits 4-5 and HTIME/VTIME), cleared when the CPU
    // reads $4211 or when both IRQ enables are turned off. This IS the
    // IRQ line level: the CPU is interrupted as long as it's set (and
    // the I flag is clear) - games acknowledge by reading $4211 inside
    // the handler.
    irq_flag: bool,

    // =========================================================================
    // APU I/O PORTS ($2140-$2143) - SPC700 Communication Interface
    // =========================================================================
    // The SNES audio subsystem (APU) consists of a Sony SPC700 8-bit CPU with
    // 64KB dedicated audio RAM, running independently from the main 65816.
    //
    // References:
    //   - https://wiki.superfamicom.org/spc700-reference
    //   - https://snes.nesdev.org/wiki/Booting_the_SPC700
    //   - https://wiki.superfamicom.org/transferring-data-from-rom-to-the-snes-apu
    //
    // PORT ARCHITECTURE:
    // -------------------------------------------------------------------------
    // There are 8 bytes of buffered data: 4 bytes CPU-side, 4 bytes APU-side.
    //
    //   65816 Side          SPC700 Side
    //   -----------         -----------
    //   $2140 (APUIO0) <--> $F4 (bidirectional)
    //   $2141 (APUIO1) <--> $F5 (bidirectional)
    //   $2142 (APUIO2) <--> $F6 (bidirectional)
    //   $2143 (APUIO3) <--> $F7 (bidirectional)
    //
    // When one side writes, the other reads that value from its register.
    // Both sides can write simultaneously (separate buffers).
    //
    // IPL BOOT ROM PROTOCOL:
    // -------------------------------------------------------------------------
    // The SPC700 has a 64-byte internal IPL ROM that runs at power-on/reset.
    // It initializes the audio system and waits to receive a sound driver.
    //
    // PHASE 1 - Ready Signal:
    //   APU writes $AA to port 0, $BB to port 1 to signal "ready for transfer"
    //   CPU polls $2140 waiting for $AA, then confirms $2141 == $BB
    //
    // PHASE 2 - Transfer Start:
    //   CPU writes destination address to $2142 (low) and $2143 (high)
    //   CPU writes non-zero value to $2141 (data byte, or just $01)
    //   CPU writes $CC to $2140 to initiate transfer
    //   CPU polls $2140 waiting for APU to echo $CC
    //
    // PHASE 3 - Data Transfer Loop:
    //   For each byte:
    //     CPU writes data byte to $2141
    //     CPU writes current index (0, 1, 2, ... 255, 0, 1, ...) to $2140
    //     CPU polls $2140 waiting for APU to echo the index
    //   Transfer rate: ~520 master clocks per byte (~650 bytes per frame)
    //
    // PHASE 4 - Execute Command:
    //   To end transfer and start execution:
    //     CPU writes $00 to $2141 (signals "execute", not "more data")
    //     CPU writes execution address to $2142 (low) and $2143 (high)
    //     CPU increments $2140 value by 2+ and writes it
    //     APU jumps to the uploaded code
    //
    // POST-UPLOAD DRIVER COMMUNICATION:
    // -------------------------------------------------------------------------
    // After the sound driver starts running, games communicate with it using
    // game-specific protocols. Common patterns:
    //   - Port 0: Command acknowledgment / status
    //   - Port 1: Command byte or data
    //   - Ports 2-3: Additional parameters
    //
    // The APU is now fully emulated via the SPC700 CPU which runs the IPL ROM
    // and any uploaded sound driver code.
    // =========================================================================

    // The full APU emulation (SPC700 + DSP)
    apu: Apu,

    // =========================================================================
    // DSP-1 CARTRIDGE COPROCESSOR (NEC uPD77C25)
    // =========================================================================
    // Games like Super Mario Kart and Pilotwings ship with a math coprocessor
    // on the cartridge, low-level emulated in coproc/upd7725.zig running the
    // real microcode dump. The SNES sees exactly two registers, mapped by
    // board type:
    //   HiROM boards (Super Mario Kart):
    //     banks $00-$1F (+ mirrors $80-$9F): $6000-$6FFF = DR, $7000-$7FFF = SR
    //   LoROM boards (Pilotwings, Super Air Diver...):
    //     banks $30-$3F (+ mirrors $B0-$BF): $8000-$BFFF = DR, $C000-$FFFF = SR
    // dsp1_present is set at cartridge load when the ROM header's chip-type
    // byte announces a DSP ($03-$05) AND the microcode file was found.
    // =========================================================================
    dsp1: Upd7725,
    dsp1_present: bool,
    // Fixed-point accumulator for the DSP clock (2.048MHz vs 21.477MHz
    // master: 2 instructions per 21 master cycles). Lives on the Bus so
    // that BOTH the per-CPU-instruction path (root.zig) and the DMA byte
    // loop (dma.zig) can advance the DSP - on hardware the coprocessor
    // keeps running during DMA, and games depend on it: Super Mario Kart
    // DMA-reads DSP-1 results at exactly the pace the microcode streams
    // them into DR.
    dsp_accum: u32,

    /// Advance the DSP-1 by the given number of master-clock cycles.
    pub fn tickDsp(self: *Bus, master_cycles: u32) void {
        if (!self.dsp1_present) return;
        self.dsp_accum += master_cycles * 2;
        while (self.dsp_accum >= 21) {
            self.dsp_accum -= 21;
            self.dsp1.step();
            // Instruction-level PC trace for one frame (see dbg.trace_dsp):
            // histogram the output to find microcode stuck in internal
            // loops, or follow a conversation instruction by instruction.
            if (comptime dbg.trace_dsp) {
                if (self.ppu.frame_count == dbg.trace_frame_min) {
                    std.debug.print("[DSPPC] {x:0>3}\n", .{self.dsp1.pc});
                }
            }
        }
    }

    pub fn init(ppu: *Ppu) Bus {
        return Bus{
            .wram = [_]u8{0} ** (128 * 1024), // 128KB Work RAM, zeroed
            .cartridge = null,
            .ppu = ppu,
            .dma = Dma.init(),
            .wram_addr = 0,
            .nmitimen = 0, // NMI/IRQ disabled at boot
            .htime = 0x1FF, // H-IRQ at max (disabled)
            .vtime = 0x1FF, // V-IRQ at max (disabled)
            .mdmaen = 0,
            .hdmaen = 0,
            .wrmpya = 0xFF, // Hardware math defaults
            .wrmpyb = 0,
            .wrdiv = 0xFFFF,
            .wrdivb = 0,
            .rddiv = 0,
            .rdmpy = 0,
            .memsel = 0, // SlowROM by default
            .joypad1 = 0,
            .joypad2 = 0,
            .joy1_latch = 0,
            .joy2_latch = 0,
            .joypad_strobe = false,
            .joy1_shift = 0,
            .joy2_shift = 0,
            .nmi_flag = false,
            .irq_flag = false,
            // APU with SPC700 CPU - initialized with IPL ROM ready signal
            // The SPC700 starts executing at $FFC0 (IPL ROM) and will
            // write $AA/$BB to ports 0/1 to signal readiness
            .apu = Apu.init(),
            .dsp1 = Upd7725.init(),
            .dsp1_present = false,
            .dsp_accum = 0,
        };
    }

    pub fn loadCartridge(self: *Bus, rom_data: []const u8) !void {
        self.cartridge = try Cartridge.init(rom_data);
    }

    /// Read a byte from the 24-bit address space
    pub fn read(self: *Bus, bank: u8, addr: u16) u8 {
        // SNES memory map is complex - this is a simplified LoROM mapping
        // Banks $00-$3F: System area + LoROM
        // Banks $40-$6F: LoROM mirror
        // Banks $70-$7D: SRAM
        // Banks $80-$BF: Mirror of $00-$3F
        // Banks $C0-$FF: LoROM high speed

        const effective_bank = bank & 0x7F; // Mirror $80-$FF to $00-$7F

        if (effective_bank <= 0x3F) {
            if (addr < 0x2000) {
                // $0000-$1FFF: LowRAM (first 8KB of WRAM, mirrored)
                return self.wram[addr];
            } else if (addr < 0x2100) {
                // $2000-$20FF: Unused
                return 0;
            } else if (addr >= 0x2140 and addr <= 0x2143) {
                // $2140-$2143: APU I/O ports
                return self.readApuPort(addr);
            } else if (addr == 0x2180) {
                // WMDATA read - returns WRAM byte at the port address and
                // auto-increments (used by games to stream WRAM via DMA)
                return self.readWramPort();
            } else if (addr < 0x2200) {
                // $2100-$21FF: PPU registers (except APU ports)
                return self.ppu.readRegister(addr);
            } else if (addr < 0x4000) {
                // $2200-$3FFF: Expansion, APU, etc.
                return self.readSystemRegister(addr);
            } else if (addr < 0x4200) {
                // $4000-$41FF: Joypad registers
                return self.readJoypad(addr);
            } else if (addr < 0x4400) {
                // $4200-$43FF: DMA, PPU2 status, etc.
                return self.readSystemRegister(addr);
            } else if (addr < 0x8000) {
                // $4400-$7FFF: Expansion area.
                // On HiROM boards, banks $20-$3F map SRAM at $6000-$7FFF.
                if (addr >= 0x6000 and effective_bank >= 0x20 and self.isHiRom()) {
                    return self.readSram(effective_bank, addr);
                }
                // HiROM DSP-1 window: banks $00-$1F, DR at $6000-$6FFF,
                // SR at $7000-$7FFF (Super Mario Kart polls $00:7000)
                if (self.dsp1_present and addr >= 0x6000 and effective_bank < 0x20) {
                    if (addr < 0x7000) {
                        const v = self.dsp1.readData();
                        if (comptime dbg.trace_dsp) {
                            if (self.ppu.frame_count >= dbg.trace_frame_min and self.ppu.frame_count <= dbg.trace_frame_max) {
                                std.debug.print("[DSP1] DR rd  = ${x:0>2} (pc={x:0>3} sr={x:0>4})\n", .{ v, self.dsp1.pc, self.dsp1.sr });
                            }
                        }
                        return v;
                    }
                    if (comptime dbg.trace_dsp) {
                        if (self.ppu.frame_count >= dbg.trace_frame_min and self.ppu.frame_count <= dbg.trace_frame_max) {
                            std.debug.print("[DSP1] SR rd  = ${x:0>2} (pc={x:0>3})\n", .{ self.dsp1.readStatus(), self.dsp1.pc });
                        }
                    }
                    return self.dsp1.readStatus();
                }
                if (comptime dbg.trace_dsp) {
                    std.debug.print("[DSP?] read  ${x:0>2}:{x:0>4}\n", .{ bank, addr });
                }
                return 0;
            } else {
                // $8000-$FFFF: ROM
                // LoROM DSP-1 window shadows ROM in banks $30-$3F:
                // DR at $8000-$BFFF, SR at $C000-$FFFF
                if (self.dsp1_present and !self.isHiRom() and
                    effective_bank >= 0x30 and effective_bank <= 0x3F)
                {
                    if (addr < 0xC000) {
                        return self.dsp1.readData();
                    }
                    return self.dsp1.readStatus();
                }
                return self.readRom(effective_bank, addr);
            }
        } else if (effective_bank >= 0x70 and effective_bank <= 0x7D) {
            // LoROM: SRAM in the lower half, ROM above.
            // HiROM: this whole range mirrors ROM banks $C0-$FF.
            if (addr < 0x8000 and !self.isHiRom()) {
                return self.readSram(effective_bank, addr);
            } else {
                return self.readRom(effective_bank, addr);
            }
        } else if (effective_bank >= 0x7E and effective_bank <= 0x7F) {
            // Banks $7E-$7F: Direct WRAM access (128KB total)
            // $7E:0000-$FFFF = first 64KB of WRAM
            // $7F:0000-$FFFF = second 64KB of WRAM
            const wram_addr = (@as(u24, effective_bank - 0x7E) << 16) | addr;
            if (wram_addr < self.wram.len) {
                return self.wram[wram_addr];
            }
            return 0;
        } else {
            // ROM area
            return self.readRom(effective_bank, addr);
        }
    }

    /// Write a byte to the 24-bit address space
    pub fn write(self: *Bus, bank: u8, addr: u16, value: u8) void {
        const effective_bank = bank & 0x7F;

        if (effective_bank <= 0x3F) {
            if (addr < 0x2000) {
                self.wram[addr] = value;
            } else if (addr >= 0x2140 and addr <= 0x2143) {
                self.writeApuPort(addr, value);
            } else if (addr >= 0x2180 and addr <= 0x2183) {
                // WRAM data/address port - must be checked BEFORE the generic
                // PPU range below, since $2180 sits inside $2100-$21FF but is
                // a CPU-side register, not a PPU one.
                self.writeWramRegister(addr, value);
            } else if (addr >= 0x2100 and addr < 0x2200) {
                self.ppu.writeRegister(addr, value);
            } else if (addr == 0x4016) {
                // JOYSER0 write - controller strobe/latch
                self.writeJoypadStrobe(value);
            } else if (addr >= 0x4200 and addr < 0x4400) {
                self.writeSystemRegister(addr, value);
            } else if (addr >= 0x6000 and addr < 0x8000 and effective_bank >= 0x20 and self.isHiRom()) {
                // HiROM SRAM window (banks $20-$3F, $6000-$7FFF)
                self.writeSram(effective_bank, addr, value);
            } else if (self.dsp1_present and addr >= 0x6000 and addr < 0x7000 and effective_bank < 0x20) {
                // HiROM DSP-1 data register (SR at $7000+ is read-only)
                if (comptime dbg.trace_dsp) {
                    if (self.ppu.frame_count >= dbg.trace_frame_min and self.ppu.frame_count <= dbg.trace_frame_max) {
                        std.debug.print("[DSP1] DR wr  = ${x:0>2} (pc={x:0>3} sr={x:0>4})\n", .{ value, self.dsp1.pc, self.dsp1.sr });
                    }
                }
                self.dsp1.writeData(value);
            } else if (self.dsp1_present and !self.isHiRom() and
                addr >= 0x8000 and addr < 0xC000 and
                effective_bank >= 0x30 and effective_bank <= 0x3F)
            {
                // LoROM DSP-1 data register window
                self.dsp1.writeData(value);
            }
        } else if (effective_bank >= 0x70 and effective_bank <= 0x7D) {
            if (addr < 0x8000 and !self.isHiRom()) {
                self.writeSram(effective_bank, addr, value);
            }
        } else if (effective_bank >= 0x7E and effective_bank <= 0x7F) {
            // Direct WRAM access
            const wram_addr = (@as(u24, effective_bank - 0x7E) << 16) | addr;
            if (wram_addr < self.wram.len) {
                self.wram[wram_addr] = value;
            }
        }
    }

    fn isHiRom(self: *const Bus) bool {
        if (self.cartridge) |cart| {
            return cart.cart_type != .LoROM;
        }
        return false;
    }

    fn readRom(self: *Bus, bank: u8, addr: u16) u8 {
        if (self.cartridge) |cart| {
            return cart.read(bank, addr);
        }
        return 0;
    }

    fn readSram(self: *Bus, bank: u8, addr: u16) u8 {
        if (self.cartridge) |cart| {
            return cart.readSram(bank, addr);
        }
        return 0;
    }

    fn writeSram(self: *Bus, bank: u8, addr: u16, value: u8) void {
        if (self.cartridge) |*cart| {
            cart.writeSram(bank, addr, value);
        }
    }

    // =========================================================================
    // APU PORT READ - CPU reads what the SPC700 wrote to $F4-$F7
    // =========================================================================
    // The SPC700 is now fully emulated, running the IPL ROM and any uploaded
    // sound driver. We simply read from the SPC700's output port buffer.
    // =========================================================================
    fn readApuPort(self: *Bus, addr: u16) u8 {
        const port: u2 = @truncate(addr - 0x2140);
        return self.apu.readPort(port);
    }

    // =========================================================================
    // APU PORT WRITE - CPU sends data to the SPC700's $F4-$F7 input ports
    // =========================================================================
    // The SPC700 is now fully emulated. We write to its input port buffer,
    // and the SPC700's instruction execution (running the IPL ROM or uploaded
    // driver code) handles the communication protocol.
    // =========================================================================
    fn writeApuPort(self: *Bus, addr: u16, value: u8) void {
        const port: u2 = @truncate(addr - 0x2140);
        self.apu.writePort(port, value);
    }

    // =========================================================================
    // APU SYNCHRONIZATION - Run SPC700 to keep it in sync with main CPU
    // =========================================================================
    // This should be called after each main CPU instruction with the number
    // of master cycles consumed. The APU will execute enough SPC700 cycles
    // to stay in sync.
    // =========================================================================
    pub fn runApu(self: *Bus, master_cycles: u32) void {
        self.apu.runCycles(master_cycles);
    }

    fn readSystemRegister(self: *Bus, addr: u16) u8 {
        switch (addr) {
            // Hardware math results
            0x4214 => return @truncate(self.rddiv), // RDDIVL
            0x4215 => return @truncate(self.rddiv >> 8), // RDDIVH
            0x4216 => return @truncate(self.rdmpy), // RDMPYL
            0x4217 => return @truncate(self.rdmpy >> 8), // RDMPYH

            // PPU status
            0x4210 => {
                // RDNMI - NMI flag (bit 7), CPU version (bits 0-3)
                // Bit 7 is set at the start of VBlank and cleared when this
                // register is read (acknowledge). Games poll this to detect
                // VBlank edges, so the read-clear latch behavior is required
                // for correctness (returning "in vblank" level instead of the
                // latched edge can hang wait loops).
                const flag: u8 = if (self.nmi_flag) 0x80 else 0x00;
                self.nmi_flag = false;
                return flag | 0x02; // Version bits: CPU version 2
            },
            0x4211 => {
                // TIMEUP - H/V timer IRQ flag (bit 7), cleared on read.
                // Reading this register acknowledges the IRQ and drops the
                // IRQ line (the emulator syncs cpu.irq_pending from
                // irq_flag each step).
                const flag: u8 = if (self.irq_flag) 0x80 else 0x00;
                self.irq_flag = false;
                return flag;
            },
            0x4212 => {
                // HVBJOY - PPU status
                // Bit 7: VBlank (1 during scanlines 225-261)
                // Bit 6: HBlank (1 during dots 274-339)
                // Bit 0: Auto-joypad read in progress
                //
                // Real hardware takes ~3 scanlines (225-227) to serially clock
                // 16 bits out of each controller. Well-behaved games wait for
                // bit 0 to clear before reading $4218-$421F, so we model that
                // busy window even though our latch is instantaneous.
                var status: u8 = 0;
                if (self.ppu.scanline >= 225) status |= 0x80; // VBlank
                if (self.ppu.dot >= 274) status |= 0x40; // HBlank
                if ((self.nmitimen & 0x01) != 0 and
                    self.ppu.scanline >= 225 and self.ppu.scanline < 228)
                {
                    status |= 0x01; // Auto-joypad read in progress
                }
                return status;
            },

            // Auto-joypad read results, latched at start of VBlank.
            // Layout: $4218/$4219 = pad 1 low/high, $421A/$421B = pad 2.
            // Pads 3/4 (multitap) are not connected - return 0.
            0x4218 => return @truncate(self.joy1_latch),
            0x4219 => return @truncate(self.joy1_latch >> 8),
            0x421A => return @truncate(self.joy2_latch),
            0x421B => return @truncate(self.joy2_latch >> 8),
            0x421C...0x421F => return 0,

            // DMA registers ($4300-$437F)
            0x4300...0x437F => return self.dma.readRegister(addr),

            else => return 0,
        }
    }

    fn writeSystemRegister(self: *Bus, addr: u16, value: u8) void {
        switch (addr) {
            0x4200 => {
                self.nmitimen = value;
                // Disabling both H/V IRQ sources (bits 4-5) acknowledges
                // any pending timer IRQ - hardware drops the line.
                if ((value & 0x30) == 0) {
                    self.irq_flag = false;
                }
            },

            // Hardware multiplication
            0x4202 => self.wrmpya = value,
            0x4203 => {
                self.wrmpyb = value;
                // Perform multiplication immediately
                self.rdmpy = @as(u16, self.wrmpya) * @as(u16, self.wrmpyb);
            },

            // Hardware division
            0x4204 => self.wrdiv = (self.wrdiv & 0xFF00) | value,
            0x4205 => self.wrdiv = (self.wrdiv & 0x00FF) | (@as(u16, value) << 8),
            0x4206 => {
                self.wrdivb = value;
                // Perform division immediately (real hardware takes 16 cycles)
                if (self.wrdivb != 0) {
                    self.rddiv = self.wrdiv / @as(u16, self.wrdivb);
                    self.rdmpy = self.wrdiv % @as(u16, self.wrdivb);
                } else {
                    self.rddiv = 0xFFFF;
                    self.rdmpy = self.wrdiv;
                }
            },

            // H/V IRQ timing
            0x4207 => self.htime = (self.htime & 0x100) | value,
            0x4208 => self.htime = (self.htime & 0x0FF) | (@as(u16, value & 1) << 8),
            0x4209 => self.vtime = (self.vtime & 0x100) | value,
            0x420A => self.vtime = (self.vtime & 0x0FF) | (@as(u16, value & 1) << 8),

            // DMA enable - triggers DMA transfer
            0x420B => {
                if (value != 0) {
                    _ = self.dma.runDma(value, self);
                }
            },

            // HDMA enable ($420C) - controls which DMA channels are used for HDMA
            // HDMA transfers data to PPU registers every H-blank during visible scanlines
            // Used for effects like gradient backgrounds, spotlight windows, etc.
            0x420C => {
                if (comptime dbg.trace_hdma) {
                    if (value != 0) {
                        std.debug.print("[HDMA] Enable write $420C = ${x:0>2} (channels: ", .{value});
                        for (0..8) |i| {
                            if ((value & (@as(u8, 1) << @intCast(i))) != 0) {
                                std.debug.print("{d} ", .{i});
                            }
                        }
                        std.debug.print(")\n", .{});
                    }
                }
                self.hdmaen = value;
                self.dma.hdma_enable = value;
            },

            // Memory speed
            0x420D => self.memsel = value & 1,

            // DMA channel registers ($4300-$437F)
            0x4300...0x437F => self.dma.writeRegister(addr, value),

            else => {},
        }
    }

    fn readJoypad(self: *Bus, addr: u16) u8 {
        // Manual (NES-style) serial controller read.
        // Each read returns one button bit in bit 0 and advances the shift
        // register. While the strobe is held high, the register continuously
        // reloads, so reads return the first button (B) repeatedly.
        switch (addr) {
            0x4016 => {
                // JOYSER0 - controller port 1
                if (self.joypad_strobe) self.reloadShiftRegisters();
                const bit: u8 = @truncate(self.joy1_shift >> 31);
                self.joy1_shift = (self.joy1_shift << 1) | 1; // Pad with 1s after 16 bits
                return bit;
            },
            0x4017 => {
                // JOYSER1 - controller port 2
                // Bits 2-4 read as 1 on real hardware (open bus quirk of port 2)
                if (self.joypad_strobe) self.reloadShiftRegisters();
                const bit: u8 = @truncate(self.joy2_shift >> 31);
                self.joy2_shift = (self.joy2_shift << 1) | 1;
                return bit | 0x1C;
            },
            else => return 0,
        }
    }

    /// Write to $4016 (JOYSER0) - controller strobe/latch.
    /// Writing bit0=1 makes the controllers continuously load their button
    /// state; writing bit0=0 freezes it so serial reads can shift it out.
    fn writeJoypadStrobe(self: *Bus, value: u8) void {
        const strobe = (value & 1) != 0;
        if (self.joypad_strobe and !strobe) {
            // Falling edge: latch current state for shifting
            self.reloadShiftRegisters();
        }
        self.joypad_strobe = strobe;
    }

    /// Load live button state into the manual-read shift registers.
    /// The 16-bit state (B first) goes in the top bits of a 32-bit register;
    /// the bits below are set to 1 so that reads past the 16th return 1
    /// ("controller connected" signature per SNES convention).
    fn reloadShiftRegisters(self: *Bus) void {
        self.joy1_shift = (@as(u32, self.joypad1) << 16) | 0xFFFF;
        self.joy2_shift = (@as(u32, self.joypad2) << 16) | 0xFFFF;
    }

    /// Latch controller state into the auto-read registers ($4218-$421B).
    /// Called by the emulator at the start of VBlank when auto-joypad read
    /// is enabled (NMITIMEN bit 0). On hardware this takes ~3 scanlines of
    /// serial clocking; we latch instantly and report "busy" via HVBJOY.
    pub fn autoJoypadRead(self: *Bus) void {
        self.joy1_latch = self.joypad1;
        self.joy2_latch = self.joypad2;
        // The auto-read leaves the manual shift registers empty (it clocks
        // them through), but games using auto-read don't mix modes, so we
        // don't model that detail.
    }

    /// DMA read from A-bus (full 24-bit address)
    pub fn readDma(self: *Bus, addr: u24) u8 {
        const bank: u8 = @truncate(addr >> 16);
        const offset: u16 = @truncate(addr);
        return self.read(bank, offset);
    }

    /// DMA write to A-bus (full 24-bit address)
    pub fn writeDma(self: *Bus, addr: u24, value: u8) void {
        const bank: u8 = @truncate(addr >> 16);
        const offset: u16 = @truncate(addr);
        self.write(bank, offset, value);
    }

    /// DMA read from B-bus (PPU register at $21xx)
    /// The B-bus also exposes the WRAM port ($2180) and APU ports
    /// ($2140-$2143), not just PPU registers - route accordingly.
    pub fn readPpuDma(self: *Bus, addr: u16) u8 {
        if (addr == 0x2180) return self.readWramPort();
        if (addr >= 0x2140 and addr <= 0x2143) return self.readApuPort(addr);
        return self.ppu.readRegister(addr);
    }

    /// DMA write to B-bus (PPU register at $21xx)
    /// Games commonly DMA to $2180 (WMDATA) to clear or copy blocks of WRAM.
    pub fn writePpuDma(self: *Bus, addr: u16, value: u8) void {
        if (addr >= 0x2180 and addr <= 0x2183) return self.writeWramRegister(addr, value);
        if (addr >= 0x2140 and addr <= 0x2143) return self.writeApuPort(addr, value);
        self.ppu.writeRegister(addr, value);
    }

    /// Read from the WRAM data port ($2180) and auto-increment the address.
    fn readWramPort(self: *Bus) u8 {
        const value = self.wram[self.wram_addr & 0x1FFFF];
        self.wram_addr = (self.wram_addr + 1) & 0x1FFFF;
        return value;
    }

    fn writeWramRegister(self: *Bus, addr: u16, value: u8) void {
        switch (addr) {
            0x2180 => {
                // WMDATA - Write to WRAM at current address
                if (self.wram_addr < self.wram.len) {
                    self.wram[self.wram_addr] = value;
                }
                self.wram_addr = (self.wram_addr + 1) & 0x1FFFF;
            },
            0x2181 => {
                // WMADDL - WRAM address low byte
                self.wram_addr = (self.wram_addr & 0x1FF00) | value;
            },
            0x2182 => {
                // WMADDM - WRAM address middle byte
                self.wram_addr = (self.wram_addr & 0x100FF) | (@as(u24, value) << 8);
            },
            0x2183 => {
                // WMADDH - WRAM address high bit
                self.wram_addr = (self.wram_addr & 0x0FFFF) | (@as(u24, value & 1) << 16);
            },
            else => {},
        }
    }
};

test "bus init" {
    var ppu = @import("ppu/ppu.zig").Ppu.init();
    const bus = Bus.init(&ppu);
    _ = bus;
}
