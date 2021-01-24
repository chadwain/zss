const std = @import("std");
const Builder = std.build.Builder;
const Pkg = std.build.Pkg;

const prefixTreePkg = Pkg{
    .name = "prefix-tree-map",
    .path = "dependencies/zig-data-structures/source/prefix_tree_map.zig",
};
const harfbuzzPkg = Pkg{
    .name = "harfbuzz",
    .path = "dependencies/harfbuzz.zig",
};
const freetypePkg = Pkg{
    .name = "freetype",
    .path = "dependencies/freetype.zig",
    .dependencies = &[_]Pkg{harfbuzzPkg},
};
const SDL2Pkg = Pkg{
    .name = "SDL2",
    .path = "dependencies/SDL2.zig",
};
const zssPkg = Pkg{
    .name = "zss",
    .path = "zss.zig",
    .dependencies = &[_]Pkg{ prefixTreePkg, freetypePkg, SDL2Pkg },
};

pub fn build(b: *Builder) void {
    const freetype_system_include_dir = b.option(
        []const u8,
        "freetype-dir",
        "the location of the header files for freetype",
    ) orelse "/usr/include/freetype2/";

    const mode = b.standardReleaseOptions();
    const lib = b.addStaticLibrary("zss", "zss.zig");
    lib.setBuildMode(mode);
    lib.addPackage(zssPkg);
    lib.install();

    var main_tests = b.addTest("zss.zig");
    main_tests.setBuildMode(mode);
    main_tests.addPackage(prefixTreePkg);
    main_tests.addPackage(freetypePkg);
    main_tests.addPackage(SDL2Pkg);
    main_tests.addPackage(zssPkg);
    main_tests.linkSystemLibrary("c");
    main_tests.linkSystemLibrary("freetype");
    main_tests.addIncludeDir(freetype_system_include_dir);
    main_tests.linkSystemLibrary("SDL2");

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&main_tests.step);

    var graphical_tests = b.addTest("test/test.zig");
    graphical_tests.setBuildMode(mode);
    graphical_tests.addPackage(harfbuzzPkg);
    graphical_tests.addPackage(SDL2Pkg);
    graphical_tests.addPackage(zssPkg);
    graphical_tests.linkSystemLibrary("c");
    graphical_tests.linkSystemLibrary("freetype");
    graphical_tests.addSystemIncludeDir(freetype_system_include_dir);
    graphical_tests.linkSystemLibrary("harfbuzz");
    graphical_tests.linkSystemLibrary("SDL2");

    const graphical_test_step = b.step("graphical-test", "Run graphical tests");
    graphical_test_step.dependOn(&graphical_tests.step);
}
