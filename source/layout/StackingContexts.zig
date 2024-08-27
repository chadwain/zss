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

tag: ArrayListUnmanaged(std.meta.Tag(Info)) = .{},
contexts: MultiArrayList(struct { index: Index, skip: Skip, id: Id }) = .{},
current_index: Index = undefined,
next_id: std.meta.Tag(Id) = 0,
allocator: Allocator, // TODO: This should not have its own allocator

pub fn deinit(sc: *StackingContexts) void {
    sc.tag.deinit(sc.allocator);
    sc.contexts.deinit(sc.allocator);
}

pub const Info = union(enum) {
    /// Represents no stacking context.
    none,
    /// Represents a stacking context that can have child stacking contexts.
    is_parent: ZIndex,
    /// Represents a stacking context that cannot have child stacking contexts.
    /// When one tries to create new stacking context as a child of one of these ones, it instead becomes its sibling.
    /// This type of stacking context is created by, for example, static-positioned inline-blocks, or absolute-positioned blocks.
    is_non_parent: ZIndex,
};

pub fn push(sc: *StackingContexts, info: Info, box_tree: *BoxTree, block_box: BlockBox) !?Id {
    try sc.tag.append(sc.allocator, info);

    const z_index = switch (info) {
        .none => return null,
        .is_parent, .is_non_parent => |z_index| z_index,
    };

    const sc_tree = &box_tree.stacking_contexts;

    const index: Index = if (sc.contexts.len == 0) 0 else blk: {
        const slice = sc_tree.slice();
        const skips, const z_indeces = .{ slice.items(.skip), slice.items(.z_index) };

        const parent = sc.contexts.get(sc.contexts.len - 1);
        var index = parent.index + 1;
        const end = parent.index + parent.skip;
        while (index < end and z_index >= z_indeces[index]) {
            index += skips[index];
        }

        break :blk index;
    };

    const id: Id = @enumFromInt(sc.next_id);
    const skip: Skip = switch (info) {
        .none => unreachable,
        .is_parent => blk: {
            try sc.contexts.append(sc.allocator, .{ .index = index, .skip = 1, .id = id });
            break :blk undefined;
        },
        .is_non_parent => 1,
    };
    try sc_tree.insert(
        box_tree.allocator,
        index,
        .{
            .skip = skip,
            .id = id,
            .z_index = z_index,
            .block_box = block_box,
            .ifcs = .{},
        },
    );

    sc.current_index = index;
    sc.next_id += 1;
    return id;
}

pub fn pop(sc: *StackingContexts, box_tree: *BoxTree) void {
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
