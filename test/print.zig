const zss = @import("zss");

const std = @import("std");
const assert = std.debug.assert;

const Test = @import("./Test.zig");

pub fn run(tests: []const *Test, _: []const u8) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writerStreaming(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    for (tests, 0..) |t, i| {
        try stdout.print("print: ({}/{}) \"{s}\" ... \n", .{ i + 1, tests.len, t.name });
        try stdout.flush();

        var layout = zss.Layout.init(
            &t.document.env,
            allocator,
            t.width,
            t.height,
            t.images,
            t.fonts,
        );
        defer layout.deinit();

        var box_tree = try layout.run(allocator);
        defer box_tree.deinit();
        try box_tree.debug.print(stdout, allocator);

        try stdout.writeAll("\n");
        try stdout.flush();
    }

    try stdout.print("print: all {} tests passed\n", .{tests.len});
    try stdout.flush();
}
