// ZuperNES - SNES Emulator
// Core emulator library

const std = @import("std");
const dbg = @import("debug.zig");

pub const Cpu = @import("cpu/cpu.zig").Cpu;
pub const CpuFlags = @import("cpu/cpu.zig").Flags;
pub const Bus = @import("bus.zig").Bus;
pub const Ppu = @import("ppu/ppu.zig").Ppu;
pub const Cartridge = @import("cartridge.zig").Cartridge;
pub const Dma = @import("dma.zig").Dma;

const zupernes_dots_per_line = @import("ppu/ppu.zig").DOTS_PER_SCANLINE;
const zupernes_lines_per_frame = @import("ppu/ppu.zig").SCANLINES_PER_FRAME;

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
        self.bus.dsp1.reset(); // Reset DSP-1 coprocessor (keeps its microcode)
        self.bus.dsp_accum = 0;
        self.last_scanline = 0;
        // Note: APU ports (apu_out) keep their boot signature ($AA, $BB)
        // This is correct - APU reset would reinitialize them, not clear them
    }

    pub fn loadRom(self: *Emulator, rom_data: []const u8) !void {
        try self.bus.loadCartridge(rom_data);

        // If the cartridge header announces a DSP coprocessor, try to load
        // the uPD77C25 microcode dump from disk. Nearly all DSP-1 games use
        // the DSP-1B revision (Super Mario Kart included); plain DSP-1 is
        // the fallback for the few early boards (original Pilotwings).
        // Missing microcode is not fatal - the game just hangs at its DSP
        // handshake exactly as it did before this feature existed.
        self.bus.dsp1_present = false;
        if (self.bus.cartridge.?.has_dsp) {
            const candidates = [_][]const u8{
                "test/dsp/dsp1b.rom",
                "test/dsp/dsp1.rom",
                "dsp1b.rom",
                "dsp1.rom",
            };
            var buf: [8192]u8 = undefined;
            for (candidates) |path| {
                const data = std.fs.cwd().readFile(path, &buf) catch continue;
                if (self.bus.dsp1.loadRom(data)) |_| {
                    self.bus.dsp1_present = true;
                    break;
                } else |_| {}
            }
            if (!self.bus.dsp1_present) {
                std.debug.print(
                    "Cartridge requires a DSP coprocessor but no microcode found\n" ++
                        "(looked for test/dsp/dsp1b.rom - see NEXTSTEPS.md); game may hang\n",
                    .{},
                );
            }
        }

        self.reset();
    }

    /// Run one CPU instruction
    pub fn step(self: *Emulator) void {
        // Sync the level-triggered IRQ line: if the H/V timer flag was
        // acknowledged (game read $4211) or disabled, drop the pending IRQ.
        if (!self.bus.irq_flag) {
            self.cpu.irq_pending = false;
        }

        const cycles = self.cpu.step();

        // Run APU (SPC700) to stay synchronized with main CPU.
        // cpu.step() counts cycles in ~3.58 MHz CPU clocks; the APU's
        // fixed-point ratio (3.496 CPU clocks per SPC700 cycle) expects
        // exactly that unit.
        self.bus.runApu(cycles);

        // Clock the DSP-1 coprocessor. The uPD77C25 executes one instruction
        // every 4 clocks of its 8.192MHz crystal = 2.048 MIPS. Relative to
        // the 21.477MHz master clock that's 2.048/21.477 ~= 2/21 instructions
        // per master cycle. The accumulator lives on the Bus because DMA
        // must also tick the DSP (see Bus.tickDsp). Games poll the DSP's
        // RQM bit, so small ratio error is absorbed by the handshake.
        self.bus.tickDsp(cycles * 6);

        // Track current position before tick (for scanline-transition and
        // IRQ-point crossing detection below)
        const prev_scanline = self.ppu.scanline;
        const prev_dot = self.ppu.dot;

        // Advance the PPU. One CPU cycle is ~6 master clocks (memory access
        // speed actually varies: 6 for internal/fast, 8 for SlowROM/WRAM,
        // 12 for $4016/$4017 - per-access accounting is future cycle-
        // accuracy work), and one PPU dot is 4 master clocks. This gives
        // the correct ~227 CPU cycles per 1364-master-cycle scanline.
        self.ppu.tick(cycles * 6);

        // ======================================================================
        // H/V TIMER IRQ ($4200 bits 4-5, $4207-$420A)
        // ======================================================================
        // The PPU's H/V counters trigger an IRQ when they pass the point
        // configured in HTIME/VTIME:
        //   H-IRQ only:  every scanline at H = HTIME
        //   V-IRQ only:  once per frame at V = VTIME, H = ~2
        //   H+V IRQ:     once per frame at V = VTIME, H = HTIME
        // We detect whether the (scanline, dot) position crossed the trigger
        // point during this instruction. Out-of-range HTIME (>340) or VTIME
        // (>261) values simply never match - that's how games "disable" the
        // timer without touching NMITIMEN.
        // ======================================================================
        const irq_mode = self.bus.nmitimen & 0x30;
        if (irq_mode != 0) {
            const dots_per_line: u32 = @intCast(zupernes_dots_per_line);
            const total: u32 = dots_per_line * @as(u32, @intCast(zupernes_lines_per_frame));
            const prev_pos: u32 = @as(u32, prev_scanline) * dots_per_line + prev_dot;
            const cur_pos: u32 = @as(u32, self.ppu.scanline) * dots_per_line + self.ppu.dot;
            // Unwrap across the frame boundary so cur is always >= prev
            const cur_unwrapped = if (cur_pos >= prev_pos) cur_pos else cur_pos + total;

            var crossed = false;
            if (irq_mode == 0x10) {
                // H-IRQ every line: find the first position after prev_pos
                // whose dot component equals HTIME
                const h: u32 = self.bus.htime;
                if (h < dots_per_line) {
                    const line_start = (prev_pos / dots_per_line) * dots_per_line;
                    const candidate = line_start + h;
                    const target = if (candidate > prev_pos) candidate else candidate + dots_per_line;
                    crossed = target <= cur_unwrapped;
                }
            } else {
                // V-IRQ (with or without H component): a single point per frame
                const h: u32 = if (irq_mode == 0x20) 2 else self.bus.htime;
                const v: u32 = self.bus.vtime;
                if (h < dots_per_line and v < zupernes_lines_per_frame) {
                    const point = v * dots_per_line + h;
                    const target = if (point > prev_pos) point else point + total;
                    crossed = target <= cur_unwrapped;
                }
            }

            if (crossed) {
                self.bus.irq_flag = true;
                self.cpu.triggerIrq();
            }
        }

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

    /// Drain decoded audio from the APU: stereo i16 frames at 32kHz.
    /// Returns the number of frames written into dst.
    pub fn readAudioSamples(self: *Emulator, dst: [][2]i16) usize {
        return self.bus.apu.readSamples(dst);
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
    _ = @import("coproc/upd7725.zig");
}
