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

pub const Document = struct {
    root_element: Element,
    urls: std.MultiArrayList(Url),
    cascade_source: cascade.Source,

    pub const Url = struct {
        const Urls = zss.values.parse.Urls;

        id: Environment.UrlId,
        element: Element,
        type: Urls.Type,
        src_loc: Urls.SourceLocation,
    };

    pub fn deinit(document: *Document, allocator: Allocator) void {
        document.urls.deinit(allocator);
        document.cascade_source.deinit(allocator);
    }
};

pub fn createDocument(
    allocator: Allocator,
    env: *Environment,
    ast: Ast,
    root_ast_index: Ast.Size, // TODO: This should be the index of a zml_document node
    token_source: TokenSource,
) !Document {
    var document: Document = .{
        .root_element = undefined,
        .urls = .empty,
        .cascade_source = .{},
    };
    errdefer document.deinit(allocator);

    var stack = Stack(struct {
        sequence: Ast.Sequence,
        parent: Element,
    }){};
    defer stack.deinit(allocator);

    const root_placement: ElementTree.NodePlacement = .orphan;
    document.root_element, const root_children =
        try createElement(&document, allocator, root_placement, env, ast, root_ast_index, token_source);
    if (root_children) |index| {
        stack.top = .{
            .sequence = ast.children(index),
            .parent = document.root_element,
        };
    }
    while (stack.top) |*top| {
        const ast_index = top.sequence.nextSkipSpaces(ast) orelse {
            _ = stack.pop();
            continue;
        };
        const placement: ElementTree.NodePlacement = .{ .last_child_of = top.parent };
        const element, const children =
            try createElement(&document, allocator, placement, env, ast, ast_index, token_source);
        if (children) |index| {
            try stack.push(allocator, .{
                .sequence = ast.children(index),
                .parent = element,
            });
        }
    }

    return document;
}

fn createElement(
    document: *Document,
    allocator: Allocator,
    placement: ElementTree.NodePlacement,
    env: *Environment,
    ast: Ast,
    ast_index: Ast.Size,
    token_source: TokenSource,
) !struct { Element, ?Ast.Size } {
    const element = try env.element_tree.allocateElement(env.allocator);
    switch (ast.tag(ast_index)) {
        .zml_element => {
            const children_index = try parseElement(document, allocator, element, placement, env, ast, ast_index, token_source);
            return .{ element, children_index };
        },
        .zml_text_element => {
            try parseTextElement(element, placement, env, ast, ast_index, token_source);
            return .{ element, null };
        },
        else => unreachable,
    }
}

fn parseElement(
    document: *Document,
    allocator: Allocator,
    element: Element,
    placement: ElementTree.NodePlacement,
    env: *Environment,
    ast: Ast,
    zml_element: Ast.Size,
    token_source: TokenSource,
) !Ast.Size {
    assert(ast.tag(zml_element) == .zml_element);
    env.element_tree.initElement(element, .normal, placement);

    var element_children = ast.children(zml_element);

    const features = element_children.nextSkipSpaces(ast).?;
    assert(ast.tag(features) == .zml_features);

    {
        var features_children = ast.children(features);
        while (features_children.nextSkipSpaces(ast)) |index| {
            switch (ast.tag(index)) {
                .zml_type => {
                    const type_name = try env.addTypeOrAttributeName(ast.location(index), token_source);
                    env.element_tree.setFqType(element, .{ .namespace = .none, .name = type_name });
                },
                .zml_id => {
                    const id = try env.addIdName(ast.location(index), token_source);
                    try env.element_tree.registerId(env.allocator, id, element);
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
        try applyStyleBlockDeclarations(document, allocator, element, env, ast, last_declaration, token_source);
    }

    const children = if (has_style_block)
        element_children.nextSkipSpaces(ast).?
    else
        style_block;
    assert(ast.tag(children) == .zml_children);

    return children;
}

fn parseTextElement(
    element: Element,
    placement: ElementTree.NodePlacement,
    env: *Environment,
    ast: Ast,
    zml_text_element: Ast.Size,
    token_source: TokenSource,
) !void {
    assert(ast.tag(zml_text_element) == .zml_text_element);
    env.element_tree.initElement(element, .text, placement);

    // TODO: Don't use the element tree's arena
    var arena = env.element_tree.arena.promote(env.allocator);
    defer env.element_tree.arena = arena.state;
    const location = ast.location(zml_text_element);
    const string = try token_source.copyString(location, arena.allocator());
    env.element_tree.setText(element, string);
}

fn applyStyleBlockDeclarations(
    document: *Document,
    allocator: Allocator,
    element: Element,
    env: *Environment,
    ast: Ast,
    last_declaration: Ast.Size,
    token_source: TokenSource,
) !void {
    var urls = zss.values.parse.Urls.init(env);
    defer urls.deinit(allocator);

    var buffer: [zss.property.recommended_buffer_size]u8 = undefined;
    const block = try zss.property.parseDeclarationsFromAst(env, ast, token_source, &buffer, last_declaration, urls.toManaged(allocator));
    if (env.decls.hasValues(block, .important)) try document.cascade_source.style_attrs_important.putNoClobber(env.allocator, element, block);
    if (env.decls.hasValues(block, .normal)) try document.cascade_source.style_attrs_normal.putNoClobber(env.allocator, element, block);

    urls.commit(env);
    var iterator = urls.iterator();
    while (iterator.next()) |url| {
        try document.urls.append(allocator, .{ .id = url.id, .element = element, .type = url.desc.type, .src_loc = url.desc.src_loc });
    }
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

    const type1 = try env.addTypeOrAttributeNameString("type1");
    const type2 = try env.addTypeOrAttributeNameString("type2");

    var document = try createDocument(allocator, &env, ast, 1, token_source);
    defer document.deinit(allocator);

    const cascade_node = zss.cascade.Node{ .leaf = &document.cascade_source };
    try env.cascade_list.author.append(env.allocator, &cascade_node);
    try cascade.run(&env, document.root_element);

    const types = zss.values.types;

    {
        const element = document.root_element;
        if (element.eqlNull()) return error.TestFailure;
        const cascaded_values = env.element_tree.cascadedValues(element);
        const box_style = cascaded_values.getPtr(.box_style) orelse return error.TestFailure;
        try box_style.display.expectEqual(.{ .declared = .block });
    }

    {
        const element = env.element_tree.firstChild(document.root_element);
        if (element.eqlNull()) return error.TestFailure;
        try std.testing.expectEqual(type1, env.element_tree.fqType(element).name);
        const cascaded_values = env.element_tree.cascadedValues(element);
        const all = cascaded_values.all orelse return error.TestFailure;
        try std.testing.expectEqual(types.CssWideKeyword.unset, all);
    }

    {
        const element = env.element_tree.lastChild(document.root_element);
        if (element.eqlNull()) return error.TestFailure;
        try std.testing.expectEqual(type2, env.element_tree.fqType(element).name);
        const cascaded_values = env.element_tree.cascadedValues(element);
        const all = cascaded_values.all orelse return error.TestFailure;
        try std.testing.expect(cascaded_values.getPtr(.box_style) == null);
        try std.testing.expectEqual(types.CssWideKeyword.inherit, all);
    }
}
