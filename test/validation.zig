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
        std.debug.print("validate document {}... ", .{i});
        defer std.debug.print("\n", .{});

        var test_case = data.toTestCase(library);
        defer test_case.deinit();
        var document = try zss.layout.doLayout(
            &test_case.element_tree,
            &test_case.cascaded_value_tree,
            allocator,
            .{ .w = test_case.width, .h = test_case.height },
        );
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
    const StackingContextTree = used.StackingContextTree;
    const ZIndex = used.ZIndex;

    if (document.stacking_context_tree.subtree.items.len == 0) return;
    var stack = std.ArrayList(StackingContextTree.Range).init(allocator);
    defer stack.deinit();
    stack.append(document.stacking_context_tree.range()) catch unreachable;
    while (stack.items.len > 0) {
        const parent = stack.pop();
        var range = parent.children(document.stacking_context_tree);
        var last: ZIndex = std.math.minInt(ZIndex);
        while (!range.empty()) : (range.next(document.stacking_context_tree)) {
            const current = range.get(document.stacking_context_tree).z_index;
            try expect(last <= current);
            last = current;
            stack.append(range) catch unreachable;
        }
    }
}
