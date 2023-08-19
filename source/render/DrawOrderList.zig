//! In order to draw a document, we need to generate drawable objects from a `BoxTree` (the result of layout).
//! The `DrawOrderList` is, conceptually, a list of all of those drawable objects, in the order they should be drawn.
//! In terms of implementation, the `DrawOrderList` is made up of smaller "sub-lists" (called `SubList`).
//! Each drawable object can be referenced by its position in one of these sub-lists.
//! Each drawable has an associated DrawIndex.
//! The DrawIndex of two drawables can be compared to see which one must be drawn before the other. (Lower value = draw first)

const DrawOrderList = @This();

const zss = @import("../../zss.zig");
const used_values = zss.used_values;
const ZssUnit = used_values.ZssUnit;
const ZssVector = used_values.ZssVector;
const ZssRect = used_values.ZssRect;
const BoxOffsets = used_values.BoxOffsets;
const BlockBoxIndex = used_values.BlockBoxIndex;
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

pub const SubListIndex = u32;
pub const root_sub_list = @as(SubListIndex, 0);

pub const DrawIndex = u32;

/// Represents a drawable object.
pub const Drawable = union(enum) {
    /// The drawable is a block box.
    block_box: BlockBox,
    /// The drawable is a line box of an inline formatting context.
    line_box: LineBox,

    pub const BlockBox = struct {
        block_box: used_values.BlockBox,
        border_top_left: ZssVector,
    };

    pub const LineBox = struct {
        ifc_index: InlineFormattingContextIndex,
        line_box_index: usize,
        origin: ZssVector,
    };

    pub fn format(drawable: Drawable, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;

        switch (drawable) {
            .block_box => |block_box| try writer.print("BlockBox subtree={} index={}", .{ block_box.block_box.subtree, block_box.block_box.index }),
            .line_box => |line_box| try writer.print("LineBox ifc={} index={}", .{ line_box.ifc_index, line_box.line_box_index }),
        }
    }
};

sub_lists: ArrayListUnmanaged(SubList),
quad_tree: QuadTree,

/// A reference to a Drawable.
pub const DrawableRef = struct {
    sub_list: SubListIndex,
    entry_index: SubList.Size,

    pub fn format(ref: DrawableRef, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;

        try writer.print("DrawableRef sub_list={} entry_index={}", .{ ref.sub_list, ref.entry_index });
    }
};

/// A `SubList` represents a small segment of the entire `DrawOrderList`.
/// SubLists reference other SubLists, forming a tree structure.
/// Each SubList is referenced by a `SubListIndex`.
/// There is always at least 1 SubList - referenced by `root_sub_list`.
/// There is also 1 SubList created for every stacking context. (In the future there may be more reasons to create SubLists)
///
/// Because they are designed to represent stacking contexts, a SubList is, conceptually, a list like this:
///     [ root drawable, before1, ..., beforeN, child drawables, after1, ..., afterN ],
/// where,
///     the root drawable is the drawable corresponding to root block box of the stacking context,
///     child drawables are all the drawables in the stacking context except for the root block box, and
///     before1...beforeN and after1...afterN are the child stacking contexts with z-index < 0 and z-index >= 0, respectively.
pub const SubList = struct {
    /// All of the drawables corresponding to this SubList. The root drawable has index 0.
    entries: ArrayListUnmanaged(Drawable) = .{},
    /// Child SubLists of this SubList. This list is split into two halves: "before" and "after".
    before_and_after: ArrayListUnmanaged(SubListIndex) = .{},
    /// An index into `before_and_after` which tells you where the "before" section ends and the "after" section begins.
    midpoint: Size = undefined,
    /// The DrawIndex of the root drawable.
    root_draw_index: DrawIndex = undefined,
    /// The DrawIndex of the first drawable that is not the root drawable.
    first_child_draw_index: DrawIndex = undefined,

    const Size = u32;

    /// Information on a particular SubList.
    const Description = struct {
        index: SubListIndex,
        /// The position of the top left corner of the stacking context.
        initial_vector: ZssVector,
        /// The stacking context that caused the SubList to be created.
        stacking_context: StackingContextIndex,
    };

    /// Returns the entry index.
    fn addEntry(sub_list: *SubList, allocator: Allocator, drawable: Drawable) !Size {
        if (sub_list.entries.items.len == std.math.maxInt(Size)) return error.Overflow;
        try sub_list.entries.append(allocator, drawable);
        return @intCast(sub_list.entries.items.len - 1);
    }

    fn setMidpoint(sub_list: *SubList) void {
        sub_list.midpoint = @intCast(sub_list.before_and_after.items.len);
    }
};

/// Frees resources associated with the DrawOrderList.
pub fn deinit(list: *DrawOrderList, allocator: Allocator) void {
    for (list.sub_lists.items) |*sub_list| {
        sub_list.entries.deinit(allocator);
        sub_list.before_and_after.deinit(allocator);
    }
    list.sub_lists.deinit(allocator);
    list.quad_tree.deinit(allocator);
}

/// Helper struct used while creating the DrawOrderList.
const Builder = struct {
    // A SubList can be in two states:
    //     "pending" - it has been allocated, but lacks the information needed to populate it
    //     "ready" - there is enough information to populate it

    pending_sub_lists: AutoHashMapUnmanaged(StackingContextIndex, SubListIndex) = .{},
    ready_sub_lists: ArrayListUnmanaged(SubList.Description) = .{},

    fn deinit(builder: *Builder, allocator: Allocator) void {
        builder.pending_sub_lists.deinit(allocator);
        builder.ready_sub_lists.deinit(allocator);
    }

    fn makeSublistReady(builder: *Builder, allocator: Allocator, stacking_context: StackingContextIndex, initial_vector: ZssVector) !void {
        const sublist_index = (builder.pending_sub_lists.fetchRemove(stacking_context) orelse unreachable).value;
        try builder.ready_sub_lists.append(allocator, SubList.Description{
            .index = sublist_index,
            .initial_vector = initial_vector,
            .stacking_context = stacking_context,
        });
    }
};

/// Creates a `DrawOrderList` from a `BoxTree`.
pub fn create(box_tree: BoxTree, allocator: Allocator) !DrawOrderList {
    var draw_order_list = DrawOrderList{ .sub_lists = .{}, .quad_tree = .{} };
    errdefer draw_order_list.deinit(allocator);

    {
        var builder = Builder{};
        defer builder.deinit(allocator);

        try draw_order_list.sub_lists.append(allocator, .{});

        const subtree = box_tree.blocks.subtrees.items[initial_containing_block.subtree];
        const box_offsets = subtree.box_offsets.items[initial_containing_block.index];
        const insets = subtree.insets.items[initial_containing_block.index];
        const border_top_left = insets.add(box_offsets.border_pos);
        const content_top_left = border_top_left.add(box_offsets.content_pos);

        {
            const data = draw_order_list.getSubList(root_sub_list);
            data.setMidpoint();

            // Add the initial containing block to the draw order list
            const entry_index = try data.addEntry(
                allocator,
                Drawable{
                    .block_box = .{
                        .block_box = initial_containing_block,
                        .border_top_left = border_top_left,
                    },
                },
            );
            try draw_order_list.quad_tree.insert(
                allocator,
                calcBoundingBox(border_top_left, box_offsets),
                .{
                    .sub_list = root_sub_list,
                    .entry_index = entry_index,
                },
            );
        }

        const slice = box_tree.stacking_contexts.list.slice();
        if (slice.len > 0) {
            // Add the root stacking context to the draw order list
            try allocateSubList(&builder, &draw_order_list, allocator, root_sub_list, 0);
            try builder.makeSublistReady(allocator, 0, content_top_left);
        }

        while (builder.ready_sub_lists.items.len > 0) {
            const description = builder.ready_sub_lists.pop();
            try populateSubList(&draw_order_list, &builder, description, allocator, box_tree, slice);
        }

        assert(builder.pending_sub_lists.size == 0);
    }

    // Iterate over all of the SubLists to fill in the `root_draw_index` and `first_child_draw_index` fields.
    {
        const StackItem = struct {
            data: *SubList,
            child_index: SubList.Size = 0,
            state: enum { before, midpoint, after } = .before,
        };
        var stack = ArrayListUnmanaged(StackItem){};
        defer stack.deinit(allocator);

        {
            const data = draw_order_list.getSubList(root_sub_list);
            data.root_draw_index = 0;
            try stack.append(allocator, .{ .data = data });
        }

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
                    draw_index += @intCast(data.entries.items.len - 1);
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
            const child_data = draw_order_list.getSubList(child_sub_list);
            child_data.root_draw_index = draw_index;
            draw_index += 1;
            try stack.append(allocator, .{ .data = child_data });
        }
    }

    return draw_order_list;
}

fn getSubList(draw_order_list: *DrawOrderList, index: SubListIndex) *SubList {
    return &draw_order_list.sub_lists.items[index];
}

/// Allocating a SubList automatically puts it in the "pending" state, and updates the parent SubList.
fn allocateSubList(
    builder: *Builder,
    draw_order_list: *DrawOrderList,
    allocator: Allocator,
    parent: SubListIndex,
    stacking_context: StackingContextIndex,
) !void {
    if (draw_order_list.sub_lists.items.len == std.math.maxInt(SubListIndex)) return error.Overflow;
    const index = @as(SubListIndex, @intCast(draw_order_list.sub_lists.items.len));
    try draw_order_list.sub_lists.append(allocator, .{});
    try builder.pending_sub_lists.put(allocator, stacking_context, index);

    const parent_data = draw_order_list.getSubList(parent);
    if (parent_data.before_and_after.items.len == std.math.maxInt(SubList.Size)) return error.Overflow;
    try parent_data.before_and_after.append(allocator, index);
}

fn populateSubList(
    draw_order_list: *DrawOrderList,
    builder: *Builder,
    description: SubList.Description,
    allocator: Allocator,
    box_tree: BoxTree,
    slice: StackingContextTree.List.Slice,
) !void {
    const stacking_context = description.stacking_context;

    {
        // Allocate sub-lists for child stacking contexts
        const skips = slice.items(.__skip);
        const z_indeces = slice.items(.z_index);
        var child_stacking_context = stacking_context + 1;
        const end = stacking_context + skips[stacking_context];
        while (child_stacking_context < end and z_indeces[child_stacking_context] < 0) : (child_stacking_context += skips[child_stacking_context]) {
            try allocateSubList(builder, draw_order_list, allocator, description.index, child_stacking_context);
        }

        draw_order_list.getSubList(description.index).setMidpoint();

        while (child_stacking_context < end) : (child_stacking_context += skips[child_stacking_context]) {
            try allocateSubList(builder, draw_order_list, allocator, description.index, child_stacking_context);
        }
    }

    const root_block_box = slice.items(.block_box)[stacking_context];
    const root_block_subtree = box_tree.blocks.subtrees.items[root_block_box.subtree];
    const root_box_offsets = root_block_subtree.box_offsets.items[root_block_box.index];
    const root_insets = root_block_subtree.insets.items[root_block_box.index];
    const root_border_top_left = description.initial_vector.add(root_insets).add(root_box_offsets.border_pos);
    const root_content_top_left = root_border_top_left.add(root_box_offsets.content_pos);

    {
        const data = draw_order_list.getSubList(description.index);

        // Add the root block to the draw order list
        const root_entry_index = try data.addEntry(
            allocator,
            Drawable{
                .block_box = .{
                    .block_box = root_block_box,
                    .border_top_left = root_border_top_left,
                },
            },
        );
        try draw_order_list.quad_tree.insert(
            allocator,
            calcBoundingBox(root_border_top_left, root_box_offsets),
            .{ .sub_list = description.index, .entry_index = root_entry_index },
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

        var ifc_infos = AutoHashMapUnmanaged(InlineFormattingContextIndex, struct { vector: ZssVector, containing_block_width: ZssUnit }){};
        defer ifc_infos.deinit(allocator);

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

                            const entry_index = try data.addEntry(
                                allocator,
                                Drawable{
                                    .block_box = .{
                                        .block_box = .{ .subtree = subtree_index, .index = block_index },
                                        .border_top_left = border_top_left,
                                    },
                                },
                            );
                            try draw_order_list.quad_tree.insert(
                                allocator,
                                calcBoundingBox(border_top_left, box_offsets),
                                .{ .sub_list = description.index, .entry_index = entry_index },
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
                            .end = @intCast(child_subtree.skip.items.len),
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
            for (ifc.line_boxes.items, 0..) |line_box, line_box_index| {
                const bounding_box = ZssRect{
                    .x = info.vector.x,
                    .y = info.vector.y + line_box.baseline - ifc.ascender,
                    .w = info.containing_block_width,
                    .h = line_box_height,
                };
                const entry_index = try data.addEntry(
                    allocator,
                    Drawable{
                        .line_box = .{
                            .ifc_index = ifc_index,
                            .line_box_index = line_box_index,
                            .origin = info.vector,
                        },
                    },
                );
                try draw_order_list.quad_tree.insert(
                    allocator,
                    bounding_box,
                    .{ .sub_list = description.index, .entry_index = entry_index },
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

pub fn getEntry(draw_order_list: DrawOrderList, ref: DrawableRef) Drawable {
    return draw_order_list.sub_lists.items[ref.sub_list].entries.items[ref.entry_index];
}

pub fn getDrawIndex(draw_order_list: DrawOrderList, ref: DrawableRef) DrawIndex {
    const sub_list = draw_order_list.sub_lists.items[ref.sub_list];
    if (ref.entry_index == 0) {
        return sub_list.root_draw_index;
    } else {
        return sub_list.first_child_draw_index + ref.entry_index - 1;
    }
}
