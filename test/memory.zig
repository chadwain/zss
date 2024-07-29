const zss = @import("zss");
const ElementTree = zss.ElementTree;
const Element = ElementTree.Element;

const std = @import("std");
const assert = std.debug.assert;

const Test = @import("./testing.zig").Test;

pub fn run(tests: []const Test) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    const stdout = std.io.getStdOut().writer();

    var images = zss.Images{};
    defer images.deinit(allocator);
    const images_slice = images.slice();

    var storage = zss.values.Storage{ .allocator = allocator };
    defer storage.deinit();

    for (tests, 0..) |t, i| {
        try stdout.print("memory safety: ({}/{}) \"{s}\" ... ", .{ i + 1, tests.len, t.name });
        defer stdout.writeAll("\n") catch {};

        try std.testing.checkAllAllocationFailures(allocator, testFn, .{ t.slice, t.root, t.width, t.height, images_slice, &t.fonts, &storage });

        try stdout.writeAll("success");
    }

    try stdout.print("memory safety: all {} tests passed\n", .{tests.len});
}

fn testFn(
    allocator: std.mem.Allocator,
    element_tree_slice: ElementTree.Slice,
    root: Element,
    width: u32,
    height: u32,
    images: zss.Images.Slice,
    fonts: *const zss.Fonts,
    storage: *const zss.values.Storage,
) !void {
    var box_tree = try zss.layout.doLayout(element_tree_slice, root, allocator, width, height, images, fonts, storage);
    defer box_tree.deinit();
}
