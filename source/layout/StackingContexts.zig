const StackingContexts = @This();

const std = @import("std");
const assert = std.debug.assert;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const Allocator = std.mem.Allocator;

const zss = @import("../zss.zig");
const used_values = zss.used_values;
const BlockBox = used_values.BlockBox;
const BoxTree = used_values.BoxTree;
const StackingContextIndex = used_values.StackingContextIndex;
const StackingContextRef = used_values.StackingContextRef;
const ZIndex = used_values.ZIndex;

tag: ArrayListUnmanaged(Tag) = .{},
index: ArrayListUnmanaged(StackingContextIndex) = .{},
ref: ArrayListUnmanaged(StackingContextRef) = .{},
current_index: StackingContextIndex = undefined,
allocator: Allocator,

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
    is_parent: IndexAndRef,
    is_non_parent: IndexAndRef,
};

pub const IndexAndRef = struct {
    index: StackingContextIndex,
    ref: StackingContextRef,
};

pub fn deinit(sc: *StackingContexts) void {
    sc.tag.deinit(sc.allocator);
    sc.index.deinit(sc.allocator);
    sc.ref.deinit(sc.allocator);
}

pub fn createRootStackingContext(box_tree: *BoxTree, block_box: BlockBox) !Info {
    assert(box_tree.stacking_contexts.size() == 0);
    try box_tree.stacking_contexts.ensureTotalCapacity(box_tree.allocator, 1);
    const ref = box_tree.stacking_contexts.createRootAssumeCapacity(.{ .z_index = 0, .block_box = block_box, .ifcs = .{} });
    return .{ .is_parent = .{ .index = 0, .ref = ref } };
}

pub fn createStackingContext(sc: *StackingContexts, comptime tag: Tag, box_tree: *BoxTree, block_box: BlockBox, z_index: ZIndex) !Info {
    switch (tag) {
        .none => @compileError("nope"),
        .is_parent, .is_non_parent => {
            const index_and_ref = try createStackingContextImpl(sc, box_tree, block_box, z_index);
            return @unionInit(Info, @tagName(tag), index_and_ref);
        },
    }
}

fn createStackingContextImpl(sc: *StackingContexts, box_tree: *BoxTree, block_box: BlockBox, z_index: ZIndex) !IndexAndRef {
    const sc_tree = &box_tree.stacking_contexts;
    try sc_tree.ensureTotalCapacity(box_tree.allocator, sc_tree.size() + 1);
    const tree_slice = sc_tree.list.slice();
    const tree_skips = tree_slice.items(.__skip);
    const tree_z_index = tree_slice.items(.z_index);

    const parent_index = sc.index.items[sc.index.items.len - 1];
    var current = parent_index + 1;
    const end = parent_index + tree_skips[parent_index];
    while (current < end and z_index >= tree_z_index[current]) {
        current += tree_skips[current];
    }

    for (sc.index.items) |index| {
        tree_skips[index] += 1;
    }

    const ref = sc_tree.next_ref;
    sc_tree.list.insertAssumeCapacity(current, .{ .__skip = 1, .__ref = ref, .z_index = z_index, .block_box = block_box, .ifcs = .{} });
    sc_tree.next_ref += 1;
    return .{ .index = current, .ref = ref };
}

pub fn pushStackingContext(sc: *StackingContexts, info: Info) !void {
    try sc.tag.append(sc.allocator, info);
    switch (info) {
        .none => {},
        .is_parent => |i| {
            sc.current_index = i.index;
            try sc.index.append(sc.allocator, i.index);
            try sc.ref.append(sc.allocator, i.ref);
        },
        .is_non_parent => |i| sc.current_index = i.index,
    }
}

pub fn popStackingContext(sc: *StackingContexts) void {
    const tag = sc.tag.pop();
    switch (tag) {
        .none => {},
        .is_parent => {
            _ = sc.index.pop();
            _ = sc.ref.pop();
            if (sc.tag.items.len > 0) {
                sc.current_index = sc.index.items[sc.index.items.len - 1];
            } else {
                sc.current_index = undefined;
            }
        },
        .is_non_parent => {
            sc.current_index = sc.index.items[sc.index.items.len - 1];
        },
    }
}

pub fn fixupStackingContextRef(box_tree: *BoxTree, ref: StackingContextRef, block_box: BlockBox) void {
    const tree = &box_tree.stacking_contexts;
    const refs = tree.list.items(.__ref);
    const index = @as(StackingContextIndex, @intCast(std.mem.indexOfScalar(StackingContextRef, refs, ref).?));
    const block_boxes = tree.list.items(.block_box);
    block_boxes[index] = block_box;
}
