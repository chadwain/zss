const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const zss = @import("zss.zig");
const Ast = zss.syntax.Ast;
const Environment = zss.Environment;
const ElementTree = zss.ElementTree;
const Element = ElementTree.Element;
const Stack = zss.util.Stack;
const TokenSource = zss.syntax.tokenize.Source;

pub const Parser = @import("syntax/zml.zig").Parser;

comptime {
    if (@import("builtin").is_test) {
        std.testing.refAllDecls(@This());
    }
}

pub fn astToElementTree(
    element_tree: *ElementTree,
    env: *Environment,
    ast: Ast.Slice,
    root_zml_element: Ast.Size,
    source: TokenSource,
    allocator: Allocator,
) !Element {
    var stack = Stack(struct {
        interval: Ast.Interval,
        parent: Element,
    }){};
    defer stack.deinit(allocator);

    const root_element = try element_tree.allocateElement();
    {
        const slice = element_tree.slice();
        slice.initElement(root_element, .normal, .orphan, {});
        const children_index = try parseElement(slice, root_element, env, ast, root_zml_element, source);
        stack.top = .{
            .interval = ast.children(children_index),
            .parent = root_element,
        };
    }

    while (stack.top) |*top| {
        const ast_index = top.interval.next(ast) orelse {
            _ = stack.pop();
            continue;
        };
        const element = try element_tree.allocateElement();
        const slice = element_tree.slice();
        slice.initElement(element, .normal, .last_child_of, top.parent);
        const children_index = try parseElement(slice, element, env, ast, ast_index, source);
        try stack.push(allocator, .{
            .interval = ast.children(children_index),
            .parent = element,
        });
    }

    return root_element;
}

fn parseElement(
    element_tree: ElementTree.Slice,
    element: Element,
    env: *Environment,
    ast: Ast.Slice,
    zml_element: Ast.Size,
    source: TokenSource,
) !Ast.Size {
    assert(ast.tag(zml_element) == .zml_element);
    var element_children = ast.children(zml_element);

    const features = element_children.next(ast).?;
    assert(ast.tag(features) == .zml_features);

    {
        var features_children = ast.children(features);
        while (features_children.next(ast)) |index| {
            switch (ast.tag(index)) {
                .zml_type => {
                    const type_name = try env.addTypeOrAttributeName(ast.location(index), source);
                    element_tree.set(.fq_type, element, .{ .namespace = .none, .name = type_name });
                },
                .zml_id => std.debug.panic("TODO: parse zml element: id feature", .{}),
                .zml_class => std.debug.panic("TODO: parse zml element: class feature", .{}),
                .zml_attribute => std.debug.panic("TODO: parse zml element: attribute feature", .{}),
                else => break,
            }
        }
    }

    const style_block = element_children.next(ast).?;
    const has_style_block = (ast.tag(style_block) == .zml_styles);
    if (has_style_block) {
        std.debug.panic("TODO: parse zml element: style block", .{});
    }

    const children = if (has_style_block)
        element_children.next(ast).?
    else
        style_block;
    assert(ast.tag(children) == .zml_children);

    return children;
}

test astToElementTree {
    const input =
        \\* { /*comment*/
        \\  type1 {}
        \\  type2 {}
        \\}
    ;
    const source = try TokenSource.init(zss.util.Utf8String{ .data = input });
    const allocator = std.testing.allocator;

    var parser = Parser.init(source, allocator);
    defer parser.deinit();

    var ast = Ast{};
    defer ast.deinit(allocator);
    try parser.parse(&ast, allocator);

    var element_tree = ElementTree.init(allocator);
    defer element_tree.deinit();

    var env = Environment.init(allocator);
    defer env.deinit();

    _ = try astToElementTree(&element_tree, &env, ast.slice(), 1, source, allocator);
}
