//! zml - zss markup language
//!
//! zml is a lightweight & minimal markup language for creating documents.
//! Its main purpose is to be able to assign CSS properties and features to
//! document elements with as little syntax as possible.
//! The syntax should feel natural to anyone that has used CSS.
//!
//!
//! The grammar of zml documents is presented below.
//! It uses the value definition syntax described in CSS Values and Units Level 4.
//!
//! <root>               = <element>
//! <node>               = <directive>* [ <element> | <text> ]
//! <directive>          = <at-keyword-token> '(' <any-value> ')'
//!
//! <element>            = <features> <inline-style-block>? <children>
//! <text>               = <string-token>
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
//! <children>           = '{' <node>* '}'
//!
//! <ident-token>        = <defined in CSS Syntax Level 3>
//! <string-token>       = <defined in CSS Syntax Level 3>
//! <hash-token>         = <defined in CSS Syntax Level 3>
//! <at-keyword-token>   = <defined in CSS Syntax Level 3>
//! <any-value>          = <defined in CSS Syntax Level 3>
//! <declaration-list>   = <defined in CSS Style Attributes>
//!
//! Whitespace or comments are required between the components of <features>.
//! The <hash-token> component of <id> must be an "id" hash token.
//! No whitespace or comments are allowed between the components of <class>.
//! No whitespace or comments are allowed between the <at-keyword-token> and '(' of <directive>.
//!
//!
//! A directive can be placed before a node in order to modify it.
//! List of directives:
//!
//! @name - Give a name to a zml node. Named nodes can be accessed using `Document.named_nodes`.
//! Syntax: <ident-token>

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
    named_nodes: std.StringArrayHashMapUnmanaged(Element),

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
        for (document.named_nodes.keys()) |key| allocator.free(key);
        document.named_nodes.deinit(allocator);
    }
};

pub fn createDocument(
    allocator: Allocator,
    env: *Environment,
    ast: Ast,
    token_source: TokenSource,
    zml_document_index: Ast.Size,
) !Document {
    assert(ast.tag(zml_document_index) == .zml_document);
    var document: Document = .{
        .root_element = undefined,
        .urls = .empty,
        .cascade_source = .{},
        .named_nodes = .empty,
    };
    errdefer document.deinit(allocator);

    const root_zml_node_index = blk: {
        var document_children = ast.children(zml_document_index);
        const root_zml_node_index = document_children.nextSkipSpaces(ast) orelse {
            document.root_element = Element.null_element;
            return document;
        };
        assert(document_children.emptySkipSpaces(ast));
        break :blk root_zml_node_index;
    };

    var node_stack = Stack(struct { element: Element, child_sequence: Ast.Sequence }){};
    defer node_stack.deinit(allocator);

    document.root_element, const root_zml_children_index = try analyzeNode(&document, allocator, .orphan, env, ast, token_source, root_zml_node_index);
    if (root_zml_children_index) |index| {
        node_stack.top = .{ .element = document.root_element, .child_sequence = ast.children(index) };
    }

    while (node_stack.top) |*top| {
        const zml_node_index = top.child_sequence.nextSkipSpaces(ast) orelse {
            _ = node_stack.pop();
            continue;
        };

        const placement: ElementTree.NodePlacement = .{ .last_child_of = top.element };
        const element, const zml_children_index = try analyzeNode(&document, allocator, placement, env, ast, token_source, zml_node_index);
        if (zml_children_index) |index| {
            try node_stack.push(allocator, .{ .element = element, .child_sequence = ast.children(index) });
        }
    }

    return document;
}

fn analyzeNode(
    document: *Document,
    allocator: Allocator,
    placement: ElementTree.NodePlacement,
    env: *Environment,
    ast: Ast,
    token_source: TokenSource,
    zml_node_index: Ast.Size,
) !struct { Element, ?Ast.Size } {
    assert(ast.tag(zml_node_index) == .zml_node);
    const element = try env.element_tree.allocateElement(env.allocator);

    var child_sequence = ast.children(zml_node_index);
    while (child_sequence.nextSkipSpaces(ast)) |node_child_index| {
        switch (ast.tag(node_child_index)) {
            .zml_directive => {
                const directive_name = try token_source.copyAtKeyword(ast.location(node_child_index), allocator); // TODO: Avoid heap allocation
                defer allocator.free(directive_name);
                if (std.mem.eql(u8, directive_name, "name")) {
                    var directive_child_sequence = ast.children(node_child_index);
                    const name_index = directive_child_sequence.nextSkipSpaces(ast) orelse return error.InvalidZmlDirective;
                    if (ast.tag(name_index) != .token_ident) return error.InvalidZmlDirective;
                    if (!directive_child_sequence.emptySkipSpaces(ast)) return error.InvalidZmlDirective;

                    try document.named_nodes.ensureUnusedCapacity(allocator, 1);
                    const name = try token_source.copyIdentifier(ast.location(name_index), allocator);
                    errdefer allocator.free(name);
                    const gop = document.named_nodes.getOrPutAssumeCapacity(name);
                    if (gop.found_existing) return error.DuplicateZmlNamedNode;
                    gop.value_ptr.* = element;
                } else {
                    return error.UnrecognizedZmlDirective;
                }
            },
            .zml_element => {
                assert(child_sequence.emptySkipSpaces(ast));
                const zml_children_index = try analyzeElement(document, allocator, element, placement, env, ast, token_source, node_child_index);
                return .{ element, zml_children_index };
            },
            .zml_text => {
                assert(child_sequence.emptySkipSpaces(ast));
                try analyzeText(element, placement, env, ast, token_source, node_child_index);
                return .{ element, null };
            },
            else => unreachable,
        }
    }
    unreachable;
}

fn analyzeElement(
    document: *Document,
    allocator: Allocator,
    element: Element,
    placement: ElementTree.NodePlacement,
    env: *Environment,
    ast: Ast,
    token_source: TokenSource,
    zml_element_index: Ast.Size,
) !Ast.Size {
    assert(ast.tag(zml_element_index) == .zml_element);
    env.element_tree.initElement(element, .normal, placement);

    var element_child_sequence = ast.children(zml_element_index);

    const zml_features_index = element_child_sequence.nextSkipSpaces(ast).?;
    assert(ast.tag(zml_features_index) == .zml_features);

    var features_child_sequence = ast.children(zml_features_index);
    while (features_child_sequence.nextSkipSpaces(ast)) |index| {
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

    const zml_styles_index = element_child_sequence.nextSkipSpaces(ast).?;
    const has_style_block = (ast.tag(zml_styles_index) == .zml_styles);
    if (has_style_block) {
        const last_declaration = ast.extra(zml_styles_index).index;
        try applyStyleBlockDeclarations(document, allocator, element, env, ast, token_source, last_declaration);
    }

    const zml_children_index = if (has_style_block)
        element_child_sequence.nextSkipSpaces(ast).?
    else
        zml_styles_index;
    assert(ast.tag(zml_children_index) == .zml_children);

    assert(element_child_sequence.emptySkipSpaces(ast));
    return zml_children_index;
}

fn analyzeText(
    element: Element,
    placement: ElementTree.NodePlacement,
    env: *Environment,
    ast: Ast,
    token_source: TokenSource,
    zml_text_index: Ast.Size,
) !void {
    assert(ast.tag(zml_text_index) == .zml_text);
    env.element_tree.initElement(element, .text, placement);

    // TODO: Don't use the element tree's arena
    var arena = env.element_tree.arena.promote(env.allocator);
    defer env.element_tree.arena = arena.state;
    const location = ast.location(zml_text_index);
    const string = try token_source.copyString(location, arena.allocator());
    env.element_tree.setText(element, string);
}

fn applyStyleBlockDeclarations(
    document: *Document,
    allocator: Allocator,
    element: Element,
    env: *Environment,
    ast: Ast,
    token_source: TokenSource,
    last_declaration_index: Ast.Size,
) !void {
    var urls = zss.values.parse.Urls.init(env);
    defer urls.deinit(allocator);

    var buffer: [zss.property.recommended_buffer_size]u8 = undefined;
    const block = try zss.property.parseDeclarationsFromAst(env, ast, token_source, &buffer, last_declaration_index, urls.toManaged(allocator));
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
        \\@name(root) * (display: block) { /*comment*/
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

    var document = try createDocument(allocator, &env, ast, token_source, 0);
    defer document.deinit(allocator);

    try std.testing.expectEqual(@as(?Element, document.root_element), document.named_nodes.get("root"));

    env.root_element = document.root_element;
    const cascade_node = zss.cascade.Node{ .leaf = &document.cascade_source };
    try env.cascade_list.author.append(env.allocator, &cascade_node);
    try cascade.run(&env);

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
