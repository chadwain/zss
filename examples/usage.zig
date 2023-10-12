const std = @import("std");
const zss = @import("zss");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    var env = zss.Environment.init(allocator);
    defer env.deinit();

    const stylesheet_text =
        \\* {
        \\  display: none;
        \\}
    ;
    const stylesheet_source = zss.syntax.parse.Source.init(try zss.syntax.tokenize.Source.init(stylesheet_text));

    try env.addStylesheet(stylesheet_source);

    var tree = zss.ElementTree.init(allocator);
    defer tree.deinit();

    const root = try tree.allocateElement();
    const slice = tree.slice();
    slice.initElement(root, .normal, .orphan, {});
    try slice.runCascade(root, allocator, &env);

    var box_tree = try zss.layout.doLayout(slice, root, allocator, .{ .width = 100, .height = 100 });
    defer box_tree.deinit();
}
