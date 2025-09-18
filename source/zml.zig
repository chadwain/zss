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
const Stack = zss.Stack;
const TokenSource = zss.syntax.TokenSource;

pub const Document = struct {
    tree: NodeTree.Slice,
    urls: std.MultiArrayList(Url),
    cascade_source: cascade.Source,
    id: Environment.DocumentId,
    named_nodes: std.StringArrayHashMapUnmanaged(Node),

    pub const Size = u32;

    pub const Node = enum(Size) {
        _,

        pub fn parent(node: Node, document: *const Document) ?Node {
            const parent_index = document.tree.items(.parent)[@intFromEnum(node)];
            if (parent_index == node) return null;
            return parent_index;
        }

        pub fn nextSibling(node: Node, document: *const Document) ?Node {
            const next_sibling_index = document.tree.items(.next_sibling)[@intFromEnum(node)];
            if (@intFromEnum(next_sibling_index) == 0) return null;
            return next_sibling_index;
        }

        pub fn previousSibling(node: Node, document: *const Document) ?Node {
            const previous_sibling_index = document.tree.items(.previous_sibling)[@intFromEnum(node)];
            if (@intFromEnum(previous_sibling_index) == 0) return null;
            return previous_sibling_index;
        }

        pub fn firstChild(node: Node, document: *const Document) ?Node {
            const last_child_index = document.tree.items(.last_child)[@intFromEnum(node)];
            if (@intFromEnum(last_child_index) == 0) return null;
            return @enumFromInt(@intFromEnum(node) + 1);
        }

        pub fn lastChild(node: Node, document: *const Document) ?Node {
            const last_child_index = document.tree.items(.last_child)[@intFromEnum(node)];
            if (@intFromEnum(last_child_index) == 0) return null;
            return last_child_index;
        }

        pub fn toZssNode(node: Node, document: *const Document) Environment.NodeId {
            return .{ .document = document.id, .value = @intFromEnum(node) };
        }

        pub fn fromZssNode(document: *const Document, node: Environment.NodeId) Node {
            assert(document.id == node.document);
            return @enumFromInt(node.value);
        }
    };

    pub const NodeData = struct {
        /// `parent == index` represents null.
        parent: Node,
        /// `next_sibling == 0` represents null.
        next_sibling: Node,
        /// `previous_sibling == 0` represents null.
        previous_sibling: Node,

        // There is no `first_child` field. The first child of any node, if it exists, is `index + 1`.
        // `last_child == 0` represents null.

        /// `last_child == 0` represents null.
        last_child: Node,
    };

    pub const NodeTree = std.MultiArrayList(NodeData);

    pub const Url = struct {
        const Urls = zss.values.parse.Urls;

        id: Environment.UrlId,
        node: Node,
        type: Urls.Type,
        src_loc: Urls.SourceLocation,
    };

    pub fn deinit(document: *Document, allocator: Allocator) void {
        document.tree.deinit(allocator);
        document.urls.deinit(allocator);
        document.cascade_source.deinit(allocator);
        for (document.named_nodes.keys()) |key| allocator.free(key);
        document.named_nodes.deinit(allocator);
    }

    pub fn rootNode(document: *const Document) ?Node {
        if (document.tree.len == 0) return null;
        return @enumFromInt(0);
    }

    pub fn rootZssNode(document: *const Document) ?Environment.NodeId {
        if (document.tree.len == 0) return null;
        return .{ .document = document.id, .value = 0 };
    }

    pub fn setEnvTreeInterface(document: *const Document, env: *Environment) void {
        env.root_node = document.rootZssNode();
        env.tree_interface = .{
            .context = document,
            .vtable = comptime &.{
                .node_edge = tree_interface_fns.node_edge,
            },
        };
    }

    pub const tree_interface_fns = struct {
        pub fn node_edge(context: *const anyopaque, zss_node: Environment.NodeId, edge: Environment.TreeInterface.Edge) ?Environment.NodeId {
            const document: *const Document = @alignCast(@ptrCast(context));
            assert(zss_node.document == document.id);

            const node: Node = @enumFromInt(zss_node.value);
            const result_node = switch (edge) {
                .parent => node.parent(document),
                .previous_sibling => node.previousSibling(document),
                .next_sibling => node.nextSibling(document),
                .first_child => node.firstChild(document),
                .last_child => node.lastChild(document),
            } orelse return null;
            return .{ .document = document.id, .value = @intFromEnum(result_node) };
        }
    };
};

pub fn createDocumentFromTokenSource(allocator: Allocator, token_source: TokenSource, env: *Environment) !Document {
    var parser = zss.syntax.Parser.init(token_source, allocator);
    defer parser.deinit();
    var ast, const zml_document_index = try parser.parseZmlDocument(allocator);
    defer ast.deinit(allocator);
    return createDocument(allocator, env, ast, token_source, zml_document_index);
}

pub fn createDocument(
    allocator: Allocator,
    env: *Environment,
    id: Environment.DocumentId,
    ast: Ast,
    token_source: TokenSource,
    zml_document_index: Ast.Index,
) !Document {
    assert(zml_document_index.tag(ast) == .zml_document);

    var document: Document = .{
        .tree = .empty,
        .urls = .empty,
        .cascade_source = .{},
        .id = id,
        .named_nodes = .empty,
    };
    errdefer document.deinit(allocator);

    const root_zml_node_index = blk: {
        var document_children = zml_document_index.children(ast);
        const root_zml_node_index = document_children.nextSkipSpaces(ast) orelse return document;
        assert(document_children.emptySkipSpaces(ast));
        break :blk root_zml_node_index;
    };

    const ns = struct {
        fn init(
            tr: *const Document.NodeTree.Slice,
            doc_node: Document.Size,
            parent: Document.Size,
            previous_sibling: Document.Size,
        ) void {
            tr.items(.parent)[doc_node] = @enumFromInt(parent);
            tr.items(.previous_sibling)[doc_node] = @enumFromInt(previous_sibling);
            tr.items(.next_sibling)[doc_node] = @enumFromInt(0);
            if (previous_sibling != 0) {
                tr.items(.next_sibling)[previous_sibling] = @enumFromInt(doc_node);
            }
        }

        fn finalize(
            tr: *const Document.NodeTree.Slice,
            doc_node: Document.Size,
            last_child: Document.Size,
        ) void {
            tr.items(.last_child)[doc_node] = @enumFromInt(last_child);
        }

        fn getChildSequence(zml_children_index: ?Ast.Index, a: Ast) ?Ast.Sequence {
            const index = zml_children_index orelse return null;
            assert(index.tag(a) == .zml_children);
            var child_sequence = index.children(a);
            if (child_sequence.emptySkipSpaces(a)) return null;
            return child_sequence;
        }
    };

    var tree = Document.NodeTree{};
    errdefer tree.deinit(allocator);

    const Item = struct {
        parent_doc_node: Document.Size,
        previous_sibling_doc_node: Document.Size,
        last_child_doc_node: Document.Size,
        child_sequence: Ast.Sequence,
    };

    var stack = Stack(Item){};
    defer stack.deinit(allocator);

    const root_doc_node, const root_zml_children_index =
        try analyzeNode(&document, allocator, &tree, env, ast, token_source, root_zml_node_index);

    ns.init(&tree.slice(), root_doc_node, root_doc_node, 0);

    if (ns.getChildSequence(root_zml_children_index, ast)) |child_sequence| {
        stack.top = .{
            .parent_doc_node = root_doc_node,
            .previous_sibling_doc_node = 0,
            .last_child_doc_node = 0,
            .child_sequence = child_sequence,
        };
    } else {
        ns.finalize(&tree.slice(), root_doc_node, 0);
    }

    while (stack.top) |*top| {
        const zml_node_index = top.child_sequence.nextSkipSpaces(ast) orelse {
            const item = stack.pop();
            ns.finalize(&tree.slice(), item.parent_doc_node, item.last_child_doc_node);
            if (stack.top) |*top2| top2.last_child_doc_node = item.parent_doc_node;
            continue;
        };

        const doc_node, const zml_children_index =
            try analyzeNode(&document, allocator, &tree, env, ast, token_source, zml_node_index);

        ns.init(&tree.slice(), doc_node, top.parent_doc_node, top.previous_sibling_doc_node);
        top.previous_sibling_doc_node = doc_node;

        if (ns.getChildSequence(zml_children_index, ast)) |child_sequence| {
            try stack.push(allocator, .{
                .parent_doc_node = doc_node,
                .previous_sibling_doc_node = 0,
                .last_child_doc_node = 0,
                .child_sequence = child_sequence,
            });
        } else {
            ns.finalize(&tree.slice(), doc_node, 0);
            top.last_child_doc_node = doc_node;
        }
    }

    document.tree = tree.slice();
    return document;
}

/// Returns the document node index, and optionally the Ast index of a `zml_children` component.
fn analyzeNode(
    document: *Document,
    allocator: Allocator,
    tree: *Document.NodeTree,
    env: *Environment,
    ast: Ast,
    token_source: TokenSource,
    zml_node_index: Ast.Index,
) !struct { Document.Size, ?Ast.Index } {
    assert(zml_node_index.tag(ast) == .zml_node);
    const doc_node = std.math.cast(Document.Size, try tree.addOne(allocator)) orelse return error.Overflow;
    const zss_node_id: Environment.NodeId = .{ .document = document.id, .value = doc_node };

    var zml_node_child_sequence = zml_node_index.children(ast);
    try analyzeDirectives(document, allocator, doc_node, ast, token_source, &zml_node_child_sequence);
    const zml_node_last_child_index = zml_node_child_sequence.nextSkipSpaces(ast) orelse unreachable;
    assert(zml_node_child_sequence.emptySkipSpaces(ast));
    switch (zml_node_last_child_index.tag(ast)) {
        .zml_element => {
            const zml_children_index = try analyzeElement(document, allocator, doc_node, zss_node_id, env, ast, token_source, zml_node_last_child_index);
            return .{ doc_node, zml_children_index };
        },
        .zml_text => {
            assert(zml_node_child_sequence.emptySkipSpaces(ast));
            try analyzeText(zss_node_id, env, ast, token_source, zml_node_last_child_index);
            return .{ doc_node, null };
        },
        else => unreachable,
    }
}

fn analyzeDirectives(
    document: *Document,
    allocator: Allocator,
    doc_node: Document.Size,
    ast: Ast,
    token_source: TokenSource,
    zml_node_child_sequence: *Ast.Sequence,
) !void {
    while (zml_node_child_sequence.nextSkipSpaces(ast)) |node_child_index| {
        switch (node_child_index.tag(ast)) {
            .zml_directive => {
                const directive_name = try token_source.copyAtKeyword(node_child_index.location(ast), allocator); // TODO: Avoid heap allocation
                defer allocator.free(directive_name);
                if (std.mem.eql(u8, directive_name, "name")) {
                    var directive_child_sequence = node_child_index.children(ast);
                    const name_index = directive_child_sequence.nextSkipSpaces(ast) orelse return error.InvalidZmlDirective;
                    if (name_index.tag(ast) != .token_ident) return error.InvalidZmlDirective;
                    if (!directive_child_sequence.emptySkipSpaces(ast)) return error.InvalidZmlDirective;

                    try document.named_nodes.ensureUnusedCapacity(allocator, 1);
                    const name = try token_source.copyIdentifier(name_index.location(ast), allocator);
                    errdefer allocator.free(name);
                    const gop = document.named_nodes.getOrPutAssumeCapacity(name);
                    if (gop.found_existing) return error.DuplicateZmlNamedNode;
                    gop.value_ptr.* = @enumFromInt(doc_node);
                } else {
                    return error.UnrecognizedZmlDirective;
                }
            },
            else => {
                zml_node_child_sequence.reset(node_child_index);
                return;
            },
        }
    } else unreachable;
}

/// Returns the Ast index of the element's `zml_children` component.
fn analyzeElement(
    document: *Document,
    allocator: Allocator,
    doc_node: Document.Size,
    zss_node_id: Environment.NodeId,
    env: *Environment,
    ast: Ast,
    token_source: TokenSource,
    zml_element_index: Ast.Index,
) !Ast.Index {
    assert(zml_element_index.tag(ast) == .zml_element);
    try env.setNodeProperty(.category, zss_node_id, .element);

    var element_child_sequence = zml_element_index.children(ast);

    const zml_features_index = element_child_sequence.nextSkipSpaces(ast).?;
    assert(zml_features_index.tag(ast) == .zml_features);

    var features_child_sequence = zml_features_index.children(ast);
    while (features_child_sequence.nextSkipSpaces(ast)) |index| {
        switch (index.tag(ast)) {
            .zml_type => {
                const type_name = try env.addTypeOrAttributeName(index.location(ast), token_source);
                try env.setNodeProperty(.type, zss_node_id, .{ .namespace = .none, .name = type_name });
            },
            .zml_id => {
                const id = try env.addIdName(index.location(ast), token_source);
                try env.registerId(id, zss_node_id);
            },
            .zml_class => std.debug.panic("TODO: parse zml element: class feature", .{}),
            .zml_attribute => std.debug.panic("TODO: parse zml element: attribute feature", .{}),
            else => break,
        }
    }

    const zml_styles_index = element_child_sequence.nextSkipSpaces(ast).?;
    const has_style_block = (zml_styles_index.tag(ast) == .zml_styles);
    if (has_style_block) {
        const last_declaration = zml_styles_index.extra(ast).index;
        try analyzeInlineStyleBlock(document, allocator, doc_node, zss_node_id, env, ast, token_source, last_declaration);
    }

    const zml_children_index = if (has_style_block)
        element_child_sequence.nextSkipSpaces(ast).?
    else
        zml_styles_index;
    assert(zml_children_index.tag(ast) == .zml_children);

    assert(element_child_sequence.emptySkipSpaces(ast));
    return zml_children_index;
}

fn analyzeText(
    zss_node_id: Environment.NodeId,
    env: *Environment,
    ast: Ast,
    token_source: TokenSource,
    zml_text_index: Ast.Index,
) !void {
    assert(zml_text_index.tag(ast) == .zml_text);
    try env.setNodeProperty(.category, zss_node_id, .text);

    const text_id = try env.addTextFromStringToken(zml_text_index.location(ast), token_source);
    try env.setNodeProperty(.text, zss_node_id, text_id);
}

fn analyzeInlineStyleBlock(
    document: *Document,
    allocator: Allocator,
    doc_node: Document.Size,
    zss_node_id: Environment.NodeId,
    env: *Environment,
    ast: Ast,
    token_source: TokenSource,
    last_declaration_index: Ast.Index,
) !void {
    var urls = zss.values.parse.Urls.init(env);
    defer urls.deinit(allocator);

    var buffer: [zss.property.recommended_buffer_size]u8 = undefined;
    const block = try zss.property.parseDeclarationsFromAst(env, ast, token_source, &buffer, last_declaration_index, urls.toManaged(allocator));
    if (env.decls.hasValues(block, .important)) try document.cascade_source.style_attrs_important.putNoClobber(env.allocator, zss_node_id, block);
    if (env.decls.hasValues(block, .normal)) try document.cascade_source.style_attrs_normal.putNoClobber(env.allocator, zss_node_id, block);

    urls.commit(env);
    var iterator = urls.iterator();
    while (iterator.next()) |url| {
        try document.urls.append(allocator, .{ .id = url.id, .node = @enumFromInt(doc_node), .type = url.desc.type, .src_loc = url.desc.src_loc });
    }
}

test "create a zml document" {
    const input =
        \\@name(the-root-element) * (display: block) { /*comment*/
        \\  type1 (all: unset) {}
        \\  type2 (display: block; all: inherit !important) {}
        \\}
    ;
    const token_source = try TokenSource.init(input);
    const allocator = std.testing.allocator;

    var ast, const zml_document_index = blk: {
        var parser = zss.syntax.Parser.init(token_source, allocator);
        defer parser.deinit();
        break :blk try parser.parseZmlDocument(allocator);
    };
    defer ast.deinit(allocator);

    var env = Environment.init(allocator);
    defer env.deinit();

    const type1 = try env.addTypeOrAttributeNameString("type1");
    const type2 = try env.addTypeOrAttributeNameString("type2");

    var document = try createDocument(allocator, &env, try env.addDocument(), ast, token_source, zml_document_index);
    defer document.deinit(allocator);

    try std.testing.expectEqual(document.rootNode(), document.named_nodes.get("the-root-element"));

    document.setEnvTreeInterface(&env);

    const cascade_node = zss.cascade.Node{ .leaf = &document.cascade_source };
    try env.cascade_list.author.append(env.allocator, &cascade_node);
    try cascade.run(&env);

    const types = zss.values.types;

    {
        const node = document.rootNode() orelse return error.TestFailure;
        const zss_node = node.toZssNode(&document);
        assert(Document.Node.fromZssNode(&document, zss_node) == node);
        const cascaded_values = env.getNodeProperty(.cascaded_values, zss_node);
        const box_style = cascaded_values.getPtr(.box_style) orelse return error.TestFailure;
        try box_style.display.expectEqual(.{ .declared = .block });
    }

    {
        const node = document.rootNode().?.firstChild(&document) orelse return error.TestFailure;
        const zss_node = node.toZssNode(&document);
        assert(Document.Node.fromZssNode(&document, zss_node) == node);
        try std.testing.expectEqual(type1, env.getNodeProperty(.type, zss_node).name);
        const cascaded_values = env.getNodeProperty(.cascaded_values, zss_node);
        const all = cascaded_values.all orelse return error.TestFailure;
        try std.testing.expectEqual(types.CssWideKeyword.unset, all);
    }

    {
        const node = document.rootNode().?.lastChild(&document) orelse return error.TestFailure;
        const zss_node = node.toZssNode(&document);
        assert(Document.Node.fromZssNode(&document, zss_node) == node);
        try std.testing.expectEqual(type2, env.getNodeProperty(.type, zss_node).name);
        const cascaded_values = env.getNodeProperty(.cascaded_values, zss_node);
        const all = cascaded_values.all orelse return error.TestFailure;
        try std.testing.expect(cascaded_values.getPtr(.box_style) == null);
        try std.testing.expectEqual(types.CssWideKeyword.inherit, all);
    }
}

test "create a zml document 2" {
    const input =
        \\* {
        \\  * {
        \\    * {}
        \\    ""
        \\  }
        \\  * {
        \\    ""
        \\  }
        \\  * {}
        \\}
    ;
    const token_source = try TokenSource.init(input);
    const allocator = std.testing.allocator;

    var ast, const zml_document_index = blk: {
        var parser = zss.syntax.Parser.init(token_source, allocator);
        defer parser.deinit();
        break :blk try parser.parseZmlDocument(allocator);
    };
    defer ast.deinit(allocator);

    var env = Environment.init(allocator);
    defer env.deinit();

    var document = try createDocument(allocator, &env, try env.addDocument(), ast, token_source, zml_document_index);
    defer document.deinit(allocator);
}
