const zss = @import("zss");
const ZssSize = zss.used_values.ZssSize;
const ElementTree = zss.ElementTree;
const CascadedValueStore = zss.CascadedValueStore;

const std = @import("std");
const assert = std.debug.assert;

const cases = @import("./test_cases.zig");

const hb = @import("harfbuzz");

test "memory" {
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
        std.debug.print("check memory safety {}... ", .{i});
        defer std.debug.print("\n", .{});

        const test_case = data.toTestCase(library);
        defer test_case.deinit();

        const viewport_size = ZssSize{ .w = test_case.width, .h = test_case.height };
        try std.testing.checkAllAllocationFailures(std.testing.allocator, testFn, .{
            @as(*const ElementTree, &test_case.element_tree),
            @as(*const CascadedValueStore, &test_case.cascaded_values),
            viewport_size,
        });

        std.debug.print("success", .{});
    }
}

fn testFn(allocator: std.mem.Allocator, element_tree: *const ElementTree, cascaded_values: *const CascadedValueStore, viewport_size: ZssSize) !void {
    var box_tree = try zss.layout.doLayout(element_tree.*, cascaded_values.*, allocator, viewport_size);
    defer box_tree.deinit();
}
