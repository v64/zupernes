// Per-frame WRAM logger for game-level timing comparisons against Mesen2.
//
// Built against ANY ZuperNES tree (it uses only Emulator.init/setup/loadRom/
// runFrame and bus.wram, which the pinned oracle also has), so the same
// logger measures the pin, the candidate's aggregate path and the ordered
// profile:
//
//   zig build-exe -OReleaseFast --dep zupernes -Mroot=test/timing/frame_log.zig \
//     --dep build_options -Mzupernes=<tree>/src/root.zig -Mbuild_options=<options.zig>
//   frame_log <rom> <frames> <out.tsv> [--ordered] [--dump-every N] ADDR...
//
// --dump-every N also writes the full 128 KiB WRAM at the start of every
// Nth frame to <out.tsv>.<frame>.wram (compare with the Mesen side).
//
// Each row: frame index (the frame that just STARTED, matching Mesen2's
// startFrame event), then the hex byte at each WRAM ADDR (hex, $7E bank).
const std = @import("std");
const zupernes = @import("zupernes");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const rom = try std.fs.cwd().readFileAlloc(allocator, args[1], 16 * 1024 * 1024);
    defer allocator.free(rom);
    const frames = try std.fmt.parseInt(u32, args[2], 10);
    var ordered = false;
    var dump_every: u32 = 0;
    var addrs: std.ArrayListUnmanaged(u32) = .empty;
    defer addrs.deinit(allocator);
    var ai: usize = 4;
    while (ai < args.len) : (ai += 1) {
        const a = args[ai];
        if (std.mem.eql(u8, a, "--ordered")) {
            ordered = true;
        } else if (std.mem.eql(u8, a, "--dump-every")) {
            ai += 1;
            dump_every = try std.fmt.parseInt(u32, args[ai], 10);
        } else try addrs.append(allocator, try std.fmt.parseInt(u32, a, 16));
    }

    const emu = try allocator.create(zupernes.Emulator);
    defer allocator.destroy(emu);
    emu.* = zupernes.Emulator.init();
    emu.setup();
    try emu.loadRom(rom);
    if (ordered) {
        if (@hasDecl(zupernes.Emulator, "enableOrderedClockFromPowerOn")) {
            emu.enableOrderedClockFromPowerOn();
        } else return error.NoOrderedProfile;
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    for (1..frames + 1) |f| {
        emu.runFrame();
        try out.print(allocator, "{d}", .{f});
        for (addrs.items) |a| try out.print(allocator, "\t{x:0>2}", .{emu.bus.wram[a & 0x1FFFF]});
        try out.append(allocator, '\n');
        if (dump_every != 0 and f % dump_every == 0) {
            var name_buf: [512]u8 = undefined;
            const name = try std.fmt.bufPrint(&name_buf, "{s}.{d}.wram", .{ args[3], f });
            const dump = try std.fs.cwd().createFile(name, .{});
            defer dump.close();
            try dump.writeAll(&emu.bus.wram);
        }
    }
    const file = try std.fs.cwd().createFile(args[3], .{});
    defer file.close();
    try file.writeAll(out.items);
}
