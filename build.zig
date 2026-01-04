const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Sokol dependency
    const dep_sokol = b.dependency("sokol", .{
        .target = target,
        .optimize = optimize,
    });

    // Core emulator library module
    const emu_mod = b.addModule("zupernes", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
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

    // Unit tests
    const emu_tests = b.addTest(.{
        .root_module = emu_mod,
    });
    const run_emu_tests = b.addRunArtifact(emu_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_emu_tests.step);
}
