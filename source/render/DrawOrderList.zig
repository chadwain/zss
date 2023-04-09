const DrawOrderList = @This();

const zss = @import("../../zss.zig");
const used_values = zss.used_values;
const ZssUnit = used_values.ZssUnit;
const ZssVector = used_values.ZssVector;
const ZssRect = used_values.ZssRect;
const BoxOffsets = used_values.BoxOffsets;
const BlockBoxIndex = used_values.BlockBoxIndex;
const BlockBox = used_values.BlockBox;
const BlockSubtree = used_values.BlockSubtree;
const BlockSubtreeIndex = used_values.SubtreeIndex;
const InlineFormattingContextIndex = used_values.InlineFormattingContextIndex;
const StackingContextIndex = used_values.StackingContextIndex;
const StackingContextTree = used_values.StackingContextTree;
const BoxTree = used_values.BoxTree;
const QuadTree = @import("./QuadTree.zig");

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const AutoHashMapUnmanaged = std.AutoHashMapUnmanaged;
const MultiArrayList = std.MultiArrayList;

pub const SubList = struct {
    entries: ArrayListUnmanaged(Entry) = .{},
    index_of_first_child: usize = undefined,
    flattened_index_of_root: usize = undefined,
    flattened_index_of_first_child: usize = undefined,

    pub const Index = u32;

    pub const Entry = union(enum) {
        block_box: BlockBox,
        line_box: LineBox,
        sub_list: Index,

        pub const LineBox = struct {
            ifc_index: InlineFormattingContextIndex,
            line_box_index: usize,
        };

        pub fn format(entry: Entry, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
            _ = fmt;
            _ = options;

            switch (entry) {
                .block_box => |block_box| try writer.print("BlockBox subtree={} index={}", .{ block_box.subtree, block_box.index }),
                .line_box => |line_box| try writer.print("LineBox ifc={} index={}", .{ line_box.ifc_index, line_box.line_box_index }),
                .sub_list => |sub_list_index| try writer.print("SubList index={}", .{sub_list_index}),
            }
        }
    };

    fn addEntry(sub_list: *SubList, allocator: Allocator, entry: Entry, flattened_len: *usize) !void {
        switch (entry) {
            .sub_list => {},
            .block_box, .line_box => flattened_len.* += 1,
        }
        try sub_list.entries.append(allocator, entry);
    }
};

sub_lists: ArrayListUnmanaged(SubList),
quad_tree: QuadTree,

const SubListDescription = struct { index: SubList.Index, stacking_context: StackingContextIndex, vector: ZssVector };

pub fn deinit(list: *DrawOrderList, allocator: Allocator) void {
    for (list.sub_lists.items) |*sub_list| {
        sub_list.entries.deinit(allocator);
    }
    list.sub_lists.deinit(allocator);
    list.quad_tree.deinit(allocator);
}

pub fn create(box_tree: BoxTree, allocator: Allocator) !DrawOrderList {
    var draw_order_list = DrawOrderList{ .sub_lists = .{}, .quad_tree = .{} };
    errdefer draw_order_list.deinit(allocator);

    const first_sub_list = try allocateSubList(&draw_order_list, allocator);
    var flattened_len: usize = 0;

    // Add the initial containing block to the draw order list
    assert(box_tree.blocks.subtrees.items.len > 0);
    assert(box_tree.blocks.subtrees.items[0].skip.items.len > 0);
    const initial_containing_block = BlockBox{ .subtree = 0, .index = 0 };
    const subtree = box_tree.blocks.subtrees.items[initial_containing_block.subtree];
    const box_offsets = subtree.box_offsets.items[initial_containing_block.index];
    const insets = subtree.insets.items[initial_containing_block.index];
    const border_top_left = insets.add(box_offsets.border_pos);
    const content_top_left = border_top_left.add(box_offsets.content_pos);

    try draw_order_list.quad_tree.insert(
        allocator,
        calcBoundingBox(border_top_left, box_offsets),
        .{ .sub_list_index = first_sub_list, .entry_index = draw_order_list.sub_lists.items[first_sub_list].entries.items.len },
    );
    try draw_order_list.sub_lists.items[first_sub_list].addEntry(allocator, SubList.Entry{ .block_box = initial_containing_block }, &flattened_len);

    const slice = box_tree.stacking_contexts.list.slice();
    if (slice.len > 0) {
        // Add the root block's stacking context to the draw order list
        const index = try allocateSubList(&draw_order_list, allocator);
        const desc = SubListDescription{ .index = index, .stacking_context = 0, .vector = content_top_left };
        try draw_order_list.sub_lists.items[first_sub_list].addEntry(allocator, .{ .sub_list = index }, &flattened_len);
        const sub_list_flattened_len = try createSubListForStackingContext(&draw_order_list, desc, 1, allocator, box_tree, slice);
        flattened_len += sub_list_flattened_len;
    }

    draw_order_list.sub_lists.items[first_sub_list].index_of_first_child = draw_order_list.sub_lists.items[first_sub_list].entries.items.len;
    draw_order_list.sub_lists.items[first_sub_list].flattened_index_of_root = 0;
    draw_order_list.sub_lists.items[first_sub_list].flattened_index_of_first_child = flattened_len;

    return draw_order_list;
}

fn allocateSubList(draw_order_list: *DrawOrderList, allocator: Allocator) !SubList.Index {
    const index = std.math.cast(SubList.Index, draw_order_list.sub_lists.items.len) orelse return error.Overflow;
    try draw_order_list.sub_lists.append(allocator, .{});
    return index;
}

fn createSubListForStackingContext(
    draw_order_list: *DrawOrderList,
    desc: SubListDescription,
    flattened_index_of_root: usize,
    allocator: Allocator,
    box_tree: BoxTree,
    sc_tree_slice: StackingContextTree.List.Slice,
) error{ OutOfMemory, Overflow }!usize {
    draw_order_list.sub_lists.items[desc.index].flattened_index_of_root = flattened_index_of_root;
    var own_flattened_len: usize = 0;

    const sc_root_block = sc_tree_slice.items(.block_box)[desc.stacking_context];
    const sc_root_block_subtree = box_tree.blocks.subtrees.items[sc_root_block.subtree];

    const sc_root_box_offsets = sc_root_block_subtree.box_offsets.items[sc_root_block.index];
    const sc_root_insets = sc_root_block_subtree.insets.items[sc_root_block.index];
    const sc_root_border_top_left = desc.vector.add(sc_root_insets).add(sc_root_box_offsets.border_pos);
    const sc_root_content_top_left = sc_root_border_top_left.add(sc_root_box_offsets.content_pos);

    // Add the root block to the draw order list
    try draw_order_list.quad_tree.insert(
        allocator,
        calcBoundingBox(sc_root_border_top_left, sc_root_box_offsets),
        .{ .sub_list_index = desc.index, .entry_index = draw_order_list.sub_lists.items[desc.index].entries.items.len },
    );
    try draw_order_list.sub_lists.items[desc.index].addEntry(allocator, SubList.Entry{ .block_box = sc_root_block }, &own_flattened_len);

    const compareStackingContextIndex = struct {
        fn f(ctx: void, lhs: StackingContextIndex, rhs: StackingContextIndex) std.math.Order {
            _ = ctx;
            return std.math.order(lhs, rhs);
        }
    }.f;

    var list_of_sub_lists_to_create = MultiArrayList(SubListDescription){};
    defer list_of_sub_lists_to_create.deinit(allocator);
    var start_of_higher_stacking_contexts: usize = undefined;

    {
        // Allocate sub-lists for lower stacking contexts, and add them to the draw order list
        var child_sc_index = desc.stacking_context + 1;
        const end = desc.stacking_context + sc_tree_slice.items(.__skip)[desc.stacking_context];
        while (child_sc_index < end and sc_tree_slice.items(.z_index)[child_sc_index] < 0) : (child_sc_index += sc_tree_slice.items(.__skip)[child_sc_index]) {
            const index = try allocateSubList(draw_order_list, allocator);
            try draw_order_list.sub_lists.items[desc.index].addEntry(allocator, SubList.Entry{ .sub_list = index }, &own_flattened_len);
            try list_of_sub_lists_to_create.append(allocator, .{ .index = index, .stacking_context = child_sc_index, .vector = undefined });
        }

        start_of_higher_stacking_contexts = list_of_sub_lists_to_create.len;

        // Allocate sub-lists for higher stacking contexts
        while (child_sc_index < end) : (child_sc_index += sc_tree_slice.items(.__skip)[child_sc_index]) {
            const index = try allocateSubList(draw_order_list, allocator);
            try list_of_sub_lists_to_create.append(allocator, .{ .index = index, .stacking_context = child_sc_index, .vector = undefined });
        }
    }

    {
        var ifc_infos = AutoHashMapUnmanaged(InlineFormattingContextIndex, struct { vector: ZssVector, containing_block_width: ZssUnit }){};
        defer ifc_infos.deinit(allocator);

        const sub_list_ptr = &draw_order_list.sub_lists.items[desc.index];

        sub_list_ptr.index_of_first_child = sub_list_ptr.entries.items.len;

        var stack = ArrayListUnmanaged(struct {
            begin: BlockBoxIndex,
            end: BlockBoxIndex,
            subtree_index: BlockSubtreeIndex,
            subtree: *const BlockSubtree,
            vector: ZssVector,
        }){};
        defer stack.deinit(allocator);
        try stack.append(allocator, .{
            .begin = sc_root_block.index + 1,
            .end = sc_root_block.index + sc_root_block_subtree.skip.items[sc_root_block.index],
            .subtree_index = sc_root_block.subtree,
            .subtree = sc_root_block_subtree,
            .vector = sc_root_content_top_left,
        });

        // Add child block boxes to the draw order list
        outerLoop: while (stack.items.len > 0) {
            const last = &stack.items[stack.items.len - 1];
            const subtree_index = last.subtree_index;
            const subtree = last.subtree;
            const vector = last.vector;
            while (last.begin < last.end) {
                const block_index = last.begin;
                const block_skip = subtree.skip.items[block_index];
                const block_type = subtree.type.items[block_index];
                switch (block_type) {
                    .block => |block_info| {
                        if (block_info.stacking_context) |child_sc_ref| {
                            const child_sc_index = StackingContextTree.refToIndex(sc_tree_slice, child_sc_ref);
                            const list_index = std.sort.binarySearch(
                                StackingContextIndex,
                                child_sc_index,
                                list_of_sub_lists_to_create.items(.stacking_context),
                                {},
                                compareStackingContextIndex,
                            ) orelse unreachable;
                            list_of_sub_lists_to_create.items(.vector)[list_index] = vector;

                            last.begin += block_skip;
                        } else {
                            const box_offsets = subtree.box_offsets.items[block_index];
                            const insets = subtree.insets.items[block_index];
                            const border_top_left = vector.add(insets).add(box_offsets.border_pos);
                            const content_top_left = border_top_left.add(box_offsets.content_pos);

                            try draw_order_list.quad_tree.insert(
                                allocator,
                                calcBoundingBox(border_top_left, box_offsets),
                                .{ .sub_list_index = desc.index, .entry_index = sub_list_ptr.entries.items.len },
                            );

                            try sub_list_ptr.addEntry(
                                allocator,
                                SubList.Entry{ .block_box = .{ .subtree = subtree_index, .index = block_index } },
                                &own_flattened_len,
                            );

                            last.begin += block_skip;
                            if (block_skip != 1) {
                                try stack.append(allocator, .{
                                    .begin = block_index + 1,
                                    .end = block_index + subtree.skip.items[block_index],
                                    .subtree_index = subtree_index,
                                    .subtree = subtree,
                                    .vector = content_top_left,
                                });
                                continue :outerLoop;
                            }
                        }
                    },
                    .ifc_container => |ifc_index| {
                        const box_offsets = subtree.box_offsets.items[block_index];
                        const new_vector = vector.add(box_offsets.border_pos).add(box_offsets.content_pos);
                        try ifc_infos.putNoClobber(allocator, ifc_index, .{ .vector = new_vector, .containing_block_width = box_offsets.border_size.w });
                        last.begin += 1;
                        last.vector = new_vector;
                    },
                    .subtree_proxy => |proxy_subtree_index| {
                        last.begin += block_skip;
                        const child_subtree = box_tree.blocks.subtrees.items[proxy_subtree_index];
                        try stack.append(allocator, .{
                            .begin = 0,
                            .end = @intCast(BlockBoxIndex, child_subtree.skip.items.len),
                            .subtree_index = proxy_subtree_index,
                            .subtree = child_subtree,
                            .vector = vector,
                        });
                        continue :outerLoop;
                    },
                }
            } else {
                _ = stack.pop();
            }
        }

        // Add inline formatting context line boxes to the draw order list
        for (sc_tree_slice.items(.ifcs)[desc.stacking_context].items) |ifc_index| {
            const info = ifc_infos.get(ifc_index) orelse unreachable;
            const ifc = box_tree.ifcs.items[ifc_index];
            const line_box_height = ifc.ascender - ifc.descender;
            for (ifc.line_boxes.items) |line_box, line_box_index| {
                const bounding_box = ZssRect{
                    .x = info.vector.x,
                    .y = info.vector.y + line_box.baseline - ifc.ascender,
                    .w = info.containing_block_width,
                    .h = line_box_height,
                };
                try draw_order_list.quad_tree.insert(
                    allocator,
                    bounding_box,
                    .{ .sub_list_index = desc.index, .entry_index = sub_list_ptr.entries.items.len },
                );
                try sub_list_ptr.addEntry(
                    allocator,
                    SubList.Entry{ .line_box = .{ .ifc_index = ifc_index, .line_box_index = line_box_index } },
                    &own_flattened_len,
                );
            }
        }
    }

    var sub_list_flattened_index_of_root = flattened_index_of_root + 1;
    var i: usize = 0;

    // Create sub-lists for lower stacking contexts
    while (i < start_of_higher_stacking_contexts) : (i += 1) {
        const sub_list_desc = list_of_sub_lists_to_create.get(i);
        const sub_list_flattened_len = try createSubListForStackingContext(
            draw_order_list,
            sub_list_desc,
            sub_list_flattened_index_of_root,
            allocator,
            box_tree,
            sc_tree_slice,
        );
        sub_list_flattened_index_of_root += sub_list_flattened_len;
    }

    draw_order_list.sub_lists.items[desc.index].flattened_index_of_first_child = sub_list_flattened_index_of_root;
    sub_list_flattened_index_of_root += own_flattened_len - 1;

    // Create sub-lists for higher stacking contexts, and add them to the draw order list
    while (i < list_of_sub_lists_to_create.len) : (i += 1) {
        const sub_list_desc = list_of_sub_lists_to_create.get(i);
        try draw_order_list.sub_lists.items[desc.index].addEntry(allocator, SubList.Entry{ .sub_list = sub_list_desc.index }, &own_flattened_len);
        const sub_list_flattened_len = try createSubListForStackingContext(
            draw_order_list,
            sub_list_desc,
            sub_list_flattened_index_of_root,
            allocator,
            box_tree,
            sc_tree_slice,
        );
        sub_list_flattened_index_of_root += sub_list_flattened_len;
    }

    return sub_list_flattened_index_of_root - flattened_index_of_root;
}

fn calcBoundingBox(border_top_left: ZssVector, box_offsets: BoxOffsets) ZssRect {
    return ZssRect{
        .x = border_top_left.x,
        .y = border_top_left.y,
        .w = box_offsets.border_size.w,
        .h = box_offsets.border_size.h,
    };
}

pub fn print(list: DrawOrderList, writer: anytype, allocator: Allocator) !void {
    const printSubListDetailed = struct {
        fn f(l: DrawOrderList, entry: SubList.Entry, w: anytype) !void {
            const sub_list = l.sub_lists.items[entry.sub_list];
            try w.print("{} index_of_first_child={} flattened_index_of_root={} flattened_index_of_first_child={}\n", .{
                entry,
                sub_list.index_of_first_child,
                sub_list.flattened_index_of_root,
                sub_list.flattened_index_of_first_child,
            });
        }
    }.f;

    var stack = ArrayListUnmanaged(struct { sub_list: *const SubList, index: usize = 0 }){};
    defer stack.deinit(allocator);
    try stack.append(allocator, .{ .sub_list = &list.sub_lists.items[0] });
    try printSubListDetailed(list, SubList.Entry{ .sub_list = 0 }, writer);

    outerLoop: while (stack.items.len > 0) {
        const indent = stack.items.len;
        const last = &stack.items[stack.items.len - 1];
        while (last.index < last.sub_list.entries.items.len) {
            const sub_list = last.sub_list;
            const index = last.index;
            const entry = sub_list.entries.items[index];
            last.index += 1;
            try writer.writeByteNTimes(' ', indent * 4);
            switch (entry) {
                .sub_list => {
                    try printSubListDetailed(list, entry, writer);
                    try stack.append(allocator, .{ .sub_list = &list.sub_lists.items[entry.sub_list] });
                    continue :outerLoop;
                },
                .block_box, .line_box => try writer.print("{}\n", .{entry}),
            }
        } else {
            _ = stack.pop();
        }
    }
}

pub fn printQuadTreeObject(list: DrawOrderList, object: QuadTree.Object, writer: anytype) !void {
    const entry = list.sub_lists.items[object.sub_list_index].entries.items[object.entry_index];
    try writer.print("{}", .{entry});
}

pub fn getFlattenedIndex(draw_order_list: DrawOrderList, object: QuadTree.Object) usize {
    const sub_list = draw_order_list.sub_lists.items[object.sub_list_index];
    const entry = sub_list.entries.items[object.entry_index];
    switch (entry) {
        .block_box, .line_box => {},
        .sub_list => unreachable,
    }
    if (object.entry_index == 0) {
        return sub_list.flattened_index_of_root;
    } else {
        return sub_list.flattened_index_of_first_child + (object.entry_index - sub_list.index_of_first_child);
    }
}
