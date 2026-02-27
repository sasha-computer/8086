const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "emu8086",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    b.installArtifact(exe);

    // zig build run -- [args]
    const run_step = b.step("run", "Run the emulator");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    run_step.dependOn(&run_cmd.step);

    // zig build test -- run all tests (ReleaseFast for speed)
    // Use -Doptimize=Debug to run with safety checks if needed.
    const test_step = b.step("test", "Run all tests (ReleaseFast)");

    const test_optimize = if (optimize == .Debug) .ReleaseFast else optimize;

    const exe_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = test_optimize,
        }),
    });
    const run_tests = b.addRunArtifact(exe_tests);
    test_step.dependOn(&run_tests.step);

    // zig build test-debug -- run tests with full safety checks (slow)
    const test_debug_step = b.step("test-debug", "Run tests in Debug mode (slow, with safety checks)");
    const debug_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = .Debug,
        }),
    });
    test_debug_step.dependOn(&b.addRunArtifact(debug_tests).step);

    // zig build wasm -- Build WASM module for browser
    const wasm = b.addExecutable(.{
        .name = "emu8086",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/wasm_api.zig"),
            .target = b.resolveTargetQuery(.{
                .cpu_arch = .wasm32,
                .os_tag = .freestanding,
            }),
            .optimize = .ReleaseSmall,
        }),
    });
    wasm.entry = .disabled;
    wasm.rdynamic = true;

    const install_wasm = b.addInstallArtifact(wasm, .{
        .dest_dir = .{ .override = .{ .custom = "web" } },
    });
    b.step("wasm", "Build WASM module for browser").dependOn(&install_wasm.step);
}
