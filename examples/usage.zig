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

    var ast = blk: {
        var parser = zss.syntax.Parser.init(stylesheet_source, allocator);
        defer parser.deinit();
        break :blk try parser.parseCssStylesheet(allocator);
    };
    defer ast.deinit(allocator);

    const cascade_source = try env.cascade_tree.createSource(env.allocator);

    var stylesheet = try zss.Stylesheet.create(allocator, ast, 0, stylesheet_source, &env, cascade_source);
    defer stylesheet.deinit(allocator);

    var tree = zss.ElementTree.init();
    defer tree.deinit(allocator);

    const root = try tree.allocateElement(allocator);
    tree.initElement(root, .normal, .orphan);
    try env.cascade_tree.author.append(env.allocator, try env.cascade_tree.createNode(env.allocator, .{ .leaf = cascade_source }));
    try zss.cascade.run(&env, &tree, root, allocator);

    var fonts = zss.Fonts.init();
    defer fonts.deinit();

    var layout = zss.Layout.init(&tree, root, allocator, 100, 100, &env, &fonts);
    defer layout.deinit();

    var box_tree = try layout.run(allocator);
    defer box_tree.deinit();
}
