const StackingContexts = @This();

const std = @import("std");
const assert = std.debug.assert;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const Allocator = std.mem.Allocator;
const MultiArrayList = std.MultiArrayList;

const zss = @import("../zss.zig");
const used_values = zss.used_values;
const BlockRef = used_values.BlockRef;
const BoxTree = used_values.BoxTree;
const ZIndex = used_values.ZIndex;
const StackingContext = used_values.StackingContext;
const Index = StackingContext.Index;
const Skip = StackingContext.Skip;
const Id = StackingContext.Id;

/// A stack. A value is appended for every call to `push`.
tag: ArrayListUnmanaged(std.meta.Tag(Type)) = .{},
/// A stack. A value is appended for every new parentable stacking context.
context: MultiArrayList(ParentableStackingContext) = .{},
/// The index of the currently active stacking context.
current_index: Index = undefined,
next_id: std.meta.Tag(Id) = 0,

const ParentableStackingContext = struct {
    index: Index,
    skip: Skip,
    id: Id,
};

pub const Type = union(enum) {
    /// Represents no stacking context.
    none,
    /// Represents a stacking context that can have child stacking contexts.
    parentable: ZIndex,
    /// Represents a stacking context that cannot have child stacking contexts.
    /// When one tries to create new stacking context as a child of one of these ones, it instead becomes its sibling.
    /// This type of stacking context is created by, for example, static-positioned inline-blocks, or absolute-positioned blocks.
    non_parentable: ZIndex,
};

pub fn deinit(sc: *StackingContexts, allocator: Allocator) void {
    sc.tag.deinit(allocator);
    sc.context.deinit(allocator);
}

pub fn push(sc: *StackingContexts, allocator: Allocator, ty: Type, box_tree: *BoxTree, ref: BlockRef) !?Id {
    try sc.tag.append(allocator, ty);

    const z_index = switch (ty) {
        .none => return null,
        .parentable, .non_parentable => |z_index| z_index,
    };

    const sc_tree = &box_tree.stacking_contexts;

    const index: Index = if (sc.context.len == 0) 0 else blk: {
        const slice = sc_tree.slice();
        const skips, const z_indeces = .{ slice.items(.skip), slice.items(.z_index) };

        const parent = sc.context.get(sc.context.len - 1);
        var index = parent.index + 1;
        const end = parent.index + parent.skip;
        while (index < end and z_index >= z_indeces[index]) {
            index += skips[index];
        }

        break :blk index;
    };

    const id: Id = @enumFromInt(sc.next_id);
    const skip: Skip = switch (ty) {
        .none => unreachable,
        .parentable => blk: {
            try sc.context.append(allocator, .{ .index = index, .skip = 1, .id = id });
            break :blk undefined;
        },
        .non_parentable => 1,
    };
    try sc_tree.insert(
        box_tree.allocator,
        index,
        .{
            .skip = skip,
            .id = id,
            .z_index = z_index,
            .ref = ref,
            .ifcs = .{},
        },
    );

    sc.current_index = index;
    sc.next_id += 1;
    return id;
}

/// If the return value is not null, caller must eventually follow up with a call to `setBlock`.
pub fn pushWithoutBlock(sc: *StackingContexts, allocator: Allocator, ty: Type, box_tree: *BoxTree) !?Id {
    return push(sc, allocator, ty, box_tree, undefined);
}

pub fn pop(sc: *StackingContexts, box_tree: *BoxTree) void {
    const tag = sc.tag.pop();
    const skip: Skip = switch (tag) {
        .none => return,
        .parentable => blk: {
            const context = sc.context.pop();
            box_tree.stacking_contexts.items(.skip)[context.index] = context.skip;
            break :blk context.skip;
        },
        .non_parentable => 1,
    };

    if (sc.tag.items.len > 0) {
        sc.current_index = sc.context.items(.index)[sc.context.len - 1];
        sc.context.items(.skip)[sc.context.len - 1] += skip;
    } else {
        sc.current_index = undefined;
    }
}

pub fn setBlock(box_tree: *BoxTree, id: Id, ref: BlockRef) void {
    const slice = box_tree.stacking_contexts.slice();
    const ids = slice.items(.id);
    const index: Index = @intCast(std.mem.indexOfScalar(Id, ids, id).?);
    slice.items(.ref)[index] = ref;
}
