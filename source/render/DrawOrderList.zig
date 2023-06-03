const DrawOrderList = @This();

const zss = @import("../../zss.zig");
const used_values = zss.used_values;
const ZssUnit = used_values.ZssUnit;
const ZssVector = used_values.ZssVector;
const ZssRect = used_values.ZssRect;
const BoxOffsets = used_values.BoxOffsets;
const BlockBoxIndex = used_values.BlockBoxIndex;
const BlockBox = used_values.BlockBox;
const initial_containing_block = used_values.initial_containing_block;
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

const Builder = struct {
    pending_sub_lists: AutoHashMapUnmanaged(StackingContextIndex, SubList.Index) = .{},
    ready_sub_lists: ArrayListUnmanaged(Description) = .{},

    fn deinit(builder: *Builder, allocator: Allocator) void {
        builder.pending_sub_lists.deinit(allocator);
        builder.ready_sub_lists.deinit(allocator);
    }

    fn makeSublistReady(builder: *Builder, allocator: Allocator, stacking_context: StackingContextIndex, initial_vector: ZssVector) !void {
        const sublist_index = (builder.pending_sub_lists.fetchRemove(stacking_context) orelse unreachable).value;
        try builder.ready_sub_lists.append(allocator, Description{
            .index = sublist_index,
            .initial_vector = initial_vector,
            .stacking_context = stacking_context,
        });
    }
};

pub const DrawIndex = u32;

pub const SubList = struct {
    entries: ArrayListUnmanaged(Entry) = .{},
    before_and_after: ArrayListUnmanaged(SubList.Index) = .{},
    midpoint: Size = undefined,
    root_draw_index: DrawIndex = undefined,
    first_child_draw_index: DrawIndex = undefined,

    pub const Index = u32;
    const Size = u32;

    pub const Entry = union(enum) {
        block: Block,
        line_box: LineBox,

        pub const Block = struct {
            block_box: BlockBox,
            border_top_left: ZssVector,
        };

        pub const LineBox = struct {
            ifc_index: InlineFormattingContextIndex,
            line_box_index: usize,
            origin: ZssVector,
        };

        pub fn format(entry: Entry, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
            _ = fmt;
            _ = options;

            switch (entry) {
                .block => |block| try writer.print("BlockBox subtree={} index={}", .{ block.block_box.subtree, block.block_box.index }),
                .line_box => |line_box| try writer.print("LineBox ifc={} index={}", .{ line_box.ifc_index, line_box.line_box_index }),
            }
        }
    };

    fn addEntry(sub_list: *SubList, allocator: Allocator, entry: Entry) !void {
        try sub_list.entries.append(allocator, entry);
    }

    fn setMidpoint(sub_list: *SubList) void {
        sub_list.midpoint = @intCast(Size, sub_list.before_and_after.items.len);
    }
};

sub_lists: ArrayListUnmanaged(SubList),
quad_tree: QuadTree,

const Description = struct { index: SubList.Index, initial_vector: ZssVector, stacking_context: StackingContextIndex };

pub fn deinit(list: *DrawOrderList, allocator: Allocator) void {
    for (list.sub_lists.items) |*sub_list| {
        sub_list.entries.deinit(allocator);
        sub_list.before_and_after.deinit(allocator);
    }
    list.sub_lists.deinit(allocator);
    list.quad_tree.deinit(allocator);
}

pub fn create(box_tree: BoxTree, allocator: Allocator) !DrawOrderList {
    var draw_order_list = DrawOrderList{ .sub_lists = .{}, .quad_tree = .{} };
    errdefer draw_order_list.deinit(allocator);

    var builder = Builder{};
    defer builder.deinit(allocator);

    const first_sub_list: SubList.Index = 0;
    try draw_order_list.sub_lists.append(allocator, .{});

    const subtree = box_tree.blocks.subtrees.items[initial_containing_block.subtree];
    const box_offsets = subtree.box_offsets.items[initial_containing_block.index];
    const insets = subtree.insets.items[initial_containing_block.index];
    const border_top_left = insets.add(box_offsets.border_pos);
    const content_top_left = border_top_left.add(box_offsets.content_pos);

    {
        const data = draw_order_list.get(first_sub_list);
        data.setMidpoint();

        // Add the initial containing block to the draw order list
        const entry_index = std.math.cast(SubList.Size, data.entries.items.len) orelse return error.Overflow;
        try draw_order_list.quad_tree.insert(
            allocator,
            calcBoundingBox(border_top_left, box_offsets),
            .{
                .sub_list_index = first_sub_list,
                .entry_index = entry_index,
            },
        );
        try data.addEntry(
            allocator,
            SubList.Entry{
                .block = .{
                    .block_box = initial_containing_block,
                    .border_top_left = border_top_left,
                },
            },
        );
    }

    const slice = box_tree.stacking_contexts.list.slice();
    if (slice.len > 0) {
        // Add the root stacking context to the draw order list
        try allocateSubList(&builder, &draw_order_list, allocator, first_sub_list, 0);
        try builder.makeSublistReady(allocator, 0, content_top_left);
    }

    while (builder.ready_sub_lists.items.len > 0) {
        const description = builder.ready_sub_lists.pop();
        try createSubListForStackingContext(&draw_order_list, &builder, description, allocator, box_tree, slice);
    }

    const StackItem = struct {
        data: *SubList,
        child_index: SubList.Size = 0,
        state: enum { before, midpoint, after } = .before,
    };
    var stack = ArrayListUnmanaged(StackItem){};
    defer stack.deinit(allocator);
    try stack.append(allocator, .{ .data = draw_order_list.get(first_sub_list) });
    stack.items[0].data.root_draw_index = 0;

    var draw_index: DrawIndex = 1;
    while (stack.items.len > 0) {
        const item = &stack.items[stack.items.len - 1];
        const data = item.data;
        switch (item.state) {
            .before => {
                if (item.child_index == data.midpoint) {
                    item.state = .midpoint;
                    continue;
                }
            },
            .midpoint => {
                data.first_child_draw_index = draw_index;
                draw_index += @intCast(DrawIndex, data.entries.items.len - 1);
                item.state = .after;
                continue;
            },
            .after => {
                if (item.child_index == data.before_and_after.items.len) {
                    _ = stack.pop();
                    continue;
                }
            },
        }

        const child_sub_list = data.before_and_after.items[item.child_index];
        item.child_index += 1;
        const child_data = draw_order_list.get(child_sub_list);
        child_data.root_draw_index = draw_index;
        draw_index += 1;
        try stack.append(allocator, .{ .data = child_data });
    }

    return draw_order_list;
}

fn allocateSubList(
    builder: *Builder,
    draw_order_list: *DrawOrderList,
    allocator: Allocator,
    parent: SubList.Index,
    stacking_context: StackingContextIndex,
) !void {
    const index = std.math.cast(SubList.Index, draw_order_list.sub_lists.items.len) orelse return error.Overflow;
    try draw_order_list.sub_lists.append(allocator, .{});
    try builder.pending_sub_lists.put(allocator, stacking_context, index);

    const parent_data = draw_order_list.get(parent);
    try parent_data.before_and_after.append(allocator, index);
}

fn get(draw_order_list: *DrawOrderList, index: SubList.Index) *SubList {
    return &draw_order_list.sub_lists.items[index];
}

fn createSubListForStackingContext(
    draw_order_list: *DrawOrderList,
    builder: *Builder,
    desc: Description,
    allocator: Allocator,
    box_tree: BoxTree,
    slice: StackingContextTree.List.Slice,
) !void {
    const stacking_context = desc.stacking_context;
    const root_block_box = slice.items(.block_box)[stacking_context];
    const root_block_subtree = box_tree.blocks.subtrees.items[root_block_box.subtree];
    const root_box_offsets = root_block_subtree.box_offsets.items[root_block_box.index];
    const root_insets = root_block_subtree.insets.items[root_block_box.index];
    const root_border_top_left = desc.initial_vector.add(root_insets).add(root_box_offsets.border_pos);
    const root_content_top_left = root_border_top_left.add(root_box_offsets.content_pos);

    {
        // Allocate sub-lists for child stacking contexts
        const skips = slice.items(.__skip);
        const z_indeces = slice.items(.z_index);
        var child_stacking_context = stacking_context + 1;
        const end = stacking_context + skips[stacking_context];
        while (child_stacking_context < end and z_indeces[child_stacking_context] < 0) : (child_stacking_context += skips[child_stacking_context]) {
            try allocateSubList(builder, draw_order_list, allocator, desc.index, child_stacking_context);
        }

        draw_order_list.get(desc.index).setMidpoint();

        while (child_stacking_context < end) : (child_stacking_context += skips[child_stacking_context]) {
            try allocateSubList(builder, draw_order_list, allocator, desc.index, child_stacking_context);
        }
    }

    {
        var ifc_infos = AutoHashMapUnmanaged(InlineFormattingContextIndex, struct { vector: ZssVector, containing_block_width: ZssUnit }){};
        defer ifc_infos.deinit(allocator);

        const data = draw_order_list.get(desc.index);

        // Add the root block to the draw order list
        try draw_order_list.quad_tree.insert(
            allocator,
            calcBoundingBox(root_border_top_left, root_box_offsets),
            .{ .sub_list_index = desc.index, .entry_index = 0 },
        );
        try data.addEntry(
            allocator,
            SubList.Entry{
                .block = .{
                    .block_box = root_block_box,
                    .border_top_left = root_border_top_left,
                },
            },
        );

        var stack = ArrayListUnmanaged(struct {
            begin: BlockBoxIndex,
            end: BlockBoxIndex,
            subtree_index: BlockSubtreeIndex,
            subtree: *const BlockSubtree,
            vector: ZssVector,
        }){};
        defer stack.deinit(allocator);
        try stack.append(allocator, .{
            .begin = root_block_box.index + 1,
            .end = root_block_box.index + root_block_subtree.skip.items[root_block_box.index],
            .subtree_index = root_block_box.subtree,
            .subtree = root_block_subtree,
            .vector = root_content_top_left,
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
                        if (block_info.stacking_context) |child_stacking_context_ref| {
                            const child_stacking_context = StackingContextTree.refToIndex(slice, child_stacking_context_ref);
                            try builder.makeSublistReady(allocator, child_stacking_context, vector);

                            last.begin += block_skip;
                        } else {
                            const box_offsets = subtree.box_offsets.items[block_index];
                            const insets = subtree.insets.items[block_index];
                            const border_top_left = vector.add(insets).add(box_offsets.border_pos);
                            const content_top_left = border_top_left.add(box_offsets.content_pos);

                            const entry_index = std.math.cast(SubList.Size, data.entries.items.len) orelse return error.Overflow;
                            try draw_order_list.quad_tree.insert(
                                allocator,
                                calcBoundingBox(border_top_left, box_offsets),
                                .{ .sub_list_index = desc.index, .entry_index = entry_index },
                            );

                            try data.addEntry(
                                allocator,
                                SubList.Entry{
                                    .block = .{
                                        .block_box = .{ .subtree = subtree_index, .index = block_index },
                                        .border_top_left = border_top_left,
                                    },
                                },
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
        for (slice.items(.ifcs)[stacking_context].items) |ifc_index| {
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
                const entry_index = std.math.cast(SubList.Size, data.entries.items.len) orelse return error.Overflow;
                try draw_order_list.quad_tree.insert(
                    allocator,
                    bounding_box,
                    .{ .sub_list_index = desc.index, .entry_index = entry_index },
                );
                try data.addEntry(
                    allocator,
                    SubList.Entry{
                        .line_box = .{
                            .ifc_index = ifc_index,
                            .line_box_index = line_box_index,
                            .origin = info.vector,
                        },
                    },
                );
            }
        }
    }
}

fn calcBoundingBox(border_top_left: ZssVector, box_offsets: BoxOffsets) ZssRect {
    return ZssRect{
        .x = border_top_left.x,
        .y = border_top_left.y,
        .w = box_offsets.border_size.w,
        .h = box_offsets.border_size.h,
    };
}

pub fn print(draw_order_list: DrawOrderList, writer: anytype, allocator: Allocator) !void {
    var stack = ArrayListUnmanaged(struct {
        sub_list: *const SubList,
        child_index: SubList.Size = 0,
        state: enum { root, before, midpoint, after } = .root,
    }){};
    defer stack.deinit(allocator);
    try stack.append(allocator, .{ .sub_list = &draw_order_list.sub_lists.items[0] });

    while (stack.items.len > 0) {
        const indent = stack.items.len - 1;
        const item = &stack.items[stack.items.len - 1];
        const sub_list = item.sub_list;

        switch (item.state) {
            .root => {
                const entry = sub_list.entries.items[0];
                try writer.writeByteNTimes(' ', indent * 4);
                try writer.print("{}\n", .{entry});
                item.state = .before;
            },
            .before => {
                if (item.child_index == sub_list.midpoint) {
                    item.state = .midpoint;
                    continue;
                }
                const child_sub_list = sub_list.before_and_after.items[item.child_index];
                item.child_index += 1;
                try writer.writeByteNTimes(' ', indent * 4);
                try writer.print("SubList index={}\n", .{child_sub_list});
                try stack.append(allocator, .{ .sub_list = &draw_order_list.sub_lists.items[child_sub_list] });
            },
            .midpoint => {
                for (sub_list.entries.items[1..]) |entry| {
                    try writer.writeByteNTimes(' ', indent * 4);
                    try writer.print("{}\n", .{entry});
                }
                item.state = .after;
            },
            .after => {
                if (item.child_index == sub_list.before_and_after.items.len) {
                    _ = stack.pop();
                    continue;
                }
                const child_sub_list = sub_list.before_and_after.items[item.child_index];
                item.child_index += 1;
                try writer.writeByteNTimes(' ', indent * 4);
                try writer.print("SubList index={}\n", .{child_sub_list});
                try stack.append(allocator, .{ .sub_list = &draw_order_list.sub_lists.items[child_sub_list] });
            },
        }
    }
}

pub fn printQuadTreeObject(list: DrawOrderList, object: QuadTree.Object, writer: anytype) !void {
    const entry = list.getEntry(object);
    try writer.print("{}", .{entry});
}

pub fn getEntry(draw_order_list: DrawOrderList, object: QuadTree.Object) SubList.Entry {
    return draw_order_list.sub_lists.items[object.sub_list_index].entries.items[object.entry_index];
}

pub fn getFlattenedIndex(draw_order_list: DrawOrderList, object: QuadTree.Object) DrawIndex {
    const sub_list = draw_order_list.sub_lists.items[object.sub_list_index];
    if (object.entry_index == 0) {
        return sub_list.root_draw_index;
    } else {
        return sub_list.first_child_draw_index + object.entry_index - 1;
    }
}
