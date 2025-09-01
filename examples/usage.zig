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
    env.root_element = root;

    var stylesheet = try zss.Stylesheet.create(allocator, ast, 0, stylesheet_source, &env);
    defer stylesheet.deinit(allocator);

    const cascade_node: zss.cascade.Node = .{ .leaf = &stylesheet.cascade_source };
    try env.cascade_list.author.append(env.allocator, &cascade_node);
    try zss.cascade.run(&env);

    var images = zss.Images.init();
    defer images.deinit(allocator);

    var fonts = zss.Fonts.init();
    defer fonts.deinit();

    var layout = zss.Layout.init(&env, allocator, 100, 100, &images, &fonts);
    defer layout.deinit();

    var box_tree = try layout.run(allocator);
    defer box_tree.deinit();
}
