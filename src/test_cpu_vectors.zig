// =============================================================================
// 65816 TEST-VECTOR HARNESS (SingleStepTests)
// =============================================================================
// Runs the CPU against the SingleStepTests 65816 vectors (the successor to
// TomHarte's ProcessorTests): 10,000 generated tests per opcode, each
// giving complete initial and final machine state (registers + every RAM
// cell touched). This converts "plays games correctly" into "every
// instruction formally verified" - the trust level the ZuperWorld oracle
// role demands.
//
// Vectors: https://github.com/SingleStepTests/65816 (v1/*.json, one file
// per opcode+mode: "69.n.json" = ADC immediate, native mode; ".e." =
// emulation mode). Download separately; they are NOT in the repo.
//
// Usage:
//   zig build cpu-vectors -- <dir-with-json> [opcode-filter] [--max-fail N]
//
// We verify FINAL STATE (registers + RAM), not per-cycle bus activity -
// the CPU is instruction-granular. Cycle-count mismatches are tallied
// separately as timing telemetry, never as failures.
//
// CYCLE-SEQUENCE AUDIT (--cycles): the vectors also list every bus cycle
// with its VDA/VPA and read/write outputs. On the 5A22 that fixes each
// cycle's SNES cost: a read or write with a valid address runs at that
// address's memory speed (6/8/12 masters); a cycle with neither VDA nor VPA
// is a six-master internal cycle (Mesen2 SnesCpu::Idle). The one exception
// is the emulation-mode read-modify-write dummy write, which the vectors
// show with VDA=0 but Mesen performs as a real memory-speed write
// (IdleOrDummyWrite) - so every write is classed as a write.
//
// The CPU's own sequence comes from the ordered-clock hook every CPU cycle
// already reports through (Bus.advanceCpuPhase): read_leading = one read,
// write = one write, every internal/IdleOrRead phase = one internal cycle,
// plus the instruction's unflushed trailing internal cycles. Comparing the
// two sequences per test finds missing, extra and MISPLACED internal
// cycles, which a count alone cannot.
// =============================================================================

const std = @import("std");
const zupernes = @import("zupernes");

var bus_backing: zupernes.Bus = undefined;
var cpu_backing: zupernes.Cpu = undefined;

/// Cycle sequence reported by the CPU through the ordered-clock hook:
/// 'R' read, 'W' write, 'I' internal, with each access's master speed.
const CycleRecorder = struct {
    kinds: [512]u8 = undefined,
    speeds: [512]u8 = undefined,
    len: usize = 0,

    fn push(self: *CycleRecorder, kind: u8, speed: u32) void {
        if (self.len == self.kinds.len) return; // block-move bundles cap far below this
        self.kinds[self.len] = kind;
        self.speeds[self.len] = @intCast(speed);
        self.len += 1;
    }

    fn advance(context: *anyopaque, masters: u32, phase: zupernes.CpuClockPhase) void {
        const self: *CycleRecorder = @ptrCast(@alignCast(context));
        switch (phase) {
            .read_leading => self.push('R', masters + 4),
            .read_trailing => {},
            .write => self.push('W', masters),
            else => self.push('I', masters),
        }
    }
};
var recorder = CycleRecorder{};

/// Tally of one (expected -> actual) cycle-pattern disagreement.
const Pattern = struct { count: u64, example: []const u8 };

const Summary = struct {
    passed: u64 = 0,
    failed: u64 = 0,
    cycle_mismatch: u64 = 0,
    // --cycles only
    seq_checked: u64 = 0,
    seq_mismatch: u64 = 0,
    speed_mismatch: u64 = 0,
};

var cycle_mode = false;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len < 2) {
        std.debug.print("Usage: cpu-vectors <dir> [substring-filter] [--max-fail N]\n", .{});
        return error.BadArgs;
    }
    const dir_path = args[1];
    var filter: ?[]const u8 = null;
    var max_fail_shown: u32 = 3;
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--max-fail")) {
            i += 1;
            max_fail_shown = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, args[i], "--cycles")) {
            cycle_mode = true;
        } else {
            filter = args[i];
        }
    }

    // Flat 16MB memory the vectors assume
    const flat = try allocator.alloc(u8, 16 * 1024 * 1024);
    defer allocator.free(flat);
    @memset(flat, 0);

    bus_backing = zupernes.Bus.init(undefined); // PPU never touched in flat mode
    bus_backing.flat_mem = flat;
    cpu_backing = zupernes.Cpu.init(&bus_backing);
    if (cycle_mode) {
        // Install ONLY the CPU phase hook: no DMA hook and no PPU sink. The
        // recorder observes the CPU's own cycle stream and nothing else.
        bus_backing.ordered_clock_context = &recorder;
        bus_backing.ordered_clock_advance = CycleRecorder.advance;
    }

    var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
    defer dir.close();

    // Collect and sort file names for deterministic order
    var names = std.ArrayListUnmanaged([]u8).empty;
    defer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".json")) continue;
        if (filter) |f| {
            if (std.mem.indexOf(u8, entry.name, f) == null) continue;
        }
        try names.append(allocator, try allocator.dupe(u8, entry.name));
    }
    std.mem.sort([]u8, names.items, {}, struct {
        fn lt(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);

    var grand = Summary{};
    var failed_files: u32 = 0;
    for (names.items) |name| {
        var file_patterns = std.StringHashMap(Pattern).init(allocator);
        defer {
            var kit = file_patterns.iterator();
            while (kit.next()) |kv| {
                allocator.free(kv.key_ptr.*);
                allocator.free(kv.value_ptr.example);
            }
            file_patterns.deinit();
        }
        const summary = runFile(allocator, dir, name, flat, max_fail_shown, &file_patterns) catch |err| {
            std.debug.print("{s}: ERROR {s}\n", .{ name, @errorName(err) });
            continue;
        };
        grand.passed += summary.passed;
        grand.failed += summary.failed;
        grand.cycle_mismatch += summary.cycle_mismatch;
        grand.seq_checked += summary.seq_checked;
        grand.seq_mismatch += summary.seq_mismatch;
        grand.speed_mismatch += summary.speed_mismatch;
        if (cycle_mode and summary.seq_mismatch + summary.speed_mismatch > 0) {
            std.debug.print("CYCLES {s}: {d}/{d} sequence mismatches, {d} speed mismatches\n", .{ name, summary.seq_mismatch, summary.seq_checked, summary.speed_mismatch });
            // Top three expected->actual patterns for this opcode/mode.
            for (0..3) |_| {
                var best_key: []const u8 = "";
                var best_val: ?*Pattern = null;
                var kit = file_patterns.iterator();
                while (kit.next()) |kv| {
                    if (kv.value_ptr.count == 0) continue;
                    if (best_val == null or kv.value_ptr.count > best_val.?.count) {
                        best_val = kv.value_ptr;
                        best_key = kv.key_ptr.*;
                    }
                }
                const b = best_val orelse break;
                std.debug.print("    {d:>6}x  {s}   e.g. {s}\n", .{ b.count, best_key, b.example });
                b.count = 0;
            }
        }
        if (summary.failed > 0) {
            failed_files += 1;
            std.debug.print("{s}: {d}/{d} FAILED (cycle mismatches: {d})\n", .{ name, summary.failed, summary.passed + summary.failed, summary.cycle_mismatch });
        }
    }
    std.debug.print(
        "\nTOTAL: {d} passed, {d} failed across {d} files ({d} files with failures); cycle-count mismatches: {d}\n",
        .{ grand.passed, grand.failed, names.items.len, failed_files, grand.cycle_mismatch },
    );
    if (cycle_mode) {
        std.debug.print("CYCLE SEQUENCES: {d}/{d} match exactly; {d} sequence mismatches, {d} speed mismatches\n", .{
            grand.seq_checked - grand.seq_mismatch - grand.speed_mismatch, grand.seq_checked, grand.seq_mismatch, grand.speed_mismatch,
        });
    }
    if (grand.failed > 0) std.process.exit(1);
}

fn getInt(obj: std.json.ObjectMap, key: []const u8) i64 {
    return obj.get(key).?.integer;
}

fn runFile(allocator: std.mem.Allocator, dir: std.fs.Dir, name: []const u8, flat: []u8, max_fail_shown: u32, patterns: *std.StringHashMap(Pattern)) !Summary {
    const data = try dir.readFileAlloc(allocator, name, 64 * 1024 * 1024);
    defer allocator.free(data);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), data, .{});

    var summary = Summary{};
    var shown: u32 = 0;

    for (parsed.array.items) |test_val| {
        const t = test_val.object;
        const initial = t.get("initial").?.object;
        const final = t.get("final").?.object;

        // ---- Apply initial state ----
        const cpu = &cpu_backing;
        cpu.pc = @intCast(getInt(initial, "pc"));
        cpu.sp = @intCast(getInt(initial, "s"));
        cpu.a = @intCast(getInt(initial, "a"));
        cpu.x = @intCast(getInt(initial, "x"));
        cpu.y = @intCast(getInt(initial, "y"));
        cpu.dbr = @intCast(getInt(initial, "dbr"));
        cpu.dp = @intCast(getInt(initial, "d"));
        cpu.pbr = @intCast(getInt(initial, "pbr"));
        cpu.p = zupernes.CpuFlags.fromByte(@intCast(getInt(initial, "p")));
        cpu.emulation_mode = getInt(initial, "e") != 0;
        cpu.nmi_pending = false;
        cpu.irq_pending = false;
        cpu.waiting = false;

        const init_ram = initial.get("ram").?.array;
        for (init_ram.items) |cell| {
            const pair = cell.array;
            flat[@intCast(pair.items[0].integer)] = @intCast(pair.items[1].integer);
        }

        // ---- Execute one instruction ----
        // Block moves (MVN $54 / MVP $44) execute one byte per step with
        // the PC rewinding; the vectors bundle up to 14 iterations (their
        // cycle trace caps at 100 = 14*7+2) and snapshot MID-instruction,
        // so we iterate to match and exempt PC when the move is incomplete.
        const opcode = flat[(@as(usize, cpu.pbr) << 16) | cpu.pc];
        const is_block_move = opcode == 0x44 or opcode == 0x54;
        recorder.len = 0;
        var cycles_taken: u32 = cpu.step();
        if (cycle_mode) appendTrailingInternal(cpu);
        var pc_exempt = false;
        if (is_block_move) {
            const iterations = t.get("cycles").?.array.items.len / 7;
            var done: usize = 1;
            while (cpu.a != 0xFFFF and done < iterations) : (done += 1) {
                cycles_taken += cpu.step();
                if (cycle_mode) appendTrailingInternal(cpu);
            }
            pc_exempt = cpu.a != 0xFFFF;
        }

        // ---- Compare final state ----
        var ok = true;
        var why: []const u8 = "";
        if (!pc_exempt and cpu.pc != @as(u16, @intCast(getInt(final, "pc")))) {
            ok = false;
            why = "pc";
        } else if (cpu.sp != @as(u16, @intCast(getInt(final, "s")))) {
            ok = false;
            why = "sp";
        } else if (cpu.a != @as(u16, @intCast(getInt(final, "a")))) {
            ok = false;
            why = "a";
        } else if (cpu.x != @as(u16, @intCast(getInt(final, "x")))) {
            ok = false;
            why = "x";
        } else if (cpu.y != @as(u16, @intCast(getInt(final, "y")))) {
            ok = false;
            why = "y";
        } else if (cpu.dbr != @as(u8, @intCast(getInt(final, "dbr")))) {
            ok = false;
            why = "dbr";
        } else if (cpu.dp != @as(u16, @intCast(getInt(final, "d")))) {
            ok = false;
            why = "d";
        } else if (cpu.pbr != @as(u8, @intCast(getInt(final, "pbr")))) {
            ok = false;
            why = "pbr";
        } else if (cpu.p.toByte() != @as(u8, @intCast(getInt(final, "p")))) {
            ok = false;
            why = "p";
        } else if (cpu.emulation_mode != (getInt(final, "e") != 0)) {
            ok = false;
            why = "e";
        }

        const final_ram = final.get("ram").?.array;
        if (ok) {
            for (final_ram.items) |cell| {
                const pair = cell.array;
                if (flat[@intCast(pair.items[0].integer)] != @as(u8, @intCast(pair.items[1].integer))) {
                    ok = false;
                    why = "ram";
                    break;
                }
            }
        }

        if (ok) {
            summary.passed += 1;
        } else {
            summary.failed += 1;
            if (shown < max_fail_shown) {
                shown += 1;
                std.debug.print("FAIL {s} ({s}): p={x:0>2}->{x:0>2} want p={x:0>2} a={x:0>4}->{x:0>4} want a={x:0>4} pc={x:0>4} want {x:0>4}\n", .{
                    t.get("name").?.string,           why,
                    @as(u8, @intCast(getInt(initial, "p"))), cpu.p.toByte(),
                    @as(u8, @intCast(getInt(final, "p"))),   @as(u16, @intCast(getInt(initial, "a"))),
                    cpu.a,                            @as(u16, @intCast(getInt(final, "a"))),
                    cpu.pc,                           @as(u16, @intCast(getInt(final, "pc"))),
                });
            }
        }

        // Timing telemetry (not a failure): vector cycle count = entries
        // in the "cycles" array
        if (t.get("cycles")) |cyc| {
            if (cycles_taken != cyc.array.items.len) summary.cycle_mismatch += 1;
            if (cycle_mode) try compareCycles(allocator, cyc.array.items, t.get("name").?.string, &summary, patterns, is_block_move);
        }

        // ---- Restore flat memory to zero for the next test ----
        for (init_ram.items) |cell| {
            flat[@intCast(cell.array.items[0].integer)] = 0;
        }
        for (final_ram.items) |cell| {
            flat[@intCast(cell.array.items[0].integer)] = 0;
        }
    }
    return summary;
}

/// Emulator.step (not Cpu.step) flushes an instruction's trailing internal
/// cycles to the clock owner; the harness calls Cpu.step directly, so it
/// appends them here exactly as Emulator.step would.
fn appendTrailingInternal(cpu: *zupernes.Cpu) void {
    const internal = @as(u32, cpu.cycles) -| cpu.mem_accesses;
    var trailing = internal -| cpu.internal_flushed;
    while (trailing > 0) : (trailing -= 1) recorder.push('I', 6);
}

/// Compare the vector's bus-cycle list with the recorded CPU sequence.
fn compareCycles(
    allocator: std.mem.Allocator,
    cycles: []const std.json.Value,
    name: []const u8,
    summary: *Summary,
    patterns: *std.StringHashMap(Pattern),
    is_block_move: bool,
) !void {
    var expected: [512]u8 = undefined;
    var n: usize = 0;
    var speed_ok = true;
    for (cycles) |c| {
        if (n == expected.len) break;
        const items = c.array.items;
        const out = items[2].string;
        const vda = out[0] == 'd';
        const vpa = out[1] == 'p';
        const write = out[3] == 'w';
        const kind: u8 = if (write) 'W' else if (vda or vpa) 'R' else 'I';
        expected[n] = kind;
        if (kind != 'I' and n < recorder.len and recorder.kinds[n] == kind) {
            const addr: u24 = @intCast(items[0].integer);
            const want = bus_backing.memSpeed(@truncate(addr >> 16), @truncate(addr));
            if (want != recorder.speeds[n]) speed_ok = false;
        }
        n += 1;
    }
    summary.seq_checked += 1;
    // Block-move vectors cap their cycle list at 100 entries, ending two
    // cycles into an iteration the harness (correctly) does not run. Compare
    // the complete iterations only.
    if (is_block_move and n == 100 and recorder.len < n) n = recorder.len;
    const seq_ok = n == recorder.len and std.mem.eql(u8, expected[0..n], recorder.kinds[0..recorder.len]);
    if (seq_ok and speed_ok) return;
    if (!seq_ok) summary.seq_mismatch += 1 else summary.speed_mismatch += 1;

    const key = if (!seq_ok)
        try std.fmt.allocPrint(allocator, "want {s}  got {s}", .{ expected[0..n], recorder.kinds[0..recorder.len] })
    else
        try std.fmt.allocPrint(allocator, "speed differs on {s}", .{expected[0..n]});
    const gop = try patterns.getOrPut(key);
    if (gop.found_existing) {
        allocator.free(key);
        gop.value_ptr.count += 1;
    } else {
        gop.value_ptr.* = .{ .count = 1, .example = try allocator.dupe(u8, name) };
    }
}
