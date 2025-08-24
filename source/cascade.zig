const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const zss = @import("zss.zig");
const selectors = zss.selectors;
const Block = zss.property.Declarations.Block;
const ElementTree = zss.ElementTree;
const Element = ElementTree.Element;
const Environment = zss.Environment;
const Importance = zss.property.Importance;

/// The list of all cascade sources, grouped by their cascade origin.
///
/// You can affect the CSS cascade by inserting nodes into/removing nodes from the `user`, `author`, or `user_agent` lists.
/// Each list is independent of each other.
/// Nodes earlier in each list are considered to have a higher cascade order than later nodes in the same list.
///
/// During the cascade, each node is visited in the following way:
/// - If the node is a leaf node, its cascade source is applied.
/// - If the node is an inner node, each of its child nodes are visited in order, recursively.
pub const List = struct {
    user: std.ArrayListUnmanaged(*const Node) = .empty,
    author: std.ArrayListUnmanaged(*const Node) = .empty,
    user_agent: std.ArrayListUnmanaged(*const Node) = .empty,

    pub fn deinit(list: *List, allocator: Allocator) void {
        list.user.deinit(allocator);
        list.author.deinit(allocator);
        list.user_agent.deinit(allocator);
    }
};

pub const Origin = enum { user, author, user_agent };

pub const Node = union(enum) {
    leaf: *const Source,
    inner: []const *const Node,
};

/// Contains the data necessary for a document to participate in the CSS cascade.
/// Every document that contains CSS style information should produce one of these.
///
/// During the cascade (if this cascade source participates in it), this cascade source will get applied.
/// Applying a cascade source means to assign all of its style information to the appropriate elements in the element tree.
pub const Source = struct {
    /// Pairs of elements and important declaration blocks.
    /// These declaration blocks must be the results of parsing [style attributes](https://www.w3.org/TR/css-style-attr/),
    /// or some equivalent mechanism by which the document applies style information directly to a specific element.
    style_attrs_important: std.AutoHashMapUnmanaged(Element, Block) = .empty,
    /// Pairs of elements and normal declaration blocks.
    /// These declaration blocks must be the results of parsing [style attributes](https://www.w3.org/TR/css-style-attr/),
    /// or some equivalent mechanism by which the document applies style information directly to a specific element.
    style_attrs_normal: std.AutoHashMapUnmanaged(Element, Block) = .empty,
    /// Pairs of complex selectors and important declaration blocks.
    /// This list must be sorted such that selectors with higher cascade order appear earlier.
    selectors_important: std.MultiArrayList(SelectorBlock) = .empty,
    /// Pairs of complex selectors and normal declaration blocks.
    /// This list must be sorted such that selectors with higher cascade order appear earlier.
    selectors_normal: std.MultiArrayList(SelectorBlock) = .empty,
    selector_data: std.ArrayListUnmanaged(selectors.Code) = .empty,

    pub const SelectorBlock = struct {
        selector: selectors.Size,
        block: Block,
    };

    pub fn deinit(source: *Source, allocator: Allocator) void {
        source.style_attrs_important.deinit(allocator);
        source.style_attrs_normal.deinit(allocator);
        source.selectors_important.deinit(allocator);
        source.selectors_normal.deinit(allocator);
        source.selector_data.deinit(allocator);
    }
};

/// Runs the CSS cascade.
pub fn run(env: *Environment, root_element: Element) !void {
    var temp_arena = std.heap.ArenaAllocator.init(env.allocator);
    defer temp_arena.deinit();

    var block_lists = DeclBlockLists{};
    var stack = zss.Stack([]const *const Node){};
    const order: [6]struct { Origin, Importance } = .{
        .{ .user_agent, .important },
        .{ .user, .important },
        .{ .author, .important },
        .{ .author, .normal },
        .{ .user, .normal },
        .{ .user_agent, .normal },
    };
    for (order) |item| {
        const origin, const importance = item;
        try traverseList(&env.cascade_list, &env.element_tree, root_element, &block_lists, &stack, &temp_arena, origin, importance);
    }

    var element_tree_arena = env.element_tree.arena.promote(env.allocator);
    defer env.element_tree.arena = element_tree_arena.state;
    var element_iterator = block_lists.map.iterator();
    while (element_iterator.next()) |entry| {
        const element = entry.key_ptr.*;
        const cascaded_values = env.element_tree.cascadedValuesPtr(element);
        for (entry.value_ptr.*.items) |item| {
            try cascaded_values.applyDeclBlock(&element_tree_arena, &env.decls, item.block, item.importance);
        }
    }
}

const DeclBlockLists = struct {
    map: std.AutoArrayHashMapUnmanaged(Element, std.ArrayListUnmanaged(BlockImportance)) = .empty,

    const BlockImportance = struct {
        block: Block,
        importance: Importance,
    };

    fn insert(lists: *DeclBlockLists, arena: *std.heap.ArenaAllocator, element: Element, block: Block, importance: Importance) !void {
        const allocator = arena.allocator();
        const gop = try lists.map.getOrPut(allocator, element);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{};
        }
        try gop.value_ptr.append(allocator, .{ .block = block, .importance = importance });
    }
};

fn traverseList(
    list: *const List,
    element_tree: *const ElementTree,
    root_element: Element,
    block_lists: *DeclBlockLists,
    stack: *zss.Stack([]const *const Node),
    arena: *std.heap.ArenaAllocator,
    origin: Origin,
    importance: Importance,
) !void {
    const node_list = switch (origin) {
        .user => list.user,
        .author => list.author,
        .user_agent => list.user_agent,
    };
    const allocator = arena.allocator();

    assert(stack.top == null);
    stack.top = node_list.items;
    while (stack.top) |*top| {
        if (top.*.len == 0) {
            _ = stack.pop();
            continue;
        }
        const node: *const Node = top.*[0];
        top.* = top.*[1..];
        switch (node.*) {
            .inner => |inner| try stack.push(allocator, inner),
            .leaf => |source| try applySource(source, element_tree, root_element, block_lists, arena, importance),
        }
    }
}

fn applySource(
    source: *const Source,
    element_tree: *const ElementTree,
    root_element: Element,
    block_lists: *DeclBlockLists,
    arena: *std.heap.ArenaAllocator,
    importance: Importance,
) !void {
    {
        // TODO: Style attrs can only appear in sources with author origin
        const style_attrs = switch (importance) {
            .important => source.style_attrs_important,
            .normal => source.style_attrs_normal,
        };
        var it = style_attrs.iterator();
        while (it.next()) |entry| {
            try block_lists.insert(arena, entry.key_ptr.*, entry.value_ptr.*, importance);
        }
    }

    const selector_list = switch (importance) {
        .important => source.selectors_important,
        .normal => source.selectors_normal,
    };
    const allocator = arena.allocator();

    for (selector_list.items(.selector), selector_list.items(.block)) |selector, block| {
        var stack = zss.Stack(Element).init(root_element);
        while (stack.top) |*top| {
            if (top.eqlNull()) {
                _ = stack.pop();
                continue;
            }
            const element = top.*;
            top.* = element_tree.nextSibling(element);
            switch (element_tree.category(element)) {
                .text => continue,
                .normal => {},
            }
            const first_child = element_tree.firstChild(element);
            if (!first_child.eqlNull()) try stack.push(allocator, first_child);

            if (zss.selectors.matchElement(source.selector_data.items, selector, element_tree, element)) {
                try block_lists.insert(arena, element, block, importance);
            }
        }
    }
}
