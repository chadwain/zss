const StackingContexts = @This();

const std = @import("std");
const assert = std.debug.assert;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const Allocator = std.mem.Allocator;
const MultiArrayList = std.MultiArrayList;

const zss = @import("../zss.zig");
const used_values = zss.used_values;
const BlockBox = used_values.BlockBox;
const BoxTree = used_values.BoxTree;
const ZIndex = used_values.ZIndex;
const StackingContext = used_values.StackingContext;
const Index = StackingContext.Index;
const Skip = StackingContext.Skip;
const Id = StackingContext.Id;

tag: ArrayListUnmanaged(Tag) = .{},
contexts: MultiArrayList(struct { index: Index, skip: Skip, id: Id }) = .{},
current_index: Index = undefined,
next_id: std.meta.Tag(Id) = 0,
debug_state: DebugState = .{},
allocator: Allocator, // TODO: This should not have its own allocator

pub const Tag = enum {
    /// Represents no stacking context.
    none,
    /// Represents a stacking context that can have child stacking contexts.
    is_parent,
    /// Represents a stacking context that cannot have child stacking contexts.
    /// When one tries to create new stacking context as a child of one of these ones, it instead becomes its sibling.
    /// This type of stacking context is created by, for example, static-positioned inline-blocks, or
    /// relative-positioned blocks with a z-index that is not 'auto'.
    is_non_parent,
};

pub const Info = union(Tag) {
    none,
    is_parent: Id,
    is_non_parent: Id,
};

const DebugState = struct {
    state: if (std.debug.runtime_safety) State else void = if (std.debug.runtime_safety) .init else {},

    const State = enum { init, context_created };

    fn set(debug_state: *DebugState, state: State) void {
        if (std.debug.runtime_safety) debug_state.state = state;
    }

    fn assertState(debug_state: DebugState, state: State) void {
        if (std.debug.runtime_safety) assert(debug_state.state == state);
    }
};

pub fn deinit(sc: *StackingContexts) void {
    sc.tag.deinit(sc.allocator);
    sc.contexts.deinit(sc.allocator);
}

pub fn createRoot(sc: *StackingContexts, box_tree: *BoxTree, block_box: BlockBox) !Info {
    assert(box_tree.stacking_contexts.len == 0);
    try box_tree.stacking_contexts.ensureTotalCapacity(box_tree.allocator, 1);
    const id = sc.insert(0, &box_tree.stacking_contexts, block_box, 0);
    return .{ .is_parent = id };
}

pub fn create(sc: *StackingContexts, comptime tag: Tag, box_tree: *BoxTree, block_box: BlockBox, z_index: ZIndex) !Info {
    const sc_tree = &box_tree.stacking_contexts;
    try sc_tree.ensureUnusedCapacity(box_tree.allocator, 1);
    const slice = sc_tree.slice();
    const skips, const z_indeces = .{ slice.items(.skip), slice.items(.z_index) };

    const parent = sc.contexts.get(sc.contexts.len - 1);
    var index = parent.index + 1;
    const end = parent.index + parent.skip;
    while (index < end and z_index >= z_indeces[index]) {
        index += skips[index];
    }

    const id = sc.insert(index, sc_tree, block_box, z_index);
    return @unionInit(Info, @tagName(tag), id);
}

fn insert(sc: *StackingContexts, index: Index, sc_tree: *zss.used_values.StackingContextTree, block_box: BlockBox, z_index: ZIndex) Id {
    sc.debug_state.assertState(.init);
    sc_tree.insertAssumeCapacity(
        index,
        .{
            .skip = undefined,
            .id = @enumFromInt(sc.next_id),
            .z_index = z_index,
            .block_box = block_box,
            .ifcs = .{},
        },
    );
    sc.current_index = index;
    sc.debug_state.set(.context_created);
    defer sc.next_id += 1;
    return @enumFromInt(sc.next_id);
}

pub fn push(sc: *StackingContexts, box_tree: *BoxTree, info: Info) !void {
    try sc.tag.append(sc.allocator, info);
    switch (info) {
        .none => sc.debug_state.assertState(.init),
        .is_parent => |id| {
            sc.debug_state.assertState(.context_created);
            assert(id == box_tree.stacking_contexts.items(.id)[sc.current_index]);
            try sc.contexts.append(sc.allocator, .{ .index = sc.current_index, .skip = 1, .id = id });
        },
        .is_non_parent => |id| {
            sc.debug_state.assertState(.context_created);
            assert(id == box_tree.stacking_contexts.items(.id)[sc.current_index]);
            box_tree.stacking_contexts.items(.skip)[sc.current_index] = 1;
        },
    }
    sc.debug_state.set(.init);
}

pub fn pop(sc: *StackingContexts, box_tree: *BoxTree) void {
    sc.debug_state.assertState(.init);
    const tag = sc.tag.pop();
    const skip: Skip = switch (tag) {
        .none => return,
        .is_parent => blk: {
            const context = sc.contexts.pop();
            box_tree.stacking_contexts.items(.skip)[context.index] = context.skip;
            break :blk context.skip;
        },
        .is_non_parent => 1,
    };

    if (sc.tag.items.len > 0) {
        sc.current_index = sc.contexts.items(.index)[sc.contexts.len - 1];
        sc.contexts.items(.skip)[sc.contexts.len - 1] += skip;
    } else {
        sc.current_index = undefined;
    }
}

pub fn fixup(box_tree: *BoxTree, id: Id, block_box: BlockBox) void {
    const slice = box_tree.stacking_contexts.slice();
    const ids = slice.items(.id);
    const index: Index = @intCast(std.mem.indexOfScalar(Id, ids, id).?);
    slice.items(.block_box)[index] = block_box;
}
