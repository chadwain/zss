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
    slice_ptr: *const NodeTree.Slice,
    urls: std.MultiArrayList(Url),
    cascade_source: cascade.Source,
    named_nodes: std.StringArrayHashMapUnmanaged(Node.Index),

    pub const NodeTree = std.MultiArrayList(Node);

    pub const Node = struct {
        pub const Index = u32;

        pub const Extra = struct {
            // TODO: Storing a heap-allocated copy of the document tree is kinda weird.
            slice_ptr: *const NodeTree.Slice,
            zss_node: zss.Node,
        };

        extra: Extra,
        /// `parent == index` represents null.
        parent: Index,
        /// `next_sibling == 0` represents null.
        next_sibling: Index,
        /// `previous_sibling == 0` represents null.
        previous_sibling: Index,
        /// The first child of any node, if it exists, is `index + 1`.
        /// `last_child == 0` represents null.
        first_child: void,
        /// `last_child == 0` represents null.
        last_child: Index,

        pub const vtable: *const zss.Node.VTable = &.{
            .edge = vtable_fns.edge,
        };

        pub const vtable_fns = struct {
            pub fn edge(zss_node: *const zss.Node, which: zss.Node.Edge) ?*const zss.Node {
                const extra: *const Extra = @fieldParentPtr("zss_node", zss_node);
                const slice = extra.slice_ptr;
                const extra_base_ptr = slice.items(.extra).ptr;
                const index: Index = @intCast(extra - extra_base_ptr);

                switch (which) {
                    .parent => {
                        const parent = slice.items(.parent)[index];
                        if (parent == index) return null;
                        return &extra_base_ptr[parent].zss_node;
                    },
                    inline .previous_sibling, .next_sibling => |comptime_which| {
                        const sibling = slice.items(std.enums.nameCast(NodeTree.Field, comptime_which))[index];
                        if (sibling == 0) return null;
                        return &extra_base_ptr[sibling].zss_node;
                    },
                    inline .first_child, .last_child => |comptime_which| {
                        const last_child = slice.items(.last_child)[index];
                        if (last_child == 0) return null;
                        const child = switch (comptime_which) {
                            .first_child => index + 1,
                            .last_child => last_child,
                            else => comptime unreachable,
                        };
                        return &extra_base_ptr[child].zss_node;
                    },
                }
            }
        };
    };

    pub const Url = struct {
        const Urls = zss.values.parse.Urls;

        id: Environment.UrlId,
        node: Node.Index,
        type: Urls.Type,
        src_loc: Urls.SourceLocation,
    };

    pub fn deinit(document: *Document, allocator: Allocator) void {
        document.tree.deinit(allocator);
        allocator.destroy(document.slice_ptr);
        document.urls.deinit(allocator);
        document.cascade_source.deinit(allocator);
        for (document.named_nodes.keys()) |key| allocator.free(key);
        document.named_nodes.deinit(allocator);
    }

    pub fn rootNode(document: *const Document) ?Node.Index {
        if (document.tree.len == 0) return null;
        return 0;
    }

    pub fn rootZssNode(document: *const Document) ?*const zss.Node {
        const root_node = document.rootNode() orelse return null;
        return &document.tree.items(.extra)[root_node].zss_node;
    }
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
    ast: Ast,
    token_source: TokenSource,
    zml_document_index: Ast.Index,
) !Document {
    assert(zml_document_index.tag(ast) == .zml_document);

    var document: Document = .{
        .tree = .empty,
        .slice_ptr = try allocator.create(Document.NodeTree.Slice),
        .urls = .empty,
        .cascade_source = .{},
        .named_nodes = .empty,
    };
    errdefer document.deinit(allocator);

    const root_zml_node_index = blk: {
        var document_children = zml_document_index.children(ast);
        const root_zml_node_index = document_children.nextSkipSpaces(ast) orelse {
            @constCast(document.slice_ptr).* = .empty;
            return document;
        };
        assert(document_children.emptySkipSpaces(ast));
        break :blk root_zml_node_index;
    };

    const ns = struct {
        fn init(
            tr: *const Document.NodeTree.Slice,
            tree_index: Document.Node.Index,
            slice_ptr: *const Document.NodeTree.Slice,
            zss_node_id: zss.Node.Id,
            parent: Document.Node.Index,
            previous_sibling: Document.Node.Index,
        ) void {
            tr.items(.extra)[tree_index] = .{
                .slice_ptr = slice_ptr,
                .zss_node = .{
                    .vtable = Document.Node.vtable,
                    .id = zss_node_id,
                },
            };
            tr.items(.parent)[tree_index] = parent;
            tr.items(.previous_sibling)[tree_index] = previous_sibling;
            tr.items(.next_sibling)[tree_index] = 0;
            tr.items(.first_child)[tree_index] = {};
            if (previous_sibling != 0) {
                tr.items(.next_sibling)[previous_sibling] = tree_index;
            }
        }

        fn finalize(tr: *const Document.NodeTree.Slice, tree_index: Document.Node.Index, last_child: Document.Node.Index) void {
            tr.items(.last_child)[tree_index] = last_child;
        }
    };

    var tree = Document.NodeTree{};
    errdefer tree.deinit(allocator);

    const Item = struct {
        parent_tree_index: Document.Node.Index,
        previous_sibling_tree_index: Document.Node.Index,
        last_child_tree_index: Document.Node.Index,
        child_sequence: Ast.Sequence,
    };

    var stack = Stack(Item){};
    defer stack.deinit(allocator);

    const root_tree_index, const zss_root_node_id, const root_zml_children_index =
        try analyzeNode(&document, allocator, &tree, env, ast, token_source, root_zml_node_index);

    ns.init(&tree.slice(), root_tree_index, document.slice_ptr, zss_root_node_id, root_tree_index, 0);

    if (root_zml_children_index) |index| {
        stack.top = .{
            .parent_tree_index = root_tree_index,
            .previous_sibling_tree_index = 0,
            .last_child_tree_index = 0,
            .child_sequence = index.children(ast),
        };
    } else {
        ns.finalize(&tree.slice(), root_tree_index, 0);
    }

    while (stack.top) |*top| {
        const zml_node_index = top.child_sequence.nextSkipSpaces(ast) orelse {
            const item = stack.pop();
            ns.finalize(&tree.slice(), item.parent_tree_index, item.last_child_tree_index);
            if (stack.top) |*top2| top2.last_child_tree_index = item.parent_tree_index;
            continue;
        };

        const tree_index, const zss_node_id, const zml_children_index =
            try analyzeNode(&document, allocator, &tree, env, ast, token_source, zml_node_index);

        ns.init(&tree.slice(), tree_index, document.slice_ptr, zss_node_id, top.parent_tree_index, top.previous_sibling_tree_index);
        top.previous_sibling_tree_index = tree_index;

        if (zml_children_index) |index| {
            try stack.push(allocator, .{
                .parent_tree_index = tree_index,
                .previous_sibling_tree_index = 0,
                .last_child_tree_index = 0,
                .child_sequence = index.children(ast),
            });
        } else {
            ns.finalize(&tree.slice(), tree_index, tree_index + 1);
            top.last_child_tree_index = tree_index;
        }
    }

    for (tree.items(.extra)) |*extra| {
        env.nodes.set(.ptr, extra.zss_node.id, &extra.zss_node);
    }

    document.tree = tree.slice();
    @constCast(document.slice_ptr).* = document.tree;
    return document;
}

fn analyzeNode(
    document: *Document,
    allocator: Allocator,
    tree: *Document.NodeTree,
    env: *Environment,
    ast: Ast,
    token_source: TokenSource,
    zml_node_index: Ast.Index,
) !struct { Document.Node.Index, zss.Node.Id, ?Ast.Index } {
    assert(zml_node_index.tag(ast) == .zml_node);
    const tree_index: Document.Node.Index = @intCast(try tree.addOne(allocator));
    const zss_node_id = try env.createNode(); // TODO: Reserve every node beforehand

    var child_sequence = zml_node_index.children(ast);
    while (child_sequence.nextSkipSpaces(ast)) |node_child_index| {
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
                    gop.value_ptr.* = tree_index;
                } else {
                    return error.UnrecognizedZmlDirective;
                }
            },
            .zml_element => {
                assert(child_sequence.emptySkipSpaces(ast));
                const zml_children_index = try analyzeElement(document, allocator, tree_index, zss_node_id, env, ast, token_source, node_child_index);
                return .{ tree_index, zss_node_id, zml_children_index };
            },
            .zml_text => {
                assert(child_sequence.emptySkipSpaces(ast));
                try analyzeText(zss_node_id, env, ast, token_source, node_child_index);
                return .{ tree_index, zss_node_id, null };
            },
            else => unreachable,
        }
    }
    unreachable;
}

fn analyzeElement(
    document: *Document,
    allocator: Allocator,
    tree_index: Document.Node.Index,
    zss_node_id: zss.Node.Id,
    env: *Environment,
    ast: Ast,
    token_source: TokenSource,
    zml_element_index: Ast.Index,
) !Ast.Index {
    assert(zml_element_index.tag(ast) == .zml_element);
    env.nodes.set(.category, zss_node_id, .element);

    var element_child_sequence = zml_element_index.children(ast);

    const zml_features_index = element_child_sequence.nextSkipSpaces(ast).?;
    assert(zml_features_index.tag(ast) == .zml_features);

    var features_child_sequence = zml_features_index.children(ast);
    while (features_child_sequence.nextSkipSpaces(ast)) |index| {
        switch (index.tag(ast)) {
            .zml_type => {
                const type_name = try env.addTypeOrAttributeName(index.location(ast), token_source);
                env.nodes.set(.type, zss_node_id, .{ .namespace = .none, .name = type_name });
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
        try analyzeInlineStyleBlock(document, allocator, tree_index, zss_node_id, env, ast, token_source, last_declaration);
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
    zss_node_id: zss.Node.Id,
    env: *Environment,
    ast: Ast,
    token_source: TokenSource,
    zml_text_index: Ast.Index,
) !void {
    assert(zml_text_index.tag(ast) == .zml_text);
    env.nodes.set(.category, zss_node_id, .text);

    const text_id = try env.addTextFromStringToken(zml_text_index.location(ast), token_source);
    env.nodes.set(.text, zss_node_id, text_id);
}

fn analyzeInlineStyleBlock(
    document: *Document,
    allocator: Allocator,
    tree_index: Document.Node.Index,
    zss_node_id: zss.Node.Id,
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
        try document.urls.append(allocator, .{ .id = url.id, .node = tree_index, .type = url.desc.type, .src_loc = url.desc.src_loc });
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

    var document = try createDocument(allocator, &env, ast, token_source, zml_document_index);
    defer document.deinit(allocator);

    try std.testing.expectEqual(document.rootNode(), document.named_nodes.get("the-root-element"));

    if (document.rootZssNode()) |root_zss_node| {
        env.root_node = root_zss_node.id;
    } else {
        return error.TestFailure;
    }

    const cascade_node = zss.cascade.Node{ .leaf = &document.cascade_source };
    try env.cascade_list.author.append(env.allocator, &cascade_node);
    try cascade.run(&env);

    const types = zss.values.types;

    {
        const node = document.rootZssNode().?;
        const cascaded_values = env.nodes.get(.cascaded_values, node.id);
        const box_style = cascaded_values.getPtr(.box_style) orelse return error.TestFailure;
        try box_style.display.expectEqual(.{ .declared = .block });
    }

    {
        const node = document.rootZssNode().?.firstChild() orelse return error.TestFailure;
        try std.testing.expectEqual(type1, env.nodes.get(.type, node.id).name);
        const cascaded_values = env.nodes.get(.cascaded_values, node.id);
        const all = cascaded_values.all orelse return error.TestFailure;
        try std.testing.expectEqual(types.CssWideKeyword.unset, all);
    }

    {
        const node = document.rootZssNode().?.lastChild() orelse return error.TestFailure;
        try std.testing.expectEqual(type2, env.nodes.get(.type, node.id).name);
        const cascaded_values = env.nodes.get(.cascaded_values, node.id);
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

    var document = try createDocument(allocator, &env, ast, token_source, zml_document_index);
    defer document.deinit(allocator);
}
