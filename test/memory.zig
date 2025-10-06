const zss = @import("zss");
const ElementTree = zss.ElementTree;
const Element = ElementTree.Element;

const std = @import("std");
const assert = std.debug.assert;

const Test = @import("./Test.zig");

pub fn run(tests: []const *Test, _: []const u8) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    var stdout_buffer: [200]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writerStreaming(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    for (tests, 0..) |t, i| {
        try stdout.print("memory: ({}/{}) \"{s}\" ... ", .{ i + 1, tests.len, t.name });
        try stdout.flush();

        try std.testing.checkAllAllocationFailures(allocator, testFn, .{
            &t.document.env,
            t.width,
            t.height,
            t.images,
            t.fonts,
        });

        try stdout.writeAll("success\n");
        try stdout.flush();
    }

    try stdout.print("memory: all {} tests passed\n", .{tests.len});
    try stdout.flush();
}

fn testFn(
    allocator: std.mem.Allocator,
    env: *const zss.Environment,
    width: u32,
    height: u32,
    images: *const zss.Images,
    fonts: *const zss.Fonts,
) !void {
    var layout = zss.Layout.init(env, allocator, width, height, images, fonts);
    defer layout.deinit();

    var box_tree = try layout.run(allocator);
    defer box_tree.deinit();
}
