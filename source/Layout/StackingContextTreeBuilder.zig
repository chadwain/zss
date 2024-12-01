const Builder = @This();

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const MultiArrayList = std.MultiArrayList;

const zss = @import("../zss.zig");
const Stack = zss.util.Stack;
const used_values = zss.used_values;
const BlockRef = used_values.BlockRef;
const BoxTree = used_values.BoxTree;
const ZIndex = used_values.ZIndex;
const StackingContext = used_values.StackingContext;
const Index = StackingContext.Index;
const Skip = StackingContext.Skip;
const Id = StackingContext.Id;

/// A stack. A value is appended for every new stacking context.
contexts: MultiArrayList(Item) = .empty,
/// A stack. A value is appended for every parentable stacking context.
parentables: Stack(struct { index: Index }) = .{},
/// The index of the currently active stacking context.
/// If there is no active stacking context, the value is undefined.
// TODO: Redundant: This is always the same as `contexts.get(contexts.len - 1).index`
// TODO: Also, this field should not exist
current_index: Index = undefined,
next_id: std.meta.Tag(Id) = 0,
/// The set of stacking contexts which do not yet have an associated block box, and are therefore "incomplete".
/// This is for debugging purposes only, and will have no effect if runtime safety is disabled.
incompletes: IncompleteStackingContexts = .{},

const Item = struct {
    index: Index,
    parentable: bool,
    num_nones: Index,
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
    assert(b.incompletes.empty()); // TODO: This should be moved somewhere else
    b.contexts.deinit(allocator);
    b.parentables.deinit(allocator);
    b.incompletes.deinit(allocator);
}

pub fn pushInitial(b: *Builder, allocator: Allocator, box_tree: *BoxTree, ref: BlockRef) !Id {
    assert(b.contexts.len == 0);
    assert(b.parentables.top == null);
    assert(box_tree.stacking_contexts.len == 0);

    const index: Index = 0;
    b.parentables.top = .{ .index = index };
    return (try b.newStackingContext(allocator, index, true, 0, box_tree, ref)).?;
}

pub fn push(b: *Builder, allocator: Allocator, ty: Type, box_tree: *BoxTree, ref: BlockRef) !?Id {
    assert(b.contexts.len > 0);
    assert(b.parentables.top != null);

    const contexts = b.contexts.slice();
    const z_index = switch (ty) {
        .none => {
            contexts.items(.num_nones)[contexts.len - 1] += 1;
            return null;
        },
        .parentable, .non_parentable => |z_index| z_index,
    };

    const sc_tree = box_tree.stacking_contexts.slice();
    const parent_index = b.parentables.top.?.index;
    const index: Index = blk: {
        const skips = sc_tree.items(.skip);
        const z_indeces = sc_tree.items(.z_index);

        var index = parent_index + 1;
        const end = parent_index + skips[parent_index];
        while (index < end and z_index >= z_indeces[index]) {
            index += skips[index];
        }

        break :blk index;
    };

    const parentable = switch (ty) {
        .none => unreachable,
        .parentable => blk: {
            try b.parentables.push(allocator, .{ .index = index });
            break :blk true;
        },
        .non_parentable => blk: {
            sc_tree.items(.skip)[parent_index] += 1;
            break :blk false;
        },
    };

    return b.newStackingContext(allocator, index, parentable, z_index, box_tree, ref);
}

/// If the return value is not null, caller must eventually follow up with a call to `setBlock`.
/// Failure to do so is safety-checked undefined behavior.
pub fn pushWithoutBlock(b: *Builder, allocator: Allocator, ty: Type, box_tree: *BoxTree) !?Id {
    const id_opt = try push(b, allocator, ty, box_tree, undefined);
    if (id_opt) |id| try b.incompletes.insert(allocator, id);
    return id_opt;
}

fn newStackingContext(
    b: *Builder,
    allocator: Allocator,
    index: Index,
    parentable: bool,
    z_index: ZIndex,
    box_tree: *BoxTree,
    ref: BlockRef,
) !?Id {
    try b.contexts.append(allocator, .{
        .index = index,
        .parentable = parentable,
        .num_nones = 0,
    });
    const id: Id = @enumFromInt(b.next_id);
    try box_tree.stacking_contexts.insert(
        box_tree.allocator,
        index,
        .{
            .skip = 1,
            .id = id,
            .z_index = z_index,
            .ref = ref,
            .ifcs = .empty,
        },
    );
    b.current_index = index;
    b.next_id += 1;
    return id;
}

pub fn popInitial(b: *Builder) void {
    assert(b.contexts.len == 1);
    _ = b.parentables.pop();
    assert(b.parentables.top == null);
    const this = b.contexts.pop();
    assert(this.num_nones == 0);
    b.current_index = undefined;
}

pub fn pop(b: *Builder, box_tree: *BoxTree) void {
    assert(b.contexts.len > 1);
    assert(b.parentables.top != null);

    const num_nones = &b.contexts.items(.num_nones)[b.contexts.len - 1];
    if (num_nones.* > 0) {
        num_nones.* -= 1;
        return;
    }

    const this = b.contexts.pop();
    const contexts = b.contexts.slice();
    if (this.parentable) {
        assert(this.index == b.parentables.pop().index);
        const skips = box_tree.stacking_contexts.items(.skip);
        const parent_index = b.parentables.top.?.index;
        skips[parent_index] += skips[this.index];
    }

    b.current_index = contexts.items(.index)[contexts.len - 1];
}

pub fn setBlock(b: *Builder, id: Id, box_tree: *BoxTree, ref: BlockRef) void {
    const slice = box_tree.stacking_contexts.slice();
    const ids = slice.items(.id);
    const index: Index = @intCast(std.mem.indexOfScalar(Id, ids, id).?);
    slice.items(.ref)[index] = ref;
    b.incompletes.remove(id);
}
