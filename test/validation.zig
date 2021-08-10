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
    var library: hb.FT_Library = undefined;
    assert(hb.FT_Init_FreeType(&library) == 0);
    defer _ = hb.FT_Done_FreeType(library);

    std.debug.print("\n", .{});
    for (cases.tree_data) |_, i| {
        std.debug.print("validate document {}... ", .{i});
        defer std.debug.print("\n", .{});

        var test_case = cases.get(i, library);
        defer test_case.deinit();
        var document = try zss.layout.doLayout(&test_case.tree, allocator, .{ .w = test_case.width, .h = test_case.height });
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
        var it = zss.util.StructureArray(StackingContextId).childIterator(document.stacking_context_structure.items, parent);
        var last: ZIndex = std.math.minInt(ZIndex);
        while (it.next()) |child| {
            const current = document.stacking_contexts.items[child].z_index;
            try expect(last <= current);
            last = current;
            stack.append(child) catch unreachable;
        }
    }
}
