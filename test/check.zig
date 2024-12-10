const zss = @import("zss");
const BoxTree = zss.BoxTree;

const std = @import("std");
const assert = std.debug.assert;
const expect = std.testing.expect;
const Allocator = std.mem.Allocator;

const Test = @import("./Test.zig");

pub fn run(tests: []const *Test, _: []const u8) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    const stdout = std.io.getStdOut().writer();

    for (tests, 0..) |t, i| {
        try stdout.print("check: ({}/{}) \"{s}\" ... ", .{ i + 1, tests.len, t.name });
        defer stdout.print("\n", .{}) catch {};

        var layout = zss.Layout.init(
            t.element_tree.slice(),
            t.root_element,
            allocator,
            t.width,
            t.height,
            t.images,
            t.fonts,
            t.storage,
        );
        defer layout.deinit();

        var box_tree = try layout.run(allocator);
        defer box_tree.deinit();

        try validateStackingContexts(&box_tree, allocator);
        for (box_tree.ifcs.items) |ifc| {
            try validateInline(ifc, allocator);
        }

        try stdout.print("success", .{});
    }

    try stdout.print("check: all {} tests passed\n", .{tests.len});
}

fn validateInline(inl: *BoxTree.InlineFormattingContext, allocator: Allocator) !void {
    @setRuntimeSafety(true);
    const Index = BoxTree.InlineFormattingContext.Size;
    const glyphs = inl.glyphs.items(.index);

    var stack = std.ArrayList(Index).init(allocator);
    defer stack.deinit();
    var i: usize = 0;
    while (i < glyphs.len) : (i += 1) {
        if (glyphs[i] == 0) {
            i += 1;
            const special = BoxTree.InlineFormattingContext.Special.decode(glyphs[i]);
            switch (special.kind) {
                .BoxStart => stack.append(@as(Index, special.data)) catch unreachable,
                .BoxEnd => _ = stack.pop(),
                else => {},
            }
        }
    }
    try expect(stack.items.len == 0);
}

fn validateStackingContexts(box_tree: *zss.BoxTree, allocator: Allocator) !void {
    @setRuntimeSafety(true);
    const Size = BoxTree.StackingContextTree.Size;
    const ZIndex = BoxTree.ZIndex;

    const view = box_tree.sct.view();
    if (view.len == 0) return;
    const skips = view.items(.skip);
    const z_indeces = view.items(.z_index);

    var stack = std.ArrayList(struct { current: Size, end: Size }).init(allocator);
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
