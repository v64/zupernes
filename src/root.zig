// Zupernes - SNES Emulator
// Core emulator library

pub const Cpu = @import("cpu/cpu.zig").Cpu;
pub const Bus = @import("bus.zig").Bus;
pub const Ppu = @import("ppu/ppu.zig").Ppu;
pub const Cartridge = @import("cartridge.zig").Cartridge;

pub const Emulator = struct {
    cpu: Cpu,
    ppu: Ppu,
    bus: Bus,

    pub fn init() Emulator {
        var emu: Emulator = undefined;
        emu.bus = Bus.init(&emu.ppu);
        emu.cpu = Cpu.init(&emu.bus);
        emu.ppu = Ppu.init();
        return emu;
    }

    pub fn reset(self: *Emulator) void {
        self.cpu.reset();
        self.ppu.reset();
    }

    pub fn loadRom(self: *Emulator, rom_data: []const u8) !void {
        try self.bus.loadCartridge(rom_data);
        self.reset();
    }

    /// Run one CPU instruction
    pub fn step(self: *Emulator) void {
        const cycles = self.cpu.step();
        self.ppu.tick(cycles * 4); // PPU runs at 4x CPU clock
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
}
