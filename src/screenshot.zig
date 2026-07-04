// Headless Screenshot Tool
//
// Runs a ROM for N frames with no window/GPU, then dumps the final
// framebuffer as a PPM image. This is the primary tool for automated
// visual inspection of emulator output: an agent (or a human in a hurry)
// can run a game to a known point and look at exactly what the PPU
// produced, without any windowing system involved.
//
// Usage:
//   screenshot <rom.sfc> <frames> <out.ppm> [--input frame:buttons ...]
//   screenshot <rom.sfc> <frames> <out.ppm> --every N <outdir>
//
// Input injection:
//   --input 120:S       press Start at frame 120 (held for 30 frames)
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
    var every: u32 = 0;
    var every_dir: []const u8 = "";
    var dump_path: ?[]const u8 = null;
    var wav_path: ?[]const u8 = null;
    var movie_path: ?[]const u8 = null;
    var record_path: ?[]const u8 = null;
    var tm_force: ?u8 = null;

    var i: usize = 4;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--input")) {
            i += 1;
            try inputs.append(allocator, try parseInputEvent(args[i]));
        } else if (std.mem.eql(u8, args[i], "--every")) {
            every = try std.fmt.parseInt(u32, args[i + 1], 10);
            every_dir = args[i + 2];
            i += 2;
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
    var recording: ?zupernes.movie.Movie = if (record_path != null)
        zupernes.movie.Movie{ .frames = .empty }
    else
        null;
    defer if (recording) |*m| m.deinit(allocator);

    // Audio capture: at 32kHz a frame is ~533 samples; collect them all
    var audio: std.ArrayListUnmanaged([2]i16) = .empty;
    defer audio.deinit(allocator);

    var frame: u32 = 0;
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
        }
        if (recording) |*m| {
            try m.frames.append(allocator, pad);
        }
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

        if (every != 0 and frame % every == 0) {
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
        const text = try recording.?.serialize(allocator, path);
        defer allocator.free(text);
        try std.fs.cwd().writeFile(.{ .sub_path = path, .data = text });
        std.debug.print("Recorded movie ({d} frames) to {s}\n", .{ recording.?.len(), path });
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
