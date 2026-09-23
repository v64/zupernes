// ZuperNES - SNES Emulator
// Core emulator library

const std = @import("std");
const dbg = @import("debug.zig");

pub const Cpu = @import("cpu/cpu.zig").Cpu;
pub const CpuFlags = @import("cpu/cpu.zig").Flags;
const bus_module = @import("bus.zig");
pub const Bus = bus_module.Bus;
pub const Ppu = @import("ppu/ppu.zig").Ppu;
pub const Cartridge = @import("cartridge.zig").Cartridge;
pub const Dma = @import("dma.zig").Dma;
pub const Spc700 = @import("apu/spc700.zig").Spc700;
pub const movie = @import("movie.zig");
pub const RefreshTimeline = @import("refresh_timing.zig").Timeline;
const refresh_timing = @import("refresh_timing.zig");
/// CPU cycle provenance reported through Bus.advanceCpuPhase (exported for
/// the 65816 vector harness's cycle-sequence audit).
pub const CpuClockPhase = refresh_timing.CpuPhase;
pub const TimingProbeKind = @import("bus.zig").TimingProbeKind;

const zupernes_dots_per_line = @import("ppu/ppu.zig").DOTS_PER_SCANLINE;
const zupernes_lines_per_frame = @import("ppu/ppu.zig").SCANLINES_PER_FRAME;
const master_cycles_per_dot = @import("ppu/ppu.zig").MASTER_CYCLES_PER_DOT;
const masters_per_line: u64 = @as(u64, zupernes_dots_per_line) * master_cycles_per_dot;
const masters_per_frame: u64 = masters_per_line * zupernes_lines_per_frame;

fn absolutePpuMaster(ppu: *const Ppu) u64 {
    return ppu.absoluteMaster();
}

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

    // Research-stage serialized wall owner. It is connected explicitly only
    // by bounded fixtures until interrupt sampling and state replay migrate.
    refresh_timeline: RefreshTimeline,
    ordered_last_cpu_cycle_start: u64,
    // Mesen2 SnesCpuState::IrqLock: set when the most recent CPU cycle
    // start serviced a DMA/HDMA transfer. Consumed by the interrupt model.
    ordered_irq_lock: bool = false,
    // Wall master at which the current instruction began (ordered path).
    ordered_instruction_start: u64 = 0,

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
            .refresh_timeline = RefreshTimeline.reset(),
            .ordered_last_cpu_cycle_start = 0,
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
        // Reset-vector reads happen outside an executing CPU access phase.
        self.bus.invalidateCpuReadSample();
        self.cpu.reset(); // Reset CPU state and read reset vector from ROM
        self.ppu.reset(); // Reset PPU registers and state
        self.bus.dma.reset(); // Reset DMA channel state
        self.bus.dsp1.reset(); // Reset DSP-1 coprocessor (keeps its microcode)
        self.bus.dsp_accum = 0;
        self.last_scanline = 0;
        self.refresh_timeline = RefreshTimeline.reset();
        self.ordered_last_cpu_cycle_start = 0;
        // Note: APU ports (apu_out) keep their boot signature ($AA, $BB)
        // This is correct - APU reset would reinitialize them, not clear them
    }

    pub fn loadRomFilesystemFree(self: *Emulator, rom_data: []const u8) !void {
        // Build the machine minus the HOST part of cartridge bring-up: no
        // microcode dump lookup, no filesystem. The browser-theater WASM
        // adapter (wasm32-freestanding, no std.fs) calls this so native and
        // WASM construct the identical machine through one shared code path.
        // dsp1_present stays false here; a native host layers the microcode
        // on top in loadRom below. For a non-DSP cartridge this IS the whole
        // bring-up (the DSP microcode was reset by reset()).
        try self.bus.loadCartridge(rom_data);
        self.bus.dsp1_present = false;
        self.reset();
    }

    pub fn loadRom(self: *Emulator, rom_data: []const u8) !void {
        // The portable machine first (cartridge, reset, APU boot) - the same
        // call the browser-theater WASM adapter uses - then the HOST-only
        // step below. See loadRomFilesystemFree for the split's rationale.
        try self.loadRomFilesystemFree(rom_data);
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
    }

    /// Run one CPU instruction
    pub fn step(self: *Emulator) void {
        // Capture the instruction's PBR:PC for the VRAM- and WRAM-write source
        // traces (capture-only; no effect when the traces are disabled).
        self.ppu.writer_pc = (@as(u24, self.cpu.pbr) << 16) | self.cpu.pc;
        self.bus.writer_pc = self.ppu.writer_pc;
        // Capture-only; see `traceExec`. One never-taken branch when disabled.
        self.exec_trace.record(self.ppu.writer_pc);

        const instruction_start = absolutePpuMaster(&self.ppu);
        self.ordered_last_cpu_cycle_start = instruction_start;
        self.ordered_instruction_start = instruction_start;
        self.bus.beginCpuInstruction();
        defer self.bus.invalidateCpuReadSample();
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
        // (Bus.tickDmaHalfByte), so dma_extra goes to the PPU/APU only.
        const dma_extra: u32 = self.bus.dma_masters;
        self.bus.dma_masters = 0;
        const master: u32 = self.cpu.mem_masters + internal * 6;

        if (self.bus.orderedClockConnected()) {
            // Accesses, DMA, and flushed internal phases have already advanced
            // the wall owner in execution order. Only CPU internal work left
            // after the last access remains. Ordered DMA never accumulates in
            // the legacy aggregate.
            std.debug.assert(dma_extra == 0);
            const trailing_internal = internal -| self.cpu.internal_flushed;
            for (0..trailing_internal) |_| {
                self.bus.advanceCpuPhase(6, .internal_trailing);
            }
            const instruction_end = absolutePpuMaster(&self.ppu);
            std.debug.assert(instruction_end == self.refresh_timeline.wall_master);

            // While halted in WAI, interrupts are not checked (Mesen2 only
            // calls CheckForInterrupts when leaving the halted state).
            if (self.cpu.waiting) {
                self.bus.syncInterruptFlagsTo(instruction_end);
                if (self.bus.nmiEdgeInRange(instruction_start, instruction_end)) self.cpu.latchNmi();
                return;
            }
            const sample_master = self.ordered_last_cpu_cycle_start;
            // Mesen2 SnesCpu::DetectNmiSignalEdge: when the final cycle's
            // start serviced a DMA/HDMA (IrqLock), interrupt recognition
            // slips by one cycle - NMI is carried to the next instruction
            // and this instruction's IRQ sample reads as inactive.
            const irq_lock = self.ordered_irq_lock;
            if (self.cpu.nmi_latched or self.bus.nmiEdgeInRange(instruction_start, sample_master)) {
                if (irq_lock) self.cpu.latchNmi() else self.cpu.triggerNmi();
            }
            const irq_at_sample = self.bus.irqLineAt(sample_master);
            if (irq_at_sample) {
                self.cpu.wakeFromIrqLine();
                if (!self.cpu.irq_sample_i and !irq_lock) self.cpu.triggerIrq();
            }

            self.bus.syncInterruptFlagsTo(instruction_end);
            if (!irq_at_sample and self.bus.irqLineAt(instruction_end)) {
                self.cpu.wakeFromIrqLine();
            }
            if (self.bus.nmiEdgeInRange(sample_master, instruction_end)) {
                self.cpu.latchNmi();
            }
            return;
        }

        // Run APU (SPC700) to stay synchronized with main CPU. The APU's
        // fixed-point ratio (~20.98 master cycles per SPC700 cycle) expects
        // master-clock units.
        self.bus.runApu(master + dma_extra);

        // Clock the DSP-1 coprocessor. The uPD77C25 executes one
        // instruction per clock of its 7.6MHz crystal (see Bus.tickDsp).
        // Games poll the DSP's RQM bit, so small ratio
        // error is absorbed by the handshake - but Super Mario Kart also
        // does BLIND cycle-counted writes, so the DSP is ticked at SUB-
        // instruction granularity: CPU access helpers bring it up to "now"
        // before every bus access (flushing internal_flushed cycles), and
        // only the instruction's trailing internal cycles remain here.
        self.bus.tickDsp((internal -| self.cpu.internal_flushed) * 6);

        // Absolute hardware time is the origin for placing interrupt edges
        // within this instruction.
        // Advance the PPU by the instruction's true master-cycle cost (one
        // PPU dot is 4 master clocks, one scanline 1364), plus any DMA time
        // the instruction triggered. Using the real per-access memory
        // speeds here is what fixes the CPU-vs-frame pacing: at flat 6 the
        // CPU got ~30% more instructions per frame than hardware in
        // SlowROM code.
        // The 65816 samples NMI/IRQ immediately before the instruction's last
        // CPU cycle. Split the independent-clock advance there: an NMI edge
        // in the earlier span is eligible at the next boundary, while one in
        // the final 6/8/12-clock cycle is latched until one more instruction
        // reaches its sample point.
        const elapsed = master + dma_extra;
        const final_cycle = @min(self.cpu.finalCycleMasters(), elapsed);
        self.advancePpuWithHdma(elapsed - final_cycle);
        const sample_master = absolutePpuMaster(&self.ppu);
        self.bus.syncInterruptFlagsTo(sample_master);

        if (self.cpu.nmi_latched or self.bus.nmiEdgeInRange(instruction_start, sample_master)) {
            self.cpu.triggerNmi();
        }
        const irq_at_sample = self.bus.irqLineAt(sample_master);
        if (irq_at_sample) {
            self.cpu.wakeFromIrqLine();
            if (!self.cpu.irq_sample_i) self.cpu.triggerIrq();
        }

        self.advancePpuWithHdma(final_cycle);
        const instruction_end = absolutePpuMaster(&self.ppu);
        self.bus.syncInterruptFlagsTo(instruction_end);
        // An IRQ edge in the final CPU cycle misses this instruction's
        // acceptance sample, but its level still terminates WAI immediately.
        if (!irq_at_sample and self.bus.irqLineAt(instruction_end)) {
            self.cpu.wakeFromIrqLine();
        }
        if (self.bus.nmiEdgeInRange(sample_master, instruction_end)) {
            self.cpu.latchNmi();
        }
    }

    const HdmaEventKind = enum { init, transfer };
    // Ordered-path HDMA schedule constants (Mesen2 SnesMemoryManager).
    const hdma_start_hclock: u64 = 276 * 4;
    const hdma_visible_lines: u16 = 225; // Mesen GetVblankStart without overscan

    const OrderedClockSink = struct {
        emu: *Emulator,
        pending_hdma: ?HdmaEventKind = null,

        pub fn mastersUntilLineBoundary(self: *const OrderedClockSink) u64 {
            const in_line = @as(u64, self.emu.ppu.dot) * master_cycles_per_dot +
                self.emu.ppu.master_accum;
            return masters_per_line - in_line;
        }

        /// Mesen2 3b058f9 SnesMemoryManager event schedule, per scanline:
        ///   - line 0: HdmaInit at H-clock 12 + (line start & 7);
        ///   - visible lines (V < 225): HdmaStart at H-clock 1104 (276*4).
        /// Both only RAISE requests (Dma.beginHdmaInit/beginHdmaTransfer);
        /// the transfers run at later CPU cycle boundaries like general DMA.
        /// Events are found within the current line only - the timeline
        /// splits at every real line boundary and asks again - so a short or
        /// long line cannot misplace them.
        pub fn mastersUntilExternalEvent(self: *OrderedClockSink) ?u64 {
            const ppu = &self.emu.ppu;
            const in_line: u64 = @as(u64, ppu.dot) * master_cycles_per_dot + ppu.master_accum;
            const line_start = self.emu.refresh_timeline.wall_master - in_line;
            var best: ?u64 = null;
            if (ppu.scanline == 0) {
                const init_at: u64 = 12 + (line_start & 7);
                if (in_line < init_at) {
                    best = init_at - in_line;
                    self.pending_hdma = .init;
                }
            }
            if (ppu.scanline < hdma_visible_lines and in_line < hdma_start_hclock) {
                const delta = hdma_start_hclock - in_line;
                if (best == null or delta < best.?) {
                    best = delta;
                    self.pending_hdma = .transfer;
                }
            }
            return best;
        }

        pub fn dispatchExternalEvent(self: *OrderedClockSink) void {
            const kind = self.pending_hdma.?;
            self.pending_hdma = null;
            switch (kind) {
                .init => self.emu.bus.dma.beginHdmaInit(),
                .transfer => self.emu.bus.dma.beginHdmaTransfer(),
            }
        }

        pub fn advanceHardware(
            self: *OrderedClockSink,
            masters: u32,
            kind: refresh_timing.SegmentKind,
        ) void {
            _ = kind;
            self.emu.ppu.tick(masters);
            self.emu.bus.runApu(masters);
            self.emu.bus.tickDsp(masters);
            self.emu.bus.syncInterruptFlagsTo(absolutePpuMaster(&self.emu.ppu));
        }
    };

    fn advanceOrderedClock(
        context: *anyopaque,
        masters: u32,
        phase: refresh_timing.CpuPhase,
    ) void {
        const self: *Emulator = @ptrCast(@alignCast(context));
        switch (phase) {
            // The trailing clocks of a read belong to a cycle already begun.
            .read_trailing => {},
            else => {
                // A new CPU cycle begins. Mesen2 SnesCpu::ProcessCpuCycle
                // services pending DMA/HDMA HERE, before the cycle's own
                // clocks; the halt is measured against this cycle's length.
                if (self.bus.dma.hasPendingTransfer()) {
                    const speed: u32 = switch (phase) {
                        .read_leading => masters + 4,
                        .write => masters,
                        else => 6,
                    };
                    var clock = OrderedDmaClock{ .emu = self };
                    self.ordered_irq_lock = self.bus.dma.processPendingTransfers(&self.bus, &clock, speed);
                } else {
                    self.ordered_irq_lock = false;
                }
                // The cycle starts after any transfer it waited for.
                self.ordered_last_cpu_cycle_start = self.refresh_timeline.wall_master;
                // WAI wake detection happens at every cycle start (Mesen2
                // DetectNmiSignalEdge): the IRQ input ends WAI even with I
                // set; an NMI edge does too.
                if (self.cpu.waiting) {
                    const now = self.refresh_timeline.wall_master;
                    if (self.bus.irqLineAt(now) or self.cpu.nmi_latched or
                        self.bus.nmiEdgeInRange(self.ordered_instruction_start, now))
                    {
                        self.cpu.wai_over = true;
                    }
                }
            },
        }
        var sink = OrderedClockSink{ .emu = self };
        self.refresh_timeline.advanceWorkOrdered(masters, &sink);
    }

    /// Evaluated at the start of an implied IdleOrRead cycle (before any
    /// pending DMA is serviced for it), mirroring Mesen2 SnesCpu::IdleOrRead:
    /// an IRQ is imminent if the CPU input is asserted now or was at the
    /// previous cycle's start (PrevIrqSource) with I clear; an NMI if its
    /// edge has arrived since the instruction began or is already latched.
    fn orderedInterruptImminent(context: *anyopaque, i_flag: bool) bool {
        const self: *Emulator = @ptrCast(@alignCast(context));
        const now = self.refresh_timeline.wall_master;
        if (self.cpu.nmi_latched or self.bus.nmiEdgeInRange(self.ordered_instruction_start, now)) return true;
        if (i_flag) return false;
        return self.bus.irqLineAt(now) or
            (!self.ordered_irq_lock and self.bus.irqLineAt(self.ordered_last_cpu_cycle_start));
    }

    /// The ordered wall as seen by the DMA controller: its current master
    /// (for the reset-relative 8-master alignment) and DMA-owned advance.
    const OrderedDmaClock = struct {
        emu: *Emulator,
        pub fn now(self: *const OrderedDmaClock) u64 {
            return self.emu.refresh_timeline.wall_master;
        }
        pub fn advance(self: *OrderedDmaClock, masters: u32) void {
            if (masters == 0) return;
            self.emu.bus.tickDmaMasters(masters);
        }
    };

    fn advanceOrderedDmaClock(context: *anyopaque, masters: u32) void {
        const self: *Emulator = @ptrCast(@alignCast(context));
        var sink = OrderedClockSink{ .emu = self };
        self.refresh_timeline.advanceDmaWorkOrdered(masters, &sink);
    }

    /// Connect actual CPU and DMA execution to the ordered wall owner for the
    /// bounded fixtures. Production remains aggregate until state replay and
    /// broader oracle checks complete the migration.
    fn enableOrderedClockFixture(self: *Emulator) void {
        const wall = absolutePpuMaster(&self.ppu);
        const in_line = @as(u64, self.ppu.dot) * master_cycles_per_dot + self.ppu.master_accum;
        const line_start = wall - in_line;
        const refresh = refresh_timing.refreshMasterForLineStart(line_start);
        const next_refresh = if (refresh >= wall) refresh else refresh_timing.no_refresh_scheduled;
        self.refresh_timeline = RefreshTimeline.restore(wall, next_refresh) catch unreachable;
        self.bus.connectOrderedClock(self, advanceOrderedClock, advanceOrderedDmaClock);
        self.bus.ordered_interrupt_imminent = orderedInterruptImminent;
        // The ordered profile models the real NTSC field geometry: scanline
        // 240 of every odd non-interlace field is 1360 masters.
        self.ppu.enableShortLines();
    }

    /// Master clocks the S-CPU spends leaving reset before its first opcode
    /// fetch while the PPU, APU and refresh schedule already run. Mesen2
    /// 3b058f9 SnesConsole::Reset calls IncMasterClockStartup (186 masters)
    /// and then fetches the first opcode directly from the reset vector (the
    /// vector itself is peeked, not a timed bus read). The value fixes the
    /// CPU's phase against the reset-aligned 8-master DMA cadence and the
    /// refresh/line schedule, so every absolute timestamp depends on it.
    pub const power_on_startup_masters: u64 = 186;

    /// Connect the ordered wall owner to a machine that has just been reset
    /// (wall 0, beam at V=0 H=0) and run the power-on startup interval
    /// through it, so the first instruction starts at the hardware phase.
    /// Used by the timing-trace tool; the default runtime stays aggregate.
    pub fn enableOrderedClockFromPowerOn(self: *Emulator) void {
        std.debug.assert(absolutePpuMaster(&self.ppu) == 0);
        self.enableOrderedClockFixture();
        var sink = OrderedClockSink{ .emu = self };
        self.refresh_timeline.advanceWorkOrdered(power_on_startup_masters, &sink);
        self.ordered_last_cpu_cycle_start = self.refresh_timeline.wall_master;
    }

    const HdmaEvent = struct {
        kind: HdmaEventKind,
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

            // HDMA byte time is produced synchronously by tickDmaHalfByte(). It
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
        return savestate.write(
            &self.cpu,
            &self.ppu,
            &self.bus,
            &self.refresh_timeline,
            self.last_scanline,
            dst,
        );
    }

    /// Restore a snapshot previously produced by writeState.
    pub fn readState(self: *Emulator, src: []const u8) StateError!usize {
        const read = try savestate.read(
            &self.cpu,
            &self.ppu,
            &self.bus,
            &self.refresh_timeline,
            &self.last_scanline,
            src,
        );
        self.ordered_last_cpu_cycle_start = self.refresh_timeline.wall_master;
        return read;
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
    // H=6 plus 18 global and 8 direct-channel initialization clocks.
    try std.testing.expectEqual(@as(u16, 12), emu.ppu.dot);
    try std.testing.expectEqual(@as(u32, 2), emu.ppu.master_accum);
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
    // 18 global + 8 channel + 8 byte clocks put the end-of-byte register
    // write at H=286 with two master clocks left within that dot.
    try std.testing.expectEqual(@as(u16, hdma_transfer_dot + 8), emu.ppu.render_events[0].dot);
    try std.testing.expectEqual(@as(u16, hdma_transfer_dot + 8), emu.ppu.dot);
    try std.testing.expectEqual(@as(u32, 2), emu.ppu.master_accum);
    try std.testing.expectEqual(@as(u32, 0), emu.bus.dma_masters);
}

test "active HDMA channel bills overhead on a no-transfer line" {
    var emu = Emulator.init();
    emu.setup();
    emu.ppu.tick(277 * master_cycles_per_dot);

    emu.bus.hdmaen = 0x01;
    emu.bus.dma.hdma_enable = 0x01;
    emu.bus.dma.channels[0].a_addr = 0x7E0000;
    emu.bus.dma.channels[0].line_counter = 2;
    emu.bus.dma.channels[0].hdma_do_transfer = false;

    emu.advancePpuWithHdma(master_cycles_per_dot);
    // 18 global + 8 channel clocks, despite writing no PPU byte.
    try std.testing.expectEqual(@as(u16, hdma_transfer_dot + 6), emu.ppu.dot);
    try std.testing.expectEqual(@as(u32, 2), emu.ppu.master_accum);
    try std.testing.expectEqual(@as(u8, 1), emu.bus.dma.channels[0].line_counter);
    try std.testing.expectEqual(@as(usize, 0), emu.ppu.render_event_count);
}

test "HDMA indirect descriptor reload bills its extra 16 clocks" {
    var emu = Emulator.init();
    emu.setup();
    emu.ppu.tick(277 * master_cycles_per_dot);

    emu.bus.hdmaen = 0x01;
    emu.bus.dma.hdma_enable = 0x01;
    emu.bus.dma.channels[0].control.indirect = true;
    emu.bus.dma.channels[0].a_addr = 0x7E0000;
    emu.bus.dma.channels[0].hdma_addr = 0;
    emu.bus.dma.channels[0].line_counter = 1;
    emu.bus.dma.channels[0].hdma_do_transfer = false;
    emu.bus.wram[0] = 0x82;
    emu.bus.wram[1] = 0x34;
    emu.bus.wram[2] = 0x12;

    emu.advancePpuWithHdma(master_cycles_per_dot);
    // 18 global + 8 channel + 16 indirect-pointer clocks.
    try std.testing.expectEqual(@as(u16, hdma_transfer_dot + 10), emu.ppu.dot);
    try std.testing.expectEqual(@as(u32, 2), emu.ppu.master_accum);
    try std.testing.expectEqual(@as(u8, 0x82), emu.bus.dma.channels[0].line_counter);
    try std.testing.expectEqual(@as(u16, 0x1234), emu.bus.dma.channels[0].byte_count);
    try std.testing.expectEqual(@as(u16, 3), emu.bus.dma.channels[0].hdma_addr);
    try std.testing.expect(emu.bus.dma.channels[0].hdma_do_transfer);
}

test "RDNMI sets at V=225 H=0.5 and exact-edge reads cannot clear it for four clocks" {
    var emu = Emulator.init();
    emu.setup();
    emu.ppu.scanline = 224;
    emu.ppu.dot = 340;
    emu.bus.beginCpuInstruction();

    // Four clocks reach V=225/H=0; the latch does not set until two more.
    emu.bus.setCpuAccessTiming(5);
    try std.testing.expectEqual(@as(u8, 0x02), emu.bus.read(0, 0x4210));
    try std.testing.expect(!emu.bus.nmi_flag);

    // At H=0.5 the read sees bit 7, but the timer holds the latch set through
    // H=1.5 so an exact-edge acknowledge cannot erase the just-arrived flag.
    emu.bus.setCpuAccessTiming(6);
    try std.testing.expectEqual(@as(u8, 0x82), emu.bus.read(0, 0x4210));
    try std.testing.expect(emu.bus.nmi_flag);
    emu.bus.setCpuAccessTiming(9);
    try std.testing.expectEqual(@as(u8, 0x82), emu.bus.read(0, 0x4210));
    try std.testing.expect(emu.bus.nmi_flag);

    emu.bus.setCpuAccessTiming(10);
    try std.testing.expectEqual(@as(u8, 0x82), emu.bus.read(0, 0x4210));
    try std.testing.expect(!emu.bus.nmi_flag);
}

test "NMI service jitters by one instruction around the pre-final-cycle sample" {
    // A low-WRAM LDA #imm has two 8-clock fetch cycles. The interrupt sample
    // is therefore 8 clocks after the instruction begins, immediately before
    // its final operand-fetch cycle.
    var early = Emulator.init();
    early.setup();
    early.cpu.pc = 0;
    early.bus.wram[0] = 0xA9;
    early.bus.wram[1] = 0;
    early.bus.nmitimen = 0x80;
    early.ppu.scanline = 224;
    early.ppu.dot = 340; // NMI edge is 6 clocks away: before the sample.
    early.step();
    try std.testing.expectEqual(@as(u16, 2), early.cpu.pc);
    try std.testing.expect(early.cpu.nmi_pending);
    try std.testing.expect(!early.cpu.nmi_latched);
    early.step();
    try std.testing.expectEqual(@as(u16, 0x01FC), early.cpu.sp);

    var late = Emulator.init();
    late.setup();
    late.cpu.pc = 0;
    late.bus.wram[0] = 0xA9;
    late.bus.wram[1] = 0;
    late.bus.wram[2] = 0xA9;
    late.bus.wram[3] = 0;
    late.bus.nmitimen = 0x80;
    late.ppu.scanline = 224;
    late.ppu.dot = 339; // NMI edge is 10 clocks away: in the final cycle.
    late.step();
    try std.testing.expectEqual(@as(u16, 2), late.cpu.pc);
    try std.testing.expect(!late.cpu.nmi_pending);
    try std.testing.expect(late.cpu.nmi_latched);
    late.step();
    try std.testing.expectEqual(@as(u16, 4), late.cpu.pc);
    try std.testing.expect(late.cpu.nmi_pending);
    try std.testing.expect(!late.cpu.nmi_latched);
    late.step();
    try std.testing.expectEqual(@as(u16, 0x01FC), late.cpu.sp);
}

test "H and V timer flags include the measured compare-to-output delay" {
    var hirq = Emulator.init();
    hirq.setup();
    hirq.ppu.scanline = 10;
    hirq.ppu.dot = 102;
    hirq.bus.nmitimen = 0x10;
    hirq.bus.htime = 100;
    hirq.bus.beginCpuInstruction();

    // HTIME=100 compares at H=100; the timer output is 14+100*4 clocks
    // from line start, H=103.5. Starting at H=102 puts that edge 6 clocks
    // away, not at the already-passed programmed dot.
    hirq.bus.setCpuAccessTiming(5);
    try std.testing.expect(!hirq.bus.irq_flag);
    hirq.bus.setCpuAccessTiming(6);
    try std.testing.expect(hirq.bus.irq_flag);

    // TIMEUP is forced set for four clocks around its edge, mirroring the
    // RDNMI read-clear race.
    try std.testing.expectEqual(@as(u8, 0x80), hirq.bus.read(0, 0x4211));
    try std.testing.expect(hirq.bus.irq_flag);
    hirq.bus.setCpuAccessTiming(9);
    try std.testing.expectEqual(@as(u8, 0x80), hirq.bus.read(0, 0x4211));
    try std.testing.expect(hirq.bus.irq_flag);
    hirq.bus.setCpuAccessTiming(10);
    try std.testing.expectEqual(@as(u8, 0x80), hirq.bus.read(0, 0x4211));
    try std.testing.expect(!hirq.bus.irq_flag);

    var virq = Emulator.init();
    virq.setup();
    virq.ppu.scanline = 9;
    virq.ppu.dot = 340;
    virq.bus.nmitimen = 0x20;
    virq.bus.vtime = 10;
    virq.bus.beginCpuInstruction();
    // Four clocks finish V=9, then the V-only output appears at V=10/H=2.5.
    virq.bus.setCpuAccessTiming(13);
    try std.testing.expect(!virq.bus.irq_flag);
    virq.bus.setCpuAccessTiming(14);
    try std.testing.expect(virq.bus.irq_flag);
}

test "IRQ service has boundary jitter and samples I before final-cycle flag updates" {
    var early = Emulator.init();
    early.setup();
    early.cpu.pc = 0;
    early.cpu.p.i = false;
    early.bus.wram[0] = 0xA9;
    early.bus.wram[1] = 0;
    early.bus.nmitimen = 0x10;
    early.bus.htime = 100;
    early.ppu.scanline = 10;
    early.ppu.dot = 102; // IRQ output 6 clocks away, before sample at 8.
    early.step();
    try std.testing.expect(early.cpu.irq_pending);
    early.step();
    try std.testing.expectEqual(@as(u16, 0x01FC), early.cpu.sp);

    var late = Emulator.init();
    late.setup();
    late.cpu.pc = 0;
    late.cpu.p.i = false;
    late.bus.wram[0] = 0xA9;
    late.bus.wram[1] = 0;
    late.bus.wram[2] = 0xA9;
    late.bus.wram[3] = 0;
    late.bus.nmitimen = 0x10;
    late.bus.htime = 100;
    late.ppu.scanline = 10;
    late.ppu.dot = 101; // IRQ output 10 clocks away, in the final cycle.
    late.step();
    try std.testing.expect(!late.cpu.irq_pending);
    late.step();
    try std.testing.expectEqual(@as(u16, 4), late.cpu.pc);
    try std.testing.expect(late.cpu.irq_pending);
    late.step();
    try std.testing.expectEqual(@as(u16, 0x01FC), late.cpu.sp);

    var flags = Emulator.init();
    flags.setup();
    flags.cpu.pc = 0;
    flags.cpu.p.i = true;
    flags.bus.wram[0] = 0x58; // CLI: sample sees old I=1, so no IRQ yet.
    flags.bus.wram[1] = 0x78; // SEI: sample sees old I=0, so IRQ is accepted.
    flags.bus.irq_flag = true;
    flags.step();
    try std.testing.expect(!flags.cpu.irq_pending);
    try std.testing.expect(!flags.cpu.p.i);
    flags.step();
    try std.testing.expect(flags.cpu.irq_pending);
    try std.testing.expect(flags.cpu.p.i);
    flags.step();
    try std.testing.expectEqual(@as(u16, 0x01FC), flags.cpu.sp);
}

test "masked IRQ wakes WAI and pays the 12-master-clock resume delay" {
    var emu = Emulator.init();
    emu.setup();
    emu.cpu.pc = 0;
    emu.cpu.p.i = true;
    emu.cpu.waiting = true;
    emu.bus.wram[0] = 0xEA;
    emu.bus.irq_flag = true;

    emu.step();
    try std.testing.expect(!emu.cpu.waiting);
    try std.testing.expectEqual(@as(u8, 2), emu.cpu.wai_resume_cycles);
    try std.testing.expect(!emu.cpu.irq_pending);
    try std.testing.expectEqual(@as(u16, 0), emu.cpu.pc);

    emu.step();
    try std.testing.expectEqual(@as(u8, 0), emu.cpu.wai_resume_cycles);
    try std.testing.expectEqual(@as(u16, 0), emu.cpu.pc);
    try std.testing.expect(!emu.cpu.irq_pending);

    emu.step();
    try std.testing.expectEqual(@as(u16, 1), emu.cpu.pc);
}

test "$4200 enable during VBlank creates an immediate NMI edge only while RDNMI is set" {
    var edges = Emulator.init();
    edges.setup();
    edges.ppu.scanline = 225;
    edges.ppu.dot = 100;
    edges.bus.nmi_flag = true;
    edges.bus.nmitimen = 0x80;
    edges.bus.beginCpuInstruction();
    const start = absolutePpuMaster(&edges.ppu);

    edges.bus.setCpuAccessTiming(6);
    edges.bus.write(0, 0x4200, 0x80); // Already enabled: no new edge.
    try std.testing.expect(!edges.bus.nmiEdgeInRange(start, start + 6));
    edges.bus.setCpuAccessTiming(12);
    edges.bus.write(0, 0x4200, 0x00); // Disable does not acknowledge RDNMI.
    try std.testing.expect(edges.bus.nmi_flag);
    edges.bus.setCpuAccessTiming(18);
    edges.bus.write(0, 0x4200, 0x80); // 0->1 while RDNMI=1: immediate edge.
    try std.testing.expect(edges.bus.nmiEdgeInRange(start + 12, start + 18));

    var acknowledged = Emulator.init();
    acknowledged.setup();
    acknowledged.ppu.scanline = 225;
    acknowledged.ppu.dot = 100;
    acknowledged.bus.nmi_flag = true;
    acknowledged.bus.nmitimen = 0x80;
    acknowledged.bus.beginCpuInstruction();
    const acknowledged_start = absolutePpuMaster(&acknowledged.ppu);
    acknowledged.bus.setCpuAccessTiming(6);
    acknowledged.bus.write(0, 0x4200, 0x00);
    acknowledged.bus.setCpuAccessTiming(12);
    try std.testing.expectEqual(@as(u8, 0x82), acknowledged.bus.read(0, 0x4210));
    try std.testing.expect(!acknowledged.bus.nmi_flag);
    acknowledged.bus.setCpuAccessTiming(18);
    acknowledged.bus.write(0, 0x4200, 0x80);
    try std.testing.expect(!acknowledged.bus.nmiEdgeInRange(acknowledged_start, acknowledged_start + 18));
}

test "$4200 immediate NMI still waits for the next instruction sample" {
    var emu = Emulator.init();
    emu.setup();
    emu.ppu.scanline = 225;
    emu.ppu.dot = 100;
    emu.bus.nmi_flag = true;
    emu.bus.nmitimen = 0;
    emu.cpu.pc = 0;
    emu.cpu.a = 0x80;
    emu.bus.wram[0] = 0x8D; // STA $4200: write is its final 6-clock cycle.
    emu.bus.wram[1] = 0x00;
    emu.bus.wram[2] = 0x42;
    emu.bus.wram[3] = 0xA9; // The late edge lets this LDA #imm execute.
    emu.bus.wram[4] = 0;

    emu.step();
    try std.testing.expectEqual(@as(u8, 0x80), emu.bus.nmitimen);
    try std.testing.expectEqual(@as(u16, 3), emu.cpu.pc);
    try std.testing.expect(!emu.cpu.nmi_pending);
    try std.testing.expect(emu.cpu.nmi_latched);

    emu.step();
    try std.testing.expectEqual(@as(u16, 5), emu.cpu.pc);
    try std.testing.expect(emu.cpu.nmi_pending);
    emu.step();
    try std.testing.expectEqual(@as(u16, 0x01FC), emu.cpu.sp);
}

test "actual CPU SlowROM accesses cross refresh on the ordered wall owner" {
    const allocator = std.testing.allocator;
    const flat = try allocator.alloc(u8, 0x10000);
    defer allocator.free(flat);
    @memset(flat, 0);

    var emu = Emulator.init();
    emu.setup();
    emu.bus.flat_mem = flat;
    emu.cpu.pbr = 0;
    emu.cpu.pc = 0x8000;
    flat[0x8000] = 0xA9; // LDA #$11
    flat[0x8001] = 0x11;
    flat[0x8002] = 0xA9; // LDA #$22
    flat[0x8003] = 0x22;
    flat[0x8004] = 0xA9; // LDA #$33
    flat[0x8005] = 0x33;

    emu.ppu.dot = 125; // absolute master 500
    emu.enableOrderedClockFixture();
    emu.step();
    emu.step();
    emu.step();

    // Six real CPU accesses consume 48 work masters. The refresh at 538 is
    // emitted once to the same PPU/APU/DSP sink, producing 88 wall masters.
    try std.testing.expectEqual(@as(u64, 588), emu.refresh_timeline.wall_master);
    try std.testing.expectEqual(@as(u64, 588), absolutePpuMaster(&emu.ppu));
    try std.testing.expectEqual(@as(u16, 0x8006), emu.cpu.pc);
    try std.testing.expectEqual(@as(u16, 0x33), emu.cpu.a);
    try std.testing.expectEqual(@as(u32, 0), emu.bus.dma_masters);
}

test "actual CPU mapped read runs after its leading access clocks" {
    var emu = Emulator.init();
    emu.setup();
    emu.cpu.pc = 0;
    emu.bus.wram[0] = 0x2C; // BIT $4212
    emu.bus.wram[1] = 0x12;
    emu.bus.wram[2] = 0x42;

    // Three eight-master fetches followed by two leading I/O masters put the
    // handler at H=274 residual 2. Instruction start is still active display.
    emu.ppu.dot = 268;
    emu.enableOrderedClockFixture();
    emu.step();

    try std.testing.expect(emu.cpu.p.v);
    try std.testing.expectEqual(@as(u64, 1102), emu.refresh_timeline.wall_master);
    try std.testing.expectEqual(@as(u64, 1102), absolutePpuMaster(&emu.ppu));
}

test "actual CPU mapped write takes effect after its complete access" {
    var emu = Emulator.init();
    emu.setup();
    emu.cpu.pc = 0;
    emu.cpu.a = 0x0F;
    emu.bus.wram[0] = 0x8D; // STA $2100
    emu.bus.wram[1] = 0x00;
    emu.bus.wram[2] = 0x21;

    // The three Slow/WRAM fetch accesses end at 536. The six-master write
    // reaches refresh at 538, so its effect is journaled at wall master 582.
    emu.ppu.dot = 128;
    emu.enableOrderedClockFixture();
    emu.step();

    try std.testing.expectEqual(@as(u8, 0x0F), emu.ppu.inidisp);
    try std.testing.expectEqual(@as(usize, 1), emu.ppu.render_event_count);
    try std.testing.expectEqual(@as(u16, 145), emu.ppu.render_events[0].dot);
    try std.testing.expectEqual(@as(u64, 582), emu.refresh_timeline.wall_master);
}

/// Records DMA/HDMA byte instants through the capture-only timing probe.
const DmaInstants = struct {
    emu: *Emulator,
    reads: [8]u64 = undefined,
    writes: [8]u64 = undefined,
    read_count: usize = 0,
    write_count: usize = 0,

    fn record(context: *anyopaque, kind: bus_module.TimingProbeKind, addr: u24, value: u8) void {
        _ = addr;
        _ = value;
        const self: *DmaInstants = @ptrCast(@alignCast(context));
        const now = self.emu.refresh_timeline.wall_master;
        switch (kind) {
            .dma_read => {
                self.reads[self.read_count] = now;
                self.read_count += 1;
            },
            .dma_write => {
                self.writes[self.write_count] = now;
                self.write_count += 1;
            },
            else => {},
        }
    }

    fn install(self: *DmaInstants) void {
        self.emu.bus.timing_probe = .{ .context = self, .record = DmaInstants.record };
    }
};

/// One-byte channel-0 DMA from WRAM $00:0100 to $2100, triggered by the
/// STA $420B at WRAM $0000 (the next instruction is BRK, WRAM being zero).
fn setupOneByteDma(emu: *Emulator, source: u16) void {
    emu.setup();
    emu.cpu.pc = 0;
    emu.cpu.a = 0x01;
    emu.bus.wram[0] = 0x8D; // STA $420B
    emu.bus.wram[1] = 0x0B;
    emu.bus.wram[2] = 0x42;
    emu.bus.wram[0x0100] = 0x0F;
    emu.bus.dma.writeRegister(0x4300, 0x00); // A -> B, mode 0
    emu.bus.dma.writeRegister(0x4301, 0x00); // $2100 INIDISP
    emu.bus.dma.writeRegister(0x4302, @truncate(source));
    emu.bus.dma.writeRegister(0x4303, @truncate(source >> 8));
    emu.bus.dma.writeRegister(0x4304, 0x00);
    emu.bus.dma.writeRegister(0x4305, 0x01);
    emu.bus.dma.writeRegister(0x4306, 0x00);
}

test "general DMA halts at the second CPU cycle boundary and crosses refresh" {
    var emu = Emulator.init();
    setupOneByteDma(&emu, 0x0100);
    var instants = DmaInstants{ .emu = &emu };
    instants.install();

    // STA $420B: three WRAM fetches (8 each) + the six-master $420B write,
    // starting at wall 482 -> the write takes effect at 512. That only
    // RECORDS the request (Mesen2 SnesDmaController::Write).
    emu.ppu.dot = 120;
    emu.ppu.master_accum = 2;
    emu.enableOrderedClockFixture();
    emu.step();
    try std.testing.expectEqual(@as(u64, 512), emu.refresh_timeline.wall_master);
    try std.testing.expectEqual(@as(usize, 0), instants.read_count);

    // Boundary 1 (BRK opcode fetch, 512): start delay consumed; fetch to 520.
    // Boundary 2 (signature fetch, 520): the halt. 520 is a multiple of 8,
    // so SyncStartDma waits a full 8 (528); global overhead 8 (536); the
    // channel's 8 masters reach refresh at 538 and stall 40 (584); byte:
    // 4 masters -> source handler at 588, 4 more -> $2100 written at 592.
    emu.step();
    try std.testing.expectEqual(@as(usize, 1), instants.read_count);
    try std.testing.expectEqual(@as(u64, 588), instants.reads[0]);
    try std.testing.expectEqual(@as(u64, 592), instants.writes[0]);
    try std.testing.expectEqual(@as(u8, 0x0F), emu.ppu.inidisp);
    try std.testing.expectEqual(@as(u16, 148), emu.ppu.render_events[0].dot);
    try std.testing.expectEqual(@as(u32, 0), emu.bus.dma_masters);
}

test "DMA byte halves put the source handler four masters before the destination" {
    var emu = Emulator.init();
    setupOneByteDma(&emu, 0x4212); // source $00:4212 HVBJOY
    var instants = DmaInstants{ .emu = &emu };
    instants.install();

    // STA $420B from wall 1032 takes effect at 1062. Boundary 1 (1062)
    // consumes the start delay; the BRK fetch ends at 1070. Boundary 2:
    // 1070 & 7 = 6, so SyncStartDma waits 2 (1072); global 8 (1080);
    // channel 8 (1088); 4 masters -> the $4212 handler runs at 1092
    // (H=273, active display: bit 6 clear); 4 more -> the write at 1096.
    // Because the controller is aligned to the reset-relative 8-master
    // cadence, a source handler always lands at 4 mod 8 after reset.
    emu.ppu.dot = 258;
    emu.enableOrderedClockFixture();
    emu.step();
    emu.step();
    try std.testing.expectEqual(@as(u64, 1092), instants.reads[0]);
    try std.testing.expectEqual(@as(u64, 1096), instants.writes[0]);
    try std.testing.expectEqual(@as(u8, 0), emu.ppu.inidisp & 0x40);
}

test "HDMA request at H=1104 runs at the second CPU cycle boundary" {
    var emu = Emulator.init();
    emu.setup();
    emu.cpu.pc = 0;
    emu.bus.wram[0] = 0xA9; // LDA #$00, then BRK (WRAM is zero)
    emu.bus.wram[1] = 0x00;
    emu.bus.wram[0x0100] = 0x07;
    emu.bus.write(0, 0x420C, 0x01);
    emu.bus.dma.writeRegister(0x4300, 0x00); // direct A -> B, mode 0
    emu.bus.dma.writeRegister(0x4301, 0x00); // $2100 INIDISP
    emu.bus.dma.writeRegister(0x4308, 0x00); // table at $00:0100
    emu.bus.dma.writeRegister(0x4309, 0x01);
    emu.bus.dma.writeRegister(0x430A, 0x82); // transfer, then one repeat line
    emu.bus.dma.channels[0].hdma_do_transfer = true;
    var instants = DmaInstants{ .emu = &emu };
    instants.install();

    // Line 1 (starting at wall 1364), local H-clock 1100. LDA's opcode
    // fetch (1100-1108) passes H-clock 1104, where the schedule RAISES the
    // HDMA request with its start delay (Mesen2 BeginHdmaTransfer). The
    // operand fetch's cycle boundary (1108) consumes the delay, so nothing
    // has transferred when LDA ends at 1116.
    emu.ppu.scanline = 1;
    emu.ppu.dot = 275;
    emu.enableOrderedClockFixture();
    emu.step();
    try std.testing.expectEqual(@as(u64, 1364 + 1116), emu.refresh_timeline.wall_master);
    try std.testing.expectEqual(@as(usize, 0), instants.read_count);

    // BRK's opcode-fetch boundary (1116) runs HDMA: wall 2480 is a multiple
    // of 8, so SyncStartDma waits 8 (1124); overhead 8 (1132); the byte
    // reads $00:0100 at 1136 and writes $2100 at 1140; the table advance
    // fetches the next byte (handler 4 masters in, at 1144; done at 1148);
    // SyncEndDma completes the
    // 8-master CPU cycle (32 % 8 = 0 -> a full 8, 1156).
    emu.step();
    try std.testing.expectEqual(@as(u64, 1364 + 1136), instants.reads[0]);
    try std.testing.expectEqual(@as(u64, 1364 + 1140), instants.writes[0]);
    try std.testing.expectEqual(@as(u64, 1364 + 1144), instants.reads[1]);
    try std.testing.expectEqual(@as(u8, 0x07), emu.ppu.inidisp);
    try std.testing.expectEqual(@as(u16, 285), emu.ppu.render_events[0].dot);
    try std.testing.expectEqual(@as(u8, 0x81), emu.bus.dma.channels[0].line_counter);
    try std.testing.expectEqual(@as(u32, 0), emu.bus.dma_masters);
}

test "audited implied phases advance before effects on the ordered owner" {
    const allocator = std.testing.allocator;
    const flat = try allocator.alloc(u8, 0x10000);
    defer allocator.free(flat);
    @memset(flat, 0);

    var clc = Emulator.init();
    clc.setup();
    clc.bus.flat_mem = flat;
    clc.cpu.pbr = 0;
    clc.cpu.pc = 0x8000;
    clc.cpu.p.c = true;
    flat[0x8000] = 0x18; // CLC: opcode access then IdleOrRead before effect
    clc.ppu.dot = 132; // wall 528; opcode ends 536
    clc.enableOrderedClockFixture();
    clc.step();

    // The six-master pre-effect phase crosses refresh at 538. CLC therefore
    // ends at 582 with a two-cycle/one-access shape and a six-master final
    // cycle for the still-canonical aggregate interrupt sampler.
    try std.testing.expect(!clc.cpu.p.c);
    try std.testing.expectEqual(@as(u8, 2), clc.cpu.cycles);
    try std.testing.expectEqual(@as(u8, 1), clc.cpu.mem_accesses);
    try std.testing.expectEqual(@as(u32, 1), clc.cpu.internal_flushed);
    try std.testing.expectEqual(@as(u32, 6), clc.cpu.finalCycleMasters());
    try std.testing.expectEqual(@as(u64, 536), clc.ordered_last_cpu_cycle_start);
    try std.testing.expectEqual(@as(u64, 582), clc.refresh_timeline.wall_master);

    var xba = Emulator.init();
    xba.setup();
    xba.bus.flat_mem = flat;
    xba.cpu.pbr = 0;
    xba.cpu.pc = 0x8001;
    xba.cpu.a = 0x1234;
    flat[0x8001] = 0xEB; // XBA: IdleOrRead plus unconditional idle
    xba.ppu.dot = 125; // wall 500
    xba.enableOrderedClockFixture();
    xba.step();

    try std.testing.expectEqual(@as(u16, 0x3412), xba.cpu.a);
    try std.testing.expectEqual(@as(u8, 3), xba.cpu.cycles);
    try std.testing.expectEqual(@as(u32, 2), xba.cpu.internal_flushed);
    try std.testing.expectEqual(@as(u32, 6), xba.cpu.finalCycleMasters());
    try std.testing.expectEqual(@as(u64, 520), xba.refresh_timeline.wall_master);
}

test "ordered interrupt sampling distinguishes pre-final and final-cycle edges" {
    // Mesen2 timer model (InternalRegisters::ProcessIrqCounters): with
    // htime = 0 the H counter matches at H=6, the $4211 flag rises at 14 and
    // the CPU's IRQ input at 18. The CPU samples at its final cycle's start.
    const Case = struct { code: []const u8, final_cycle_start: u64, taken: bool };
    const cases = [_]Case{
        // LDA #$00: opcode 4-12, operand (final) cycle starts at 12 - the
        // input is still low there, so this instruction does not take it.
        .{ .code = &.{ 0xA9, 0x00 }, .final_cycle_start = 12, .taken = false },
        // LDA $0000: final (data) cycle starts at 28, after the rise at 18.
        .{ .code = &.{ 0xAD, 0x00, 0x00 }, .final_cycle_start = 28, .taken = true },
    };
    for (cases) |case| {
        var irq = Emulator.init();
        irq.setup();
        irq.cpu.pc = 0x100;
        irq.cpu.p.i = false;
        for (case.code, 0..) |b, k| irq.bus.wram[0x100 + k] = b;
        irq.bus.nmitimen = 0x10; // H-IRQ
        irq.bus.htime = 0;
        irq.ppu.dot = 1; // instruction begins at H-clock 4
        irq.enableOrderedClockFixture();
        irq.step();
        try std.testing.expectEqual(case.final_cycle_start, irq.ordered_last_cpu_cycle_start);
        try std.testing.expectEqual(case.taken, irq.bus.irqLineAt(irq.ordered_last_cpu_cycle_start));
        try std.testing.expectEqual(case.taken, irq.cpu.irq_pending);
        // The $4211 flag is already visible 4 masters before the CPU input.
        try std.testing.expect(irq.bus.irq_flag);
    }

    var nmi = Emulator.init();
    nmi.setup();
    nmi.cpu.pc = 0;
    nmi.cpu.a = 0x80;
    nmi.bus.wram[0] = 0x8D; // STA $4200; enable NMI in final access
    nmi.bus.wram[1] = 0x00;
    nmi.bus.wram[2] = 0x42;
    nmi.ppu.scanline = 225;
    nmi.ppu.dot = 100;
    nmi.bus.nmi_flag = true;
    nmi.enableOrderedClockFixture();
    nmi.step();

    // The write's immediate NMI edge is at its end, after the sample at the
    // access start. It is latched rather than accepted by this instruction.
    try std.testing.expect(!nmi.cpu.nmi_pending);
    try std.testing.expect(nmi.cpu.nmi_latched);
    try std.testing.expectEqual(
        @as(u64, 225 * 1364 + 100 * 4 + 24),
        nmi.ordered_last_cpu_cycle_start,
    );
}

test "implied and register opcodes retain their internal final cycle" {
    const TimingCase = struct { opcode: u8, cycles: u8 };
    const cases = [_]TimingCase{
        .{ .opcode = 0x18, .cycles = 2 }, // CLC
        .{ .opcode = 0x38, .cycles = 2 }, // SEC
        .{ .opcode = 0x58, .cycles = 2 }, // CLI
        .{ .opcode = 0x78, .cycles = 2 }, // SEI
        .{ .opcode = 0xB8, .cycles = 2 }, // CLV
        .{ .opcode = 0xD8, .cycles = 2 }, // CLD
        .{ .opcode = 0xF8, .cycles = 2 }, // SED
        .{ .opcode = 0xAA, .cycles = 2 }, // TAX
        .{ .opcode = 0xA8, .cycles = 2 }, // TAY
        .{ .opcode = 0x8A, .cycles = 2 }, // TXA
        .{ .opcode = 0x98, .cycles = 2 }, // TYA
        .{ .opcode = 0xBA, .cycles = 2 }, // TSX
        .{ .opcode = 0x9A, .cycles = 2 }, // TXS
        .{ .opcode = 0x9B, .cycles = 2 }, // TXY
        .{ .opcode = 0xBB, .cycles = 2 }, // TYX
        .{ .opcode = 0x5B, .cycles = 2 }, // TCD
        .{ .opcode = 0x7B, .cycles = 2 }, // TDC
        .{ .opcode = 0x1B, .cycles = 2 }, // TCS
        .{ .opcode = 0x3B, .cycles = 2 }, // TSC
        .{ .opcode = 0xE8, .cycles = 2 }, // INX
        .{ .opcode = 0xCA, .cycles = 2 }, // DEX
        .{ .opcode = 0xC8, .cycles = 2 }, // INY
        .{ .opcode = 0x88, .cycles = 2 }, // DEY
        .{ .opcode = 0x1A, .cycles = 2 }, // INC A
        .{ .opcode = 0x3A, .cycles = 2 }, // DEC A
        .{ .opcode = 0xEB, .cycles = 3 }, // XBA
        .{ .opcode = 0xFB, .cycles = 2 }, // XCE
    };
    const Profile = struct { emulation: bool, m: bool, x: bool, carry: bool };
    const profiles = [_]Profile{
        .{ .emulation = true, .m = true, .x = true, .carry = false },
        .{ .emulation = true, .m = true, .x = true, .carry = true },
        .{ .emulation = false, .m = false, .x = false, .carry = false },
        .{ .emulation = false, .m = false, .x = false, .carry = true },
    };
    const Region = struct { bank: u8, memsel: u8, fetch_masters: u32 };
    const regions = [_]Region{
        .{ .bank = 0x00, .memsel = 0, .fetch_masters = 8 }, // SlowROM
        .{ .bank = 0x80, .memsel = 1, .fetch_masters = 6 }, // FastROM
    };
    var rom = [_]u8{0} ** 0x8000;

    for (cases) |timing| {
        rom[0] = timing.opcode;
        for (profiles) |profile| {
            for (regions) |region| {
                var emu = Emulator.init();
                emu.setup();
                try emu.bus.loadCartridge(&rom);
                emu.bus.memsel = region.memsel;
                emu.cpu.pbr = region.bank;
                emu.cpu.pc = 0x8000;
                emu.cpu.emulation_mode = profile.emulation;
                emu.cpu.p.m = profile.m;
                emu.cpu.p.x = profile.x;
                emu.cpu.p.c = profile.carry;
                emu.cpu.p.i = true;
                emu.cpu.a = 0x12A5;
                emu.cpu.x = 0x34B6;
                emu.cpu.y = 0x56C7;
                emu.cpu.sp = 0x78D8;

                const start = absolutePpuMaster(&emu.ppu);
                emu.step();
                const elapsed = absolutePpuMaster(&emu.ppu) - start;
                const expected_masters = region.fetch_masters +
                    @as(u32, timing.cycles - 1) * 6;

                try std.testing.expectEqual(timing.cycles, emu.cpu.cycles);
                try std.testing.expectEqual(@as(u8, 1), emu.cpu.mem_accesses);
                try std.testing.expectEqual(region.fetch_masters, emu.cpu.mem_masters);
                try std.testing.expectEqual(@as(u32, timing.cycles - 1), emu.cpu.internal_flushed);
                try std.testing.expectEqual(@as(u32, 6), emu.cpu.finalCycleMasters());
                try std.testing.expectEqual(@as(u64, expected_masters), elapsed);
            }
        }
    }
}

test "ordered wall and audio state replay exactly across refresh" {
    const allocator = std.testing.allocator;
    const flat = try allocator.alloc(u8, 0x10000);
    defer allocator.free(flat);
    @memset(flat, 0);
    flat[0x8000] = 0xA9;
    flat[0x8001] = 0x11;
    flat[0x8002] = 0xA9;
    flat[0x8003] = 0x22;
    flat[0x8004] = 0xA9;
    flat[0x8005] = 0x33;

    const checkpoint = try allocator.alloc(u8, Emulator.state_len);
    defer allocator.free(checkpoint);
    const expected = try allocator.alloc(u8, Emulator.state_len);
    defer allocator.free(expected);
    const actual = try allocator.alloc(u8, Emulator.state_len);
    defer allocator.free(actual);

    var source = Emulator.init();
    source.setup();
    source.bus.flat_mem = flat;
    source.cpu.pbr = 0;
    source.cpu.pc = 0x8000;
    source.ppu.dot = 125; // wall 500
    source.enableOrderedClockFixture();
    source.step(); // checkpoint at 516, before refresh
    _ = try source.writeState(checkpoint);
    source.step();
    source.step(); // continuation crosses refresh and ends at 588
    _ = try source.writeState(expected);

    var replay = Emulator.init();
    replay.setup();
    replay.bus.flat_mem = flat;
    replay.enableOrderedClockFixture(); // establish callback; state restores clocks
    _ = try replay.readState(checkpoint);
    replay.step();
    replay.step();
    _ = try replay.writeState(actual);

    // Full pointer-free state equality includes CPU/PPU, DMA, the APU and its
    // audio clocks, DSP accumulator, and explicit wall/next-refresh fields.
    try std.testing.expectEqualSlices(u8, expected, actual);
    try std.testing.expectEqual(@as(u64, 588), replay.refresh_timeline.wall_master);

    replay.refresh_timeline.next_refresh_master = 0;
    try std.testing.expectError(error.InvalidRefreshSchedule, replay.writeState(actual));
}

test "savestate timing profile rejects cross restore before mutation" {
    const allocator = std.testing.allocator;
    const flat = try allocator.alloc(u8, 0x10000);
    defer allocator.free(flat);
    @memset(flat, 0);
    flat[0x8000] = 0xA9; // LDA #$11
    flat[0x8001] = 0x11;
    flat[0x8002] = 0xA9; // LDA #$22
    flat[0x8003] = 0x22;

    const legacy_checkpoint = try allocator.alloc(u8, Emulator.state_len);
    defer allocator.free(legacy_checkpoint);
    const ordered_checkpoint = try allocator.alloc(u8, Emulator.state_len);
    defer allocator.free(ordered_checkpoint);
    const expected = try allocator.alloc(u8, Emulator.state_len);
    defer allocator.free(expected);
    const actual = try allocator.alloc(u8, Emulator.state_len);
    defer allocator.free(actual);

    var legacy_source = Emulator.init();
    legacy_source.setup();
    legacy_source.bus.flat_mem = flat;
    legacy_source.cpu.pc = 0x8000;
    legacy_source.cpu.pbr = 0;
    _ = try legacy_source.writeState(legacy_checkpoint);

    var ordered_source = Emulator.init();
    ordered_source.setup();
    ordered_source.bus.flat_mem = flat;
    ordered_source.cpu.pc = 0x8000;
    ordered_source.cpu.pbr = 0;
    ordered_source.enableOrderedClockFixture();
    _ = try ordered_source.writeState(ordered_checkpoint);

    var legacy_target = Emulator.init();
    legacy_target.setup();
    legacy_target.bus.flat_mem = flat;
    legacy_target.cpu.a = 0xCAFE;
    try std.testing.expectError(error.InvalidTimingProfile, legacy_target.readState(ordered_checkpoint));
    try std.testing.expectEqual(@as(u16, 0xCAFE), legacy_target.cpu.a);

    var ordered_target = Emulator.init();
    ordered_target.setup();
    ordered_target.bus.flat_mem = flat;
    ordered_target.enableOrderedClockFixture();
    ordered_target.cpu.a = 0xBEEF;
    try std.testing.expectError(error.InvalidTimingProfile, ordered_target.readState(legacy_checkpoint));
    try std.testing.expectEqual(@as(u16, 0xBEEF), ordered_target.cpu.a);

    // Matching aggregate callers retain their profile and execute the same
    // actual next instruction after restore.
    legacy_source.step();
    _ = try legacy_source.writeState(expected);
    _ = try legacy_target.readState(legacy_checkpoint);
    legacy_target.step();
    _ = try legacy_target.writeState(actual);
    try std.testing.expectEqualSlices(u8, expected, actual);
}

test "copyright-free dma-normal ROM matches Mesen2 absolute DMA instants" {
    var rom: [0x8000]u8 = @splat(0xFF);
    const program = [_]u8{
        0x78, 0xD8, 0xA2, 0xFF, 0x9A, // SEI; CLD; LDX #$FF; TXS
        0x9C, 0x00, 0x42, // STZ $4200
        0xA9, 0x00, 0x8D, 0x00, 0x43, // mode 0, A -> B
        0xA9, 0x00, 0x8D, 0x01, 0x43, // destination $2100
        0xA9, 0x12, 0x8D, 0x02, 0x43, // source low $12
        0xA9, 0x42, 0x8D, 0x03, 0x43, // source high $42
        0xA9, 0x00, 0x8D, 0x04, 0x43, // source bank $00
        0xA9, 0x01, 0x8D, 0x05, 0x43, // one byte
        0xA9, 0x00, 0x8D, 0x06, 0x43,
        0xA9, 0x01,
        0x8D, 0x0B, 0x42, // STA $420B
        0x4C, 0x30, 0x80, // marker loop
    };
    @memcpy(rom[0..program.len], &program);
    rom[0x7FD5] = 0x20; // LoROM, SlowROM
    rom[0x7FD6] = 0x00; // ROM only
    rom[0x7FD7] = 0x08; // 32 KiB
    rom[0x7FD8] = 0x00;
    rom[0x7FD9] = 0x01; // NTSC
    rom[0x7FDA] = 0x33;
    rom[0x7FFC] = 0x00;
    rom[0x7FFD] = 0x80;

    var emu = Emulator.init();
    emu.setup();
    try emu.loadRom(&rom);
    var instants = DmaInstants{ .emu = &emu };
    instants.install();
    // Power-on origin: 186 startup masters before the first fetch
    // (Emulator.power_on_startup_masters, Mesen2 SnesConsole::Reset).
    emu.enableOrderedClockFromPowerOn();
    while (emu.cpu.pc != 0x802D) emu.step();
    const sta_start = emu.refresh_timeline.wall_master;
    emu.step(); // STA $420B: the write effect is at 682
    const request = emu.refresh_timeline.wall_master;
    while (instants.write_count == 0) emu.step();

    // This is byte-for-byte the program test/mesen/timing_path_probe.mjs
    // generates for "dma-normal". Mesen2 3b058f9 (certified sandbox,
    // test/timing/mesen_timing_path.mjs) records the $420B write at master
    // 682, the source read at 716 and the $2100 write at 720; the ordered
    // controller must reproduce those absolute instants.
    try std.testing.expectEqual(@as(u64, 652), sta_start);
    try std.testing.expectEqual(@as(u64, 682), request);
    try std.testing.expectEqual(@as(u64, 716), instants.reads[0]);
    try std.testing.expectEqual(@as(u64, 720), instants.writes[0]);
    try std.testing.expectEqual(@as(u8, 0), emu.ppu.inidisp);
    try std.testing.expectEqual(@as(usize, 1), emu.ppu.render_event_count);
    try std.testing.expectEqual(@as(u16, 180), emu.ppu.render_events[0].dot);
}

const HvbjoyReadProbe = struct {
    pc: u16,
    beam: bus_module.CpuReadSampleBeam,
    hblank: bool,
    next_pc: u16,
};

const HvbjoyWaitProbe = struct {
    reads: [64]HvbjoyReadProbe = undefined,
    read_count: usize = 0,
    return_scanline: u16 = 0,
    return_dot: u16 = 0,
    return_residual: u2 = 0,
    // DEY executions on the way out. The expected return positions below
    // were measured when DEY was (wrongly) a one-cycle opcode fetch; the
    // audited IdleOrRead phase adds six masters per DEY on this line.
    dey_count: u32 = 0,
};

fn probeSyntheticHvbjoyWait(scanline: u16, dot: u16, residual: u2, initial_y: u8) HvbjoyWaitProbe {
    var emu = Emulator.init();
    emu.setup();
    // $0000 JSR $0030; $002E LDY #$20; $0030 is the exact structure of
    // SMW's WaitForHBlank at CODE_00843B..008448. WRAM executes at the same
    // eight-master access speed as the game's SlowROM path and contains no
    // copyrighted ROM data.
    const program = [_]struct { addr: usize, byte: u8 }{
        .{ .addr = 0x0000, .byte = 0x20 }, .{ .addr = 0x0001, .byte = 0x30 },
        .{ .addr = 0x0002, .byte = 0x00 }, .{ .addr = 0x002e, .byte = 0xa0 },
        .{ .addr = 0x002f, .byte = 0x20 }, .{ .addr = 0x0030, .byte = 0x2c },
        .{ .addr = 0x0031, .byte = 0x12 }, .{ .addr = 0x0032, .byte = 0x42 },
        .{ .addr = 0x0033, .byte = 0x70 }, .{ .addr = 0x0034, .byte = 0xf9 },
        .{ .addr = 0x0035, .byte = 0x2c }, .{ .addr = 0x0036, .byte = 0x12 },
        .{ .addr = 0x0037, .byte = 0x42 }, .{ .addr = 0x0038, .byte = 0x50 },
        .{ .addr = 0x0039, .byte = 0xfb }, .{ .addr = 0x003a, .byte = 0x88 },
        .{ .addr = 0x003b, .byte = 0xd0 }, .{ .addr = 0x003c, .byte = 0xfd },
        .{ .addr = 0x003d, .byte = 0x60 },
    };
    for (program) |entry| emu.bus.wram[entry.addr] = entry.byte;
    emu.cpu.pc = 0;
    emu.cpu.y = initial_y;
    emu.ppu.scanline = scanline;
    emu.ppu.dot = dot;
    emu.ppu.master_accum = residual;

    var out = HvbjoyWaitProbe{};
    for (0..512) |_| {
        if (emu.cpu.pc == 0x003a) out.dey_count += 1;
        if (emu.cpu.pc == 0x0003) {
            out.return_scanline = emu.ppu.scanline;
            out.return_dot = emu.ppu.dot;
            out.return_residual = @intCast(emu.ppu.master_accum);
            return out;
        }
        if (emu.cpu.pc == 0x0030 or emu.cpu.pc == 0x0035) {
            const pc = emu.cpu.pc;
            emu.step();
            const read_index = out.read_count;
            std.debug.assert(read_index < out.reads.len);
            out.reads[read_index] = .{
                .pc = pc,
                .beam = emu.bus.lastCpuReadSampleBeam(),
                .hblank = emu.cpu.p.v,
                .next_pc = 0,
            };
            out.read_count += 1;
            emu.step();
            out.reads[read_index].next_pc = emu.cpu.pc;
        } else {
            emu.step();
        }
    }
    @panic("synthetic WaitForHBlank did not return");
}

test "$4212 samples its mapped-read handler phase and drives WaitForHBlank branches" {
    const cases = [_]struct {
        dot: u16,
        residual: u2,
        y: u8,
        return_line: u16,
        return_dot: u16,
        return_residual: u2,
        reads: usize,
    }{
        .{ .dot = 105, .residual = 0, .y = 0x1f, .return_line = 37, .return_dot = 177, .return_residual = 0, .reads = 13 },
        .{ .dot = 105, .residual = 2, .y = 0x1f, .return_line = 37, .return_dot = 177, .return_residual = 2, .reads = 13 },
        .{ .dot = 109, .residual = 0, .y = 0x1f, .return_line = 37, .return_dot = 181, .return_residual = 0, .reads = 13 },
        .{ .dot = 109, .residual = 1, .y = 0x1f, .return_line = 37, .return_dot = 181, .return_residual = 1, .reads = 13 },
        .{ .dot = 109, .residual = 2, .y = 0x1f, .return_line = 37, .return_dot = 181, .return_residual = 2, .reads = 13 },
        .{ .dot = 109, .residual = 3, .y = 0x1f, .return_line = 37, .return_dot = 181, .return_residual = 3, .reads = 13 },
        // These four land the access end on H=274, but the handler is four
        // masters earlier. All therefore remain active and take one more
        // polling iteration; this falsifies end-of-access sampling directly.
        .{ .dot = 102, .residual = 0, .y = 0x1f, .return_line = 37, .return_dot = 187, .return_residual = 0, .reads = 14 },
        .{ .dot = 102, .residual = 1, .y = 0x1f, .return_line = 37, .return_dot = 187, .return_residual = 1, .reads = 14 },
        .{ .dot = 102, .residual = 2, .y = 0x1f, .return_line = 37, .return_dot = 187, .return_residual = 2, .reads = 14 },
        .{ .dot = 102, .residual = 3, .y = 0x1f, .return_line = 37, .return_dot = 187, .return_residual = 3, .reads = 14 },
        // These put the handler itself on H=274. Residual 0 is active in
        // Mesen's counter rule; residuals 1/2/3 are HBlank.
        .{ .dot = 103, .residual = 0, .y = 0x1f, .return_line = 37, .return_dot = 188, .return_residual = 0, .reads = 14 },
        .{ .dot = 103, .residual = 1, .y = 0x1f, .return_line = 37, .return_dot = 175, .return_residual = 1, .reads = 13 },
        .{ .dot = 103, .residual = 2, .y = 0x1f, .return_line = 37, .return_dot = 175, .return_residual = 2, .reads = 13 },
        .{ .dot = 103, .residual = 3, .y = 0x1f, .return_line = 37, .return_dot = 175, .return_residual = 3, .reads = 13 },
        .{ .dot = 109, .residual = 0, .y = 0x07, .return_line = 37, .return_dot = 1, .return_residual = 0, .reads = 13 },
        .{ .dot = 109, .residual = 0, .y = 0x20, .return_line = 37, .return_dot = 188, .return_residual = 2, .reads = 13 },
    };
    for (cases) |case| {
        // The cases were designed on pin timing to put the first BIT $4212
        // handler at chosen H positions. JSR now spends one more internal
        // cycle (6 masters) before the routine, so start 6 masters earlier:
        // every handler then lands exactly where the original evidence
        // placed it, and read counts/branch decisions must be unchanged.
        const jsr_internal: u32 = 6;
        const start = @as(u32, case.dot) * master_cycles_per_dot + case.residual - jsr_internal;
        const result = probeSyntheticHvbjoyWait(36, @intCast(start / master_cycles_per_dot), @intCast(start % master_cycles_per_dot), case.y);
        try std.testing.expectEqual(case.reads, result.read_count);
        // Pin-era return position plus the internal cycles the pin lacked,
        // each verified against SingleStepTests 65816 and Mesen2:
        //   - DEY's IdleOrRead phase, six masters per execution;
        //   - JSR abs's internal cycle before its push (6, compensated by
        //     the earlier start above);
        //   - RTS's three internal cycles (18).
        // The branch decisions asserted below are unchanged.
        const pin_return = @as(u64, case.return_line) * masters_per_line +
            @as(u64, case.return_dot) * master_cycles_per_dot + case.return_residual;
        const actual_return = @as(u64, result.return_scanline) * masters_per_line +
            @as(u64, result.return_dot) * master_cycles_per_dot + result.return_residual;
        // JSR's cycle is absorbed by the earlier start; RTS adds three.
        const rts_internal: u64 = 3 * 6;
        try std.testing.expectEqual(pin_return + @as(u64, result.dey_count) * 6 + rts_internal, actual_return);
        for (result.reads[0..result.read_count]) |read| {
            // BVS leaves the first loop when V=0; BVC leaves the second loop
            // when V=1. Assert the branch result, not only the return dot.
            if (read.pc == 0x0030) {
                try std.testing.expectEqual(if (read.hblank) @as(u16, 0x002e) else 0x0035, read.next_pc);
            } else {
                try std.testing.expectEqual(if (read.hblank) @as(u16, 0x003a) else 0x0035, read.next_pc);
            }
            // Assert the returned flag against the explicit handler phase.
            const hclock = @as(u16, read.beam.dot) * master_cycles_per_dot + read.beam.master_residual;
            try std.testing.expectEqual(read.hblank, hclock < 4 or hclock > 274 * 4);
        }
    }
}

test "$4212 samples the mapped-read handler phase at the H=274 half-cycle" {
    // A BIT abs performs three eight-master fetches, then samples its
    // six-master I/O read after two masters and finishes four masters later.
    // This first case ends at H=274 residual 2 but samples at H=273 residual
    // 2, so an access-end model would return the wrong HBlank bit.
    var before_edge = Emulator.init();
    before_edge.setup();
    before_edge.ppu.scanline = 36;
    before_edge.ppu.dot = 267;
    before_edge.ppu.master_accum = 0;
    before_edge.bus.beginCpuInstruction();
    before_edge.bus.setCpuReadSampleTiming(26);
    before_edge.bus.setCpuAccessTiming(30);
    try std.testing.expectEqual(@as(u16, 273), before_edge.bus.lastCpuReadSampleBeam().dot);
    try std.testing.expectEqual(@as(u2, 2), before_edge.bus.lastCpuReadSampleBeam().master_residual);
    try std.testing.expect(before_edge.bus.read(0, 0x4212) & 0x40 == 0);

    // These starts put the handler on the two sides of Mesen's observable
    // H=274 edge: residual 0 is active; residual 2 is HBlank.
    var edge_zero = Emulator.init();
    edge_zero.setup();
    edge_zero.ppu.scanline = 36;
    edge_zero.ppu.dot = 267;
    edge_zero.ppu.master_accum = 2;
    edge_zero.bus.beginCpuInstruction();
    edge_zero.bus.setCpuReadSampleTiming(26);
    edge_zero.bus.setCpuAccessTiming(30);
    try std.testing.expectEqual(@as(u16, 274), edge_zero.bus.lastCpuReadSampleBeam().dot);
    try std.testing.expectEqual(@as(u2, 0), edge_zero.bus.lastCpuReadSampleBeam().master_residual);
    try std.testing.expect(edge_zero.bus.read(0, 0x4212) & 0x40 == 0);

    var edge_two = Emulator.init();
    edge_two.setup();
    edge_two.ppu.scanline = 36;
    edge_two.ppu.dot = 268;
    edge_two.ppu.master_accum = 0;
    edge_two.bus.beginCpuInstruction();
    edge_two.bus.setCpuReadSampleTiming(26);
    edge_two.bus.setCpuAccessTiming(30);
    try std.testing.expectEqual(@as(u16, 274), edge_two.bus.lastCpuReadSampleBeam().dot);
    try std.testing.expectEqual(@as(u2, 2), edge_two.bus.lastCpuReadSampleBeam().master_residual);
    try std.testing.expect(edge_two.bus.read(0, 0x4212) & 0x40 != 0);
}

test "$4212 never reuses a stale CPU sample across direct DMA and reset boundaries" {
    var emu = Emulator.init();
    emu.setup();
    emu.ppu.scanline = 36;
    emu.ppu.dot = 100;

    // An explicitly declared CPU handler phase may differ from committed PPU
    // time and is used only while valid.
    emu.bus.beginCpuInstruction();
    emu.bus.setCpuReadSampleTiming(700);
    try std.testing.expect(emu.bus.read(0, 0x4212) & 0x40 != 0);
    emu.bus.invalidateCpuReadSample();
    try std.testing.expect(emu.bus.read(0, 0x4212) & 0x40 == 0);

    emu.bus.setCpuReadSampleTiming(700);
    emu.bus.write(0, 0x0010, 0x5a);
    try std.testing.expect(emu.bus.read(0, 0x4212) & 0x40 == 0);

    emu.bus.setCpuReadSampleTiming(700);
    emu.bus.beginStandaloneDma();
    try std.testing.expect(emu.bus.readDma(0x004212) & 0x40 == 0);

    // readDma itself is safe even if a caller bypasses the outer DMA setup.
    emu.bus.setCpuReadSampleTiming(700);
    try std.testing.expect(emu.bus.readDma(0x004212) & 0x40 == 0);

    // Reset's committed beam is H=0 (HBlank in Mesen's counter rule). Seed a
    // stale active-display handler first, so the observed bit proves reset
    // cleared validity rather than coincidentally agreeing with it.
    emu.bus.beginCpuInstruction();
    emu.bus.setCpuReadSampleTiming(0);
    try std.testing.expect(emu.bus.read(0, 0x4212) & 0x40 == 0);
    emu.reset();
    try std.testing.expect(emu.bus.read(0, 0x4212) & 0x40 != 0);
}

test "$4212 CPU sample validity is transient across savestate restore" {
    var emu = Emulator.init();
    emu.setup();
    emu.ppu.scanline = 36;
    emu.ppu.dot = 100;

    const snapshot = try std.testing.allocator.alloc(u8, Emulator.state_len);
    defer std.testing.allocator.free(snapshot);
    _ = try emu.writeState(snapshot);

    emu.bus.beginCpuInstruction();
    emu.bus.setCpuReadSampleTiming(700);
    try std.testing.expect(emu.bus.read(0, 0x4212) & 0x40 != 0);
    _ = try emu.readState(snapshot);
    try std.testing.expectEqual(@as(u16, 100), emu.ppu.dot);
    try std.testing.expect(emu.bus.read(0, 0x4212) & 0x40 == 0);

    // A rejected restore must also end the transient execution phase.
    emu.bus.setCpuReadSampleTiming(700);
    try std.testing.expectError(error.ShortBuffer, emu.readState(&.{}));
    try std.testing.expect(emu.bus.read(0, 0x4212) & 0x40 == 0);
}


test "ordered profile alternates 357368 and 357364 master fields" {
    // A tight BRA loop in WRAM keeps the CPU running while fields elapse.
    var emu = Emulator.init();
    emu.setup();
    emu.cpu.pc = 0;
    emu.bus.wram[0] = 0x80; // BRA -2
    emu.bus.wram[1] = 0xFE;
    emu.enableOrderedClockFromPowerOn();

    // Mesen2 3b058f9 frame-start callbacks for the same geometry
    // (test/timing/mesen_timing_path.mjs): fields 0,1,2 are 357368, 357364,
    // 357368 masters; field 1 is odd, so its scanline 240 is 1360 masters.
    const expected = [_]u64{ 357368, 714732, 1072100 };
    for (expected) |start| {
        const frame = emu.ppu.frame_count;
        while (emu.ppu.frame_count == frame) emu.step();
        try std.testing.expectEqual(start, emu.ppu.frameStartMaster());
    }

    // The short line moves every later line start by 4 masters, and the
    // reset-aligned refresh follows the ACTUAL line start: line 241 of the
    // odd field 1 starts at 357368 + 241*1364 - 4 = 686088, which is a
    // multiple of 8, so its refresh fires at local H-clock 538.
    try std.testing.expectEqual(
        @as(u64, 686088 + 538),
        refresh_timing.refreshMasterForLineStart(357368 + 241 * 1364 - 4),
    );
    try std.testing.expect(emu.ppu.odd_frame); // field 3 is odd (0 even, 1 odd, ...)
}

test "WAI wakes through Mesen2's two-stage halted cycles" {
    // Byte-for-byte test/mesen/timing_path_probe.mjs "wai-h100": H-IRQ at
    // htime 100, CLI, then WAI; BRA. The handler at $8100 acknowledges, INCs
    // $0100 and returns. Mesen2 3b058f9 (certified sandbox) enters the
    // handler at master 488 and performs the INC's write at 598.
    //
    // Derivation: WAI's fetch ends at 404; halted 6-master idles start at
    // 404, 410, 416, 422, ... The CPU IRQ input rises at 18 + 4*100 = 418
    // (TIMEUP flag at 414), so the idle starting at 422 records the wake,
    // the idle at 428 leaves the halt, and the interrupt sequence (read at
    // PC 8, idle 6, three pushes and two vector reads at 8) runs 434-488.
    var rom: [0x8000]u8 = @splat(0xFF);
    const program = [_]u8{
        0x78, 0xD8, 0xA2, 0xFF, 0x9A, // SEI; CLD; LDX #$FF; TXS
        0xA9, 100, 0x8D, 0x07, 0x42, // HTIMEL = 100
        0xA9, 0x00, 0x8D, 0x08, 0x42, // HTIMEH = 0
        0xA9, 0x10, 0x8D, 0x00, 0x42, // NMITIMEN: H-IRQ
        0x58, // CLI
        0xCB, 0x80, 0xFD, // WAI; BRA -3
    };
    @memcpy(rom[0..program.len], &program);
    rom[0x100..0x107].* = .{ 0xAD, 0x11, 0x42, 0xEE, 0x00, 0x01, 0x40 }; // LDA $4211; INC $0100; RTI
    rom[0x7FD5] = 0x20;
    rom[0x7FD6] = 0x00;
    rom[0x7FD7] = 0x08;
    rom[0x7FD8] = 0x00;
    rom[0x7FD9] = 0x01;
    rom[0x7FDA] = 0x33;
    rom[0x7FFC] = 0x00;
    rom[0x7FFD] = 0x80;
    rom[0x7FFE] = 0x00; // IRQ/BRK vector (emulation) -> $8100
    rom[0x7FFF] = 0x81;

    const Seen = struct {
        emu: *Emulator,
        entry: u64 = 0,
        write: u64 = 0,
        fn record(context: *anyopaque, kind: bus_module.TimingProbeKind, addr: u24, value: u8) void {
            _ = value;
            const self: *@This() = @ptrCast(@alignCast(context));
            const now = self.emu.refresh_timeline.wall_master;
            if (kind == .exec and addr == 0x008100 and self.entry == 0) self.entry = now;
            if (kind == .cpu_write and addr == 0x000100 and self.write == 0) self.write = now;
        }
    };
    var emu = Emulator.init();
    emu.setup();
    try emu.loadRom(&rom);
    var seen = Seen{ .emu = &emu };
    emu.bus.timing_probe = .{ .context = &seen, .record = Seen.record };
    emu.enableOrderedClockFromPowerOn();
    while (seen.write == 0) emu.step();
    try std.testing.expectEqual(@as(u64, 488), seen.entry);
    try std.testing.expectEqual(@as(u64, 598), seen.write);
}
