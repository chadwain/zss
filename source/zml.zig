const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const zss = @import("zss.zig");
const Ast = zss.syntax.Ast;
const Declarations = zss.property.Declarations;
const Environment = zss.Environment;
const ElementTree = zss.ElementTree;
const Element = ElementTree.Element;
const Stack = zss.Stack;
const TokenSource = zss.syntax.TokenSource;

const parse = @import("zml/parse.zig");
pub const Parser = parse.Parser;

comptime {
    if (@import("builtin").is_test) {
        _ = parse;
    }
}

pub fn astToElement(
    element_tree: *ElementTree,
    env: *Environment,
    ast: Ast,
    root_ast_index: Ast.Size,
    token_source: TokenSource,
    allocator: Allocator,
) !Element {
    var stack = Stack(struct {
        sequence: Ast.Sequence,
        parent: Element,
    }){};
    defer stack.deinit(allocator);

    const root_placement: ElementTree.Slice.NodePlacement = .orphan;
    const root_element, const root_children =
        try astToElementOneIter(element_tree, root_placement, env, ast, root_ast_index, token_source);
    if (root_children) |index| {
        stack.top = .{
            .sequence = ast.children(index),
            .parent = root_element,
        };
    }
    while (stack.top) |*top| {
        const ast_index = top.sequence.nextSkipSpaces(ast) orelse {
            _ = stack.pop();
            continue;
        };
        const placement: ElementTree.Slice.NodePlacement = .{ .last_child_of = top.parent };
        const element, const children =
            try astToElementOneIter(element_tree, placement, env, ast, ast_index, token_source);
        if (children) |index| {
            try stack.push(allocator, .{
                .sequence = ast.children(index),
                .parent = element,
            });
        }
    }

    return root_element;
}

fn astToElementOneIter(
    element_tree: *ElementTree,
    placement: ElementTree.Slice.NodePlacement,
    env: *Environment,
    ast: Ast,
    ast_index: Ast.Size,
    token_source: TokenSource,
) !struct { Element, ?Ast.Size } {
    const element = try element_tree.allocateElement();
    const slice = element_tree.slice();
    switch (ast.tag(ast_index)) {
        .zml_element => {
            const children_index = try parseElement(slice, element, placement, env, ast, ast_index, token_source);
            return .{ element, children_index };
        },
        .zml_text_element => {
            try parseTextElement(slice, element, placement, ast, ast_index, token_source);
            return .{ element, null };
        },
        else => unreachable,
    }
}

fn parseElement(
    element_tree: ElementTree.Slice,
    element: Element,
    placement: ElementTree.Slice.NodePlacement,
    env: *Environment,
    ast: Ast,
    zml_element: Ast.Size,
    token_source: TokenSource,
) !Ast.Size {
    assert(ast.tag(zml_element) == .zml_element);
    element_tree.initElement(element, .normal, placement);

    var element_children = ast.children(zml_element);

    const features = element_children.nextSkipSpaces(ast).?;
    assert(ast.tag(features) == .zml_features);

    {
        var features_children = ast.children(features);
        while (features_children.nextSkipSpaces(ast)) |index| {
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

    const style_block = element_children.nextSkipSpaces(ast).?;
    const has_style_block = (ast.tag(style_block) == .zml_styles);
    if (has_style_block) {
        const last_declaration = ast.extra(style_block).index;
        try applyStyleBlockDeclarations(element_tree, element, env, ast, last_declaration, token_source);
    }

    const children = if (has_style_block)
        element_children.nextSkipSpaces(ast).?
    else
        style_block;
    assert(ast.tag(children) == .zml_children);

    return children;
}

fn parseTextElement(
    element_tree: ElementTree.Slice,
    element: Element,
    placement: ElementTree.Slice.NodePlacement,
    ast: Ast,
    zml_text_element: Ast.Size,
    token_source: TokenSource,
) !void {
    assert(ast.tag(zml_text_element) == .zml_text_element);
    element_tree.initElement(element, .text, placement);

    const location = ast.location(zml_text_element);
    const string = try token_source.copyString(location, element_tree.arena.allocator());
    element_tree.set(.text, element, string);
}

fn applyStyleBlockDeclarations(
    element_tree: ElementTree.Slice,
    element: Element,
    env: *Environment,
    ast: Ast,
    last_declaration: Ast.Size,
    token_source: TokenSource,
) !void {
    const block = try zss.property.parseDeclarationsFromAst(env, ast, token_source, &[0]u8{}, last_declaration);
    const sources = [2]ElementTree.Slice.DeclSource{
        .{ .block = block, .importance = .important },
        .{ .block = block, .importance = .normal },
    };
    try element_tree.updateCascadedValues(element, &env.decls, &sources);
}

test astToElement {
    const input =
        \\* (display: block) { /*comment*/
        \\  type1 (all: unset) {}
        \\  type2 (display: block; all: inherit !important) {}
        \\}
    ;
    const token_source = try TokenSource.init(input);
    const allocator = std.testing.allocator;

    var parser = Parser.init(token_source, allocator);
    defer parser.deinit();

    var ast = try parser.parse(allocator);
    defer ast.deinit(allocator);

    var element_tree = ElementTree.init(allocator);
    defer element_tree.deinit();

    var env = Environment.init(allocator);
    defer env.deinit();
    const type1 = try env.addTypeOrAttributeNameString("type1");
    const type2 = try env.addTypeOrAttributeNameString("type2");

    const root_element = try astToElement(&element_tree, &env, ast, 1, token_source, allocator);
    const slice = element_tree.slice();
    const types = zss.values.types;

    {
        const element = root_element;
        if (element.eqlNull()) return error.TestFailure;
        const cascaded_values = slice.get(.cascaded_values, element);
        const box_style = cascaded_values.getPtr(.box_style) orelse return error.TestFailure;
        try box_style.display.expectEqual(.{ .declared = .block });
    }

    {
        const element = slice.firstChild(root_element);
        if (element.eqlNull()) return error.TestFailure;
        try std.testing.expectEqual(type1, slice.get(.fq_type, element).name);
        const cascaded_values = slice.get(.cascaded_values, element);
        const all = cascaded_values.all orelse return error.TestFailure;
        try std.testing.expectEqual(types.CssWideKeyword.unset, all);
    }

    {
        const element = slice.lastChild(root_element);
        if (element.eqlNull()) return error.TestFailure;
        try std.testing.expectEqual(type2, slice.get(.fq_type, element).name);
        const cascaded_values = slice.get(.cascaded_values, element);
        const all = cascaded_values.all orelse return error.TestFailure;
        try std.testing.expect(cascaded_values.getPtr(.box_style) == null);
        try std.testing.expectEqual(types.CssWideKeyword.inherit, all);
    }
}
