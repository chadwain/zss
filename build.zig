const std = @import("std");
const Builder = std.build.Builder;

pub fn build(b: *Builder) void {
    const prefixTreePkg = std.build.Pkg{
        .name = "prefix-tree",
        .path = "dependencies/zig-data-structures/source/prefix_tree.zig",
    };
    const zssPkg = std.build.Pkg{
        .name = "zss",
        .path = "zss.zig",
        .dependencies = &[_]std.build.Pkg{prefixTreePkg},
    };

    const mode = b.standardReleaseOptions();
    const lib = b.addStaticLibrary("zss", "zss.zig");
    lib.setBuildMode(mode);
    lib.addPackage(zssPkg);
    lib.install();

    var main_tests = b.addTest("zss.zig");
    main_tests.setBuildMode(mode);
    main_tests.addPackage(prefixTreePkg);
    main_tests.addPackage(zssPkg);
    main_tests.linkSystemLibrary("c");
    main_tests.linkSystemLibrary("freetype");
    main_tests.addIncludeDir("dependencies/freetype/");
    main_tests.linkSystemLibrary("harfbuzz");
    main_tests.linkSystemLibrary("SDL2");

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&main_tests.step);

    var extra_tests = b.addTest("test/test.zig");
    extra_tests.setBuildMode(mode);
    extra_tests.addPackage(zssPkg);
    extra_tests.linkSystemLibrary("c");
    extra_tests.linkSystemLibrary("freetype");
    extra_tests.addIncludeDir("dependencies/freetype/");
    extra_tests.linkSystemLibrary("harfbuzz");
    extra_tests.linkSystemLibrary("SDL2");

    const extra_test_step = b.step("extra-test", "Run extra tests");
    extra_test_step.dependOn(&extra_tests.step);
}
