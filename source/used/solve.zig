const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const assert = std.debug.assert;

const zss = @import("../../zss.zig");
const computed = zss.properties;
const values = zss.values;
const BoxTree = zss.box_tree.BoxTree;
usingnamespace zss.types;

const used = @import("properties.zig");
const BlockRenderingContext = @import("BlockRenderingContext.zig");
const InlineRenderingContext = @import("InlineRenderingContext.zig");

const hb = @import("harfbuzz");

const Interval = struct {
    begin: u16,
    end: u16,
};

const UsedIdAndSubtreeSize = struct {
    used_id: u16,
    used_subtree_size: u16,
};

const UsedBlockSizes = struct {
    size: ?CSSUnit,
    min_size: CSSUnit,
    max_size: CSSUnit,
    margin_start: CSSUnit,
    margin_end: CSSUnit,
};

const InFlowInsets = struct {
    const BlockInset = union(enum) {
        /// A used length value.
        length: CSSUnit,
        /// A computed percentage value.
        percentage: f32,
    };
    inline_axis: CSSUnit,
    block_axis: BlockInset,
};

const InFlowPositioningData = struct {
    insets: InFlowInsets,
    used_id: u16,
};

const StackingContextTree = struct {
    const Entry = struct {
        subtree_size: u16,
        z_index: i16,
    };

    preorder_array: []Entry,
    data: []*BlockRenderingContext,
};

pub const BlockContext = struct {
    const Self = @This();

    box_tree: *const BoxTree,
    root_id: u16,
    allocator: *Allocator,
    intervals: ArrayListUnmanaged(Interval),
    used_id_and_subtree_size: ArrayListUnmanaged(UsedIdAndSubtreeSize),
    static_containing_block_used_inline_size: ArrayListUnmanaged(CSSUnit),
    static_containing_block_auto_block_size: ArrayListUnmanaged(CSSUnit),
    static_containing_block_used_block_sizes: ArrayListUnmanaged(UsedBlockSizes),
    in_flow_positioning_data: ArrayListUnmanaged(InFlowPositioningData),
    in_flow_positioning_data_count: ArrayListUnmanaged(u16),

    pub fn init(box_tree: *const BoxTree, allocator: *Allocator, root_id: u16, containing_block_inline_size: CSSUnit, containing_block_block_size: ?CSSUnit) !Self {
        var in_flow_positioning_data_count = ArrayListUnmanaged(u16){};
        errdefer in_flow_positioning_data_count.deinit(allocator);
        try in_flow_positioning_data_count.append(allocator, 0);

        var used_id_and_subtree_size = ArrayListUnmanaged(UsedIdAndSubtreeSize){};
        errdefer used_id_and_subtree_size.deinit(allocator);
        try used_id_and_subtree_size.append(allocator, UsedIdAndSubtreeSize{
            .used_id = undefined,
            .used_subtree_size = 1,
        });

        var static_containing_block_used_inline_size = ArrayListUnmanaged(CSSUnit){};
        errdefer static_containing_block_used_inline_size.deinit(allocator);
        // TODO using physical property when we should be using a logical one
        try static_containing_block_used_inline_size.append(allocator, containing_block_inline_size);

        var static_containing_block_auto_block_size = ArrayListUnmanaged(CSSUnit){};
        errdefer static_containing_block_auto_block_size.deinit(allocator);
        try static_containing_block_auto_block_size.append(allocator, 0);

        var static_containing_block_used_block_sizes = ArrayListUnmanaged(UsedBlockSizes){};
        errdefer static_containing_block_used_block_sizes.deinit(allocator);
        // TODO using physical property when we should be using a logical one
        try static_containing_block_used_block_sizes.append(allocator, UsedBlockSizes{
            .size = containing_block_block_size,
            .min_size = 0,
            .max_size = 0,
            .margin_start = 0,
            .margin_end = 0,
        });

        return Self{
            .box_tree = box_tree,
            .root_id = root_id,
            .allocator = allocator,
            .intervals = .{},
            .used_id_and_subtree_size = used_id_and_subtree_size,
            .static_containing_block_used_inline_size = static_containing_block_used_inline_size,
            .static_containing_block_auto_block_size = static_containing_block_auto_block_size,
            .static_containing_block_used_block_sizes = static_containing_block_used_block_sizes,
            .in_flow_positioning_data = .{},
            .in_flow_positioning_data_count = in_flow_positioning_data_count,
        };
    }

    pub fn deinit(self: *Self) void {
        self.intervals.deinit(self.allocator);
        self.used_id_and_subtree_size.deinit(self.allocator);
        self.static_containing_block_used_inline_size.deinit(self.allocator);
        self.static_containing_block_auto_block_size.deinit(self.allocator);
        self.static_containing_block_used_block_sizes.deinit(self.allocator);
        self.in_flow_positioning_data.deinit(self.allocator);
        self.in_flow_positioning_data_count.deinit(self.allocator);
    }
};

const IntermediateBlockUsedData = struct {
    const Self = @This();

    preorder_array: ArrayListUnmanaged(u16) = .{},
    box_offsets: ArrayListUnmanaged(BoxOffsets) = .{},
    borders: ArrayListUnmanaged(used.Borders) = .{},
    border_colors: ArrayListUnmanaged(used.BorderColor) = .{},
    background_color: ArrayListUnmanaged(used.BackgroundColor) = .{},
    background_image: ArrayListUnmanaged(used.BackgroundImage) = .{},
    visual_effect: ArrayListUnmanaged(used.VisualEffect) = .{},
    inline_data: ArrayListUnmanaged(BlockRenderingContext.InlineData) = .{},

    fn deinit(self: *Self, allocator: *Allocator) void {
        self.preorder_array.deinit(allocator);
        self.box_offsets.deinit(allocator);
        self.borders.deinit(allocator);
        self.border_colors.deinit(allocator);
        self.background_color.deinit(allocator);
        self.background_image.deinit(allocator);
        self.visual_effect.deinit(allocator);
        for (self.inline_data.items) |*inl| {
            inl.data.deinit(allocator);
            allocator.destroy(inl.data);
        }
        self.inline_data.deinit(allocator);
    }

    fn ensureCapacity(self: *Self, allocator: *Allocator, capacity: usize) !void {
        try self.preorder_array.ensureCapacity(allocator, capacity);
        try self.box_offsets.ensureCapacity(allocator, capacity);
        try self.borders.ensureCapacity(allocator, capacity);
        try self.border_colors.ensureCapacity(allocator, capacity);
        try self.background_color.ensureCapacity(allocator, capacity);
        try self.background_image.ensureCapacity(allocator, capacity);
        try self.visual_effect.ensureCapacity(allocator, capacity);
        try self.inline_data.ensureCapacity(allocator, capacity);
    }

    fn toNormalData(self: *Self, allocator: *Allocator) BlockRenderingContext {
        return BlockRenderingContext{
            .preorder_array = self.preorder_array.toOwnedSlice(allocator),
            .box_offsets = self.box_offsets.toOwnedSlice(allocator),
            .borders = self.borders.toOwnedSlice(allocator),
            .border_colors = self.border_colors.toOwnedSlice(allocator),
            .background_color = self.background_color.toOwnedSlice(allocator),
            .background_image = self.background_image.toOwnedSlice(allocator),
            .visual_effect = self.visual_effect.toOwnedSlice(allocator),
            .inline_data = self.inline_data.toOwnedSlice(allocator),
        };
    }
};

pub fn createBlockUsedData(context: *BlockContext, allocator: *Allocator) !BlockRenderingContext {
    const root_id = context.root_id;
    const root_subtree_size = context.box_tree.preorder_array[root_id];

    var data = IntermediateBlockUsedData{};
    errdefer data.deinit(allocator);
    try data.ensureCapacity(allocator, root_subtree_size);

    var root_interval = Interval{ .begin = root_id, .end = root_subtree_size };
    try blockLevelElementSwitch(context, &data, allocator, &root_interval);

    while (context.intervals.items.len > 0) {
        const interval = &context.intervals.items[context.intervals.items.len - 1];
        if (interval.begin == interval.end) {
            const id_subtree_size = context.used_id_and_subtree_size.items[context.used_id_and_subtree_size.items.len - 1];
            const used_id = id_subtree_size.used_id;
            const used_subtree_size = id_subtree_size.used_subtree_size;
            data.preorder_array.items[used_id] = used_subtree_size;
            context.used_id_and_subtree_size.items[context.used_id_and_subtree_size.items.len - 2].used_subtree_size += used_subtree_size;

            const box_offsets_ptr = &data.box_offsets.items[used_id];
            const parent_auto_block_size = &context.static_containing_block_auto_block_size.items[context.static_containing_block_auto_block_size.items.len - 2];
            blockContainerFinishProcessing(context, &data, box_offsets_ptr, parent_auto_block_size);

            _ = context.intervals.pop();
            _ = context.used_id_and_subtree_size.pop();
            _ = context.static_containing_block_used_inline_size.pop();
            _ = context.static_containing_block_auto_block_size.pop();
            _ = context.static_containing_block_used_block_sizes.pop();
            const in_flow_positioning_data_count = context.in_flow_positioning_data_count.pop();
            context.in_flow_positioning_data.shrinkRetainingCapacity(context.in_flow_positioning_data.items.len - in_flow_positioning_data_count);
        } else {
            try blockLevelElementSwitch(context, &data, allocator, interval);
        }
    }

    { // Finish processing the root element.
        var box_offsets = BoxOffsets{
            .border_top_left = .{ .x = 0, .y = 0 },
            .border_bottom_right = .{ .x = 0, .y = 0 },
            .content_top_left = .{ .x = 0, .y = 0 },
            .content_bottom_right = .{ .x = 0, .y = 0 },
        };
        var parent_auto_block_size = @as(CSSUnit, 0);
        blockContainerFinishProcessing(context, &data, &box_offsets, &parent_auto_block_size);
    }

    return data.toNormalData(allocator);
}

fn blockLevelElementSwitch(context: *BlockContext, data: *IntermediateBlockUsedData, allocator: *Allocator, interval: *Interval) !void {
    switch (context.box_tree.display[interval.begin]) {
        .block_flow_root, .block_flow => return blockLevelElementBeginProcessing(context, data, allocator, interval),
        .inline_flow, .text => {
            const used_id = try std.math.cast(u16, data.preorder_array.items.len);

            var inline_context = InlineContext.init(
                context.box_tree,
                allocator,
                interval.*,
                context.static_containing_block_used_inline_size.items[context.static_containing_block_used_inline_size.items.len - 1],
            );
            defer inline_context.deinit();
            const inline_data_ptr = try data.inline_data.addOne(allocator);
            inline_data_ptr.* = .{
                .used_id = used_id,
                .data = try allocator.create(InlineRenderingContext),
            };
            inline_data_ptr.data.* = try createInlineUsedData(&inline_context, allocator);

            if (inline_context.next_box_id != interval.begin + context.box_tree.preorder_array[interval.begin]) {
                @panic("TODO inline-level elements must be the last children of a block box");
            }
            interval.begin = inline_context.next_box_id;

            context.used_id_and_subtree_size.items[context.used_id_and_subtree_size.items.len - 1].used_subtree_size += 1;
            const parent_auto_block_size = &context.static_containing_block_auto_block_size.items[context.static_containing_block_auto_block_size.items.len - 1];
            try data.preorder_array.append(allocator, 1);
            try data.box_offsets.append(allocator, .{
                .border_top_left = .{ .x = 0, .y = parent_auto_block_size.* },
                .border_bottom_right = .{ .x = 0, .y = parent_auto_block_size.* },
                .content_top_left = .{ .x = 0, .y = parent_auto_block_size.* },
                .content_bottom_right = .{ .x = 0, .y = parent_auto_block_size.* },
            });
            try data.borders.append(allocator, .{});
            try data.border_colors.append(allocator, .{});
            try data.background_color.append(allocator, .{});
            try data.background_image.append(allocator, .{});
            try data.visual_effect.append(allocator, .{});
            parent_auto_block_size.* += inline_context.total_block_size;
        },
        .none => return,
        .initial, .inherit, .unset => unreachable,
    }
}

fn blockLevelElementBeginProcessing(context: *BlockContext, data: *IntermediateBlockUsedData, allocator: *Allocator, interval: *Interval) !void {
    const original_id = interval.begin;
    const subtree_size = context.box_tree.preorder_array[original_id];
    interval.begin += subtree_size;

    const used_id = try std.math.cast(u16, data.preorder_array.items.len);

    const position_inset = &context.box_tree.position_inset[original_id];
    switch (position_inset.position) {
        .static => {},
        .relative => {
            const insets = resolveRelativePositionInset(context, position_inset);
            try context.in_flow_positioning_data.append(context.allocator, InFlowPositioningData{
                .insets = insets,
                .used_id = used_id,
            });
            context.in_flow_positioning_data_count.items[context.in_flow_positioning_data_count.items.len - 1] += 1;
        },
        .sticky => @panic("TODO: sticky positioning"),
        .absolute => @panic("TODO: absolute positioning"),
        .fixed => @panic("TODO: fixed positioning"),
        .initial, .inherit, .unset => unreachable,
    }

    const preorder_array_ptr = try data.preorder_array.addOne(allocator);
    const box_offsets_ptr = try data.box_offsets.addOne(allocator);
    const borders_ptr = try data.borders.addOne(allocator);
    const inline_size = getInlineOffsets(context, original_id, box_offsets_ptr, borders_ptr);
    const size_margins = getBlockOffsets(context, original_id, box_offsets_ptr, borders_ptr);

    // TODO fill in all this data
    try data.border_colors.append(allocator, .{});
    try data.background_color.append(allocator, .{});
    try data.background_image.append(allocator, .{});
    try data.visual_effect.append(allocator, .{});

    if (subtree_size != 1) {
        try context.intervals.append(context.allocator, Interval{ .begin = original_id + 1, .end = original_id + subtree_size });
        try context.static_containing_block_used_inline_size.append(context.allocator, inline_size);
        // TODO don't add elements to this stack unconditionally
        try context.static_containing_block_auto_block_size.append(context.allocator, 0);
        // TODO don't add elements to this stack unconditionally
        try context.static_containing_block_used_block_sizes.append(context.allocator, size_margins);
        try context.used_id_and_subtree_size.append(context.allocator, UsedIdAndSubtreeSize{
            .used_id = used_id,
            .used_subtree_size = 1,
        });
        // TODO don't add elements to this stack unconditionally
        try context.in_flow_positioning_data_count.append(context.allocator, 0);
    } else {
        preorder_array_ptr.* = 1;
        context.used_id_and_subtree_size.items[context.used_id_and_subtree_size.items.len - 1].used_subtree_size += 1;
        const parent_auto_block_size = &context.static_containing_block_auto_block_size.items[context.static_containing_block_auto_block_size.items.len - 1];
        _ = blockContainerFinalizeBlockSizes(box_offsets_ptr, size_margins, 0, parent_auto_block_size);
    }
}

fn blockContainerFinishProcessing(context: *BlockContext, data: *IntermediateBlockUsedData, box_offsets: *BoxOffsets, parent_auto_block_size: *CSSUnit) void {
    const size_margins = context.static_containing_block_used_block_sizes.items[context.static_containing_block_used_block_sizes.items.len - 1];
    const auto_block_size = context.static_containing_block_auto_block_size.items[context.static_containing_block_auto_block_size.items.len - 1];
    const sizes = blockContainerFinalizeBlockSizes(box_offsets, size_margins, auto_block_size, parent_auto_block_size);
    applyInFlowPositioningToChildren(context, data.box_offsets.items, sizes.used_block_size);
}

fn blockContainerFinalizeBlockSizes(box_offsets: *BoxOffsets, size_margins: UsedBlockSizes, auto_block_size: CSSUnit, parent_auto_block_size: *CSSUnit) struct {
    used_block_size: CSSUnit,
} {
    // TODO UB if min_size > max_size
    const used_block_size = std.math.clamp(size_margins.size orelse auto_block_size, size_margins.min_size, size_margins.max_size);
    box_offsets.border_top_left.y = parent_auto_block_size.* + size_margins.margin_start;
    box_offsets.content_top_left.y += box_offsets.border_top_left.y;
    box_offsets.content_bottom_right.y = box_offsets.content_top_left.y + used_block_size;
    box_offsets.border_bottom_right.y += box_offsets.content_bottom_right.y;
    parent_auto_block_size.* = box_offsets.border_bottom_right.y + size_margins.margin_end;
    return .{
        .used_block_size = used_block_size,
    };
}

fn applyInFlowPositioningToChildren(context: *const BlockContext, box_offsets: []BoxOffsets, containing_block_block_size: CSSUnit) void {
    const count = context.in_flow_positioning_data_count.items[context.in_flow_positioning_data_count.items.len - 1];
    var i: u16 = 0;
    while (i < count) : (i += 1) {
        const positioning_data = context.in_flow_positioning_data.items[context.in_flow_positioning_data.items.len - 1 - i];
        const positioning_offset = zss.types.Offset{
            // TODO using physical property when we should be using a logical one
            .x = positioning_data.insets.inline_axis,
            // TODO using physical property when we should be using a logical one
            .y = switch (positioning_data.insets.block_axis) {
                .length => |l| l,
                .percentage => |value| percentage(value, containing_block_block_size),
            },
        };
        const box_offset = &box_offsets[positioning_data.used_id];
        inline for (std.meta.fields(BoxOffsets)) |field| {
            const offset = &@field(box_offset, field.name);
            offset.* = offset.add(positioning_offset);
        }
    }
}

fn resolveRelativePositionInset(context: *BlockContext, position_inset: *computed.PositionInset) InFlowInsets {
    const containing_block_inline_size = context.static_containing_block_used_inline_size.items[context.static_containing_block_used_inline_size.items.len - 1];
    const containing_block_block_size = context.static_containing_block_used_block_sizes.items[context.static_containing_block_used_block_sizes.items.len - 1].size;
    const inline_start = switch (position_inset.inline_start) {
        .px => |value| length(.px, value),
        .percentage => |value| percentage(value, containing_block_inline_size),
        .auto => null,
        .initial, .inherit, .unset => unreachable,
    };
    const inline_end = switch (position_inset.inline_end) {
        .px => |value| -length(.px, value),
        .percentage => |value| -percentage(value, containing_block_inline_size),
        .auto => null,
        .initial, .inherit, .unset => unreachable,
    };
    const block_start: ?InFlowInsets.BlockInset = switch (position_inset.block_start) {
        .px => |value| InFlowInsets.BlockInset{ .length = length(.px, value) },
        .percentage => |value| if (containing_block_block_size) |s|
            InFlowInsets.BlockInset{ .length = percentage(value, s) }
        else
            InFlowInsets.BlockInset{ .percentage = value },
        .auto => null,
        .initial, .inherit, .unset => unreachable,
    };
    const block_end: ?InFlowInsets.BlockInset = switch (position_inset.block_end) {
        .px => |value| InFlowInsets.BlockInset{ .length = -length(.px, value) },
        .percentage => |value| if (containing_block_block_size) |s|
            InFlowInsets.BlockInset{ .length = -percentage(value, s) }
        else
            InFlowInsets.BlockInset{ .percentage = -value },
        .auto => null,
        .initial, .inherit, .unset => unreachable,
    };
    return InFlowInsets{
        .inline_axis = inline_start orelse inline_end orelse 0,
        .block_axis = block_start orelse block_end orelse InFlowInsets.BlockInset{ .length = 0 },
    };
}

const LengthUnit = enum { px };

fn length(comptime unit: LengthUnit, value: f32) CSSUnit {
    return switch (unit) {
        .px => @floatToInt(CSSUnit, @round(value)),
    };
}

fn percentage(value: f32, unit: CSSUnit) CSSUnit {
    return @floatToInt(CSSUnit, @round(@intToFloat(f32, unit) * value));
}

fn lineWidth(val: computed.LogicalSize.BorderValue) CSSUnit {
    return switch (val) {
        .px => |value| length(.px, value),
        .thin => 1,
        .medium => 3,
        .thick => 5,
        .initial, .inherit, .unset => unreachable,
    };
}

fn getInlineOffsets(context: *const BlockContext, id: u16, box_offsets: *BoxOffsets, borders: *used.Borders) CSSUnit {
    const solved = solveInlineSizes(
        &context.box_tree.inline_size[id],
        context.static_containing_block_used_inline_size.items[context.static_containing_block_used_inline_size.items.len - 1],
    );

    // TODO using physical property when we should be using a logical one
    box_offsets.border_top_left.x = solved.margin_start;
    box_offsets.content_top_left.x = box_offsets.border_top_left.x + solved.border_start + solved.padding_start;
    box_offsets.content_bottom_right.x = box_offsets.content_top_left.x + solved.size;
    box_offsets.border_bottom_right.x = box_offsets.content_bottom_right.x + solved.padding_end + solved.border_end;

    // TODO using physical property when we should be using a logical one
    borders.left = solved.border_start;
    borders.right = solved.border_end;

    return solved.size;
}

/// This implements CSS2§10.3.3
fn solveInlineSizes(
    sizes: *const computed.LogicalSize,
    containing_block_inline_size: CSSUnit,
) struct {
    size: CSSUnit,
    border_start: CSSUnit,
    border_end: CSSUnit,
    padding_start: CSSUnit,
    padding_end: CSSUnit,
    margin_start: CSSUnit,
    margin_end: CSSUnit,
} {
    // TODO border widths must always be positive
    const border_start = lineWidth(sizes.border_start_width);
    const border_end = lineWidth(sizes.border_end_width);
    const padding_start = switch (sizes.padding_start) {
        .px => |value| length(.px, value),
        .percentage => |value| percentage(value, containing_block_inline_size),
        .initial, .inherit, .unset => unreachable,
    };
    const padding_end = switch (sizes.padding_end) {
        .px => |value| length(.px, value),
        .percentage => |value| percentage(value, containing_block_inline_size),
        .initial, .inherit, .unset => unreachable,
    };
    const cm_space = containing_block_inline_size - (border_start + border_end + padding_start + padding_end);

    // TODO UB if min_size > max_size
    const min_size = switch (sizes.min_size) {
        .px => |value| length(.px, value),
        .percentage => |value| percentage(value, std.math.max(0, containing_block_inline_size)),
        .initial, .inherit, .unset => unreachable,
    };
    const max_size = switch (sizes.max_size) {
        .px => |value| length(.px, value),
        .percentage => |value| percentage(value, std.math.max(0, containing_block_inline_size)),
        .none => std.math.maxInt(CSSUnit),
        .initial, .inherit, .unset => unreachable,
    };

    var auto_bitfield: u3 = 0;
    const size_bit = 4;
    const margin_start_bit = 2;
    const margin_end_bit = 1;

    var size = switch (sizes.size) {
        .px => |value| length(.px, value),
        .percentage => |value| percentage(value, containing_block_inline_size),
        .auto => blk: {
            auto_bitfield |= size_bit;
            break :blk 0;
        },
        .initial, .inherit, .unset => unreachable,
    };
    var margin_start = switch (sizes.margin_start) {
        .px => |value| length(.px, value),
        .percentage => |value| percentage(value, containing_block_inline_size),
        .auto => blk: {
            auto_bitfield |= margin_start_bit;
            break :blk 0;
        },
        .initial, .inherit, .unset => unreachable,
    };
    var margin_end = switch (sizes.margin_end) {
        .px => |value| length(.px, value),
        .percentage => |value| percentage(value, containing_block_inline_size),
        .auto => blk: {
            auto_bitfield |= margin_end_bit;
            break :blk 0;
        },
        .initial, .inherit, .unset => unreachable,
    };

    if (auto_bitfield == 0) {
        // TODO(§10.3.3): which margin gets set is affected by the 'direction' property
        size = std.math.clamp(size, min_size, max_size);
        margin_end = cm_space - size - margin_start;
    } else if (auto_bitfield & size_bit == 0) {
        const start = auto_bitfield & margin_start_bit;
        const end = auto_bitfield & margin_end_bit;
        const shr_amount = @boolToInt(start | end == margin_start_bit | margin_end_bit);
        size = std.math.clamp(size, min_size, max_size);
        const leftover_margin = std.math.max(0, cm_space - (size + margin_start + margin_end));
        // NOTE: which margin gets the extra 1 unit shall be affected by the 'direction' property
        if (start == 0) margin_start = leftover_margin >> shr_amount;
        if (end == 0) margin_end = (leftover_margin >> shr_amount) + @mod(leftover_margin, 2);
    } else {
        size = std.math.clamp(cm_space - margin_start - margin_end, min_size, max_size);
    }

    return .{
        .size = size,
        .border_start = border_start,
        .border_end = border_end,
        .padding_start = padding_start,
        .padding_end = padding_end,
        .margin_start = margin_start,
        .margin_end = margin_end,
    };
}

fn getBlockOffsets(context: *const BlockContext, id: u16, box_offsets: *BoxOffsets, borders: *used.Borders) UsedBlockSizes {
    const solved = solveBlockSizes(
        &context.box_tree.block_size[id],
        context.static_containing_block_used_inline_size.items[context.static_containing_block_used_inline_size.items.len - 1],
        context.static_containing_block_used_block_sizes.items[context.static_containing_block_used_block_sizes.items.len - 1].size,
    );

    // TODO using physical property when we should be using a logical one
    box_offsets.content_top_left.y = solved.border_start + solved.padding_start;
    box_offsets.border_bottom_right.y = solved.padding_end + solved.border_end;

    // TODO using physical property when we should be using a logical one
    borders.top = solved.border_start;
    borders.bottom = solved.border_end;

    // TODO using physical property when we should be using a logical one
    return UsedBlockSizes{
        .size = solved.size,
        .min_size = solved.min_size,
        .max_size = solved.max_size,
        .margin_start = solved.margin_start,
        .margin_end = solved.margin_end,
    };
}

/// This implements CSS2§10.6.3
fn solveBlockSizes(
    sizes: *const computed.LogicalSize,
    containing_block_inline_size: CSSUnit,
    containing_block_block_size: ?CSSUnit,
) struct {
    size: ?CSSUnit,
    min_size: CSSUnit,
    max_size: CSSUnit,
    border_start: CSSUnit,
    border_end: CSSUnit,
    padding_start: CSSUnit,
    padding_end: CSSUnit,
    margin_start: CSSUnit,
    margin_end: CSSUnit,
} {
    var size = switch (sizes.size) {
        .px => |value| length(.px, value),
        .percentage => |value| if (containing_block_block_size) |s|
            percentage(value, s)
        else
            null,
        .auto => null,
        .initial, .inherit, .unset => unreachable,
    };
    // TODO border widths must always be positive
    const border_start = lineWidth(sizes.border_start_width);
    const border_end = lineWidth(sizes.border_end_width);
    const padding_start = switch (sizes.padding_start) {
        .px => |value| length(.px, value),
        .percentage => |value| percentage(value, containing_block_inline_size),
        .initial, .inherit, .unset => unreachable,
    };
    const padding_end = switch (sizes.padding_end) {
        .px => |value| length(.px, value),
        .percentage => |value| percentage(value, containing_block_inline_size),
        .initial, .inherit, .unset => unreachable,
    };
    const margin_start = switch (sizes.margin_start) {
        .px => |value| length(.px, value),
        .percentage => |value| percentage(value, containing_block_inline_size),
        .auto => 0,
        .initial, .inherit, .unset => unreachable,
    };
    const margin_end = switch (sizes.margin_end) {
        .px => |value| length(.px, value),
        .percentage => |value| percentage(value, containing_block_inline_size),
        .auto => 0,
        .initial, .inherit, .unset => unreachable,
    };

    // TODO UB if min_size > max_size
    const min_size = switch (sizes.min_size) {
        .px => |value| length(.px, value),
        .percentage => |value| if (containing_block_block_size) |s|
            percentage(value, s)
        else
            0,
        .initial, .inherit, .unset => unreachable,
    };
    const max_size = switch (sizes.max_size) {
        .px => |value| length(.px, value),
        .percentage => |value| if (containing_block_block_size) |s|
            percentage(value, s)
        else
            std.math.maxInt(CSSUnit),
        .none => std.math.maxInt(CSSUnit),
        .initial, .inherit, .unset => unreachable,
    };

    return .{
        .size = size,
        .min_size = min_size,
        .max_size = max_size,
        .border_start = border_start,
        .border_end = border_end,
        .padding_start = padding_start,
        .padding_end = padding_end,
        .margin_start = margin_start,
        .margin_end = margin_end,
    };
}

test "used data" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.testing.expect(!gpa.deinit());
    const al = &gpa.allocator;

    const len = 4;
    var preorder_array = [len]u16{ 4, 2, 1, 1 };
    const inline_size_1 = computed.LogicalSize{
        .size = .{ .percentage = 0.7 },
        .margin_start = .{ .px = 20 },
        .margin_end = .{ .px = 20 },
        .border_start_width = .{ .px = 5 },
        .border_end_width = .{ .px = 5 },
    };
    const inline_size_2 = computed.LogicalSize{
        .margin_start = .{ .px = 20 },
        .border_start_width = .{ .px = 5 },
        .border_end_width = .{ .px = 5 },
    };
    const block_size_1 = computed.LogicalSize{
        .size = .{ .percentage = 0.9 },
        .border_start_width = .{ .px = 5 },
        .border_end_width = .{ .px = 5 },
    };
    const block_size_2 = computed.LogicalSize{
        .border_start_width = .{ .px = 5 },
        .border_end_width = .{ .px = 5 },
    };

    var inline_size = [len]computed.LogicalSize{ inline_size_1, inline_size_2, inline_size_1, inline_size_1 };
    var block_size = [len]computed.LogicalSize{ block_size_1, block_size_2, block_size_1, block_size_1 };
    var display = [len]computed.Display{
        .{ .block_flow_root = {} },
        .{ .block_flow = {} },
        .{ .block_flow = {} },
        .{ .block_flow = {} },
    };
    var position_inset = [len]computed.PositionInset{
        .{ .position = .{ .relative = {} }, .inline_start = .{ .px = 100 } },
        .{},
        .{},
        .{},
    };
    var latin1_text = [_]computed.Latin1Text{.{ .text = "" }} ** len;
    var font = computed.Font{ .font = null };
    var context = try BlockContext.init(
        &BoxTree{
            .preorder_array = &preorder_array,
            .inline_size = &inline_size,
            .block_size = &block_size,
            .display = &display,
            .position_inset = &position_inset,
            .latin1_text = &latin1_text,
            .font = font,
        },
        al,
        0,
        400,
        400,
    );
    defer context.deinit();
    var data = try createBlockUsedData(&context, al);
    defer data.deinit(al);

    for (data.box_offsets) |box_offset| {
        std.debug.print("{}\n", .{box_offset});
    }
    for (data.borders) |border| {
        std.debug.print("{}\n", .{border});
    }
}

const IntermediateInlineUsedData = struct {
    const Self = @This();

    line_boxes: ArrayListUnmanaged(InlineRenderingContext.LineBox) = .{},
    glyph_indeces: ArrayListUnmanaged(hb.hb_codepoint_t) = .{},
    positions: ArrayListUnmanaged(InlineRenderingContext.Position) = .{},
    font: *hb.hb_font_t = undefined,

    measures_top: ArrayListUnmanaged(InlineRenderingContext.BoxMeasures) = .{},
    measures_right: ArrayListUnmanaged(InlineRenderingContext.BoxMeasures) = .{},
    measures_bottom: ArrayListUnmanaged(InlineRenderingContext.BoxMeasures) = .{},
    measures_left: ArrayListUnmanaged(InlineRenderingContext.BoxMeasures) = .{},
    heights: ArrayListUnmanaged(InlineRenderingContext.Heights) = .{},
    background_color: ArrayListUnmanaged(used.BackgroundColor) = .{},

    margins: ArrayListUnmanaged(used.MarginLeftRight) = .{},

    fn deinit(self: *Self, allocator: *Allocator) void {
        self.line_boxes.deinit(allocator);
        self.glyph_indeces.deinit(allocator);
        self.positions.deinit(allocator);
        self.measures_top.deinit(allocator);
        self.measures_right.deinit(allocator);
        self.measures_bottom.deinit(allocator);
        self.measures_left.deinit(allocator);
        self.heights.deinit(allocator);
        self.background_color.deinit(allocator);
        self.margins.deinit(allocator);
    }

    fn ensureCapacity(self: *Self, allocator: *Allocator, count: usize) !void {
        try self.line_boxes.ensureCapacity(allocator, count);
        try self.glyph_indeces.ensureCapacity(allocator, count);
        try self.positions.ensureCapacity(allocator, count);
        try self.measures_top.ensureCapacity(allocator, count);
        try self.measures_right.ensureCapacity(allocator, count);
        try self.measures_bottom.ensureCapacity(allocator, count);
        try self.measures_left.ensureCapacity(allocator, count);
        try self.heights.ensureCapacity(allocator, count);
        try self.background_color.ensureCapacity(allocator, count);
        try self.margins.ensureCapacity(allocator, count);
    }

    fn toNormalData(self: *Self, allocator: *Allocator) InlineRenderingContext {
        self.margins.deinit(allocator);
        return InlineRenderingContext{
            .line_boxes = self.line_boxes.toOwnedSlice(allocator),
            .glyph_indeces = self.glyph_indeces.toOwnedSlice(allocator),
            .positions = self.positions.toOwnedSlice(allocator),
            .font = self.font,
            .measures_top = self.measures_top.toOwnedSlice(allocator),
            .measures_right = self.measures_right.toOwnedSlice(allocator),
            .measures_bottom = self.measures_bottom.toOwnedSlice(allocator),
            .measures_left = self.measures_left.toOwnedSlice(allocator),
            .heights = self.heights.toOwnedSlice(allocator),
            .background_color = self.background_color.toOwnedSlice(allocator),
        };
    }
};

pub const InlineContext = struct {
    box_tree: *const BoxTree,
    intervals: ArrayListUnmanaged(Interval),
    used_ids: ArrayListUnmanaged(u16),
    allocator: *Allocator,
    block_container_interval: Interval,
    containing_block_inline_size: CSSUnit,

    total_block_size: CSSUnit = undefined,
    next_box_id: u16 = undefined,

    const Self = @This();

    pub fn init(box_tree: *const BoxTree, allocator: *Allocator, block_container_interval: Interval, containing_block_inline_size: CSSUnit) Self {
        return Self{
            .box_tree = box_tree,
            .intervals = .{},
            .used_ids = .{},
            .allocator = allocator,
            .block_container_interval = block_container_interval,
            .containing_block_inline_size = containing_block_inline_size,
        };
    }

    pub fn deinit(self: *Self) void {
        self.intervals.deinit(self.allocator);
        self.used_ids.deinit(self.allocator);
    }
};

pub fn createInlineUsedData(context: *InlineContext, allocator: *Allocator) !InlineRenderingContext {
    const root_interval = context.block_container_interval;

    var data = IntermediateInlineUsedData{};
    errdefer data.deinit(allocator);
    try data.ensureCapacity(allocator, root_interval.end - root_interval.begin + 1);

    // TODO delete this font stuff
    const font = context.box_tree.font;
    data.font = font.font.?;

    const root_used_id = try addRootInlineBox(&data, allocator);
    try addBoxStart(&data, allocator, root_used_id);

    if (root_interval.begin != root_interval.end) {
        try context.intervals.append(context.allocator, root_interval);
        try context.used_ids.append(context.allocator, root_used_id);
    } else {
        try addBoxEnd(&data, allocator, root_used_id);
    }

    while (context.intervals.items.len > 0) {
        const interval = &context.intervals.items[context.intervals.items.len - 1];
        if (interval.begin == interval.end) {
            const used_id = context.used_ids.items[context.used_ids.items.len - 1];
            try addBoxEnd(&data, allocator, used_id);
            if (context.intervals.items.len == 1) {
                context.next_box_id = interval.end;
            }

            _ = context.intervals.pop();
            _ = context.used_ids.pop();
        } else {
            const original_id = interval.begin;
            const subtree_size = context.box_tree.preorder_array[original_id];
            interval.begin += subtree_size;

            switch (context.box_tree.display[original_id]) {
                .inline_flow => {
                    const used_id = try addInlineElementData(context.box_tree, &data, allocator, original_id, context.containing_block_inline_size);
                    try addBoxStart(&data, allocator, used_id);

                    if (subtree_size != 1) {
                        try context.intervals.append(context.allocator, Interval{ .begin = original_id + 1, .end = original_id + subtree_size });
                        try context.used_ids.append(context.allocator, used_id);
                    } else {
                        try addBoxEnd(&data, allocator, used_id);
                    }
                },
                .text => try addText(&data, allocator, context.box_tree.latin1_text[original_id], font),
                .block_flow, .block_flow_root => {
                    // Immediately finish off this group of inline elements.
                    var i: usize = context.used_ids.items.len;
                    while (i > 0) : (i -= 1) {
                        try addBoxEnd(&data, allocator, context.used_ids.items[i - 1]);
                    }
                    context.next_box_id = original_id;
                    break;
                },
                .none => continue,
                .initial, .inherit, .unset => unreachable,
            }
        }
    }

    context.total_block_size = try splitIntoLineBoxes(&data, allocator, data.font, context.containing_block_inline_size);

    return data.toNormalData(allocator);
}

fn addText(data: *IntermediateInlineUsedData, allocator: *Allocator, latin1_text: computed.Latin1Text, font: computed.Font) Allocator.Error!void {
    const buffer = hb.hb_buffer_create() orelse unreachable;
    defer hb.hb_buffer_destroy(buffer);
    if (hb.hb_buffer_allocation_successful(buffer) == 0) return error.OutOfMemory;

    hb.hb_buffer_add_utf8(buffer, latin1_text.text.ptr, @intCast(c_int, latin1_text.text.len), 0, @intCast(c_int, latin1_text.text.len));
    // TODO assuming ltr direction
    hb.hb_buffer_set_direction(buffer, hb.hb_direction_t.HB_DIRECTION_LTR);
    hb.hb_buffer_set_script(buffer, hb.hb_script_t.HB_SCRIPT_LATIN);
    hb.hb_buffer_set_language(buffer, hb.hb_language_from_string("en", -1));
    hb.hb_shape(font.font.?, buffer, 0, 0);

    const glyph_infos = blk: {
        var n: c_uint = 0;
        const p = hb.hb_buffer_get_glyph_infos(buffer, &n);
        break :blk p[0..n];
    };
    const glyph_positions = blk: {
        var n: c_uint = 0;
        const p = hb.hb_buffer_get_glyph_positions(buffer, &n);
        break :blk p[0..n];
    };
    assert(glyph_infos.len == glyph_positions.len);
    var extents: hb.hb_glyph_extents_t = undefined;

    const old_len = data.glyph_indeces.items.len;
    // Allocate twice as much so that special indeces always have space
    try data.glyph_indeces.ensureCapacity(allocator, old_len + 2 * glyph_infos.len);
    try data.positions.ensureCapacity(allocator, old_len + 2 * glyph_infos.len);
    for (glyph_infos) |info, i| {
        const pos = glyph_positions[i];
        const extents_result = hb.hb_font_get_glyph_extents(font.font.?, info.codepoint, &extents);
        const width = if (extents_result != 0) extents.width else 0;
        data.glyph_indeces.appendAssumeCapacity(info.codepoint);
        data.positions.appendAssumeCapacity(InlineRenderingContext.Position{ .offset = @divFloor(pos.x_offset, 64), .advance = @divFloor(pos.x_advance, 64), .width = @divFloor(width, 64) });
        if (info.codepoint == InlineRenderingContext.special_index) {
            data.glyph_indeces.appendAssumeCapacity(InlineRenderingContext.encodeSpecial(.Literal_FFFF, undefined));
            data.positions.appendAssumeCapacity(undefined);
        }
    }
}

fn addBoxStart(data: *IntermediateInlineUsedData, allocator: *Allocator, result_id: u16) !void {
    const left = data.measures_left.items[result_id];
    const margin = data.margins.items[result_id].left;
    const width = left.border + left.padding + margin;
    try data.glyph_indeces.appendSlice(allocator, &[2]hb.hb_codepoint_t{ InlineRenderingContext.special_index, InlineRenderingContext.encodeSpecial(.BoxStart, result_id) });
    try data.positions.appendSlice(allocator, &[2]InlineRenderingContext.Position{ .{ .offset = 0, .advance = width, .width = width }, undefined });
}

fn addBoxEnd(data: *IntermediateInlineUsedData, allocator: *Allocator, result_id: u16) !void {
    const right = data.measures_right.items[result_id];
    const margin = data.margins.items[result_id].right;
    const width = right.border + right.padding + margin;
    try data.glyph_indeces.appendSlice(allocator, &[2]hb.hb_codepoint_t{ InlineRenderingContext.special_index, InlineRenderingContext.encodeSpecial(.BoxEnd, result_id) });
    try data.positions.appendSlice(allocator, &[2]InlineRenderingContext.Position{ .{ .offset = 0, .advance = width, .width = width }, undefined });
}

fn splitIntoLineBoxes(data: *IntermediateInlineUsedData, allocator: *Allocator, font: *hb.hb_font_t, containing_block_inline_size: CSSUnit) !CSSUnit {
    var font_extents: hb.hb_font_extents_t = undefined;
    // TODO assuming ltr direction
    assert(hb.hb_font_get_h_extents(font, &font_extents) != 0);
    const line_spacing = @divFloor(font_extents.ascender - font_extents.descender + font_extents.line_gap, 64);

    var cursor: CSSUnit = 0;
    var line_box = InlineRenderingContext.LineBox{ .baseline = @divFloor(font_extents.ascender, 64), .elements = [2]usize{ 0, 0 } };
    var i: usize = 0;
    while (i < data.glyph_indeces.items.len) : (i += 1) {
        const gi = data.glyph_indeces.items[i];
        const pos = data.positions.items[i];

        if (pos.width > 0 and cursor + pos.offset + pos.width > containing_block_inline_size and line_box.elements[1] - line_box.elements[0] > 0) {
            try data.line_boxes.append(allocator, line_box);
            cursor = 0;
            line_box = .{ .baseline = line_box.baseline + line_spacing, .elements = [2]usize{ line_box.elements[1], line_box.elements[1] } };
        }

        cursor += pos.advance;
        line_box.elements[1] += 1;

        if (gi == InlineRenderingContext.special_index) {
            i += 1;
            line_box.elements[1] += 1;
        }
    }

    try data.line_boxes.append(allocator, line_box);
    return line_box.baseline - @divFloor(font_extents.descender, 64);
}

fn addRootInlineBox(data: *IntermediateInlineUsedData, allocator: *Allocator) !u16 {
    try data.measures_top.append(allocator, .{ .border = 0, .padding = 0, .border_color_rgba = 0 });
    try data.measures_right.append(allocator, .{ .border = 0, .padding = 0, .border_color_rgba = 0 });
    try data.measures_bottom.append(allocator, .{ .border = 0, .padding = 0, .border_color_rgba = 0 });
    try data.measures_left.append(allocator, .{ .border = 0, .padding = 0, .border_color_rgba = 0 });
    try data.margins.append(allocator, .{ .left = 0, .right = 0 });
    try data.heights.append(allocator, undefined);
    try data.background_color.append(allocator, undefined);
    return 0;
}

fn addInlineElementData(box_tree: *const BoxTree, data: *IntermediateInlineUsedData, allocator: *Allocator, original_id: u16, containing_block_inline_size: CSSUnit) !u16 {
    const inline_sizes = box_tree.inline_size[original_id];

    const margin_inline_start = switch (inline_sizes.margin_start) {
        .px => |value| length(.px, value),
        .percentage => |value| percentage(value, containing_block_inline_size),
        .auto => 0,
        .initial, .inherit, .unset => unreachable,
    };
    const border_inline_start = lineWidth(inline_sizes.border_start_width);
    const padding_inline_start = switch (inline_sizes.padding_start) {
        .px => |value| length(.px, value),
        .percentage => |value| percentage(value, containing_block_inline_size),
        .initial, .inherit, .unset => unreachable,
    };
    const margin_inline_end = switch (inline_sizes.margin_end) {
        .px => |value| length(.px, value),
        .percentage => |value| percentage(value, containing_block_inline_size),
        .auto => 0,
        .initial, .inherit, .unset => unreachable,
    };
    const border_inline_end = lineWidth(inline_sizes.border_end_width);
    const padding_inline_end = switch (inline_sizes.padding_end) {
        .px => |value| length(.px, value),
        .percentage => |value| percentage(value, containing_block_inline_size),
        .initial, .inherit, .unset => unreachable,
    };

    const block_sizes = box_tree.block_size[original_id];

    const border_block_start = lineWidth(block_sizes.border_start_width);
    const padding_block_start = switch (block_sizes.padding_start) {
        .px => |value| length(.px, value),
        .percentage => |value| percentage(value, containing_block_inline_size),
        .initial, .inherit, .unset => unreachable,
    };
    const border_block_end = lineWidth(block_sizes.border_end_width);
    const padding_block_end = switch (block_sizes.padding_end) {
        .px => |value| length(.px, value),
        .percentage => |value| percentage(value, containing_block_inline_size),
        .initial, .inherit, .unset => unreachable,
    };

    // TODO using physical property when we should be using a logical one
    try data.measures_left.append(allocator, .{ .border = border_inline_start, .padding = padding_inline_start, .border_color_rgba = undefined });
    try data.measures_right.append(allocator, .{ .border = border_inline_end, .padding = padding_inline_end, .border_color_rgba = undefined });
    try data.measures_top.append(allocator, .{ .border = border_block_start, .padding = padding_block_start, .border_color_rgba = undefined });
    try data.measures_bottom.append(allocator, .{ .border = border_block_end, .padding = padding_block_end, .border_color_rgba = undefined });
    try data.margins.append(allocator, .{ .left = margin_inline_start, .right = margin_inline_end });
    try data.heights.append(allocator, undefined);
    try data.background_color.append(allocator, undefined);
    return std.math.cast(u16, data.measures_left.items.len - 1);
}

test "inline used data" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.testing.expect(!gpa.deinit());
    const al = &gpa.allocator;

    const blob = hb.hb_blob_create_from_file("test/fonts/NotoSans-Regular.ttf");
    defer hb.hb_blob_destroy(blob);
    if (blob == hb.hb_blob_get_empty()) return error.HarfBuzzError;

    const face = hb.hb_face_create(blob, 0);
    defer hb.hb_face_destroy(face);
    if (face == hb.hb_face_get_empty()) return error.HarfBuzzError;

    const hb_font = hb.hb_font_create(face);
    defer hb.hb_font_destroy(hb_font);
    if (hb_font == hb.hb_font_get_empty()) return error.HarfBuzzError;
    hb.hb_font_set_scale(hb_font, 40 * 64, 40 * 64);

    const len = 5;
    var preorder_array = [len]u16{ 5, 1, 1, 1, 1 };
    var inline_size = [len]computed.LogicalSize{
        .{},
        .{ .border_start_width = .{ .px = 10 }, .border_end_width = .{ .px = 40 } },
        .{},
        .{ .border_start_width = .{ .px = 30 }, .border_end_width = .{ .px = 40 } },
        .{},
    };
    var block_size = [_]computed.LogicalSize{.{}} ** len;
    var display = [len]computed.Display{ .{ .block_flow_root = {} }, .{ .inline_flow = {} }, .{ .text = {} }, .{ .inline_flow = {} }, .{ .block_flow = {} } };
    var position_inset = [_]computed.PositionInset{.{}} ** len;
    var latin1_text = [_]computed.Latin1Text{.{ .text = "" }} ** len;
    latin1_text[2] = .{ .text = "hello world" };
    var font = computed.Font{ .font = hb_font };
    const tree = BoxTree{
        .preorder_array = &preorder_array,
        .inline_size = &inline_size,
        .block_size = &block_size,
        .display = &display,
        .position_inset = &position_inset,
        .latin1_text = &latin1_text,
        .font = font,
    };
    //const viewport_rect = CSSSize{ .w = 50, .h = 400 };

    var context = InlineContext.init(&tree, al, Interval{ .begin = 1, .end = preorder_array[0] }, 50);
    defer context.deinit();
    var data = try createInlineUsedData(&context, al);
    defer data.deinit(al);

    {
        const p = std.debug.print;
        p("\n", .{});
        p("glyphs\n", .{});
        var i: usize = 0;
        while (i < data.glyph_indeces.len) : (i += 1) {
            const gi = data.glyph_indeces[i];
            if (gi == InlineRenderingContext.special_index) {
                i += 1;
                p("{}\n", .{InlineRenderingContext.decodeSpecial(data.glyph_indeces[i])});
            } else {
                p("{x}\n", .{gi});
            }
        }
        p("\n", .{});
        p("positions\n", .{});
        for (data.positions) |pos| {
            p("{}\n", .{pos});
        }
        p("\n", .{});
        p("line boxes\n", .{});
        for (data.line_boxes) |l| {
            p("{}\n", .{l});
        }
    }
}
