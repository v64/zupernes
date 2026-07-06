// =============================================================================
// SPC700 TEST-VECTOR HARNESS (SingleStepTests)
// =============================================================================
// Runs the APU's SPC700 core against the SingleStepTests spc700 vectors -
// the same treatment the 65816 got (src/test_cpu_vectors.zig, 5.12M
// vectors clean): 1,000 generated tests per opcode, each giving complete
// initial and final machine state (registers + every RAM cell touched)
// plus a per-cycle bus trace. This converts "SMW's driver sounds right"
// into "every instruction formally verified" - the sound core is vendored
// into ZuperWorld, so its correctness is oracle infrastructure too.
//
// Vectors: https://github.com/SingleStepTests/spc700 (v1/*.json, one file
// per opcode: "00.json".."ff.json"). Download separately; NOT in the repo.
//
// Usage:
//   zig build -Doptimize=ReleaseFast spc-vectors -- <dir-with-json> [opcode-filter] [--max-fail N]
//
// Semantics the vectors assume (and how we honor them):
//  - The whole 64KB is plain RAM: no I/O registers at $F0-$FF, no IPL
//    ROM overlay at $FFC0. The core's `test_flat_ram` flag (added for
//    this harness) bypasses both mappings - the vectors verify the CPU
//    CORE, not the peripherals (timers/ports/DSP have no vector suite;
//    they stay covered by the game-level harnesses).
//  - We verify FINAL STATE (registers + a full 64KB RAM image diff -
//    stronger than checking only the listed cells, it also catches
//    spurious writes). Cycle-count mismatches are tallied separately as
//    timing telemetry, never as failures - same policy as the 65816.
//
// Status 2026-07-05: 256,000/256,000 state-exact. The only cycle-count
// telemetry is SLEEP ($EF) and STOP ($FF), 1000 each: the vectors
// snapshot the halt loop mid-wait (7 cycles: fetch + 3x re-read/wait),
// while we model both as 3-cycle no-ops - final state agrees either
// way, and no game code executes them (SMW's driver certainly not; on
// the S-SMP a STOP is unrecoverable without a full APU reset).
// =============================================================================

const std = @import("std");
const zupernes = @import("zupernes");

// The Spc700 embeds its 64KB RAM + DSP by value (~70KB) - static like
// the 65816 harness's globals, not stack.
var spc_backing: zupernes.Spc700 = undefined;
// The expected final image: initial RAM with the final cells applied.
var expect_ram: [65536]u8 = undefined;

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
        std.debug.print("Usage: spc-vectors <dir> [substring-filter] [--max-fail N]\n", .{});
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

    spc_backing = zupernes.Spc700.init();
    spc_backing.test_flat_ram = true;
    spc_backing.ipl_rom_enabled = false;
    @memset(&spc_backing.ram, 0);
    @memset(&expect_ram, 0);

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
        const summary = runFile(allocator, dir, name, max_fail_shown) catch |err| {
            std.debug.print("{s}: ERROR {s}\n", .{ name, @errorName(err) });
            continue;
        };
        grand.passed += summary.passed;
        grand.failed += summary.failed;
        grand.cycle_mismatch += summary.cycle_mismatch;
        if (summary.failed > 0) {
            failed_files += 1;
            std.debug.print("{s}: {d}/{d} FAILED (cycle mismatches: {d})\n", .{ name, summary.failed, summary.passed + summary.failed, summary.cycle_mismatch });
        } else if (summary.cycle_mismatch > 0) {
            // Timing-only telemetry: state is exact, cycle count isn't.
            std.debug.print("{s}: state-exact, {d} cycle-count mismatches\n", .{ name, summary.cycle_mismatch });
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

fn runFile(allocator: std.mem.Allocator, dir: std.fs.Dir, name: []const u8, max_fail_shown: u32) !Summary {
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
        const spc = &spc_backing;
        spc.pc = @intCast(getInt(initial, "pc"));
        spc.a = @intCast(getInt(initial, "a"));
        spc.x = @intCast(getInt(initial, "x"));
        spc.y = @intCast(getInt(initial, "y"));
        spc.sp = @intCast(getInt(initial, "sp"));
        spc.psw = @intCast(getInt(initial, "psw"));

        const init_ram = initial.get("ram").?.array;
        for (init_ram.items) |cell| {
            const pair = cell.array;
            const addr: u16 = @intCast(pair.items[0].integer);
            const val: u8 = @intCast(pair.items[1].integer);
            spc.ram[addr] = val;
            expect_ram[addr] = val;
        }
        // Expected final image = initial image + the final cells (the
        // final list restates every touched cell, so this is complete).
        const final_ram = final.get("ram").?.array;
        for (final_ram.items) |cell| {
            const pair = cell.array;
            expect_ram[@intCast(pair.items[0].integer)] = @intCast(pair.items[1].integer);
        }

        // ---- Execute one instruction ----
        const cycles_taken: u32 = spc.step();

        // ---- Compare final state ----
        var ok = true;
        var why: []const u8 = "";
        if (spc.pc != @as(u16, @intCast(getInt(final, "pc")))) {
            ok = false;
            why = "pc";
        } else if (spc.a != @as(u8, @intCast(getInt(final, "a")))) {
            ok = false;
            why = "a";
        } else if (spc.x != @as(u8, @intCast(getInt(final, "x")))) {
            ok = false;
            why = "x";
        } else if (spc.y != @as(u8, @intCast(getInt(final, "y")))) {
            ok = false;
            why = "y";
        } else if (spc.sp != @as(u8, @intCast(getInt(final, "sp")))) {
            ok = false;
            why = "sp";
        } else if (spc.psw != @as(u8, @intCast(getInt(final, "psw")))) {
            ok = false;
            why = "psw";
        } else if (!std.mem.eql(u8, &spc.ram, &expect_ram)) {
            ok = false;
            why = "ram";
        }

        if (ok) {
            summary.passed += 1;
        } else {
            summary.failed += 1;
            if (shown < max_fail_shown) {
                shown += 1;
                std.debug.print("FAIL {s} ({s}): psw={x:0>2}->{x:0>2} want {x:0>2} a={x:0>2}->{x:0>2} want {x:0>2} pc={x:0>4} want {x:0>4}\n", .{
                    t.get("name").?.string,                    why,
                    @as(u8, @intCast(getInt(initial, "psw"))), spc.psw,
                    @as(u8, @intCast(getInt(final, "psw"))),   @as(u8, @intCast(getInt(initial, "a"))),
                    spc.a,                                     @as(u8, @intCast(getInt(final, "a"))),
                    spc.pc,                                    @as(u16, @intCast(getInt(final, "pc"))),
                });
                if (std.mem.eql(u8, why, "ram")) {
                    for (0..65536) |addr| {
                        if (spc.ram[addr] != expect_ram[addr]) {
                            std.debug.print("  ram[{x:0>4}] = {x:0>2}, want {x:0>2}\n", .{ addr, spc.ram[addr], expect_ram[addr] });
                        }
                    }
                }
            }
        }

        // Timing telemetry (not a failure): vector cycle count = entries
        // in the "cycles" array (including "wait" idle cycles)
        if (t.get("cycles")) |cyc| {
            if (cycles_taken != cyc.array.items.len) summary.cycle_mismatch += 1;
        }

        // ---- Restore both images to zero for the next test ----
        // (cells the CPU wrote that the vector didn't list get wiped by
        // the full-image restore below only if listed - so wipe OUR ram
        // from the expected image's footprint plus a full clear of any
        // divergence found; cheapest correct: reset both from the two
        // cell lists, then clear any surviving diff bytes.)
        for (init_ram.items) |cell| {
            const addr: u16 = @intCast(cell.array.items[0].integer);
            spc.ram[addr] = 0;
            expect_ram[addr] = 0;
        }
        for (final_ram.items) |cell| {
            const addr: u16 = @intCast(cell.array.items[0].integer);
            spc.ram[addr] = 0;
            expect_ram[addr] = 0;
        }
        // A buggy instruction may have scribbled cells outside both
        // lists; sweep them so one failure can't cascade. (memcmp-fast
        // when clean, which is the common case.)
        if (!std.mem.eql(u8, &spc.ram, &expect_ram)) {
            @memset(&spc.ram, 0);
            @memset(&expect_ram, 0);
        }
    }
    return summary;
}
