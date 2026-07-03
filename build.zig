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

    // Unit tests
    const emu_tests = b.addTest(.{
        .root_module = emu_mod,
    });
    const run_emu_tests = b.addRunArtifact(emu_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_emu_tests.step);
}
