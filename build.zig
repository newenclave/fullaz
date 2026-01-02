const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("fullaz", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const unit_tests = b.addModule("fullaz_tests", .{
        .root_source_file = b.path("tests/tests.zig"),
        .target = target,
    });

    const exe = b.addExecutable(.{
        .name = "fullaz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "fullaz", .module = mod },
            },
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const mod_tests = b.addTest(.{
        .root_module = unit_tests,
    });

    mod_tests.root_module.addImport("fullaz", mod);

    const test_filter = b.option([]const u8, "test-filter", "Filter tests by name");
    if (test_filter) |filter| {
        mod_tests.filters = &.{filter};
    }

    // Install test executable for debugging
    const install_tests = b.addInstallArtifact(mod_tests, .{});

    const run_mod_tests = b.addRunArtifact(mod_tests);
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    if (test_filter) |filter| {
        exe_tests.filters = &.{filter};
    }

    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    // Add install-tests step for debugging
    const install_test_step = b.step("install-tests", "Install test executable for debugging");
    install_test_step.dependOn(&install_tests.step);
}
