const Builder = @This();

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const zss = @import("../zss.zig");
const Stack = zss.Stack;

const BoxTree = zss.BoxTree;
const BlockRef = BoxTree.BlockRef;
const IfcId = BoxTree.InlineFormattingContextId;
const ZIndex = BoxTree.ZIndex;
const StackingContext = BoxTree.StackingContext;
const StackingContextTree = BoxTree.StackingContextTree;
const Size = StackingContextTree.Size;
const Id = StackingContextTree.Id;

/// A value is pushed for every new stacking context.
contexts: Stack(struct {
    index: Size,
    parentable: bool,
    num_nones: Size,
}) = .{},
/// A value is pushed for every parentable stacking context.
parentables: Stack(struct { index: Size }) = .{},
next_id: std.meta.Tag(Id) = 0,
/// The set of stacking contexts which do not yet have an associated block box, and are therefore "incomplete".
/// This is for debugging purposes only, and will have no effect if runtime safety is disabled.
incompletes: IncompleteStackingContexts = .{},

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
    b.contexts.deinit(allocator);
    b.parentables.deinit(allocator);
    b.incompletes.deinit(allocator);
}

pub fn endFrame(b: *Builder) void {
    assert(b.incompletes.empty());
}

pub fn pushInitial(b: *Builder, box_tree: *BoxTree, ref: BlockRef) !Id {
    assert(b.contexts.top == null);
    assert(b.parentables.top == null);
    assert(box_tree.stacking_contexts.list.len == 0);

    const index: Size = 0;
    b.contexts.top = .{
        .index = index,
        .parentable = true,
        .num_nones = 0,
    };
    b.parentables.top = .{ .index = index };
    return (try b.newStackingContext(index, 0, box_tree, ref)).?;
}

pub fn push(b: *Builder, allocator: Allocator, ty: Type, box_tree: *BoxTree, ref: BlockRef) !?Id {
    assert(b.contexts.top != null);
    assert(b.parentables.top != null);

    const z_index = switch (ty) {
        .none => {
            b.contexts.top.?.num_nones += 1;
            return null;
        },
        .parentable, .non_parentable => |z_index| z_index,
    };

    const sct = box_tree.stacking_contexts.view();
    const parent_index = b.parentables.top.?.index;
    const index: Size = blk: {
        const skips = sct.items(.skip);
        const z_indeces = sct.items(.z_index);

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
            sct.items(.skip)[parent_index] += 1;
            break :blk false;
        },
    };
    try b.contexts.push(allocator, .{
        .index = index,
        .parentable = parentable,
        .num_nones = 0,
    });
    return b.newStackingContext(index, z_index, box_tree, ref);
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
    index: Size,
    z_index: ZIndex,
    box_tree: *BoxTree,
    ref: BlockRef,
) !?Id {
    const id: Id = @enumFromInt(b.next_id);
    try box_tree.stacking_contexts.list.insert(
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
    b.next_id += 1;
    return id;
}

pub fn popInitial(b: *Builder) void {
    const this = b.contexts.pop();
    _ = b.parentables.pop();
    assert(this.num_nones == 0);
    assert(b.contexts.top == null);
    assert(b.parentables.top == null);
}

pub fn pop(b: *Builder, box_tree: *BoxTree) void {
    assert(b.contexts.top != null);
    assert(b.parentables.top != null);

    const num_nones = &b.contexts.top.?.num_nones;
    if (num_nones.* > 0) {
        num_nones.* -= 1;
        return;
    }

    const this = b.contexts.pop();
    if (this.parentable) {
        assert(this.index == b.parentables.pop().index);
        const skips = box_tree.stacking_contexts.view().items(.skip);
        const parent_index = b.parentables.top.?.index;
        skips[parent_index] += skips[this.index];
    }
}

pub fn setBlock(b: *Builder, id: Id, box_tree: *BoxTree, ref: BlockRef) void {
    const sct = box_tree.stacking_contexts.view();
    const ids = sct.items(.id);
    const index: Size = @intCast(std.mem.indexOfScalar(Id, ids, id).?);
    sct.items(.ref)[index] = ref;
    b.incompletes.remove(id);
}

pub fn addIfc(b: *Builder, box_tree: *BoxTree, ifc_id: IfcId) !void {
    const index = b.contexts.top.?.index;
    const list = &box_tree.stacking_contexts.view().items(.ifcs)[index];
    try list.append(box_tree.allocator, ifc_id);
}
