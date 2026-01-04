// Zupernes - SNES Emulator
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

            // Trigger NMI at start of VBlank (scanline 225) if enabled
            if (self.ppu.scanline == 225) {
                if ((self.bus.nmitimen & 0x80) != 0) {
                    self.cpu.triggerNmi();
                }
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
};

test {
    _ = @import("cpu/cpu.zig");
    _ = @import("bus.zig");
    _ = @import("ppu/ppu.zig");
    _ = @import("cartridge.zig");
    _ = @import("dma.zig");
}
