const std = @import("std");

// The current PPU profile uses these values. Refresh phase itself is derived
// from each actual line start below, so alternate geometry must supply its
// observed boundary rather than inheriting a frame-period assumption.
pub const current_line_masters: u64 = 341 * 4;
pub const current_lines_per_frame: u64 = 262;
pub const current_frame_masters: u64 = current_line_masters * current_lines_per_frame;
pub const reset_refresh_hclock: u64 = 538;
pub const refresh_stall_masters: u32 = 40;
pub const no_refresh_scheduled: u64 = std.math.maxInt(u64);
pub const RestoreError = error{InvalidRefreshSchedule};

/// Reset-aligned refresh start for one observed physical scanline. The caller
/// supplies its actual absolute wall-clock boundary; short/long scanlines can
/// therefore change the local H-clock without changing the global phase.
pub fn refreshMasterForLineStart(line_start: u64) u64 {
    return line_start + reset_refresh_hclock - (line_start & 7);
}

pub const Advance = struct {
    wall_elapsed: u64,
    refresh_masters: u64,
    refreshes: u32,
};

pub const SegmentKind = enum {
    cpu_work,
    dma_work,
    dram_refresh,
};

/// Provenance retained at the CPU-to-clock-owner boundary. Every case is CPU
/// work to the wall scheduler, but keeping the cause distinct prevents the
/// conditional implied-operation IdleOrRead from becoming an anonymous flat
/// six-master charge.
pub const CpuPhase = enum {
    read_leading,
    read_trailing,
    write,
    idle_or_read_before_effect,
    internal_before_effect,
    internal_before_access,
    internal_trailing,
};

/// CPU read handlers run after the access's leading clocks and before its
/// final four master clocks. This is a hardware phase boundary, not a trace
/// callback adjustment.
pub fn cpuReadLeadingMasters(access_masters: u32) u32 {
    std.debug.assert(access_masters == 6 or access_masters == 8 or access_masters == 12);
    return access_masters - 4;
}

pub const CpuAccessPhases = struct {
    timeline: *Timeline,

    /// Advance to a mapped read handler. The caller performs the read only
    /// after this returns, then calls finishRead for the trailing clocks.
    pub fn beginRead(self: CpuAccessPhases, access_masters: u32, sink: anytype) void {
        self.timeline.advanceWorkOrdered(cpuReadLeadingMasters(access_masters), sink);
    }

    pub fn finishRead(self: CpuAccessPhases, sink: anytype) void {
        self.timeline.advanceWorkOrdered(4, sink);
    }

    /// SNES writes take effect after the complete access cycle.
    pub fn beforeWrite(self: CpuAccessPhases, access_masters: u32, sink: anytype) void {
        std.debug.assert(access_masters == 6 or access_masters == 8 or access_masters == 12);
        self.timeline.advanceWorkOrdered(access_masters, sink);
    }

    /// Advance an internal CPU phase before its architectural effect. The
    /// separately audited implied/register family uses one such six-master
    /// phase, while XBA uses two.
    pub fn beforeInternalEffect(self: CpuAccessPhases, internal_masters: u32, sink: anytype) void {
        std.debug.assert(internal_masters % 6 == 0);
        self.timeline.advanceWorkOrdered(internal_masters, sink);
    }
};

/// Prototype timeline for any bus-owning work: CPU, DMA, or HDMA consumes
/// `work_masters`; the PPU/APU/coprocessors observe `wall_elapsed`. Keeping the
/// next event explicit distinguishes an unprocessed event at an exact boundary
/// from a snapshot taken after its 40-master stall.
pub const Timeline = struct {
    wall_master: u64,
    next_refresh_master: u64,

    pub fn reset() Timeline {
        return .{ .wall_master = 0, .next_refresh_master = refreshMasterForLineStart(0) };
    }

    pub fn restore(wall_master: u64, next_refresh_master: u64) RestoreError!Timeline {
        if (next_refresh_master < wall_master) return RestoreError.InvalidRefreshSchedule;
        return .{ .wall_master = wall_master, .next_refresh_master = next_refresh_master };
    }

    /// Schedule refresh from an actual line-boundary event. The owner must
    /// split advancement at line boundaries and call this once per new line.
    pub fn beginLine(self: *Timeline, line_start_master: u64) void {
        std.debug.assert(self.wall_master == line_start_master);
        self.next_refresh_master = refreshMasterForLineStart(line_start_master);
    }

    /// Consume CPU work on the single serialized wall timeline. `sink`
    /// advances every independently clocked device for each ordered segment
    /// and reports the PPU's current distance to its actual line boundary.
    /// Reaching that boundary schedules the following line from the observed
    /// absolute wall time, so a short or long line changes refresh phase.
    ///
    /// `sink` contract:
    ///   mastersUntilLineBoundary() -> positive u64
    ///   mastersUntilExternalEvent() -> ?u64 (strictly positive when present)
    ///   advanceHardware(masters: u32, kind: SegmentKind) -> void
    ///   dispatchExternalEvent() -> void
    pub fn advanceWorkOrdered(self: *Timeline, work_masters: u64, sink: anytype) void {
        self.advanceWorkOrderedAs(work_masters, sink, .cpu_work);
    }

    pub fn advanceDmaWorkOrdered(self: *Timeline, work_masters: u64, sink: anytype) void {
        self.advanceWorkOrderedAs(work_masters, sink, .dma_work);
    }

    fn advanceWorkOrderedAs(
        self: *Timeline,
        work_masters: u64,
        sink: anytype,
        work_kind: SegmentKind,
    ) void {
        var remaining = work_masters;
        while (remaining != 0) {
            const line_delta: u64 = sink.mastersUntilLineBoundary();
            std.debug.assert(line_delta != 0);
            const line_boundary = self.wall_master + line_delta;
            const external_delta = sink.mastersUntilExternalEvent();
            if (external_delta) |delta| std.debug.assert(delta != 0);
            const external_master = if (external_delta) |delta|
                self.wall_master + delta
            else
                no_refresh_scheduled;
            const event_master = @min(@min(self.next_refresh_master, line_boundary), external_master);
            const work_to_event = event_master - self.wall_master;

            if (remaining < work_to_event) {
                advanceSegment(self, sink, remaining, work_kind);
                return;
            }

            if (work_to_event != 0) {
                advanceSegment(self, sink, work_to_event, work_kind);
                remaining -= work_to_event;
            }

            if (event_master == line_boundary) {
                // advanceHardware above moved the PPU through its real line
                // rollover. Its absolute position is the next line's origin.
                self.beginLine(self.wall_master);
            } else {
                if (event_master == self.next_refresh_master) {
                    self.next_refresh_master = no_refresh_scheduled;
                    self.advanceWallThroughLines(refresh_stall_masters, sink, .dram_refresh);
                } else {
                    sink.dispatchExternalEvent();
                }
            }
        }
    }

    /// Advance wall-only time, splitting at real PPU line rollovers. Refresh
    /// is normally far from the boundary, but handling the crossing here
    /// keeps the clock contract correct for every geometry the sink exposes.
    fn advanceWallThroughLines(
        self: *Timeline,
        wall_masters: u64,
        sink: anytype,
        kind: SegmentKind,
    ) void {
        var remaining = wall_masters;
        while (remaining != 0) {
            const line_delta: u64 = sink.mastersUntilLineBoundary();
            std.debug.assert(line_delta != 0);
            const segment = @min(remaining, line_delta);
            advanceSegment(self, sink, segment, kind);
            remaining -= segment;
            if (segment == line_delta) self.beginLine(self.wall_master);
        }
    }

    fn advanceSegment(self: *Timeline, sink: anytype, masters: u64, kind: SegmentKind) void {
        std.debug.assert(masters <= std.math.maxInt(u32));
        self.wall_master += masters;
        sink.advanceHardware(@intCast(masters), kind);
    }

    pub fn advanceWork(self: *Timeline, work_masters: u64) Advance {
        const start = self.wall_master;
        var remaining = work_masters;
        var refreshes: u32 = 0;

        if (self.next_refresh_master <= self.wall_master + remaining) {
            const work_before_refresh = self.next_refresh_master - self.wall_master;
            remaining -= work_before_refresh;
            const fired = self.next_refresh_master;
            self.wall_master = fired + refresh_stall_masters;
            refreshes += 1;
            self.next_refresh_master = no_refresh_scheduled;
        }
        self.wall_master += remaining;

        return .{
            .wall_elapsed = self.wall_master - start,
            .refresh_masters = @as(u64, refreshes) * refresh_stall_masters,
            .refreshes = refreshes,
        };
    }
};

const RecordedSegment = struct {
    masters: u32,
    kind: SegmentKind,
};

const TestHardware = struct {
    line_lengths: []const u16,
    line_index: usize = 0,
    in_line: u16 = 0,
    cpu_work: u64 = 0,
    dma_work: u64 = 0,
    refresh: u64 = 0,
    segments: [16]RecordedSegment = undefined,
    segment_count: usize = 0,

    fn mastersUntilLineBoundary(self: *const TestHardware) u64 {
        return self.line_lengths[self.line_index] - self.in_line;
    }

    fn mastersUntilExternalEvent(self: *const TestHardware) ?u64 {
        _ = self;
        return null;
    }

    fn dispatchExternalEvent(self: *TestHardware) void {
        _ = self;
        unreachable;
    }

    fn advanceHardware(self: *TestHardware, masters: u32, kind: SegmentKind) void {
        self.segments[self.segment_count] = .{ .masters = masters, .kind = kind };
        self.segment_count += 1;
        switch (kind) {
            .cpu_work => self.cpu_work += masters,
            .dma_work => self.dma_work += masters,
            .dram_refresh => self.refresh += masters,
        }

        var remaining = masters;
        while (remaining != 0) {
            const to_boundary: u32 = self.line_lengths[self.line_index] - self.in_line;
            const step = @min(remaining, to_boundary);
            self.in_line += @intCast(step);
            remaining -= step;
            if (self.in_line == self.line_lengths[self.line_index]) {
                self.in_line = 0;
                self.line_index = (self.line_index + 1) % self.line_lengths.len;
            }
        }
    }
};

test "reset schedule follows 538 minus line-start master modulo eight" {
    try std.testing.expectEqual(@as(u64, 538), refreshMasterForLineStart(0));
    try std.testing.expectEqual(@as(u64, 1364 + 534), refreshMasterForLineStart(1364));
    try std.testing.expectEqual(@as(u64, 2 * 1364 + 538), refreshMasterForLineStart(2 * 1364));
    try std.testing.expectEqual(current_frame_masters + 538, refreshMasterForLineStart(current_frame_masters));
    for (0..current_lines_per_frame * 2) |line| {
        const line_start = line * current_line_masters;
        try std.testing.expectEqual(@as(u64, 2), refreshMasterForLineStart(line_start) & 7);
    }

    // A 1360-master short first line makes the next local position H=538
    // rather than H=534 while preserving the reset-aligned absolute event.
    try std.testing.expectEqual(@as(u64, 1360 + 538), refreshMasterForLineStart(1360));
}

test "three SlowROM immediate loads crossing refresh consume 48 work and 88 wall masters" {
    var timeline = try Timeline.restore(500, refreshMasterForLineStart(0));
    const result = timeline.advanceWork(48);
    try std.testing.expectEqual(@as(u64, 88), result.wall_elapsed);
    try std.testing.expectEqual(@as(u64, 40), result.refresh_masters);
    try std.testing.expectEqual(@as(u32, 1), result.refreshes);
    try std.testing.expectEqual(@as(u64, 588), timeline.wall_master);
}

test "ordered wall clock emits CPU work and refresh to one hardware sink" {
    const lines = [_]u16{@intCast(current_line_masters)};
    var hardware = TestHardware{ .line_lengths = &lines, .in_line = 500 };
    var timeline = try Timeline.restore(500, refreshMasterForLineStart(0));

    timeline.advanceWorkOrdered(48, &hardware);

    try std.testing.expectEqual(@as(u64, 588), timeline.wall_master);
    try std.testing.expectEqual(@as(u64, 48), hardware.cpu_work);
    try std.testing.expectEqual(@as(u64, 40), hardware.refresh);
    try std.testing.expectEqual(@as(usize, 3), hardware.segment_count);
    try std.testing.expectEqualDeep(
        RecordedSegment{ .masters = 38, .kind = .cpu_work },
        hardware.segments[0],
    );
    try std.testing.expectEqualDeep(
        RecordedSegment{ .masters = 40, .kind = .dram_refresh },
        hardware.segments[1],
    );
    try std.testing.expectEqualDeep(
        RecordedSegment{ .masters = 10, .kind = .cpu_work },
        hardware.segments[2],
    );
}

test "CPU read handler and write effect occupy causal wall phases" {
    const lines = [_]u16{@intCast(current_line_masters)};
    try std.testing.expectEqual(@as(u32, 2), cpuReadLeadingMasters(6));
    try std.testing.expectEqual(@as(u32, 4), cpuReadLeadingMasters(8));
    try std.testing.expectEqual(@as(u32, 8), cpuReadLeadingMasters(12));

    // A six-master I/O read beginning at 536 reaches refresh during its two
    // leading masters. The mapped handler runs at 578, then four clocks trail.
    var read_hardware = TestHardware{ .line_lengths = &lines, .in_line = 536 };
    var read_timeline = try Timeline.restore(536, refreshMasterForLineStart(0));
    const read_phases = CpuAccessPhases{ .timeline = &read_timeline };
    read_phases.beginRead(6, &read_hardware);
    const handler_master = read_timeline.wall_master;
    read_phases.finishRead(&read_hardware);
    try std.testing.expectEqual(@as(u64, 578), handler_master);
    try std.testing.expectEqual(@as(u64, 582), read_timeline.wall_master);

    // Starting two clocks earlier puts the handler before refresh. Only the
    // trailing phase stalls, which a callback-minus-four projection misses.
    var trailing_hardware = TestHardware{ .line_lengths = &lines, .in_line = 534 };
    var trailing_timeline = try Timeline.restore(534, refreshMasterForLineStart(0));
    const trailing_phases = CpuAccessPhases{ .timeline = &trailing_timeline };
    trailing_phases.beginRead(6, &trailing_hardware);
    const earlier_handler = trailing_timeline.wall_master;
    trailing_phases.finishRead(&trailing_hardware);
    try std.testing.expectEqual(@as(u64, 536), earlier_handler);
    try std.testing.expectEqual(@as(u64, 580), trailing_timeline.wall_master);

    // A write effect occurs only after the complete access and any refresh
    // reached by it has advanced the independently clocked hardware.
    var write_hardware = TestHardware{ .line_lengths = &lines, .in_line = 536 };
    var write_timeline = try Timeline.restore(536, refreshMasterForLineStart(0));
    const write_phases = CpuAccessPhases{ .timeline = &write_timeline };
    write_phases.beforeWrite(6, &write_hardware);
    try std.testing.expectEqual(@as(u64, 582), write_timeline.wall_master);
}

test "internal instruction work advances before its architectural effect" {
    const lines = [_]u16{@intCast(current_line_masters)};
    var hardware = TestHardware{ .line_lengths = &lines, .in_line = 536 };
    var timeline = try Timeline.restore(536, refreshMasterForLineStart(0));
    const phases = CpuAccessPhases{ .timeline = &timeline };

    phases.beforeInternalEffect(6, &hardware);
    try std.testing.expectEqual(@as(u64, 582), timeline.wall_master);
    try std.testing.expectEqual(@as(u64, 6), hardware.cpu_work);
    try std.testing.expectEqual(@as(u64, 40), hardware.refresh);
}

test "actual short-line rollover determines the next refresh phase" {
    const lines = [_]u16{ 1360, 1364 };
    var hardware = TestHardware{
        .line_lengths = &lines,
        .in_line = 1350,
    };
    var timeline = try Timeline.restore(1350, no_refresh_scheduled);

    timeline.advanceWorkOrdered(548, &hardware);

    // Ten work clocks reach the actual 1360-master boundary. The following
    // line schedules at local H=538, reached by the remaining 538 work clocks.
    try std.testing.expectEqual(@as(u64, 1938), timeline.wall_master);
    try std.testing.expectEqual(@as(u64, 548), hardware.cpu_work);
    try std.testing.expectEqual(@as(u64, 40), hardware.refresh);
    try std.testing.expectEqual(@as(usize, 1), hardware.line_index);
    try std.testing.expectEqual(@as(u16, 578), hardware.in_line);
}

test "wall-only refresh time also observes a line rollover" {
    // Deliberately tiny synthetic geometry forces the refresh stall itself
    // across a boundary, exercising the generic ordered-wall contract.
    const lines = [_]u16{ 560, 600 };
    var hardware = TestHardware{ .line_lengths = &lines, .in_line = 536 };
    var timeline = try Timeline.restore(536, refreshMasterForLineStart(0));

    timeline.advanceWorkOrdered(2, &hardware);

    try std.testing.expectEqual(@as(u64, 578), timeline.wall_master);
    try std.testing.expectEqual(@as(u64, 2), hardware.cpu_work);
    try std.testing.expectEqual(@as(u64, 40), hardware.refresh);
    try std.testing.expectEqual(@as(usize, 1), hardware.line_index);
    try std.testing.expectEqual(@as(u16, 18), hardware.in_line);
    try std.testing.expectEqual(refreshMasterForLineStart(560), timeline.next_refresh_master);
}

test "work ending on refresh start pays the stall before completing" {
    var before = try Timeline.restore(500, refreshMasterForLineStart(0));
    try std.testing.expectEqual(@as(u64, 37), before.advanceWork(37).wall_elapsed);
    try std.testing.expectEqual(@as(u64, 537), before.wall_master);

    var on_edge = try Timeline.restore(500, refreshMasterForLineStart(0));
    try std.testing.expectEqual(@as(u64, 78), on_edge.advanceWork(38).wall_elapsed);
    try std.testing.expectEqual(@as(u64, 578), on_edge.wall_master);
}

test "chunked access projection equals one instruction span" {
    var accesses = try Timeline.restore(500, refreshMasterForLineStart(0));
    const first = accesses.advanceWork(32);
    const second = accesses.advanceWork(16);
    try std.testing.expectEqual(@as(u64, 32), first.wall_elapsed);
    try std.testing.expectEqual(@as(u64, 56), second.wall_elapsed);
    try std.testing.expectEqual(@as(u64, 588), accesses.wall_master);

    var instruction = try Timeline.restore(500, refreshMasterForLineStart(0));
    try std.testing.expectEqual(@as(u64, 88), instruction.advanceWork(48).wall_elapsed);
    try std.testing.expectEqual(instruction.wall_master, accesses.wall_master);
    try std.testing.expectEqual(instruction.next_refresh_master, accesses.next_refresh_master);
}

test "read handler and callback remain distinct around a refresh" {
    // Six-master I/O read: two leading masters, handler, four trailing. A
    // refresh reached by the leading phase occurs before the handler.
    var before_handler = try Timeline.restore(536, refreshMasterForLineStart(0));
    try std.testing.expectEqual(@as(u64, 42), before_handler.advanceWork(2).wall_elapsed);
    try std.testing.expectEqual(@as(u64, 578), before_handler.wall_master);
    try std.testing.expectEqual(@as(u64, 4), before_handler.advanceWork(4).wall_elapsed);

    // If the handler is at 536 instead, the trailing phase reaches refresh.
    // The callback is 44 wall masters later, so callback-minus-four would put
    // the sample on the wrong side of the event.
    var after_handler = try Timeline.restore(536, refreshMasterForLineStart(0));
    try std.testing.expectEqual(@as(u64, 44), after_handler.advanceWork(4).wall_elapsed);
    try std.testing.expectEqual(@as(u64, 580), after_handler.wall_master);
}

test "DMA-like work uses the same bus timeline and actual line boundaries" {
    const lines = [_]u16{@intCast(current_line_masters)};
    var hardware = TestHardware{ .line_lengths = &lines, .in_line = 520 };
    var ordered_dma = try Timeline.restore(520, refreshMasterForLineStart(0));
    ordered_dma.advanceDmaWorkOrdered(64, &hardware);
    try std.testing.expectEqual(@as(u64, 624), ordered_dma.wall_master);
    try std.testing.expectEqual(@as(u64, 0), hardware.cpu_work);
    try std.testing.expectEqual(@as(u64, 64), hardware.dma_work);
    try std.testing.expectEqual(@as(u64, 40), hardware.refresh);

    var dma = try Timeline.restore(520, refreshMasterForLineStart(0));
    const dma_result = dma.advanceWork(64);
    try std.testing.expectEqual(@as(u64, 104), dma_result.wall_elapsed);
    try std.testing.expectEqual(@as(u32, 1), dma_result.refreshes);

    const near_frame_end = current_frame_masters - 20;
    var wrap = try Timeline.restore(near_frame_end, no_refresh_scheduled);
    try std.testing.expectEqual(@as(u64, 20), wrap.advanceWork(20).wall_elapsed);
    wrap.beginLine(current_frame_masters);
    const wrap_result = wrap.advanceWork(580);
    try std.testing.expectEqual(@as(u32, 1), wrap_result.refreshes);
    try std.testing.expectEqual(@as(u64, 620), wrap_result.wall_elapsed);
    try std.testing.expectEqual(current_frame_masters + 620, wrap.wall_master);
}

test "serialized timeline replays the same refresh decision" {
    var source = try Timeline.restore(500, refreshMasterForLineStart(0));
    _ = source.advanceWork(32);
    const saved_wall = source.wall_master;
    const saved_next = source.next_refresh_master;

    const expected = source.advanceWork(16);
    var restored = try Timeline.restore(saved_wall, saved_next);
    const actual = restored.advanceWork(16);
    try std.testing.expectEqualDeep(expected, actual);
    try std.testing.expectEqualDeep(source, restored);
}

test "restore rejects an already-past refresh event" {
    try std.testing.expectError(
        RestoreError.InvalidRefreshSchedule,
        Timeline.restore(539, refreshMasterForLineStart(0)),
    );
}
