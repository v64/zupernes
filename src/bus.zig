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
    // Since we don't emulate the actual SPC700, we stub this communication
    // by echoing writes and providing sensible default responses.
    // =========================================================================

    // APU output registers (what CPU reads from $2140-$2143)
    // These represent what the SPC700 "wrote" to its side
    apu_out: [4]u8,

    // APU input registers (what CPU writes to $2140-$2143)
    // These represent what the 65816 sent to the SPC700
    apu_in: [4]u8,

    // APU state tracking for the stub implementation
    apu_boot_done: bool, // True after CPU writes $CC (transfer started)
    apu_last_index: u8, // Last index value written to port 0 during transfer
    apu_driver_ready: bool, // True after execute command (driver running)

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
            // APU boot state: $AA at port 0, $BB at port 1 signals "ready"
            // This is what the IPL ROM writes after initialization
            .apu_out = [_]u8{ 0xAA, 0xBB, 0x00, 0x00 },
            .apu_in = [_]u8{ 0x00, 0x00, 0x00, 0x00 },
            .apu_boot_done = false, // True once $CC written (transfer mode)
            .apu_last_index = 0, // Track transfer index for execute detection
            .apu_driver_ready = false, // True once sound driver is running
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
    // APU PORT READ - CPU reads what the SPC700 "wrote"
    // =========================================================================
    // During boot: Returns $AA (port 0) and $BB (port 1) - the ready signal
    // During transfer: Returns echoed index values for handshake
    // After driver starts: Returns driver status/acknowledgment
    // =========================================================================
    fn readApuPort(self: *Bus, addr: u16) u8 {
        const port = addr - 0x2140;
        const value = self.apu_out[port];
        dbg.apuRead(addr, value, self.apu_out);
        return value;
    }

    // =========================================================================
    // APU PORT WRITE - CPU sends data/commands to the SPC700
    // =========================================================================
    // This is the heart of CPU-APU communication. The protocol has multiple
    // phases, and we need to track state to respond correctly.
    //
    // Protocol reference: https://wiki.superfamicom.org/transferring-data-from-rom-to-the-snes-apu
    // =========================================================================
    fn writeApuPort(self: *Bus, addr: u16, value: u8) void {
        const port = addr - 0x2140;
        self.apu_in[port] = value;

        // -----------------------------------------------------------------
        // PHASE 1: Pre-transfer (boot signature visible)
        // -----------------------------------------------------------------
        // Before $CC is written, APU shows $AA/$BB. Games may clear ports
        // with $00 during init - we must NOT echo these or we lose the
        // boot signature that games poll for.
        if (!self.apu_boot_done) {
            if (port == 0 and value == 0xCC) {
                // $CC to port 0 = "start transfer" command
                // Echo it back to acknowledge, enter transfer mode
                self.apu_boot_done = true;
                self.apu_last_index = 0xCC;
                self.apu_out[0] = 0xCC;
                if (comptime dbg.trace_apu) {
                    std.debug.print("[APU] Transfer start ($CC) - entering transfer mode\n", .{});
                }
            } else {
                // Pre-boot: only echo non-zero, non-boot-signature values
                // This preserves $AA/$BB for the ready check
                const is_boot_sig = (port == 0 and value == 0xAA) or (port == 1 and value == 0xBB);
                if (value != 0 and !is_boot_sig) {
                    self.apu_out[port] = value;
                    dbg.apuWrite(addr, value, true);
                } else {
                    dbg.apuWrite(addr, value, false);
                }
            }
            return;
        }

        // -----------------------------------------------------------------
        // PHASE 4: Post-execute driver communication
        // -----------------------------------------------------------------
        // After the sound driver is running, we're in a game-specific
        // protocol. Common N-SPC patterns:
        //
        // Port 0: Command acknowledgment byte
        //   - Game writes command, driver echoes when processed
        //   - Value $00 typically means "idle/ready"
        //
        // Port 1: Command byte or "no-op" ($FF)
        //   - $FF often means "no command" or "query status"
        //   - When $FF is sent, driver signals ready with port 0 = $00
        //
        // We simulate this by:
        //   - Echoing port 0 writes (game commands)
        //   - When port 1 = $FF, setting port 0 = $00 (driver idle)
        // -----------------------------------------------------------------
        if (self.apu_driver_ready) {
            self.apu_out[port] = value;

            if (port == 1 and value == 0xFF) {
                // $FF to port 1 = "no command" / "idle query"
                // Different games expect different responses. SMW's N-SPC driver
                // likely expects the same boot signature pattern ($BBAA).
                // This matches the pre-transfer ready state.
                self.apu_out[0] = 0xAA;
                self.apu_out[1] = 0xBB;
                if (comptime dbg.trace_apu) {
                    std.debug.print("[APU] Driver: idle query ($FF) -> $BBAA (boot pattern)\n", .{});
                }
            } else if (port == 0) {
                // Command to port 0 - acknowledge by echoing the value
                // (Some drivers increment, but echoing is more common)
                self.apu_out[0] = value;
                if (comptime dbg.trace_apu) {
                    std.debug.print("[APU] Driver cmd: port0=${x:0>2} -> ack\n", .{value});
                }
            } else {
                if (comptime dbg.trace_apu) {
                    std.debug.print("[APU] Driver: port{d}=${x:0>2}\n", .{ port, value });
                }
            }
            return;
        }

        // -----------------------------------------------------------------
        // PHASES 2-3: Data transfer with execute detection
        // -----------------------------------------------------------------
        // During transfer, port 0 carries the byte index (0, 1, 2, ...)
        // and port 1 carries the data byte. We echo port 0 to acknowledge.
        //
        // EXECUTE DETECTION (Phase 4 trigger):
        // The execute command is detected when:
        //   1. Port 1 is written with $00 (meaning "no more data, execute")
        //   2. Port 0 jumps by 2 or more (not a normal +1 increment)
        //
        // When we detect execute, we signal "driver ready" and enter
        // the post-execute communication phase.
        // -----------------------------------------------------------------

        if (port == 0) {
            // Port 0 write during transfer - this is the index/control byte

            // Check for execute command: index jumps by 2+ AND port 1 is $00
            // The jump detection: if new value differs from last by more than 1
            // (accounting for the 0->255 wrap case)
            const diff = value -% self.apu_last_index;
            const is_execute = (diff >= 2) and (self.apu_in[1] == 0x00);

            if (is_execute) {
                // Execute command detected!
                // The uploaded code would now run. We simulate this by
                // entering driver mode and signaling "ready".
                self.apu_driver_ready = true;
                self.apu_out[0] = value; // Echo the execute index
                if (comptime dbg.trace_apu) {
                    std.debug.print("[APU] EXECUTE: index ${x:0>2} (jumped from ${x:0>2}) - driver starting\n", .{ value, self.apu_last_index });
                }
            } else {
                // Normal data transfer - echo the index
                self.apu_out[0] = value;
                self.apu_last_index = value;
            }
        } else {
            // Port 1, 2, or 3 write - just echo it
            self.apu_out[port] = value;
        }

        dbg.apuWrite(addr, value, true);
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
