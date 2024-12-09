//! In order to draw a document, we need to generate drawable objects from a `BoxTree` (the result of layout).
//! The `DrawList` is, conceptually, a list of all of those drawable objects, in the order they should be drawn.
//! In terms of implementation, the `DrawList` is made up of smaller "sub-lists" (called `SubList`).
//! Each drawable object can be referenced by its position in one of these sub-lists.
//! Each drawable has an associated DrawIndex.
//! The DrawIndex of two drawables can be compared to see which one must be drawn before the other. (Lower value = draw first)

const DrawList = @This();

const zss = @import("../zss.zig");

const BoxTree = zss.BoxTree;
const BoxOffsets = BoxTree.BoxOffsets;
const InlineFormattingContextId = BoxTree.InlineFormattingContextId;
const StackingContextTree = BoxTree.StackingContextTree;
const Subtree = BoxTree.Subtree;

const math = zss.math;
const Rect = math.Rect;
const Unit = math.Unit;
const Vector = math.Vector;

const QuadTree = @import("./QuadTree.zig");

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const AutoHashMapUnmanaged = std.AutoHashMapUnmanaged;

pub const SubListIndex = u32;

pub const DrawIndex = u32;

/// Represents a drawable object.
pub const Drawable = union(enum) {
    // TODO: Instead of individual boxes, store entire ranges of boxes as a single Drawable

    /// The drawable is a block box.
    block_box: BlockBox,
    /// The drawable is a line box of an inline formatting context.
    line_box: LineBox,

    pub const BlockBox = struct {
        ref: BoxTree.BlockRef,
        border_top_left: Vector,
    };

    pub const LineBox = struct {
        ifc_id: InlineFormattingContextId,
        line_box_index: usize,
        origin: Vector,
    };

    pub fn format(drawable: Drawable, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;

        switch (drawable) {
            .block_box => |block_box| try writer.print("BlockBox subtree={} index={}", .{ block_box.ref.subtree, block_box.ref.index }),
            .line_box => |line_box| try writer.print("LineBox ifc={} index={}", .{ line_box.ifc_id, line_box.line_box_index }),
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

/// A `SubList` represents a small segment of the entire `DrawList`.
/// SubLists reference other SubLists, forming a tree structure.
/// Each SubList is referenced by a `SubListIndex`.
/// There is 1 SubList created for every stacking context. (In the future there may be more reasons to create SubLists)
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
        initial_vector: Vector,
        /// The stacking context that caused the SubList to be created.
        stacking_context: StackingContextTree.Size,
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

/// Frees resources associated with the DrawList.
pub fn deinit(list: *DrawList, allocator: Allocator) void {
    for (list.sub_lists.items) |*sub_list| {
        sub_list.entries.deinit(allocator);
        sub_list.before_and_after.deinit(allocator);
    }
    list.sub_lists.deinit(allocator);
    list.quad_tree.deinit(allocator);
}

/// Helper struct used while creating the DrawList.
const Builder = struct {
    // A SubList can be in two states:
    //     "pending" - it has been allocated, but lacks the information needed to populate it
    //     "ready" - there is enough information to populate it

    pending_sub_lists: AutoHashMapUnmanaged(StackingContextTree.Size, SubListIndex) = .{},
    ready_sub_lists: ArrayListUnmanaged(SubList.Description) = .{},

    fn deinit(builder: *Builder, allocator: Allocator) void {
        builder.pending_sub_lists.deinit(allocator);
        builder.ready_sub_lists.deinit(allocator);
    }

    fn makeSublistReady(builder: *Builder, allocator: Allocator, stacking_context: StackingContextTree.Size, initial_vector: Vector) !void {
        const sublist_index = (builder.pending_sub_lists.fetchRemove(stacking_context) orelse unreachable).value;
        try builder.ready_sub_lists.append(allocator, SubList.Description{
            .index = sublist_index,
            .initial_vector = initial_vector,
            .stacking_context = stacking_context,
        });
    }
};

/// Creates a `DrawList` from a `BoxTree`.
pub fn create(box_tree: *const BoxTree, allocator: Allocator) !DrawList {
    var draw_list = DrawList{ .sub_lists = .{}, .quad_tree = .{} };
    errdefer draw_list.deinit(allocator);

    var root_sub_list: SubListIndex = undefined;

    {
        var builder = Builder{};
        defer builder.deinit(allocator);

        const view = box_tree.sct.view();

        {
            // Add the initial containing block stacking context to the draw order list
            try allocateIcbSubList(&builder, &draw_list, allocator);
            try builder.makeSublistReady(allocator, 0, .{ .x = 0, .y = 0 });
            const description = builder.ready_sub_lists.pop();
            root_sub_list = description.index;
            try populateSubList(&draw_list, &builder, description, allocator, box_tree, view);
        }

        while (builder.ready_sub_lists.items.len > 0) {
            const description = builder.ready_sub_lists.pop();
            try populateSubList(&draw_list, &builder, description, allocator, box_tree, view);
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
            const data = draw_list.getSubList(root_sub_list);
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
            const child_data = draw_list.getSubList(child_sub_list);
            child_data.root_draw_index = draw_index;
            draw_index += 1;
            try stack.append(allocator, .{ .data = child_data });
        }
    }

    return draw_list;
}

fn getSubList(draw_list: *DrawList, index: SubListIndex) *SubList {
    return &draw_list.sub_lists.items[index];
}

fn allocateIcbSubList(
    builder: *Builder,
    draw_list: *DrawList,
    allocator: Allocator,
) !void {
    assert(draw_list.sub_lists.items.len == 0);
    try draw_list.sub_lists.append(allocator, .{});
    try builder.pending_sub_lists.put(allocator, 0, 0);
}

/// Allocating a SubList automatically puts it in the "pending" state, and updates the parent SubList.
fn allocateSubList(
    builder: *Builder,
    draw_list: *DrawList,
    allocator: Allocator,
    parent: SubListIndex,
    stacking_context: StackingContextTree.Size,
) !void {
    if (draw_list.sub_lists.items.len == std.math.maxInt(SubListIndex)) return error.Overflow;
    const index = @as(SubListIndex, @intCast(draw_list.sub_lists.items.len));
    try draw_list.sub_lists.append(allocator, .{});
    try builder.pending_sub_lists.put(allocator, stacking_context, index);

    const parent_data = draw_list.getSubList(parent);
    if (parent_data.before_and_after.items.len == std.math.maxInt(SubList.Size)) return error.Overflow;
    try parent_data.before_and_after.append(allocator, index);
}

const PopulateSubListContext = struct {
    quad_tree: *QuadTree,
    box_tree: *const BoxTree,
    sc_tree: StackingContextTree.View,

    sub_list: *SubList,
    sublist_index: SubListIndex,
    stack: Stack = .{},
    ifc_infos: AutoHashMapUnmanaged(
        InlineFormattingContextId,
        struct { vector: Vector, containing_block_width: Unit },
    ) = .{},

    const Stack = zss.Stack(struct {
        begin: Subtree.Size,
        end: Subtree.Size,
        subtree_index: Subtree.Id,
        subtree: Subtree.View,
        vector: Vector,
    });

    fn deinit(ctx: *PopulateSubListContext, allocator: Allocator) void {
        ctx.stack.deinit(allocator);
        ctx.ifc_infos.deinit(allocator);
    }
};

fn populateSubList(
    draw_list: *DrawList,
    builder: *Builder,
    description: SubList.Description,
    allocator: Allocator,
    box_tree: *const BoxTree,
    view: StackingContextTree.View,
) !void {
    const stacking_context = description.stacking_context;

    {
        // Allocate sub-lists for child stacking contexts
        const skips = view.items(.skip);
        const z_indeces = view.items(.z_index);
        var child_stacking_context = stacking_context + 1;
        const end = stacking_context + skips[stacking_context];
        while (child_stacking_context < end and z_indeces[child_stacking_context] < 0) : (child_stacking_context += skips[child_stacking_context]) {
            try allocateSubList(builder, draw_list, allocator, description.index, child_stacking_context);
        }

        draw_list.getSubList(description.index).setMidpoint();

        while (child_stacking_context < end) : (child_stacking_context += skips[child_stacking_context]) {
            try allocateSubList(builder, draw_list, allocator, description.index, child_stacking_context);
        }
    }

    var ctx = PopulateSubListContext{
        .sub_list = draw_list.getSubList(description.index),
        .sublist_index = description.index,
        .quad_tree = &draw_list.quad_tree,
        .box_tree = box_tree,
        .sc_tree = view,
    };
    defer ctx.deinit(allocator);

    {
        // Add the root block to the draw order list
        const root_block_box = view.items(.ref)[stacking_context];
        const root_block_subtree = box_tree.blocks.subtree(root_block_box.subtree).view();
        const root_block_skip = root_block_subtree.items(.skip)[root_block_box.index];
        const initial_item = PopulateSubListContext.Stack.Item{
            .begin = undefined,
            .end = undefined,
            .subtree_index = root_block_box.subtree,
            .subtree = root_block_subtree,
            .vector = description.initial_vector,
        };
        const item = try analyzeBlock(&ctx, allocator, root_block_box.index, root_block_skip, &initial_item);
        ctx.stack.top = item;
    }

    // Add child block boxes to the draw order list
    while (ctx.stack.top) |*top| {
        if (top.begin == top.end) {
            _ = ctx.stack.pop();
            continue;
        }
        const block_index = top.begin;
        const block_skip = top.subtree.items(.skip)[block_index];
        top.begin += block_skip;

        if (top.subtree.items(.stacking_context)[block_index]) |child_stacking_context_id| {
            const child_stacking_context: StackingContextTree.Size =
                @intCast(std.mem.indexOfScalar(StackingContextTree.Id, view.items(.id), child_stacking_context_id).?);
            try builder.makeSublistReady(allocator, child_stacking_context, top.vector);
            continue;
        }

        const item = try analyzeBlock(&ctx, allocator, block_index, block_skip, top);
        try ctx.stack.push(allocator, item);
    }

    // Add inline formatting context line boxes to the draw order list
    for (ctx.sc_tree.items(.ifcs)[stacking_context].items) |ifc_id| {
        const info = ctx.ifc_infos.get(ifc_id).?;
        const ifc = box_tree.getIfc(ifc_id);
        const line_box_height = ifc.ascender + ifc.descender;
        for (ifc.line_boxes.items, 0..) |line_box, line_box_index| {
            const bounding_box = Rect{
                .x = info.vector.x,
                .y = info.vector.y + line_box.baseline - ifc.ascender,
                .w = info.containing_block_width,
                .h = line_box_height,
            };
            const entry_index = try ctx.sub_list.addEntry(
                allocator,
                Drawable{
                    .line_box = .{
                        .ifc_id = ifc_id,
                        .line_box_index = line_box_index,
                        .origin = info.vector,
                    },
                },
            );
            try draw_list.quad_tree.insert(
                allocator,
                bounding_box,
                .{ .sub_list = description.index, .entry_index = entry_index },
            );
        }
    }
}

// NOTE: `ctx` and `top` alias
fn analyzeBlock(
    ctx: *PopulateSubListContext,
    allocator: Allocator,
    block_index: Subtree.Size,
    block_skip: Subtree.Size,
    top: *const PopulateSubListContext.Stack.Item,
) !PopulateSubListContext.Stack.Item {
    const block_type = top.subtree.items(.type)[block_index];
    const box_offsets = top.subtree.items(.box_offsets)[block_index];
    switch (block_type) {
        .block => {
            const insets = top.subtree.items(.insets)[block_index];
            const border_top_left = top.vector.add(insets).add(box_offsets.border_pos);
            const content_top_left = border_top_left.add(box_offsets.content_pos);

            const entry_index = try ctx.sub_list.addEntry(
                allocator,
                Drawable{
                    .block_box = .{
                        .ref = .{ .subtree = top.subtree_index, .index = block_index },
                        .border_top_left = border_top_left,
                    },
                },
            );
            try ctx.quad_tree.insert(
                allocator,
                calcBoundingBox(border_top_left, box_offsets),
                .{ .sub_list = ctx.sublist_index, .entry_index = entry_index },
            );

            return .{
                .begin = block_index + 1,
                .end = block_index + block_skip,
                .subtree_index = top.subtree_index,
                .subtree = top.subtree,
                .vector = content_top_left,
            };
        },
        .ifc_container => |ifc_id| {
            const content_top_left = top.vector.add(box_offsets.border_pos).add(box_offsets.content_pos);
            try ctx.ifc_infos.putNoClobber(
                allocator,
                ifc_id,
                .{ .vector = content_top_left, .containing_block_width = box_offsets.content_size.w },
            );

            return .{
                .begin = block_index + 1,
                .end = block_index + block_skip,
                .subtree_index = top.subtree_index,
                .subtree = top.subtree,
                .vector = content_top_left,
            };
        },
        .subtree_proxy => |proxy_subtree_index| {
            const child_subtree = ctx.box_tree.blocks.subtree(proxy_subtree_index);
            const content_top_left = top.vector.add(box_offsets.border_pos).add(box_offsets.content_pos);
            return .{
                .begin = 0,
                .end = child_subtree.size(),
                .subtree_index = proxy_subtree_index,
                .subtree = child_subtree.view(),
                .vector = content_top_left,
            };
        },
    }
}

fn calcBoundingBox(border_top_left: Vector, box_offsets: BoxOffsets) Rect {
    return Rect{
        .x = border_top_left.x,
        .y = border_top_left.y,
        .w = box_offsets.border_size.w,
        .h = box_offsets.border_size.h,
    };
}

pub fn print(draw_list: DrawList, writer: anytype, allocator: Allocator) !void {
    var stack = ArrayListUnmanaged(struct {
        sub_list: *const SubList,
        child_index: SubList.Size = 0,
        state: enum { root, before, midpoint, after } = .root,
    }){};
    defer stack.deinit(allocator);
    try stack.append(allocator, .{ .sub_list = &draw_list.sub_lists.items[0] });

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
                try stack.append(allocator, .{ .sub_list = &draw_list.sub_lists.items[child_sub_list] });
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
                try stack.append(allocator, .{ .sub_list = &draw_list.sub_lists.items[child_sub_list] });
            },
        }
    }
}

pub fn getEntry(draw_list: DrawList, ref: DrawableRef) Drawable {
    return draw_list.sub_lists.items[ref.sub_list].entries.items[ref.entry_index];
}

pub fn getDrawIndex(draw_list: DrawList, ref: DrawableRef) DrawIndex {
    const sub_list = draw_list.sub_lists.items[ref.sub_list];
    if (ref.entry_index == 0) {
        return sub_list.root_draw_index;
    } else {
        return sub_list.first_child_draw_index + ref.entry_index - 1;
    }
}
