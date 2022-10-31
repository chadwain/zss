const zss = @import("zss");
const ElementTree = zss.ElementTree;
const Element = ElementTree.Element;
const CascadedValueStore = zss.CascadedValueStore;
const ViewportSize = zss.layout.ViewportSize;

const std = @import("std");
const assert = std.debug.assert;

pub fn run(tests: []const zss.testing.Test) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer assert(!gpa.deinit());
    const allocator = gpa.allocator();

    const stdout = std.io.getStdOut().writer();

    for (tests) |t, i| {
        try stdout.print("memory safety: ({}/{}) \"{s}\" ... ", .{ i + 1, tests.len, t.name });
        defer stdout.writeAll("\n") catch {};

        const viewport_size = ViewportSize{ .width = t.width, .height = t.height };
        try std.testing.checkAllAllocationFailures(allocator, testFn, .{
            @as(*const ElementTree, &t.element_tree),
            t.root,
            @as(*const CascadedValueStore, &t.cascaded_values),

            viewport_size,
        });

        try stdout.writeAll("success");
    }

    try stdout.print("memory safety: all {} tests passed\n", .{tests.len});
}

fn testFn(allocator: std.mem.Allocator, element_tree: *const ElementTree, root: Element, cascaded_values: *const CascadedValueStore, viewport_size: ViewportSize) !void {
    var box_tree = try zss.layout.doLayout(element_tree, root, cascaded_values, allocator, viewport_size);
    defer box_tree.deinit();
}
