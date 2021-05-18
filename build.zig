const std = @import("std");
const Builder = std.build.Builder;
const Pkg = std.build.Pkg;

const pkgs = struct {
    const harfbuzz = Pkg{
        .name = "harfbuzz",
        .path = "dependencies/harfbuzz.zig",
    };
    const freetype = Pkg{
        .name = "freetype",
        .path = "dependencies/freetype.zig",
        .dependencies = &[_]Pkg{harfbuzz},
    };
    const SDL2 = Pkg{
        .name = "SDL2",
        .path = "dependencies/SDL2.zig",
    };
    const zss = Pkg{
        .name = "zss",
        .path = "zss.zig",
        .dependencies = &[_]Pkg{ harfbuzz, SDL2, freetype },
    };
};

pub const graphical_tests = blk: {
    const Test = struct {
        name: []const u8,
        root: []const u8,
    };

    break :blk [_]Test{
        Test{ .name = "block_format", .root = "test/block_formatting.zig" },
        Test{ .name = "inline_format", .root = "test/inline_formatting.zig" },
    };
};

pub fn build(b: *Builder) void {
    const mode = b.standardReleaseOptions();
    const target = b.standardTargetOptions(.{});

    const lib = b.addStaticLibrary("zss", "zss.zig");
    lib.setBuildMode(mode);
    lib.setTarget(target);
    lib.install();

    var main_tests = b.addTest("zss.zig");
    main_tests.setBuildMode(mode);
    main_tests.setTarget(target);
    main_tests.addPackage(pkgs.harfbuzz);
    main_tests.linkLibC();
    main_tests.linkSystemLibrary("harfbuzz");

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&main_tests.step);

    const graphical_test_step = b.step("graphical-test", "Build graphical tests");
    inline for (graphical_tests) |t| {
        var test_exec = b.addExecutable(t.name, t.root);
        test_exec.setBuildMode(mode);
        test_exec.setTarget(target);
        test_exec.addPackage(pkgs.harfbuzz);
        test_exec.addPackage(pkgs.freetype);
        test_exec.addPackage(pkgs.SDL2);
        test_exec.addPackage(pkgs.zss);
        test_exec.linkLibC();
        test_exec.linkSystemLibrary("harfbuzz");
        test_exec.linkSystemLibrary("freetype");
        test_exec.linkSystemLibrary("SDL2");
        test_exec.linkSystemLibrary("SDL2_image");
        test_exec.install();

        graphical_test_step.dependOn(&test_exec.step);
    }

    const demo_step = b.step("demo", "Build the demo");
    var demo_exec = b.addExecutable("demo", "demo/demo1.zig");
    demo_exec.setBuildMode(mode);
    demo_exec.setTarget(target);
    demo_exec.addPackage(pkgs.harfbuzz);
    demo_exec.addPackage(pkgs.freetype);
    demo_exec.addPackage(pkgs.SDL2);
    demo_exec.addPackage(pkgs.zss);
    demo_exec.linkLibC();
    demo_exec.linkSystemLibrary("harfbuzz");
    demo_exec.linkSystemLibrary("freetype");
    demo_exec.linkSystemLibrary("SDL2");
    demo_exec.linkSystemLibrary("SDL2_image");
    demo_exec.install();
    demo_step.dependOn(&demo_exec.step);
}
