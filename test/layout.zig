const zss = @import("zss");
const ZssUnit = zss.used_values.ZssUnit;
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
    face: ?*hb.hb_face_t,
    font: ?*hb.hb_font_t,

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
        if (self.font) |f| hb.hb_font_destroy(f);
        if (self.face) |f| hb.hb_face_destroy(f);
    }
};

pub fn get(index: usize) TestCase {
    @setRuntimeSafety(true);
    const data = tree_data[index];

    var face: ?*hb.hb_face_t = null;
    var font: ?*hb.hb_font_t = null;
    if (data.font) |font_file| {
        const blob = hb.hb_blob_create_from_file(font_file);
        defer hb.hb_blob_destroy(blob);
        assert(blob != hb.hb_blob_get_empty());

        face = hb.hb_face_create(blob, 0);
        assert(face != hb.hb_face_get_empty());

        font = hb.hb_font_create(face);
        assert(font != hb.hb_font_get_empty());
        hb.hb_font_set_scale(font, @intCast(c_int, data.font_size) * 64, @intCast(c_int, data.font_size) * 64);
    }

    return TestCase{
        .tree = .{
            .structure = allocator.dupe(BoxId, data.structure) catch unreachable,
            .display = allocator.dupe(Display, data.display) catch unreachable,
            .position = allocator.dupe(Positioning, data.position) catch unreachable,
            .inline_size = allocator.dupe(LogicalSize, data.inline_size) catch unreachable,
            .block_size = allocator.dupe(LogicalSize, data.block_size) catch unreachable,
            .insets = allocator.dupe(Insets, data.insets) catch unreachable,
            .latin1_text = allocator.dupe(Latin1Text, data.latin1_text) catch unreachable,
            .border = allocator.dupe(Border, data.border) catch unreachable,
            .background = allocator.dupe(Background, data.background) catch unreachable,
            .font = .{ .font = font orelse hb.hb_font_get_empty().? },
        },
        .width = data.width,
        .height = data.height,
        .face = face,
        .font = font,
    };
}

test "layout" {
    std.debug.print("\n", .{});
    for (tree_data) |_, i| {
        std.debug.print("layout test {}... ", .{i});
        defer std.debug.print("\n", .{});

        var test_case = get(i);
        defer test_case.deinit();
        var document = try zss.layout.doLayout(&test_case.tree, allocator, test_case.width, test_case.height);
        defer document.deinit();

        try testStackingContexts(&document);

        std.debug.print("success", .{});
    }
}

fn testStackingContexts(document: *zss.used_values.Document) !void {
    @setRuntimeSafety(true);
    var stack = std.ArrayList(u16).init(allocator);
    defer stack.deinit();
    stack.append(0) catch unreachable;
    while (stack.items.len > 0) {
        const parent = stack.pop();
        var it = zss.util.StructureArray(u16).childIterator(document.blocks.stacking_context_structure.items, parent);
        var last: i32 = std.math.minInt(i32);
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
    position: []const Positioning,
    inline_size: []const LogicalSize,
    block_size: []const LogicalSize,
    insets: []const Insets,
    latin1_text: []const Latin1Text,
    border: []const Border,
    background: []const Background,
    width: ZssUnit = 400,
    height: ZssUnit = 400,
    font: ?[:0]const u8 = null,
    font_size: u32 = 12,
};

pub const fonts = [_][:0]const u8{
    "demo/NotoSans-Regular.ttf",
};

pub const tree_data = [_]TreeData{
    .{
        .structure = &.{1},
        .display = &.{.{ .block = {} }},
        .position = &.{.{}},
        .inline_size = &.{.{}},
        .block_size = &.{.{}},
        .insets = &.{.{}},
        .latin1_text = &.{.{}},
        .border = &.{.{}},
        .background = &.{.{}},
    },
    .{
        .structure = &.{ 2, 1 },
        .display = &.{ .{ .block = {} }, .{ .block = {} } },
        .position = &(.{.{}} ** 2),
        .inline_size = &(.{.{}} ** 2),
        .block_size = &(.{.{}} ** 2),
        .insets = &(.{.{}} ** 2),
        .latin1_text = &(.{.{}} ** 2),
        .border = &(.{.{}} ** 2),
        .background = &(.{.{}} ** 2),
    },
    .{
        .structure = &.{ 2, 1 },
        .display = &.{ .{ .block = {} }, .{ .inline_ = {} } },
        .position = &(.{.{}} ** 2),
        .inline_size = &(.{.{}} ** 2),
        .block_size = &(.{.{}} ** 2),
        .insets = &(.{.{}} ** 2),
        .latin1_text = &(.{.{}} ** 2),
        .border = &(.{.{}} ** 2),
        .background = &(.{.{}} ** 2),
        .font = fonts[0],
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
        .inline_size = &(.{.{}} ** 5),
        .block_size = &(.{.{}} ** 5),
        .insets = &(.{.{}} ** 5),
        .latin1_text = &(.{.{}} ** 5),
        .border = &(.{.{}} ** 5),
        .background = &(.{.{}} ** 5),
    },
};
