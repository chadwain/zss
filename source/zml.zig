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
    tree: NodeList.Slice,
    slice_ptr: *const NodeList.Slice,
    urls: std.MultiArrayList(Url),
    cascade_source: cascade.Source,
    named_nodes: std.StringArrayHashMapUnmanaged(Element),

    pub const NodeList = std.MultiArrayList(Node);

    pub const Node = struct {
        pub const Index = u32;

        pub const Extra = struct {
            // TODO: Storing a heap-allocated copy of the document tree is kinda weird.
            slice_ptr: *const NodeList.Slice,
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
            pub fn edge(zss_node: *zss.Node, which: zss.Node.Edge) ?*zss.Node {
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
                        const sibling = slice.items(std.enums.nameCast(NodeList.Field, comptime_which))[index];
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
        element: Element,
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

    pub fn rootZssNode(document: *const Document) ?*Node {
        if (document.tree.len == 0) return null;
        return &document.tree.items(.extra)[0].zss_node;
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
        .root_element = undefined,
        .tree = .empty,
        .slice_ptr = try allocator.create(Document.NodeList.Slice),
        .urls = .empty,
        .cascade_source = .{},
        .named_nodes = .empty,
    };
    errdefer document.deinit(allocator);

    var tree = Document.NodeList{};
    errdefer tree.deinit(allocator);

    const root_zml_node_index = blk: {
        var document_children = zml_document_index.children(ast);
        const root_zml_node_index = document_children.nextSkipSpaces(ast) orelse {
            document.root_element = Element.null_element;
            return document;
        };
        assert(document_children.emptySkipSpaces(ast));
        break :blk root_zml_node_index;
    };

    const ns = struct {
        fn init(tr: *const Document.NodeList.Slice, tree_index: Document.Node.Index, parent: Document.Node.Index, previous_sibling: Document.Node.Index) void {
            tr.items(.parent)[tree_index] = parent;
            tr.items(.previous_sibling)[tree_index] = previous_sibling;
            tr.items(.next_sibling)[tree_index] = 0;
            tr.items(.first_child)[tree_index] = {};
            if (previous_sibling != 0) {
                tr.items(.next_sibling)[previous_sibling] = tree_index;
            }
        }

        fn finalize(tr: *const Document.NodeList.Slice, tree_index: Document.Node.Index, last_child: Document.Node.Index) void {
            tr.items(.last_child)[tree_index] = last_child;
        }
    };

    const Item = struct {
        element: Element,
        parent_tree_index: Document.Node.Index,
        previous_sibling_tree_index: Document.Node.Index,
        last_child_tree_index: Document.Node.Index,
        child_sequence: Ast.Sequence,
    };

    var stack = Stack(Item){};
    defer stack.deinit(allocator);

    const root_tree_index: Document.Node.Index = @intCast(try tree.addOne(allocator));
    ns.init(&tree.slice(), root_tree_index, root_tree_index, 0);

    document.root_element, const root_zml_children_index = try analyzeNode(&document, allocator, .orphan, env, ast, token_source, root_zml_node_index);
    if (root_zml_children_index) |index| {
        stack.top = .{
            .element = document.root_element,
            .parent_tree_index = root_tree_index,
            .previous_sibling_tree_index = 0,
            .last_child_tree_index = 0,
            .child_sequence = index.children(ast),
        };
    } else {
        ns.finalize(&tree.slice(), root_tree_index, root_tree_index + 1);
    }

    while (stack.top) |*top| {
        const zml_node_index = top.child_sequence.nextSkipSpaces(ast) orelse {
            const item = stack.pop();
            ns.finalize(&tree.slice(), item.parent_tree_index, item.last_child_tree_index);
            if (stack.top) |*top2| top2.last_child_tree_index = item.parent_tree_index;
            continue;
        };

        const tree_index: Document.Node.Index = @intCast(try tree.addOne(allocator));
        ns.init(&tree.slice(), tree_index, top.parent_tree_index, top.previous_sibling_tree_index);
        top.previous_sibling_tree_index = tree_index;

        const placement: ElementTree.NodePlacement = .{ .last_child_of = top.element };
        const element, const zml_children_index = try analyzeNode(&document, allocator, placement, env, ast, token_source, zml_node_index);
        if (zml_children_index) |index| {
            try stack.push(allocator, .{
                .element = element,
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

    @memset(tree.items(.extra), .{
        .slice_ptr = document.slice_ptr,
        .zss_node = .{ .vtable = Document.Node.vtable },
    });

    document.tree = tree.slice();
    @constCast(document.slice_ptr).* = document.tree;
    return document;
}

fn analyzeNode(
    document: *Document,
    allocator: Allocator,
    placement: ElementTree.NodePlacement,
    env: *Environment,
    ast: Ast,
    token_source: TokenSource,
    zml_node_index: Ast.Index,
) !struct { Element, ?Ast.Index } {
    assert(zml_node_index.tag(ast) == .zml_node);
    const element = try env.element_tree.allocateElement(env.allocator);

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
    zml_element_index: Ast.Index,
) !Ast.Index {
    assert(zml_element_index.tag(ast) == .zml_element);
    env.element_tree.initElement(element, .normal, placement);

    var element_child_sequence = zml_element_index.children(ast);

    const zml_features_index = element_child_sequence.nextSkipSpaces(ast).?;
    assert(zml_features_index.tag(ast) == .zml_features);

    var features_child_sequence = zml_features_index.children(ast);
    while (features_child_sequence.nextSkipSpaces(ast)) |index| {
        switch (index.tag(ast)) {
            .zml_type => {
                const type_name = try env.addTypeOrAttributeName(index.location(ast), token_source);
                env.element_tree.setFqType(element, .{ .namespace = .none, .name = type_name });
            },
            .zml_id => {
                const id = try env.addIdName(index.location(ast), token_source);
                try env.element_tree.registerId(env.allocator, id, element);
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
        try analyzeInlineStyleBlock(document, allocator, element, env, ast, token_source, last_declaration);
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
    element: Element,
    placement: ElementTree.NodePlacement,
    env: *Environment,
    ast: Ast,
    token_source: TokenSource,
    zml_text_index: Ast.Index,
) !void {
    assert(zml_text_index.tag(ast) == .zml_text);
    env.element_tree.initElement(element, .text, placement);
    const text_id = try env.addTextFromStringToken(zml_text_index.location(ast), token_source);
    env.element_tree.setText(element, text_id);
}

fn analyzeInlineStyleBlock(
    document: *Document,
    allocator: Allocator,
    element: Element,
    env: *Environment,
    ast: Ast,
    token_source: TokenSource,
    last_declaration_index: Ast.Index,
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

test "create a zml document" {
    const input =
        \\@name(root) * (display: block) { /*comment*/
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
