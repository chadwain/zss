const zss = @import("zss");
const ZssSize = zss.used_values.ZssSize;
const ElementTree = zss.ElementTree;
const CascadedValueStore = zss.CascadedValueStore;
const ViewportSize = zss.layout.ViewportSize;

const std = @import("std");
const assert = std.debug.assert;

pub fn run(tests: []const zss.testing.Test) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer assert(!gpa.deinit());
    const allocator = gpa.allocator();

    for (tests) |t, i| {
        std.debug.print("memory safety: ({}/{}) \"{s}\" ... ", .{ i, tests.len, t.name });
        defer std.debug.print("\n", .{});

        const viewport_size = ViewportSize{ .width = t.width, .height = t.height };
        try std.testing.checkAllAllocationFailures(allocator, testFn, .{
            @as(*const ElementTree, &t.element_tree),
            @as(*const CascadedValueStore, &t.cascaded_values),
            viewport_size,
        });

        std.debug.print("success", .{});
    }

    std.debug.print("memory safety: all {} tests passed\n", .{tests.len});
}

fn testFn(allocator: std.mem.Allocator, element_tree: *const ElementTree, cascaded_values: *const CascadedValueStore, viewport_size: ViewportSize) !void {
    var box_tree = try zss.layout.doLayout(element_tree.*, cascaded_values.*, allocator, viewport_size);
    defer box_tree.deinit();
}
