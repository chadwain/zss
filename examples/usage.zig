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

    var ast, const rule_list_index = blk: {
        var parser = zss.syntax.Parser.init(stylesheet_source, allocator);
        defer parser.deinit();
        break :blk try parser.parseCssStylesheet(allocator);
    };
    defer ast.deinit(allocator);

    var env = zss.Environment.init(allocator);
    defer env.deinit();

    const node_group = try env.addNodeGroup();
    env.root_node = .{ .group = node_group, .value = 0 };
    env.tree_interface = .{
        .context = &node_group,
        .vtable = comptime &.{
            .node_edge = nodeEdge,
        },
    };

    var stylesheet = try zss.Stylesheet.create(allocator, ast, rule_list_index, stylesheet_source, &env);
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

fn nodeEdge(context: *const anyopaque, node: zss.Environment.NodeId, _: zss.Environment.TreeInterface.Edge) ?zss.Environment.NodeId {
    const node_group: *const zss.Environment.NodeGroup = @alignCast(@ptrCast(context));
    std.debug.assert(node.group == node_group.*);
    std.debug.assert(node.value == 0);
    return null;
}
