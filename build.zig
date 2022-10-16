const std = @import("std");
const Builder = std.build.Builder;
const Pkg = std.build.Pkg;

const pkgs = struct {
    const harfbuzz = Pkg{
        .name = "harfbuzz",
        .source = .{ .path = "dependencies/harfbuzz.zig" },
    };
    const SDL2 = Pkg{
        .name = "SDL2",
        .source = .{ .path = "dependencies/SDL2.zig" },
    };
};

// All of our artifacts will be built with stage1 because zss uses async/await.

pub fn build(b: *Builder) void {
    const mode = b.standardReleaseOptions();
    const target = b.standardTargetOptions(.{});

    const zss_lib = b.addStaticLibrary("zss", "zss.zig");
    zss_lib.setBuildMode(mode);
    zss_lib.setTarget(target);
    zss_lib.use_stage1 = true;
    zss_lib.install();

    addTests(b, mode, target);
    addDemo(b, mode, target);
}

fn addTests(b: *Builder, mode: std.builtin.Mode, target: std.zig.CrossTarget) void {
    const all_tests_step = b.step("test", "Run all tests");

    var lib_tests = b.addTest("zss.zig");
    lib_tests.setBuildMode(mode);
    lib_tests.setTarget(target);
    lib_tests.addPackage(pkgs.harfbuzz);
    lib_tests.linkLibC();
    lib_tests.linkSystemLibrary("harfbuzz");
    lib_tests.linkSystemLibrary("freetype2");
    lib_tests.use_stage1 = true;
    const lib_tests_step = b.step("test-lib", "Run library tests");
    lib_tests_step.dependOn(&lib_tests.step);

    var test_suite = b.addExecutable("test-suite", "test/testing.zig");
    test_suite.setBuildMode(mode);
    test_suite.setTarget(target);
    test_suite.linkLibC();
    test_suite.linkSystemLibrary("harfbuzz");
    test_suite.linkSystemLibrary("freetype2");
    test_suite.linkSystemLibrary("SDL2");
    test_suite.addPackage(pkgs.harfbuzz);
    test_suite.addPackage(pkgs.SDL2);
    test_suite.addPackage(Pkg{
        .name = "zss",
        .source = .{ .path = "zss.zig" },
        .dependencies = &[_]Pkg{ pkgs.harfbuzz, pkgs.SDL2 },
    });
    test_suite.use_stage1 = true;
    test_suite.install();

    const test_category_filter = b.option([]const []const u8, "tests", "List of test categories to run");
    const test_suite_options = b.addOptions();
    test_suite.addOptions("build_options", test_suite_options);
    test_suite_options.addOption([]const []const u8, "tests", test_category_filter orelse &[_][]const u8{ "validation", "memory" });

    var run_test_suite = test_suite.run();
    run_test_suite.step.dependOn(&test_suite.step);

    const test_suite_step = b.step("test-suite", "Run the test suite");
    test_suite_step.dependOn(&run_test_suite.step);

    all_tests_step.dependOn(&lib_tests.step);
    all_tests_step.dependOn(&run_test_suite.step);
}

fn addDemo(b: *Builder, mode: std.builtin.Mode, target: std.zig.CrossTarget) void {
    var demo_exe = b.addExecutable("demo", "demo/demo.zig");
    demo_exe.addPackage(pkgs.harfbuzz);
    demo_exe.addPackage(pkgs.SDL2);
    demo_exe.addPackage(Pkg{
        .name = "zss",
        .source = .{ .path = "zss.zig" },
        .dependencies = &[_]Pkg{ pkgs.harfbuzz, pkgs.SDL2 },
    });
    demo_exe.linkLibC();
    demo_exe.linkSystemLibrary("harfbuzz");
    demo_exe.linkSystemLibrary("freetype2");
    demo_exe.linkSystemLibrary("SDL2");
    demo_exe.linkSystemLibrary("SDL2_image");
    demo_exe.setBuildMode(mode);
    demo_exe.setTarget(target);
    demo_exe.use_stage1 = true;
    demo_exe.install();

    var demo_cmd = demo_exe.run();
    if (b.args) |args| demo_cmd.addArgs(args);
    demo_cmd.step.dependOn(&demo_exe.step);

    const demo_step = b.step("demo", "Run the demo");
    demo_step.dependOn(&demo_cmd.step);
}
