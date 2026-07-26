// =============================================================================
// RECORDING VERIFIER - proves a recorded run replays to the same machine.
// =============================================================================
// The acceptance test for the recording path (round 82 item 1). A recording
// that does not replay exactly is worse than no recording: it looks like
// evidence and is not. So the check is the strongest available shape, the
// same one savestate_verify uses:
//
//   A: run a scripted input schedule with Emulator.recordInputs armed,
//      snapshotting the complete machine after every frame.
//   B: serialize A's capture to .zmov text, parse it BACK, and drive a
//      SEPARATE emulator with movie.buttons(f) - the ordinary replay path,
//      not a shortcut through A's in-memory buffer.
//
// After every frame the two machines' COMPLETE states are compared byte for
// byte - CPU, PPU (VRAM/CGRAM/OAM/framebuffer and intra-frame position),
// WRAM, cartridge SRAM, DMA, APU and the DSP-1 registers - so the first
// divergent frame is reported rather than a bare verdict at the end.
//
// Going through the TEXT is the point. It proves the recorder samples where
// replay writes, and that the format carries the run; a comparison against
// the capture buffer would prove neither.
//
// Usage:
//   record-verify <rom.sfc> <frames> [--seed N] [--inject-divergence FRAME]
//
// Exit code 0 means bit-identical for every frame.
//
// --inject-divergence FRAME corrupts one frame of the parsed movie before
// replaying, so the run MUST fail. A check that cannot fail proves nothing.
// =============================================================================

const std = @import("std");
const zupernes = @import("zupernes");
const Emulator = zupernes.Emulator;

/// A deterministic, varied input schedule. Real play is what the frontend
/// records; this needs to exercise button changes at every cadence including
/// held-across-frames and single-frame taps, without depending on a game.
fn scheduledPad(frame: u32, seed: u32) u16 {
    var x: u32 = frame *% 2654435761 +% seed;
    x ^= x >> 13;
    x *%= 1274126177;
    x ^= x >> 16;
    // Hold a button across several frames roughly half the time, so the
    // capture is not just uncorrelated noise.
    const held: u16 = if ((frame / 7) % 2 == 0) 0x0100 else 0;
    return (@as(u16, @truncate(x)) & 0xFFF0) | held;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len < 3) {
        std.debug.print(
            "Usage: record-verify <rom.sfc> <frames> [--seed N] [--inject-divergence FRAME]\n",
            .{},
        );
        return error.BadArgs;
    }
    const rom_path = args[1];
    const frames = try std.fmt.parseInt(u32, args[2], 10);
    var seed: u32 = 1;
    var inject: ?u32 = null;
    var i: usize = 3;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--seed")) {
            i += 1;
            seed = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, args[i], "--inject-divergence")) {
            i += 1;
            inject = try std.fmt.parseInt(u32, args[i], 10);
        } else {
            std.debug.print("Unknown option: {s}\n", .{args[i]});
            return error.BadArgs;
        }
    }

    const rom = try std.fs.cwd().readFileAlloc(allocator, rom_path, 16 * 1024 * 1024);
    defer allocator.free(rom);

    var rom_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(rom, &rom_digest, .{});
    var rom_hex: [64]u8 = undefined;
    _ = try std.fmt.bufPrint(&rom_hex, "{x}", .{rom_digest});

    // ---- A: record ----
    const capture = try allocator.alloc(u16, frames);
    defer allocator.free(capture);
    const a_states = try allocator.alloc(u8, @as(usize, frames) * Emulator.state_len);
    defer allocator.free(a_states);

    const emu_a = try allocator.create(Emulator);
    defer allocator.destroy(emu_a);
    emu_a.* = Emulator.init();
    emu_a.setup();
    try emu_a.loadRom(rom);
    emu_a.recordInputs(capture);
    for (0..frames) |f| {
        emu_a.setJoypad(0, scheduledPad(@intCast(f), seed));
        emu_a.runFrame();
        _ = try emu_a.writeState(a_states[f * Emulator.state_len ..][0..Emulator.state_len]);
    }
    emu_a.stopRecording();
    if (emu_a.recordedInputsDropped() != 0) {
        std.debug.print("FAIL: capture truncated, {d} frames dropped\n", .{emu_a.recordedInputsDropped()});
        std.process.exit(1);
    }
    if (emu_a.recordedInputs().len != frames) {
        std.debug.print(
            "FAIL: recorded {d} frames, expected {d}\n",
            .{ emu_a.recordedInputs().len, frames },
        );
        std.process.exit(1);
    }

    // ---- the artifact, through the text ----
    var recorded = zupernes.movie.Movie{ .frames = .empty };
    defer recorded.deinit(allocator);
    try recorded.frames.appendSlice(allocator, emu_a.recordedInputs());
    recorded.meta.rom_sha256 = &rom_hex;
    recorded.meta.recorded_frames = frames;
    const text = try recorded.serialize(allocator, "record-verify");
    defer allocator.free(text);

    var replay = try zupernes.movie.Movie.parse(allocator, text);
    defer replay.deinit(allocator);
    if (!replay.romMatches(&rom_hex)) {
        std.debug.print("FAIL: the recording's rom-sha256 does not match the ROM it was made from\n", .{});
        std.process.exit(1);
    }
    if (replay.meta.recorded_frames != frames) {
        std.debug.print("FAIL: recorded-frames says {?d}, capture has {d}\n", .{ replay.meta.recorded_frames, frames });
        std.process.exit(1);
    }
    if (replay.len() != frames) {
        std.debug.print("FAIL: parsed {d} frame lines, expected {d}\n", .{ replay.len(), frames });
        std.process.exit(1);
    }
    if (inject) |at| {
        if (at < replay.len()) {
            replay.frames.items[at] ^= 0x0100;
            std.debug.print("(injected a divergence into replay frame {d})\n", .{at});
        }
    }

    // ---- B: replay into a separate machine ----
    const emu_b = try allocator.create(Emulator);
    defer allocator.destroy(emu_b);
    emu_b.* = Emulator.init();
    emu_b.setup();
    try emu_b.loadRom(rom);
    const b_state = try allocator.alloc(u8, Emulator.state_len);
    defer allocator.free(b_state);

    for (0..frames) |f| {
        emu_b.setJoypad(0, replay.buttons(@intCast(f)));
        emu_b.runFrame();
        _ = try emu_b.writeState(b_state);
        const a_state = a_states[f * Emulator.state_len ..][0..Emulator.state_len];
        if (!std.mem.eql(u8, a_state, b_state)) {
            var at: usize = 0;
            while (at < b_state.len and a_state[at] == b_state[at]) at += 1;
            std.debug.print(
                "FAIL: frame {d} differs (first differing byte {d}: recorded ${x:0>2}, replayed ${x:0>2})\n",
                .{ f, at, a_state[at], b_state[at] },
            );
            std.process.exit(1);
        }
    }

    std.debug.print(
        "OK: {d} frames recorded, serialized, reparsed and replayed bit-identical\n",
        .{frames},
    );
}
