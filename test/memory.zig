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

    const stdout = std.io.getStdOut().writer();

    for (tests, 0..) |t, i| {
        try stdout.print("memory: ({}/{}) \"{s}\" ... ", .{ i + 1, tests.len, t.name });
        defer stdout.writeAll("\n") catch {};

        try std.testing.checkAllAllocationFailures(allocator, testFn, .{
            t.element_tree.slice(),
            t.root_element,
            t.width,
            t.height,
            t.images,
            t.fonts,
            &t.env.decls,
        });

        try stdout.writeAll("success");
    }

    try stdout.print("memory: all {} tests passed\n", .{tests.len});
}

fn testFn(
    allocator: std.mem.Allocator,
    element_tree_slice: ElementTree.Slice,
    root: Element,
    width: u32,
    height: u32,
    images: zss.Images.Slice,
    fonts: *const zss.Fonts,
    decls: *const zss.property.Declarations,
) !void {
    var layout = zss.Layout.init(element_tree_slice, root, allocator, width, height, images, fonts, decls);
    defer layout.deinit();

    var box_tree = try layout.run(allocator);
    defer box_tree.deinit();
}
