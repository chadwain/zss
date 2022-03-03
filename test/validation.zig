const zss = @import("zss");
const used = zss.used_values;
const ZssUnit = used.ZssUnit;

const std = @import("std");
const assert = std.debug.assert;
const expect = std.testing.expect;
const allocator = std.testing.allocator;

const cases = @import("./test_cases.zig");

const hb = @import("harfbuzz");

test "validation" {
    var all_test_data = try cases.getTestData();
    defer {
        for (all_test_data.items) |*data| data.deinit();
        all_test_data.deinit();
    }

    var library: hb.FT_Library = undefined;
    assert(hb.FT_Init_FreeType(&library) == 0);
    defer _ = hb.FT_Done_FreeType(library);

    std.debug.print("\n", .{});
    for (all_test_data.items) |data, i| {
        std.debug.print("validate boxes {}... ", .{i});
        defer std.debug.print("\n", .{});

        var test_case = data.toTestCase(library);
        defer test_case.deinit();
        var boxes = try zss.layout.doLayout(
            &test_case.element_tree,
            &test_case.cascaded_value_tree,
            allocator,
            .{ .w = test_case.width, .h = test_case.height },
        );
        defer boxes.deinit();

        try validateStackingContexts(&boxes);
        for (boxes.inlines.items) |inl| {
            try validateInline(inl);
        }

        std.debug.print("success", .{});
    }
}

fn validateInline(inl: *used.InlineFormattingContext) !void {
    @setRuntimeSafety(true);
    const InlineBoxIndex = used.InlineBoxIndex;

    var stack = std.ArrayList(InlineBoxIndex).init(allocator);
    defer stack.deinit();
    var i: usize = 0;
    while (i < inl.glyph_indeces.items.len) : (i += 1) {
        if (inl.glyph_indeces.items[i] == 0) {
            i += 1;
            const special = used.InlineFormattingContext.Special.decode(inl.glyph_indeces.items[i]);
            switch (special.kind) {
                .BoxStart => stack.append(@as(InlineBoxIndex, special.data)) catch unreachable,
                .BoxEnd => _ = stack.pop(),
                else => {},
            }
        }
    }
    try expect(stack.items.len == 0);
}

fn validateStackingContexts(boxes: *zss.used_values.Boxes) !void {
    @setRuntimeSafety(true);
    const StackingContextTree = used.StackingContextTree;
    const ZIndex = used.ZIndex;

    const root_iterator = boxes.stacking_contexts.iterator() orelse return;

    const slice = boxes.stacking_contexts.slice();
    const skips = slice.items(.__skip);
    const z_index = slice.items(.z_index);
    try expect(z_index[root_iterator.index] == 0);

    var stack = std.ArrayList(StackingContextTree.Iterator).init(allocator);
    defer stack.deinit();

    stack.append(root_iterator) catch unreachable;
    while (stack.items.len > 0) {
        const parent = stack.pop();
        var child = parent.firstChild(skips);
        var previous: ZIndex = std.math.minInt(ZIndex);
        while (!child.empty()) : (child = child.nextSibling(skips)) {
            const current = z_index[child.index];
            try expect(previous <= current);
            previous = current;
            stack.append(child) catch unreachable;
        }
    }
}
