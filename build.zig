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
};

pub fn build(b: *Builder) void {
    const mode = b.standardReleaseOptions();
    const target = b.standardTargetOptions(.{});

    const zss_lib = b.addStaticLibrary("zss", "zss.zig");
    zss_lib.setBuildMode(mode);
    zss_lib.setTarget(target);
    zss_lib.install();

    var lib_tests = b.addTest("zss.zig");
    lib_tests.setBuildMode(mode);
    lib_tests.setTarget(target);
    lib_tests.addPackage(pkgs.harfbuzz);
    lib_tests.linkLibC();
    lib_tests.linkSystemLibrary("harfbuzz");

    const lib_tests_step = b.step("test", "Run the library tests");
    lib_tests_step.dependOn(&lib_tests.step);

    addDemo(b, mode, target);
}

fn addDemo(b: *Builder, mode: std.builtin.Mode, target: std.zig.CrossTarget) void {
    var demo_exe = b.addExecutable("demo", "demo/demo1.zig");
    linkSdl2Freetype(demo_exe);
    demo_exe.setBuildMode(mode);
    demo_exe.setTarget(target);

    var demo_cmd = demo_exe.run();
    if (b.args) |args| demo_cmd.addArgs(args);
    demo_cmd.step.dependOn(&demo_exe.step);

    const demo_step = b.step("demo", "Run the demo");
    demo_step.dependOn(&demo_cmd.step);
}

fn linkSdl2Freetype(exe: *std.build.LibExeObjStep) void {
    exe.addPackage(pkgs.harfbuzz);
    exe.addPackage(pkgs.freetype);
    exe.addPackage(pkgs.SDL2);
    exe.addPackage(Pkg{
        .name = "zss",
        .path = "zss.zig",
        .dependencies = &[_]Pkg{ pkgs.harfbuzz, pkgs.SDL2, pkgs.freetype },
    });
    exe.linkLibC();
    exe.linkSystemLibrary("harfbuzz");
    exe.linkSystemLibrary("freetype");
    exe.linkSystemLibrary("SDL2");
    exe.linkSystemLibrary("SDL2_image");
}
