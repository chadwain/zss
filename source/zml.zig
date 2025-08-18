//! zml - zss markup language
//!
//! zml is a lightweight & minimal markup language for creating documents.
//! Its main purpose is to be able to assign CSS properties and features to
//! document elements with as little syntax as possible.
//! The syntax should feel natural to anyone that has used CSS.
//!
//! The grammar of zml documents is presented below.
//! It uses the value definition syntax described in CSS Values and Units Level 4.
//!
//! <root>               = <element>
//! <element>            = <normal-element> | <text-element>
//! <normal-element>     = <features> <inline-style-block>? <children>
//! <text-element>       = <string-token>
//!
//! <features>           = '*' | [ <type> | <id> | <class> | <attribute> ]+
//! <type>               = <ident-token>
//! <id>                 = <hash-token>
//! <class>              = '.' <ident-token>
//! <attribute>          = '[' <ident-token> [ '=' <attribute-value> ]? ']'
//! <attribute-value>    = <ident-token> | <string-token>
//!
//! <inline-style-block> = '(' <declaration-list> ')'
//!
//! <children>           = '{' <element>* '}'
//!
//! <ident-token>        = <defined in CSS Syntax Level 3>
//! <string-token>       = <defined in CSS Syntax Level 3>
//! <hash-token>         = <defined in CSS Syntax Level 3>
//! <declaration-list>   = <defined in CSS Style Attributes>
//!
//! Whitespace or comments are required between the components of <features>.
//! The <hash-token> component of <id> must be an "id" hash token.
//! No whitespace or comments are allowed between the components of <class>.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const zss = @import("zss.zig");
const cascade = zss.cascade;
const Ast = zss.syntax.Ast;
const Environment = zss.Environment;
const ElementTree = zss.ElementTree;
const Element = ElementTree.Element;
const Stack = zss.Stack;
const TokenSource = zss.syntax.TokenSource;

pub fn createDocument(
    element_tree: *ElementTree,
    allocator: Allocator,
    env: *Environment,
    ast: Ast,
    root_ast_index: Ast.Size,
    token_source: TokenSource,
    cascade_source: *cascade.Source,
) !Element {
    env.recentUrlsManaged().clearUrls();

    var stack = Stack(struct {
        sequence: Ast.Sequence,
        parent: Element,
    }){};
    defer stack.deinit(allocator);

    const root_placement: ElementTree.NodePlacement = .orphan;
    const root_element, const root_children =
        try createElement(element_tree, allocator, root_placement, env, ast, root_ast_index, token_source, cascade_source);
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
        const placement: ElementTree.NodePlacement = .{ .last_child_of = top.parent };
        const element, const children =
            try createElement(element_tree, allocator, placement, env, ast, ast_index, token_source, cascade_source);
        if (children) |index| {
            try stack.push(allocator, .{
                .sequence = ast.children(index),
                .parent = element,
            });
        }
    }

    return root_element;
}

fn createElement(
    element_tree: *ElementTree,
    allocator: Allocator,
    placement: ElementTree.NodePlacement,
    env: *Environment,
    ast: Ast,
    ast_index: Ast.Size,
    token_source: TokenSource,
    cascade_source: *cascade.Source,
) !struct { Element, ?Ast.Size } {
    const element = try element_tree.allocateElement(allocator);
    switch (ast.tag(ast_index)) {
        .zml_element => {
            const children_index = try parseElement(element_tree, element, allocator, placement, env, ast, ast_index, token_source, cascade_source);
            return .{ element, children_index };
        },
        .zml_text_element => {
            try parseTextElement(element_tree, element, allocator, placement, ast, ast_index, token_source);
            return .{ element, null };
        },
        else => unreachable,
    }
}

fn parseElement(
    element_tree: *ElementTree,
    element: Element,
    allocator: Allocator,
    placement: ElementTree.NodePlacement,
    env: *Environment,
    ast: Ast,
    zml_element: Ast.Size,
    token_source: TokenSource,
    cascade_source: *cascade.Source,
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
                    element_tree.setFqType(element, .{ .namespace = .none, .name = type_name });
                },
                .zml_id => {
                    const id = try env.addIdName(ast.location(index), token_source);
                    try element_tree.registerId(allocator, id, element);
                },
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
        try applyStyleBlockDeclarations(element, env, ast, last_declaration, token_source, cascade_source);
    }

    const children = if (has_style_block)
        element_children.nextSkipSpaces(ast).?
    else
        style_block;
    assert(ast.tag(children) == .zml_children);

    return children;
}

fn parseTextElement(
    element_tree: *ElementTree,
    element: Element,
    allocator: Allocator,
    placement: ElementTree.NodePlacement,
    ast: Ast,
    zml_text_element: Ast.Size,
    token_source: TokenSource,
) !void {
    assert(ast.tag(zml_text_element) == .zml_text_element);
    element_tree.initElement(element, .text, placement);

    // TODO: Don't use the element tree's arena
    var arena = element_tree.arena.promote(allocator);
    defer element_tree.arena = arena.state;
    const location = ast.location(zml_text_element);
    const string = try token_source.copyString(location, arena.allocator());
    element_tree.setText(element, string);
}

fn applyStyleBlockDeclarations(
    element: Element,
    env: *Environment,
    ast: Ast,
    last_declaration: Ast.Size,
    token_source: TokenSource,
    cascade_source: *cascade.Source,
) !void {
    var buffer: [zss.property.recommended_buffer_size]u8 = undefined;
    const block = try zss.property.parseDeclarationsFromAst(env, ast, token_source, &buffer, last_declaration);
    if (env.decls.hasValues(block, .important)) try cascade_source.style_attrs_important.putNoClobber(env.allocator, element, block);
    if (env.decls.hasValues(block, .normal)) try cascade_source.style_attrs_normal.putNoClobber(env.allocator, element, block);
}

test createDocument {
    const input =
        \\* (display: block) { /*comment*/
        \\  type1 (all: unset) {}
        \\  type2 (display: block; all: inherit !important) {}
        \\}
    ;
    const token_source = try TokenSource.init(input);
    const allocator = std.testing.allocator;

    var ast = blk: {
        var parser = zss.syntax.Parser.init(token_source, allocator);
        defer parser.deinit();
        break :blk try parser.parseZmlDocument(allocator);
    };
    defer ast.deinit(allocator);

    var env = Environment.init(allocator);
    defer env.deinit();

    var element_tree = ElementTree.init();
    defer element_tree.deinit(allocator);

    const type1 = try env.addTypeOrAttributeNameString("type1");
    const type2 = try env.addTypeOrAttributeNameString("type2");

    const cascade_source = try env.cascade_tree.createSource(env.allocator);
    const root_element = try createDocument(&element_tree, allocator, &env, ast, 1, token_source, cascade_source);

    const cascade_node = try env.cascade_tree.createNode(env.allocator, .{ .leaf = cascade_source });
    try env.cascade_tree.author.append(env.allocator, cascade_node);
    try cascade.run(&env, &element_tree, root_element, allocator);

    const types = zss.values.types;

    {
        const element = root_element;
        if (element.eqlNull()) return error.TestFailure;
        const cascaded_values = element_tree.cascadedValues(element);
        const box_style = cascaded_values.getPtr(.box_style) orelse return error.TestFailure;
        try box_style.display.expectEqual(.{ .declared = .block });
    }

    {
        const element = element_tree.firstChild(root_element);
        if (element.eqlNull()) return error.TestFailure;
        try std.testing.expectEqual(type1, element_tree.fqType(element).name);
        const cascaded_values = element_tree.cascadedValues(element);
        const all = cascaded_values.all orelse return error.TestFailure;
        try std.testing.expectEqual(types.CssWideKeyword.unset, all);
    }

    {
        const element = element_tree.lastChild(root_element);
        if (element.eqlNull()) return error.TestFailure;
        try std.testing.expectEqual(type2, element_tree.fqType(element).name);
        const cascaded_values = element_tree.cascadedValues(element);
        const all = cascaded_values.all orelse return error.TestFailure;
        try std.testing.expect(cascaded_values.getPtr(.box_style) == null);
        try std.testing.expectEqual(types.CssWideKeyword.inherit, all);
    }
}
