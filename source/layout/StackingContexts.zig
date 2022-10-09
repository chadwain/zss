const StackingContexts = @This();

const std = @import("std");
const assert = std.debug.assert;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const Allocator = std.mem.Allocator;

const used_values = @import("./used_values.zig");
const StackingContextIndex = used_values.StackingContextIndex;
const ZIndex = used_values.ZIndex;
const BlockBox = used_values.BlockBox;
const BoxTree = used_values.BoxTree;

tag: ArrayListUnmanaged(Tag) = .{},
index: ArrayListUnmanaged(StackingContextIndex) = .{},
current: StackingContextIndex = undefined,
allocator: Allocator,

pub const Tag = enum {
    none,
    is_parent,
    is_non_parent,
};

pub const Data = union(Tag) {
    none: void,
    is_parent: StackingContextIndex,
    is_non_parent: StackingContextIndex,
};

pub fn deinit(sc: *StackingContexts) void {
    sc.tag.deinit(sc.allocator);
    sc.index.deinit(sc.allocator);
}

pub fn createRootStackingContext(box_tree: *BoxTree, block_box: BlockBox, z_index: ZIndex) !StackingContextIndex {
    assert(box_tree.stacking_contexts.size() == 0);
    try box_tree.stacking_contexts.ensureTotalCapacity(box_tree.allocator, 1);
    const result = box_tree.stacking_contexts.createRootAssumeCapacity(.{ .z_index = z_index, .block_box = block_box, .ifcs = .{} });
    return result;
}

pub fn createStackingContext(sc: *StackingContexts, box_tree: *BoxTree, block_box: BlockBox, z_index: ZIndex) !StackingContextIndex {
    try box_tree.stacking_contexts.ensureTotalCapacity(box_tree.allocator, box_tree.stacking_contexts.size() + 1);
    const sc_tree_slice = box_tree.stacking_contexts.multi_list.slice();
    const sc_tree_skips = sc_tree_slice.items(.__skip);
    const sc_tree_z_index = sc_tree_slice.items(.z_index);

    const parent_index = sc.index.items[sc.index.items.len - 1];
    var current = parent_index + 1;
    const end = parent_index + sc_tree_skips[parent_index];
    while (current < end and z_index >= sc_tree_z_index[current]) {
        current += sc_tree_skips[current];
    }

    for (sc.index.items) |index| {
        sc_tree_skips[index] += 1;
    }

    box_tree.stacking_contexts.multi_list.insertAssumeCapacity(current, .{ .__skip = 1, .z_index = z_index, .block_box = block_box, .ifcs = .{} });
    return current;
}

pub fn pushStackingContext(sc: *StackingContexts, data: Data) !void {
    try sc.tag.append(sc.allocator, @as(Tag, data));
    switch (data) {
        .none => {},
        .is_parent => |sc_index| {
            sc.current = sc_index;
            try sc.index.append(sc.allocator, sc_index);
        },
        .is_non_parent => |sc_index| {
            sc.current = sc_index;
        },
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
