const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const assert = std.debug.assert;

const zss = @import("../../zss.zig");
const BoxTree = zss.BoxTree;
const BoxId = BoxTree.BoxId;
const root_box_id = BoxTree.root_box_id;
const reserved_box_id = BoxTree.reserved_box_id;
const maximum_box_id = BoxTree.maximum_box_id;

const used_values = @import("./used_values.zig");
const ZssUnit = used_values.ZssUnit;
const unitsPerPixel = used_values.unitsPerPixel;
const UsedId = used_values.UsedId;
const UsedSubtreeSize = used_values.UsedSubtreeSize;
const UsedBoxCount = used_values.UsedBoxCount;
const StackingContextId = used_values.StackingContextId;
const InlineId = used_values.InlineId;
const ZIndex = used_values.ZIndex;
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
    if (box_tree.structure[0] > maximum_box_id) return error.Overflow;
    var context = try LayoutContext.init(box_tree, allocator, document_width, document_height);
    defer context.deinit();
    var doc = Document{
        .blocks = BlockLevelUsedValues{},
        .inlines = .{},
        .allocator = allocator,
    };
    errdefer doc.deinit();
    try createBlockLevelUsedValues(&doc, &context);
    return doc;
}

const LengthUnit = enum { px };

fn length(comptime unit: LengthUnit, value: f32) ZssUnit {
    return switch (unit) {
        .px => @floatToInt(ZssUnit, @round(value * unitsPerPixel)),
    };
}

fn positiveLength(comptime unit: LengthUnit, value: f32) !ZssUnit {
    if (value < 0) return error.InvalidValue;
    return length(unit, value);
}

fn percentage(value: f32, unit: ZssUnit) ZssUnit {
    return @floatToInt(ZssUnit, @round(@intToFloat(f32, unit) * value));
}

fn positivePercentage(value: f32, unit: ZssUnit) !ZssUnit {
    if (value < 0) return error.InvalidValue;
    return percentage(value, unit);
}

const LayoutMode = enum {
    Flow,
    ShrinkToFit1stPass,
    ShrinkToFit2ndPass,
    InlineContainer,
};

const UsedIdInterval = struct {
    begin: UsedId,
    end: UsedId,
};

const UsedLogicalHeights = struct {
    height: ?ZssUnit,
    min_height: ZssUnit,
    max_height: ZssUnit,
};

const Metadata = struct {
    is_stacking_context_parent: bool,
};

const InlineBlock = struct {
    /// The box id of the inline block.
    box_id: BoxId,
    /// The position within the glyph_indeces array of
    /// the special glyph index that represents the inline block.
    index: usize,
};

const InlineContainer = struct {
    values: *InlineLevelUsedValues,
    containing_block_logical_width: ZssUnit,
    inline_blocks: []InlineBlock,
    next_inline_block: usize,

    fn deinit(self: *@This(), allocator: *Allocator) void {
        allocator.free(self.inline_blocks);
    }
};

const LayoutContext = struct {
    const Self = @This();

    const Interval = struct {
        parent: BoxId,
        begin: BoxId,
        end: BoxId,
    };

    box_tree: *const BoxTree,
    allocator: *Allocator,

    layout_mode: ArrayListUnmanaged(LayoutMode),

    metadata: ArrayListUnmanaged(Metadata),
    stacking_context_id: ArrayListUnmanaged(StackingContextId),
    used_id_to_box_id: ArrayListUnmanaged(BoxId),

    intervals: ArrayListUnmanaged(Interval),
    used_id: ArrayListUnmanaged(UsedId),
    used_subtree_size: ArrayListUnmanaged(UsedSubtreeSize),
    flow_block_used_logical_width: ArrayListUnmanaged(ZssUnit),
    flow_block_auto_logical_height: ArrayListUnmanaged(ZssUnit),
    flow_block_used_logical_heights: ArrayListUnmanaged(UsedLogicalHeights),

    relative_positioned_descendants_ids: ArrayListUnmanaged(UsedId),
    relative_positioned_descendants_count: ArrayListUnmanaged(UsedBoxCount),

    shrink_to_fit_available_width: ArrayListUnmanaged(ZssUnit),
    shrink_to_fit_auto_width: ArrayListUnmanaged(ZssUnit),
    shrink_to_fit_base_width: ArrayListUnmanaged(ZssUnit),
    used_id_intervals: ArrayListUnmanaged(UsedIdInterval),

    inline_container: ArrayListUnmanaged(InlineContainer),

    fn init(box_tree: *const BoxTree, allocator: *Allocator, containing_block_logical_width: ZssUnit, containing_block_logical_height: ZssUnit) !Self {
        var layout_mode = ArrayListUnmanaged(LayoutMode){};
        errdefer layout_mode.deinit(allocator);
        try layout_mode.append(allocator, .Flow);

        var intervals = ArrayListUnmanaged(Interval){};
        errdefer intervals.deinit(allocator);
        try intervals.append(allocator, .{ .parent = root_box_id, .begin = root_box_id, .end = root_box_id + box_tree.structure[root_box_id] });

        var used_subtree_size = ArrayListUnmanaged(UsedSubtreeSize){};
        errdefer used_subtree_size.deinit(allocator);
        try used_subtree_size.append(allocator, 1);

        var flow_block_used_logical_width = ArrayListUnmanaged(ZssUnit){};
        errdefer flow_block_used_logical_width.deinit(allocator);
        try flow_block_used_logical_width.append(allocator, containing_block_logical_width);

        var flow_block_auto_logical_height = ArrayListUnmanaged(ZssUnit){};
        errdefer flow_block_auto_logical_height.deinit(allocator);
        try flow_block_auto_logical_height.append(allocator, 0);

        var flow_block_used_logical_heights = ArrayListUnmanaged(UsedLogicalHeights){};
        errdefer flow_block_used_logical_heights.deinit(allocator);
        try flow_block_used_logical_heights.append(allocator, UsedLogicalHeights{
            .height = containing_block_logical_height,
            .min_height = 0,
            .max_height = 0,
        });

        var relative_positioned_descendants_count = ArrayListUnmanaged(UsedBoxCount){};
        errdefer relative_positioned_descendants_count.deinit(allocator);
        try relative_positioned_descendants_count.append(allocator, 0);

        return Self{
            .box_tree = box_tree,
            .allocator = allocator,
            .intervals = intervals,
            .layout_mode = layout_mode,
            .metadata = .{},
            .stacking_context_id = .{},
            .used_id_to_box_id = .{},
            .used_id = .{},
            .used_subtree_size = used_subtree_size,
            .flow_block_used_logical_width = flow_block_used_logical_width,
            .flow_block_auto_logical_height = flow_block_auto_logical_height,
            .flow_block_used_logical_heights = flow_block_used_logical_heights,
            .relative_positioned_descendants_ids = .{},
            .relative_positioned_descendants_count = relative_positioned_descendants_count,
            .shrink_to_fit_available_width = .{},
            .shrink_to_fit_auto_width = .{},
            .shrink_to_fit_base_width = .{},
            .used_id_intervals = .{},
            .inline_container = .{},
        };
    }

    fn deinit(self: *Self) void {
        self.intervals.deinit(self.allocator);
        self.metadata.deinit(self.allocator);
        self.layout_mode.deinit(self.allocator);
        self.used_id.deinit(self.allocator);
        self.used_subtree_size.deinit(self.allocator);
        self.stacking_context_id.deinit(self.allocator);
        self.used_id_to_box_id.deinit(self.allocator);
        self.flow_block_used_logical_width.deinit(self.allocator);
        self.flow_block_auto_logical_height.deinit(self.allocator);
        self.flow_block_used_logical_heights.deinit(self.allocator);
        self.relative_positioned_descendants_ids.deinit(self.allocator);
        self.relative_positioned_descendants_count.deinit(self.allocator);
        self.shrink_to_fit_available_width.deinit(self.allocator);
        self.shrink_to_fit_auto_width.deinit(self.allocator);
        self.shrink_to_fit_base_width.deinit(self.allocator);
        self.used_id_intervals.deinit(self.allocator);
        for (self.inline_container.items) |*container| {
            container.deinit(self.allocator);
        }
        self.inline_container.deinit(self.allocator);
    }
};

fn createBlockLevelUsedValues(doc: *Document, context: *LayoutContext) Error!void {
    doc.blocks.ensureCapacity(doc.allocator, context.box_tree.structure[0]) catch {};

    // Process the root element.
    try processElement(doc, context);
    if (doc.blocks.structure.items.len == 0) {
        // The root element has a 'display' value of 'none'.
        return;
    }

    // Create the root stacking context.
    try doc.blocks.stacking_context_structure.append(doc.allocator, 1);
    try doc.blocks.stacking_contexts.append(doc.allocator, .{ .z_index = 0, .used_id = 0 });
    doc.blocks.properties.items[0].creates_stacking_context = true;
    try context.stacking_context_id.append(context.allocator, 0);

    // Process all other elements.
    while (context.layout_mode.items.len > 1) {
        try processElement(doc, context);
    }

    // Solve for all of the properties that don't affect layout.
    const num_created_boxes = doc.blocks.structure.items[0];
    assert(context.used_id_to_box_id.items.len == num_created_boxes);
    try doc.blocks.border_colors.resize(doc.allocator, num_created_boxes);
    try doc.blocks.background1.resize(doc.allocator, num_created_boxes);
    try doc.blocks.background2.resize(doc.allocator, num_created_boxes);
    for (context.used_id_to_box_id.items) |box_id, used_id| {
        if (box_id != reserved_box_id) {
            try blockBoxSolveOtherProperties(doc, context.box_tree, box_id, @intCast(UsedId, used_id));
        } else {
            blockBoxFillOtherPropertiesWithDefaults(doc, @intCast(UsedId, used_id));
        }
    }
}

fn processElement(doc: *Document, context: *LayoutContext) !void {
    const layout_mode = context.layout_mode.items[context.layout_mode.items.len - 1];
    switch (layout_mode) {
        .Flow => {
            const interval = &context.intervals.items[context.intervals.items.len - 1];
            if (interval.begin != interval.end) {
                const display = context.box_tree.display[interval.begin];
                return switch (display) {
                    .block => pushFlowBlock(doc, context, interval),
                    .inline_, .inline_block, .text => pushInlineContainer(doc, context, interval),
                    .none => skipElement(context, interval),
                };
            } else {
                popFlowBlock(doc, context);
            }
        },
        .ShrinkToFit1stPass => {
            const interval = &context.intervals.items[context.intervals.items.len - 1];
            if (interval.begin != interval.end) {
                const display = context.box_tree.display[interval.begin];
                return switch (display) {
                    .block => pushShrinkToFit1stPassBlock(doc, context, interval),
                    .none => skipElement(context, interval),
                    else => @panic("unimplemented"),
                };
            } else {
                try popShrinkToFit1stPassBlock(doc, context);
            }
        },
        .ShrinkToFit2ndPass => {
            const used_id_interval = &context.used_id_intervals.items[context.used_id_intervals.items.len - 1];
            if (used_id_interval.begin != used_id_interval.end) {
                try pushShrinkToFit2ndPassBlock(doc, context, used_id_interval);
            } else {
                popShrinkToFit2ndPassBlock(doc, context);
            }
        },
        .InlineContainer => {
            const container = context.inline_container.items[context.inline_container.items.len - 1];

            if (container.next_inline_block < container.inline_blocks.len) {
                return pushInlineBlock(doc, context, container);
            }

            try popInlineContainer(doc, context);
        },
    }
}

fn skipElement(context: *LayoutContext, interval: *LayoutContext.Interval) void {
    const box_id = interval.begin;
    interval.begin += context.box_tree.structure[box_id];
}

fn addBlockToFlow(box_offsets: *used_values.BoxOffsets, margin_end: ZssUnit, parent_auto_logical_height: *ZssUnit) void {
    box_offsets.border_start.y += parent_auto_logical_height.*;
    box_offsets.content_start.y += parent_auto_logical_height.*;
    box_offsets.content_end.y += parent_auto_logical_height.*;
    box_offsets.border_end.y += parent_auto_logical_height.*;
    parent_auto_logical_height.* = box_offsets.border_end.y + margin_end;
}

fn pushFlowBlock(doc: *Document, context: *LayoutContext, interval: *LayoutContext.Interval) !void {
    const box_id = interval.begin;
    const subtree_size = context.box_tree.structure[box_id];
    interval.begin += subtree_size;

    const block = try createBlock(doc, context, box_id);
    block.structure.* = undefined;
    block.properties.* = .{};

    const logical_width = try flowBlockSolveInlineSizes(context, box_id, block.box_offsets, block.borders, block.margins);
    const used_logical_heights = try flowBlockSolveBlockSizesPart1(context, box_id, block.box_offsets, block.borders, block.margins);

    const position = context.box_tree.position[box_id];
    const stacking_context_id = switch (position.style) {
        .static => null,
        .relative => blk: {
            if (box_id == root_box_id) {
                // This is the root element. Position must be 'static'.
                return error.InvalidValue;
            }

            context.relative_positioned_descendants_count.items[context.relative_positioned_descendants_count.items.len - 1] += 1;
            try context.relative_positioned_descendants_ids.append(context.allocator, block.used_id);
            switch (position.z_index) {
                .value => |z_index| break :blk try createStackingContext(doc, context, block, z_index),
                .auto => {
                    _ = try createStackingContext(doc, context, block, 0);
                    break :blk null;
                },
            }
        },
    };

    if (subtree_size != 1) {
        // The allocations here must have corresponding deallocations in popFlowBlock.
        try context.layout_mode.append(context.allocator, .Flow);
        try context.intervals.append(context.allocator, .{ .parent = box_id, .begin = box_id + 1, .end = box_id + subtree_size });
        try context.used_id.append(context.allocator, block.used_id);
        try context.used_subtree_size.append(context.allocator, 1);
        try context.flow_block_used_logical_width.append(context.allocator, logical_width);
        try context.flow_block_auto_logical_height.append(context.allocator, 0);
        // TODO don't need used_logical_heights
        try context.flow_block_used_logical_heights.append(context.allocator, used_logical_heights);
        try context.relative_positioned_descendants_count.append(context.allocator, 0);
        if (stacking_context_id) |id| {
            try context.stacking_context_id.append(context.allocator, id);
            try context.metadata.append(context.allocator, .{ .is_stacking_context_parent = true });
        } else {
            try context.metadata.append(context.allocator, .{ .is_stacking_context_parent = false });
        }
    } else {
        // Optimized path for elements that have no children. It is a shorter version of popFlowBlock.
        block.structure.* = 1;
        context.used_subtree_size.items[context.used_subtree_size.items.len - 1] += 1;

        const parent_layout_mode = context.layout_mode.items[context.layout_mode.items.len - 1];
        switch (parent_layout_mode) {
            .Flow => {
                _ = flowBlockSolveBlockSizesPart2(block.box_offsets, used_logical_heights, 0);
                const parent_auto_logical_height = &context.flow_block_auto_logical_height.items[context.flow_block_auto_logical_height.items.len - 1];
                addBlockToFlow(block.box_offsets, block.margins.block_end, parent_auto_logical_height);
            },
            .ShrinkToFit1stPass => @panic("unimplemented"),
            .ShrinkToFit2ndPass => @panic("unimplemented"),
            // Valid as long as this function cannot be reached from processElement -> InlineContainer.
            .InlineContainer => unreachable,
        }
    }
}

fn popFlowBlock(doc: *Document, context: *LayoutContext) void {
    const used_id = context.used_id.items[context.used_id.items.len - 1];
    const used_subtree_size = context.used_subtree_size.items[context.used_subtree_size.items.len - 1];
    doc.blocks.structure.items[used_id] = used_subtree_size;
    context.used_subtree_size.items[context.used_subtree_size.items.len - 2] += used_subtree_size;

    const box_offsets = &doc.blocks.box_offsets.items[used_id];
    const margins = doc.blocks.margins.items[used_id];

    const parent_layout_mode = context.layout_mode.items[context.layout_mode.items.len - 2];
    switch (parent_layout_mode) {
        .Flow => {
            flowBlockFinishLayout(doc, context, box_offsets);
            const parent_auto_logical_height = &context.flow_block_auto_logical_height.items[context.flow_block_auto_logical_height.items.len - 2];
            addBlockToFlow(box_offsets, margins.block_end, parent_auto_logical_height);
        },
        .ShrinkToFit1stPass => @panic("unimplemented"),
        .ShrinkToFit2ndPass => @panic("unimplemented"),
        .InlineContainer => {
            inlineBlockFinishLayout(doc, context, box_offsets);
            const container = &context.inline_container.items[context.inline_container.items.len - 1];
            addBlockToInlineContainer(container, used_id, box_offsets.*, margins);
        },
    }

    // The deallocations here must correspond to allocations in pushFlowBlock.
    _ = context.layout_mode.pop();
    _ = context.intervals.pop();
    _ = context.used_id.pop();
    _ = context.used_subtree_size.pop();
    _ = context.flow_block_used_logical_width.pop();
    _ = context.flow_block_auto_logical_height.pop();
    _ = context.flow_block_used_logical_heights.pop();
    const metadata = context.metadata.pop();
    if (metadata.is_stacking_context_parent) {
        _ = context.stacking_context_id.pop();
    }
    const relative_positioned_descendants_count = context.relative_positioned_descendants_count.pop();
    context.relative_positioned_descendants_ids.shrinkRetainingCapacity(context.relative_positioned_descendants_ids.items.len - relative_positioned_descendants_count);
}

/// This is an implementation of CSS2§10.2, CSS2§10.3.3, and CSS2§10.4.
fn flowBlockSolveInlineSizes(
    context: *const LayoutContext,
    box_id: BoxId,
    box_offsets: *used_values.BoxOffsets,
    borders: *used_values.Borders,
    margins: *used_values.Margins,
) !ZssUnit {
    const max = std.math.max;
    const inline_size = context.box_tree.inline_size[box_id];
    const containing_block_logical_width = context.flow_block_used_logical_width.items[context.flow_block_used_logical_width.items.len - 1];
    assert(containing_block_logical_width >= 0);

    const border_start = switch (inline_size.border_start) {
        .px => |value| try positiveLength(.px, value),
    };
    const border_end = switch (inline_size.border_end) {
        .px => |value| try positiveLength(.px, value),
    };
    const padding_start = switch (inline_size.padding_start) {
        .px => |value| try positiveLength(.px, value),
        .percentage => |value| try positivePercentage(value, containing_block_logical_width),
    };
    const padding_end = switch (inline_size.padding_end) {
        .px => |value| try positiveLength(.px, value),
        .percentage => |value| try positivePercentage(value, containing_block_logical_width),
    };

    const min_size = switch (inline_size.min_size) {
        .px => |value| try positiveLength(.px, value),
        .percentage => |value| try positivePercentage(value, max(0, containing_block_logical_width)),
    };
    const max_size = switch (inline_size.max_size) {
        .px => |value| try positiveLength(.px, value),
        .percentage => |value| try positivePercentage(value, max(0, containing_block_logical_width)),
        .none => std.math.maxInt(ZssUnit),
    };

    var auto_bitfield: u3 = 0;
    const size_bit = 4;
    const margin_start_bit = 2;
    const margin_end_bit = 1;

    var size = switch (inline_size.size) {
        .px => |value| try positiveLength(.px, value),
        .percentage => |value| try positivePercentage(value, containing_block_logical_width),
        .auto => blk: {
            auto_bitfield |= size_bit;
            break :blk 0;
        },
    };
    var margin_start = switch (inline_size.margin_start) {
        .px => |value| length(.px, value),
        .percentage => |value| percentage(value, containing_block_logical_width),
        .auto => blk: {
            auto_bitfield |= margin_start_bit;
            break :blk 0;
        },
    };
    var margin_end = switch (inline_size.margin_end) {
        .px => |value| length(.px, value),
        .percentage => |value| percentage(value, containing_block_logical_width),
        .auto => blk: {
            auto_bitfield |= margin_end_bit;
            break :blk 0;
        },
    };

    const content_margin_space = containing_block_logical_width - (border_start + border_end + padding_start + padding_end);
    if (auto_bitfield == 0) {
        // None of the values were auto, so one of the margins must be set according to the other values.
        // TODO the margin that gets set is determined by the 'direction' property
        size = zss.util.clamp(size, min_size, max_size);
        margin_end = content_margin_space - size - margin_start;
    } else if (auto_bitfield & size_bit == 0) {
        // 'inline-size' is not auto, but at least one of 'margin-inline-start' and 'margin-inline-end' is.
        // If there is only one "auto", then that value gets the remaining margin space.
        // Else, there are 2 "auto"s, and both values get half the remaining margin space.
        const start = auto_bitfield & margin_start_bit;
        const end = auto_bitfield & margin_end_bit;
        const shr_amount = @boolToInt(start | end == margin_start_bit | margin_end_bit);
        size = zss.util.clamp(size, min_size, max_size);
        const leftover_margin = max(0, content_margin_space - (size + margin_start + margin_end));
        // TODO the margin that gets the extra 1 unit shall be determined by the 'direction' property
        if (start != 0) margin_start = leftover_margin >> shr_amount;
        if (end != 0) margin_end = (leftover_margin >> shr_amount) + @mod(leftover_margin, 2);
    } else {
        // 'inline-size' is auto, so it is set according to the other values.
        // The margin values don't need to change.
        size = zss.util.clamp(content_margin_space - margin_start - margin_end, min_size, max_size);
    }

    box_offsets.border_start.x = margin_start;
    box_offsets.content_start.x = margin_start + border_start + padding_start;
    box_offsets.content_end.x = box_offsets.content_start.x + size;
    box_offsets.border_end.x = box_offsets.content_end.x + padding_end + border_end;

    borders.inline_start = border_start;
    borders.inline_end = border_end;

    margins.inline_start = margin_start;
    margins.inline_end = margin_end;

    return size;
}

/// This is an implementation of CSS2§10.5 and CSS2§10.6.3.
fn flowBlockSolveBlockSizesPart1(
    context: *const LayoutContext,
    box_id: BoxId,
    box_offsets: *used_values.BoxOffsets,
    borders: *used_values.Borders,
    margins: *used_values.Margins,
) !UsedLogicalHeights {
    const block_size = context.box_tree.block_size[box_id];
    const containing_block_logical_width = context.flow_block_used_logical_width.items[context.flow_block_used_logical_width.items.len - 1];
    const containing_block_logical_height = context.flow_block_used_logical_heights.items[context.flow_block_used_logical_heights.items.len - 1].height;
    assert(containing_block_logical_width >= 0);
    if (containing_block_logical_height) |h| assert(h >= 0);

    const size = switch (block_size.size) {
        .px => |value| try positiveLength(.px, value),
        .percentage => |value| if (containing_block_logical_height) |h|
            try positivePercentage(value, h)
        else
            null,
        .auto => null,
    };
    const border_start = switch (block_size.border_start) {
        .px => |value| try positiveLength(.px, value),
    };
    const border_end = switch (block_size.border_end) {
        .px => |value| try positiveLength(.px, value),
    };
    const padding_start = switch (block_size.padding_start) {
        .px => |value| try positiveLength(.px, value),
        .percentage => |value| try positivePercentage(value, containing_block_logical_width),
    };
    const padding_end = switch (block_size.padding_end) {
        .px => |value| try positiveLength(.px, value),
        .percentage => |value| try positivePercentage(value, containing_block_logical_width),
    };
    const margin_start = switch (block_size.margin_start) {
        .px => |value| length(.px, value),
        .percentage => |value| percentage(value, containing_block_logical_width),
        .auto => 0,
    };
    const margin_end = switch (block_size.margin_end) {
        .px => |value| length(.px, value),
        .percentage => |value| percentage(value, containing_block_logical_width),
        .auto => 0,
    };

    const min_size = switch (block_size.min_size) {
        .px => |value| try positiveLength(.px, value),
        .percentage => |value| if (containing_block_logical_height) |s|
            try positivePercentage(value, s)
        else
            0,
    };
    const max_size = switch (block_size.max_size) {
        .px => |value| try positiveLength(.px, value),
        .percentage => |value| if (containing_block_logical_height) |s|
            try positivePercentage(value, s)
        else
            std.math.maxInt(ZssUnit),
        .none => std.math.maxInt(ZssUnit),
    };

    // NOTE These are not the actual offsets, just some values that can be
    // determined without knowing 'size'. The offsets are properly filled in
    // in 'flowBlockSolveSizesPart2'.
    box_offsets.border_start.y = margin_start;
    box_offsets.content_start.y = margin_start + border_start + padding_start;
    box_offsets.border_end.y = padding_end + border_end;

    borders.block_start = border_start;
    borders.block_end = border_end;

    margins.block_start = margin_start;
    margins.block_end = margin_end;

    return UsedLogicalHeights{
        .height = size,
        .min_height = min_size,
        .max_height = max_size,
    };
}

fn flowBlockSolveBlockSizesPart2(box_offsets: *used_values.BoxOffsets, used_logical_heights: UsedLogicalHeights, auto_logical_height: ZssUnit) ZssUnit {
    const used_logical_height = zss.util.clamp(used_logical_heights.height orelse auto_logical_height, used_logical_heights.min_height, used_logical_heights.max_height);
    box_offsets.content_end.y = box_offsets.content_start.y + used_logical_height;
    box_offsets.border_end.y += box_offsets.content_end.y;
    return used_logical_height;
}

fn flowBlockFinishLayout(doc: *Document, context: *LayoutContext, box_offsets: *used_values.BoxOffsets) void {
    const used_logical_heights = context.flow_block_used_logical_heights.items[context.flow_block_used_logical_heights.items.len - 1];
    const auto_logical_height = context.flow_block_auto_logical_height.items[context.flow_block_auto_logical_height.items.len - 1];
    const logical_width = context.flow_block_used_logical_width.items[context.flow_block_used_logical_width.items.len - 1];
    const logical_height = flowBlockSolveBlockSizesPart2(box_offsets, used_logical_heights, auto_logical_height);
    blockBoxApplyRelativePositioningToChildren(doc, context, logical_width, logical_height);
}

fn pushShrinkToFit1stPassBlock(doc: *Document, context: *LayoutContext, interval: *LayoutContext.Interval) !void {
    const box_id = interval.begin;
    const subtree_size = context.box_tree.structure[box_id];
    interval.begin += subtree_size;

    const block = try createBlock(doc, context, box_id);
    block.structure.* = undefined;
    block.properties.* = .{};

    const width_info = try shrinkToFit1stPassGetWidth(context, box_id);
    // TODO This should probably be removed.
    // The heights of the block are solved in either the 2nd pass or in inlineBlockSolveSizesPart1.
    const used_logical_heights = UsedLogicalHeights{ .height = null, .min_height = 0, .max_height = std.math.maxInt(ZssUnit) };

    if (width_info.width) |width| {
        block.box_offsets.content_end.x = 0;
        const parent_shrink_to_fit_width = &context.shrink_to_fit_auto_width.items[context.shrink_to_fit_auto_width.items.len - 1];
        parent_shrink_to_fit_width.* = std.math.max(parent_shrink_to_fit_width.*, width + width_info.base_width);
        // The allocations here must have corresponding deallocations in popFlowBlock.
        try context.layout_mode.append(context.allocator, .Flow);
        try context.intervals.append(context.allocator, .{ .parent = box_id, .begin = box_id + 1, .end = box_id + subtree_size });
        try context.used_id.append(context.allocator, block.used_id);
        try context.used_subtree_size.append(context.allocator, 1);
        try context.flow_block_used_logical_width.append(context.allocator, width);
        try context.flow_block_auto_logical_height.append(context.allocator, 0);
        try context.flow_block_used_logical_heights.append(context.allocator, used_logical_heights);
        try context.relative_positioned_descendants_count.append(context.allocator, 0);
    } else {
        block.box_offsets.content_end.x = 1;
        const parent_available_width = context.shrink_to_fit_available_width.items[context.shrink_to_fit_available_width.items.len - 1];
        // The allocations here must have corresponding deallocations in popShrinkToFit1stPassBlock.
        try context.layout_mode.append(context.allocator, .ShrinkToFit1stPass);
        try context.intervals.append(context.allocator, .{ .parent = box_id, .begin = box_id + 1, .end = box_id + subtree_size });
        try context.shrink_to_fit_available_width.append(context.allocator, std.math.max(0, parent_available_width - width_info.base_width));
        try context.shrink_to_fit_auto_width.append(context.allocator, 0);
        try context.shrink_to_fit_base_width.append(context.allocator, width_info.base_width);
        try context.flow_block_used_logical_heights.append(context.allocator, used_logical_heights);
        try context.used_id.append(context.allocator, block.used_id);
        try context.used_subtree_size.append(context.allocator, 1);
        try context.relative_positioned_descendants_count.append(context.allocator, 0);
        try context.metadata.append(context.allocator, .{ .is_stacking_context_parent = false });
    }
}

fn popShrinkToFit1stPassBlock(doc: *Document, context: *LayoutContext) !void {
    const used_id = context.used_id.items[context.used_id.items.len - 1];
    const used_subtree_size = context.used_subtree_size.items[context.used_subtree_size.items.len - 1];
    doc.blocks.structure.items[used_id] = used_subtree_size;
    context.used_subtree_size.items[context.used_subtree_size.items.len - 2] += used_subtree_size;

    const shrink_to_fit_width = context.shrink_to_fit_auto_width.items[context.shrink_to_fit_auto_width.items.len - 1];

    var go_to_2nd_pass = false;
    const parent_layout_mode = context.layout_mode.items[context.layout_mode.items.len - 2];
    switch (parent_layout_mode) {
        // Valid as long as flow blocks cannot directly contain shrink-to-fit blocks.
        .Flow => unreachable,
        .ShrinkToFit1stPass => {
            const parent_shrink_to_fit_width = &context.shrink_to_fit_auto_width.items[context.shrink_to_fit_auto_width.items.len - 2];
            const base_width = context.shrink_to_fit_base_width.items[context.shrink_to_fit_base_width.items.len - 1];
            parent_shrink_to_fit_width.* = std.math.max(parent_shrink_to_fit_width.*, shrink_to_fit_width + base_width);
        },
        .ShrinkToFit2ndPass => @panic("unimplemented"),
        .InlineContainer => {
            go_to_2nd_pass = true;
        },
    }

    _ = context.layout_mode.pop();
    _ = context.intervals.pop();
    _ = context.shrink_to_fit_available_width.pop();
    _ = context.shrink_to_fit_auto_width.pop();
    _ = context.shrink_to_fit_base_width.pop();
    _ = context.flow_block_used_logical_heights.pop();
    _ = context.used_id.pop();
    _ = context.used_subtree_size.pop();
    const metadata = context.metadata.pop();
    if (metadata.is_stacking_context_parent) {
        _ = context.stacking_context_id.pop();
    }
    const relative_positioned_descendants_count = context.relative_positioned_descendants_count.pop();
    context.relative_positioned_descendants_ids.shrinkRetainingCapacity(context.relative_positioned_descendants_ids.items.len - relative_positioned_descendants_count);

    if (go_to_2nd_pass) {
        const box_id = context.used_id_to_box_id.items[used_id];
        const box_offsets = &doc.blocks.box_offsets.items[used_id];
        const borders = &doc.blocks.borders.items[used_id];
        const margins = &doc.blocks.margins.items[used_id];
        const used_logical_heights = try flowBlockSolveBlockSizesPart1(context, box_id, box_offsets, borders, margins);

        try context.layout_mode.append(context.allocator, .ShrinkToFit2ndPass);
        try context.flow_block_used_logical_width.append(context.allocator, shrink_to_fit_width);
        try context.flow_block_auto_logical_height.append(context.allocator, 0);
        try context.flow_block_used_logical_heights.append(context.allocator, used_logical_heights);
        try context.used_id.append(context.allocator, used_id);
        try context.used_id_intervals.append(context.allocator, .{ .begin = used_id + 1, .end = used_id + doc.blocks.structure.items[used_id] });
    }
}

const ShrinkToFit1stPassGetWidthResult = struct {
    base_width: ZssUnit,
    width: ?ZssUnit,
};

fn shrinkToFit1stPassGetWidth(
    context: *const LayoutContext,
    box_id: BoxId,
) !ShrinkToFit1stPassGetWidthResult {
    const inline_size = context.box_tree.inline_size[box_id];
    var result = ShrinkToFit1stPassGetWidthResult{ .base_width = 0, .width = null };

    switch (inline_size.border_start) {
        .px => |value| result.base_width += try positiveLength(.px, value),
    }
    switch (inline_size.border_end) {
        .px => |value| result.base_width += try positiveLength(.px, value),
    }
    switch (inline_size.padding_start) {
        .px => |value| result.base_width += try positiveLength(.px, value),
        .percentage => {},
    }
    switch (inline_size.padding_end) {
        .px => |value| result.base_width += try positiveLength(.px, value),
        .percentage => {},
    }
    switch (inline_size.margin_start) {
        .px => |value| result.base_width += length(.px, value),
        .percentage => {},
        .auto => {},
    }
    switch (inline_size.margin_end) {
        .px => |value| result.base_width += length(.px, value),
        .percentage => {},
        .auto => {},
    }

    switch (inline_size.size) {
        .px => |value| {
            var size = try positiveLength(.px, value);
            // TODO should min_size play a role regardless of the value of size?
            switch (inline_size.min_size) {
                .px => |min_value| size = std.math.max(size, try positiveLength(.px, min_value)),
                .percentage => {},
            }
            switch (inline_size.max_size) {
                .px => |max_value| size = std.math.min(size, try positiveLength(.px, max_value)),
                .percentage => {},
                .none => {},
            }
            result.width = size;
        },
        .percentage => {},
        .auto => {},
    }

    return result;
}

fn pushShrinkToFit2ndPassBlock(doc: *Document, context: *LayoutContext, used_id_interval: *UsedIdInterval) !void {
    const used_id = used_id_interval.begin;
    const used_subtree_size = doc.blocks.structure.items[used_id_interval.begin];
    used_id_interval.begin += used_subtree_size;

    const properties = doc.blocks.properties.items[used_id];
    if (properties.inline_context_index) |index| {
        @panic("unimplemented");
    }

    const box_id = context.used_id_to_box_id.items[used_id];

    const box_offsets = &doc.blocks.box_offsets.items[used_id];
    const borders = &doc.blocks.borders.items[used_id];
    const margins = &doc.blocks.margins.items[used_id];
    switch (box_offsets.content_end.x) {
        0 => @panic("TODO fixed width block in shrink-to-fit 2nd pass"),
        1 => {
            const logical_width = try flowBlockSolveInlineSizes(context, box_id, box_offsets, borders, margins);
            const used_logical_heights = try flowBlockSolveBlockSizesPart1(context, box_id, box_offsets, borders, margins);

            try context.layout_mode.append(context.allocator, .ShrinkToFit2ndPass);
            try context.flow_block_used_logical_width.append(context.allocator, logical_width);
            try context.flow_block_auto_logical_height.append(context.allocator, 0);
            try context.flow_block_used_logical_heights.append(context.allocator, used_logical_heights);
            try context.used_id.append(context.allocator, used_id);
            try context.used_id_intervals.append(context.allocator, .{ .begin = used_id + 1, .end = used_id + used_subtree_size });
        },
        else => unreachable,
    }
}

fn popShrinkToFit2ndPassBlock(doc: *Document, context: *LayoutContext) void {
    const used_id = context.used_id.items[context.used_id.items.len - 1];
    const box_offsets = &doc.blocks.box_offsets.items[used_id];
    const margins = doc.blocks.margins.items[used_id];

    const parent_layout_mode = context.layout_mode.items[context.layout_mode.items.len - 2];
    switch (parent_layout_mode) {
        .Flow => @panic("unimplemented"),
        .ShrinkToFit1stPass => @panic("unimplemented"),
        .ShrinkToFit2ndPass => {
            flowBlockFinishLayout(doc, context, box_offsets);
            const parent_auto_logical_height = &context.flow_block_auto_logical_height.items[context.flow_block_auto_logical_height.items.len - 2];
            addBlockToFlow(box_offsets, margins.block_end, parent_auto_logical_height);
        },
        .InlineContainer => {
            inlineBlockFinishLayout(doc, context, box_offsets);
            const container = &context.inline_container.items[context.inline_container.items.len - 1];
            addBlockToInlineContainer(container, used_id, box_offsets.*, margins);
        },
    }

    _ = context.layout_mode.pop();
    _ = context.flow_block_used_logical_width.pop();
    _ = context.flow_block_auto_logical_height.pop();
    _ = context.flow_block_used_logical_heights.pop();
    _ = context.used_id.pop();
    _ = context.used_id_intervals.pop();
}

fn pushInlineContainer(doc: *Document, context: *LayoutContext, interval: *LayoutContext.Interval) !void {
    var inline_blocks = ArrayListUnmanaged(InlineBlock){};
    errdefer inline_blocks.deinit(context.allocator);

    const containing_block_logical_width = context.flow_block_used_logical_width.items[context.flow_block_used_logical_width.items.len - 1];
    var inline_context = InlineLayoutContext.init(context.box_tree, context.allocator, interval.*, containing_block_logical_width, &inline_blocks);
    defer inline_context.deinit();

    const inline_values_ptr = try doc.allocator.create(InlineLevelUsedValues);
    errdefer doc.allocator.destroy(inline_values_ptr);
    inline_values_ptr.* = .{};
    errdefer inline_values_ptr.deinit(doc.allocator);

    try createInlineLevelUsedValues(doc, &inline_context, inline_values_ptr);

    if (inline_context.next_box_id != interval.parent + context.box_tree.structure[interval.parent]) {
        @panic("TODO A group of inline-level elements cannot be interrupted by a block-level element");
    }
    interval.begin = inline_context.next_box_id;
    try doc.inlines.append(doc.allocator, inline_values_ptr);

    // Create an "anonymous block box" to contain this inline formatting context.
    const block = try createBlock(doc, context, reserved_box_id);
    block.structure.* = undefined;
    block.box_offsets.* = .{
        .border_start = .{ .x = 0, .y = 0 },
        .border_end = .{ .x = containing_block_logical_width, .y = 0 },
        .content_start = .{ .x = 0, .y = 0 },
        .content_end = .{ .x = containing_block_logical_width, .y = 0 },
    };
    block.borders.* = .{};
    block.margins.* = .{};
    block.properties.* = .{ .inline_context_index = try std.math.cast(InlineId, doc.inlines.items.len - 1) };

    if (inline_blocks.items.len != 0) {
        // The allocations here must have corresponding deallocations in popInlineContainer.
        try context.layout_mode.append(context.allocator, .InlineContainer);
        try context.used_id.append(context.allocator, block.used_id);
        try context.used_subtree_size.append(context.allocator, 1);
        try context.inline_container.append(context.allocator, .{
            .values = inline_values_ptr,
            .containing_block_logical_width = containing_block_logical_width,
            .inline_blocks = inline_blocks.toOwnedSlice(context.allocator),
            .next_inline_block = 0,
        });
    } else {
        // Optimized path for containers that have no inline-blocks. It is a shorter version of popInlineContainer.
        block.structure.* = 1;
        context.used_subtree_size.items[context.used_subtree_size.items.len - 1] += 1;

        const total_logical_height = try inlineValuesFinishLayout(doc, context, inline_values_ptr, containing_block_logical_width);
        block.box_offsets.content_end.y = total_logical_height;
        block.box_offsets.border_end.y = total_logical_height;

        const parent_layout_mode = context.layout_mode.items[context.layout_mode.items.len - 1];
        switch (parent_layout_mode) {
            .Flow => {
                const parent_auto_logical_height = &context.flow_block_auto_logical_height.items[context.flow_block_auto_logical_height.items.len - 1];
                addBlockToFlow(block.box_offsets, 0, parent_auto_logical_height);
            },
            .ShrinkToFit1stPass => @panic("unimplemented"),
            .ShrinkToFit2ndPass => @panic("unimplemented"),
            .InlineContainer => unreachable,
        }
    }
}

fn popInlineContainer(doc: *Document, context: *LayoutContext) !void {
    const used_id = context.used_id.items[context.used_id.items.len - 1];
    const used_subtree_size = context.used_subtree_size.items[context.used_subtree_size.items.len - 1];
    doc.blocks.structure.items[used_id] = used_subtree_size;
    context.used_subtree_size.items[context.used_subtree_size.items.len - 2] += used_subtree_size;

    const container = &context.inline_container.items[context.inline_container.items.len - 1];
    const containing_block_logical_width = context.flow_block_used_logical_width.items[context.flow_block_used_logical_width.items.len - 1];
    const total_logical_height = try inlineValuesFinishLayout(doc, context, container.values, containing_block_logical_width);

    inlineContainerPositionInlineBlocks(doc, container.*);

    const box_offsets = &doc.blocks.box_offsets.items[used_id];
    box_offsets.content_end.y = total_logical_height;
    box_offsets.border_end.y = total_logical_height;

    const parent_layout_mode = context.layout_mode.items[context.layout_mode.items.len - 2];
    switch (parent_layout_mode) {
        .Flow => {
            const parent_auto_logical_height = &context.flow_block_auto_logical_height.items[context.flow_block_auto_logical_height.items.len - 1];
            addBlockToFlow(box_offsets, 0, parent_auto_logical_height);
        },
        .ShrinkToFit1stPass => @panic("unimplemented"),
        .ShrinkToFit2ndPass => @panic("unimplemented"),
        .InlineContainer => unreachable,
    }

    // The deallocations here must correspond to allocations in pushInlineContainer.
    _ = context.layout_mode.pop();
    _ = context.used_id.pop();
    _ = context.used_subtree_size.pop();
    container.deinit(context.allocator);
    _ = context.inline_container.pop();
}

fn inlineContainerPositionInlineBlocks(doc: *Document, container: InlineContainer) void {
    for (container.inline_blocks) |inline_block| {
        const my_line_box = for (container.values.line_boxes.items) |line_box| {
            if (inline_block.index >= line_box.elements[0] and inline_block.index < line_box.elements[1]) break line_box;
        } else unreachable;
        var i = my_line_box.elements[0];
        var distance: ZssUnit = 0;
        while (i < inline_block.index) : (i += 1) {
            distance += container.values.metrics.items[i].advance;
            if (container.values.glyph_indeces.items[i] == 0) {
                i += 1;
            }
        }

        const special = InlineLevelUsedValues.Special.decode(container.values.glyph_indeces.items[i + 1]);
        const used_id: UsedId = special.data;
        const box_offsets = &doc.blocks.box_offsets.items[used_id];
        const margins = doc.blocks.margins.items[used_id];
        const translation_inline = distance + margins.inline_start;
        const translation_block = my_line_box.baseline - (box_offsets.border_end.y - box_offsets.border_start.y) - margins.block_start - margins.block_end;
        inline for (std.meta.fields(used_values.BoxOffsets)) |field| {
            const v = &@field(box_offsets.*, field.name);
            v.x += translation_inline;
            v.y += translation_block;
        }
    }
}

fn addBlockToInlineContainer(container: *InlineContainer, used_id: UsedId, box_offsets: used_values.BoxOffsets, margins: used_values.Margins) void {
    const inline_block = container.inline_blocks[container.next_inline_block];
    container.next_inline_block += 1;

    const fragment_width = box_offsets.border_end.x - box_offsets.border_start.x;
    const fragment_advance = fragment_width + margins.inline_start + margins.inline_end;
    container.values.glyph_indeces.items[inline_block.index + 1] = InlineLevelUsedValues.Special.encodeInlineBlock(used_id);
    container.values.metrics.items[inline_block.index] = .{ .offset = margins.inline_start, .advance = fragment_advance, .width = fragment_width };
}

fn pushInlineBlock(doc: *Document, context: *LayoutContext, container: InlineContainer) !void {
    const inline_block = container.inline_blocks[container.next_inline_block];
    const box_id = inline_block.box_id;
    const subtree_size = context.box_tree.structure[box_id];

    const block = try createBlock(doc, context, box_id);
    block.structure.* = undefined;
    block.properties.* = .{};

    _ = try createStackingContext(doc, context, block, 0);

    const sizes = try inlineBlockSolveSizesPart1(context, inline_block.box_id, block.box_offsets, block.borders, block.margins);

    if (sizes.logical_width) |logical_width| {
        // The allocations here must have corresponding deallocations in popFlowBlock.
        try context.layout_mode.append(context.allocator, .Flow);
        try context.intervals.append(context.allocator, .{ .parent = box_id, .begin = box_id + 1, .end = box_id + subtree_size });
        try context.flow_block_used_logical_width.append(context.allocator, logical_width);
        try context.flow_block_auto_logical_height.append(context.allocator, 0);
        try context.flow_block_used_logical_heights.append(context.allocator, sizes.logical_heights);
        try context.used_id.append(context.allocator, block.used_id);
        try context.used_subtree_size.append(context.allocator, 1);
        try context.relative_positioned_descendants_count.append(context.allocator, 0);
        try context.metadata.append(context.allocator, .{ .is_stacking_context_parent = false });
    } else {
        const base_width = (block.box_offsets.content_start.x - block.box_offsets.border_start.x) + (block.box_offsets.border_end.x - block.box_offsets.content_end.x) + block.margins.inline_start + block.margins.inline_end;
        const available_width = container.containing_block_logical_width - base_width;
        // The allocations here must have corresponding deallocations in popShrinkToFit1stPassBlock.
        try context.layout_mode.append(context.allocator, .ShrinkToFit1stPass);
        try context.intervals.append(context.allocator, .{ .parent = box_id, .begin = box_id + 1, .end = box_id + subtree_size });
        try context.flow_block_auto_logical_height.append(context.allocator, 0);
        try context.flow_block_used_logical_heights.append(context.allocator, sizes.logical_heights);
        try context.shrink_to_fit_available_width.append(context.allocator, std.math.max(0, available_width));
        try context.shrink_to_fit_auto_width.append(context.allocator, 0);
        try context.shrink_to_fit_base_width.append(context.allocator, base_width);
        try context.used_id.append(context.allocator, block.used_id);
        try context.used_subtree_size.append(context.allocator, 1);
        try context.relative_positioned_descendants_count.append(context.allocator, 0);
        try context.metadata.append(context.allocator, .{ .is_stacking_context_parent = false });
    }
}

const InlineBlockSolveSizesResult = struct {
    logical_width: ?ZssUnit,
    logical_heights: UsedLogicalHeights,
};

fn inlineBlockSolveSizesPart1(
    context: *LayoutContext,
    box_id: BoxId,
    box_offsets: *used_values.BoxOffsets,
    borders: *used_values.Borders,
    margins: *used_values.Margins,
) !InlineBlockSolveSizesResult {
    const max = std.math.max;
    const inline_sizes = context.box_tree.inline_size[box_id];
    const block_sizes = context.box_tree.block_size[box_id];
    const containing_block_logical_width = context.flow_block_used_logical_width.items[context.flow_block_used_logical_width.items.len - 1];
    assert(containing_block_logical_width >= 0);

    const border_inline_start = switch (inline_sizes.border_start) {
        .px => |value| try positiveLength(.px, value),
    };
    const border_inline_end = switch (inline_sizes.border_end) {
        .px => |value| try positiveLength(.px, value),
    };
    const padding_inline_start = switch (inline_sizes.padding_start) {
        .px => |value| try positiveLength(.px, value),
        .percentage => |value| try positivePercentage(value, containing_block_logical_width),
    };
    const padding_inline_end = switch (inline_sizes.padding_end) {
        .px => |value| try positiveLength(.px, value),
        .percentage => |value| try positivePercentage(value, containing_block_logical_width),
    };
    const margin_inline_start = switch (inline_sizes.margin_start) {
        .px => |value| length(.px, value),
        .percentage => |value| percentage(value, containing_block_logical_width),
        .auto => 0,
    };
    const margin_inline_end = switch (inline_sizes.margin_end) {
        .px => |value| length(.px, value),
        .percentage => |value| percentage(value, containing_block_logical_width),
        .auto => 0,
    };
    const min_inline_size = switch (inline_sizes.min_size) {
        .px => |value| try positiveLength(.px, value),
        .percentage => |value| try positivePercentage(value, max(0, containing_block_logical_width)),
    };
    const max_inline_size = switch (inline_sizes.max_size) {
        .px => |value| try positiveLength(.px, value),
        .percentage => |value| try positivePercentage(value, max(0, containing_block_logical_width)),
        .none => std.math.maxInt(ZssUnit),
    };
    const inline_size = switch (inline_sizes.size) {
        .px => |value| try positiveLength(.px, value),
        .percentage => |value| try positivePercentage(value, containing_block_logical_width),
        .auto => null,
    };

    const border_block_start = switch (block_sizes.border_start) {
        .px => |value| try positiveLength(.px, value),
    };
    const border_block_end = switch (block_sizes.border_end) {
        .px => |value| try positiveLength(.px, value),
    };
    const padding_block_start = switch (block_sizes.padding_start) {
        .px => |value| try positiveLength(.px, value),
        .percentage => |value| try positivePercentage(value, containing_block_logical_width),
    };
    const padding_block_end = switch (block_sizes.padding_end) {
        .px => |value| try positiveLength(.px, value),
        .percentage => |value| try positivePercentage(value, containing_block_logical_width),
    };
    const margin_block_start = switch (block_sizes.margin_start) {
        .px => |value| length(.px, value),
        .percentage => |value| percentage(value, containing_block_logical_width),
        .auto => 0,
    };
    const margin_block_end = switch (block_sizes.margin_end) {
        .px => |value| length(.px, value),
        .percentage => |value| percentage(value, containing_block_logical_width),
        .auto => 0,
    };
    const min_block_size = switch (block_sizes.min_size) {
        .px => |value| try positiveLength(.px, value),
        .percentage => |value| try positivePercentage(value, max(0, containing_block_logical_width)),
    };
    const max_block_size = switch (block_sizes.max_size) {
        .px => |value| try positiveLength(.px, value),
        .percentage => |value| try positivePercentage(value, max(0, containing_block_logical_width)),
        .none => std.math.maxInt(ZssUnit),
    };
    const block_size = switch (block_sizes.size) {
        .px => |value| try positiveLength(.px, value),
        .percentage => |value| try positivePercentage(value, containing_block_logical_width),
        .auto => null,
    };

    box_offsets.border_start = .{ .x = margin_inline_start, .y = margin_block_start };
    box_offsets.content_start = .{
        .x = margin_inline_start + border_inline_start + padding_inline_start,
        .y = margin_block_start + border_block_start + padding_block_start,
    };
    box_offsets.border_end = .{ .x = border_inline_end + padding_inline_end, .y = border_block_end + padding_block_end };
    borders.* = .{ .inline_start = border_inline_start, .inline_end = border_inline_end, .block_start = border_block_start, .block_end = border_block_end };
    margins.* = .{ .inline_start = margin_inline_start, .inline_end = margin_inline_end, .block_start = margin_block_start, .block_end = margin_block_end };

    return InlineBlockSolveSizesResult{
        .logical_width = if (inline_size) |s| zss.util.clamp(s, min_inline_size, max_inline_size) else null,
        .logical_heights = UsedLogicalHeights{
            .height = block_size,
            .min_height = min_block_size,
            .max_height = max_block_size,
        },
    };
}

fn inlineBlockSolveSizesPart2(box_offsets: *used_values.BoxOffsets, used_logical_width: ZssUnit, used_logical_heights: UsedLogicalHeights, auto_logical_height: ZssUnit) ZssUnit {
    const used_logical_height = zss.util.clamp(used_logical_heights.height orelse auto_logical_height, used_logical_heights.min_height, used_logical_heights.max_height);
    box_offsets.content_end = .{
        .x = box_offsets.content_start.x + used_logical_width,
        .y = box_offsets.content_start.y + used_logical_height,
    };
    box_offsets.border_end.x += box_offsets.content_end.x;
    box_offsets.border_end.y += box_offsets.content_end.y;
    return used_logical_height;
}

fn inlineBlockFinishLayout(doc: *Document, context: *LayoutContext, box_offsets: *used_values.BoxOffsets) void {
    const used_logical_width = context.flow_block_used_logical_width.items[context.flow_block_used_logical_width.items.len - 1];
    const auto_logical_height = context.flow_block_auto_logical_height.items[context.flow_block_auto_logical_height.items.len - 1];
    const used_logical_heights = context.flow_block_used_logical_heights.items[context.flow_block_used_logical_heights.items.len - 1];
    const used_logical_height = inlineBlockSolveSizesPart2(box_offsets, used_logical_width, used_logical_heights, auto_logical_height);

    blockBoxApplyRelativePositioningToChildren(doc, context, used_logical_width, used_logical_height);
}

const Block = struct {
    used_id: UsedId,
    structure: *UsedId,
    box_offsets: *used_values.BoxOffsets,
    borders: *used_values.Borders,
    margins: *used_values.Margins,
    properties: *BlockLevelUsedValues.BoxProperties,
};

fn createBlock(doc: *Document, context: *LayoutContext, box_id: BoxId) !Block {
    assert(doc.blocks.structure.items.len == context.used_id_to_box_id.items.len);
    const used_id = try std.math.cast(UsedId, doc.blocks.structure.items.len);
    try context.used_id_to_box_id.append(context.allocator, box_id);
    return Block{
        .used_id = used_id,
        .structure = try doc.blocks.structure.addOne(doc.allocator),
        .box_offsets = try doc.blocks.box_offsets.addOne(doc.allocator),
        .borders = try doc.blocks.borders.addOne(doc.allocator),
        .margins = try doc.blocks.margins.addOne(doc.allocator),
        .properties = try doc.blocks.properties.addOne(doc.allocator),
    };
}

fn blockBoxSolveOtherProperties(doc: *Document, box_tree: *const BoxTree, box_id: BoxId, used_id: UsedId) !void {
    const box_offsets_ptr = &doc.blocks.box_offsets.items[used_id];
    const borders_ptr = &doc.blocks.borders.items[used_id];

    const border_colors_ptr = &doc.blocks.border_colors.items[used_id];
    border_colors_ptr.* = solveBorderColors(box_tree.border[box_id]);

    const background1_ptr = &doc.blocks.background1.items[used_id];
    const background2_ptr = &doc.blocks.background2.items[used_id];
    const background = box_tree.background[box_id];
    background1_ptr.* = solveBackground1(background);
    background2_ptr.* = try solveBackground2(background, box_offsets_ptr, borders_ptr);
}

fn blockBoxFillOtherPropertiesWithDefaults(doc: *Document, used_id: UsedId) void {
    doc.blocks.borders.items[used_id] = .{};
    doc.blocks.background1.items[used_id] = .{};
    doc.blocks.background2.items[used_id] = .{};
}

fn createStackingContext(doc: *Document, context: *LayoutContext, block: Block, z_index: ZIndex) !StackingContextId {
    const parent_stacking_context_id = context.stacking_context_id.items[context.stacking_context_id.items.len - 1];
    var current = parent_stacking_context_id + 1;
    const end = parent_stacking_context_id + doc.blocks.stacking_context_structure.items[parent_stacking_context_id];
    while (current < end and z_index >= doc.blocks.stacking_contexts.items[current].z_index) : (current += doc.blocks.stacking_context_structure.items[current]) {}

    for (context.stacking_context_id.items) |index| {
        doc.blocks.stacking_context_structure.items[index] += 1;
    }
    try doc.blocks.stacking_context_structure.insert(doc.allocator, current, 1);
    try doc.blocks.stacking_contexts.insert(doc.allocator, current, .{ .z_index = z_index, .used_id = block.used_id });
    block.properties.creates_stacking_context = true;
    return current;
}

fn blockBoxApplyRelativePositioningToChildren(doc: *Document, context: *LayoutContext, containing_block_logical_width: ZssUnit, containing_block_logical_height: ZssUnit) void {
    const count = context.relative_positioned_descendants_count.items[context.relative_positioned_descendants_count.items.len - 1];
    var i: UsedBoxCount = 0;
    while (i < count) : (i += 1) {
        const used_id = context.relative_positioned_descendants_ids.items[context.relative_positioned_descendants_ids.items.len - 1 - i];
        const box_id = context.used_id_to_box_id.items[used_id];
        const insets = context.box_tree.insets[box_id];
        const box_offsets = &doc.blocks.box_offsets.items[used_id];

        const inline_start = switch (insets.inline_start) {
            .px => |value| length(.px, value),
            .percentage => |value| percentage(value, containing_block_logical_width),
            .auto => null,
        };
        const inline_end = switch (insets.inline_end) {
            .px => |value| -length(.px, value),
            .percentage => |value| -percentage(value, containing_block_logical_width),
            .auto => null,
        };
        const block_start = switch (insets.block_start) {
            .px => |value| length(.px, value),
            .percentage => |value| percentage(value, containing_block_logical_height),
            .auto => null,
        };
        const block_end = switch (insets.block_end) {
            .px => |value| -length(.px, value),
            .percentage => |value| -percentage(value, containing_block_logical_height),
            .auto => null,
        };

        // TODO the value of the 'direction' property matters here
        const translation_inline = inline_start orelse inline_end orelse 0;
        const translation_block = block_start orelse block_end orelse 0;

        inline for (std.meta.fields(used_values.BoxOffsets)) |field| {
            const offset = &@field(box_offsets, field.name);
            offset.x += translation_inline;
            offset.y += translation_block;
        }
    }
}

const InlineLayoutContext = struct {
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
    containing_block_logical_width: ZssUnit,

    inline_blocks: *ArrayListUnmanaged(InlineBlock),
    next_box_id: BoxId,

    fn init(
        box_tree: *const BoxTree,
        allocator: *Allocator,
        block_container_interval: LayoutContext.Interval,
        containing_block_logical_width: ZssUnit,
        inline_blocks: *ArrayListUnmanaged(InlineBlock),
    ) Self {
        return Self{
            .box_tree = box_tree,
            .intervals = .{},
            .used_ids = .{},
            .allocator = allocator,
            .root_interval = Interval{ .begin = block_container_interval.begin, .end = block_container_interval.end },
            .containing_block_logical_width = containing_block_logical_width,
            .inline_blocks = inline_blocks,
            .next_box_id = block_container_interval.end,
        };
    }

    fn deinit(self: *Self) void {
        self.intervals.deinit(self.allocator);
        self.used_ids.deinit(self.allocator);
    }
};

fn createInlineLevelUsedValues(doc: *Document, context: *InlineLayoutContext, values: *InlineLevelUsedValues) Error!void {
    const root_interval = context.root_interval;

    values.ensureCapacity(doc.allocator, root_interval.end - root_interval.begin + 1) catch {};

    try inlineLevelRootElementPush(doc, context, values, root_interval);

    while (context.intervals.items.len > 0) {
        const interval = &context.intervals.items[context.intervals.items.len - 1];
        if (interval.begin != interval.end) {
            const should_break = try inlineLevelElementPush(doc, context, values, interval);
            if (should_break) break;
        } else {
            try inlineLevelElementPop(doc, context, values);
        }
    }
}

fn inlineLevelRootElementPush(doc: *Document, context: *InlineLayoutContext, values: *InlineLevelUsedValues, root_interval: InlineLayoutContext.Interval) !void {
    const root_used_id = try addRootInlineBoxData(doc, values);
    try addBoxStart(doc, values, root_used_id);

    if (root_interval.begin != root_interval.end) {
        try context.intervals.append(context.allocator, root_interval);
        try context.used_ids.append(context.allocator, root_used_id);
    } else {
        try addBoxEnd(doc, values, root_used_id);
    }
}

fn inlineLevelElementPush(doc: *Document, context: *InlineLayoutContext, values: *InlineLevelUsedValues, interval: *InlineLayoutContext.Interval) !bool {
    const box_id = interval.begin;
    const subtree_size = context.box_tree.structure[box_id];
    interval.begin += subtree_size;

    switch (context.box_tree.display[box_id]) {
        .inline_ => {
            const used_id = try addInlineElementData(doc, context, values, box_id, context.containing_block_logical_width);
            try addBoxStart(doc, values, used_id);

            if (subtree_size != 1) {
                try context.intervals.append(context.allocator, .{ .begin = box_id + 1, .end = box_id + subtree_size });
                try context.used_ids.append(context.allocator, used_id);
            } else {
                // Optimized path for elements that have no children. It is like a shorter version of inlineLevelElementPop.
                try addBoxEnd(doc, values, used_id);
            }
        },
        .inline_block => {
            try values.glyph_indeces.appendSlice(doc.allocator, &.{ 0, undefined });
            try values.metrics.appendSlice(doc.allocator, &.{ undefined, undefined });
            try context.inline_blocks.append(context.allocator, .{ .box_id = box_id, .index = values.glyph_indeces.items.len - 2 });
        },
        .text => try addText(doc, values, context.box_tree.latin1_text[box_id], context.box_tree.font),
        .block => {
            // Immediately finish off this inline layout context.
            context.next_box_id = box_id;
            return true;
        },
        .none => {},
    }

    return false;
}

fn inlineLevelElementPop(doc: *Document, context: *InlineLayoutContext, values: *InlineLevelUsedValues) !void {
    const used_id = context.used_ids.items[context.used_ids.items.len - 1];
    try addBoxEnd(doc, values, used_id);

    _ = context.intervals.pop();
    _ = context.used_ids.pop();
}

fn addText(doc: *Document, values: *InlineLevelUsedValues, latin1_text: BoxTree.Latin1Text, font: BoxTree.Font) !void {
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
                try endTextRun(doc, values, latin1_text, buffer, font.font, run_begin, run_end);
                try addLineBreak(doc, values);
                run_begin = run_end + 1;
            },
            '\r' => {
                try endTextRun(doc, values, latin1_text, buffer, font.font, run_begin, run_end);
                try addLineBreak(doc, values);
                run_end += @boolToInt(run_end + 1 < latin1_text.text.len and latin1_text.text[run_end + 1] == '\n');
                run_begin = run_end + 1;
            },
            '\t' => {
                try endTextRun(doc, values, latin1_text, buffer, font.font, run_begin, run_end);
                run_begin = run_end + 1;
                // TODO tab size should be determined by the 'tab-size' property
                const tab_size = 8;
                hb.hb_buffer_add_latin1(buffer, " " ** tab_size, tab_size, 0, tab_size);
                if (hb.hb_buffer_allocation_successful(buffer) == 0) return error.OutOfMemory;
                try addTextRun(doc, values, buffer, font.font);
                assert(hb.hb_buffer_set_length(buffer, 0) != 0);
            },
            else => {},
        }
    }

    try endTextRun(doc, values, latin1_text, buffer, font.font, run_begin, run_end);
}

fn endTextRun(doc: *Document, values: *InlineLevelUsedValues, latin1_text: BoxTree.Latin1Text, buffer: *hb.hb_buffer_t, font: *hb.hb_font_t, run_begin: usize, run_end: usize) !void {
    if (run_end > run_begin) {
        hb.hb_buffer_add_latin1(buffer, latin1_text.text.ptr, @intCast(c_int, latin1_text.text.len), @intCast(c_uint, run_begin), @intCast(c_int, run_end - run_begin));
        if (hb.hb_buffer_allocation_successful(buffer) == 0) return error.OutOfMemory;
        try addTextRun(doc, values, buffer, font);
        assert(hb.hb_buffer_set_length(buffer, 0) != 0);
    }
}

fn addTextRun(doc: *Document, values: *InlineLevelUsedValues, buffer: *hb.hb_buffer_t, font: *hb.hb_font_t) !void {
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
    try values.glyph_indeces.ensureCapacity(doc.allocator, old_len + 2 * glyph_infos.len);
    try values.metrics.ensureCapacity(doc.allocator, old_len + 2 * glyph_infos.len);

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

fn addLineBreak(doc: *Document, values: *InlineLevelUsedValues) !void {
    try values.glyph_indeces.appendSlice(doc.allocator, &.{ 0, InlineLevelUsedValues.Special.encodeLineBreak() });
    try values.metrics.appendSlice(doc.allocator, &.{ .{ .offset = 0, .advance = 0, .width = 0 }, undefined });
}

fn addBoxStart(doc: *Document, values: *InlineLevelUsedValues, used_id: UsedId) !void {
    const inline_start = values.inline_start.items[used_id];
    const margin = values.margins.items[used_id].start;
    const width = inline_start.border + inline_start.padding;
    const advance = width + margin;

    const glyph_indeces = [2]hb.hb_codepoint_t{ 0, InlineLevelUsedValues.Special.encodeBoxStart(used_id) };
    try values.glyph_indeces.appendSlice(doc.allocator, &glyph_indeces);
    const metrics = [2]InlineLevelUsedValues.Metrics{ .{ .offset = margin, .advance = advance, .width = width }, undefined };
    try values.metrics.appendSlice(doc.allocator, &metrics);
}

fn addBoxEnd(doc: *Document, values: *InlineLevelUsedValues, used_id: UsedId) !void {
    const inline_end = values.inline_end.items[used_id];
    const margin = values.margins.items[used_id].end;
    const width = inline_end.border + inline_end.padding;
    const advance = width + margin;

    const glyph_indeces = [2]hb.hb_codepoint_t{ 0, InlineLevelUsedValues.Special.encodeBoxEnd(used_id) };
    try values.glyph_indeces.appendSlice(doc.allocator, &glyph_indeces);
    const metrics = [2]InlineLevelUsedValues.Metrics{ .{ .offset = 0, .advance = advance, .width = width }, undefined };
    try values.metrics.appendSlice(doc.allocator, &metrics);
}

fn addRootInlineBoxData(doc: *Document, values: *InlineLevelUsedValues) !UsedId {
    try values.inline_start.append(doc.allocator, .{ .border = 0, .padding = 0, .border_color_rgba = 0 });
    try values.inline_end.append(doc.allocator, .{ .border = 0, .padding = 0, .border_color_rgba = 0 });
    try values.block_start.append(doc.allocator, .{ .border = 0, .padding = 0, .border_color_rgba = 0 });
    try values.block_end.append(doc.allocator, .{ .border = 0, .padding = 0, .border_color_rgba = 0 });
    try values.margins.append(doc.allocator, .{ .start = 0, .end = 0 });
    try values.background1.append(doc.allocator, .{});
    return 0;
}

fn addInlineElementData(doc: *Document, context: *InlineLayoutContext, values: *InlineLevelUsedValues, box_id: BoxId, containing_block_logical_width: ZssUnit) !UsedId {
    const inline_sizes = context.box_tree.inline_size[box_id];

    const margin_inline_start = switch (inline_sizes.margin_start) {
        .px => |value| length(.px, value),
        .percentage => |value| percentage(value, containing_block_logical_width),
        .auto => 0,
    };
    const border_inline_start = switch (inline_sizes.border_start) {
        .px => |value| try positiveLength(.px, value),
    };
    const padding_inline_start = switch (inline_sizes.padding_start) {
        .px => |value| try positiveLength(.px, value),
        .percentage => |value| try positivePercentage(value, containing_block_logical_width),
    };
    const margin_inline_end = switch (inline_sizes.margin_end) {
        .px => |value| length(.px, value),
        .percentage => |value| percentage(value, containing_block_logical_width),
        .auto => 0,
    };
    const border_inline_end = switch (inline_sizes.border_end) {
        .px => |value| try positiveLength(.px, value),
    };
    const padding_inline_end = switch (inline_sizes.padding_end) {
        .px => |value| try positiveLength(.px, value),
        .percentage => |value| try positivePercentage(value, containing_block_logical_width),
    };

    const block_sizes = context.box_tree.block_size[box_id];

    const border_block_start = switch (block_sizes.border_start) {
        .px => |value| try positiveLength(.px, value),
    };
    const padding_block_start = switch (block_sizes.padding_start) {
        .px => |value| try positiveLength(.px, value),
        .percentage => |value| try positivePercentage(value, containing_block_logical_width),
    };
    const border_block_end = switch (block_sizes.border_end) {
        .px => |value| try positiveLength(.px, value),
    };
    const padding_block_end = switch (block_sizes.padding_end) {
        .px => |value| try positiveLength(.px, value),
        .percentage => |value| try positivePercentage(value, containing_block_logical_width),
    };

    const border_colors = solveBorderColors(context.box_tree.border[box_id]);

    try values.inline_start.append(doc.allocator, .{ .border = border_inline_start, .padding = padding_inline_start, .border_color_rgba = border_colors.inline_start_rgba });
    try values.inline_end.append(doc.allocator, .{ .border = border_inline_end, .padding = padding_inline_end, .border_color_rgba = border_colors.inline_end_rgba });
    try values.block_start.append(doc.allocator, .{ .border = border_block_start, .padding = padding_block_start, .border_color_rgba = border_colors.block_start_rgba });
    try values.block_end.append(doc.allocator, .{ .border = border_block_end, .padding = padding_block_end, .border_color_rgba = border_colors.block_end_rgba });
    try values.margins.append(doc.allocator, .{ .start = margin_inline_start, .end = margin_inline_end });
    try values.background1.append(doc.allocator, solveBackground1(context.box_tree.background[box_id]));
    return std.math.cast(UsedId, values.inline_start.items.len - 1);
}

fn inlineValuesFinishLayout(doc: *Document, context: *LayoutContext, values: *InlineLevelUsedValues, containing_block_logical_width: ZssUnit) !ZssUnit {
    values.font = context.box_tree.font.font;
    values.font_color_rgba = switch (context.box_tree.font.color) {
        .rgba => |rgba| rgba,
    };

    const total_logical_height = try splitIntoLineBoxes(doc, values, containing_block_logical_width);
    return total_logical_height;
}

fn splitIntoLineBoxes(doc: *Document, values: *InlineLevelUsedValues, containing_block_logical_width: ZssUnit) !ZssUnit {
    var font_extents: hb.hb_font_extents_t = undefined;
    // TODO assuming ltr direction
    assert(hb.hb_font_get_h_extents(values.font, &font_extents) != 0);
    values.ascender = @divFloor(font_extents.ascender * unitsPerPixel, 64);
    values.descender = @divFloor(font_extents.descender * unitsPerPixel, 64);
    const top_height: ZssUnit = @divFloor((font_extents.ascender + @divFloor(font_extents.line_gap, 2) + @mod(font_extents.line_gap, 2)) * unitsPerPixel, 64);
    const bottom_height: ZssUnit = @divFloor((-font_extents.descender + @divFloor(font_extents.line_gap, 2)) * unitsPerPixel, 64);

    var cursor: ZssUnit = 0;
    var line_box = InlineLevelUsedValues.LineBox{ .baseline = 0, .elements = [2]usize{ 0, 0 } };
    var max_top_height = top_height;

    var i: usize = 0;
    while (i < values.glyph_indeces.items.len) : (i += 1) {
        const gi = values.glyph_indeces.items[i];
        const metrics = values.metrics.items[i];

        if (gi == 0) {
            i += 1;
            const special = InlineLevelUsedValues.Special.decode(values.glyph_indeces.items[i]);
            switch (@intToEnum(InlineLevelUsedValues.Special.LayoutInternalKind, @enumToInt(special.kind))) {
                .LineBreak => {
                    line_box.baseline += max_top_height;
                    try values.line_boxes.append(doc.allocator, line_box);
                    cursor = 0;
                    line_box = .{ .baseline = line_box.baseline + bottom_height, .elements = [2]usize{ line_box.elements[1] + 2, line_box.elements[1] + 2 } };
                    max_top_height = top_height;
                    continue;
                },
                else => {},
            }
        }

        // TODO A glyph with a width of zero but an advance that is non-zero may overflow the width of the containing block
        if (cursor > 0 and metrics.width > 0 and cursor + metrics.offset + metrics.width > containing_block_logical_width and line_box.elements[1] > line_box.elements[0]) {
            line_box.baseline += max_top_height;
            try values.line_boxes.append(doc.allocator, line_box);
            cursor = 0;
            line_box = .{ .baseline = line_box.baseline + bottom_height, .elements = [2]usize{ line_box.elements[1], line_box.elements[1] } };
            max_top_height = top_height;
        }

        cursor += metrics.advance;

        if (gi == 0) {
            const special = InlineLevelUsedValues.Special.decode(values.glyph_indeces.items[i]);
            switch (@intToEnum(InlineLevelUsedValues.Special.LayoutInternalKind, @enumToInt(special.kind))) {
                .InlineBlock => {
                    const used_id = @as(UsedId, special.data);
                    const box_offsets = doc.blocks.box_offsets.items[used_id];
                    const margins = doc.blocks.margins.items[used_id];
                    const margin_box_height = box_offsets.border_end.y - box_offsets.border_start.y + margins.block_start + margins.block_end;
                    max_top_height = std.math.max(max_top_height, margin_box_height);
                },
                .LineBreak => unreachable,
                else => {},
            }
            line_box.elements[1] += 2;
        } else {
            line_box.elements[1] += 1;
        }
    }

    if (line_box.elements[1] > line_box.elements[0]) {
        line_box.baseline += max_top_height;
        try values.line_boxes.append(doc.allocator, line_box);
    }

    if (values.line_boxes.items.len > 0) {
        return values.line_boxes.items[values.line_boxes.items.len - 1].baseline + bottom_height;
    } else {
        return 0;
    }
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

fn solveBackground2(bg: BoxTree.Background, box_offsets: *const used_values.BoxOffsets, borders: *const used_values.Borders) !used_values.Background2 {
    var object = switch (bg.image) {
        .object => |object| object,
        .none => return used_values.Background2{},
    };

    const border_width = box_offsets.border_end.x - box_offsets.border_start.x;
    const border_height = box_offsets.border_end.y - box_offsets.border_start.y;
    const padding_width = border_width - borders.inline_start - borders.inline_end;
    const padding_height = border_height - borders.block_start - borders.block_end;
    const content_width = box_offsets.content_end.x - box_offsets.content_start.x;
    const content_height = box_offsets.content_end.y - box_offsets.content_start.y;
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
                .px => |val| try positiveLength(.px, val),
                .percentage => |p| try positivePercentage(p, positioning_area.width),
                .auto => blk: {
                    width_was_auto = true;
                    break :blk 0;
                },
            },
            .height = switch (size.height) {
                .px => |val| try positiveLength(.px, val),
                .percentage => |p| try positivePercentage(p, positioning_area.height),
                .auto => blk: {
                    height_was_auto = true;
                    break :blk 0;
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
                .percentage => |p| blk: {
                    const actual_p = switch (position.x.side) {
                        .left => p,
                        .right => 1 - p,
                    };
                    break :blk percentage(actual_p, positioning_area.width - size.width);
                },
            },
            .y = switch (position.y.offset) {
                .px => |val| length(.px, val),
                .percentage => |p| blk: {
                    const actual_p = switch (position.y.side) {
                        .top => p,
                        .bottom => 1 - p,
                    };
                    break :blk percentage(actual_p, positioning_area.height - size.height);
                },
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
