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

pub const Tree = struct {
    user: std.ArrayListUnmanaged(*Node) = .empty,
    author: std.ArrayListUnmanaged(*Node) = .empty,
    user_agent: std.ArrayListUnmanaged(*Node) = .empty,

    nodes: std.ArrayListUnmanaged(*Node) = .empty,

    pub const Node = union(enum) {
        leaf: *const Source,
        inner: std.ArrayListUnmanaged(*Node),
    };

    pub fn deinit(tree: *Tree, allocator: Allocator) void {
        tree.user.deinit(allocator);
        tree.author.deinit(allocator);
        tree.user_agent.deinit(allocator);
        for (tree.nodes.items) |node| {
            switch (node.*) {
                .leaf => {},
                .inner => |*list| list.deinit(allocator),
            }
            allocator.destroy(node);
        }
        tree.nodes.deinit(allocator);
    }

    pub fn createNode(tree: *Tree, allocator: Allocator, value: Node) !*Node {
        try tree.nodes.ensureUnusedCapacity(allocator, 1);
        const node = try allocator.create(Node);
        node.* = value;
        tree.nodes.appendAssumeCapacity(node);
        return node;
    }
};

pub const Origin = enum { user, author, user_agent };

pub const Source = struct {
    style_attrs_important: std.AutoHashMapUnmanaged(Element, Block) = .empty,
    style_attrs_normal: std.AutoHashMapUnmanaged(Element, Block) = .empty,
    selectors_important: std.MultiArrayList(SelectorBlock) = .empty,
    selectors_normal: std.MultiArrayList(SelectorBlock) = .empty,
    selector_data: std.ArrayListUnmanaged(selectors.Code) = .empty,

    pub fn deinit(source: *Source, allocator: Allocator) void {
        source.style_attrs_important.deinit(allocator);
        source.style_attrs_normal.deinit(allocator);
        source.selectors_important.deinit(allocator);
        source.selectors_normal.deinit(allocator);
        source.selector_data.deinit(allocator);
    }
};

pub const SelectorBlock = struct {
    selector: selectors.Size,
    block: Block,
};

pub fn run(env: *Environment, root_element: Element) !void {
    var temp_arena = std.heap.ArenaAllocator.init(env.allocator);
    defer temp_arena.deinit();

    var lists = DeclBlockLists{};
    var stack = zss.Stack([]const *const Tree.Node){};
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
        try traverseTree(&env.cascade_tree, &env.element_tree, root_element, &lists, &stack, &temp_arena, origin, importance);
    }

    var element_tree_arena = env.element_tree.arena.promote(env.allocator);
    defer env.element_tree.arena = element_tree_arena.state;
    var element_iterator = lists.map.iterator();
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

fn traverseTree(
    tree: *const Tree,
    element_tree: *const ElementTree,
    root_element: Element,
    lists: *DeclBlockLists,
    stack: *zss.Stack([]const *const Tree.Node),
    arena: *std.heap.ArenaAllocator,
    origin: Origin,
    importance: Importance,
) !void {
    const node_list = switch (origin) {
        .user => tree.user,
        .author => tree.author,
        .user_agent => tree.user_agent,
    };
    const allocator = arena.allocator();

    assert(stack.top == null);
    stack.top = node_list.items;
    while (stack.top) |*top| {
        if (top.*.len == 0) {
            _ = stack.pop();
            continue;
        }
        const node: *const Tree.Node = top.*[0];
        top.* = top.*[1..];
        switch (node.*) {
            .inner => |inner| try stack.push(allocator, inner.items),
            .leaf => |source| try evaluateSource(source, element_tree, root_element, lists, arena, importance),
        }
    }
}

fn evaluateSource(
    source: *const Source,
    element_tree: *const ElementTree,
    root_element: Element,
    lists: *DeclBlockLists,
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
            try lists.insert(arena, entry.key_ptr.*, entry.value_ptr.*, importance);
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
                try lists.insert(arena, element, block, importance);
            }
        }
    }
}
