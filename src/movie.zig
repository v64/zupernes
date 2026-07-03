// =============================================================================
// INPUT MOVIES (TAS format)
// =============================================================================
// A movie is the complete controller input for a deterministic run: one
// line per frame. Combined with a deterministic emulator this reproduces a
// play session exactly - the foundation for TAS support, regression
// testing ("does the movie still finish the level?"), cross-emulator
// verification, and the ZuperWorld port's frame-lockstep comparisons
// (both projects consume this same format).
//
// FORMAT (.zmov, text):
//   - Lines starting with '#' are comments/metadata. Recognized metadata
//     keys (informational, not enforced): "# rom-sha256: <hex>",
//     "# name: <title>".
//   - Every other line is ONE FRAME of controller 1 input: the set of
//     held buttons as characters, in any order. Empty line = no input.
//       B Y s S U D L R A X l r
//     (s = Select, S = Start, l/r = shoulders - same letters as the
//     screenshot tool's --input flags.)
//   - Frame 0 is the first frame after power-on/reset.
//
// The frame-to-line mapping is 1:1 with EMULATED frames, including lag
// frames - like BizHawk's input log, which this format is deliberately
// one small step from (a .bk2 importer needs only the container and
// per-line mnemonic translation).
// =============================================================================

const std = @import("std");

/// Map a button character to its bit in the $4219:$4218 button layout.
pub fn buttonBit(c: u8) ?u16 {
    return switch (c) {
        'B' => 0x8000,
        'Y' => 0x4000,
        's' => 0x2000,
        'S' => 0x1000,
        'U' => 0x0800,
        'D' => 0x0400,
        'L' => 0x0200,
        'R' => 0x0100,
        'A' => 0x0080,
        'X' => 0x0040,
        'l' => 0x0020,
        'r' => 0x0010,
        else => null,
    };
}

/// The canonical character for each button bit, MSB-first.
pub const BUTTON_CHARS = "BYsSUDLRAXlr";

pub const Movie = struct {
    /// Buttons held on each frame (controller 1), index = frame number.
    frames: std.ArrayListUnmanaged(u16),

    pub fn deinit(self: *Movie, allocator: std.mem.Allocator) void {
        self.frames.deinit(allocator);
    }

    /// Input for a frame; frames past the end of the movie are no-input.
    pub fn buttons(self: *const Movie, frame: u32) u16 {
        if (frame >= self.frames.items.len) return 0;
        return self.frames.items[frame];
    }

    pub fn len(self: *const Movie) u32 {
        return @intCast(self.frames.items.len);
    }

    /// Parse .zmov text.
    pub fn parse(allocator: std.mem.Allocator, text: []const u8) !Movie {
        var movie = Movie{ .frames = .empty };
        errdefer movie.deinit(allocator);

        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len > 0 and line[0] == '#') continue;
            // A trailing newline yields one empty final segment; only treat
            // empty lines BETWEEN content as frames. Simplest rule matching
            // intent: skip an empty line only if it's the very last segment.
            if (line.len == 0 and lines.peek() == null) break;
            var pad: u16 = 0;
            for (line) |c| {
                if (c == '.') continue; // optional padding character
                pad |= buttonBit(c) orelse return error.BadButtonChar;
            }
            try movie.frames.append(allocator, pad);
        }
        return movie;
    }

    /// Serialize to .zmov text (canonical form: MSB-first button chars).
    pub fn serialize(self: *const Movie, allocator: std.mem.Allocator, name: ?[]const u8) ![]u8 {
        var out = std.ArrayListUnmanaged(u8).empty;
        errdefer out.deinit(allocator);
        try out.appendSlice(allocator, "# zmov 1\n");
        if (name) |n| {
            try out.appendSlice(allocator, "# name: ");
            try out.appendSlice(allocator, n);
            try out.append(allocator, '\n');
        }
        for (self.frames.items) |pad| {
            for (BUTTON_CHARS, 0..) |c, i| {
                const bit = @as(u16, 0x8000) >> @intCast(i);
                if (bit < 0x0010) break;
                if ((pad & bit) != 0) try out.append(allocator, c);
            }
            try out.append(allocator, '\n');
        }
        return out.toOwnedSlice(allocator);
    }
};

test "movie round trip" {
    const allocator = std.testing.allocator;
    const text =
        \\# zmov 1
        \\# name: test
        \\
        \\SR
        \\B
        \\
        \\
    ;
    var movie = try Movie.parse(allocator, text);
    defer movie.deinit(allocator);
    try std.testing.expectEqual(@as(u32, 4), movie.len());
    try std.testing.expectEqual(@as(u16, 0), movie.buttons(0));
    try std.testing.expectEqual(@as(u16, 0x1100), movie.buttons(1)); // Start+Right
    try std.testing.expectEqual(@as(u16, 0x8000), movie.buttons(2)); // B
    try std.testing.expectEqual(@as(u16, 0), movie.buttons(3));
    try std.testing.expectEqual(@as(u16, 0), movie.buttons(100)); // past end

    const round = try movie.serialize(allocator, "test");
    defer allocator.free(round);
    var again = try Movie.parse(allocator, round);
    defer again.deinit(allocator);
    try std.testing.expectEqual(movie.len(), again.len());
    for (0..movie.len()) |i| {
        try std.testing.expectEqual(movie.buttons(@intCast(i)), again.buttons(@intCast(i)));
    }
}
