const zss = @import("zss");
const used = zss.used_values;
const ZssUnit = used.ZssUnit;

const std = @import("std");
const assert = std.debug.assert;
const expect = std.testing.expect;

const Test = @import("./testing.zig").Test;

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = gpa.allocator();

pub fn run(tests: []const Test) !void {
    defer assert(gpa.deinit() == .ok);

    const stdout = std.io.getStdOut().writer();

    var images = zss.Images{};
    defer images.deinit(allocator);
    const images_slice = images.slice();

    var storage = zss.values.Storage{ .allocator = allocator };
    defer storage.deinit();

    for (tests, 0..) |t, i| {
        try stdout.print("validation: ({}/{}) \"{s}\" ... ", .{ i + 1, tests.len, t.name });
        defer stdout.print("\n", .{}) catch {};

        var box_tree = try zss.layout.doLayout(
            t.slice,
            t.root,
            allocator,
            t.width,
            t.height,
            images_slice,
            &storage,
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
    const Index = used.StackingContext.Index;
    const ZIndex = used.ZIndex;

    const slice = box_tree.stacking_contexts.slice();
    if (slice.len == 0) return;
    const skips = slice.items(.skip);
    const z_indeces = slice.items(.z_index);

    var stack = std.ArrayList(struct { current: Index, end: Index }).init(allocator);
    defer stack.deinit();

    try expect(z_indeces[0] == 0);
    stack.append(.{ .current = 0, .end = skips[0] }) catch unreachable;
    while (stack.items.len > 0) {
        const parent = stack.pop();
        var child = parent.current + 1;
        var previous_z_index: ZIndex = std.math.minInt(ZIndex);
        while (child < parent.end) : (child += skips[child]) {
            const z_index = z_indeces[child];
            try expect(previous_z_index <= z_index);
            previous_z_index = z_index;
            stack.append(.{ .current = child, .end = child + skips[child] }) catch unreachable;
        }
    }
}
