// =============================================================================
// TIMING TRACE - the ZuperNES side of the ordered-timing cross-oracle
// =============================================================================
// Runs a ROM from power-on on the ORDERED wall owner (src/refresh_timing.zig)
// and writes a TSV of bus events at the same instants Mesen2's Lua callbacks
// report them (see Bus.TimingProbeKind), with the same columns the Mesen
// probe scripts write:
//
//   event  address  value  master  line  hclock
//
// `master` is the absolute wall master clock since power-on (Mesen2's
// masterClock), `line`/`hclock` the PPU beam at that instant. Because both
// sides start from the same power-on origin - 186 startup masters before the
// first opcode fetch (Emulator.power_on_startup_masters) - absolute values are
// directly comparable, not just intervals.
//
// Usage:
//   timing-trace <rom.sfc> <out.tsv> [--frames N] [--exec LO HI]
//
//   --frames N     stop after N frames (default 3)
//   --exec LO HI   record opcode fetches with 24-bit PC in [LO, HI] (hex);
//                  without it no exec rows are written
//
// Every CPU write, DMA/HDMA read and write, interrupt entry, and frame start
// is recorded. test/timing/cross_oracle.mjs runs this and Mesen on the same
// copyright-free probe ROMs and compares the event streams.
// =============================================================================

const std = @import("std");
const zupernes = @import("zupernes");
const Emulator = zupernes.Emulator;
const Bus = zupernes.Bus;

const Recorder = struct {
    emu: *Emulator,
    out: std.ArrayListUnmanaged(u8) = .empty,
    allocator: std.mem.Allocator,
    exec_lo: u24 = 1,
    exec_hi: u24 = 0, // empty range by default

    fn row(self: *Recorder, event: []const u8, addr: u24, value: u8) void {
        const emu = self.emu;
        const hclock = @as(u32, emu.ppu.dot) * 4 + emu.ppu.master_accum;
        self.out.print(self.allocator, "{s}\t{x:0>6}\t{x:0>2}\t{d}\t{d}\t{d}\n", .{
            event, addr, value, emu.refresh_timeline.wall_master, emu.ppu.scanline, hclock,
        }) catch @panic("out of memory");
    }

    fn record(context: *anyopaque, kind: zupernes.TimingProbeKind, addr: u24, value: u8) void {
        const self: *Recorder = @ptrCast(@alignCast(context));
        switch (kind) {
            .exec => if (addr >= self.exec_lo and addr <= self.exec_hi) self.row("exec", addr, value),
            .cpu_read => {}, // voluminous; add a filter here when a probe needs it
            .cpu_write => self.row("cpu_write", addr, value),
            .dma_read => self.row("dma_read", addr, value),
            .dma_write => self.row("dma_write", addr, value),
            .irq_entry => self.row("irq_entry", addr, value),
            .nmi_entry => self.row("nmi_entry", addr, value),
        }
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len < 3) {
        std.debug.print("usage: timing-trace <rom.sfc> <out.tsv> [--frames N] [--exec LO HI]\n", .{});
        return error.BadArgs;
    }

    var frames: u64 = 3;
    var exec_lo: u24 = 1;
    var exec_hi: u24 = 0;
    var i: usize = 3;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--frames")) {
            i += 1;
            frames = try std.fmt.parseInt(u64, args[i], 10);
        } else if (std.mem.eql(u8, args[i], "--exec")) {
            exec_lo = try std.fmt.parseInt(u24, args[i + 1], 16);
            exec_hi = try std.fmt.parseInt(u24, args[i + 2], 16);
            i += 2;
        } else return error.BadArgs;
    }

    const rom = try std.fs.cwd().readFileAlloc(allocator, args[1], 16 * 1024 * 1024);
    defer allocator.free(rom);

    // Emulator is large and self-referential (bus -> ppu, cpu -> bus): give
    // it a stable heap address before setup wires the pointers.
    const emu = try allocator.create(Emulator);
    defer allocator.destroy(emu);
    emu.* = Emulator.init();
    emu.setup();
    try emu.loadRom(rom);

    var recorder = Recorder{ .emu = emu, .allocator = allocator, .exec_lo = exec_lo, .exec_hi = exec_hi };
    defer recorder.out.deinit(allocator);
    try recorder.out.appendSlice(allocator, "event\taddress\tvalue\tmaster\tline\thclock\n");
    emu.bus.timing_probe = .{ .context = &recorder, .record = Recorder.record };

    // Frame 0 begins at wall 0 by definition (before the startup clocks).
    try recorder.out.appendSlice(allocator, "frame_start\t000000\t00\t0\t0\t0\n");
    emu.enableOrderedClockFromPowerOn();
    var last_frame = emu.ppu.frame_count;
    while (emu.ppu.frame_count < frames) {
        emu.step();
        if (emu.ppu.frame_count != last_frame) {
            last_frame = emu.ppu.frame_count;
            // The beam has already moved past the line-0 origin inside this
            // step; report the field's start at its own origin instant.
            const start = emu.ppu.frameStartMaster();
            recorder.out.print(allocator, "frame_start\t000000\t00\t{d}\t0\t0\n", .{start}) catch unreachable;
        }
    }

    const file = try std.fs.cwd().createFile(args[2], .{});
    defer file.close();
    try file.writeAll(recorder.out.items);
}
