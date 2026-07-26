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
//   - Lines starting with '#' are comments/metadata, and must all precede
//     the first frame line so a reader can stop scanning. Recognized keys:
//
//       # zmov 1
//       # rom-sha256: <64 hex>   content hash of the ROM this was recorded
//                                against. ENFORCED WHEN PRESENT by whoever
//                                replays it - a recording always writes one
//                                and so cannot be replayed against the wrong
//                                ROM, while a hand-authored movie without one
//                                keeps working unchanged.
//       # start: power-on        default, and the pre-existing contract; or
//       # start: savestate       with the three keys below.
//       # start-file: <path>     savestate, relative to the .zmov
//       # start-sha256: <64 hex> hash of that savestate file
//       # start-origin: <movie-sha256>:<frame>
//                                how the savestate was REACHED. A savestate
//                                on its own is bytes with no story; this
//                                makes it regenerable - replay that movie to
//                                that frame and the bytes must equal
//                                start-sha256 - which is the difference
//                                between trusting a blob and checking it.
//       # recorded-frames: <N>   the recorder's own count, a truncation
//                                cross-check against the parsed frame total.
//       # name: <title>
//
//     UNKNOWN keys are ignored, so the format keeps extending without
//     breaking readers. `# controllers: 2` is reserved and unimplemented:
//     the frame lines below are controller 1 only.
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

/// How a movie's frame 0 is reached.
pub const Start = enum { power_on, savestate };

/// The parsed `#` header. Every field is optional because a hand-authored
/// movie may carry none of them; consumers decide what they require. Slices
/// borrow the parsed text and stay valid as long as it does.
pub const Meta = struct {
    rom_sha256: ?[]const u8 = null,
    start: Start = .power_on,
    start_file: ?[]const u8 = null,
    start_sha256: ?[]const u8 = null,
    /// `<movie-sha256>:<frame>` verbatim; `startOriginFrame` splits it.
    start_origin: ?[]const u8 = null,
    /// `<movie-sha256>:<N>` — this movie's first N frames were COPIED from
    /// that origin movie, and frame N is where the resumed tail begins. Set
    /// only on a spliced recording, which starts at power-on precisely
    /// because the prefix is present: it needs no external savestate.
    spliced_origin: ?[]const u8 = null,
    /// Why this recording cannot be regenerated, when it cannot. Present
    /// only in that case; a reader that sees it knows the artifact is a
    /// tail whose starting state has no checkable story.
    non_regenerable: ?[]const u8 = null,
    recorded_frames: ?u32 = null,
    name: ?[]const u8 = null,

    /// The frame half of `start-origin`, or null if absent/malformed.
    pub fn startOriginFrame(self: Meta) ?u32 {
        const origin = self.start_origin orelse return null;
        const colon = std.mem.lastIndexOfScalar(u8, origin, ':') orelse return null;
        return std.fmt.parseInt(u32, origin[colon + 1 ..], 10) catch null;
    }

    /// The movie-hash half of `start-origin`, or null if absent/malformed.
    pub fn startOriginMovie(self: Meta) ?[]const u8 {
        const origin = self.start_origin orelse return null;
        const colon = std.mem.lastIndexOfScalar(u8, origin, ':') orelse return null;
        return origin[0..colon];
    }
};

pub const Movie = struct {
    /// Buttons held on each frame (controller 1), index = frame number.
    frames: std.ArrayListUnmanaged(u16),
    /// Parsed `#` header. Borrows the text passed to `parse`.
    meta: Meta = .{},

    pub fn deinit(self: *Movie, allocator: std.mem.Allocator) void {
        self.frames.deinit(allocator);
    }

    /// A recording's ROM hash must match the ROM about to run it. Returns
    /// true when the movie declares no hash - hand-authored movies predate
    /// the key and stay usable; only a movie that DOES declare one is held
    /// to it. Callers report; this only decides.
    pub fn romMatches(self: *const Movie, rom_sha256_hex: []const u8) bool {
        const declared = self.meta.rom_sha256 orelse return true;
        return std.ascii.eqlIgnoreCase(declared, rom_sha256_hex);
    }

    /// Input for a frame; frames past the end of the movie are no-input.
    pub fn buttons(self: *const Movie, frame: u32) u16 {
        if (frame >= self.frames.items.len) return 0;
        return self.frames.items[frame];
    }

    pub fn len(self: *const Movie) u32 {
        return @intCast(self.frames.items.len);
    }

    /// One `# key: value` header line. Unrecognized keys and bare comments
    /// are ignored rather than rejected, so the format extends without
    /// breaking readers; a malformed value for a KNOWN key is left null
    /// rather than failing the parse, because a movie's frames are usable
    /// even when its provenance is not.
    fn readMetaLine(self: *Movie, line: []const u8) void {
        const body = std.mem.trim(u8, line[1..], " \t");
        const colon = std.mem.indexOfScalar(u8, body, ':') orelse return;
        const key = std.mem.trim(u8, body[0..colon], " \t");
        const value = std.mem.trim(u8, body[colon + 1 ..], " \t");
        if (value.len == 0) return;
        if (std.mem.eql(u8, key, "rom-sha256")) {
            self.meta.rom_sha256 = value;
        } else if (std.mem.eql(u8, key, "start")) {
            if (std.mem.eql(u8, value, "power-on")) {
                self.meta.start = .power_on;
            } else if (std.mem.eql(u8, value, "savestate")) {
                self.meta.start = .savestate;
            }
        } else if (std.mem.eql(u8, key, "start-file")) {
            self.meta.start_file = value;
        } else if (std.mem.eql(u8, key, "start-sha256")) {
            self.meta.start_sha256 = value;
        } else if (std.mem.eql(u8, key, "start-origin")) {
            self.meta.start_origin = value;
        } else if (std.mem.eql(u8, key, "spliced-origin")) {
            self.meta.spliced_origin = value;
        } else if (std.mem.eql(u8, key, "non-regenerable")) {
            self.meta.non_regenerable = value;
        } else if (std.mem.eql(u8, key, "recorded-frames")) {
            self.meta.recorded_frames = std.fmt.parseInt(u32, value, 10) catch null;
        } else if (std.mem.eql(u8, key, "name")) {
            self.meta.name = value;
        }
    }

    /// Parse .zmov text. The returned Meta borrows `text`.
    pub fn parse(allocator: std.mem.Allocator, text: []const u8) !Movie {
        var movie = Movie{ .frames = .empty };
        errdefer movie.deinit(allocator);

        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len > 0 and line[0] == '#') {
                movie.readMetaLine(line);
                continue;
            }
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
    /// `name` overrides `meta.name` when given, so existing callers keep
    /// their one-argument behaviour.
    pub fn serialize(self: *const Movie, allocator: std.mem.Allocator, name: ?[]const u8) ![]u8 {
        var out = std.ArrayListUnmanaged(u8).empty;
        errdefer out.deinit(allocator);
        try out.appendSlice(allocator, "# zmov 1\n");
        // The whole header precedes the first frame line, per the format.
        if (self.meta.rom_sha256) |v| {
            try out.appendSlice(allocator, "# rom-sha256: ");
            try out.appendSlice(allocator, v);
            try out.append(allocator, '\n');
        }
        if (self.meta.start == .savestate) {
            // Only stated when it is not the default, so a power-on movie
            // serializes exactly as it did before this key existed.
            try out.appendSlice(allocator, "# start: savestate\n");
            if (self.meta.start_file) |v| {
                try out.appendSlice(allocator, "# start-file: ");
                try out.appendSlice(allocator, v);
                try out.append(allocator, '\n');
            }
            if (self.meta.start_sha256) |v| {
                try out.appendSlice(allocator, "# start-sha256: ");
                try out.appendSlice(allocator, v);
                try out.append(allocator, '\n');
            }
            if (self.meta.start_origin) |v| {
                try out.appendSlice(allocator, "# start-origin: ");
                try out.appendSlice(allocator, v);
                try out.append(allocator, '\n');
            }
        }
        // Both of these describe a POWER-ON movie, so they sit outside the
        // savestate block above. A spliced recording carries its prefix in
        // its own frame list and needs no start-file to replay.
        if (self.meta.spliced_origin) |v| {
            try out.appendSlice(allocator, "# spliced-origin: ");
            try out.appendSlice(allocator, v);
            try out.append(allocator, '\n');
        }
        if (self.meta.non_regenerable) |v| {
            try out.appendSlice(allocator, "# non-regenerable: ");
            try out.appendSlice(allocator, v);
            try out.append(allocator, '\n');
        }
        if (self.meta.recorded_frames) |n| {
            try out.print(allocator, "# recorded-frames: {d}\n", .{n});
        }
        if (name orelse self.meta.name) |n| {
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

test "metadata parses, round-trips, and stays optional" {
    const allocator = std.testing.allocator;
    const text =
        \\# zmov 1
        \\# rom-sha256: 0123456789ABCDEF
        \\# start: savestate
        \\# start-file: prefix.zst
        \\# start-sha256: deadbeef
        \\# start-origin: cafebabe:1018
        \\# recorded-frames: 2
        \\# name: recorded
        \\# a bare comment with no colon
        \\# unknown-key: ignored
        \\R
        \\B
        \\
    ;
    var movie = try Movie.parse(allocator, text);
    defer movie.deinit(allocator);
    try std.testing.expectEqual(@as(u32, 2), movie.len());
    try std.testing.expectEqualStrings("0123456789ABCDEF", movie.meta.rom_sha256.?);
    try std.testing.expectEqual(Start.savestate, movie.meta.start);
    try std.testing.expectEqualStrings("prefix.zst", movie.meta.start_file.?);
    try std.testing.expectEqualStrings("cafebabe", movie.meta.startOriginMovie().?);
    try std.testing.expectEqual(@as(u32, 1018), movie.meta.startOriginFrame().?);
    try std.testing.expectEqual(@as(u32, 2), movie.meta.recorded_frames.?);
    try std.testing.expectEqualStrings("recorded", movie.meta.name.?);

    // The header survives a round trip, keys and frames both.
    const round = try movie.serialize(allocator, null);
    defer allocator.free(round);
    var again = try Movie.parse(allocator, round);
    defer again.deinit(allocator);
    try std.testing.expectEqual(movie.len(), again.len());
    try std.testing.expectEqualStrings("0123456789ABCDEF", again.meta.rom_sha256.?);
    try std.testing.expectEqual(Start.savestate, again.meta.start);
    try std.testing.expectEqualStrings("cafebabe:1018", again.meta.start_origin.?);
    try std.testing.expectEqual(@as(u32, 2), again.meta.recorded_frames.?);
}

test "a movie with no metadata still parses, and a power-on movie serializes unchanged" {
    // The compatibility promise: every committed .zmov predates these keys.
    const allocator = std.testing.allocator;
    const text =
        \\# zmov 1
        \\# name: legacy
        \\R
        \\
    ;
    var movie = try Movie.parse(allocator, text);
    defer movie.deinit(allocator);
    try std.testing.expectEqual(Start.power_on, movie.meta.start);
    try std.testing.expect(movie.meta.rom_sha256 == null);
    const round = try movie.serialize(allocator, null);
    defer allocator.free(round);
    try std.testing.expectEqualStrings("# zmov 1\n# name: legacy\nR\n", round);
}

test "rom hash is enforced when declared and permissive when absent" {
    const allocator = std.testing.allocator;
    var declared = try Movie.parse(allocator, "# zmov 1\n# rom-sha256: abc123\nR\n");
    defer declared.deinit(allocator);
    try std.testing.expect(declared.romMatches("abc123"));
    try std.testing.expect(declared.romMatches("ABC123")); // hex case is not identity
    try std.testing.expect(!declared.romMatches("999999"));

    var silent = try Movie.parse(allocator, "# zmov 1\nR\n");
    defer silent.deinit(allocator);
    try std.testing.expect(silent.romMatches("anything at all"));
}
