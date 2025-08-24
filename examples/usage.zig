const std = @import("std");
const zss = @import("zss");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    const stylesheet_text =
        \\@namespace hello "world";
        \\* {
        \\  display: block;
        \\}
    ;
    const stylesheet_source = try zss.syntax.TokenSource.init(stylesheet_text);

    var ast = blk: {
        var parser = zss.syntax.Parser.init(stylesheet_source, allocator);
        defer parser.deinit();
        break :blk try parser.parseCssStylesheet(allocator);
    };
    defer ast.deinit(allocator);

    var env = zss.Environment.init(allocator);
    defer env.deinit();

    const root = try env.element_tree.allocateElement(env.allocator);
    env.element_tree.initElement(root, .normal, .orphan);

    var stylesheet = try zss.Stylesheet.create(allocator, ast, 0, stylesheet_source, &env);
    defer stylesheet.deinit(allocator);

    try env.cascade_tree.author.append(env.allocator, try env.cascade_tree.createNode(env.allocator, .{ .leaf = &stylesheet.cascade_source }));
    try zss.cascade.run(&env, root);

    var fonts = zss.Fonts.init();
    defer fonts.deinit();

    var layout = zss.Layout.init(&env, root, allocator, 100, 100, &fonts);
    defer layout.deinit();

    var box_tree = try layout.run(allocator);
    defer box_tree.deinit();
}
