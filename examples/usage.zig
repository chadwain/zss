const std = @import("std");
const zss = @import("zss");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    var env = zss.Environment.init(allocator);
    defer env.deinit();

    const stylesheet_text =
        \\@namespace hello "world";
        \\* {
        \\  display: none;
        \\}
    ;
    const stylesheet_source = try zss.syntax.TokenSource.init(stylesheet_text);

    try env.addStylesheet(stylesheet_source);

    var tree = zss.ElementTree.init(allocator);
    defer tree.deinit();

    const root = try tree.allocateElement();
    const slice = tree.slice();
    slice.initElement(root, .normal, .orphan);
    try slice.runCascade(root, allocator, &env);

    var images = zss.Images{};
    defer images.deinit(allocator);

    var fonts = zss.Fonts.init();
    defer fonts.deinit();

    var layout = zss.Layout.init(slice, root, allocator, 100, 100, images.slice(), &fonts, &env.decls);
    defer layout.deinit();

    var box_tree = try layout.run(allocator);
    defer box_tree.deinit();
}
