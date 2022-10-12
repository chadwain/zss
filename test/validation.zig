const zss = @import("zss");
const used = zss.used_values;
const ZssUnit = used.ZssUnit;

const std = @import("std");
const assert = std.debug.assert;
const expect = std.testing.expect;

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = gpa.allocator();

pub fn run(tests: []const zss.testing.Test) !void {
    defer assert(!gpa.deinit());

    const stdout = std.io.getStdOut().writer();

    for (tests) |t, i| {
        try stdout.print("validation: ({}/{}) \"{s}\" ... ", .{ i + 1, tests.len, t.name });
        defer stdout.print("\n", .{}) catch {};

        var box_tree = try zss.layout.doLayout(
            t.element_tree,
            t.cascaded_values,
            allocator,
            .{ .width = t.width, .height = t.height },
        );
        defer box_tree.deinit();

        try validateStackingContexts(&box_tree);
        for (box_tree.ifcs.items) |ifc| {
            try validateInline(ifc);
        }

        try stdout.print("success", .{});
    }

    try stdout.print("validation: all {} tests passed\n", .{tests.len});
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

fn validateStackingContexts(box_tree: *zss.used_values.BoxTree) !void {
    @setRuntimeSafety(true);
    const StackingContextTree = used.StackingContextTree;
    const ZIndex = used.ZIndex;

    const root_iterator = box_tree.stacking_contexts.iterator();
    if (root_iterator.empty()) return;

    const slice = box_tree.stacking_contexts.list.slice();
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
