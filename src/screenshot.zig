// Headless Screenshot Tool
//
// Runs a ROM for N frames with no window/GPU, then dumps the final
// framebuffer as a PPM image. This is the primary tool for automated
// visual inspection of emulator output: an agent (or a human in a hurry)
// can run a game to a known point and look at exactly what the PPU
// produced, without any windowing system involved.
//
// Usage:
//   screenshot <rom.sfc> <frames> <out.ppm> [options]
//   screenshot <rom.sfc> <frames> <out.ppm> --every N <outdir>
//
// Input injection:
//   --input 120:S       press Start at frame 120 (held for 30 frames)
//   --input-when 100=07:S[:HOLD[:SETTLE]]
//                         press when a WRAM predicate becomes true
//   Buttons: S=Start, s=Select, A/B/X/Y, U/D/L/R (dpad), l/r (shoulders)
//
// Movies (TAS format, see src/movie.zig):
//   --movie FILE         play back a .zmov movie (overrides --input)
//   --record-movie FILE  write the run's resolved per-frame inputs as .zmov
//   (--input + --record-movie converts an ad-hoc script into a movie)
//
// The PPM (P6) format is chosen because it needs no dependencies to
// write; convert to PNG with `sips -s format png out.ppm --out out.png`
// on macOS.

const std = @import("std");
const zupernes = @import("zupernes");
const Emulator = zupernes.Emulator;

const SCREEN_WIDTH = 256;
const SCREEN_HEIGHT = 224;

/// A scheduled input event: press `buttons` starting at `frame`,
/// hold for `hold` frames (default 30 ≈ half a second, enough for
/// any game's input polling to notice).
const InputEvent = struct {
    frame: u32,
    buttons: u16,
    hold: u32 = 30,
};

const WramPredicate = struct { addr: usize, value: u8 };

const InputWhenEvent = struct {
    predicates: []WramPredicate,
    buttons: u16,
    hold: u32 = 2,
    settle: u32 = 4,

    fn deinit(self: InputWhenEvent, allocator: std.mem.Allocator) void {
        allocator.free(self.predicates);
    }
};

/// Map a button character to its bit in the standard SNES joypad layout
/// (as read from $4218/$4219: BYsS UDLR AXlr ----, we store the full
/// 16-bit word with B in bit 15).
fn buttonBit(c: u8) ?u16 {
    return switch (c) {
        'B' => 0x8000, // B
        'Y' => 0x4000, // Y
        's' => 0x2000, // Select
        'S' => 0x1000, // Start
        'U' => 0x0800, // Up
        'D' => 0x0400, // Down
        'L' => 0x0200, // Left
        'R' => 0x0100, // Right
        'A' => 0x0080, // A
        'X' => 0x0040, // X
        'l' => 0x0020, // L shoulder
        'r' => 0x0010, // R shoulder
        else => null,
    };
}

fn parseInputEvent(spec: []const u8) !InputEvent {
    // FRAME:BTNS or FRAME:BTNS:HOLD (hold duration in frames, default 30)
    var it = std.mem.splitScalar(u8, spec, ':');
    const frame_s = it.next() orelse return error.BadInputSpec;
    const btns_s = it.next() orelse return error.BadInputSpec;
    const hold_s = it.next();
    var buttons: u16 = 0;
    for (btns_s) |c| {
        buttons |= buttonBit(c) orelse return error.BadButton;
    }
    return .{
        .frame = try std.fmt.parseInt(u32, frame_s, 10),
        .buttons = buttons,
        .hold = if (hold_s) |h| try std.fmt.parseInt(u32, h, 10) else 30,
    };
}

fn parseInputWhenEvent(allocator: std.mem.Allocator, spec: []const u8) !InputWhenEvent {
    var it = std.mem.splitScalar(u8, spec, ':');
    const pred_s = it.next() orelse return error.BadInputSpec;
    const btns_s = it.next() orelse return error.BadInputSpec;
    const hold_s = it.next();
    const settle_s = it.next();
    if (it.next() != null) return error.BadInputSpec;

    var list: std.ArrayListUnmanaged(WramPredicate) = .empty;
    errdefer list.deinit(allocator);
    var pred_it = std.mem.splitScalar(u8, pred_s, ',');
    while (pred_it.next()) |predicate| {
        const equal = std.mem.indexOfScalar(u8, predicate, '=') orelse return error.BadInputSpec;
        if (equal == 0 or equal + 1 == predicate.len) return error.BadInputSpec;
        const addr = try parseWramNumber(predicate[0..equal]);
        const value_num = try parseWramNumber(predicate[equal + 1 ..]);
        if (value_num > 0xFF) return error.BadInputSpec;
        const value: u8 = @intCast(value_num);
        if (addr >= 128 * 1024) return error.BadWramAddress;
        try list.append(allocator, .{ .addr = addr, .value = value });
    }
    if (list.items.len == 0) return error.BadInputSpec;
    var buttons: u16 = 0;
    for (btns_s) |c| buttons |= buttonBit(c) orelse return error.BadButton;
    return .{ .predicates = try list.toOwnedSlice(allocator), .buttons = buttons,
        .hold = if (hold_s) |h| try std.fmt.parseInt(u32, h, 10) else 2,
        .settle = if (settle_s) |s| try std.fmt.parseInt(u32, s, 10) else 4 };
}

fn parseWramNumber(text: []const u8) !u32 {
    const digits = if (std.mem.startsWith(u8, text, "0x") or std.mem.startsWith(u8, text, "0X")) text[2..]
        else if (std.mem.startsWith(u8, text, "$")) text[1..]
        else text;
    return try std.fmt.parseInt(u32, digits, 16);
}

fn predicatesMatch(event: InputWhenEvent, wram: []const u8) bool {
    for (event.predicates) |predicate| if (wram[predicate.addr] != predicate.value) return false;
    return true;
}

fn writePpm(framebuffer: []const u16, path: []const u8) !void {
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();

    var header_buf: [64]u8 = undefined;
    const header = try std.fmt.bufPrint(&header_buf, "P6\n{d} {d}\n255\n", .{ SCREEN_WIDTH, SCREEN_HEIGHT });
    try file.writeAll(header);

    // Convert 15-bit BGR (SNES CGRAM format: -bbbbbgg gggrrrrr) to RGB24.
    // The <<3 scaling leaves the low 3 bits at zero; that's fine for
    // inspection purposes (max value 0xF8 instead of 0xFF).
    var buffer: [SCREEN_WIDTH * SCREEN_HEIGHT * 3]u8 = undefined;
    for (0..framebuffer.len) |i| {
        const color = framebuffer[i];
        buffer[i * 3 + 0] = @truncate((color & 0x1F) << 3);
        buffer[i * 3 + 1] = @truncate(((color >> 5) & 0x1F) << 3);
        buffer[i * 3 + 2] = @truncate(((color >> 10) & 0x1F) << 3);
    }
    try file.writeAll(&buffer);
}

/// Reach the origin movie a validated sidecar names and return its first
/// `frame` inputs, or null when it cannot be reached or cannot be trusted.
///
/// This is what makes a resumed recording SELF-CONTAINED: with the origin's
/// prefix in hand the recorder can write one power-on movie instead of a tail
/// that only replays if a 412 KB blob travels beside it.
///
/// Every rejection here is deliberate and prints its reason. The alternative -
/// splicing whatever the path happens to point at - would silently produce a
/// movie whose prefix does not reach the state its tail assumes, which
/// replays as a plausible wrong run. That is the failure class the whole
/// provenance triple exists to close, so a doubtful splice must degrade to a
/// marked tail rather than a confident artifact.
fn originPrefix(
    allocator: std.mem.Allocator,
    state_path: []const u8,
    origin_file: []const u8,
    sha_hex: []const u8,
    frame: u32,
) !?[]u16 {
    // The writer stores a bare basename when the movie sat beside the state,
    // and the path as given otherwise. So a name with no separator resolves
    // against the STATE's directory - which is what keeps a state/sidecar/movie
    // trio working after it is moved as a group.
    var path_buf: [1024]u8 = undefined;
    const resolved = if (std.fs.path.dirname(origin_file) == null) blk: {
        const dir = std.fs.path.dirname(state_path) orelse ".";
        break :blk std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, origin_file }) catch return null;
    } else origin_file;

    const text = std.fs.cwd().readFileAlloc(allocator, resolved, 16 * 1024 * 1024) catch {
        std.debug.print("splice: origin movie {s} not readable; keeping the tail\n", .{resolved});
        return null;
    };
    defer allocator.free(text);

    // THE HASH IS AUTHORITATIVE, THE PATH IS ONLY A HINT. A file that has
    // been edited since the snapshot was taken no longer reaches that state,
    // and its inputs are exactly the wrong prefix to prepend.
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(text, &digest, .{});
    var hex: [64]u8 = undefined;
    _ = try std.fmt.bufPrint(&hex, "{x}", .{&digest});
    if (!std.ascii.eqlIgnoreCase(&hex, sha_hex)) {
        std.debug.print(
            "splice: {s} does not match the recorded origin hash; keeping the tail\n",
            .{resolved},
        );
        return null;
    }

    var origin = zupernes.movie.Movie.parse(allocator, text) catch {
        std.debug.print("splice: origin movie {s} does not parse; keeping the tail\n", .{resolved});
        return null;
    };
    defer origin.deinit(allocator);

    // A spliced movie claims to play from power-on. If the origin itself
    // resumed from a savestate, its frame 0 is not power-on and the claim
    // would be false. Refusing is honest; chaining back through a second
    // sidecar is a feature, not a silent assumption.
    if (origin.meta.start != .power_on) {
        std.debug.print(
            "splice: origin {s} is itself a savestate movie; keeping the tail\n",
            .{resolved},
        );
        return null;
    }
    if (origin.len() < frame) {
        std.debug.print(
            "splice: origin {s} has {d} frames, fewer than the snapshot frame {d}; keeping the tail\n",
            .{ resolved, origin.len(), frame },
        );
        return null;
    }

    // The state was written at the START of `frame`, before it ran, so
    // frames 0..frame-1 are exactly the inputs that reached it.
    return try allocator.dupe(u16, origin.frames.items[0..frame]);
}

// The Emulator struct is large (VRAM, WRAM, framebuffers...) and holds
// internal self-pointers, so it must live at a stable address — global,
// not on the stack.
var emulator: Emulator = undefined;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 4) {
        std.debug.print(
            \\Usage: screenshot <rom.sfc> <frames> <out.ppm> [options]
            \\Options:
            \\  --input F:BTNS   press buttons at frame F (e.g. 120:S for Start)
            \\  --input-when PRED[,PRED...]:BTNS[:HOLD[:SETTLE]]
            \\                   press once WRAM predicates hold, in declaration order
            \\                   (default HOLD is 2, SETTLE is 4; each trigger fires once)
            \\  --every N DIR    also dump a frame every N frames into DIR
            \\
        , .{});
        return error.BadArgs;
    }

    const rom_path = args[1];
    const total_frames = try std.fmt.parseInt(u32, args[2], 10);
    const out_path = args[3];

    var inputs: std.ArrayListUnmanaged(InputEvent) = .empty;
    defer inputs.deinit(allocator);
    var when_inputs: std.ArrayListUnmanaged(InputWhenEvent) = .empty;
    defer {
        for (when_inputs.items) |event| event.deinit(allocator);
        when_inputs.deinit(allocator);
    }
    var every: u32 = 0;
    var every_dir: []const u8 = "";
    var range_start: u32 = 0;
    var range_end: u32 = std.math.maxInt(u32);
    var dump_path: ?[]const u8 = null;
    var wav_path: ?[]const u8 = null;
    var movie_path: ?[]const u8 = null;
    var record_path: ?[]const u8 = null;
    const SaveStateSpec = struct { frame: u32, path: []const u8 };
    var save_state: ?SaveStateSpec = null;
    var load_state_path: ?[]const u8 = null;
    var start_state_sha: [64]u8 = undefined;
    var start_state_valid = false;
    var tm_force: ?u8 = null;
    var wram_path: ?[]const u8 = null;

    var i: usize = 4;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--input")) {
            i += 1;
            try inputs.append(allocator, try parseInputEvent(args[i]));
        } else if (std.mem.eql(u8, args[i], "--input-when")) {
            i += 1;
            try when_inputs.append(allocator, try parseInputWhenEvent(allocator, args[i]));
        } else if (std.mem.eql(u8, args[i], "--every")) {
            every = try std.fmt.parseInt(u32, args[i + 1], 10);
            every_dir = args[i + 2];
            i += 2;
        } else if (std.mem.eql(u8, args[i], "--range")) {
            // Restrict --every dumps to frames [A, B] (e.g. --range 3100:3300)
            i += 1;
            const sep = std.mem.indexOfScalar(u8, args[i], ':') orelse return error.BadArgs;
            range_start = try std.fmt.parseInt(u32, args[i][0..sep], 10);
            range_end = try std.fmt.parseInt(u32, args[i][sep + 1 ..], 10);
        } else if (std.mem.eql(u8, args[i], "--dump")) {
            i += 1;
            dump_path = args[i];
        } else if (std.mem.eql(u8, args[i], "--wav")) {
            i += 1;
            wav_path = args[i];
        } else if (std.mem.eql(u8, args[i], "--tm")) {
            i += 1;
            tm_force = try std.fmt.parseInt(u8, args[i], 0);
        } else if (std.mem.eql(u8, args[i], "--movie")) {
            i += 1;
            movie_path = args[i];
        } else if (std.mem.eql(u8, args[i], "--record-movie")) {
            i += 1;
            record_path = args[i];
        } else if (std.mem.eql(u8, args[i], "--load-state")) {
            i += 1;
            load_state_path = args[i];
        } else if (std.mem.eql(u8, args[i], "--save-state-at")) {
            // FRAME:FILE, matching the oracle recorder's --save-state. The
            // snapshot is taken at the START of FRAME, so resuming from it
            // and running FRAME onward reproduces the original run.
            i += 1;
            const spec = args[i];
            const colon = std.mem.indexOfScalar(u8, spec, ':') orelse return error.BadArgs;
            save_state = .{
                .frame = try std.fmt.parseInt(u32, spec[0..colon], 10),
                .path = spec[colon + 1 ..],
            };
        } else if (std.mem.eql(u8, args[i], "--dump-wram")) {
            // Write all 128KB of WRAM after the final frame - the
            // cross-emulator debugging workhorse: diff against a Mesen2
            // Lua dump of the same frame to find diverging game state.
            i += 1;
            wram_path = args[i];
        } else {
            std.debug.print("Unknown option: {s}\n", .{args[i]});
            return error.BadArgs;
        }
    }

    const file = try std.fs.cwd().openFile(rom_path, .{});
    defer file.close();
    const rom_data = try file.readToEndAlloc(allocator, 16 * 1024 * 1024);
    defer allocator.free(rom_data);

    emulator = Emulator.init();
    emulator.setup();
    try emulator.loadRom(rom_data);
    emulator.ppu.tm_force = tm_force;

    var playback: ?zupernes.movie.Movie = null;
    defer if (playback) |*m| m.deinit(allocator);
    if (movie_path) |path| {
        const text = try std.fs.cwd().readFileAlloc(allocator, path, 16 * 1024 * 1024);
        defer allocator.free(text);
        playback = try zupernes.movie.Movie.parse(allocator, text);
        std.debug.print("Playing movie: {s} ({d} frames)\n", .{ path, playback.?.len() });
    }
    // A savestate start REPLACES power-on, so it must happen before any frame
    // runs, before recording is armed, and before a snapshot could be taken.
    // Through Emulator.readStateFile - the same call the interactive frontend
    // makes - so a headless resume and an interactive one cannot drift.
    // The sidecar's text is borrowed by the parsed struct, so it has to
    // outlive the record block far below rather than the load block here.
    var sidecar_text: ?[]u8 = null;
    defer if (sidecar_text) |t| allocator.free(t);
    var sidecar: ?zupernes.Emulator.savestate.Sidecar = null;
    if (load_state_path) |path| {
        const snapshot = emulator.readStateFile(allocator, path, &start_state_sha) catch |err| {
            std.debug.print("Savestate {s} rejected: {}\n", .{ path, err });
            return err;
        };
        allocator.free(snapshot);
        start_state_valid = true;
        std.debug.print("Resumed from savestate: {s}\n", .{path});

        // READ BACK THE PROVENANCE THE WRITER ALREADY WROTE. Without this a
        // recording made from a resume carries `start` and `start-sha256`
        // but not `start-origin` - two thirds of the triple, and
        // unregenerable by the format's own definition.
        var side_name_buf: [512]u8 = undefined;
        const side_name = try std.fmt.bufPrint(&side_name_buf, "{s}.origin", .{path});
        if (std.fs.cwd().readFileAlloc(allocator, side_name, 64 * 1024)) |text| {
            sidecar_text = text;
            const parsed = zupernes.Emulator.savestate.Sidecar.parse(text);
            // A sidecar is a claim ABOUT A SPECIFIC FILE. If its hash does
            // not match the state we actually loaded, it describes some
            // other snapshot that once had this name, and every field in it
            // is suspect - so it is discarded whole rather than mined for
            // the parts that look plausible.
            const claims_this_state = if (parsed.start_sha256) |h|
                std.ascii.eqlIgnoreCase(h, &start_state_sha)
            else
                false;
            if (claims_this_state) {
                sidecar = parsed;
            } else {
                std.debug.print(
                    "Sidecar {s} describes a different savestate (hash mismatch); ignoring it\n",
                    .{side_name},
                );
            }
        } else |_| {
            // No sidecar is not an error: a hand-made state legitimately has
            // none. It only means any recording from it cannot claim to be
            // regenerable, which the record path states explicitly.
        }
    }

    // Recording uses the EMULATOR's capture API, not a parallel accumulation
    // of the pad we are about to set. Those are not the same thing: setJoypad
    // masks the low nibble (the $4218 layout has no bits there), so appending
    // `pad` records a value the machine may never have held. Sampling where
    // Emulator.recordInputs samples - the frame boundary, the same point
    // replay's setJoypad writes - is what makes a headless recording and an
    // interactive one the same artifact rather than two lookalikes.
    var record_buffer: []u16 = &.{};
    defer if (record_buffer.len != 0) allocator.free(record_buffer);
    if (record_path != null) {
        record_buffer = try allocator.alloc(u16, total_frames);
        emulator.recordInputs(record_buffer);
    }

    // Audio capture: at 32kHz a frame is ~533 samples; collect them all
    var audio: std.ArrayListUnmanaged([2]i16) = .empty;
    defer audio.deinit(allocator);

    var frame: u32 = 0;
    var when_index: usize = 0;
    var when_requires_false = false;
    var when_settled: u32 = 0;
    var when_release_at: ?u32 = null;
    var when_active_until = try allocator.alloc(u32, when_inputs.items.len);
    defer allocator.free(when_active_until);
    @memset(when_active_until, 0);
    while (frame < total_frames) : (frame += 1) {
        // Input priority: movie playback, else the --input schedule
        // (overlapping events OR together)
        var pad: u16 = 0;
        if (playback) |*m| {
            pad = m.buttons(frame);
        } else {
            for (inputs.items) |ev| {
                if (frame >= ev.frame and frame < ev.frame + ev.hold) {
                    pad |= ev.buttons;
                }
            }
            // A trigger's hold is followed by one unconditional neutral
            // frame.  SMW's ControllerUpdate turns that edge into the
            // released/just-pressed distinction used by menu code; without
            // it, back-to-back event presses can be observed as one press.
            const when_is_release_frame = if (when_release_at) |release_at| frame == release_at else false;
            if (!when_is_release_frame) {
                for (when_inputs.items, 0..) |event, event_index| {
                    if (frame < when_active_until[event_index]) pad |= event.buttons;
                }
            }
            if (when_index < when_inputs.items.len) {
                const event = when_inputs.items[when_index];
                const matches = predicatesMatch(event, emulator.bus.wram[0..]);
                if (when_is_release_frame) {
                    // Do not even arm the next event during the neutral edge.
                    when_settled = 0;
                } else if (when_requires_false) {
                    if (!matches) {
                        when_requires_false = false;
                        when_settled = 0;
                    }
                } else if (!matches) {
                    when_settled = 0;
                } else if (event.settle != 0 and when_settled + 1 < event.settle) {
                    when_settled += 1;
                } else if (matches) {
                    pad |= event.buttons;
                    when_active_until[when_index] = frame +| event.hold;
                    // The neutral edge follows the held interval. A zero
                    // hold still gets a released frame on the next frame.
                    when_release_at = frame +| @max(event.hold, 1);
                    std.debug.print("input-when trigger {d} at frame {d}\n", .{ when_index, frame });
                    when_index += 1;
                    when_settled = 0;
                    // If the next predicate is already true, require it
                    // to go false before firing: a generic leave-and-
                    // return wait, without game-specific knowledge.
                    if (when_index < when_inputs.items.len) {
                        when_requires_false = predicatesMatch(when_inputs.items[when_index], emulator.bus.wram[0..]);
                    }
                }
            }
            if (when_is_release_frame) when_release_at = null;
        }
        if (save_state) |spec| if (frame == spec.frame) {
            // At the START of the frame, before it runs: resuming here and
            // running FRAME onward reproduces the original run exactly.
            const bytes = try allocator.alloc(u8, zupernes.Emulator.state_len);
            defer allocator.free(bytes);
            _ = try emulator.writeState(bytes);
            try std.fs.cwd().writeFile(.{ .sub_path = spec.path, .data = bytes });

            // THE PROVENANCE TRIPLE, BY CONSTRUCTION. A savestate on its own
            // is 412 KB with no story; these three facts make it
            // REGENERABLE - replay that movie to that frame and the bytes
            // must equal this hash. Written as a sidecar beside the state so
            // it cannot drift from the file it describes, and emitted here
            // rather than by the caller because only this code knows all
            // three at once.
            //
            // origin is the movie ACTUALLY PLAYED. Without one there is no
            // regenerable claim to make, and an unverifiable provenance is
            // worse than an absent one - so the field is omitted, not faked.
            var state_digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(bytes, &state_digest, .{});
            var origin_buf: [1024]u8 = undefined;
            const origin_text = if (movie_path) |mp| blk: {
                const movie_text = try std.fs.cwd().readFileAlloc(allocator, mp, 16 * 1024 * 1024);
                defer allocator.free(movie_text);
                var movie_digest: [32]u8 = undefined;
                std.crypto.hash.sha2.Sha256.hash(movie_text, &movie_digest, .{});
                // origin-file makes the origin REACHABLE, not merely named.
                // The hash identifies the movie but cannot locate it, and a
                // recorder that wants to splice the origin's inputs in front
                // of a resumed tail has to open the file. Stored relative to
                // the sidecar when they sit together, so the pair can be
                // moved without breaking the link; the hash stays
                // authoritative, so a stale path fails the check rather than
                // silently splicing the wrong prefix.
                const side_dir = std.fs.path.dirname(spec.path) orelse ".";
                const rel = if (std.mem.eql(u8, std.fs.path.dirname(mp) orelse ".", side_dir))
                    std.fs.path.basename(mp)
                else
                    mp;
                break :blk try std.fmt.bufPrint(&origin_buf, "origin-file: {s}\nstart-origin: {x}:{d}\n", .{ rel, &movie_digest, spec.frame });
            } else try std.fmt.bufPrint(&origin_buf, "start-origin: none (no --movie; this snapshot is not regenerable)\n", .{});

            var side_buf: [1024]u8 = undefined;
            const sidecar_body = try std.fmt.bufPrint(&side_buf, "start-sha256: {x}\nframe: {d}\n{s}", .{ &state_digest, spec.frame, origin_text });
            var side_name_buf: [512]u8 = undefined;
            const side_name = try std.fmt.bufPrint(&side_name_buf, "{s}.origin", .{spec.path});
            try std.fs.cwd().writeFile(.{ .sub_path = side_name, .data = sidecar_body });
            std.debug.print("Saved state at frame {d} to {s} (+ {s})\n", .{ spec.frame, spec.path, side_name });
        };
        emulator.setJoypad(0, pad);

        emulator.runFrame();

        if (wav_path != null) {
            var chunk: [2048][2]i16 = undefined;
            while (true) {
                const n = emulator.readAudioSamples(&chunk);
                if (n == 0) break;
                try audio.appendSlice(allocator, chunk[0..n]);
            }
        }

        if (every != 0 and frame % every == 0 and frame >= range_start and frame <= range_end) {
            var path_buf: [512]u8 = undefined;
            const path = try std.fmt.bufPrint(&path_buf, "{s}/frame_{d:0>5}.ppm", .{ every_dir, frame });
            try writePpm(emulator.getFramebuffer(), path);
        }
    }

    try writePpm(emulator.getFramebuffer(), out_path);
    std.debug.print("Wrote {s} after {d} frames\n", .{ out_path, total_frames });

    if (dump_path) |path| {
        try dumpState(path);
        std.debug.print("Wrote PPU state dump to {s}\n", .{path});
    }

    if (record_path) |path| {
        emulator.stopRecording();
        const frames = emulator.recordedInputs();
        if (emulator.recordedInputsDropped() != 0) {
            // Cannot happen with a buffer sized to total_frames, but a
            // truncated recording presented as whole is the failure this
            // counter exists to make impossible.
            std.debug.print(
                "record: TRUNCATED - {d} frames dropped; refusing to write {s}\n",
                .{ emulator.recordedInputsDropped(), path },
            );
            return error.RecordingTruncated;
        }
        var m = zupernes.movie.Movie{ .frames = .empty };
        defer m.deinit(allocator);
        try m.frames.appendSlice(allocator, frames);
        // A recording declares the ROM it was made against and its own frame
        // count, exactly like the interactive path - a headless recording
        // that omitted them would be the legal-but-unpinned artifact that
        // reopens the wrong-ROM class through the back door.
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(rom_data, &digest, .{});
        var rom_hex: [64]u8 = undefined;
        _ = try std.fmt.bufPrint(&rom_hex, "{x}", .{&digest});
        m.meta.rom_sha256 = &rom_hex;
        m.meta.recorded_frames = @intCast(frames.len);
        var spliced_buf: [160]u8 = undefined;
        if (load_state_path) |sp| {
            // start-origin is still never INVENTED here - this run was handed
            // a state and cannot know how it was reached. It is now READ, from
            // the .origin sidecar that `--save-state-at` wrote and that was
            // hash-checked against the state actually loaded. The claim is
            // still the writer's; what changed is that the reader stopped
            // throwing it away.
            const claim = if (sidecar) |sc| sc.originParts() else null;

            // PREFERRED OUTCOME: splice, and emit one self-contained movie.
            const prefix: ?[]u16 = if (claim) |c| blk: {
                const of = (sidecar.?.origin_file) orelse {
                    std.debug.print(
                        "splice: sidecar names no origin-file (written before that key); keeping the tail\n",
                        .{},
                    );
                    break :blk null;
                };
                break :blk originPrefix(allocator, sp, of, c.sha, c.frame) catch null;
            } else null;
            defer if (prefix) |p| allocator.free(p);

            if (prefix) |p| {
                // One movie: the origin's inputs 0..N-1, then this run's tail.
                // It starts at power-on because the prefix is present, so it
                // needs no savestate beside it - which is the whole point.
                try m.frames.insertSlice(allocator, 0, p);
                m.meta.recorded_frames = @intCast(m.frames.items.len);
                m.meta.spliced_origin = try std.fmt.bufPrint(
                    &spliced_buf,
                    "{s}:{d}",
                    .{ claim.?.sha, claim.?.frame },
                );
                std.debug.print(
                    "record: spliced {d} origin frames + {d} recorded = {d}; movie is self-contained\n",
                    .{ p.len, frames.len, m.frames.items.len },
                );
            } else {
                // FALLBACK: the tail stays, and says exactly what it is.
                m.meta.start = .savestate;
                // The format says start-file is RELATIVE TO THE .ZMOV. Writing
                // the absolute path we happened to be invoked with would bake
                // this machine's layout into a shareable artifact - the same
                // leak as passing the output path as the movie's name. When
                // the snapshot sits beside the recording, the basename is the
                // whole answer.
                m.meta.start_file = if (std.mem.eql(u8, std.fs.path.dirname(sp) orelse ".", std.fs.path.dirname(path) orelse "."))
                    std.fs.path.basename(sp)
                else
                    sp;
                if (start_state_valid) m.meta.start_sha256 = &start_state_sha;

                if (claim) |c| {
                    // THE STAMP. The triple is complete even unspliced: the
                    // origin movie is named by hash and frame, so the state
                    // this tail assumes can be regenerated by whoever holds
                    // that movie. Locating it is a lookup, not a guess.
                    m.meta.start_origin = try std.fmt.bufPrint(
                        &spliced_buf,
                        "{s}:{d}",
                        .{ c.sha, c.frame },
                    );
                } else {
                    // No claim exists to stamp. Say so in the artifact rather
                    // than leaving a reader to infer it from a missing key -
                    // omitted, not faked, but also not silent.
                    m.meta.non_regenerable = if (sidecar == null)
                        "no .origin sidecar beside the savestate"
                    else
                        "sidecar records no origin movie (snapshot taken without --movie)";
                }
            }
        }
        // No name: the old call passed the OUTPUT PATH as the movie's name,
        // baking an absolute local path into an artifact meant to be shared.
        // The metadata above says what the file is; the path says only where
        // this machine happened to put it.
        const text = try m.serialize(allocator, null);
        defer allocator.free(text);
        try std.fs.cwd().writeFile(.{ .sub_path = path, .data = text });
        std.debug.print("Recorded movie ({d} frames) to {s}\n", .{ m.len(), path });
    }

    if (wram_path) |path| {
        try std.fs.cwd().writeFile(.{ .sub_path = path, .data = &emulator.bus.wram });
        std.debug.print("Wrote WRAM (128KB) to {s}\n", .{path});
    }


    if (wav_path) |path| {
        try writeWav(path, audio.items);
        std.debug.print("Wrote {d} audio frames ({d:.1}s) to {s}\n", .{
            audio.items.len,
            @as(f64, @floatFromInt(audio.items.len)) / 32000.0,
            path,
        });
    }
}

/// Write captured audio as a standard 16-bit stereo 32kHz WAV file.
fn writeWav(path: []const u8, frames: []const [2]i16) !void {
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();

    const data_bytes: u32 = @intCast(frames.len * 4);
    var header: [44]u8 = undefined;
    @memcpy(header[0..4], "RIFF");
    std.mem.writeInt(u32, header[4..8], 36 + data_bytes, .little);
    @memcpy(header[8..12], "WAVE");
    @memcpy(header[12..16], "fmt ");
    std.mem.writeInt(u32, header[16..20], 16, .little); // fmt chunk size
    std.mem.writeInt(u16, header[20..22], 1, .little); // PCM
    std.mem.writeInt(u16, header[22..24], 2, .little); // stereo
    std.mem.writeInt(u32, header[24..28], 32000, .little); // sample rate
    std.mem.writeInt(u32, header[28..32], 32000 * 4, .little); // byte rate
    std.mem.writeInt(u16, header[32..34], 4, .little); // block align
    std.mem.writeInt(u16, header[34..36], 16, .little); // bits per sample
    @memcpy(header[36..40], "data");
    std.mem.writeInt(u32, header[40..44], data_bytes, .little);
    try file.writeAll(&header);
    try file.writeAll(std.mem.sliceAsBytes(frames));
}

/// Dump complete PPU state (registers + VRAM + CGRAM + OAM) to a file for
/// offline analysis. Format: text header with register values, then raw
/// binary sections. This lets us inspect exactly what the game put in
/// video memory at any point, and diff against known-good emulators.
fn dumpState(path: []const u8) !void {
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();

    const ppu = &emulator.ppu;
    var buf: [4096]u8 = undefined;
    const header = try std.fmt.bufPrint(&buf,
        \\ZUPERNES-DUMP-V1
        \\frame={d}
        \\inidisp={x:0>2} bgmode={x:0>2} mosaic={x:0>2}
        \\bg1sc={x:0>2} bg2sc={x:0>2} bg3sc={x:0>2} bg4sc={x:0>2}
        \\bg12nba={x:0>2} bg34nba={x:0>2}
        \\bg1hofs={d} bg1vofs={d} bg2hofs={d} bg2vofs={d}
        \\bg3hofs={d} bg3vofs={d} bg4hofs={d} bg4vofs={d}
        \\tm={x:0>2} ts={x:0>2} tmw={x:0>2} tsw={x:0>2}
        \\cgwsel={x:0>2} cgadsub={x:0>2}
        \\w12sel={x:0>2} w34sel={x:0>2} wobjsel={x:0>2}
        \\wh0={d} wh1={d} wh2={d} wh3={d}
        \\obsel={x:0>2}
        \\BINARY: vram[65536] cgram[512] oam[544]
        \\
    , .{
        ppu.frame_count,
        ppu.inidisp,       ppu.bgmode,   ppu.mosaic,
        ppu.bg1sc,         ppu.bg2sc,    ppu.bg3sc,    ppu.bg4sc,
        ppu.bg12nba,       ppu.bg34nba,
        ppu.bg1hofs,       ppu.bg1vofs,  ppu.bg2hofs,  ppu.bg2vofs,
        ppu.bg3hofs,       ppu.bg3vofs,  ppu.bg4hofs,  ppu.bg4vofs,
        ppu.tm,            ppu.ts,       ppu.tmw,      ppu.tsw,
        ppu.cgwsel,        ppu.cgadsub,
        ppu.w12sel,        ppu.w34sel,   ppu.wobjsel,
        ppu.wh0,           ppu.wh1,      ppu.wh2,      ppu.wh3,
        ppu.obsel,
    });
    try file.writeAll(header);
    try file.writeAll(&ppu.vram);
    try file.writeAll(&ppu.cgram);
    try file.writeAll(&ppu.oam);
}
