const zss = @import("zss");

const std = @import("std");
const assert = std.debug.assert;

const Test = @import("./Test.zig");

pub fn run(tests: []const *Test, _: []const u8) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    const stdout = std.io.getStdOut().writer().any();

    for (tests, 0..) |t, i| {
        try stdout.print("print: ({}/{}) \"{s}\" ... \n", .{ i + 1, tests.len, t.name });

        var box_tree = try zss.layout.doLayout(
            t.element_tree.slice(),
            t.root_element,
            allocator,
            t.width,
            t.height,
            t.images,
            t.fonts,
            t.storage,
        );
        defer box_tree.deinit();
        try box_tree.print(stdout, allocator);

        try stdout.writeAll("\n");
    }

    try stdout.print("print: all {} tests passed\n", .{tests.len});
}
