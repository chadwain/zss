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

/// A structure capable of storing the cascaded values of all CSS properties for every document node.
pub const Database = struct {
    node_map: std.AutoHashMapUnmanaged(Environment.NodeId, Storage) = .empty,
    arena: std.heap.ArenaAllocator.State = .{},

    pub fn deinit(db: *Database, allocator: Allocator) void {
        db.node_map.deinit(allocator);

        var arena = db.arena.promote(allocator);
        defer db.arena = arena.state;
        arena.deinit();
    }

    pub fn addStorage(db: *Database, allocator: Allocator, node: Environment.NodeId) !*Storage {
        const gop = try db.node_map.getOrPut(allocator, node);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        return gop.value_ptr;
    }

    pub fn getStorage(db: *const Database, node: Environment.NodeId) ?*Storage {
        return db.node_map.getPtr(node);
    }

    /// Stores the cascaded values of all CSS properties for a single document node.
    /// Pointers to cascaded values are not stable.
    pub const Storage = struct {
        /// Maps each value group to its cascaded values.
        group_map: Map = .{},
        /// The cascaded value for the 'all' CSS property.
        all: ?CssWideKeyword = null,

        pub const Map = std.EnumMap(groups.Tag, usize);

        const CssWideKeyword = zss.values.types.CssWideKeyword;
        const groups = zss.values.groups;

        /// The main operation performed during the CSS cascade is "applying a declaration".
        ///
        /// To apply a declaration "decl" to a destination value "destValue" means the following:
        ///     1. If "destValue" is NOT equal to `.undeclared`, do nothing and return.
        ///     2. If "decl" is affected by the CSS 'all' property, then copy the value of the 'all' property into "destValue" and return.
        ///     3. Copy "decl" into "destValue".
        ///
        /// You can also apply an entire declaration block to a destination storage
        /// (where "destination storage" is some arbitrary data structure than can hold cascaded values).
        ///
        /// To apply a declaration block "block" to a destination storage "destStorage" means the following:
        ///     1. For each declaration "decl" within "block", apply "decl" to the corresponding value within "destStorage".
        ///
        /// Declaration blocks must be passed to this function in cascade order.
        pub fn applyDeclBlock(
            storage: *Storage,
            /// The `Database` that `storage` belongs to.
            db: *Database,
            /// The database's allocator.
            allocator: Allocator,
            decls: *const zss.Declarations,
            block: zss.Declarations.Block,
            importance: Importance,
        ) !void {
            // TODO: The 'all' property does not affect some properties
            if (storage.all != null) return;

            if (decls.getAll(block, importance)) |all| storage.all = all;

            var iterator = decls.groupIterator(block, importance);
            while (iterator.next()) |group| {
                const needs_init = !storage.group_map.contains(group);
                const map_value = if (needs_init) storage.group_map.putUninitialized(group) else storage.group_map.getPtrAssertContains(group);

                switch (group) {
                    inline else => |comptime_group| {
                        const CascadedValues = comptime_group.CascadedValues();
                        const cascaded_values: *CascadedValues = switch (comptime canFitWithinUsize(CascadedValues)) {
                            true => blk: {
                                const values: *CascadedValues = @ptrCast(map_value);
                                if (needs_init) values.* = .{};
                                break :blk values;
                            },
                            false => blk: {
                                if (needs_init) {
                                    var arena = db.arena.promote(allocator);
                                    defer db.arena = arena.state;

                                    const values = try arena.allocator().create(CascadedValues);
                                    values.* = .{};
                                    map_value.* = @intFromPtr(values);
                                }
                                break :blk @ptrFromInt(map_value.*);
                            },
                        };
                        decls.apply(comptime_group, block, importance, cascaded_values);
                    },
                }
            }
        }

        /// If there is a cascaded value for the value group `group`, returns a pointer to it. Otherwise returns `null`.
        pub fn getPtr(storage: *const Storage, comptime group: groups.Tag) ?*const group.CascadedValues() {
            const map_value_ptr = storage.group_map.getPtrConst(group) orelse return null;
            const CascadedValues = group.CascadedValues();
            return switch (comptime canFitWithinUsize(CascadedValues)) {
                true => @ptrCast(map_value_ptr),
                false => @ptrFromInt(map_value_ptr.*),
            };
        }

        fn canFitWithinUsize(comptime T: type) bool {
            return (@alignOf(T) <= @alignOf(usize) and @sizeOf(T) <= @sizeOf(usize));
        }

        pub fn reset(storage: *Storage) void {
            storage.group_map = .{}; // TODO: Leaks memory (but okay, because of arena allocation)
            storage.all = null;
        }
    };
};

const RunContext = struct {
    arena: std.heap.ArenaAllocator,
    element_to_decl_block_list: std.AutoArrayHashMapUnmanaged(Environment.NodeId, std.ArrayListUnmanaged(BlockImportance)) = .empty,
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
pub fn run(list: *const List, env: *Environment, temp_allocator: Allocator) !void {
    var ctx = RunContext{ .arena = .init(temp_allocator) };
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

    var element_iterator = ctx.element_to_decl_block_list.iterator();
    while (element_iterator.next()) |entry| {
        const node = entry.key_ptr.*;
        const cascaded_values = try env.cascade_db.addStorage(env.allocator, node);
        cascaded_values.reset();
        for (entry.value_ptr.*.items) |item| {
            try cascaded_values.applyDeclBlock(&env.cascade_db, env.allocator, &env.decls, item.block, item.importance);
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
