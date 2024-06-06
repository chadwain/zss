const std = @import("std");
const Build = std.Build;
const Module = Build.Module;
const OptimizeMode = std.builtin.OptimizeMode;
const ResolvedTarget = Build.ResolvedTarget;

pub fn build(b: *Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});
    const mods = getModules(b, optimize, target);

    addTests(b, optimize, target, mods);
    addDemo(b, optimize, target, mods);
    addExamples(b, optimize, target, mods);
}

const Modules = struct {
    zss: *Module,
    mach_glfw: *Module,
    mach_harfbuzz: *Module,
    // sdl2: *Module,
    zgl: *Module,
    zigimg: *Module,
};

fn getModules(b: *Build, optimize: OptimizeMode, target: ResolvedTarget) Modules {
    var mods: Modules = undefined;

    const mach_freetype_dep = b.dependency("mach-freetype", .{
        .optimize = optimize,
        .target = target,
    });
    mods.mach_harfbuzz = mach_freetype_dep.module("mach-harfbuzz");

    // mods.sdl2 = b.createModule(.{
    //     .root_source_file = b.path("dependencies/SDL2.zig"),
    //     .target = target,
    // });
    // mods.sdl2.linkSystemLibrary("SDL2", .{});
    // if (target.result.os.tag == .windows) {
    //     mods.sdl2.linkSystemLibrary("gdi32", .{});
    //     mods.sdl2.linkSystemLibrary("imm32", .{});
    //     mods.sdl2.linkSystemLibrary("ole32", .{});
    //     mods.sdl2.linkSystemLibrary("oleaut32", .{});
    //     mods.sdl2.linkSystemLibrary("setupapi", .{});
    //     mods.sdl2.linkSystemLibrary("version", .{});
    //     mods.sdl2.linkSystemLibrary("winmm", .{});
    // }

    const zgl_dep = b.dependency("zgl", .{});
    mods.zgl = zgl_dep.module("zgl");

    const zigimg_dep = b.dependency("zigimg", .{});
    mods.zigimg = zigimg_dep.module("zigimg");

    const mach_glfw_dep = b.dependency("mach-glfw", .{
        .optimize = optimize,
        .target = target,
    });
    mods.mach_glfw = mach_glfw_dep.module("mach-glfw");

    mods.zss = b.addModule("zss", .{
        .root_source_file = b.path("source/zss.zig"),
        .imports = &.{
            .{ .name = "mach-harfbuzz", .module = mods.mach_harfbuzz },
            .{ .name = "mach-glfw", .module = mods.mach_glfw },
            // TODO: Only import SDL2 if necessary
            // TODO: Only import zgl if necessary
            // .{ .name = "SDL2", .module = mods.sdl2 },
            .{ .name = "zgl", .module = mods.zgl },
        },
        .target = target,
        .optimize = optimize,
    });

    return mods;
}

fn addTests(b: *Build, optimize: OptimizeMode, target: ResolvedTarget, mods: Modules) void {
    // Unit tests

    const unit_tests = b.addTest(.{
        .name = "zss-unit-tests",
        .root_source_file = b.path("source/zss.zig"),
        .target = target,
        .optimize = optimize,
    });
    unit_tests.root_module.addImport("mach-harfbuzz", mods.mach_harfbuzz);
    b.installArtifact(unit_tests);

    const unit_tests_step = b.step("test-units", "Run unit tests");
    const run_unit_tests = b.addRunArtifact(unit_tests);
    unit_tests_step.dependOn(&run_unit_tests.step);

    // Larger test suite

    const test_suite = b.addExecutable(.{
        .name = "zss-test-suite",
        .root_source_file = b.path("test/testing.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_suite.root_module.addImport("zss", mods.zss);
    test_suite.root_module.addImport("mach-glfw", mods.mach_glfw);
    test_suite.root_module.addImport("mach-harfbuzz", mods.mach_harfbuzz);
    test_suite.root_module.addImport("zgl", mods.zgl);
    test_suite.root_module.addImport("zigimg", mods.zigimg);
    // test_suite.root_module.addImport("SDL2", mods.sdl2);
    b.installArtifact(test_suite);

    const test_category_filter = b.option([]const []const u8, "tests", "List of test categories to run");
    const test_suite_options = b.addOptions();
    test_suite.root_module.addOptions("build-options", test_suite_options);
    test_suite_options.addOption([]const []const u8, "tests", test_category_filter orelse &[_][]const u8{ "validation", "memory" });

    const test_suite_step = b.step("test-suite", "Run the test suite");
    const run_test_suite = b.addRunArtifact(test_suite);
    test_suite_step.dependOn(&run_test_suite.step);

    // All tests at once

    const all_tests_step = b.step("test-all", "Run all tests");
    all_tests_step.dependOn(&run_unit_tests.step);
    all_tests_step.dependOn(&run_test_suite.step);
}

fn addDemo(b: *Build, optimize: OptimizeMode, target: ResolvedTarget, mods: Modules) void {
    // const demo = b.addExecutable(.{
    //     .name = "demo",
    //     .root_source_file = b.path("demo/demo.zig"),
    //     .target = target,
    //     .optimize = optimize,
    // });
    // demo.root_module.addImport("zss", mods.zss);
    // demo.root_module.addImport("mach-harfbuzz", mods.mach_harfbuzz);
    // demo.root_module.addImport("SDL2", mods.sdl2);
    // demo.linkSystemLibrary("SDL2_image");
    // b.installArtifact(demo);

    // const demo_step = b.step("demo", "Run a graphical demo program");
    // const run_demo = b.addRunArtifact(demo);
    // demo_step.dependOn(&run_demo.step);
    // if (b.args) |args| run_demo.addArgs(args);

    const demo_opengl = b.addExecutable(.{
        .name = "demo-opengl",
        .root_source_file = b.path("demo/demo_opengl.zig"),
        .target = target,
        .optimize = optimize,
    });
    demo_opengl.root_module.addAnonymousImport("zss", .{
        .root_source_file = b.path("source/zss.zig"),
        .imports = &.{
            .{ .name = "mach-harfbuzz", .module = mods.mach_harfbuzz },
            .{ .name = "zgl", .module = mods.zgl },
        },
        .target = target,
        .optimize = optimize,
    });
    demo_opengl.root_module.addImport("mach-harfbuzz", mods.mach_harfbuzz);
    demo_opengl.root_module.addImport("zgl", mods.zgl);
    demo_opengl.root_module.addImport("zigimg", mods.zigimg);
    demo_opengl.root_module.addImport("mach-glfw", mods.mach_glfw);
    b.installArtifact(demo_opengl);

    const demo_opengl_step = b.step("demo-opengl", "Run a graphical demo program");
    const run_demo_opengl = b.addRunArtifact(demo_opengl);
    demo_opengl_step.dependOn(&run_demo_opengl.step);
    if (b.args) |args| run_demo_opengl.addArgs(args);
}

fn addExamples(b: *Build, optimize: OptimizeMode, target: ResolvedTarget, mods: Modules) void {
    addExample(b, optimize, target, mods, "parse", "examples/parse.zig", "Run a parser program");
    addExample(b, optimize, target, mods, "usage", "examples/usage.zig", "Run an example usage program");
}

fn addExample(
    b: *Build,
    optimize: OptimizeMode,
    target: ResolvedTarget,
    mods: Modules,
    name: []const u8,
    path: []const u8,
    description: []const u8,
) void {
    const exe = b.addExecutable(.{
        .name = name,
        .root_source_file = b.path(path),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("zss", mods.zss);
    b.installArtifact(exe);

    const step = b.step(name, description);
    const run = b.addRunArtifact(exe);
    step.dependOn(&run.step);
    if (b.args) |args| run.addArgs(args);
}
