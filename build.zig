const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const verbose_tests = b.option(bool, "verbose-tests", "Enable debug output in tests") orelse false;
    const full_validation = b.option(
        bool,
        "full-validation",
        "Enable expensive full-structure validation",
    ) orelse false;
    const fullaz_options = b.addOptions();
    fullaz_options.addOption(bool, "full_validation", full_validation);

    const mod = b.addModule("fullaz", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });
    mod.addOptions("build_options", fullaz_options);

    const unit_tests = b.addModule("fullaz_tests", .{
        .root_source_file = b.path("tests/tests.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_options = b.addOptions();
    test_options.addOption(bool, "verbose_tests", verbose_tests);
    const test_printer = b.createModule(.{
        .root_source_file = b.path("tests/printer.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_printer.addOptions("build_options", test_options);

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
    if (verbose_tests) {
        const test_runner_path = b.graph.zig_lib_directory.join(b.allocator, &.{ "compiler", "test_runner.zig" }) catch @panic("OOM resolving test runner path");
        mod_tests.test_runner = .{
            .path = .{ .cwd_relative = test_runner_path },
            .mode = .simple,
        };
    }

    mod_tests.root_module.addImport("fullaz", mod);
    mod_tests.root_module.addImport("test_printer", test_printer);

    const test_filter = b.option([]const u8, "test-filter", "Filter tests by name");
    applyTestFilter(b, mod_tests, test_filter);

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
    const pages_compile_errors_step = b.step(
        "test-pages-compile-errors",
        "Check pages compile-time diagnostics",
    );
    for ([_]CompileErrorFixture{
        .{
            .source = "tests/compile_errors/pages/duplicate_component.zig",
            .expected = "Duplicate pages Schema component: index",
        },
        .{
            .source = "tests/compile_errors/pages/unknown_component.zig",
            .expected = "Unknown pages Schema component: missing",
        },
    }) |fixture| {
        addCompileErrorFixture(
            b,
            pages_compile_errors_step,
            mod,
            target,
            optimize,
            fixture,
        );
    }
    test_step.dependOn(pages_compile_errors_step);
    //test_step.dependOn(&run_exe_tests.step);

    // Add install-tests step for debugging
    const install_test_step = b.step("install-tests", "Install test executable for debugging");
    install_test_step.dependOn(&install_tests.step);

    // --- demos: each one is an exe, a test step and a browser build ---
    const zigline_dep = b.dependency("zigline", .{
        .target = target,
        .optimize = optimize,
    });
    const zigline_mod = zigline_dep.module("zigline");

    // Fresh module instances targeting wasm (the ones above are pinned to the
    // host). The engine + MemoryBlock storage are I/O-free, so they compile for
    // freestanding wasm; only main.zig (std.process/std.Io/zigline) is excluded.
    const wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const fullaz_wasm = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    });
    fullaz_wasm.addOptions("build_options", fullaz_options);

    // Shared terminal plumbing for the full-screen demos. Not a demo itself,
    // so it gets a module and a test step rather than an addDemo call.
    const demo_common = b.addModule("demo_common", .{
        .root_source_file = b.path("demos/common/src/root.zig"),
        .target = target,
    });

    const common_tests_mod = b.addModule("demo_common_tests", .{
        .root_source_file = b.path("demos/common/tests/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    const common_tests = b.addTest(.{ .root_module = common_tests_mod });
    common_tests.root_module.addImport("demo_common", demo_common);
    applyTestFilter(b, common_tests, test_filter);
    const run_common_tests = b.addRunArtifact(common_tests);
    b.step("test-common", "Run shared demo tests").dependOn(&run_common_tests.step);

    const demo_ctx = DemoContext{
        .target = target,
        .optimize = optimize,
        .wasm_target = wasm_target,
        .fullaz = mod,
        .fullaz_wasm = fullaz_wasm,
        .zigline = zigline_mod,
        .demo_common = demo_common,
        .test_filter = test_filter,
    };

    addDemo(b, demo_ctx, .{
        .name = "sstable",
        .lib_source = "demos/sstable/src/root.zig",
        .exe_source = "demos/sstable/src/main.zig",
        .run_step = "run-sstable",
        .run_desc = "Run the SSTable format explorer",
        .tests_source = "demos/sstable/tests/tests.zig",
        .test_step = "test-sstable",
        .test_desc = "Run SSTable demo tests",
        .wasm_source = "demos/sstable/src/wasm.zig",
        .wasm_step = "wasm-sstable",
        .wasm_desc = "Build the SSTable WASM demo into zig-out/web-sstable",
        .web_dir = "web-sstable",
        .web_index = "demos/sstable/web/index.html",
    });

    addDemo(b, demo_ctx, .{
        .name = "fsx",
        .lib_source = "demos/fsx/src/root.zig",
        .lib_needs_zigline = true,
        .exe_source = "demos/fsx/src/main.zig",
        .run_step = "run-fs",
        .run_desc = "Run the fsx example",
        .tests_source = "demos/fsx/tests/tests.zig",
        .tests_need_zigline = true,
        .test_step = "test-fs",
        .test_desc = "Run fsx tests",
        // The native root pulls in I/O, so the browser build has its own.
        .wasm_lib_source = "demos/fsx/src/wasm_root.zig",
        .wasm_source = "demos/fsx/src/wasm.zig",
        .wasm_step = "wasm-fsx",
        .wasm_desc = "Build the fsx WASM backend into zig-out/web-fsx",
        .web_dir = "web-fsx",
        .web_index = "demos/fsx/web/index.html",
    });

    addDemo(b, demo_ctx, .{
        .name = "galaxy",
        .lib_source = "demos/galaxy/src/root.zig",
        .lib_needs_zigline = true,
        .exe_source = "demos/galaxy/src/main.zig",
        .run_step = "run-galaxy",
        .run_desc = "Run the galaxy explorer demo",
        .tests_source = "demos/galaxy/tests/tests.zig",
        .test_step = "test-galaxy",
        .test_desc = "Run galaxy tests",
        .wasm_source = "demos/galaxy/src/wasm.zig",
        .wasm_step = "wasm-galaxy",
        .wasm_desc = "Build the galaxy WASM demo into zig-out/web",
        .web_dir = "web",
        .web_index = "demos/galaxy/web/index.html",
    });

    addDemo(b, demo_ctx, .{
        .name = "cloud",
        .lib_source = "demos/cloud/src/root.zig",
        .exe_source = "demos/cloud/src/main.zig",
        .exe_needs_common = true,
        .run_step = "run-cloud",
        .run_desc = "Run the point-cloud LOD viewer",
        .tests_source = "demos/cloud/tests/tests.zig",
        .test_step = "test-cloud",
        .test_desc = "Run cloud demo tests",
        .wasm_source = "demos/cloud/src/wasm.zig",
        .wasm_step = "wasm-cloud",
        .wasm_desc = "Build the cloud WASM demo into zig-out/web-cloud",
        .web_dir = "web-cloud",
        .web_index = "demos/cloud/web/index.html",
    });

    addDemo(b, demo_ctx, .{
        .name = "gravity",
        .lib_source = "demos/gravity/src/root.zig",
        .exe_source = "demos/gravity/src/main.zig",
        .exe_needs_common = true,
        .run_step = "run-gravity",
        .run_desc = "Run the Barnes-Hut gravity demo",
        .tests_source = "demos/gravity/tests/tests.zig",
        .test_step = "test-gravity",
        .test_desc = "Run gravity demo tests",
        .wasm_source = "demos/gravity/src/wasm.zig",
        .wasm_step = "wasm-gravity",
        .wasm_desc = "Build the gravity WASM demo into zig-out/web-gravity",
        .web_dir = "web-gravity",
        .web_index = "demos/gravity/web/index.html",
    });
}

const DemoContext = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    wasm_target: std.Build.ResolvedTarget,
    fullaz: *std.Build.Module,
    fullaz_wasm: *std.Build.Module,
    zigline: *std.Build.Module,
    demo_common: *std.Build.Module,
    test_filter: ?[]const u8,
};

// Every field earns its place: step names are irregular (run-fs, not run-fsx),
// galaxy installs into web/ rather than web-galaxy/, fsx needs a separate wasm
// root, and zigline is imported by a different set of modules in each demo.
const Demo = struct {
    name: []const u8,

    lib_source: []const u8,
    lib_needs_zigline: bool = false,

    exe_source: []const u8,
    // Only the demos that draw a full-screen frame need the shared terminal.
    exe_needs_common: bool = false,
    run_step: []const u8,
    run_desc: []const u8,

    tests_source: []const u8,
    tests_need_zigline: bool = false,
    test_step: []const u8,
    test_desc: []const u8,

    wasm_source: []const u8,
    wasm_lib_source: ?[]const u8 = null,
    wasm_step: []const u8,
    wasm_desc: []const u8,
    web_dir: []const u8,
    web_index: []const u8,
};

const CompileErrorFixture = struct {
    source: []const u8,
    expected: []const u8,
};

fn addCompileErrorFixture(
    b: *std.Build,
    step: *std.Build.Step,
    fullaz: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    fixture: CompileErrorFixture,
) void {
    const fixture_module = b.createModule(.{
        .root_source_file = b.path(fixture.source),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "fullaz", .module = fullaz }},
    });
    const compile = b.addTest(.{ .root_module = fixture_module });
    compile.expect_errors = .{ .contains = fixture.expected };
    step.dependOn(&compile.step);
}

fn applyTestFilter(b: *std.Build, compile: *std.Build.Step.Compile, filter: ?[]const u8) void {
    const wanted = filter orelse return;
    const owned = b.allocator.dupe(u8, wanted) catch @panic("OOM duping test-filter");
    const filters = b.allocator.alloc([]const u8, 1) catch @panic("OOM alloc filters");
    filters[0] = owned;
    compile.filters = filters;
}

fn addDemo(b: *std.Build, ctx: DemoContext, demo: Demo) void {
    // The library surface, imported by the exe and the tests alike so the demo
    // source is compiled once and testable across the tests/src boundary.
    const lib = b.addModule(demo.name, .{
        .root_source_file = b.path(demo.lib_source),
        .target = ctx.target,
        .imports = if (demo.lib_needs_zigline) &.{
            .{ .name = "fullaz", .module = ctx.fullaz },
            .{ .name = "zigline", .module = ctx.zigline },
        } else &.{
            .{ .name = "fullaz", .module = ctx.fullaz },
        },
    });

    const exe_module = b.createModule(.{
        .root_source_file = b.path(demo.exe_source),
        .target = ctx.target,
        .optimize = ctx.optimize,
        .imports = &.{
            .{ .name = "fullaz", .module = ctx.fullaz },
            .{ .name = "zigline", .module = ctx.zigline },
            .{ .name = demo.name, .module = lib },
        },
    });
    if (demo.exe_needs_common) {
        exe_module.addImport("demo_common", ctx.demo_common);
    }
    const exe = b.addExecutable(.{ .name = demo.name, .root_module = exe_module });
    b.installArtifact(exe);

    const run_step = b.step(demo.run_step, demo.run_desc);
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const tests_mod = b.addModule(b.fmt("{s}_tests", .{demo.name}), .{
        .root_source_file = b.path(demo.tests_source),
        .target = ctx.target,
        .optimize = ctx.optimize,
    });
    const tests = b.addTest(.{ .root_module = tests_mod });
    tests.root_module.addImport("fullaz", ctx.fullaz);
    if (demo.tests_need_zigline) {
        tests.root_module.addImport("zigline", ctx.zigline);
    }
    tests.root_module.addImport(demo.name, lib);
    applyTestFilter(b, tests, ctx.test_filter);

    const run_tests = b.addRunArtifact(tests);
    b.step(demo.test_step, demo.test_desc).dependOn(&run_tests.step);

    const wasm_lib = b.createModule(.{
        .root_source_file = b.path(demo.wasm_lib_source orelse demo.lib_source),
        .target = ctx.wasm_target,
        .optimize = .ReleaseSmall,
        .imports = &.{
            .{ .name = "fullaz", .module = ctx.fullaz_wasm },
        },
    });
    const wasm = b.addExecutable(.{
        .name = demo.name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(demo.wasm_source),
            .target = ctx.wasm_target,
            .optimize = .ReleaseSmall,
            .imports = &.{
                .{ .name = "fullaz", .module = ctx.fullaz_wasm },
                .{ .name = demo.name, .module = wasm_lib },
            },
        }),
    });
    wasm.entry = .disabled; // no _start; JS drives via the exports
    wasm.rdynamic = true; // export the `export fn`s

    const wasm_step = b.step(demo.wasm_step, demo.wasm_desc);
    const install_wasm = b.addInstallArtifact(wasm, .{
        .dest_dir = .{ .override = .{ .custom = demo.web_dir } },
    });
    wasm_step.dependOn(&install_wasm.step);
    const install_html = b.addInstallFile(
        b.path(demo.web_index),
        b.fmt("{s}/index.html", .{demo.web_dir}),
    );
    wasm_step.dependOn(&install_html.step);
}
