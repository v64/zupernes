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
// =============================================================================

const std = @import("std");
const zupernes = @import("zupernes");

var bus_backing: zupernes.Bus = undefined;
var cpu_backing: zupernes.Cpu = undefined;

const Summary = struct {
    passed: u64 = 0,
    failed: u64 = 0,
    cycle_mismatch: u64 = 0,
};

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
        const summary = runFile(allocator, dir, name, flat, max_fail_shown) catch |err| {
            std.debug.print("{s}: ERROR {s}\n", .{ name, @errorName(err) });
            continue;
        };
        grand.passed += summary.passed;
        grand.failed += summary.failed;
        grand.cycle_mismatch += summary.cycle_mismatch;
        if (summary.failed > 0) {
            failed_files += 1;
            std.debug.print("{s}: {d}/{d} FAILED (cycle mismatches: {d})\n", .{ name, summary.failed, summary.passed + summary.failed, summary.cycle_mismatch });
        }
    }
    std.debug.print(
        "\nTOTAL: {d} passed, {d} failed across {d} files ({d} files with failures); cycle-count mismatches: {d}\n",
        .{ grand.passed, grand.failed, names.items.len, failed_files, grand.cycle_mismatch },
    );
    if (grand.failed > 0) std.process.exit(1);
}

fn getInt(obj: std.json.ObjectMap, key: []const u8) i64 {
    return obj.get(key).?.integer;
}

fn runFile(allocator: std.mem.Allocator, dir: std.fs.Dir, name: []const u8, flat: []u8, max_fail_shown: u32) !Summary {
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
        var cycles_taken: u32 = cpu.step();
        var pc_exempt = false;
        if (is_block_move) {
            const iterations = t.get("cycles").?.array.items.len / 7;
            var done: usize = 1;
            while (cpu.a != 0xFFFF and done < iterations) : (done += 1) {
                cycles_taken += cpu.step();
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
