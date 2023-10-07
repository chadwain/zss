const std = @import("std");
const Build = std.Build;
const Module = Build.Module;

const Modules = struct {
    harfbuzz: *Module,
    sdl2: *Module,
};

pub fn build(b: *Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    const zss_lib = b.addStaticLibrary(.{
        .name = "zss",
        .root_source_file = .{ .path = "zss.zig" },
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(zss_lib);

    const zss_step = b.step("zss", "Build zss");
    zss_step.dependOn(&zss_lib.step);

    const mods = Modules{
        .harfbuzz = b.createModule(.{ .source_file = .{ .path = "dependencies/harfbuzz.zig" } }),
        .sdl2 = b.createModule(.{ .source_file = .{ .path = "dependencies/SDL2.zig" } }),
    };

    addTests(b, optimize, target, mods);
    addDemo(b, optimize, target, mods);
    addExamples(b, optimize, target, mods);
}

fn addTests(b: *Build, optimize: std.builtin.Mode, target: std.zig.CrossTarget, mods: Modules) void {
    const all_tests_step = b.step("test", "Build all tests");

    const lib_tests = b.addTest(.{
        .name = "lib-tests",
        .root_source_file = .{ .path = "zss.zig" },
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    lib_tests.addModule("harfbuzz", mods.harfbuzz);
    lib_tests.linkSystemLibrary("harfbuzz");
    lib_tests.linkSystemLibrary("freetype2");
    b.installArtifact(lib_tests);

    const run_lib_tests = b.addRunArtifact(lib_tests);
    run_lib_tests.step.dependOn(&lib_tests.step);

    const lib_tests_step = b.step("test-lib", "Run library tests");
    lib_tests_step.dependOn(&run_lib_tests.step);

    const test_suite = b.addExecutable(.{
        .name = "test-suite",
        .root_source_file = .{ .path = "test/testing.zig" },
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_suite.linkSystemLibrary("harfbuzz");
    test_suite.linkSystemLibrary("freetype2");
    test_suite.linkSystemLibrary("SDL2");
    test_suite.addModule("harfbuzz", mods.harfbuzz);
    test_suite.addModule("SDL2", mods.sdl2);
    test_suite.addAnonymousModule("zss", .{
        .source_file = .{ .path = "zss.zig" },
        .dependencies = &.{
            .{ .name = "harfbuzz", .module = mods.harfbuzz },
            .{ .name = "SDL2", .module = mods.sdl2 },
        },
    });
    b.installArtifact(test_suite);

    const test_category_filter = b.option([]const []const u8, "tests", "List of test categories to run");
    const test_suite_options = b.addOptions();
    test_suite.addOptions("build_options", test_suite_options);
    test_suite_options.addOption([]const []const u8, "tests", test_category_filter orelse &[_][]const u8{ "validation", "memory" });

    const run_test_suite = b.addRunArtifact(test_suite);
    run_test_suite.step.dependOn(&test_suite.step);

    const test_suite_step = b.step("test-suite", "Run the test suite");
    test_suite_step.dependOn(&run_test_suite.step);

    all_tests_step.dependOn(&run_lib_tests.step);
    all_tests_step.dependOn(&run_test_suite.step);
}

fn addDemo(b: *Build, optimize: std.builtin.Mode, target: std.zig.CrossTarget, mods: Modules) void {
    var demo_exe = b.addExecutable(.{
        .name = "demo",
        .root_source_file = .{ .path = "demo/demo.zig" },
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    demo_exe.addModule("harfbuzz", mods.harfbuzz);
    demo_exe.addModule("SDL2", mods.sdl2);
    demo_exe.addAnonymousModule("zss", .{
        .source_file = .{ .path = "zss.zig" },
        .dependencies = &.{
            .{ .name = "harfbuzz", .module = mods.harfbuzz },
            .{ .name = "SDL2", .module = mods.sdl2 },
        },
    });
    demo_exe.linkSystemLibrary("harfbuzz");
    demo_exe.linkSystemLibrary("freetype2");
    demo_exe.linkSystemLibrary("SDL2");
    demo_exe.linkSystemLibrary("SDL2_image");
    b.installArtifact(demo_exe);

    const demo_cmd = b.addRunArtifact(demo_exe);
    if (b.args) |args| demo_cmd.addArgs(args);
    demo_cmd.step.dependOn(&demo_exe.step);

    const demo_step = b.step("demo", "Run the demo");
    demo_step.dependOn(&demo_cmd.step);
}

fn addExamples(b: *Build, optimize: std.builtin.Mode, target: std.zig.CrossTarget, mods: Modules) void {
    addExample(b, optimize, target, mods, "parse", "examples/parse.zig", "Run a parser program");
    addExample(b, optimize, target, mods, "usage", "examples/usage.zig", "Run an example-usage program");
}

fn addExample(
    b: *Build,
    optimize: std.builtin.Mode,
    target: std.zig.CrossTarget,
    mods: Modules,
    name: []const u8,
    path: []const u8,
    description: []const u8,
) void {
    var exe = b.addExecutable(.{
        .name = name,
        .root_source_file = .{ .path = path },
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe.addAnonymousModule("zss", .{
        .source_file = .{ .path = "zss.zig" },
        .dependencies = &.{
            .{ .name = "harfbuzz", .module = mods.harfbuzz },
        },
    });
    exe.linkSystemLibrary("harfbuzz");
    b.installArtifact(exe);

    const cmd = b.addRunArtifact(exe);
    if (b.args) |args| cmd.addArgs(args);
    cmd.step.dependOn(&exe.step);

    const step = b.step(name, description);
    step.dependOn(&cmd.step);
}
