// =============================================================================
// SAVESTATE VERIFIER - proves a resumed run is bit-identical to a
// from-power-on run of the same input.
// =============================================================================
// A savestate that silently diverges would poison every recording built on it,
// so the capability is not usable until this passes. The check is deliberately
// the strongest available shape:
//
//   A: power-on -> run to `frames`, taking a full snapshot after every frame.
//   B: power-on -> run to `snapshot_frame`, snapshot, restore that snapshot
//      into a SEPARATE emulator instance, then run to `frames`.
//
// After each frame past the snapshot point, A's and B's COMPLETE machine
// states are compared byte for byte - not just the framebuffer, and not just
// the final frame - so the first frame at which the two diverge is reported
// rather than a bare pass/fail at the end. "Complete" here is the savestate
// itself, which is every pointer-free byte the machine owns: CPU, PPU
// (including VRAM/CGRAM/OAM/framebuffer and the intra-frame position), WRAM,
// cartridge SRAM, DMA, APU (SPC700 RAM + DSP) and the DSP-1 registers.
//
// Restoring into a separate instance is the point: it proves the format
// carries the state rather than accidentally relying on the origin machine's
// memory still being there.
//
// Usage:
//   savestate-verify <rom.sfc> <frames> <snapshot_frame> [--movie FILE]
//                    [--inject-divergence N]
//
// Exit code 0 means bit-identical for every compared frame.
//
// --inject-divergence N perturbs byte N of the snapshot before restoring it,
// so the run MUST fail. It exists because a check that cannot fail proves
// nothing: it demonstrates that this verifier actually detects a machine that
// resumed wrong, rather than passing because it compares nothing.
// =============================================================================

const std = @import("std");
const zupernes = @import("zupernes");
const Emulator = zupernes.Emulator;

// The Emulator is far too large for the stack (VRAM + WRAM + framebuffer +
// APU RAM); both instances live in the binary's data segment.
var emu_a: Emulator = undefined;
var emu_b: Emulator = undefined;

const magic_len = Emulator.savestate.magic.len;

fn padFor(playback: ?*const zupernes.movie.Movie, frame: u32) u16 {
    if (playback) |m| return m.buttons(frame);
    return 0;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len < 4) {
        std.debug.print(
            "Usage: savestate-verify <rom.sfc> <frames> <snapshot_frame> [--movie FILE]\n",
            .{},
        );
        return error.BadArgs;
    }
    const rom_path = args[1];
    const total_frames = try std.fmt.parseInt(u32, args[2], 10);
    const snapshot_frame = try std.fmt.parseInt(u32, args[3], 10);
    if (snapshot_frame >= total_frames) {
        std.debug.print("snapshot_frame must be < frames\n", .{});
        return error.BadArgs;
    }

    var movie_path: ?[]const u8 = null;
    var inject: ?usize = null;
    var i: usize = 4;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--movie") and i + 1 < args.len) {
            i += 1;
            movie_path = args[i];
        } else if (std.mem.eql(u8, args[i], "--inject-divergence") and i + 1 < args.len) {
            i += 1;
            inject = try std.fmt.parseInt(usize, args[i], 10);
        } else {
            std.debug.print("Unknown option: {s}\n", .{args[i]});
            return error.BadArgs;
        }
    }

    const rom_data = try std.fs.cwd().readFileAlloc(allocator, rom_path, 16 * 1024 * 1024);
    defer allocator.free(rom_data);

    var playback: ?zupernes.movie.Movie = null;
    defer if (playback) |*m| m.deinit(allocator);
    if (movie_path) |path| {
        const text = try std.fs.cwd().readFileAlloc(allocator, path, 16 * 1024 * 1024);
        defer allocator.free(text);
        playback = try zupernes.movie.Movie.parse(allocator, text);
    }
    const pb: ?*const zupernes.movie.Movie = if (playback) |*m| m else null;

    const snap = try allocator.alloc(u8, Emulator.state_len);
    defer allocator.free(snap);
    const state_a = try allocator.alloc(u8, Emulator.state_len);
    defer allocator.free(state_a);
    const state_b = try allocator.alloc(u8, Emulator.state_len);
    defer allocator.free(state_b);

    // ---- A: power-on, run to the snapshot point, capture ----
    emu_a = Emulator.init();
    emu_a.setup();
    try emu_a.loadRom(rom_data);

    var frame: u32 = 0;
    while (frame < snapshot_frame) : (frame += 1) {
        emu_a.setJoypad(0, padFor(pb, frame));
        emu_a.runFrame();
    }
    _ = try emu_a.writeState(snap);

    if (inject) |off| {
        // Deliberately corrupt the snapshot so the comparison below MUST
        // fail. Proves the verifier has teeth. Skips the magic header so the
        // failure is a real state divergence rather than a rejected load.
        const at = magic_len + (off % (Emulator.state_len - magic_len));
        snap[at] +%= 1;
        std.debug.print("injected divergence at snapshot byte {d}\n", .{at});
    }

    // ---- B: a SEPARATE machine restored from that snapshot ----
    emu_b = Emulator.init();
    emu_b.setup();
    try emu_b.loadRom(rom_data);
    _ = try emu_b.readState(snap);

    // The restore must reproduce the origin machine exactly, before either
    // side runs another instruction.
    _ = try emu_a.writeState(state_a);
    _ = try emu_b.writeState(state_b);
    if (!std.mem.eql(u8, state_a, state_b)) {
        const off = firstDiff(state_a, state_b);
        std.debug.print(
            "FAIL: restored state differs from origin at frame {d}, byte offset {d} ({x:0>2} vs {x:0>2})\n",
            .{ snapshot_frame, off, state_a[off], state_b[off] },
        );
        std.process.exit(1);
    }

    // ---- lockstep to the end, comparing the whole machine each frame ----
    while (frame < total_frames) : (frame += 1) {
        const pad = padFor(pb, frame);
        emu_a.setJoypad(0, pad);
        emu_a.runFrame();
        emu_b.setJoypad(0, pad);
        emu_b.runFrame();

        _ = try emu_a.writeState(state_a);
        _ = try emu_b.writeState(state_b);
        if (!std.mem.eql(u8, state_a, state_b)) {
            const off = firstDiff(state_a, state_b);
            std.debug.print(
                "FAIL: first divergence at frame {d}, byte offset {d} ({x:0>2} vs {x:0>2})\n",
                .{ frame + 1, off, state_a[off], state_b[off] },
            );
            std.process.exit(1);
        }
    }

    std.debug.print(
        "OK: resumed run is bit-identical to the from-power-on run\n" ++
            "  rom            {s}\n" ++
            "  frames         {d}\n" ++
            "  snapshot at    {d}\n" ++
            "  compared       {d} frames, {d} bytes of machine state each\n",
        .{ rom_path, total_frames, snapshot_frame, total_frames - snapshot_frame, Emulator.state_len },
    );
}

fn firstDiff(a: []const u8, b: []const u8) usize {
    for (a, 0..) |byte, idx| if (byte != b[idx]) return idx;
    return a.len;
}
