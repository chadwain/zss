const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const zss = @import("zss.zig");
const Ast = zss.syntax.Ast;
const CascadedValues = zss.CascadedValues;
const Environment = zss.Environment;
const ElementTree = zss.ElementTree;
const Element = ElementTree.Element;
const Stack = zss.util.Stack;
const TokenSource = zss.syntax.tokenize.Source;

const parse_zml = @import("syntax/zml.zig");
pub const Parser = parse_zml.Parser;

comptime {
    if (@import("builtin").is_test) {
        _ = parse_zml;
    }
}

pub fn astToElementTree(
    element_tree: *ElementTree,
    env: *Environment,
    ast: Ast.Slice,
    root_zml_element: Ast.Size,
    token_source: TokenSource,
    allocator: Allocator,
) !Element {
    var cascade_arena = ArenaAllocator.init(allocator);
    defer cascade_arena.deinit();

    var stack = Stack(struct {
        sequence: Ast.Sequence,
        parent: Element,
    }){};
    defer stack.deinit(allocator);

    const root_element = try element_tree.allocateElement();
    {
        const slice = element_tree.slice();
        slice.initElement(root_element, .normal, .orphan, {});
        const children_index = try parseElement(slice, root_element, env, ast, root_zml_element, token_source, &cascade_arena);
        stack.top = .{
            .sequence = ast.children(children_index),
            .parent = root_element,
        };
    }

    while (stack.top) |*top| {
        const ast_index = top.sequence.next(ast) orelse {
            _ = stack.pop();
            continue;
        };
        const element = try element_tree.allocateElement();
        const slice = element_tree.slice();
        slice.initElement(element, .normal, .last_child_of, top.parent);
        const children_index = try parseElement(slice, element, env, ast, ast_index, token_source, &cascade_arena);
        try stack.push(allocator, .{
            .sequence = ast.children(children_index),
            .parent = element,
        });
    }

    return root_element;
}

/// Returns the index of the child block.
fn parseElement(
    element_tree: ElementTree.Slice,
    element: Element,
    env: *Environment,
    ast: Ast.Slice,
    zml_element: Ast.Size,
    token_source: TokenSource,
    cascade_arena: *ArenaAllocator,
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
                    const type_name = try env.addTypeOrAttributeName(ast.location(index), token_source);
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
        _ = cascade_arena.reset(.retain_capacity);
        try applyStyleBlockDeclarations(element_tree, element, ast, style_block, token_source, cascade_arena);
    }

    const children = if (has_style_block)
        element_children.next(ast).?
    else
        style_block;
    assert(ast.tag(children) == .zml_children);

    return children;
}

fn applyStyleBlockDeclarations(
    element_tree: ElementTree.Slice,
    element: Element,
    ast: Ast.Slice,
    style_block: Ast.Size,
    token_source: TokenSource,
    cascade_arena: *ArenaAllocator,
) !void {
    const parsed_declarations = try zss.properties.declaration.parseDeclarationsFromAst(cascade_arena, ast, token_source, style_block);
    const sources = [2]*const CascadedValues{ &parsed_declarations.important, &parsed_declarations.normal };
    try element_tree.updateCascadedValues(element, &sources);
}

test astToElementTree {
    const input =
        \\* (display: block) { /*comment*/
        \\  type1 (all: unset) {}
        \\  type2 (display: block; all: inherit !important) {}
        \\}
    ;
    const token_source = try TokenSource.init(zss.util.Utf8String{ .data = input });
    const allocator = std.testing.allocator;

    var parser = Parser.init(token_source, allocator);
    defer parser.deinit();

    var ast = Ast{};
    defer ast.deinit(allocator);
    try parser.parse(&ast, allocator);

    var element_tree = ElementTree.init(allocator);
    defer element_tree.deinit();

    var env = Environment.init(allocator);
    defer env.deinit();
    const type1 = try env.addTypeOrAttributeNameString("type1");
    const type2 = try env.addTypeOrAttributeNameString("type2");

    const root_element = try astToElementTree(&element_tree, &env, ast.slice(), 1, token_source, allocator);
    const slice = element_tree.slice();
    const aggregates = zss.properties.aggregates;
    const CssWideKeyword = zss.values.types.CssWideKeyword;

    {
        const element = root_element;
        if (element.eqlNull()) return error.TestFailure;
        const cascaded_values = slice.get(.cascaded_values, element);
        const box_style = cascaded_values.get(.box_style) orelse return error.TestFailure;
        try std.testing.expectEqual(aggregates.BoxStyle{ .display = .block }, box_style);
    }

    {
        const element = slice.firstChild(root_element);
        if (element.eqlNull()) return error.TestFailure;
        try std.testing.expectEqual(type1, slice.get(.fq_type, element).name);
        const cascaded_values = slice.get(.cascaded_values, element);
        const all = cascaded_values.all orelse return error.TestFailure;
        try std.testing.expectEqual(@as(?CssWideKeyword, .unset), all);
    }

    {
        const element = slice.lastChild(root_element);
        if (element.eqlNull()) return error.TestFailure;
        try std.testing.expectEqual(type2, slice.get(.fq_type, element).name);
        const cascaded_values = slice.get(.cascaded_values, element);
        const all = cascaded_values.all orelse return error.TestFailure;
        try std.testing.expect(cascaded_values.get(.box_style) == null);
        try std.testing.expectEqual(@as(?CssWideKeyword, .inherit), all);
    }
}
