const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Debug mode option - enables all debug tracing and frame output
    // Build with: zig build -Ddebug=true
    const debug_mode = b.option(bool, "debug", "Enable emulator debug output") orelse false;

    // Sokol dependency (graphics/windowing library)
    const dep_sokol = b.dependency("sokol", .{
        .target = target,
        .optimize = optimize,
    });

    // Build options - shared between main exe and emulator library
    // IMPORTANT: createModule() must only be called ONCE, then shared
    const build_opts = b.addOptions();
    build_opts.addOption(bool, "debug_mode", debug_mode);
    const build_opts_mod = build_opts.createModule();

    // Core emulator library module
    const emu_mod = b.addModule("zupernes", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "build_options", .module = build_opts_mod },
        },
    });

    // Main executable
    const exe = b.addExecutable(.{
        .name = "zupernes",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zupernes", .module = emu_mod },
                .{ .name = "sokol", .module = dep_sokol.module("sokol") },
                .{ .name = "build_options", .module = build_opts_mod },
            },
        }),
    });

    // Link sokol artifact for native platform libraries
    exe.root_module.linkLibrary(dep_sokol.artifact("sokol_clib"));

    b.installArtifact(exe);

    // Run step
    const run_step = b.step("run", "Run the emulator");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Test harness executable
    const test_harness = b.addExecutable(.{
        .name = "test-harness",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test_harness.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zupernes", .module = emu_mod },
            },
        }),
    });

    b.installArtifact(test_harness);

    const run_tests_step = b.step("test-roms", "Run ROM test harness");
    const run_test_harness = b.addRunArtifact(test_harness);
    run_tests_step.dependOn(&run_test_harness.step);
    run_test_harness.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_test_harness.addArgs(args);
    }

    // Headless screenshot tool - runs a ROM for N frames without a window
    // and dumps the framebuffer as PPM. Used for automated visual testing:
    //   zig build screenshot -- rom.sfc 300 /tmp/out.ppm --input 120:S
    const screenshot = b.addExecutable(.{
        .name = "screenshot",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/screenshot.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zupernes", .module = emu_mod },
            },
        }),
    });

    b.installArtifact(screenshot);

    const screenshot_step = b.step("screenshot", "Run headless and dump framebuffer to PPM");
    const run_screenshot = b.addRunArtifact(screenshot);
    screenshot_step.dependOn(&run_screenshot.step);
    run_screenshot.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_screenshot.addArgs(args);
    }

    // Savestate verifier: proves a resumed run is bit-identical to a
    // from-power-on run of the same input.
    //   zig build savestate-verify -- <rom.sfc> <frames> <snapshot> [--movie F]
    const savestate_verify = b.addExecutable(.{
        .name = "savestate-verify",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/savestate_verify.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zupernes", .module = emu_mod },
            },
        }),
    });
    b.installArtifact(savestate_verify);
    const savestate_verify_step = b.step("savestate-verify", "Prove savestate resume is bit-identical");
    const run_savestate_verify = b.addRunArtifact(savestate_verify);
    savestate_verify_step.dependOn(&run_savestate_verify.step);
    run_savestate_verify.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_savestate_verify.addArgs(args);
    }

    // Recording verifier: proves a recorded run replays to the same machine.
    //   zig build record-verify -- <rom.sfc> <frames> [--inject-divergence F]
    const record_verify = b.addExecutable(.{
        .name = "record-verify",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/record_verify.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zupernes", .module = emu_mod },
            },
        }),
    });
    b.installArtifact(record_verify);
    const record_verify_step = b.step("record-verify", "Prove a recording replays bit-identical");
    const run_record_verify = b.addRunArtifact(record_verify);
    record_verify_step.dependOn(&run_record_verify.step);
    run_record_verify.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_record_verify.addArgs(args);
    }

    // Splice verifier: proves a recording made from a resume is SELF-CONTAINED
    // - that the origin prefix it splices in front of the tail reproduces the
    // resumed run exactly when replayed from power-on.
    //   zig build splice-verify -- <rom.sfc>
    //
    // A shell script rather than a Zig binary because what it exercises is the
    // FRONTEND's file plumbing: the .origin sidecar, its hash check, and the
    // three fallbacks. Driving the real `screenshot` executable is the point;
    // an in-process test would prove the splice arithmetic while skipping
    // everything that reads and writes the files.
    //
    // Build ReleaseFast first - it runs ~1300 emulated frames several times.
    const splice_verify_step = b.step("splice-verify", "Prove a resumed recording is self-contained");
    const run_splice_verify = b.addSystemCommand(&.{"test/splice-verify.sh"});
    run_splice_verify.step.dependOn(b.getInstallStep());
    splice_verify_step.dependOn(&run_splice_verify.step);
    if (b.args) |args| {
        run_splice_verify.addArgs(args);
    }

    // CPU test-vector harness (SingleStepTests 65816 JSON vectors)
    //   zig build cpu-vectors -- <dir-with-json> [filter]
    const cpu_vectors = b.addExecutable(.{
        .name = "cpu-vectors",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test_cpu_vectors.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zupernes", .module = emu_mod },
            },
        }),
    });
    b.installArtifact(cpu_vectors);
    const cpu_vectors_step = b.step("cpu-vectors", "Run 65816 test vectors against the CPU");
    const run_cpu_vectors = b.addRunArtifact(cpu_vectors);
    cpu_vectors_step.dependOn(&run_cpu_vectors.step);
    run_cpu_vectors.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cpu_vectors.addArgs(args);
    }

    // SPC700 test-vector harness (SingleStepTests spc700 JSON vectors) -
    // the sound-core twin of cpu-vectors above
    //   zig build spc-vectors -- <dir-with-json> [filter]
    const spc_vectors = b.addExecutable(.{
        .name = "spc-vectors",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test_spc_vectors.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zupernes", .module = emu_mod },
            },
        }),
    });
    b.installArtifact(spc_vectors);
    const spc_vectors_step = b.step("spc-vectors", "Run SPC700 test vectors against the APU core");
    const run_spc_vectors = b.addRunArtifact(spc_vectors);
    spc_vectors_step.dependOn(&run_spc_vectors.step);
    run_spc_vectors.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_spc_vectors.addArgs(args);
    }

    // Unit tests

    // ------------------------------------------------------------------
    // Browser theater: the real emulator core compiled to freestanding
    // wasm32, exported with the zn_* adapter contract (src/theater/wasm/
    // main.zig). The browser page loads the artifact from
    // src/theater/zupernes.wasm; the InstallArtifact step with a custom
    // dest_dir stages the built wasm from zig-out into the source tree so
    // the static app and the artifact live in one folder that
    // `python3 src/theater/serve.py` ships.
    //
    // `zig build theater -Doptimize=ReleaseFast` is the exact build the
    // page uses (TASK.md); the staged binary is gitignored.
    // ------------------------------------------------------------------
    const theater_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
        .cpu_model = .baseline,
    });
    const theater_wasm = b.addExecutable(.{
        .name = "zupernes",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/theater/wasm/main.zig"),
            .target = theater_target,
            .optimize = optimize,
            .imports = &.{
                // Same zupernes module the native frontends import: the WASM
                // build runs the REAL core through the same code paths
                // native runs for the parity fixtures.
                .{ .name = "zupernes", .module = emu_mod },
            },
        }),
    });
    theater_wasm.entry = .disabled;
    // wasm GC strips unreferenced export fns; rdynamic adds ALL symbols to
    // the dynamic symbol table, which is what makes the zn_* exports survive
    // into the wasm export section (verified: only `memory` survives without
    // it - Zig 0.15 marks exports, wasm-ld still relies on the symbol table).
    theater_wasm.rdynamic = true;
    // The adapter constructs the ~940 KB Emulator by value (Emulator.init()
    // returns it, then it is copied into its heap slot); the temporary lives
    // on the wasm shadow stack, so the default stack is far too small. 4 MB
    // covers construction plus the deepest emulator call paths.
    theater_wasm.stack_size = 4 * 1024 * 1024;
    // STAGING: the page loads the artifact from src/theater/zupernes.wasm
    // (the directory `python3 src/theater/serve.py` serves), but a custom
    // InstallDir is still relative to zig-out - install alone can only
    // produce zig-out/src/theater/zupernes.wasm, invisible to the server
    // (and to a clean checkout with no zig-out). The copy into the source
    // tree is therefore part of THE BUILD GRAPH: a Run step whose cwd is
    // the build root copies the installed artifact from zig-out into
    // src/theater/. Nothing is manual, and the artifact stays gitignored.
    const theater_step = b.step("theater", "Build the browser-theater WASM adapter");
    const install_theater = b.addInstallArtifact(theater_wasm, .{
        .dest_dir = .{ .override = .{ .custom = "src/theater" } },
    });
    const stage_theater = b.addSystemCommand(&.{ "cp", "-f" });
    stage_theater.setCwd(.{ .cwd_relative = b.build_root.path orelse "." });
    stage_theater.addFileArg(install_theater.emitted_bin.?);
    stage_theater.addArg("src/theater/zupernes.wasm");
    stage_theater.step.dependOn(&install_theater.step);
    theater_step.dependOn(&stage_theater.step);
    const emu_tests = b.addTest(.{
        .root_module = emu_mod,
    });
    const run_emu_tests = b.addRunArtifact(emu_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_emu_tests.step);
}
