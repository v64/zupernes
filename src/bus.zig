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
            // APU with SPC700 CPU - initialized with IPL ROM ready signal
            // The SPC700 starts executing at $FFC0 (IPL ROM) and will
            // write $AA/$BB to ports 0/1 to signal readiness
            .apu = Apu.init(),
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
                // $4400-$7FFF: Expansion
                return 0;
            } else {
                // $8000-$FFFF: ROM
                return self.readRom(effective_bank, addr);
            }
        } else if (effective_bank >= 0x70 and effective_bank <= 0x7D) {
            // SRAM
            if (addr < 0x8000) {
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
            } else if (addr >= 0x2100 and addr < 0x2200) {
                self.ppu.writeRegister(addr, value);
            } else if (addr >= 0x2180 and addr <= 0x2183) {
                self.writeWramRegister(addr, value);
            } else if (addr >= 0x4200 and addr < 0x4400) {
                self.writeSystemRegister(addr, value);
            }
        } else if (effective_bank >= 0x70 and effective_bank <= 0x7D) {
            if (addr < 0x8000) {
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
                // Bit 7 is set at start of VBlank, cleared on read
                const in_vblank = self.ppu.scanline >= 225;
                return if (in_vblank) 0x82 else 0x02;
            },
            0x4211 => return 0x00, // TIMEUP - IRQ flag
            0x4212 => {
                // HVBJOY - PPU status
                // Bit 7: VBlank (1 during scanlines 225-261)
                // Bit 6: HBlank (1 during dots 274-339)
                // Bit 0: Auto-joypad read in progress
                var status: u8 = 0;
                if (self.ppu.scanline >= 225) status |= 0x80; // VBlank
                if (self.ppu.dot >= 274) status |= 0x40; // HBlank
                return status;
            },
            0x4016 => return 0, // JOYSER0
            0x4017 => return 0, // JOYSER1

            // H/V counters
            0x4218...0x421F => return 0, // Joypad auto-read results

            // DMA registers ($4300-$437F)
            0x4300...0x437F => return self.dma.readRegister(addr),

            else => return 0,
        }
    }

    fn writeSystemRegister(self: *Bus, addr: u16, value: u8) void {
        switch (addr) {
            0x4200 => self.nmitimen = value,

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

            // HDMA enable
            0x420C => {
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
        _ = self;
        // TODO: Implement joypad
        switch (addr) {
            0x4016 => return 0, // JOYSER0
            0x4017 => return 0, // JOYSER1
            0x4218...0x421F => return 0, // JOY1-4
            else => return 0,
        }
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
    pub fn readPpuDma(self: *Bus, addr: u16) u8 {
        return self.ppu.readRegister(addr);
    }

    /// DMA write to B-bus (PPU register at $21xx)
    pub fn writePpuDma(self: *Bus, addr: u16, value: u8) void {
        self.ppu.writeRegister(addr, value);
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
