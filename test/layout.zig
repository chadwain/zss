const zss = @import("zss");
const used = zss.used_values;
const ZssUnit = used.ZssUnit;
const BoxTree = zss.BoxTree;
usingnamespace BoxTree;

const std = @import("std");
const assert = std.debug.assert;
const expect = std.testing.expect;
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
        .width = data.width,
        .height = data.height,
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

test "validate document" {
    var library: hb.FT_Library = undefined;
    assert(hb.FT_Init_FreeType(&library) == 0);
    defer _ = hb.FT_Done_FreeType(library);

    std.debug.print("\n", .{});
    for (tree_data) |_, i| {
        std.debug.print("validate document {}... ", .{i});
        defer std.debug.print("\n", .{});

        var test_case = get(i, library);
        defer test_case.deinit();
        var document = try zss.layout.doLayout(&test_case.tree, allocator, test_case.width, test_case.height);
        defer document.deinit();

        try validateStackingContexts(&document);
        for (document.inlines.items) |inl| {
            try validateInline(inl);
        }

        std.debug.print("success", .{});
    }
}

fn validateInline(inl: *used.InlineLevelUsedValues) !void {
    @setRuntimeSafety(true);
    const UsedId = used.UsedId;

    var stack = std.ArrayList(UsedId).init(allocator);
    defer stack.deinit();
    var i: usize = 0;
    while (i < inl.glyph_indeces.items.len) : (i += 1) {
        if (inl.glyph_indeces.items[i] == 0) {
            i += 1;
            const special = used.InlineLevelUsedValues.Special.decode(inl.glyph_indeces.items[i]);
            switch (special.kind) {
                .BoxStart => stack.append(special.data) catch unreachable,
                .BoxEnd => _ = stack.pop(),
                else => {},
            }
        }
    }
    try expect(stack.items.len == 0);
}

fn validateStackingContexts(document: *zss.used_values.Document) !void {
    @setRuntimeSafety(true);
    const StackingContextId = used.StackingContextId;
    const ZIndex = used.ZIndex;

    var stack = std.ArrayList(StackingContextId).init(allocator);
    defer stack.deinit();
    stack.append(0) catch unreachable;
    while (stack.items.len > 0) {
        const parent = stack.pop();
        var it = zss.util.StructureArray(StackingContextId).childIterator(document.blocks.stacking_context_structure.items, parent);
        var last: ZIndex = std.math.minInt(ZIndex);
        while (it.next()) |child| {
            const current = document.blocks.stacking_contexts.items[child].z_index;
            try expect(last <= current);
            last = current;
            stack.append(child) catch unreachable;
        }
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
    width: ZssUnit = 400,
    height: ZssUnit = 400,
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
};
