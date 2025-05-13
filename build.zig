const std = @import("std");
const Build = std.Build;
const Dependency = Build.Dependency;
const LazyPath = Build.LazyPath;
const Module = Build.Module;
const OptimizeMode = std.builtin.OptimizeMode;
const ResolvedTarget = Build.ResolvedTarget;
const Step = Build.Step;

const Config = struct {
    optimize: OptimizeMode,
    target: ResolvedTarget,
};

const Deps = struct {
    harfbuzz: *Dependency,
    zgl: *Dependency,

    fn machGlfw(b: *Build, config: Config) ?*Dependency {
        return b.lazyDependency("mach-glfw", .{
            .optimize = config.optimize,
            .target = config.target,
        });
    }

    fn zigimg(b: *Build, config: Config) ?*Dependency {
        return b.lazyDependency("zigimg", .{
            .optimize = config.optimize,
            .target = config.target,
        });
    }
};

pub fn build(b: *Build) void {
    const config = Config{
        .optimize = b.standardOptimizeOption(.{}),
        .target = b.standardTargetOptions(.{}),
    };

    const deps = Deps{
        .harfbuzz = b.dependency("harfbuzz", .{
            .optimize = config.optimize,
            .target = config.target,
        }),
        .zgl = b.dependency("zgl", .{
            .optimize = config.optimize,
            .target = config.target,
        }),
    };

    const zss = b.addModule("zss", .{
        .root_source_file = b.path("source/zss.zig"),
        .target = config.target,
        .optimize = config.optimize,
    });
    zss.addImport("harfbuzz", deps.harfbuzz.module("harfbuzz"));
    zss.addImport("zgl", deps.zgl.module("zgl"));
    zss.linkLibrary(deps.harfbuzz.artifact("harfbuzz"));

    const unit_tests = addUnitTests(b, config, deps);
    const test_suite = addTestSuite(b, config, deps, zss);
    addDemo(b, config, deps, zss);
    addExamples(b, config, zss);

    const all_tests = b.step("test", "Run all tests");
    all_tests.dependOn(&unit_tests.step);
    all_tests.dependOn(&test_suite.step);
}

fn addUnitTests(b: *Build, config: Config, deps: Deps) *Step.Run {
    const unit_tests = b.addTest(.{
        .name = "zss-unit-tests",
        .root_source_file = b.path("source/zss.zig"),
        .target = config.target,
        .optimize = config.optimize,
    });
    unit_tests.root_module.addImport("harfbuzz", deps.harfbuzz.module("harfbuzz"));
    unit_tests.linkLibrary(deps.harfbuzz.artifact("harfbuzz"));

    const run = b.addRunArtifact(unit_tests);
    const install = b.addInstallArtifact(unit_tests, .{});
    const step = b.step("test-units", "Run unit tests");
    step.dependOn(&run.step);
    step.dependOn(&install.step);
    b.getInstallStep().dependOn(&install.step);

    return run;
}

fn addTestSuite(b: *Build, config: Config, deps: Deps, zss: *Module) *Step.Run {
    const test_suite = b.addExecutable(.{
        .name = "zss-test-suite",
        .root_source_file = b.path("test/suite.zig"),
        .target = config.target,
        .optimize = config.optimize,
    });

    {
        const TestSuiteCategory = enum {
            check,
            memory,
            opengl,
            print,
        };

        const category_strings = b.option([]const []const u8, "test", "A test category to run (can be used multiple times)") orelse &.{};
        var category_set = std.enums.EnumSet(TestSuiteCategory).initEmpty();
        var final_categories = std.BoundedArray([]const u8, std.meta.fields(TestSuiteCategory).len){};
        for (category_strings) |in| {
            const val = std.meta.stringToEnum(TestSuiteCategory, in) orelse std.debug.panic("Invalid test suite category: {s}", .{in});
            if (!category_set.contains(val)) {
                category_set.insert(val);
                final_categories.appendAssumeCapacity(in);
            }
        }

        const options_module = b.addOptions();
        options_module.addOption([]const []const u8, "test_categories", final_categories.slice());
        test_suite.root_module.addOptions("build-options", options_module);
    }

    test_suite.root_module.addImport("zss", zss);
    test_suite.root_module.addImport("harfbuzz", deps.harfbuzz.module("harfbuzz"));
    test_suite.root_module.addImport("zgl", deps.zgl.module("zgl"));
    if (Deps.zigimg(b, config)) |zigimg| {
        test_suite.root_module.addImport("zigimg", zigimg.module("zigimg"));
    }
    if (Deps.machGlfw(b, config)) |mach_glfw| {
        test_suite.root_module.addImport("mach-glfw", mach_glfw.module("mach-glfw"));
    }

    const run = b.addRunArtifact(test_suite);
    const test_cases_path = b.path("test/cases");
    const resources_path = b.path("test/res");
    const output_path = b.path("test/output");
    run.addDirectoryArg(test_cases_path);
    run.addDirectoryArg(resources_path);
    run.addDirectoryArg(output_path);
    if (b.args) |args| run.addArgs(args);

    const install = b.addInstallArtifact(test_suite, .{});
    const step = b.step("test-suite", "Run the test suite");
    step.dependOn(&run.step);
    step.dependOn(&install.step);
    b.getInstallStep().dependOn(&install.step);

    return run;
}

fn addDemo(b: *Build, config: Config, deps: Deps, zss: *Module) void {
    const demo = b.addExecutable(.{
        .name = "demo",
        .root_source_file = b.path("demo/demo.zig"),
        .target = config.target,
        .optimize = config.optimize,
    });
    demo.root_module.addImport("zss", zss);
    demo.root_module.addImport("harfbuzz", deps.harfbuzz.module("harfbuzz"));
    demo.root_module.addImport("zgl", deps.zgl.module("zgl"));
    if (Deps.zigimg(b, config)) |zigimg| {
        demo.root_module.addImport("zigimg", zigimg.module("zigimg"));
    }
    if (Deps.machGlfw(b, config)) |mach_glfw| {
        demo.root_module.addImport("mach-glfw", mach_glfw.module("mach-glfw"));
    }

    const run = b.addRunArtifact(demo);
    if (b.args) |args| run.addArgs(args);
    const install = b.addInstallArtifact(demo, .{});
    const step = b.step("demo", "Run a graphical demo program");
    step.dependOn(&run.step);
    step.dependOn(&install.step);
    b.getInstallStep().dependOn(&install.step);
}

fn addExamples(b: *Build, config: Config, zss: *Module) void {
    addExample(b, config, zss, "parse", "examples/parse.zig", "Run an example parser program");
    addExample(b, config, zss, "usage", "examples/usage.zig", "Run an example usage program");
}

fn addExample(
    b: *Build,
    config: Config,
    zss: *Module,
    name: []const u8,
    path: []const u8,
    description: []const u8,
) void {
    const exe = b.addExecutable(.{
        .name = name,
        .root_source_file = b.path(path),
        .target = config.target,
        .optimize = config.optimize,
    });
    exe.root_module.addImport("zss", zss);
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    const install = b.addInstallArtifact(exe, .{});
    const step = b.step(name, description);
    step.dependOn(&run.step);
    step.dependOn(&install.step);
    b.getInstallStep().dependOn(&install.step);
}
