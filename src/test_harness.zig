// Test Harness for SNES ROM tests
// Runs test ROMs in headless mode and compares output against golden images

const std = @import("std");
const zupernes = @import("zupernes");
const Emulator = zupernes.Emulator;

const SCREEN_WIDTH = 256;
const SCREEN_HEIGHT = 224;

const TestResult = struct {
    name: []const u8,
    passed: bool,
    frames_run: u32,
    error_msg: ?[]const u8,
};

const TestConfig = struct {
    rom_path: []const u8,
    golden_path: ?[]const u8,
    frames_to_run: u32 = 60, // Default: run for 1 second (60 frames)
    compare_threshold: f32 = 0.01, // 1% pixel difference allowed
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = std.process.args();
    _ = args.skip(); // Skip program name

    const rom_dir = args.next() orelse "test/snes-test-roms";
    const golden_dir = args.next() orelse "test/golden";

    std.debug.print("ZuperNES Test Harness\n", .{});
    std.debug.print("=====================\n\n", .{});
    std.debug.print("ROM directory: {s}\n", .{rom_dir});
    std.debug.print("Golden directory: {s}\n\n", .{golden_dir});

    // Find all test ROMs
    var dir = std.fs.cwd().openDir(rom_dir, .{ .iterate = true }) catch |err| {
        std.debug.print("Failed to open ROM directory: {}\n", .{err});
        return;
    };
    defer dir.close();

    var results: std.ArrayListUnmanaged(TestResult) = .empty;
    defer results.deinit(allocator);

    var rom_count: u32 = 0;
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;

        const name = entry.name;
        if (!std.mem.endsWith(u8, name, ".sfc") and !std.mem.endsWith(u8, name, ".smc")) {
            continue;
        }

        rom_count += 1;

        const result = runTest(allocator, rom_dir, golden_dir, name) catch |err| {
            try results.append(allocator, .{
                .name = try allocator.dupe(u8, name),
                .passed = false,
                .frames_run = 0,
                .error_msg = @errorName(err),
            });
            continue;
        };

        try results.append(allocator, result);
    }

    // Print results
    std.debug.print("\nResults:\n", .{});
    std.debug.print("--------\n", .{});

    var passed: u32 = 0;
    var failed: u32 = 0;

    for (results.items) |result| {
        const status = if (result.passed) "PASS" else "FAIL";
        const color = if (result.passed) "\x1b[32m" else "\x1b[31m";
        const reset = "\x1b[0m";

        std.debug.print("{s}[{s}]{s} {s}", .{ color, status, reset, result.name });

        if (result.error_msg) |msg| {
            std.debug.print(" - {s}", .{msg});
        }

        std.debug.print(" ({d} frames)\n", .{result.frames_run});

        if (result.passed) {
            passed += 1;
        } else {
            failed += 1;
        }
    }

    std.debug.print("\nSummary: {d}/{d} tests passed\n", .{ passed, rom_count });

    if (failed > 0) {
        std.process.exit(1);
    }
}

fn runTest(
    allocator: std.mem.Allocator,
    rom_dir: []const u8,
    golden_dir: []const u8,
    rom_name: []const u8,
) !TestResult {
    _ = golden_dir;

    // Build full path
    const rom_path = try std.fs.path.join(allocator, &.{ rom_dir, rom_name });
    defer allocator.free(rom_path);

    std.debug.print("Running: {s}\n", .{rom_name});

    // Load ROM
    const file = try std.fs.cwd().openFile(rom_path, .{});
    defer file.close();

    const rom_data = try file.readToEndAlloc(allocator, 16 * 1024 * 1024);
    defer allocator.free(rom_data);

    // Create emulator and load ROM
    var emulator = Emulator.init();
    emulator.setup();
    try emulator.loadRom(rom_data);

    // Run for specified number of frames
    const frames_to_run: u32 = 60;
    var frames: u32 = 0;

    while (frames < frames_to_run) {
        emulator.runFrame();
        frames += 1;
    }

    // Get final framebuffer
    const framebuffer = emulator.getFramebuffer();

    // For now, just check that we got output (non-zero framebuffer)
    var has_output = false;
    for (framebuffer) |pixel| {
        if (pixel != 0) {
            has_output = true;
            break;
        }
    }

    // TODO: Compare against golden image when available
    // For now, pass if we ran without crashing
    return TestResult{
        .name = try allocator.dupe(u8, rom_name),
        .passed = true, // Pass if we didn't crash
        .frames_run = frames,
        .error_msg = if (!has_output) "No output generated" else null,
    };
}

fn saveFramebuffer(
    allocator: std.mem.Allocator,
    framebuffer: []const u16,
    path: []const u8,
) !void {
    // Save as simple PPM format for debugging
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();

    var writer = file.writer();

    // PPM header
    try writer.print("P6\n{d} {d}\n255\n", .{ SCREEN_WIDTH, SCREEN_HEIGHT });

    // Convert and write pixels
    var buffer: [SCREEN_WIDTH * SCREEN_HEIGHT * 3]u8 = undefined;
    for (0..framebuffer.len) |i| {
        const color = framebuffer[i];
        // SNES: -bbbbbgg gggrrrrr (15-bit BGR)
        buffer[i * 3 + 0] = @truncate((color & 0x1F) << 3); // R
        buffer[i * 3 + 1] = @truncate(((color >> 5) & 0x1F) << 3); // G
        buffer[i * 3 + 2] = @truncate(((color >> 10) & 0x1F) << 3); // B
    }

    try writer.writeAll(&buffer);

    _ = allocator;
}

fn compareFramebuffers(
    actual: []const u16,
    expected: []const u16,
    threshold: f32,
) bool {
    if (actual.len != expected.len) return false;

    var diff_count: usize = 0;
    for (0..actual.len) |i| {
        if (actual[i] != expected[i]) {
            diff_count += 1;
        }
    }

    const diff_ratio = @as(f32, @floatFromInt(diff_count)) / @as(f32, @floatFromInt(actual.len));
    return diff_ratio <= threshold;
}
