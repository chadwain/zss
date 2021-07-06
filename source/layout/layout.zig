const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const assert = std.debug.assert;

const zss = @import("../../zss.zig");
const BoxTree = zss.BoxTree;
const BoxId = BoxTree.BoxId;

const used_values = @import("./used_values.zig");
const ZssUnit = used_values.ZssUnit;
const unitsPerPixel = used_values.unitsPerPixel;
const UsedId = used_values.UsedId;
const BlockLevelUsedValues = used_values.BlockLevelUsedValues;
const InlineLevelUsedValues = used_values.InlineLevelUsedValues;
const Document = used_values.Document;

const hb = @import("harfbuzz");

pub const Error = error{
    InvalidValue,
    OutOfMemory,
    Overflow,
};

pub fn doLayout(box_tree: *const BoxTree, allocator: *Allocator, document_width: ZssUnit, document_height: ZssUnit) Error!Document {
    var context = try BlockLevelLayoutContext.init(box_tree, allocator, 0, document_width, document_height);
    defer context.deinit();
    return Document{ .block_values = try createBlockLevelUsedValues(&context, allocator) };
}

const LengthUnit = enum { px };

fn length(comptime unit: LengthUnit, value: f32) ZssUnit {
    return switch (unit) {
        .px => @floatToInt(ZssUnit, @round(value * unitsPerPixel)),
    };
}

fn percentage(value: f32, unit: ZssUnit) ZssUnit {
    return @floatToInt(ZssUnit, @round(@intToFloat(f32, unit) * value));
}

const UsedIdAndSubtreeSize = struct {
    used_id: UsedId,
    used_subtree_size: UsedId,
};

const UsedBlockSizes = struct {
    size: ?ZssUnit,
    min_size: ZssUnit,
    max_size: ZssUnit,
    margin_start: ZssUnit,
    margin_end: ZssUnit,
};

//const InFlowInsets = struct {
//    const BlockInset = union(enum) {
//        /// A used length value.
//        length: ZssUnit,
//        /// A computed percentage value.
//        percentage: f32,
//    };
//    inline_axis: ZssUnit,
//    block_axis: BlockInset,
//};
//
//const InFlowPositioningData = struct {
//    insets: InFlowInsets,
//    used_id: UsedId,
//};

const BlockLevelLayoutContext = struct {
    const Self = @This();

    const Interval = struct {
        parent: BoxId,
        begin: BoxId,
        end: BoxId,
    };

    box_tree: *const BoxTree,
    root_box_id: BoxId,
    allocator: *Allocator,
    intervals: ArrayListUnmanaged(Interval),
    used_id_and_subtree_size: ArrayListUnmanaged(UsedIdAndSubtreeSize),
    static_containing_block_used_inline_size: ArrayListUnmanaged(ZssUnit),
    static_containing_block_auto_block_size: ArrayListUnmanaged(ZssUnit),
    static_containing_block_used_block_sizes: ArrayListUnmanaged(UsedBlockSizes),
    //in_flow_positioning_data: ArrayListUnmanaged(InFlowPositioningData),
    //in_flow_positioning_data_count: ArrayListUnmanaged(UsedId),

    fn init(box_tree: *const BoxTree, allocator: *Allocator, root_box_id: BoxId, containing_block_inline_size: ZssUnit, containing_block_block_size: ?ZssUnit) !Self {
        //var in_flow_positioning_data_count = ArrayListUnmanaged(UsedId){};
        //errdefer in_flow_positioning_data_count.deinit(allocator);
        //try in_flow_positioning_data_count.append(allocator, 0);

        var used_id_and_subtree_size = ArrayListUnmanaged(UsedIdAndSubtreeSize){};
        errdefer used_id_and_subtree_size.deinit(allocator);
        try used_id_and_subtree_size.append(allocator, UsedIdAndSubtreeSize{
            .used_id = undefined,
            .used_subtree_size = 1,
        });

        var static_containing_block_used_inline_size = ArrayListUnmanaged(ZssUnit){};
        errdefer static_containing_block_used_inline_size.deinit(allocator);
        try static_containing_block_used_inline_size.append(allocator, containing_block_inline_size);

        var static_containing_block_auto_block_size = ArrayListUnmanaged(ZssUnit){};
        errdefer static_containing_block_auto_block_size.deinit(allocator);
        try static_containing_block_auto_block_size.append(allocator, 0);

        var static_containing_block_used_block_sizes = ArrayListUnmanaged(UsedBlockSizes){};
        errdefer static_containing_block_used_block_sizes.deinit(allocator);
        try static_containing_block_used_block_sizes.append(allocator, UsedBlockSizes{
            .size = containing_block_block_size,
            .min_size = 0,
            .max_size = 0,
            .margin_start = 0,
            .margin_end = 0,
        });

        return Self{
            .box_tree = box_tree,
            .root_box_id = root_box_id,
            .allocator = allocator,
            .intervals = .{},
            .used_id_and_subtree_size = used_id_and_subtree_size,
            .static_containing_block_used_inline_size = static_containing_block_used_inline_size,
            .static_containing_block_auto_block_size = static_containing_block_auto_block_size,
            .static_containing_block_used_block_sizes = static_containing_block_used_block_sizes,
            //.in_flow_positioning_data = .{},
            //.in_flow_positioning_data_count = in_flow_positioning_data_count,
        };
    }

    fn deinit(self: *Self) void {
        self.intervals.deinit(self.allocator);
        self.used_id_and_subtree_size.deinit(self.allocator);
        self.static_containing_block_used_inline_size.deinit(self.allocator);
        self.static_containing_block_auto_block_size.deinit(self.allocator);
        self.static_containing_block_used_block_sizes.deinit(self.allocator);
        //self.in_flow_positioning_data.deinit(self.allocator);
        //self.in_flow_positioning_data_count.deinit(self.allocator);
    }
};

const IntermediateBlockLevelUsedValues = struct {
    const Self = @This();

    allocator: *Allocator,
    structure: ArrayListUnmanaged(UsedId) = .{},
    box_offsets: ArrayListUnmanaged(used_values.BoxOffsets) = .{},
    borders: ArrayListUnmanaged(used_values.Borders) = .{},
    border_colors: ArrayListUnmanaged(used_values.BorderColor) = .{},
    background1: ArrayListUnmanaged(used_values.Background1) = .{},
    background2: ArrayListUnmanaged(used_values.Background2) = .{},
    //visual_effect: ArrayListUnmanaged(used_values.VisualEffect) = .{},
    inline_values: ArrayListUnmanaged(BlockLevelUsedValues.InlineValues) = .{},

    fn deinit(self: *Self) void {
        self.structure.deinit(self.allocator);
        self.box_offsets.deinit(self.allocator);
        self.borders.deinit(self.allocator);
        self.border_colors.deinit(self.allocator);
        self.background1.deinit(self.allocator);
        self.background2.deinit(self.allocator);
        //self.visual_effect.deinit(self.allocator);
        for (self.inline_values.items) |*inl| {
            inl.values.deinit(self.allocator);
            self.allocator.destroy(inl.values);
        }
        self.inline_values.deinit(self.allocator);
    }

    fn ensureCapacity(self: *Self, capacity: usize) !void {
        try self.structure.ensureCapacity(self.allocator, capacity);
        try self.box_offsets.ensureCapacity(self.allocator, capacity);
        try self.borders.ensureCapacity(self.allocator, capacity);
        try self.border_colors.ensureCapacity(self.allocator, capacity);
        try self.background1.ensureCapacity(self.allocator, capacity);
        try self.background2.ensureCapacity(self.allocator, capacity);
        //try self.visual_effect.ensureCapacity(self.allocator, capacity);
    }

    fn toBlockLevelUsedValues(self: *Self) BlockLevelUsedValues {
        return BlockLevelUsedValues{
            .structure = self.structure.toOwnedSlice(self.allocator),
            .box_offsets = self.box_offsets.toOwnedSlice(self.allocator),
            .borders = self.borders.toOwnedSlice(self.allocator),
            .border_colors = self.border_colors.toOwnedSlice(self.allocator),
            .background1 = self.background1.toOwnedSlice(self.allocator),
            .background2 = self.background2.toOwnedSlice(self.allocator),
            //.visual_effect = self.visual_effect.toOwnedSlice(self.allocator),
            .inline_values = self.inline_values.toOwnedSlice(self.allocator),
        };
    }
};

fn createBlockLevelUsedValues(context: *BlockLevelLayoutContext, values_allocator: *Allocator) Error!BlockLevelUsedValues {
    const root_box_id = context.root_box_id;
    const root_subtree_size = context.box_tree.structure[root_box_id];
    var root_interval = BlockLevelLayoutContext.Interval{ .parent = root_box_id, .begin = root_box_id, .end = root_box_id + root_subtree_size };

    var values = IntermediateBlockLevelUsedValues{ .allocator = values_allocator };
    errdefer values.deinit();
    values.ensureCapacity(root_subtree_size) catch {};

    try blockLevelElementPush(context, &values, &root_interval);

    while (context.intervals.items.len > 0) {
        const interval = &context.intervals.items[context.intervals.items.len - 1];
        if (interval.begin != interval.end) {
            try blockLevelElementPush(context, &values, interval);
        } else {
            blockLevelElementPop(context, &values, interval.*);
        }
    }

    { // Finish layout for the root element.
        var box_offsets = used_values.BoxOffsets{
            .border_start = .{ .inline_dir = 0, .block_dir = 0 },
            .border_end = .{ .inline_dir = 0, .block_dir = 0 },
            .content_start = .{ .inline_dir = 0, .block_dir = 0 },
            .content_end = .{ .inline_dir = 0, .block_dir = 0 },
        };
        var parent_auto_block_size = @as(ZssUnit, 0);
        blockContainerFinishLayout(context, &values, &box_offsets, &parent_auto_block_size);
    }

    return values.toBlockLevelUsedValues();
}

fn blockLevelElementPush(context: *BlockLevelLayoutContext, values: *IntermediateBlockLevelUsedValues, interval: *BlockLevelLayoutContext.Interval) !void {
    switch (context.box_tree.display[interval.begin]) {
        .block => return blockContainerSolveSizeAndPositionPart1(context, values, interval),
        .inline_, .text => return blockLevelAddInlineData(context, values, interval),
        .none => return blockLevelAddNone(context, interval),
    }
}

fn blockLevelElementPop(context: *BlockLevelLayoutContext, values: *IntermediateBlockLevelUsedValues, interval: BlockLevelLayoutContext.Interval) void {
    const id_subtree_size = context.used_id_and_subtree_size.items[context.used_id_and_subtree_size.items.len - 1];
    const used_id = id_subtree_size.used_id;
    const used_subtree_size = id_subtree_size.used_subtree_size;
    values.structure.items[used_id] = used_subtree_size;
    context.used_id_and_subtree_size.items[context.used_id_and_subtree_size.items.len - 2].used_subtree_size += used_subtree_size;

    const box_offsets_ptr = &values.box_offsets.items[used_id];
    const parent_auto_block_size = &context.static_containing_block_auto_block_size.items[context.static_containing_block_auto_block_size.items.len - 2];
    blockContainerFinishLayout(context, values, box_offsets_ptr, parent_auto_block_size);
    blockContainerSolveOtherProperties(context, values, interval.parent, used_id);

    _ = context.intervals.pop();
    _ = context.used_id_and_subtree_size.pop();
    _ = context.static_containing_block_used_inline_size.pop();
    _ = context.static_containing_block_auto_block_size.pop();
    _ = context.static_containing_block_used_block_sizes.pop();
    //const in_flow_positioning_data_count = context.in_flow_positioning_data_count.pop();
    //context.in_flow_positioning_data.shrinkRetainingCapacity(context.in_flow_positioning_data.items.len - in_flow_positioning_data_count);
}

fn blockContainerSolveSizeAndPositionPart1(context: *BlockLevelLayoutContext, values: *IntermediateBlockLevelUsedValues, interval: *BlockLevelLayoutContext.Interval) !void {
    const box_id = interval.begin;
    const subtree_size = context.box_tree.structure[box_id];
    interval.begin += subtree_size;

    const used_id = try std.math.cast(UsedId, values.structure.items.len);

    //const position_inset = &context.box_tree.position_inset[box_id];
    //switch (position_inset.position) {
    //    .static => {},
    //    .relative => {
    //        const insets = resolveRelativePositionInset(context, position_inset);
    //        // TODO Only need to do this if the block inset is a percentage value,
    //        // otherwise we can just apply the positioning immediately
    //        try context.in_flow_positioning_data.append(context.allocator, InFlowPositioningData{
    //            .insets = insets,
    //            .used_id = used_id,
    //        });
    //        context.in_flow_positioning_data_count.items[context.in_flow_positioning_data_count.items.len - 1] += 1;
    //    },
    //}

    const structure_ptr = try values.structure.addOne(values.allocator);
    const box_offsets_ptr = try values.box_offsets.addOne(values.allocator);
    const borders_ptr = try values.borders.addOne(values.allocator);
    const inline_size = try blockContainerSolveInlineSizesAndOffsets(context, box_id, box_offsets_ptr, borders_ptr);
    const used_block_sizes = try blockContainerSolveBlockSizesAndOffsets(context, box_id, box_offsets_ptr, borders_ptr);

    _ = try values.border_colors.addOne(values.allocator);
    _ = try values.background1.addOne(values.allocator);
    _ = try values.background2.addOne(values.allocator);
    //_ = try values.visual_effect.addOne(values.allocator);

    if (subtree_size != 1) {
        try context.intervals.append(context.allocator, .{ .parent = box_id, .begin = box_id + 1, .end = box_id + subtree_size });
        try context.static_containing_block_used_inline_size.append(context.allocator, inline_size);
        try context.static_containing_block_auto_block_size.append(context.allocator, 0);
        try context.static_containing_block_used_block_sizes.append(context.allocator, used_block_sizes);
        try context.used_id_and_subtree_size.append(context.allocator, UsedIdAndSubtreeSize{ .used_id = used_id, .used_subtree_size = 1 });
        //try context.in_flow_positioning_data_count.append(context.allocator, 0);
    } else {
        // Optimized path for elements that have no children. It is like a shorter version of blockLevelElementPop.
        structure_ptr.* = 1;
        context.used_id_and_subtree_size.items[context.used_id_and_subtree_size.items.len - 1].used_subtree_size += 1;
        const parent_auto_block_size = &context.static_containing_block_auto_block_size.items[context.static_containing_block_auto_block_size.items.len - 1];
        blockContainerSolveSizeAndPositionPart2(box_offsets_ptr, used_block_sizes, 0, parent_auto_block_size);
        blockContainerSolveOtherProperties(context, values, box_id, used_id);
    }
}

fn blockContainerFinishLayout(context: *BlockLevelLayoutContext, values: *IntermediateBlockLevelUsedValues, box_offsets: *used_values.BoxOffsets, parent_auto_block_size: *ZssUnit) void {
    const used_block_sizes = context.static_containing_block_used_block_sizes.items[context.static_containing_block_used_block_sizes.items.len - 1];
    const auto_block_size = context.static_containing_block_auto_block_size.items[context.static_containing_block_auto_block_size.items.len - 1];
    blockContainerSolveSizeAndPositionPart2(box_offsets, used_block_sizes, auto_block_size, parent_auto_block_size);
    //applyInFlowPositioningToChildren(context, values.box_offsets.items, sizes.used_block_size);
}

fn blockContainerSolveSizeAndPositionPart2(box_offsets: *used_values.BoxOffsets, used_block_sizes: UsedBlockSizes, auto_block_size: ZssUnit, parent_auto_block_size: *ZssUnit) void {
    const used_block_size = zss.util.clamp(used_block_sizes.size orelse auto_block_size, used_block_sizes.min_size, used_block_sizes.max_size);
    box_offsets.border_start.block_dir = parent_auto_block_size.* + used_block_sizes.margin_start;
    box_offsets.content_start.block_dir += box_offsets.border_start.block_dir;
    box_offsets.content_end.block_dir = box_offsets.content_start.block_dir + used_block_size;
    box_offsets.border_end.block_dir += box_offsets.content_end.block_dir;
    parent_auto_block_size.* = box_offsets.border_end.block_dir + used_block_sizes.margin_end;
}

fn blockContainerSolveOtherProperties(context: *BlockLevelLayoutContext, values: *IntermediateBlockLevelUsedValues, box_id: BoxId, used_id: UsedId) void {
    const box_offsets_ptr = &values.box_offsets.items[used_id];
    const borders_ptr = &values.borders.items[used_id];

    const border_colors_ptr = &values.border_colors.items[used_id];
    border_colors_ptr.* = solveBorderColors(context.box_tree.border[box_id]);

    const background1_ptr = &values.background1.items[used_id];
    const background2_ptr = &values.background2.items[used_id];
    const background = context.box_tree.background[box_id];
    background1_ptr.* = solveBackground1(background);
    background2_ptr.* = solveBackground2(background, box_offsets_ptr, borders_ptr);

    //const visual_effect_ptr = &values.visual_effect.items[used_id];
    //// TODO fill in all this values
    //visual_effect_ptr.* = .{};
}

//fn applyInFlowPositioningToChildren(context: *const BlockLevelLayoutContext, box_offsets: []used_values.BoxOffsets, containing_block_block_size: ZssUnit) void {
//    const count = context.in_flow_positioning_data_count.items[context.in_flow_positioning_data_count.items.len - 1];
//    var i: UsedId = 0;
//    while (i < count) : (i += 1) {
//        const positioning_data = context.in_flow_positioning_data.items[context.in_flow_positioning_data.items.len - 1 - i];
//        const positioning_offset = zss.types.ZssVector{
//            // TODO assuming a 'horizontal-tb' value for the 'writing-mode' property
//            .x = positioning_data.insets.inline_axis,
//            // TODO assuming a 'horizontal-tb' value for the 'writing-mode' property
//            .y = switch (positioning_data.insets.block_axis) {
//                .length => |l| l,
//                .percentage => |value| percentage(value, containing_block_block_size),
//            },
//        };
//        const box_offset = &box_offsets[positioning_data.used_id];
//        inline for (std.meta.fields(used_values.BoxOffsets)) |field| {
//            const offset = &@field(box_offset, field.name);
//            offset.* = offset.add(positioning_offset);
//        }
//    }
//}
//
//fn resolveRelativePositionInset(context: *BlockLevelLayoutContext, position_inset: *BoxTree.PositionInset) InFlowInsets {
//    const containing_block_inline_size = context.static_containing_block_used_inline_size.items[context.static_containing_block_used_inline_size.items.len - 1];
//    const containing_block_block_size = context.static_containing_block_used_block_sizes.items[context.static_containing_block_used_block_sizes.items.len - 1].size;
//    const inline_start = switch (position_inset.inline_start) {
//        .px => |value| length(.px, value),
//        .percentage => |value| percentage(value, containing_block_inline_size),
//        .auto => null,
//    };
//    const inline_end = switch (position_inset.inline_end) {
//        .px => |value| -length(.px, value),
//        .percentage => |value| -percentage(value, containing_block_inline_size),
//        .auto => null,
//    };
//    const block_start: ?InFlowInsets.BlockInset = switch (position_inset.block_start) {
//        .px => |value| InFlowInsets.BlockInset{ .length = length(.px, value) },
//        .percentage => |value| if (containing_block_block_size) |s|
//            InFlowInsets.BlockInset{ .length = percentage(value, s) }
//        else
//            InFlowInsets.BlockInset{ .percentage = value },
//        .auto => null,
//    };
//    const block_end: ?InFlowInsets.BlockInset = switch (position_inset.block_end) {
//        .px => |value| InFlowInsets.BlockInset{ .length = -length(.px, value) },
//        .percentage => |value| if (containing_block_block_size) |s|
//            InFlowInsets.BlockInset{ .length = -percentage(value, s) }
//        else
//            InFlowInsets.BlockInset{ .percentage = -value },
//        .auto => null,
//    };
//    return InFlowInsets{
//        .inline_axis = inline_start orelse inline_end orelse 0,
//        .block_axis = block_start orelse block_end orelse InFlowInsets.BlockInset{ .length = 0 },
//    };
//}

/// This is an implementation of CSS2§10.2 and CSS2§10.3.3.
fn blockContainerSolveInlineSizesAndOffsets(context: *const BlockLevelLayoutContext, box_id: BoxId, box_offsets: *used_values.BoxOffsets, borders: *used_values.Borders) !ZssUnit {
    const max = std.math.max;
    const inline_size = context.box_tree.inline_size[box_id];
    const containing_block_inline_size = context.static_containing_block_used_inline_size.items[context.static_containing_block_used_inline_size.items.len - 1];

    const border_start = switch (inline_size.border_start) {
        .px => |value| length(.px, value),
    };
    const border_end = switch (inline_size.border_end) {
        .px => |value| length(.px, value),
    };
    const padding_start = switch (inline_size.padding_start) {
        .px => |value| length(.px, value),
        .percentage => |value| percentage(value, containing_block_inline_size),
    };
    const padding_end = switch (inline_size.padding_end) {
        .px => |value| length(.px, value),
        .percentage => |value| percentage(value, containing_block_inline_size),
    };

    const min_size = switch (inline_size.min_size) {
        .px => |value| length(.px, value),
        .percentage => |value| percentage(value, max(0, containing_block_inline_size)),
    };
    const max_size = switch (inline_size.max_size) {
        .px => |value| length(.px, value),
        .percentage => |value| percentage(value, max(0, containing_block_inline_size)),
        .none => std.math.maxInt(ZssUnit),
    };

    var auto_bitfield: u3 = 0;
    const size_bit = 4;
    const margin_start_bit = 2;
    const margin_end_bit = 1;

    var size = switch (inline_size.size) {
        .px => |value| length(.px, value),
        .percentage => |value| percentage(value, containing_block_inline_size),
        .auto => blk: {
            auto_bitfield |= size_bit;
            break :blk 0;
        },
    };
    var margin_start = switch (inline_size.margin_start) {
        .px => |value| length(.px, value),
        .percentage => |value| percentage(value, containing_block_inline_size),
        .auto => blk: {
            auto_bitfield |= margin_start_bit;
            break :blk 0;
        },
    };
    var margin_end = switch (inline_size.margin_end) {
        .px => |value| length(.px, value),
        .percentage => |value| percentage(value, containing_block_inline_size),
        .auto => blk: {
            auto_bitfield |= margin_end_bit;
            break :blk 0;
        },
    };

    if (border_start < 0) return error.InvalidValue;
    if (border_end < 0) return error.InvalidValue;
    if (padding_start < 0) return error.InvalidValue;
    if (padding_end < 0) return error.InvalidValue;
    if (size < 0) return error.InvalidValue;
    if (min_size < 0) return error.InvalidValue;
    if (max_size < 0) return error.InvalidValue;

    const content_margin_space = containing_block_inline_size - (border_start + border_end + padding_start + padding_end);
    if (auto_bitfield == 0) {
        // None of the values were auto, so one of the margins must be set according to the other values.
        // TODO the margin that gets set is determined by the 'direction' property
        size = zss.util.clamp(size, min_size, max_size);
        margin_end = content_margin_space - size - margin_start;
    } else if (auto_bitfield & size_bit == 0) {
        // 'width' is not auto, but at least one of 'margin-start' and 'margin-end' is.
        // If there is only one "auto", then that value gets the remaining margin space.
        // Else, there are 2 "auto"s, and both values get half the remaining margin space.
        const start = auto_bitfield & margin_start_bit;
        const end = auto_bitfield & margin_end_bit;
        const shr_amount = @boolToInt(start | end == margin_start_bit | margin_end_bit);
        size = zss.util.clamp(size, min_size, max_size);
        const leftover_margin = max(0, content_margin_space - (size + margin_start + margin_end));
        // TODO the margin that gets the extra 1 unit shall be determined by the 'direction' property
        if (start == 0) margin_start = leftover_margin >> shr_amount;
        if (end == 0) margin_end = (leftover_margin >> shr_amount) + @mod(leftover_margin, 2);
    } else {
        // 'width' is auto, so it is set according to the other values.
        // The margin values don't need to change.
        size = zss.util.clamp(content_margin_space - margin_start - margin_end, min_size, max_size);
    }

    box_offsets.border_start.inline_dir = margin_start;
    box_offsets.content_start.inline_dir = box_offsets.border_start.inline_dir + border_start + padding_start;
    box_offsets.content_end.inline_dir = box_offsets.content_start.inline_dir + size;
    box_offsets.border_end.inline_dir = box_offsets.content_end.inline_dir + padding_end + border_end;

    borders.inline_start = border_start;
    borders.inline_end = border_end;

    return size;
}

/// This is an implementation of CSS2§10.5 and CSS2§10.6.3.
fn blockContainerSolveBlockSizesAndOffsets(context: *const BlockLevelLayoutContext, box_id: BoxId, box_offsets: *used_values.BoxOffsets, borders: *used_values.Borders) !UsedBlockSizes {
    const block_size = context.box_tree.block_size[box_id];
    const containing_block_inline_size = context.static_containing_block_used_inline_size.items[context.static_containing_block_used_inline_size.items.len - 1];
    const containing_block_block_size = context.static_containing_block_used_block_sizes.items[context.static_containing_block_used_block_sizes.items.len - 1].size;

    const size = switch (block_size.size) {
        .px => |value| length(.px, value),
        .percentage => |value| if (containing_block_block_size) |s|
            percentage(value, s)
        else
            null,
        .auto => null,
    };
    const border_start = switch (block_size.border_start) {
        .px => |value| length(.px, value),
    };
    const border_end = switch (block_size.border_end) {
        .px => |value| length(.px, value),
    };
    const padding_start = switch (block_size.padding_start) {
        .px => |value| length(.px, value),
        .percentage => |value| percentage(value, containing_block_inline_size),
    };
    const padding_end = switch (block_size.padding_end) {
        .px => |value| length(.px, value),
        .percentage => |value| percentage(value, containing_block_inline_size),
    };
    const margin_start = switch (block_size.margin_start) {
        .px => |value| length(.px, value),
        .percentage => |value| percentage(value, containing_block_inline_size),
        .auto => 0,
    };
    const margin_end = switch (block_size.margin_end) {
        .px => |value| length(.px, value),
        .percentage => |value| percentage(value, containing_block_inline_size),
        .auto => 0,
    };

    const min_size = switch (block_size.min_size) {
        .px => |value| length(.px, value),
        .percentage => |value| if (containing_block_block_size) |s|
            percentage(value, s)
        else
            0,
    };
    const max_size = switch (block_size.max_size) {
        .px => |value| length(.px, value),
        .percentage => |value| if (containing_block_block_size) |s|
            percentage(value, s)
        else
            std.math.maxInt(ZssUnit),
        .none => std.math.maxInt(ZssUnit),
    };

    if (border_start < 0) return error.InvalidValue;
    if (border_end < 0) return error.InvalidValue;
    if (padding_start < 0) return error.InvalidValue;
    if (padding_end < 0) return error.InvalidValue;
    if (size) |s| if (s < 0) return error.InvalidValue;
    if (min_size < 0) return error.InvalidValue;
    if (max_size < 0) return error.InvalidValue;

    // NOTE These are not the actual offsets, just some values that can be
    // determined without knowing 'size'. The offsets are properly filled in
    // in 'blockContainerSolveSizeAndPositionPart2'.
    box_offsets.content_start.block_dir = border_start + padding_start;
    box_offsets.border_end.block_dir = padding_end + border_end;

    borders.block_start = border_start;
    borders.block_end = border_end;

    return UsedBlockSizes{
        .size = size,
        .min_size = min_size,
        .max_size = max_size,
        .margin_start = margin_start,
        .margin_end = margin_end,
    };
}

fn blockLevelAddInlineData(context: *BlockLevelLayoutContext, values: *IntermediateBlockLevelUsedValues, interval: *BlockLevelLayoutContext.Interval) !void {
    const used_id = try std.math.cast(UsedId, values.structure.items.len);

    var inline_context = InlineLevelLayoutContext.init(
        context.box_tree,
        context.allocator,
        interval.*,
        context.static_containing_block_used_inline_size.items[context.static_containing_block_used_inline_size.items.len - 1],
    );
    defer inline_context.deinit();

    const inline_values_ptr = try values.allocator.create(InlineLevelUsedValues);
    errdefer values.allocator.destroy(inline_values_ptr);
    inline_values_ptr.* = try createInlineLevelUsedValues(&inline_context, values.allocator);
    errdefer inline_values_ptr.deinit(values.allocator);

    if (inline_context.next_box_id != interval.begin + context.box_tree.structure[interval.begin]) {
        @panic("TODO A group of inline-level elements cannot be interrupted by a block-level element");
    }
    interval.begin = inline_context.next_box_id;
    try values.inline_values.append(values.allocator, .{
        .id_of_containing_block = used_id,
        .values = inline_values_ptr,
    });

    context.used_id_and_subtree_size.items[context.used_id_and_subtree_size.items.len - 1].used_subtree_size += 1;
    const parent_auto_block_size = &context.static_containing_block_auto_block_size.items[context.static_containing_block_auto_block_size.items.len - 1];
    defer parent_auto_block_size.* += inline_context.total_block_size;

    // Create an "anonymous block box" to contain this inline formatting context.
    try values.structure.append(values.allocator, 1);
    try values.box_offsets.append(values.allocator, .{
        .border_start = .{ .inline_dir = 0, .block_dir = parent_auto_block_size.* },
        .border_end = .{ .inline_dir = 0, .block_dir = parent_auto_block_size.* },
        .content_start = .{ .inline_dir = 0, .block_dir = parent_auto_block_size.* },
        .content_end = .{ .inline_dir = 0, .block_dir = parent_auto_block_size.* },
    });
    try values.borders.append(values.allocator, .{});
    try values.border_colors.append(values.allocator, .{});
    try values.background1.append(values.allocator, .{});
    try values.background2.append(values.allocator, .{});
    //try values.visual_effect.append(allocator, .{});

}

fn blockLevelAddNone(context: *BlockLevelLayoutContext, interval: *BlockLevelLayoutContext.Interval) void {
    const box_id = interval.begin;
    interval.begin += context.box_tree.structure[box_id];
}

test "block used values" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer assert(!gpa.deinit());
    const al = &gpa.allocator;

    const len = 4;
    var structure = [len]BoxId{ 4, 2, 1, 1 };
    const inline_size_1 = BoxTree.LogicalSize{
        .size = .{ .percentage = 0.7 },
        .margin_start = .{ .px = 20 },
        .margin_end = .{ .px = 20 },
        .border_start = .{ .px = 5 },
        .border_end = .{ .px = 5 },
    };
    const inline_size_2 = BoxTree.LogicalSize{
        .margin_start = .{ .px = 20 },
        .border_start = .{ .px = 5 },
        .border_end = .{ .px = 5 },
    };
    const block_size_1 = BoxTree.LogicalSize{
        .size = .{ .percentage = 0.9 },
        .border_start = .{ .px = 5 },
        .border_end = .{ .px = 5 },
    };
    const block_size_2 = BoxTree.LogicalSize{
        .border_start = .{ .px = 5 },
        .border_end = .{ .px = 5 },
    };

    var inline_size = [len]BoxTree.LogicalSize{ inline_size_1, inline_size_2, inline_size_1, inline_size_1 };
    var block_size = [len]BoxTree.LogicalSize{ block_size_1, block_size_2, block_size_1, block_size_1 };
    var display = [len]BoxTree.Display{
        .{ .block = {} },
        .{ .block = {} },
        .{ .block = {} },
        .{ .block = {} },
    };
    //var position_inset = [len]BoxTree.PositionInset{
    //    .{ .position = .{ .relative = {} }, .inline_start = .{ .px = 100 } },
    //    .{},
    //    .{},
    //    .{},
    //};
    var latin1_text = [_]BoxTree.Latin1Text{.{ .text = "" }} ** len;
    var font = BoxTree.Font{ .font = hb.hb_font_get_empty().? };
    var border = [_]BoxTree.Border{.{}} ** len;
    var background = [_]BoxTree.Background{.{}} ** len;
    var context = try BlockLevelLayoutContext.init(
        &BoxTree{
            .structure = &structure,
            .inline_size = &inline_size,
            .block_size = &block_size,
            .display = &display,
            //.position_inset = &position_inset,
            .latin1_text = &latin1_text,
            .font = font,
            .border = &border,
            .background = &background,
        },
        al,
        0,
        400,
        400,
    );
    defer context.deinit();
    var values = try createBlockLevelUsedValues(&context, al);
    defer values.deinit(al);
}

const IntermediateInlineLevelUsedValues = struct {
    const Self = @This();
    const Margins = struct {
        start: ZssUnit = 0,
        end: ZssUnit = 0,
    };

    allocator: *Allocator,
    line_boxes: ArrayListUnmanaged(InlineLevelUsedValues.LineBox) = .{},
    glyph_indeces: ArrayListUnmanaged(hb.hb_codepoint_t) = .{},
    metrics: ArrayListUnmanaged(InlineLevelUsedValues.Metrics) = .{},
    font: *hb.hb_font_t = undefined,
    font_color_rgba: u32 = undefined,

    inline_start: ArrayListUnmanaged(InlineLevelUsedValues.BoxProperties) = .{},
    inline_end: ArrayListUnmanaged(InlineLevelUsedValues.BoxProperties) = .{},
    block_start: ArrayListUnmanaged(InlineLevelUsedValues.BoxProperties) = .{},
    block_end: ArrayListUnmanaged(InlineLevelUsedValues.BoxProperties) = .{},
    background1: ArrayListUnmanaged(used_values.Background1) = .{},
    ascender: ZssUnit = undefined,
    descender: ZssUnit = undefined,

    margins: ArrayListUnmanaged(Margins) = .{},

    fn deinit(self: *Self) void {
        self.line_boxes.deinit(self.allocator);
        self.glyph_indeces.deinit(self.allocator);
        self.metrics.deinit(self.allocator);
        self.inline_start.deinit(self.allocator);
        self.inline_end.deinit(self.allocator);
        self.block_start.deinit(self.allocator);
        self.block_end.deinit(self.allocator);
        self.background1.deinit(self.allocator);
        self.margins.deinit(self.allocator);
    }

    fn ensureCapacity(self: *Self, count: usize) !void {
        try self.line_boxes.ensureCapacity(self.allocator, count);
        try self.glyph_indeces.ensureCapacity(self.allocator, count);
        try self.metrics.ensureCapacity(self.allocator, count);
        try self.inline_start.ensureCapacity(self.allocator, count);
        try self.inline_end.ensureCapacity(self.allocator, count);
        try self.block_start.ensureCapacity(self.allocator, count);
        try self.block_end.ensureCapacity(self.allocator, count);
        try self.background1.ensureCapacity(self.allocator, count);
        try self.margins.ensureCapacity(self.allocator, count);
    }

    fn toInlineLevelUsedValues(self: *Self) InlineLevelUsedValues {
        self.margins.deinit(self.allocator);
        return InlineLevelUsedValues{
            .line_boxes = self.line_boxes.toOwnedSlice(self.allocator),
            .glyph_indeces = self.glyph_indeces.toOwnedSlice(self.allocator),
            .metrics = self.metrics.toOwnedSlice(self.allocator),
            .font = self.font,
            .font_color_rgba = self.font_color_rgba,
            .inline_start = self.inline_start.toOwnedSlice(self.allocator),
            .inline_end = self.inline_end.toOwnedSlice(self.allocator),
            .block_start = self.block_start.toOwnedSlice(self.allocator),
            .block_end = self.block_end.toOwnedSlice(self.allocator),
            .background1 = self.background1.toOwnedSlice(self.allocator),
            .ascender = self.ascender,
            .descender = self.descender,
        };
    }
};

const InlineLevelLayoutContext = struct {
    const Self = @This();

    const Interval = struct {
        begin: BoxId,
        end: BoxId,
    };

    box_tree: *const BoxTree,
    intervals: ArrayListUnmanaged(Interval),
    used_ids: ArrayListUnmanaged(UsedId),
    allocator: *Allocator,
    root_interval: Interval,
    containing_block_inline_size: ZssUnit,

    total_block_size: ZssUnit = undefined,
    next_box_id: BoxId,

    fn init(box_tree: *const BoxTree, allocator: *Allocator, block_container_interval: BlockLevelLayoutContext.Interval, containing_block_inline_size: ZssUnit) Self {
        return Self{
            .box_tree = box_tree,
            .intervals = .{},
            .used_ids = .{},
            .allocator = allocator,
            .root_interval = Interval{ .begin = block_container_interval.begin, .end = block_container_interval.end },
            .containing_block_inline_size = containing_block_inline_size,
            .next_box_id = block_container_interval.end,
        };
    }

    fn deinit(self: *Self) void {
        self.intervals.deinit(self.allocator);
        self.used_ids.deinit(self.allocator);
    }
};

fn createInlineLevelUsedValues(context: *InlineLevelLayoutContext, values_allocator: *Allocator) Error!InlineLevelUsedValues {
    const root_interval = context.root_interval;

    var values = IntermediateInlineLevelUsedValues{ .allocator = values_allocator };
    errdefer values.deinit();
    values.ensureCapacity(root_interval.end - root_interval.begin + 1) catch {};

    try inlineLevelRootElementPush(context, &values, root_interval);

    while (context.intervals.items.len > 0) {
        const interval = &context.intervals.items[context.intervals.items.len - 1];
        if (interval.begin != interval.end) {
            const should_break = try inlineLevelElementPush(context, &values, interval);
            if (should_break) break;
        } else {
            try inlineLevelElementPop(context, &values);
        }
    }

    values.font = context.box_tree.font.font;
    values.font_color_rgba = switch (context.box_tree.font.color) {
        .rgba => |rgba| rgba,
    };
    var font_extents: hb.hb_font_extents_t = undefined;
    // TODO assuming ltr direction
    assert(hb.hb_font_get_h_extents(values.font, &font_extents) != 0);
    values.ascender = @divFloor(font_extents.ascender * unitsPerPixel, 64);
    values.descender = -@divFloor(font_extents.descender * unitsPerPixel, 64);

    context.total_block_size = try splitIntoLineBoxes(&values, values.font, context.containing_block_inline_size);

    return values.toInlineLevelUsedValues();
}

fn inlineLevelRootElementPush(context: *InlineLevelLayoutContext, values: *IntermediateInlineLevelUsedValues, root_interval: InlineLevelLayoutContext.Interval) !void {
    const root_used_id = try addRootInlineBoxData(values);
    try addBoxStart(values, root_used_id);

    if (root_interval.begin != root_interval.end) {
        try context.intervals.append(context.allocator, root_interval);
        try context.used_ids.append(context.allocator, root_used_id);
    } else {
        try addBoxEnd(values, root_used_id);
    }
}

fn inlineLevelElementPush(context: *InlineLevelLayoutContext, values: *IntermediateInlineLevelUsedValues, interval: *InlineLevelLayoutContext.Interval) !bool {
    const box_id = interval.begin;
    const subtree_size = context.box_tree.structure[box_id];
    interval.begin += subtree_size;

    switch (context.box_tree.display[box_id]) {
        .inline_ => {
            const used_id = try addInlineElementData(context.box_tree, values, box_id, context.containing_block_inline_size);
            try addBoxStart(values, used_id);

            if (subtree_size != 1) {
                try context.intervals.append(context.allocator, .{ .begin = box_id + 1, .end = box_id + subtree_size });
                try context.used_ids.append(context.allocator, used_id);
            } else {
                // Optimized path for elements that have no children. It is like a shorter version of inlineLevelElementPop.
                try addBoxEnd(values, used_id);
            }
        },
        .text => try addText(values, context.box_tree.latin1_text[box_id], context.box_tree.font),
        .block => {
            // Immediately finish off this inline layout context.
            context.next_box_id = box_id;
            return true;
        },
        .none => {},
    }

    return false;
}

fn inlineLevelElementPop(context: *InlineLevelLayoutContext, values: *IntermediateInlineLevelUsedValues) !void {
    const used_id = context.used_ids.items[context.used_ids.items.len - 1];
    try addBoxEnd(values, used_id);

    _ = context.intervals.pop();
    _ = context.used_ids.pop();
}

fn addText(values: *IntermediateInlineLevelUsedValues, latin1_text: BoxTree.Latin1Text, font: BoxTree.Font) !void {
    const buffer = hb.hb_buffer_create() orelse unreachable;
    defer hb.hb_buffer_destroy(buffer);
    _ = hb.hb_buffer_pre_allocate(buffer, @intCast(c_uint, latin1_text.text.len));
    // TODO direction, script, and language must be determined by examining the text itself
    hb.hb_buffer_set_direction(buffer, hb.hb_direction_t.HB_DIRECTION_LTR);
    hb.hb_buffer_set_script(buffer, hb.hb_script_t.HB_SCRIPT_LATIN);
    hb.hb_buffer_set_language(buffer, hb.hb_language_from_string("en", -1));

    var run_begin: usize = 0;
    var run_end: usize = 0;
    while (run_end < latin1_text.text.len) : (run_end += 1) {
        const codepoint = latin1_text.text[run_end];
        switch (codepoint) {
            '\n' => {
                try endTextRun(values, latin1_text, buffer, font.font, run_begin, run_end);
                try addLineBreak(values);
                run_begin = run_end + 1;
            },
            '\r' => {
                try endTextRun(values, latin1_text, buffer, font.font, run_begin, run_end);
                try addLineBreak(values);
                run_end += @boolToInt(run_end + 1 < latin1_text.text.len and latin1_text.text[run_end + 1] == '\n');
                run_begin = run_end + 1;
            },
            '\t' => {
                try endTextRun(values, latin1_text, buffer, font.font, run_begin, run_end);
                run_begin = run_end + 1;
                // TODO tab size should be determined by the 'tab-size' property
                const tab_size = 8;
                hb.hb_buffer_add_latin1(buffer, " " ** tab_size, tab_size, 0, tab_size);
                if (hb.hb_buffer_allocation_successful(buffer) == 0) return error.OutOfMemory;
                try addTextRun(values, buffer, font.font);
                assert(hb.hb_buffer_set_length(buffer, 0) != 0);
            },
            else => {},
        }
    }

    try endTextRun(values, latin1_text, buffer, font.font, run_begin, run_end);
}

fn endTextRun(values: *IntermediateInlineLevelUsedValues, latin1_text: BoxTree.Latin1Text, buffer: *hb.hb_buffer_t, font: *hb.hb_font_t, run_begin: usize, run_end: usize) !void {
    if (run_end > run_begin) {
        hb.hb_buffer_add_latin1(buffer, latin1_text.text.ptr, @intCast(c_int, latin1_text.text.len), @intCast(c_uint, run_begin), @intCast(c_int, run_end - run_begin));
        if (hb.hb_buffer_allocation_successful(buffer) == 0) return error.OutOfMemory;
        try addTextRun(values, buffer, font);
        assert(hb.hb_buffer_set_length(buffer, 0) != 0);
    }
}

fn addTextRun(values: *IntermediateInlineLevelUsedValues, buffer: *hb.hb_buffer_t, font: *hb.hb_font_t) !void {
    hb.hb_shape(font, buffer, null, 0);
    const glyph_infos = blk: {
        var n: c_uint = 0;
        const p = hb.hb_buffer_get_glyph_infos(buffer, &n);
        break :blk p[0..n];
    };

    // TODO Find out why the values in glyph_positions lead to poorly placed glyphs.

    //const glyph_positions = blk: {
    //    var n: c_uint = 0;
    //    const p = hb.hb_buffer_get_glyph_positions(buffer, &n);
    //    break :blk p[0..n];
    //};
    var extents: hb.hb_glyph_extents_t = undefined;

    const old_len = values.glyph_indeces.items.len;
    // Allocate twice as much so that special glyph indeces always have space
    try values.glyph_indeces.ensureCapacity(values.allocator, old_len + 2 * glyph_infos.len);
    try values.metrics.ensureCapacity(values.allocator, old_len + 2 * glyph_infos.len);

    for (glyph_infos) |info, i| {
        //const pos = glyph_positions[i];
        const extents_result = hb.hb_font_get_glyph_extents(font, info.codepoint, &extents);
        if (extents_result == 0) {
            extents.width = 0;
            extents.x_bearing = 0;
        }

        values.glyph_indeces.appendAssumeCapacity(info.codepoint);
        //values.metrics.appendAssumeCapacity(.{ .offset = @divFloor(pos.x_offset * unitsPerPixel, 64), .advance = @divFloor(pos.x_advance * unitsPerPixel, 64), .width = @divFloor(width * unitsPerPixel, 64) });
        values.metrics.appendAssumeCapacity(.{
            .offset = @divFloor(extents.x_bearing * unitsPerPixel, 64),
            .advance = @divFloor(hb.hb_font_get_glyph_h_advance(font, info.codepoint) * unitsPerPixel, 64),
            .width = @divFloor(extents.width * unitsPerPixel, 64),
        });

        if (info.codepoint == 0) {
            values.glyph_indeces.appendAssumeCapacity(InlineLevelUsedValues.Special.encodeZeroGlyphIndex());
            values.metrics.appendAssumeCapacity(undefined);
        }
    }
}

fn addLineBreak(values: *IntermediateInlineLevelUsedValues) !void {
    try values.glyph_indeces.appendSlice(values.allocator, &.{ 0, InlineLevelUsedValues.Special.encodeLineBreak() });
    try values.metrics.appendSlice(values.allocator, &.{ .{ .offset = 0, .advance = 0, .width = 0 }, undefined });
}

fn addBoxStart(values: *IntermediateInlineLevelUsedValues, used_id: UsedId) !void {
    const inline_start = values.inline_start.items[used_id];
    const margin = values.margins.items[used_id].start;
    const width = inline_start.border + inline_start.padding;
    const advance = width + margin;

    const glyph_indeces = [2]hb.hb_codepoint_t{ 0, InlineLevelUsedValues.Special.encodeBoxStart(used_id) };
    try values.glyph_indeces.appendSlice(values.allocator, &glyph_indeces);
    const metrics = [2]InlineLevelUsedValues.Metrics{ .{ .offset = margin, .advance = advance, .width = width }, undefined };
    try values.metrics.appendSlice(values.allocator, &metrics);
}

fn addBoxEnd(values: *IntermediateInlineLevelUsedValues, used_id: UsedId) !void {
    const inline_end = values.inline_end.items[used_id];
    const margin = values.margins.items[used_id].end;
    const width = inline_end.border + inline_end.padding;
    const advance = width + margin;

    const glyph_indeces = [2]hb.hb_codepoint_t{ 0, InlineLevelUsedValues.Special.encodeBoxEnd(used_id) };
    try values.glyph_indeces.appendSlice(values.allocator, &glyph_indeces);
    const metrics = [2]InlineLevelUsedValues.Metrics{ .{ .offset = 0, .advance = advance, .width = width }, undefined };
    try values.metrics.appendSlice(values.allocator, &metrics);
}

fn addRootInlineBoxData(values: *IntermediateInlineLevelUsedValues) !UsedId {
    try values.inline_start.append(values.allocator, .{ .border = 0, .padding = 0, .border_color_rgba = 0 });
    try values.inline_end.append(values.allocator, .{ .border = 0, .padding = 0, .border_color_rgba = 0 });
    try values.block_start.append(values.allocator, .{ .border = 0, .padding = 0, .border_color_rgba = 0 });
    try values.block_end.append(values.allocator, .{ .border = 0, .padding = 0, .border_color_rgba = 0 });
    try values.margins.append(values.allocator, .{ .start = 0, .end = 0 });
    try values.background1.append(values.allocator, .{});
    return 0;
}

fn addInlineElementData(box_tree: *const BoxTree, values: *IntermediateInlineLevelUsedValues, box_id: BoxId, containing_block_inline_size: ZssUnit) !UsedId {
    const inline_sizes = box_tree.inline_size[box_id];

    const margin_inline_start = switch (inline_sizes.margin_start) {
        .px => |value| length(.px, value),
        .percentage => |value| percentage(value, containing_block_inline_size),
        .auto => 0,
    };
    const border_inline_start = switch (inline_sizes.border_start) {
        .px => |value| length(.px, value),
    };
    const padding_inline_start = switch (inline_sizes.padding_start) {
        .px => |value| length(.px, value),
        .percentage => |value| percentage(value, containing_block_inline_size),
    };
    const margin_inline_end = switch (inline_sizes.margin_end) {
        .px => |value| length(.px, value),
        .percentage => |value| percentage(value, containing_block_inline_size),
        .auto => 0,
    };
    const border_inline_end = switch (inline_sizes.border_end) {
        .px => |value| length(.px, value),
    };
    const padding_inline_end = switch (inline_sizes.padding_end) {
        .px => |value| length(.px, value),
        .percentage => |value| percentage(value, containing_block_inline_size),
    };

    const block_sizes = box_tree.block_size[box_id];

    const border_block_start = switch (block_sizes.border_start) {
        .px => |value| length(.px, value),
    };
    const padding_block_start = switch (block_sizes.padding_start) {
        .px => |value| length(.px, value),
        .percentage => |value| percentage(value, containing_block_inline_size),
    };
    const border_block_end = switch (block_sizes.border_end) {
        .px => |value| length(.px, value),
    };
    const padding_block_end = switch (block_sizes.padding_end) {
        .px => |value| length(.px, value),
        .percentage => |value| percentage(value, containing_block_inline_size),
    };

    if (border_inline_start < 0) return error.InvalidValue;
    if (border_inline_end < 0) return error.InvalidValue;
    if (border_block_start < 0) return error.InvalidValue;
    if (border_block_end < 0) return error.InvalidValue;
    if (padding_inline_start < 0) return error.InvalidValue;
    if (padding_inline_end < 0) return error.InvalidValue;
    if (padding_block_start < 0) return error.InvalidValue;
    if (padding_block_end < 0) return error.InvalidValue;

    const border_colors = solveBorderColors(box_tree.border[box_id]);

    try values.inline_start.append(values.allocator, .{ .border = border_inline_start, .padding = padding_inline_start, .border_color_rgba = border_colors.inline_start_rgba });
    try values.inline_end.append(values.allocator, .{ .border = border_inline_end, .padding = padding_inline_end, .border_color_rgba = border_colors.inline_end_rgba });
    try values.block_start.append(values.allocator, .{ .border = border_block_start, .padding = padding_block_start, .border_color_rgba = border_colors.block_start_rgba });
    try values.block_end.append(values.allocator, .{ .border = border_block_end, .padding = padding_block_end, .border_color_rgba = border_colors.block_end_rgba });
    try values.margins.append(values.allocator, .{ .start = margin_inline_start, .end = margin_inline_end });
    try values.background1.append(values.allocator, solveBackground1(box_tree.background[box_id]));
    return std.math.cast(UsedId, values.inline_start.items.len - 1);
}

fn splitIntoLineBoxes(values: *IntermediateInlineLevelUsedValues, font: *hb.hb_font_t, containing_block_inline_size: ZssUnit) !ZssUnit {
    var font_extents: hb.hb_font_extents_t = undefined;
    // TODO assuming ltr direction
    assert(hb.hb_font_get_h_extents(font, &font_extents) != 0);
    const ascender = @divFloor(font_extents.ascender * unitsPerPixel, 64);
    const descender = @divFloor(font_extents.descender * unitsPerPixel, 64);
    const line_gap = @divFloor(font_extents.line_gap * unitsPerPixel, 64);
    const line_spacing = ascender - descender + line_gap;

    var cursor: ZssUnit = 0;
    var line_box = InlineLevelUsedValues.LineBox{ .baseline = ascender, .elements = [2]usize{ 0, 0 } };

    var i: usize = 0;
    while (i < values.glyph_indeces.items.len) : (i += 1) {
        const gi = values.glyph_indeces.items[i];
        const metrics = values.metrics.items[i];

        // TODO A glyph with a width of zero but an advance that is non-zero may overflow the width of the containing block
        if (cursor > 0 and metrics.width > 0 and cursor + metrics.offset + metrics.width > containing_block_inline_size and line_box.elements[1] > line_box.elements[0]) {
            try values.line_boxes.append(values.allocator, line_box);
            cursor = 0;
            line_box = .{ .baseline = line_box.baseline + line_spacing, .elements = [2]usize{ line_box.elements[1], line_box.elements[1] } };
        }

        cursor += metrics.advance;

        switch (gi) {
            0 => {
                i += 1;
                const special = InlineLevelUsedValues.Special.decode(values.glyph_indeces.items[i]);
                switch (@intToEnum(InlineLevelUsedValues.Special.LayoutInternalKind, @enumToInt(special.kind))) {
                    .LineBreak => {
                        try values.line_boxes.append(values.allocator, line_box);
                        cursor = 0;
                        line_box = .{ .baseline = line_box.baseline + line_spacing, .elements = [2]usize{ line_box.elements[1] + 2, line_box.elements[1] + 2 } };
                    },
                    else => line_box.elements[1] += 2,
                }
            },
            else => line_box.elements[1] += 1,
        }
    }

    if (line_box.elements[1] > line_box.elements[0]) {
        try values.line_boxes.append(values.allocator, line_box);
    }

    if (values.line_boxes.items.len > 0) {
        return values.line_boxes.items[values.line_boxes.items.len - 1].baseline - descender;
    } else {
        return 0;
    }
}

test "inline used values" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer assert(!gpa.deinit());
    const al = &gpa.allocator;

    const blob = hb.hb_blob_create_from_file("demo/NotoSans-Regular.ttf");
    defer hb.hb_blob_destroy(blob);
    if (blob == hb.hb_blob_get_empty()) return error.HarfBuzzError;

    const face = hb.hb_face_create(blob, 0);
    defer hb.hb_face_destroy(face);
    if (face == hb.hb_face_get_empty()) return error.HarfBuzzError;

    const hb_font = hb.hb_font_create(face);
    defer hb.hb_font_destroy(hb_font);
    if (hb_font == hb.hb_font_get_empty()) return error.HarfBuzzError;
    hb.hb_font_set_scale(hb_font, 40 * 64, 40 * 64);

    const len = 2;
    var structure = [len]BoxId{ 2, 1 };
    var inline_size = [_]BoxTree.LogicalSize{.{}} ** len;
    var block_size = [_]BoxTree.LogicalSize{.{}} ** len;
    var display = [len]BoxTree.Display{
        .{ .block = {} },
        .{ .text = {} },
    };
    var latin1_text = [len]BoxTree.Latin1Text{ .{}, .{ .text = "hello world" } };
    var font = BoxTree.Font{ .font = hb_font.? };
    var border = [_]BoxTree.Border{.{}} ** len;
    var background = [_]BoxTree.Background{.{}} ** len;
    const tree = BoxTree{
        .structure = &structure,
        .inline_size = &inline_size,
        .block_size = &block_size,
        .display = &display,
        .latin1_text = &latin1_text,
        .font = font,
        .border = &border,
        .background = &background,
    };

    var context = InlineLevelLayoutContext.init(&tree, al, .{ .parent = 0, .begin = 1, .end = structure[0] }, 50);
    defer context.deinit();
    var values = try createInlineLevelUsedValues(&context, al);
    defer values.deinit(al);

    try std.testing.expect(context.next_box_id == 2);
}

fn solveBorderColors(border: BoxTree.Border) used_values.BorderColor {
    const solveOneBorderColor = struct {
        fn f(color: BoxTree.Border.Color) u32 {
            return switch (color) {
                .rgba => |rgba| rgba,
            };
        }
    }.f;

    return used_values.BorderColor{
        .inline_start_rgba = solveOneBorderColor(border.inline_start_color),
        .inline_end_rgba = solveOneBorderColor(border.inline_end_color),
        .block_start_rgba = solveOneBorderColor(border.block_start_color),
        .block_end_rgba = solveOneBorderColor(border.block_end_color),
    };
}

fn solveBackground1(bg: BoxTree.Background) used_values.Background1 {
    return used_values.Background1{
        .color_rgba = switch (bg.color) {
            .rgba => |rgba| rgba,
        },
        .clip = switch (bg.clip) {
            .border_box => .Border,
            .padding_box => .Padding,
            .content_box => .Content,
        },
    };
}

fn solveBackground2(bg: BoxTree.Background, box_offsets: *const used_values.BoxOffsets, borders: *const used_values.Borders) used_values.Background2 {
    var object = switch (bg.image) {
        .object => |object| object,
        .none => return .{},
    };

    const border_width = box_offsets.border_end.inline_dir - box_offsets.border_start.inline_dir;
    const border_height = box_offsets.border_end.block_dir - box_offsets.border_start.block_dir;
    const padding_width = border_width - borders.inline_start - borders.inline_end;
    const padding_height = border_height - borders.block_start - borders.block_end;
    const content_width = box_offsets.content_end.inline_dir - box_offsets.content_start.inline_dir;
    const content_height = box_offsets.content_end.block_dir - box_offsets.content_start.block_dir;
    const positioning_area: struct { origin: used_values.Background2.Origin, width: ZssUnit, height: ZssUnit } = switch (bg.origin) {
        .border_box => .{ .origin = .Border, .width = border_width, .height = border_height },
        .padding_box => .{ .origin = .Padding, .width = padding_width, .height = padding_height },
        .content_box => .{ .origin = .Content, .width = content_width, .height = content_height },
    };

    const NaturalSize = struct {
        width: ZssUnit,
        height: ZssUnit,
        has_aspect_ratio: bool,

        fn init(obj: *BoxTree.Background.Image.Object) @This() {
            const n = obj.getNaturalSize();
            assert(n.width >= 0);
            assert(n.height >= 0);
            return @This(){ .width = length(.px, n.width), .height = length(.px, n.height), .has_aspect_ratio = n.width != 0 and n.height != 0 };
        }
    };
    // Initialize on first use.
    var natural: ?NaturalSize = null;

    var width_was_auto = false;
    var height_was_auto = false;
    var size: used_values.Background2.Size = switch (bg.size) {
        .size => |size| .{
            .width = switch (size.width) {
                .px => |val| blk: {
                    // Value must be positive
                    assert(val >= 0);
                    break :blk length(.px, val);
                },
                .percentage => |p| blk: {
                    // Percentage must be positive
                    assert(p >= 0);
                    break :blk percentage(p, positioning_area.width);
                },
                .auto => blk: {
                    width_was_auto = true;
                    break :blk undefined;
                },
            },
            .height = switch (size.height) {
                .px => |val| blk: {
                    // Value must be positive
                    assert(val >= 0);
                    break :blk length(.px, val);
                },
                .percentage => |p| blk: {
                    // Percentage must be positive
                    assert(p >= 0);
                    break :blk percentage(p, positioning_area.height);
                },
                .auto => blk: {
                    height_was_auto = true;
                    break :blk undefined;
                },
            },
        },
        .contain, .cover => blk: {
            if (natural == null) natural = NaturalSize.init(&object);
            if (!natural.?.has_aspect_ratio) break :blk used_values.Background2.Size{ .width = natural.?.width, .height = natural.?.height };

            const positioning_area_is_wider_than_image = positioning_area.width * natural.?.height > positioning_area.height * natural.?.width;
            const is_contain = (bg.size == .contain);

            if (positioning_area_is_wider_than_image == is_contain) {
                break :blk used_values.Background2.Size{ .width = @divFloor(positioning_area.height * natural.?.width, natural.?.height), .height = positioning_area.height };
            } else {
                break :blk used_values.Background2.Size{ .width = positioning_area.width, .height = @divFloor(positioning_area.width * natural.?.height, natural.?.width) };
            }
        },
    };

    const repeat: used_values.Background2.Repeat = switch (bg.repeat) {
        .repeat => |repeat| .{
            .x = switch (repeat.x) {
                .no_repeat => .None,
                .repeat => .Repeat,
                .space => .Space,
                .round => .Round,
            },
            .y = switch (repeat.y) {
                .no_repeat => .None,
                .repeat => .Repeat,
                .space => .Space,
                .round => .Round,
            },
        },
    };

    if (width_was_auto or height_was_auto or repeat.x == .Round or repeat.y == .Round) {
        const divRound = zss.util.divRound;
        if (natural == null) natural = NaturalSize.init(&object);

        if (width_was_auto and height_was_auto) {
            size.width = natural.?.width;
            size.height = natural.?.height;
        } else if (width_was_auto) {
            size.width = if (natural.?.has_aspect_ratio) divRound(size.height * natural.?.width, natural.?.height) else positioning_area.width;
        } else if (height_was_auto) {
            size.height = if (natural.?.has_aspect_ratio) divRound(size.width * natural.?.height, natural.?.width) else positioning_area.height;
        }

        if (repeat.x == .Round and repeat.y == .Round) {
            size.width = @divFloor(positioning_area.width, std.math.max(1, divRound(positioning_area.width, size.width)));
            size.height = @divFloor(positioning_area.height, std.math.max(1, divRound(positioning_area.height, size.height)));
        } else if (repeat.x == .Round) {
            if (size.width > 0) size.width = @divFloor(positioning_area.width, std.math.max(1, divRound(positioning_area.width, size.width)));
            if (height_was_auto and natural.?.has_aspect_ratio) size.height = @divFloor(size.width * natural.?.height, natural.?.width);
        } else if (repeat.y == .Round) {
            if (size.height > 0) size.height = @divFloor(positioning_area.height, std.math.max(1, divRound(positioning_area.height, size.height)));
            if (width_was_auto and natural.?.has_aspect_ratio) size.width = @divFloor(size.height * natural.?.width, natural.?.height);
        }
    }

    const position: used_values.Background2.Position = switch (bg.position) {
        .position => |position| .{
            .x = switch (position.x.offset) {
                .px => |val| length(.px, val),
                .percentage => |p| percentage(
                    switch (position.x.side) {
                        .left => p,
                        .right => 1 - p,
                    },
                    positioning_area.width - size.width,
                ),
            },
            .y = switch (position.y.offset) {
                .px => |val| length(.px, val),
                .percentage => |p| percentage(
                    switch (position.y.side) {
                        .top => p,
                        .bottom => 1 - p,
                    },
                    positioning_area.height - size.height,
                ),
            },
        },
    };

    return used_values.Background2{
        .image = object.data,
        .origin = positioning_area.origin,
        .position = position,
        .size = size,
        .repeat = repeat,
    };
}
