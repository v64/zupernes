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
