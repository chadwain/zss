const std = @import("std");
const Build = std.Build;
const LazyPath = Build.LazyPath;
const Module = Build.Module;
const OptimizeMode = std.builtin.OptimizeMode;
const ResolvedTarget = Build.ResolvedTarget;
const Step = Build.Step;

pub fn build(b: *Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    _ = b.addModule("zss", .{
        .root_source_file = b.path("source/zss.zig"),
        .target = target,
        .optimize = optimize,
    });

    const mods = getModules(b, optimize, target);
    const unit_tests = addUnitTests(b, optimize, target, mods);
    const test_suite = addTestSuite(b, optimize, target, mods);
    addDemo(b, optimize, target, mods);
    addExamples(b, optimize, target, mods);

    const all_tests = b.step("test", "Run all tests");
    all_tests.dependOn(&unit_tests.step);
    all_tests.dependOn(&test_suite.step);
}

const Modules = struct {
    mach_glfw: *Module,
    mach_harfbuzz: *Module,
    zgl: *Module,
    zigimg: *Module,
};

fn getModules(b: *Build, optimize: OptimizeMode, target: ResolvedTarget) Modules {
    const mach_freetype_dep = b.dependency("mach-freetype", .{
        .optimize = optimize,
        .target = target,
    });
    const mach_glfw_dep = b.dependency("mach-glfw", .{
        .optimize = optimize,
        .target = target,
    });
    const zigimg_dep = b.dependency("zigimg", .{});
    const zgl_dep = b.dependency("zgl", .{});

    return .{
        .mach_harfbuzz = mach_freetype_dep.module("mach-harfbuzz"),
        .mach_glfw = mach_glfw_dep.module("mach-glfw"),
        .zgl = zgl_dep.module("zgl"),
        .zigimg = zigimg_dep.module("zigimg"),
    };
}

fn addUnitTests(b: *Build, optimize: OptimizeMode, target: ResolvedTarget, mods: Modules) *Step.Run {
    const unit_tests = b.addTest(.{
        .name = "zss-unit-tests",
        .root_source_file = b.path("source/zss.zig"),
        .target = target,
        .optimize = optimize,
    });
    unit_tests.root_module.addImport("mach-harfbuzz", mods.mach_harfbuzz);
    b.installArtifact(unit_tests);

    const run = b.addRunArtifact(unit_tests);
    const step = b.step("test-units", "Run unit tests");
    step.dependOn(&run.step);

    return run;
}

fn addTestSuite(b: *Build, optimize: OptimizeMode, target: ResolvedTarget, mods: Modules) *Step.Run {
    const test_suite = b.addExecutable(.{
        .name = "zss-test-suite",
        .root_source_file = b.path("test/suite.zig"),
        .target = target,
        .optimize = optimize,
    });

    {
        const TestSuiteCategory = enum {
            check,
            memory,
            opengl,
        };

        const category_strings = b.option([]const []const u8, "test", "A test category to run (can be used multiple times)") orelse &.{};
        var category_set = std.enums.EnumSet(TestSuiteCategory).initEmpty();
        for (category_strings) |in| {
            const val = std.meta.stringToEnum(TestSuiteCategory, in) orelse std.debug.panic("Invalid, test suite category: {s}", .{in});
            category_set.insert(val);
        }

        var categories = std.BoundedArray([]const u8, std.meta.fields(TestSuiteCategory).len){};
        var it = category_set.iterator();
        while (it.next()) |category| categories.appendAssumeCapacity(@tagName(category));
        const options_module = b.addOptions();
        options_module.addOption([]const []const u8, "test_categories", categories.slice());

        test_suite.root_module.addOptions("build-options", options_module);
    }

    {
        const zss_mod = b.createModule(.{
            .root_source_file = b.path("source/zss.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "mach-harfbuzz", .module = mods.mach_harfbuzz },
                .{ .name = "zgl", .module = mods.zgl },
            },
        });
        test_suite.root_module.addImport("zss", zss_mod);
        test_suite.root_module.addImport("mach-harfbuzz", mods.mach_harfbuzz);
        test_suite.root_module.addImport("zgl", mods.zgl);
        test_suite.root_module.addImport("zigimg", mods.zigimg);
        test_suite.root_module.addImport("mach-glfw", mods.mach_glfw);
    }

    b.installArtifact(test_suite);
    const run = b.addRunArtifact(test_suite);
    const test_cases_path = b.path("test/cases");
    const resources_path = b.path("test/res");
    run.addDirectoryArg(test_cases_path);
    run.addDirectoryArg(resources_path);

    const step = b.step("test-suite", "Run the test suite");
    step.dependOn(&run.step);

    return run;
}

fn addDemo(b: *Build, optimize: OptimizeMode, target: ResolvedTarget, mods: Modules) void {
    const demo = b.addExecutable(.{
        .name = "demo",
        .root_source_file = b.path("demo/demo.zig"),
        .target = target,
        .optimize = optimize,
    });
    demo.root_module.addAnonymousImport("zss", .{
        .root_source_file = b.path("source/zss.zig"),
        .imports = &.{
            .{ .name = "mach-harfbuzz", .module = mods.mach_harfbuzz },
            .{ .name = "zgl", .module = mods.zgl },
        },
        .target = target,
        .optimize = optimize,
    });
    demo.root_module.addImport("mach-harfbuzz", mods.mach_harfbuzz);
    demo.root_module.addImport("zgl", mods.zgl);
    demo.root_module.addImport("zigimg", mods.zigimg);
    demo.root_module.addImport("mach-glfw", mods.mach_glfw);
    b.installArtifact(demo);

    const demo_step = b.step("demo", "Run a graphical demo program");
    const run_demo = b.addRunArtifact(demo);
    demo_step.dependOn(&run_demo.step);
    if (b.args) |args| run_demo.addArgs(args);
}

fn addExamples(b: *Build, optimize: OptimizeMode, target: ResolvedTarget, mods: Modules) void {
    const zss_mod = b.createModule(.{
        .root_source_file = b.path("source/zss.zig"),
        .imports = &.{
            .{ .name = "mach-harfbuzz", .module = mods.mach_harfbuzz },
        },
        .target = target,
        .optimize = optimize,
    });
    addExample(b, optimize, target, zss_mod, "parse", "examples/parse.zig", "Run an example parser program");
    addExample(b, optimize, target, zss_mod, "usage", "examples/usage.zig", "Run an example usage program");
}

fn addExample(
    b: *Build,
    optimize: OptimizeMode,
    target: ResolvedTarget,
    zss_mod: *Module,
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
    exe.root_module.addImport("zss", zss_mod);
    b.installArtifact(exe);

    const step = b.step(name, description);
    const run = b.addRunArtifact(exe);
    step.dependOn(&run.step);
    if (b.args) |args| run.addArgs(args);
}
