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
current: StackingContextIndex = undefined,
allocator: Allocator,

pub const Tag = enum {
    none,
    is_parent,
    is_non_parent,

    fn Value(comptime tag: Tag) type {
        return switch (tag) {
            .none => void,
            .is_parent, .is_non_parent => StackingContextIndex,
        };
    }
};

pub const IndexAndRef = struct {
    index: StackingContextIndex,
    ref: StackingContextRef,
};

pub fn deinit(sc: *StackingContexts) void {
    sc.tag.deinit(sc.allocator);
    sc.index.deinit(sc.allocator);
}

pub fn createRootStackingContext(box_tree: *BoxTree, block_box: BlockBox, z_index: ZIndex) !IndexAndRef {
    assert(box_tree.stacking_contexts.size() == 0);
    try box_tree.stacking_contexts.ensureTotalCapacity(box_tree.allocator, 1);
    const ref = box_tree.stacking_contexts.createRootAssumeCapacity(.{ .z_index = z_index, .block_box = block_box, .ifcs = .{} });
    return IndexAndRef{ .index = 0, .ref = ref };
}

pub fn createStackingContext(sc: *StackingContexts, box_tree: *BoxTree, block_box: BlockBox, z_index: ZIndex) !IndexAndRef {
    const tree = &box_tree.stacking_contexts;
    try tree.ensureTotalCapacity(box_tree.allocator, tree.size() + 1);
    const tree_slice = tree.list.slice();
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

    const ref = tree.next_ref;
    tree.list.insertAssumeCapacity(current, .{ .__skip = 1, .__ref = ref, .z_index = z_index, .block_box = block_box, .ifcs = .{} });
    tree.next_ref += 1;
    return IndexAndRef{ .index = current, .ref = ref };
}

pub fn pushStackingContext(sc: *StackingContexts, comptime tag: Tag, value: tag.Value()) !void {
    try sc.tag.append(sc.allocator, tag);
    switch (tag) {
        .none => {},
        .is_parent => {
            sc.current = value;
            try sc.index.append(sc.allocator, value);
        },
        .is_non_parent => sc.current = value,
    }
}

pub fn popStackingContext(sc: *StackingContexts) void {
    const tag = sc.tag.pop();
    switch (tag) {
        .none => {},
        .is_parent => {
            _ = sc.index.pop();
            if (sc.tag.items.len > 0) {
                sc.current = sc.index.items[sc.index.items.len - 1];
            } else {
                sc.current = undefined;
            }
        },
        .is_non_parent => {
            sc.current = sc.index.items[sc.index.items.len - 1];
        },
    }
}

pub fn fixupStackingContextIndex(box_tree: *BoxTree, index: StackingContextIndex, block_box: BlockBox) void {
    const tree = &box_tree.stacking_contexts;
    const block_boxes = tree.list.items(.block_box);
    block_boxes[index] = block_box;
}

pub fn fixupStackingContextRef(box_tree: *BoxTree, ref: StackingContextRef, block_box: BlockBox) void {
    const tree = &box_tree.stacking_contexts;
    const refs = tree.list.items(.__ref);
    const index = @as(StackingContextIndex, @intCast(std.mem.indexOfScalar(StackingContextRef, refs, ref).?));
    fixupStackingContextIndex(box_tree, index, block_box);
}
