const Builder = @This();

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
/// If there is no active stacking context, the value is undefined.
current_index: Index = undefined,
next_id: std.meta.Tag(Id) = 0,
/// The set of stacking contexts which do not yet have an associated block box, and are therefore "incomplete".
/// This is for debugging purposes only, and will have no effect if runtime safety is disabled.
incompletes: IncompleteStackingContexts = .{},

const ParentableStackingContext = struct {
    index: Index,
    skip: Skip,
    id: Id,
};

const IncompleteStackingContexts = switch (std.debug.runtime_safety) {
    true => struct {
        set: std.AutoHashMapUnmanaged(Id, void) = .empty,

        fn deinit(self: *IncompleteStackingContexts, allocator: Allocator) void {
            self.set.deinit(allocator);
        }

        fn insert(self: *IncompleteStackingContexts, allocator: Allocator, id: Id) !void {
            try self.set.putNoClobber(allocator, id, {});
        }

        fn remove(self: *IncompleteStackingContexts, id: Id) void {
            assert(self.set.remove(id));
        }

        fn empty(self: *IncompleteStackingContexts) bool {
            return self.set.count() == 0;
        }
    },
    false => struct {
        fn deinit(_: *IncompleteStackingContexts, _: Allocator) void {}

        fn insert(_: *IncompleteStackingContexts, _: Allocator, _: Id) !void {}

        fn remove(_: *IncompleteStackingContexts, _: Id) void {}

        fn empty(_: *IncompleteStackingContexts) bool {
            return true;
        }
    },
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

pub fn deinit(b: *Builder, allocator: Allocator) void {
    assert(b.incompletes.empty());
    b.incompletes.deinit(allocator);
    b.tag.deinit(allocator);
    b.context.deinit(allocator);
}

pub fn push(b: *Builder, allocator: Allocator, ty: Type, box_tree: *BoxTree, ref: BlockRef) !?Id {
    try b.tag.append(allocator, ty);

    const z_index = switch (ty) {
        .none => return null,
        .parentable, .non_parentable => |z_index| z_index,
    };

    const sc_tree = &box_tree.stacking_contexts;

    const index: Index = if (b.context.len == 0) 0 else blk: {
        const slice = sc_tree.slice();
        const skips, const z_indeces = .{ slice.items(.skip), slice.items(.z_index) };

        const parent = b.context.get(b.context.len - 1);
        var index = parent.index + 1;
        const end = parent.index + parent.skip;
        while (index < end and z_index >= z_indeces[index]) {
            index += skips[index];
        }

        break :blk index;
    };

    const id: Id = @enumFromInt(b.next_id);
    const skip: Skip = switch (ty) {
        .none => unreachable,
        .parentable => blk: {
            try b.context.append(allocator, .{ .index = index, .skip = 1, .id = id });
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

    b.current_index = index;
    b.next_id += 1;
    return id;
}

/// If the return value is not null, caller must eventually follow up with a call to `setBlock`.
/// Failure to do so is safety-checked undefined behavior.
pub fn pushWithoutBlock(b: *Builder, allocator: Allocator, ty: Type, box_tree: *BoxTree) !?Id {
    const id_opt = try push(b, allocator, ty, box_tree, undefined);
    if (id_opt) |id| try b.incompletes.insert(allocator, id);
    return id_opt;
}

pub fn pop(b: *Builder, box_tree: *BoxTree) void {
    const tag = b.tag.pop();
    const skip: Skip = switch (tag) {
        .none => return,
        .parentable => blk: {
            const context = b.context.pop();
            box_tree.stacking_contexts.items(.skip)[context.index] = context.skip;
            break :blk context.skip;
        },
        .non_parentable => 1,
    };

    if (b.tag.items.len > 0) {
        b.current_index = b.context.items(.index)[b.context.len - 1];
        b.context.items(.skip)[b.context.len - 1] += skip;
    } else {
        b.current_index = undefined;
    }
}

pub fn setBlock(b: *Builder, id: Id, box_tree: *BoxTree, ref: BlockRef) void {
    const slice = box_tree.stacking_contexts.slice();
    const ids = slice.items(.id);
    const index: Index = @intCast(std.mem.indexOfScalar(Id, ids, id).?);
    slice.items(.ref)[index] = ref;
    b.incompletes.remove(id);
}
