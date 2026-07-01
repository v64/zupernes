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
    const colon = std.mem.indexOfScalar(u8, spec, ':') orelse return error.BadInputSpec;
    const frame = try std.fmt.parseInt(u32, spec[0..colon], 10);
    var buttons: u16 = 0;
    for (spec[colon + 1 ..]) |c| {
        buttons |= buttonBit(c) orelse return error.BadButton;
    }
    return .{ .frame = frame, .buttons = buttons };
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

    var i: usize = 4;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--input")) {
            i += 1;
            try inputs.append(allocator, try parseInputEvent(args[i]));
        } else if (std.mem.eql(u8, args[i], "--every")) {
            every = try std.fmt.parseInt(u32, args[i + 1], 10);
            every_dir = args[i + 2];
            i += 2;
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

    var frame: u32 = 0;
    while (frame < total_frames) : (frame += 1) {
        // Apply any scheduled input for this frame. Multiple overlapping
        // events OR together.
        var pad: u16 = 0;
        for (inputs.items) |ev| {
            if (frame >= ev.frame and frame < ev.frame + ev.hold) {
                pad |= ev.buttons;
            }
        }
        emulator.setJoypad(0, pad);

        emulator.runFrame();

        if (every != 0 and frame % every == 0) {
            var path_buf: [512]u8 = undefined;
            const path = try std.fmt.bufPrint(&path_buf, "{s}/frame_{d:0>5}.ppm", .{ every_dir, frame });
            try writePpm(emulator.getFramebuffer(), path);
        }
    }

    try writePpm(emulator.getFramebuffer(), out_path);
    std.debug.print("Wrote {s} after {d} frames\n", .{ out_path, total_frames });
}
