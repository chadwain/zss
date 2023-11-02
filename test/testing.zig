const zss = @import("zss");
const ElementTree = zss.ElementTree;
const Element = ElementTree.Element;

const std = @import("std");
const assert = std.debug.assert;

const hb = @import("harfbuzz");

pub const Test = @import("./Test.zig");

pub const allocator = gpa.allocator();
var gpa = std.heap.GeneralPurposeAllocator(.{}){};

var library: hb.FT_Library = undefined;

const Category = enum {
    validation,
    memory,
    sdl,
    print,
};

const categories = blk: {
    const build_options = @import("build_options");
    const tests = build_options.tests;

    var result: [tests.len]Category = undefined;
    for (tests, &result) |t, *category| {
        category.* = std.meta.stringToEnum(Category, t) orelse @compileError("Invalid test category: " ++ t);
    }
    break :blk result;
};

pub fn main() !void {
    defer assert(gpa.deinit() == .ok);

    assert(hb.FT_Init_FreeType(&library) == 0);
    defer _ = hb.FT_Done_FreeType(library);

    var tests: [all_tests.len]Test = undefined;
    inline for (all_tests, &tests) |test_info, *t| {
        setupTest(t, test_info);
    }
    defer for (&tests) |*t| {
        deinitTest(t);
    };

    for (categories, 0..) |c, i| {
        switch (c) {
            .validation => try @import("./validation.zig").run(&tests),
            .memory => try @import("./memory.zig").run(&tests),
            .sdl => try @import("./sdl.zig").run(&tests),
            .print => try @import("./print.zig").run(&tests),
        }
        if (i + 1 < categories.len) {
            std.debug.print("\n", .{});
        }
    }
}

fn setupTest(t: *Test, info: TestInfo) void {
    t.* = Test.init();
    info[1](t);
    t.name = info[0];
    t.slice = t.element_tree.slice();

    if (!t.root.eqlNull()) {
        assert(hb.FT_New_Face(library, t.font.ptr, 0, &t.ft_face) == 0);
        assert(hb.FT_Set_Char_Size(t.ft_face, 0, @as(c_int, @intCast(t.font_size)) * 64, 96, 96) == 0);

        t.hb_font = blk: {
            const hb_font = hb.hb_ft_font_create_referenced(t.ft_face).?;
            hb.hb_ft_font_set_funcs(hb_font);
            break :blk hb_font;
        };

        const slice = t.element_tree.slice();
        const cv = slice.ptr(.cascaded_values, t.root);
        cv.add(slice.arena, .font, .{ .font = .{ .font = t.hb_font.? } }) catch |err| fail(err);
        cv.add(slice.arena, .color, .{ .color = .{ .rgba = t.font_color } }) catch |err| fail(err);
    } else {
        t.ft_face = undefined;
        t.hb_font = null;
    }
}

fn fail(err: anyerror) noreturn {
    std.debug.print("Error while setting up a test: {s}\n", .{@errorName(err)});
    std.os.abort();
}

fn deinitTest(t: *Test) void {
    t.element_tree.deinit();
    if (t.hb_font) |font| {
        hb.hb_font_destroy(font);
        _ = hb.FT_Done_Face(t.ft_face);
    }
}

pub const TestInfo = std.meta.Tuple(&[2]type{ []const u8, *const fn (*Test) void });

const all_tests = blk: {
    const modules = [_]type{
        @import("./tests/empty_tree.zig"),
        @import("./tests/single_element.zig"),
        @import("./tests/two_elements.zig"),
        @import("./tests/block_inline_text.zig"),
        @import("./tests/simple_text.zig"),
        @import("./tests/shrink_to_fit.zig"),
        @import("./tests/position_relative.zig"),
    };

    var num_tests = 0;
    for (modules) |m| {
        if (@hasDecl(m, "tests")) {
            if (!std.meta.trait.is(.Array)(@TypeOf(m.tests)) or std.meta.Child(@TypeOf(m.tests)) != TestInfo) {
                @compileError("field 'tests' of struct '" ++ @typeName(m) ++ "' must be of type [N]" ++ @typeName(TestInfo));
            }
            num_tests += m.tests.len;
        } else {
            num_tests += 1;
        }
    }

    var result: [num_tests]TestInfo = undefined;
    var i = 0;
    for (modules) |m| {
        if (@hasDecl(m, "tests")) {
            for (m.tests) |test_info| {
                result[i] = TestInfo{ m.name ++ " - " ++ test_info[0], test_info[1] };
                i += 1;
            }
        } else {
            result[i] = TestInfo{ m.name, m.setup };
            i += 1;
        }
    }
    break :blk result;
};

pub const strings = [_][]const u8{
    "sample text",
    "The quick brown fox jumps over the lazy dog",
};

pub const fonts = [_][:0]const u8{
    "demo/NotoSans-Regular.ttf",
};

pub const colors = [_]zss.values.types.Color{
    .{ .rgba = 0x8795c7ff },
    .{ .rgba = 0x46bb4fff },
    .{ .rgba = 0xe0e0acff },
    .{ .rgba = 0x57d9cdff },
};

pub const border_color_sets = [_][]const zss.properties.BorderColors{
    &.{
        .{ .inline_start_color = .{ .rgba = 0x1e3c7bff }, .inline_end_color = .{ .rgba = 0xc5b6f7ff }, .block_start_color = .{ .rgba = 0x8e5085ff }, .block_end_color = .{ .rgba = 0xfdc409ff } },
        .{ .inline_start_color = .{ .rgba = 0xe5bb0dff }, .inline_end_color = .{ .rgba = 0x46eefcff }, .block_start_color = .{ .rgba = 0xa4504bff }, .block_end_color = .{ .rgba = 0xb43430ff } },
        .{ .inline_start_color = .{ .rgba = 0x8795c7ff }, .inline_end_color = .{ .rgba = 0x46bb4fff }, .block_start_color = .{ .rgba = 0xe0e0acff }, .block_end_color = .{ .rgba = 0x57d9cdff } },
        .{ .inline_start_color = .{ .rgba = 0x9cd82fff }, .inline_end_color = .{ .rgba = 0x53d6bdff }, .block_start_color = .{ .rgba = 0x5469a9ff }, .block_end_color = .{ .rgba = 0x66cb11ff } },
        .{ .inline_start_color = .{ .rgba = 0x1fb338ff }, .inline_end_color = .{ .rgba = 0xa1314aff }, .block_start_color = .{ .rgba = 0xca2c76ff }, .block_end_color = .{ .rgba = 0xc462e9ff } },
        .{ .inline_start_color = .{ .rgba = 0xb0afb5ff }, .inline_end_color = .{ .rgba = 0x74b703ff }, .block_start_color = .{ .rgba = 0xab42d3ff }, .block_end_color = .{ .rgba = 0x753ed2ff } },
        .{ .inline_start_color = .{ .rgba = 0xf4372cff }, .inline_end_color = .{ .rgba = 0xf1bc8dff }, .block_start_color = .{ .rgba = 0xb4c284ff }, .block_end_color = .{ .rgba = 0xb509b7ff } },
        .{ .inline_start_color = .{ .rgba = 0xa7faeaff }, .inline_end_color = .{ .rgba = 0xe0931dff }, .block_start_color = .{ .rgba = 0x11cff8ff }, .block_end_color = .{ .rgba = 0x423d8fff } },
    },
};
