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
        .optimize = optimize,
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
        const owned = b.allocator.dupe(u8, filter) catch @panic("OOM duping test-filter");

        const filters = b.allocator.alloc([]const u8, 1) catch @panic("OOM alloc filters");
        filters[0] = owned;

        mod_tests.filters = filters;
    }

    // Install test executable for debugging
    const install_tests = b.addInstallArtifact(mod_tests, .{});

    const run_mod_tests = b.addRunArtifact(mod_tests);
    // const exe_tests = b.addTest(.{
    //     .root_module = exe.root_module,
    // });

    // if (test_filter) |filter| {
    //     exe_tests.filters = &.{filter};
    // }

    //const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    //test_step.dependOn(&run_exe_tests.step);

    // Add install-tests step for debugging
    const install_test_step = b.step("install-tests", "Install test executable for debugging");
    install_test_step.dependOn(&install_tests.step);

    // --- fsx: filesystem-in-a-file example (separate exe + tests) ---
    const zigline_dep = b.dependency("zigline", .{
        .target = target,
        .optimize = optimize,
    });
    const zigline_mod = zigline_dep.module("zigline");

    // The fsx library surface (demos/fsx/src/root.zig), imported by both the exe and
    // the tests so fsx source is compiled once and testable across the tests/src
    // module boundary.
    const fsx_mod = b.addModule("fsx", .{
        .root_source_file = b.path("demos/fsx/src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "fullaz", .module = mod },
            .{ .name = "zigline", .module = zigline_mod },
        },
    });

    const fsx_exe = b.addExecutable(.{
        .name = "fsx",
        .root_module = b.createModule(.{
            .root_source_file = b.path("demos/fsx/src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "fullaz", .module = mod },
                .{ .name = "zigline", .module = zigline_mod },
                .{ .name = "fsx", .module = fsx_mod },
            },
        }),
    });
    b.installArtifact(fsx_exe);

    const run_fs_step = b.step("run-fs", "Run the fsx example");
    const run_fs_cmd = b.addRunArtifact(fsx_exe);
    run_fs_step.dependOn(&run_fs_cmd.step);
    run_fs_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_fs_cmd.addArgs(args);
    }

    const fsx_tests_mod = b.addModule("fsx_tests", .{
        .root_source_file = b.path("demos/fsx/tests/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    const fsx_tests = b.addTest(.{ .root_module = fsx_tests_mod });
    fsx_tests.root_module.addImport("fullaz", mod);
    fsx_tests.root_module.addImport("zigline", zigline_mod);
    fsx_tests.root_module.addImport("fsx", fsx_mod);
    if (test_filter) |filter| {
        const owned = b.allocator.dupe(u8, filter) catch @panic("OOM duping fsx test-filter");
        const filters = b.allocator.alloc([]const u8, 1) catch @panic("OOM alloc fsx filters");
        filters[0] = owned;
        fsx_tests.filters = filters;
    }
    const run_fsx_tests = b.addRunArtifact(fsx_tests);
    const test_fs_step = b.step("test-fs", "Run fsx tests");
    test_fs_step.dependOn(&run_fsx_tests.step);

    // --- galaxy: R-tree galaxy-explorer demo (separate exe + tests) ---
    const galaxy_mod = b.addModule("galaxy", .{
        .root_source_file = b.path("demos/galaxy/src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "fullaz", .module = mod },
            .{ .name = "zigline", .module = zigline_mod },
        },
    });

    const galaxy_exe = b.addExecutable(.{
        .name = "galaxy",
        .root_module = b.createModule(.{
            .root_source_file = b.path("demos/galaxy/src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "fullaz", .module = mod },
                .{ .name = "zigline", .module = zigline_mod },
                .{ .name = "galaxy", .module = galaxy_mod },
            },
        }),
    });
    b.installArtifact(galaxy_exe);

    const run_galaxy_step = b.step("run-galaxy", "Run the galaxy explorer demo");
    const run_galaxy_cmd = b.addRunArtifact(galaxy_exe);
    run_galaxy_step.dependOn(&run_galaxy_cmd.step);
    run_galaxy_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_galaxy_cmd.addArgs(args);
    }

    const galaxy_tests_mod = b.addModule("galaxy_tests", .{
        .root_source_file = b.path("demos/galaxy/tests/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    const galaxy_tests = b.addTest(.{ .root_module = galaxy_tests_mod });
    galaxy_tests.root_module.addImport("fullaz", mod);
    galaxy_tests.root_module.addImport("galaxy", galaxy_mod);
    if (test_filter) |filter| {
        const owned = b.allocator.dupe(u8, filter) catch @panic("OOM duping galaxy test-filter");
        const filters = b.allocator.alloc([]const u8, 1) catch @panic("OOM alloc galaxy filters");
        filters[0] = owned;
        galaxy_tests.filters = filters;
    }
    const run_galaxy_tests = b.addRunArtifact(galaxy_tests);
    const test_galaxy_step = b.step("test-galaxy", "Run galaxy tests");
    test_galaxy_step.dependOn(&run_galaxy_tests.step);
}
