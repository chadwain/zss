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
    enable_harfbuzz: bool,
    enable_opengl: bool,
};

const deps = struct {
    fn addHarfbuzz(b: *Build, config: Config, module: *Module) void {
        if (!config.enable_harfbuzz) return;
        if (b.lazyDependency("harfbuzz", .{
            .optimize = config.optimize,
            .target = config.target,
        })) |harfbuzz| {
            module.addImport("harfbuzz", harfbuzz.module("harfbuzz"));
            module.linkLibrary(harfbuzz.artifact("harfbuzz"));
        }
    }

    fn addMachGlfw(b: *Build, config: Config, module: *Module) void {
        if (b.lazyDependency("mach-glfw", .{
            .optimize = config.optimize,
            .target = config.target,
        })) |mach_glfw| {
            module.addImport("mach-glfw", mach_glfw.module("mach-glfw"));
        }
    }

    fn addZgl(b: *Build, config: Config, module: *Module) void {
        if (!config.enable_opengl) return;
        if (b.lazyDependency("zgl", .{
            .optimize = config.optimize,
            .target = config.target,
        })) |zgl| {
            module.addImport("zgl", zgl.module("zgl"));
        }
    }

    fn addZigimg(b: *Build, config: Config, module: *Module) void {
        if (b.lazyDependency("zigimg", .{
            .optimize = config.optimize,
            .target = config.target,
        })) |zigimg| {
            module.addImport("zigimg", zigimg.module("zigimg"));
        }
    }
};

pub fn build(b: *Build) void {
    const config = Config{
        .optimize = b.standardOptimizeOption(.{}),
        .target = b.standardTargetOptions(.{}),
        .enable_harfbuzz = b.option(bool, "enable-harfbuzz", "Enable Harfbuzz support") orelse true,
        .enable_opengl = b.option(bool, "enable-opengl", "Enable OpenGL support") orelse true,
    };

    const zss = b.addModule("zss", .{
        .root_source_file = b.path("source/zss.zig"),
        .target = config.target,
        .optimize = config.optimize,
    });
    deps.addHarfbuzz(b, config, zss);
    deps.addZgl(b, config, zss);

    const unit_tests = addUnitTests(b, config);
    const test_suite = addTestSuite(b, config, zss);
    addDemo(b, config, zss);
    addExamples(b, config, zss);

    const all_tests = b.step("test", "Run all tests");
    all_tests.dependOn(&unit_tests.step);
    all_tests.dependOn(&test_suite.step);
}

fn addUnitTests(b: *Build, config: Config) *Step.Run {
    const unit_tests = b.addTest(.{
        .name = "zss-unit-tests",
        .root_source_file = b.path("source/zss.zig"),
        .target = config.target,
        .optimize = config.optimize,
    });
    deps.addHarfbuzz(b, config, unit_tests.root_module);

    const run = b.addRunArtifact(unit_tests);
    const install = b.addInstallArtifact(unit_tests, .{});
    const step = b.step("test-units", "Run unit tests");
    step.dependOn(&run.step);
    step.dependOn(&install.step);
    b.getInstallStep().dependOn(&install.step);

    return run;
}

fn addTestSuite(b: *Build, config: Config, zss: *Module) *Step.Run {
    const test_suite = b.addExecutable(.{
        .name = "zss-test-suite",
        .root_source_file = b.path("test/suite.zig"),
        .target = config.target,
        .optimize = config.optimize,
    });
    test_suite.root_module.addImport("zss", zss);
    deps.addHarfbuzz(b, config, test_suite.root_module);
    deps.addZgl(b, config, test_suite.root_module);
    deps.addZigimg(b, config, test_suite.root_module);

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

                switch (val) {
                    .check, .memory, .print => {},
                    .opengl => {
                        deps.addMachGlfw(b, config, test_suite.root_module);
                    },
                }
            }
        }

        const options_module = b.addOptions();
        options_module.addOption([]const []const u8, "test_categories", final_categories.slice());
        test_suite.root_module.addOptions("build-options", options_module);
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

fn addDemo(b: *Build, config: Config, zss: *Module) void {
    const demo = b.addExecutable(.{
        .name = "demo",
        .root_source_file = b.path("demo/demo.zig"),
        .target = config.target,
        .optimize = config.optimize,
    });
    demo.root_module.addImport("zss", zss);
    deps.addHarfbuzz(b, config, demo.root_module);
    deps.addZgl(b, config, demo.root_module);
    deps.addZigimg(b, config, demo.root_module);
    deps.addMachGlfw(b, config, demo.root_module);

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
