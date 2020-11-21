const Builder = @import("std").build.Builder;

pub fn build(b: *Builder) void {
    const mode = b.standardReleaseOptions();
    const lib = b.addStaticLibrary("zss", "source/main.zig");
    lib.setBuildMode(mode);
    lib.addPackagePath("prefix-tree", "./dependencies/zig-data-structures/source/prefix_tree.zig");
    lib.install();

    var main_tests = b.addTest("source/main.zig");
    main_tests.setBuildMode(mode);
    main_tests.addPackagePath("prefix-tree", "./dependencies/zig-data-structures/source/prefix_tree.zig");

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&main_tests.step);
}
