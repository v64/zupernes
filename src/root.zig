// ZuperNES - SNES Emulator
// Core emulator library

pub const Cpu = @import("cpu/cpu.zig").Cpu;
pub const Bus = @import("bus.zig").Bus;
pub const Ppu = @import("ppu/ppu.zig").Ppu;
pub const Cartridge = @import("cartridge.zig").Cartridge;
pub const Dma = @import("dma.zig").Dma;

pub const Emulator = struct {
    cpu: Cpu,
    ppu: Ppu,
    bus: Bus,

    // Track last scanline for HDMA timing
    last_scanline: u16,

    pub fn init() Emulator {
        return Emulator{
            .cpu = undefined,
            .ppu = Ppu.init(),
            .bus = undefined,
            .last_scanline = 0,
        };
    }

    /// Must be called after init() to set up internal pointers
    /// Call this on the final location of the Emulator struct (not a temporary copy)
    pub fn setup(self: *Emulator) void {
        // Initialize bus with pointer to PPU (PPU is already in final location)
        self.bus = Bus.init(&self.ppu);
        // Initialize CPU with pointer to bus (bus is now in final location)
        self.cpu = Cpu.init(&self.bus);
    }

    pub fn reset(self: *Emulator) void {
        self.cpu.reset(); // Reset CPU state and read reset vector from ROM
        self.ppu.reset(); // Reset PPU registers and state
        self.bus.dma.reset(); // Reset DMA channel state
        self.last_scanline = 0;
        // Note: APU ports (apu_out) keep their boot signature ($AA, $BB)
        // This is correct - APU reset would reinitialize them, not clear them
    }

    pub fn loadRom(self: *Emulator, rom_data: []const u8) !void {
        try self.bus.loadCartridge(rom_data);
        self.reset();
    }

    /// Run one CPU instruction
    pub fn step(self: *Emulator) void {
        const cycles = self.cpu.step();

        // Run APU (SPC700) to stay synchronized with main CPU
        // The SPC700 runs at 1.024 MHz, main CPU at ~3.58 MHz
        // Ratio: 3.58/1.024 ≈ 3.5 CPU cycles per SPC cycle
        self.bus.runApu(cycles);

        // Track current scanline before tick
        const prev_scanline = self.ppu.scanline;

        self.ppu.tick(cycles * 4); // PPU runs at 4x CPU clock

        // Check for scanline transitions
        if (self.ppu.scanline != prev_scanline) {
            // New scanline started
            if (self.ppu.scanline == 0) {
                // Start of new frame - initialize HDMA
                self.bus.dma.initHdma(&self.bus);
            }

            // Start of VBlank (scanline 225):
            if (self.ppu.scanline == 225) {
                // Set the RDNMI ($4210) flag - it latches regardless of
                // whether NMI generation is enabled, and is cleared when
                // the CPU reads $4210 (or when VBlank ends, below).
                self.bus.nmi_flag = true;

                // Auto-joypad read: hardware serially clocks the controllers
                // into $4218-$421F at VBlank start when NMITIMEN bit 0 is set
                if ((self.bus.nmitimen & 0x01) != 0) {
                    self.bus.autoJoypadRead();
                }

                // Trigger NMI if enabled (NMITIMEN bit 7)
                if ((self.bus.nmitimen & 0x80) != 0) {
                    self.cpu.triggerNmi();
                }
            }

            // End of VBlank: the RDNMI flag clears itself even if never read
            if (self.ppu.scanline == 0) {
                self.bus.nmi_flag = false;
            }

            // Run HDMA at H-blank (start of each scanline during visible area)
            if (self.bus.hdmaen != 0 and self.ppu.scanline <= 224) {
                self.bus.dma.runHdma(&self.bus);
            }
        }
    }

    /// Run until the end of a frame
    pub fn runFrame(self: *Emulator) void {
        const frame_start = self.ppu.frame_count;
        while (self.ppu.frame_count == frame_start) {
            self.step();
        }
    }

    /// Get the current framebuffer for rendering
    pub fn getFramebuffer(self: *Emulator) []const u16 {
        return self.ppu.getFramebuffer();
    }

    /// Set the live button state for a controller (0 = pad 1, 1 = pad 2).
    /// Button layout matches the $4219:$4218 auto-read register pair:
    ///   bit 15: B      bit 11: Up      bit 7: A
    ///   bit 14: Y      bit 10: Down    bit 6: X
    ///   bit 13: Select bit  9: Left    bit 5: L
    ///   bit 12: Start  bit  8: Right   bit 4: R
    /// (bits 3-0 are always 0 for a standard controller)
    pub fn setJoypad(self: *Emulator, pad: u1, buttons: u16) void {
        if (pad == 0) {
            self.bus.joypad1 = buttons & 0xFFF0;
        } else {
            self.bus.joypad2 = buttons & 0xFFF0;
        }
    }
};

test {
    _ = @import("cpu/cpu.zig");
    _ = @import("bus.zig");
    _ = @import("ppu/ppu.zig");
    _ = @import("cartridge.zig");
    _ = @import("dma.zig");
}
