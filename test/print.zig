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

        var layout = zss.Layout.init(
            &t.element_tree,
            t.root_element,
            allocator,
            t.width,
            t.height,
            &t.env,
            t.fonts,
        );
        defer layout.deinit();

        var box_tree = try layout.run(allocator);
        defer box_tree.deinit();
        try box_tree.debug.print(stdout, allocator);

        try stdout.writeAll("\n");
    }

    try stdout.print("print: all {} tests passed\n", .{tests.len});
}
