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
const master_cycles_per_dot = @import("ppu/ppu.zig").MASTER_CYCLES_PER_DOT;

// Anomie's timing measurements place the frame-start HDMA initialization at
// about V=0/H=6 and each visible-line transfer at H=278.  H-blank itself
// begins at H=274; the later point is the DMA controller's bus-arbitration
// event, not merely the PPU blanking edge.
const hdma_init_dot: u16 = 6;
const hdma_transfer_dot: u16 = 278;

pub const Emulator = struct {
    cpu: Cpu,
    ppu: Ppu,
    bus: Bus,

    // Track last scanline for HDMA timing
    last_scanline: u16,

    /// Capture-only input recorder; see `recordInputs`. Deliberately NOT
    /// part of the savestate: a snapshot captures the machine, not the
    /// instrument watching it.
    input_record: InputRecord = .{},

    /// Capture-only executed-instruction recorder; see `traceExec`. Like
    /// `input_record` above it is deliberately NOT part of the savestate: a
    /// snapshot captures the machine, not the instrument watching it.
    exec_trace: ExecTrace = .{},

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
        // Capture-only; see `traceExec`. One never-taken branch when disabled.
        self.exec_trace.record(self.ppu.writer_pc);

        self.bus.beginCpuInstruction();
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
        self.advancePpuWithHdma(master + dma_extra);

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
        }
    }

    const HdmaEvent = struct {
        kind: enum { init, transfer },
        masters_until: u32,
    };

    /// Return the next hardware HDMA point strictly after the PPU's committed
    /// beam position.  Keeping this in master-clock units preserves the PPU's
    /// sub-dot accumulator when an instruction ends between dots.
    fn nextHdmaEvent(self: *const Emulator) HdmaEvent {
        const line_masters: u32 = @as(u32, zupernes_dots_per_line) * master_cycles_per_dot;
        const frame_masters: u32 = line_masters * @as(u32, zupernes_lines_per_frame);
        const now: u32 = @as(u32, self.ppu.scanline) * line_masters +
            @as(u32, self.ppu.dot) * master_cycles_per_dot + self.ppu.master_accum;

        const init_at: u32 = @as(u32, hdma_init_dot) * master_cycles_per_dot;
        const init_delta = if (init_at > now)
            init_at - now
        else
            frame_masters - now + init_at;

        const transfer_offset: u32 = @as(u32, hdma_transfer_dot) * master_cycles_per_dot;
        var transfer_at: u32 = undefined;
        if (self.ppu.scanline <= 224) {
            const this_line = @as(u32, self.ppu.scanline) * line_masters + transfer_offset;
            if (this_line > now) {
                transfer_at = this_line;
            } else if (self.ppu.scanline < 224) {
                transfer_at = (@as(u32, self.ppu.scanline) + 1) * line_masters + transfer_offset;
            } else {
                transfer_at = frame_masters + transfer_offset;
            }
        } else {
            transfer_at = frame_masters + transfer_offset;
        }
        const transfer_delta = transfer_at - now;

        if (init_delta < transfer_delta) {
            return .{ .kind = .init, .masters_until = init_delta };
        }
        return .{ .kind = .transfer, .masters_until = transfer_delta };
    }

    /// Advance the PPU through one completed CPU instruction, stopping at the
    /// DMA controller's hardware beam points.  CPU execution is still at
    /// instruction granularity, but PPU/APU time is split at the event so an
    /// HDMA register write is journaled at H=278 plus its byte-transfer time,
    /// rather than at the following scanline's H=0.
    fn advancePpuWithHdma(self: *Emulator, elapsed_masters: u32) void {
        var remaining = elapsed_masters;
        while (remaining != 0) {
            const event = self.nextHdmaEvent();
            if (event.masters_until > remaining) {
                self.ppu.tick(remaining);
                return;
            }

            self.ppu.tick(event.masters_until);
            remaining -= event.masters_until;

            self.bus.beginStandaloneDma();
            switch (event.kind) {
                .init => self.bus.dma.initHdma(&self.bus),
                .transfer => if (self.bus.hdmaen != 0) {
                    self.bus.dma.runHdma(&self.bus);
                },
            }

            // HDMA byte time is produced synchronously by tickDmaByte().  It
            // is stolen from the CPU at this beam point, so commit it now;
            // leaving it for the next instruction would put the PPU write at
            // the right projected dot but pause the actual beam too late.
            const hdma_masters = self.bus.dma_masters;
            self.bus.dma_masters = 0;
            if (hdma_masters != 0) {
                self.bus.runApu(hdma_masters);
                self.ppu.tick(hdma_masters);
            }
        }
    }

    /// Run until the end of a frame
    pub fn runFrame(self: *Emulator) void {
        self.input_record.sample(self.bus.joypad1);
        const frame_start = self.ppu.frame_count;
        while (self.ppu.frame_count == frame_start) {
            self.step();
        }
    }

    // ---- Input recording (capture-only debug/capture API) ----
    // A general "what did the machine actually play?" recorder, on the same
    // terms as the VRAM and WRAM traces: it observes and cannot perturb, and
    // it is not tied to any game.
    //
    // Sampled at the FRAME BOUNDARY in runFrame, which is the same point
    // replay writes with setJoypad - so record and replay are symmetric by
    // construction rather than by agreement. Two consequences worth stating:
    //
    //  - Lag frames are captured definitionally, because the sample is per
    //    EMULATED frame, which is exactly the .zmov contract.
    //  - It is deliberately NOT hooked at bus.autoJoypadRead, the true
    //    hardware consumption point: that only runs when NMITIMEN bit 0 is
    //    set, so a frame with auto-read disabled would record NOTHING and
    //    silently shorten the movie. The frame boundary is defined on every
    //    frame, which is the property that matters.
    //
    // The buffer is caller-owned so Emulator stays small and the recorder
    // never allocates; recording state is not part of a savestate.
    pub const InputRecord = struct {
        dst: []u16 = &.{},
        count: usize = 0,
        dropped: usize = 0,
        enabled: bool = false,

        fn sample(self: *InputRecord, pad: u16) void {
            if (!self.enabled) return;
            if (self.count == self.dst.len) {
                self.dropped += 1;
                return;
            }
            self.dst[self.count] = pad;
            self.count += 1;
        }
    };

    /// Every instruction the 65816 executes, as `PBR:PC`, while enabled and
    /// while the address falls in `[filter_lo, filter_hi]`.
    ///
    /// It ONLY observes: `step` already computes this exact value for the VRAM
    /// and WRAM write traces, so recording it cannot alter bus, CPU or DMA
    /// state or timing, and enabling it has zero effect on emulated output.
    /// Answers "what did the CPU actually execute here?" - the counterpart to
    /// the write traces' "which routine wrote this?", and the one question a
    /// write trace can only answer by elimination.
    ///
    /// The buffer belongs to the caller (like `recordInputs`), because a useful
    /// instruction window is far larger than a write window and does not belong
    /// embedded in the machine. `dropped` counts instructions past the end, so
    /// a truncated capture convicts itself instead of reading as a short path -
    /// a nonzero `dropped` means narrow the filter or enlarge the buffer, never
    /// interpret the result.
    pub const ExecTrace = struct {
        dst: []u24 = &.{},
        count: usize = 0,
        dropped: usize = 0,
        enabled: bool = false,
        filter_lo: u24 = 0,
        filter_hi: u24 = 0xFFFFFF,

        fn record(self: *ExecTrace, pc: u24) void {
            if (!self.enabled) return;
            if (pc < self.filter_lo or pc > self.filter_hi) return;
            if (self.count == self.dst.len) {
                self.dropped += 1;
                return;
            }
            self.dst[self.count] = pc;
            self.count += 1;
        }
    };

    /// Begin recording executed `PBR:PC` values into `dst`, one entry per
    /// instruction whose address is in [lo, hi]. Clears any previous capture.
    pub fn traceExec(self: *Emulator, dst: []u24, lo: u24, hi: u24) void {
        self.exec_trace = .{ .dst = dst, .enabled = true, .filter_lo = lo, .filter_hi = hi };
    }

    /// Stop recording (leaves the captured instructions intact for reading).
    pub fn stopExecTrace(self: *Emulator) void {
        self.exec_trace.enabled = false;
    }

    /// The instructions captured so far (oldest first).
    pub fn execTraceEvents(self: *const Emulator) []const u24 {
        return self.exec_trace.dst[0..self.exec_trace.count];
    }

    /// Count of instructions dropped past the buffer (0 = complete).
    pub fn execTraceDropped(self: *const Emulator) usize {
        return self.exec_trace.dropped;
    }

    /// Begin recording controller 1 into `dst`, one entry per emulated frame.
    /// Clears any previous capture.
    pub fn recordInputs(self: *Emulator, dst: []u16) void {
        self.input_record = .{ .dst = dst, .enabled = true };
    }

    /// Stop recording (leaves the captured frames intact for reading).
    pub fn stopRecording(self: *Emulator) void {
        self.input_record.enabled = false;
    }

    /// The frames captured so far, in order.
    pub fn recordedInputs(self: *const Emulator) []const u16 {
        return self.input_record.dst[0..self.input_record.count];
    }

    /// Frames dropped past the buffer's capacity (0 = the capture is
    /// complete). A nonzero value means the recording is TRUNCATED and must
    /// not be presented as a full run.
    pub fn recordedInputsDropped(self: *const Emulator) usize {
        return self.input_record.dropped;
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

    /// Capture-only field timing for a consumer which must replay this
    /// emulator's CPU-driven APU clock in another host.  It observes neither
    /// sound state nor ports, and ordinary emulation never enables it.
    pub fn beginAudioFrameClockCapture(self: *Emulator) void {
        self.bus.apu.beginFrameClockCapture();
    }

    pub fn endAudioFrameClockCapture(self: *Emulator) ?@import("apu/apu.zig").Apu.FrameClock {
        return self.bus.apu.endFrameClockCapture();
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

    /// Restore from a snapshot FILE, reporting the snapshot's own sha256 so a
    /// caller can record the provenance it was resumed from.
    ///
    /// One code path for every frontend deliberately. The interactive and
    /// headless loaders differ only in how they report failure, and two
    /// copies of "read, size-check, restore, hash" is how a headless resume
    /// would eventually drift from an interactive one - the same class as the
    /// recorder that accumulated its own pads beside the emulator's.
    ///
    /// Reading `state_len + 1` is the size check: a snapshot from a build
    /// that captured MORE state must fail rather than being truncated into a
    /// plausible-looking restore. `readState` then rejects a short or
    /// relaid-out one via the header's layout length.
    pub fn readStateFile(
        self: *Emulator,
        allocator: std.mem.Allocator,
        path: []const u8,
        sha256_hex_out: ?*[64]u8,
    ) ![]u8 {
        const snapshot = try std.fs.cwd().readFileAlloc(allocator, path, state_len + 1);
        errdefer allocator.free(snapshot);
        _ = try self.readState(snapshot);
        if (sha256_hex_out) |out| {
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(snapshot, &digest, .{});
            _ = std.fmt.bufPrint(out, "{x}", .{&digest}) catch unreachable;
        }
        return snapshot;
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

test "recording is symmetric with replay through the .zmov text" {
    // The acceptance test for the recording path: whatever the machine was
    // driven with must come back out of the file byte-for-byte, at the same
    // frame indices, WITHOUT the test agreeing with the recorder about where
    // the sample point is. Both sides go through the public API only.
    const allocator = std.testing.allocator;
    const schedule = [_]u16{ 0x0000, 0x4100, 0x4100, 0x0080, 0x0000, 0x1000 };

    var buf: [schedule.len]u16 = undefined;
    var emu = Emulator.init();
    emu.setup();
    emu.recordInputs(&buf);
    for (schedule) |pad| {
        emu.setJoypad(0, pad);
        emu.runFrame();
    }
    emu.stopRecording();
    try std.testing.expectEqual(@as(usize, 0), emu.recordedInputsDropped());
    try std.testing.expectEqual(schedule.len, emu.recordedInputs().len);

    // setJoypad masks the low nibble (the $4218 layout has no bits there),
    // so compare against what the machine actually holds, not the raw ask.
    for (emu.recordedInputs(), schedule) |got, asked| {
        try std.testing.expectEqual(asked & 0xFFF0, got);
    }

    var recorded = movie.Movie{ .frames = .empty };
    defer recorded.deinit(allocator);
    try recorded.frames.appendSlice(allocator, emu.recordedInputs());
    recorded.meta.rom_sha256 = "abc123";
    recorded.meta.recorded_frames = @intCast(emu.recordedInputs().len);

    const text = try recorded.serialize(allocator, "round trip");
    defer allocator.free(text);
    var replayed = try movie.Movie.parse(allocator, text);
    defer replayed.deinit(allocator);

    try std.testing.expectEqual(recorded.len(), replayed.len());
    try std.testing.expectEqual(recorded.len(), replayed.meta.recorded_frames.?);
    try std.testing.expectEqualStrings("abc123", replayed.meta.rom_sha256.?);
    for (0..replayed.len()) |i| {
        try std.testing.expectEqual(schedule[i] & 0xFFF0, replayed.buttons(@intCast(i)));
    }
}

test "a truncated recording is reported, not silently short" {
    var small: [2]u16 = undefined;
    var emu = Emulator.init();
    emu.setup();
    emu.recordInputs(&small);
    for (0..5) |_| emu.runFrame();
    try std.testing.expectEqual(@as(usize, 2), emu.recordedInputs().len);
    try std.testing.expectEqual(@as(usize, 3), emu.recordedInputsDropped());
}

test "recording is off by default and does not survive into a savestate" {
    var emu = Emulator.init();
    emu.setup();
    emu.runFrame();
    try std.testing.expectEqual(@as(usize, 0), emu.recordedInputs().len);
    try std.testing.expectEqual(@as(usize, 0), emu.recordedInputsDropped());
    // The recorder is an instrument, not machine state: state_len is the
    // captured machine only, so arming it cannot change a snapshot's size.
    const before = Emulator.state_len;
    var buf: [4]u16 = undefined;
    emu.recordInputs(&buf);
    try std.testing.expectEqual(before, Emulator.state_len);
}

test "HDMA initialization occurs at line zero H=6" {
    var emu = Emulator.init();
    emu.setup();

    emu.bus.hdmaen = 0x01;
    emu.bus.dma.hdma_enable = 0x01;
    emu.bus.dma.channels[0].a_addr = 0x7E0000;
    emu.bus.wram[0] = 0x81;

    emu.advancePpuWithHdma(hdma_init_dot * master_cycles_per_dot - 1);
    try std.testing.expectEqual(@as(u16, 0), emu.bus.dma.channels[0].hdma_addr);
    try std.testing.expectEqual(@as(u8, 0), emu.bus.dma.channels[0].line_counter);

    emu.advancePpuWithHdma(1);
    try std.testing.expectEqual(hdma_init_dot, emu.ppu.dot);
    try std.testing.expectEqual(@as(u16, 1), emu.bus.dma.channels[0].hdma_addr);
    try std.testing.expectEqual(@as(u8, 0x81), emu.bus.dma.channels[0].line_counter);
    try std.testing.expect(emu.bus.dma.channels[0].hdma_do_transfer);
}

test "visible-line HDMA write is journaled from H=278, not line start" {
    var emu = Emulator.init();
    emu.setup();

    // Begin just after the separate H=6 initialization point and prepare one
    // direct mode-0 byte to INIDISP.  A zero next line descriptor terminates
    // the channel after this transfer.
    emu.ppu.tick(277 * master_cycles_per_dot);
    emu.bus.hdmaen = 0x01;
    emu.bus.dma.hdma_enable = 0x01;
    emu.bus.dma.channels[0].a_addr = 0x7E0000;
    emu.bus.dma.channels[0].hdma_addr = 0;
    emu.bus.dma.channels[0].line_counter = 1;
    emu.bus.dma.channels[0].hdma_do_transfer = true;
    emu.bus.wram[0] = 0x0F;
    emu.bus.wram[1] = 0;

    const before = emu.ppu.inidisp;
    emu.advancePpuWithHdma(master_cycles_per_dot - 1);
    try std.testing.expectEqual(before, emu.ppu.inidisp);
    try std.testing.expectEqual(@as(usize, 0), emu.ppu.render_event_count);

    emu.advancePpuWithHdma(1);
    try std.testing.expectEqual(@as(u8, 0x0F), emu.ppu.inidisp);
    try std.testing.expectEqual(@as(usize, 1), emu.ppu.render_event_count);
    try std.testing.expectEqual(@as(u16, hdma_transfer_dot + 2), emu.ppu.render_events[0].dot);
    try std.testing.expectEqual(@as(u16, hdma_transfer_dot + 2), emu.ppu.dot);
    try std.testing.expectEqual(@as(u32, 0), emu.bus.dma_masters);
}
