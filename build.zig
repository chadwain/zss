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

    var validation_tests = b.addTest("test/validation.zig");
    validation_tests.setBuildMode(mode);
    validation_tests.setTarget(target);
    validation_tests.linkLibC();
    validation_tests.linkSystemLibrary("harfbuzz");
    validation_tests.linkSystemLibrary("freetype2");
    validation_tests.addPackage(pkgs.harfbuzz);
    validation_tests.addPackage(Pkg{
        .name = "zss",
        .source = .{ .path = "zss.zig" },
        .dependencies = &[_]Pkg{pkgs.harfbuzz},
    });
    validation_tests.use_stage1 = true;
    const validation_tests_step = b.step("test-validation", "Run validation tests");
    validation_tests_step.dependOn(&validation_tests.step);

    var memory_tests = b.addTest("test/memory.zig");
    memory_tests.setBuildMode(mode);
    memory_tests.setTarget(target);
    memory_tests.linkLibC();
    memory_tests.linkSystemLibrary("harfbuzz");
    memory_tests.linkSystemLibrary("freetype2");
    memory_tests.addPackage(pkgs.harfbuzz);
    memory_tests.addPackage(Pkg{
        .name = "zss",
        .source = .{ .path = "zss.zig" },
        .dependencies = &[_]Pkg{pkgs.harfbuzz},
    });
    memory_tests.use_stage1 = true;
    const memory_tests_step = b.step("test-memory", "Run memory tests");
    memory_tests_step.dependOn(&memory_tests.step);

    var sdl_tests = b.addTest("test/sdl.zig");
    sdl_tests.setBuildMode(mode);
    sdl_tests.setTarget(target);
    sdl_tests.linkLibC();
    sdl_tests.linkSystemLibrary("harfbuzz");
    sdl_tests.linkSystemLibrary("freetype2");
    sdl_tests.linkSystemLibrary("SDL2");
    sdl_tests.addPackage(pkgs.harfbuzz);
    sdl_tests.addPackage(pkgs.SDL2);
    sdl_tests.addPackage(Pkg{
        .name = "zss",
        .source = .{ .path = "zss.zig" },
        .dependencies = &[_]Pkg{ pkgs.harfbuzz, pkgs.SDL2 },
    });
    sdl_tests.use_stage1 = true;
    const sdl_tests_step = b.step("test-sdl", "Run SDL tests");
    sdl_tests_step.dependOn(&sdl_tests.step);

    all_tests_step.dependOn(&lib_tests.step);
    all_tests_step.dependOn(&validation_tests.step);
    all_tests_step.dependOn(&memory_tests.step);
    all_tests_step.dependOn(&sdl_tests.step);
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
