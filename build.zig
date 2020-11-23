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
    lib.addPackage(prefixTreePkg);
    lib.install();

    var main_tests = b.addTest("zss.zig");
    main_tests.setBuildMode(mode);
    main_tests.addPackage(prefixTreePkg);
    main_tests.linkSystemLibrary("SDL2");
    main_tests.linkSystemLibrary("c");

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&main_tests.step);

    var extra_tests = b.addTest("test/block_formatting.zig");
    extra_tests.setBuildMode(mode);
    extra_tests.addPackage(zssPkg);
    extra_tests.linkSystemLibrary("SDL2");
    extra_tests.linkSystemLibrary("c");

    const extra_test_step = b.step("extra-test", "Run extra tests");
    extra_test_step.dependOn(&extra_tests.step);
}
