const zss = @import("zss");
const ElementTree = zss.ElementTree;
const CascadedValueStore = zss.CascadedValueStore;

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
    print,
};

const categories = blk: {
    const build_options = @import("build_options");
    const tests = build_options.tests;

    var result: [tests.len]Category = undefined;
    for (tests) |t, i| {
        result[i] = std.meta.stringToEnum(Category, t) orelse @compileError("Invalid test category: " ++ t);
    }
    break :blk result;
};

pub fn main() !void {
    defer assert(!gpa.deinit());

    assert(hb.FT_Init_FreeType(&library) == 0);
    defer _ = hb.FT_Done_FreeType(library);

    var tests: [all_tests.len]Test = undefined;
    inline for (all_tests) |test_info, i| {
        setupTest(&tests[i], test_info);
    }
    defer for (tests) |*t| {
        deinitTest(t);
    };

    for (categories) |c, i| {
        switch (c) {
            .validation => try @import("./validation.zig").run(&tests),
            .memory => try @import("./memory.zig").run(&tests),
            .print => try @import("./print.zig").run(&tests),
        }
        if (i + 1 < categories.len) {
            std.debug.print("\n", .{});
        }
    }
}

fn setupTest(t: *Test, info: TestInfo) void {
    t.* = Test{ .name = undefined, .ft_face = undefined, .hb_font = undefined };
    info[1](t);
    t.name = info[0];

    if (t.element_tree.size() > 0) {
        assert(hb.FT_New_Face(library, t.font, 0, &t.ft_face) == 0);
        assert(hb.FT_Set_Char_Size(t.ft_face, 0, @intCast(c_int, t.font_size) * 64, 96, 96) == 0);

        t.hb_font = blk: {
            const hb_font = hb.hb_ft_font_create_referenced(t.ft_face).?;
            hb.hb_ft_font_set_funcs(hb_font);
            break :blk hb_font;
        };

        t.cascaded_values.font.ensureUnusedCapacity(allocator, 1) catch |err| fail(err);
        t.cascaded_values.color.ensureUnusedCapacity(allocator, 1) catch |err| fail(err);
        t.cascaded_values.font.setAssumeCapacity(0, .{ .font = .{ .font = t.hb_font.? } });
        t.cascaded_values.color.setAssumeCapacity(0, .{ .color = .{ .rgba = t.font_color } });
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
    t.element_tree.deinit(allocator);
    t.cascaded_values.deinit(allocator);
    if (t.hb_font) |font| {
        hb.hb_font_destroy(font);
        _ = hb.FT_Done_Face(t.ft_face);
    }
}

pub const TestInfo = std.meta.Tuple(&[2]type{ []const u8, fn (*Test) void });

const all_tests = blk: {
    const modules = [_]type{
        @import("./tests/empty_tree.zig"),
        @import("./tests/single_element.zig"),
        @import("./tests/two_elements.zig"),
        @import("./tests/block_inline_text.zig"),
        @import("./tests/shrink_to_fit.zig"),
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

const ArrayList = undefined;
const TreeData = undefined;

fn getTestData() !ArrayList(TreeData) {
    var list = ArrayList(TreeData).init(allocator);
    try list.append(blk: {
        var tree_data = try TreeData.init(2, &.{ .box_style, .content_width, .content_height, .horizontal_edges, .background1 });
        const root = tree_data.createRoot();
        const root_0 = tree_data.insertChild(root);

        tree_data.set(.box_style, root, .{ .display = .block });
        tree_data.set(.content_height, root, .{ .size = .{ .px = 50 } });

        tree_data.set(.box_style, root_0, .{ .display = .block });
        tree_data.set(.content_width, root_0, .{ .size = .{ .px = 50 } });
        tree_data.set(.content_height, root_0, .{ .size = .{ .px = 50 } });
        tree_data.set(.horizontal_edges, root_0, .{ .margin_start = .auto, .margin_end = .auto });
        tree_data.set(.background1, root_0, .{ .color = .{ .rgba = 0x404070ff } });
        break :blk tree_data;
    });
    try list.append(blk: {
        var tree_data = try TreeData.init(5, &.{ .box_style, .z_index });
        const root = tree_data.createRoot();
        const root_0 = tree_data.insertChild(root);
        const root_1 = tree_data.insertChild(root);
        const root_2 = tree_data.insertChild(root);
        const root_3 = tree_data.insertChild(root);

        tree_data.set(.box_style, root, .{ .display = .block });
        tree_data.set(.box_style, root_0, .{ .display = .block, .position = .relative });
        tree_data.set(.box_style, root_1, .{ .display = .block, .position = .relative });
        tree_data.set(.box_style, root_2, .{ .display = .block, .position = .relative });
        tree_data.set(.box_style, root_3, .{ .display = .block, .position = .relative });

        tree_data.set(.z_index, root_0, .{ .z_index = .{ .integer = 6 } });
        tree_data.set(.z_index, root_1, .{ .z_index = .{ .integer = -2 } });
        tree_data.set(.z_index, root_2, .{ .z_index = .auto });
        tree_data.set(.z_index, root_3, .{ .z_index = .{ .integer = -5 } });
        break :blk tree_data;
    });
    try list.append(blk: {
        var tree_data = try TreeData.init(7, &.{ .box_style, .content_height, .background1, .text });
        const root = tree_data.createRoot();
        const root_0 = tree_data.insertChild(root);
        const root_1 = tree_data.insertChild(root);
        const root_2 = tree_data.insertChild(root);
        const root_3 = tree_data.insertChild(root);
        const root_3_0 = tree_data.insertChild(root_3);
        const root_4 = tree_data.insertChild(root);

        tree_data.set(.box_style, root, .{ .display = .block });

        tree_data.set(.box_style, root_0, .{ .display = .block });
        tree_data.set(.content_height, root_0, .{ .size = .{ .px = 50 } });
        tree_data.set(.background1, root_0, .{ .color = .{ .rgba = 0x508020ff } });

        tree_data.set(.box_style, root_1, .{ .display = .text });
        tree_data.set(.text, root_1, .{ .text = "stuff 1" });

        tree_data.set(.box_style, root_2, .{ .display = .block });
        tree_data.set(.content_height, root_2, .{ .size = .{ .px = 50 } });
        tree_data.set(.background1, root_2, .{ .color = .{ .rgba = 0x472658ff } });

        tree_data.set(.box_style, root_3, .{ .display = .inline_ });
        tree_data.set(.background1, root_3, .{ .color = .{ .rgba = 0xd74529ff } });

        tree_data.set(.box_style, root_3_0, .{ .display = .text });
        tree_data.set(.text, root_3_0, .{ .text = "stuff 2" });

        tree_data.set(.box_style, root_4, .{ .display = .block });
        tree_data.set(.content_height, root_4, .{ .size = .{ .px = 50 } });
        tree_data.set(.background1, root_4, .{ .color = .{ .rgba = 0xd5ad81ff } });
        break :blk tree_data;
    });
    try list.append(blk: {
        var tree_data = try TreeData.init(5, &.{ .box_style, .content_width, .content_height, .background1, .text });
        const root = tree_data.createRoot();
        const root_0 = tree_data.insertChild(root);
        const root_1 = tree_data.insertChild(root);
        const root_1_0 = tree_data.insertChild(root_1);
        const root_2 = tree_data.insertChild(root);

        tree_data.set(.box_style, root_0, .{ .display = .text });
        tree_data.set(.text, root_0, .{ .text = "abc\ndef" });

        tree_data.set(.box_style, root_1, .{ .display = .inline_block });
        tree_data.set(.content_width, root_1, .{ .size = .{ .px = 50 } });
        tree_data.set(.content_height, root_1, .{ .size = .{ .px = 50 } });
        tree_data.set(.background1, root_1, .{ .color = .{ .rgba = 0x48728fff } });

        tree_data.set(.box_style, root_1_0, .{ .display = .text });
        tree_data.set(.text, root_1_0, .{ .text = "123\n456" });

        tree_data.set(.box_style, root_2, .{ .display = .text });
        tree_data.set(.text, root_2, .{ .text = "666\n777" });
        break :blk tree_data;
    });
    // try list.append(blk: {
    //     var tree_data = try TreeData.init(6, &.{ .box_style, .content_width, .content_height, .horizontal_edges, .vertical_edges, .background1, .text });
    //     const root = tree_data.createRoot();
    //     const root_0 = tree_data.insertChild(root);
    //     const root_0_0 = tree_data.insertChild(root_0);
    //     const root_0_1 = tree_data.insertChild(root_0);
    //     const root_0_2 = tree_data.insertChild(root_0);
    //     const root_1 = tree_data.insertChild(root);

    //     tree_data.set(.box_style, root, .{ .display = .block });
    //     tree_data.set(.background1, root, .{ .color = .{ .rgba = 0x7ac638ff } });

    //     tree_data.set(.box_style, root_0, .{ .display = .inline_block });
    //     tree_data.set(.background1, root_0, .{ .color = .{ .rgba = 0x208050ff } });

    //     tree_data.set(.box_style, root_0_0, .{ .display = .block });
    //     tree_data.set(.content_width, root_0_0, .{ .size = .{ .px = 100 } });
    //     tree_data.set(.content_height, root_0_0, .{ .size = .{ .px = 50 } });
    //     tree_data.set(.horizontal_edges, root_0_0, .{ .padding_start = .{ .px = 10 }, .padding_end = .{ .px = 10 } });
    //     tree_data.set(.vertical_edges, root_0_0, .{ .padding_start = .{ .px = 10 }, .padding_end = .{ .px = 10 } });
    //     tree_data.set(.background1, root_0_0, .{ .color = .{ .rgba = 0x9f2034ff }, .clip = .content_box });

    //     tree_data.set(.box_style, root_0_1, .{ .display = .none });

    //     tree_data.set(.box_style, root_0_2, .{ .display = .block });
    //     tree_data.set(.content_width, root_0_2, .{ .size = .{ .px = 70 } });
    //     tree_data.set(.content_height, root_0_2, .{ .size = .{ .px = 70 } });
    //     tree_data.set(.horizontal_edges, root_0_2, .{ .padding_start = .{ .px = 10 }, .padding_end = .{ .px = 10 } });
    //     tree_data.set(.vertical_edges, root_0_2, .{ .padding_start = .{ .px = 10 }, .padding_end = .{ .px = 10 } });
    //     tree_data.set(.background1, root_0_2, .{ .color = .{ .rgba = 0x36ab8fff }, .clip = .content_box });

    //     tree_data.set(.box_style, root_1, .{ .display = .text });
    //     tree_data.set(.text, root_1, .{ .text = strings[1] });
    //     break :blk tree_data;
    // });
    //    try list.append(blk: {
    //        var tree_data = try TreeData.init(9, &.{ .box_style, .vertical_edges, .text, .background1 });
    //        const root = tree_data.createRoot();
    //        const inline_block_1 = tree_data.insertChild(root);
    //        const text_1 = tree_data.insertChild(inline_block_1);
    //        const inline_block_2 = tree_data.insertChild(inline_block_1);
    //        const text_2 = tree_data.insertChild(inline_block_2);
    //        const inline_block_3 = tree_data.insertChild(inline_block_2);
    //        const text_3 = tree_data.insertChild(inline_block_3);
    //        const inline_block_4 = tree_data.insertChild(inline_block_3);
    //        const text_4 = tree_data.insertChild(inline_block_4);
    //
    //        tree_data.set(.box_style, inline_block_1, .{ .display = .inline_block });
    //        tree_data.set(.vertical_edges, inline_block_1, .{ .padding_start = .{ .px = 10 } });
    //        tree_data.set(.background1, inline_block_1, .{ .color = .{ .rgba = 0x508020ff } });
    //
    //        tree_data.set(.box_style, inline_block_2, .{ .display = .inline_block });
    //        tree_data.set(.vertical_edges, inline_block_2, .{ .padding_start = .{ .px = 10 } });
    //        tree_data.set(.background1, inline_block_2, .{ .color = .{ .rgba = 0x805020ff } });
    //
    //        tree_data.set(.box_style, inline_block_3, .{ .display = .inline_block });
    //        tree_data.set(.vertical_edges, inline_block_3, .{ .padding_start = .{ .px = 10 } });
    //        tree_data.set(.background1, inline_block_3, .{ .color = .{ .rgba = 0x802050ff } });
    //
    //        tree_data.set(.box_style, inline_block_4, .{ .display = .inline_block });
    //        tree_data.set(.vertical_edges, inline_block_4, .{ .padding_start = .{ .px = 10 } });
    //        tree_data.set(.background1, inline_block_4, .{ .color = .{ .rgba = 0x208050ff } });
    //
    //        tree_data.set(.box_style, text_1, .{ .display = .text });
    //        tree_data.set(.text, text_1, .{ .text = "nested inline blocks  1 " });
    //
    //        tree_data.set(.box_style, text_2, .{ .display = .text });
    //        tree_data.set(.text, text_2, .{ .text = "2 " });
    //
    //        tree_data.set(.box_style, text_3, .{ .display = .text });
    //        tree_data.set(.text, text_3, .{ .text = "3 " });
    //
    //        tree_data.set(.box_style, text_4, .{ .display = .text });
    //        tree_data.set(.text, text_4, .{ .text = "4 " });
    //
    //        break :blk tree_data;
    //    });
    return list;
}

const tree_data_old = [_]TreeData{
    .{
        .structure = &.{ 7, 2, 1, 1, 2, 1, 1 },
        .display = &.{ .{ .block = {} }, .{ .block = {} }, .{ .text = {} }, .{ .text = {} }, .{ .inline_block = {} }, .{ .text = {} }, .{ .text = {} } },
        .inline_size = &.{ .{}, .{ .size = .{ .px = 400 } }, .{}, .{}, .{ .size = .{ .px = 100 } }, .{}, .{} },
        .block_size = &.{ .{}, .{ .size = .{ .px = 50 }, .margin_start = .{ .px = -20 } }, .{}, .{}, .{}, .{}, .{} },
        .latin1_text = &.{ .{}, .{}, .{ .text = "behind the inline block" }, .{ .text = "before the inline block... " }, .{}, .{ .text = "inside the inline block" }, .{ .text = " ...after the inline block" } },
        .background = &.{ .{}, .{ .color = .{ .rgba = 0x9f2034ff } }, .{}, .{}, .{ .color = .{ .rgba = 0x208420ff } }, .{}, .{} },
        .position = &.{ .{}, .{ .style = .{ .relative = {} } }, .{}, .{}, .{}, .{}, .{} },
        .insets = &.{ .{}, .{ .block_start = .{ .px = 20 } }, .{}, .{}, .{}, .{}, .{} },
    },
    .{
        .structure = &.{ 6, 5, 1, 1, 2, 1 },
        .display = &.{ .{ .block = {} }, .{ .inline_block = {} }, .{ .block = {} }, .{ .block = {} }, .{ .block = {} }, .{ .text = {} } },
        .inline_size = &.{
            .{},
            .{ .border_start = .{ .px = 10 }, .border_end = .{ .px = 10 } },
            .{ .padding_end = .{ .px = 50 }, .border_start = .{ .px = 10 }, .border_end = .{ .px = 10 } },
            .{ .size = .{ .px = 20 }, .border_start = .{ .px = 10 }, .border_end = .{ .px = 10 } },
            .{ .border_start = .{ .px = 10 }, .border_end = .{ .px = 10 } },
            .{},
        },
        .block_size = &.{
            .{},
            .{ .padding_start = .{ .px = 0 }, .padding_end = .{ .px = 0 }, .border_start = .{ .px = 10 }, .border_end = .{ .px = 10 } },
            .{ .size = .{ .px = 50 }, .border_start = .{ .px = 10 }, .border_end = .{ .px = 10 } },
            .{ .size = .{ .px = 50 }, .border_start = .{ .px = 10 }, .border_end = .{ .px = 10 } },
            .{ .border_start = .{ .px = 10 }, .border_end = .{ .px = 10 } },
            .{},
        },
        .latin1_text = &.{ .{}, .{}, .{}, .{}, .{}, .{ .text = "the inline-block width fits this text" } },
        .background = &.{ .{}, .{ .color = .{ .rgba = 0x508020ff } }, .{ .color = .{ .rgba = 0x472658ff } }, .{ .color = .{ .rgba = 0xd74529ff } }, .{ .color = .{ .rgba = 0xd5ad81ff } }, .{} },
        .border = border_color_sets[0],
    },
};
