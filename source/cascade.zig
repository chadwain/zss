const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const zss = @import("zss.zig");
const selectors = zss.selectors;
const Block = zss.Declarations.Block;
const Environment = zss.Environment;
const Importance = zss.Declarations.Importance;

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
    user: []const *const Node = &.{},
    author: []const *const Node = &.{},
    user_agent: []const *const Node = &.{},
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
/// Applying a cascade source means to assign all of its style information to the appropriate elements in the document tree.
pub const Source = struct {
    /// Pairs of elements and important declaration blocks.
    /// These declaration blocks must be the results of parsing [style attributes](https://www.w3.org/TR/css-style-attr/),
    /// or some equivalent mechanism by which the document applies style information directly to a specific element.
    style_attrs_important: std.AutoHashMapUnmanaged(zss.Environment.NodeId, Block) = .empty,
    /// Pairs of elements and normal declaration blocks.
    /// These declaration blocks must be the results of parsing [style attributes](https://www.w3.org/TR/css-style-attr/),
    /// or some equivalent mechanism by which the document applies style information directly to a specific element.
    style_attrs_normal: std.AutoHashMapUnmanaged(zss.Environment.NodeId, Block) = .empty,
    /// Pairs of complex selectors and important declaration blocks.
    /// This list must be sorted such that selectors with higher cascade order appear earlier.
    selectors_important: std.MultiArrayList(SelectorBlock) = .empty,
    /// Pairs of complex selectors and normal declaration blocks.
    /// This list must be sorted such that selectors with higher cascade order appear earlier.
    selectors_normal: std.MultiArrayList(SelectorBlock) = .empty,
    selector_data: std.ArrayList(selectors.Data) = .empty,

    pub const SelectorBlock = struct {
        selector: selectors.Data.ListIndex,
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

const RunContext = struct {
    arena: std.heap.ArenaAllocator,
    element_to_decl_block_list: std.AutoArrayHashMapUnmanaged(zss.Environment.NodeId, std.ArrayListUnmanaged(BlockImportance)) = .empty,
    cascade_node_stack: zss.Stack([]const *const Node) = .{},
    document_node_stack: zss.Stack(?Environment.NodeId) = .{},

    const BlockImportance = struct {
        block: Block,
        importance: Importance,
    };

    fn appendDeclBlock(ctx: *RunContext, node: zss.Environment.NodeId, block: Block, importance: Importance) !void {
        const allocator = ctx.arena.allocator();
        const gop = try ctx.element_to_decl_block_list.getOrPut(allocator, node);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{};
        }
        try gop.value_ptr.append(allocator, .{ .block = block, .importance = importance });
    }
};

/// Runs the CSS cascade.
pub fn run(list: *const List, env: *Environment, allocator: Allocator) !void {
    var ctx = RunContext{ .arena = .init(allocator) };
    defer ctx.arena.deinit();

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
        try traverseList(&ctx, list, env, origin, importance);
    }

    var cascaded_values_arena = env.node_properties.arena.promote(env.allocator);
    defer env.node_properties.arena = cascaded_values_arena.state;
    var element_iterator = ctx.element_to_decl_block_list.iterator();
    while (element_iterator.next()) |entry| {
        const node = entry.key_ptr.*;
        const cascaded_values = try env.getNodePropertyPtr(.cascaded_values, node);
        cascaded_values.clear();
        for (entry.value_ptr.*.items) |item| {
            try cascaded_values.applyDeclBlock(&cascaded_values_arena, &env.decls, item.block, item.importance);
        }
    }
}

fn traverseList(ctx: *RunContext, list: *const List, env: *const Environment, origin: Origin, importance: Importance) !void {
    const node_list = switch (origin) {
        .user => list.user,
        .author => list.author,
        .user_agent => list.user_agent,
    };
    const allocator = ctx.arena.allocator();

    assert(ctx.cascade_node_stack.top == null);
    ctx.cascade_node_stack.top = node_list;
    while (ctx.cascade_node_stack.top) |*top| {
        if (top.*.len == 0) {
            _ = ctx.cascade_node_stack.pop();
            continue;
        }
        const node: *const Node = top.*[0];
        top.* = top.*[1..];

        switch (node.*) {
            .inner => |inner| try ctx.cascade_node_stack.push(allocator, inner),
            .leaf => |source| try applySource(ctx, source, env, importance),
        }
    }
}

fn applySource(ctx: *RunContext, source: *const Source, env: *const Environment, importance: Importance) !void {
    {
        // TODO: Style attrs can only appear in sources with author origin
        const style_attrs = switch (importance) {
            .important => source.style_attrs_important,
            .normal => source.style_attrs_normal,
        };
        var it = style_attrs.iterator();
        while (it.next()) |entry| {
            const node = entry.key_ptr.*;
            switch (env.getNodeProperty(.category, node)) {
                .text => unreachable,
                .element => {},
            }
            const block = entry.value_ptr.*;
            try ctx.appendDeclBlock(node, block, importance);
        }
    }

    const selector_list = switch (importance) {
        .important => source.selectors_important,
        .normal => source.selectors_normal,
    };
    const allocator = ctx.arena.allocator();

    for (selector_list.items(.selector), selector_list.items(.block)) |selector, block| {
        assert(ctx.document_node_stack.top == null);
        ctx.document_node_stack.top = env.root_node;
        while (ctx.document_node_stack.top) |*top| {
            const node = top.* orelse {
                _ = ctx.document_node_stack.pop();
                continue;
            };
            top.* = node.nextSibling(env);
            switch (env.getNodeProperty(.category, node)) {
                .text => continue,
                .element => {},
            }
            if (node.firstChild(env)) |first_child| try ctx.document_node_stack.push(allocator, first_child);

            if (zss.selectors.matchElement(source.selector_data.items, selector, env, node)) {
                try ctx.appendDeclBlock(node, block, importance);
            }
        }
    }
}
