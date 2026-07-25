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
pub const Spc700 = @import("apu/spc700.zig").Spc700;
pub const movie = @import("movie.zig");

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

        // Capture the instruction's PBR:PC for the VRAM- and WRAM-write source
        // traces (capture-only; no effect when the traces are disabled).
        self.ppu.writer_pc = (@as(u24, self.cpu.pbr) << 16) | self.cpu.pc;
        self.bus.writer_pc = self.ppu.writer_pc;

        const cycles = self.cpu.step();

        // ======================================================================
        // MASTER-CYCLE CONVERSION
        // ======================================================================
        // cpu.step() returns untimed CPU cycles; the true master-clock cost
        // is region-dependent per bus access (Bus.memSpeed: SlowROM/WRAM 8,
        // I/O 6, joypad 12, FastROM 6). The CPU accounted its accesses in
        // mem_masters/mem_accesses; the remaining cycles are internal ones
        // at 6 master cycles each. Flat-rating everything at 6 (the old
        // model) ran typical SlowROM code ~30% fast relative to the
        // PPU/APU/DSP - which broke Super Mario Kart's cycle-tuned blind
        // DSP-1 parameter writes (see Bus.memSpeed docs).
        const accesses: u32 = self.cpu.mem_accesses;
        const internal: u32 = @as(u32, cycles) -| accesses;
        // DMA/HDMA transfers execute synchronously inside the instruction
        // that triggered them (a $420B write, or runHdma below on a prior
        // step); their bus time accumulates in Bus.dma_masters and is
        // billed here. The DSP was ALREADY ticked during the transfer
        // (Bus.tickDmaByte), so dma_extra goes to the PPU/APU only.
        const dma_extra: u32 = self.bus.dma_masters;
        self.bus.dma_masters = 0;
        const master: u32 = self.cpu.mem_masters + internal * 6;

        // Run APU (SPC700) to stay synchronized with main CPU. The APU's
        // fixed-point ratio (~20.98 master cycles per SPC700 cycle) expects
        // master-clock units.
        self.bus.runApu(master + dma_extra);

        // Clock the DSP-1 coprocessor. The uPD77C25 executes one
        // instruction per clock of its 7.6MHz crystal (see Bus.tickDsp).
        // Games poll the DSP's RQM bit, so small ratio
        // error is absorbed by the handshake - but Super Mario Kart also
        // does BLIND cycle-counted writes, so the DSP is ticked at SUB-
        // instruction granularity: Cpu.accountAccess brings it up to "now"
        // before every bus access (flushing internal_flushed cycles), and
        // only the instruction's trailing internal cycles remain here.
        self.bus.tickDsp((internal -| self.cpu.internal_flushed) * 6);

        // Track current position before tick (for scanline-transition and
        // IRQ-point crossing detection below)
        const prev_scanline = self.ppu.scanline;
        const prev_dot = self.ppu.dot;

        // Advance the PPU by the instruction's true master-cycle cost (one
        // PPU dot is 4 master clocks, one scanline 1364), plus any DMA time
        // the instruction triggered. Using the real per-access memory
        // speeds here is what fixes the CPU-vs-frame pacing: at flat 6 the
        // CPU got ~30% more instructions per frame than hardware in
        // SlowROM code.
        self.ppu.tick(master + dma_extra);

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

    // ---- VRAM-write source trace (capture-only debug/capture API) ----
    // A general tool for "which routine populates this VRAM region, from what
    // source?". Enabling it only records $2118/$2119 writes in a word-address
    // window (with the writer PBR:PC and any DMA source); it never alters PPU,
    // CPU, or DMA behavior, so emulated output is unchanged. See ppu.VramTrace.
    pub const VramWrite = @import("ppu/ppu.zig").VramWrite;

    /// Begin tracing VRAM writes whose word address is in [lo, hi]. Clears any
    /// previously captured events.
    pub fn traceVramWrites(self: *Emulator, lo: u16, hi: u16) void {
        self.ppu.vram_trace.filter_lo = lo;
        self.ppu.vram_trace.filter_hi = hi;
        self.ppu.vram_trace.count = 0;
        self.ppu.vram_trace.dropped = 0;
        self.ppu.vram_trace.enabled = true;
    }

    /// Stop recording (leaves captured events intact for reading).
    pub fn stopVramTrace(self: *Emulator) void {
        self.ppu.vram_trace.enabled = false;
    }

    /// The events captured so far (oldest first).
    pub fn vramTraceEvents(self: *const Emulator) []const VramWrite {
        return self.ppu.vram_trace.events[0..self.ppu.vram_trace.count];
    }

    /// Count of writes dropped past the trace capacity (0 = complete).
    pub fn vramTraceDropped(self: *const Emulator) usize {
        return self.ppu.vram_trace.dropped;
    }

    // ---- WRAM-write source trace (capture-only debug/capture API) ----
    // The WRAM counterpart of the VRAM trace above, on identical terms: a
    // general tool for "which routine writes this variable, and when?".
    // Enabling it only records writes whose WRAM offset falls in a window,
    // with the writer PBR:PC and which of the three WRAM paths carried it; it
    // never alters bus, CPU, or DMA behavior, so emulated output is unchanged.
    // See bus.WramTrace. Not game-specific and not tied to any address.
    pub const WramWrite = @import("bus.zig").WramWrite;

    /// Begin tracing WRAM writes whose offset is in [lo, hi] (bank $7E maps to
    /// $00000, $7F to $10000; the $00-$3F low-8KB mirror lands on the same
    /// offsets, so a zero-page filter catches every writer). Clears any
    /// previously captured events.
    pub fn traceWramWrites(self: *Emulator, lo: u24, hi: u24) void {
        self.bus.wram_trace.filter_lo = lo;
        self.bus.wram_trace.filter_hi = hi;
        self.bus.wram_trace.count = 0;
        self.bus.wram_trace.dropped = 0;
        self.bus.wram_trace.enabled = true;
    }

    /// Stop recording (leaves captured events intact for reading).
    pub fn stopWramTrace(self: *Emulator) void {
        self.bus.wram_trace.enabled = false;
    }

    /// The events captured so far (oldest first).
    pub fn wramTraceEvents(self: *const Emulator) []const WramWrite {
        return self.bus.wram_trace.events[0..self.bus.wram_trace.count];
    }

    /// Count of writes dropped past the trace capacity (0 = complete).
    pub fn wramTraceDropped(self: *const Emulator) usize {
        return self.bus.wram_trace.dropped;
    }

    /// Drain decoded audio from the APU: stereo i16 frames at 32kHz.
    /// Returns the number of frames written into dst.
    pub fn readAudioSamples(self: *Emulator, dst: [][2]i16) usize {
        return self.bus.apu.readSamples(dst);
    }

    /// Canonical APU capture-state byte count. The state is pointer-free and
    /// excludes already-produced PCM; drain audio before taking an anchor.
    pub const audio_state_len = @import("apu/apu.zig").Apu.state_len;

    pub fn writeAudioState(self: *const Emulator, dst: []u8) usize {
        return self.bus.apu.writeState(dst);
    }

    pub fn readAudioState(self: *Emulator, src: []const u8) usize {
        return self.bus.apu.readState(src);
    }

    // ---- Savestate (capture-only machine snapshot / restore) ----
    // A general emulator capability, on the same terms as the traces above:
    // nothing here runs during ordinary emulation and taking a snapshot does
    // not perturb the machine. The format is an explicit pointer-free byte
    // layout, NOT a struct dump, because the Emulator is self-referential
    // (see savestate.zig). Restore into a machine that has already had
    // setup() and loadRom() run with the SAME ROM; every interior pointer in
    // the destination survives untouched.
    pub const savestate = @import("savestate.zig");
    pub const state_len = savestate.state_len;
    pub const StateError = savestate.Error;

    /// Capture the whole machine into dst (>= state_len bytes).
    pub fn writeState(self: *const Emulator, dst: []u8) StateError!usize {
        return savestate.write(&self.cpu, &self.ppu, &self.bus, self.last_scanline, dst);
    }

    /// Restore a snapshot previously produced by writeState.
    pub fn readState(self: *Emulator, src: []const u8) StateError!usize {
        return savestate.read(&self.cpu, &self.ppu, &self.bus, &self.last_scanline, src);
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
    _ = @import("movie.zig");
    _ = @import("savestate.zig");
}
