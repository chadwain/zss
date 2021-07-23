const zss = @import("zss");
const ZssUnit = zss.used_values.ZssUnit;
const unitsPerPixel = zss.used_values.unitsPerPixel;
const BoxTree = zss.BoxTree;
usingnamespace BoxTree;

const std = @import("std");
const assert = std.debug.assert;
const allocator = std.testing.allocator;

const hb = @import("harfbuzz");

pub const TestCase = struct {
    tree: BoxTree,
    width: ZssUnit,
    height: ZssUnit,
    face: hb.FT_Face,

    pub fn deinit(self: *@This()) void {
        allocator.free(self.tree.structure);
        allocator.free(self.tree.display);
        allocator.free(self.tree.position);
        allocator.free(self.tree.inline_size);
        allocator.free(self.tree.block_size);
        allocator.free(self.tree.insets);
        allocator.free(self.tree.latin1_text);
        allocator.free(self.tree.border);
        allocator.free(self.tree.background);
        hb.hb_font_destroy(self.tree.font.font);
        _ = hb.FT_Done_Face(self.face);
    }
};

pub fn get(index: usize, library: hb.FT_Library) TestCase {
    @setRuntimeSafety(true);
    const data = tree_data[index];

    var face: hb.FT_Face = undefined;
    assert(hb.FT_New_Face(library, data.font, 0, &face) == 0);
    assert(hb.FT_Set_Char_Size(face, 0, @intCast(c_int, data.font_size) * 64, 96, 96) == 0);

    const tree_size = data.structure.len;
    assert(data.display.len == data.structure.len);
    return TestCase{
        .tree = .{
            .structure = allocator.dupe(BoxId, data.structure) catch unreachable,
            .display = allocator.dupe(Display, data.display) catch unreachable,
            .position = copy(Positioning, data.position, tree_size),
            .inline_size = copy(LogicalSize, data.inline_size, tree_size),
            .block_size = copy(LogicalSize, data.block_size, tree_size),
            .insets = copy(Insets, data.insets, tree_size),
            .latin1_text = copy(Latin1Text, data.latin1_text, tree_size),
            .border = copy(Border, data.border, tree_size),
            .background = copy(Background, data.background, tree_size),
            .font = .{
                .font = blk: {
                    const hb_font = hb.hb_ft_font_create_referenced(face).?;
                    hb.hb_ft_font_set_funcs(hb_font);
                    break :blk hb_font;
                },
                .color = .{ .rgba = data.font_color },
            },
        },
        .width = @intCast(ZssUnit, data.width * unitsPerPixel),
        .height = @intCast(ZssUnit, data.height * unitsPerPixel),
        .face = face,
    };
}

fn copy(comptime T: type, data: ?[]const T, tree_size: usize) []T {
    @setRuntimeSafety(true);
    if (data) |arr| {
        assert(arr.len == tree_size);
        return allocator.dupe(T, arr) catch unreachable;
    } else {
        const arr = allocator.alloc(T, tree_size) catch unreachable;
        std.mem.set(T, arr, .{});
        return arr;
    }
}

pub const TreeData = struct {
    structure: []const BoxId,
    display: []const Display,
    position: ?[]const Positioning = null,
    inline_size: ?[]const LogicalSize = null,
    block_size: ?[]const LogicalSize = null,
    insets: ?[]const Insets = null,
    latin1_text: ?[]const Latin1Text = null,
    border: ?[]const Border = null,
    background: ?[]const Background = null,
    width: u32 = 400,
    height: u32 = 400,
    font: [:0]const u8 = fonts[0],
    font_size: u32 = 12,
    font_color: u32 = 0xffffffff,
};

pub const strings = [_][]const u8{
    "sample text",
    "The quick brown fox jumps over the lazy dog",
};

pub const fonts = [_][:0]const u8{
    "demo/NotoSans-Regular.ttf",
};

pub const tree_data = [_]TreeData{
    .{
        .structure = &.{1},
        .display = &.{.{ .block = {} }},
    },
    .{
        .structure = &.{ 2, 1 },
        .display = &.{ .{ .block = {} }, .{ .block = {} } },
    },
    .{
        .structure = &.{ 2, 1 },
        .display = &.{ .{ .block = {} }, .{ .inline_ = {} } },
    },
    .{
        .structure = &.{1},
        .display = &.{.{ .inline_ = {} }},
    },
    .{
        .structure = &.{1},
        .display = &.{.{ .inline_block = {} }},
        .inline_size = &.{.{ .size = .{ .px = 50 } }},
    },
    .{
        .structure = &.{1},
        .display = &.{.{ .text = {} }},
        .latin1_text = &.{.{ .text = strings[0] }},
    },
    .{
        .structure = &.{ 2, 1 },
        .display = &.{ .{ .inline_ = {} }, .{ .text = {} } },
        .latin1_text = &.{ .{}, .{ .text = strings[0] } },
    },
    .{
        .structure = &.{ 3, 2, 1 },
        .display = &.{ .{ .block = {} }, .{ .inline_ = {} }, .{ .text = {} } },
        .latin1_text = &.{ .{}, .{}, .{ .text = strings[1] } },
        .font_size = 18,
    },
    .{
        .structure = &.{ 2, 1 },
        .display = &.{ .{ .block = {} }, .{ .block = {} } },
        .inline_size = &.{ .{}, .{ .size = .{ .px = 50 }, .margin_start = .{ .auto = {} }, .margin_end = .{ .auto = {} } } },
        .block_size = &.{ .{ .size = .{ .px = 50 } }, .{ .size = .{ .px = 50 } } },
        .background = &.{ .{}, .{ .color = .{ .rgba = 0x404070ff } } },
    },
    .{
        .structure = &.{ 5, 1, 1, 1, 1 },
        .display = &.{ .{ .block = {} }, .{ .block = {} }, .{ .block = {} }, .{ .block = {} }, .{ .block = {} } },
        .position = &.{
            .{},
            .{ .style = .{ .relative = {} }, .z_index = .{ .value = 6 } },
            .{ .style = .{ .relative = {} }, .z_index = .{ .value = -2 } },
            .{ .style = .{ .relative = {} }, .z_index = .{ .auto = {} } },
            .{ .style = .{ .relative = {} }, .z_index = .{ .value = -5 } },
        },
    },
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
        .structure = &.{ 9, 8, 1, 6, 1, 4, 1, 2, 1 },
        .display = &.{ .{ .block = {} }, .{ .inline_block = {} }, .{ .text = {} }, .{ .inline_block = {} }, .{ .text = {} }, .{ .inline_block = {} }, .{ .text = {} }, .{ .inline_block = {} }, .{ .text = {} } },
        .inline_size = &.{ .{}, .{ .size = .{ .px = 350 } }, .{}, .{ .size = .{ .px = 100 } }, .{}, .{ .size = .{ .px = 50 } }, .{}, .{ .size = .{ .px = 25 } }, .{} },
        .block_size = &.{ .{}, .{ .padding_start = .{ .px = 10 } }, .{}, .{ .padding_start = .{ .px = 10 } }, .{}, .{ .padding_start = .{ .px = 10 } }, .{}, .{ .padding_start = .{ .px = 10 } }, .{} },
        .latin1_text = &.{ .{}, .{}, .{ .text = "nested inline blocks  1 " }, .{}, .{ .text = "2 " }, .{}, .{ .text = "3 " }, .{}, .{ .text = "4 " } },
        .background = &.{ .{}, .{ .color = .{ .rgba = 0x508020ff } }, .{}, .{ .color = .{ .rgba = 0x805020ff } }, .{}, .{ .color = .{ .rgba = 0x802050ff } }, .{}, .{ .color = .{ .rgba = 0x208050ff } }, .{} },
    },
};
