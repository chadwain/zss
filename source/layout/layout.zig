const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const MultiArrayList = std.MultiArrayList;

const zss = @import("../../zss.zig");
const ElementTree = zss.ElementTree;
const ElementIndex = ElementTree.Index;
const root_element = @as(ElementIndex, 0);
const ValueTree = zss.ValueTree;
const SSTSeeker = zss.SSTSeeker;
const sstSeeker = zss.sstSeeker;

const used_values = @import("./used_values.zig");
const ZssUnit = used_values.ZssUnit;
const ZssSize = used_values.ZssSize;
const units_per_pixel = used_values.units_per_pixel;
const BlockBoxIndex = used_values.BlockBoxIndex;
const BlockBoxSkip = used_values.BlockBoxSkip;
const BlockBoxCount = used_values.BlockBoxCount;
const BlockBoxTree = used_values.BlockBoxTree;
const StackingContextIndex = used_values.StackingContextIndex;
const ZIndex = used_values.ZIndex;
const InlineBoxIndex = used_values.InlineBoxIndex;
const InlineFormattingContext = used_values.InlineFormattingContext;
const InlineFormattingContextIndex = used_values.InlineFormattingContextIndex;
const GlyphIndex = InlineFormattingContext.GlyphIndex;
const Document = used_values.Document;

const hb = @import("harfbuzz");

pub const Error = error{
    InvalidValue,
    OutOfMemory,
    Overflow,
};

pub fn doLayout(
    element_tree: *const ElementTree,
    cascaded_value_tree: *const ValueTree,
    allocator: Allocator,
    viewport_size: ZssSize,
) Error!Document {
    var inputs = Inputs{
        .element_tree_skips = element_tree.skips(),
        .seekers = Seekers.init(cascaded_value_tree),
        .font = cascaded_value_tree.font,
        .stage = undefined,
        .current_stage = undefined,
        .allocator = allocator,
        .viewport_size = viewport_size,
        .element_index_to_box = try allocator.alloc(BoxType, element_tree.size()),
    };
    defer inputs.deinit();

    var context = BlockLayoutContext{ .inputs = &inputs };
    defer context.deinit();
    var doc = Document{ .allocator = allocator };
    errdefer doc.deinit();

    {
        inputs.current_stage = .box_gen;
        inputs.stage = .{ .box_gen = .{
            .seekers = BoxGenSeekers.init(cascaded_value_tree),
        } };
        defer inputs.deinitStage(.box_gen);

        try doBoxGeneration(&doc, &context);
        inputs.assertEmptyStage(.box_gen);
    }

    {
        inputs.current_stage = .cosmetic;
        inputs.stage = .{ .cosmetic = .{
            .seekers = CosmeticSeekers.init(cascaded_value_tree),
        } };
        defer inputs.deinitStage(.cosmetic);

        try doCosmeticLayout(&doc, &inputs);
        inputs.assertEmptyStage(.cosmetic);
    }

    return doc;
}

const LengthUnit = enum { px };

fn length(comptime unit: LengthUnit, value: f32) ZssUnit {
    return switch (unit) {
        .px => @floatToInt(ZssUnit, @round(value * units_per_pixel)),
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

fn clampSize(size: ZssUnit, min_size: ZssUnit, max_size: ZssUnit) ZssUnit {
    return std.math.max(min_size, std.math.min(size, max_size));
}

const BorderThickness = enum { thin, medium, thick };

fn borderWidth(comptime thickness: BorderThickness) f32 {
    return switch (thickness) {
        .thin => 1,
        .medium => 3,
        .thick => 5,
    };
}

fn color(col: zss.value.Color, current_color: used_values.Color) used_values.Color {
    return switch (col) {
        .rgba => |rgba| rgba,
        .current_color => current_color,
        .initial, .inherit, .unset => unreachable,
    };
}

fn getCurrentColor(col: zss.value.Color) used_values.Color {
    return switch (col) {
        .rgba => |rgba| rgba,
        .current_color => unreachable,
        .initial, .inherit, .unset => unreachable,
    };
}

const LayoutMode = enum {
    InitialContainingBlock,
    Flow,
    InlineFormattingContext,
};

const Interval = struct {
    begin: ElementIndex,
    end: ElementIndex,
};

const UsedIdInterval = struct {
    begin: BlockBoxIndex,
    end: BlockBoxIndex,
};

const UsedLogicalHeights = struct {
    height: ?ZssUnit,
    min_height: ZssUnit,
    max_height: ZssUnit,
};

const Metadata = struct {
    is_stacking_context_parent: bool,
};

const Seekers = struct {
    const fields = std.meta.fields(ValueTree.Values);
    const Enum = std.meta.FieldEnum(ValueTree.Values);

    all: SSTSeeker(fields[@enumToInt(Enum.all)].field_type),
    text: SSTSeeker(fields[@enumToInt(Enum.text)].field_type),

    fn init(cascaded_value_tree: *const ValueTree) Seekers {
        var result: Seekers = undefined;
        inline for (std.meta.fields(Seekers)) |seeker| {
            @field(result, seeker.name) = sstSeeker(@field(cascaded_value_tree.values, seeker.name));
        }
        return result;
    }
};

const BoxGenSeekers = struct {
    const fields = std.meta.fields(ValueTree.Values);
    const Enum = std.meta.FieldEnum(ValueTree.Values);

    box_style: SSTSeeker(fields[@enumToInt(Enum.box_style)].field_type),
    content_width: SSTSeeker(fields[@enumToInt(Enum.content_width)].field_type),
    horizontal_edges: SSTSeeker(fields[@enumToInt(Enum.horizontal_edges)].field_type),
    content_height: SSTSeeker(fields[@enumToInt(Enum.content_height)].field_type),
    vertical_edges: SSTSeeker(fields[@enumToInt(Enum.vertical_edges)].field_type),
    z_index: SSTSeeker(fields[@enumToInt(Enum.z_index)].field_type),

    fn init(cascaded_value_tree: *const ValueTree) BoxGenSeekers {
        var result: BoxGenSeekers = undefined;
        inline for (std.meta.fields(BoxGenSeekers)) |seeker| {
            @field(result, seeker.name) = sstSeeker(@field(cascaded_value_tree.values, seeker.name));
        }
        return result;
    }
};

const BoxGenComputedValueStack = struct {
    box_style: ArrayListUnmanaged(ValueTree.BoxStyle) = .{},
    content_width: ArrayListUnmanaged(ValueTree.ContentSize) = .{},
    horizontal_edges: ArrayListUnmanaged(ValueTree.BoxEdges) = .{},
    content_height: ArrayListUnmanaged(ValueTree.ContentSize) = .{},
    vertical_edges: ArrayListUnmanaged(ValueTree.BoxEdges) = .{},
    z_index: ArrayListUnmanaged(ValueTree.ZIndex) = .{},
};

const BoxGenCurrentValues = struct {
    box_style: ValueTree.BoxStyle,
    content_width: ValueTree.ContentSize,
    horizontal_edges: ValueTree.BoxEdges,
    content_height: ValueTree.ContentSize,
    vertical_edges: ValueTree.BoxEdges,
    z_index: ValueTree.ZIndex,
};

const BoxGenComptutedValueFlags = struct {
    box_style: bool = false,
    content_width: bool = false,
    horizontal_edges: bool = false,
    content_height: bool = false,
    vertical_edges: bool = false,
    z_index: bool = false,
};

const CosmeticSeekers = struct {
    const fields = std.meta.fields(ValueTree.Values);
    const Enum = std.meta.FieldEnum(ValueTree.Values);

    border_colors: SSTSeeker(fields[@enumToInt(Enum.border_colors)].field_type),
    background1: SSTSeeker(fields[@enumToInt(Enum.background1)].field_type),
    background2: SSTSeeker(fields[@enumToInt(Enum.background2)].field_type),
    color: SSTSeeker(fields[@enumToInt(Enum.color)].field_type),

    fn init(cascaded_value_tree: *const ValueTree) CosmeticSeekers {
        var result: CosmeticSeekers = undefined;
        inline for (std.meta.fields(CosmeticSeekers)) |seeker| {
            @field(result, seeker.name) = sstSeeker(@field(cascaded_value_tree.values, seeker.name));
        }
        return result;
    }
};

const CosmeticComputedValueStack = struct {
    border_colors: ArrayListUnmanaged(ValueTree.BorderColors) = .{},
    background1: ArrayListUnmanaged(ValueTree.Background1) = .{},
    background2: ArrayListUnmanaged(ValueTree.Background2) = .{},
    color: ArrayListUnmanaged(ValueTree.Color) = .{},
};

const CosmeticCurrentValues = struct {
    border_colors: ValueTree.BorderColors,
    background1: ValueTree.Background1,
    background2: ValueTree.Background2,
    color: ValueTree.Color,
};

const CosmeticComptutedValueFlags = struct {
    border_colors: bool = false,
    background1: bool = false,
    background2: bool = false,
    color: bool = false,
};

const ThisElement = struct {
    element: ElementIndex = undefined,
    all: ?zss.value.All = undefined,
};

const BoxType = union(enum) {
    none,
    block_box: BlockBoxIndex,
    inline_box: struct { ifc_index: InlineFormattingContextIndex, index: InlineBoxIndex },
};

const Inputs = struct {
    const Self = @This();

    const Stage = enum { box_gen, cosmetic };

    element_tree_skips: []const ElementIndex,
    seekers: Seekers,
    font: ValueTree.Font,

    this_element: ThisElement = .{},
    element_stack: ArrayListUnmanaged(ThisElement) = .{},

    stage: union {
        box_gen: struct {
            seekers: BoxGenSeekers,
            current_values: BoxGenCurrentValues = undefined,
            current_flags: BoxGenComptutedValueFlags = .{},
            value_stack: BoxGenComputedValueStack = .{},
        },
        cosmetic: struct {
            seekers: CosmeticSeekers,
            current_values: CosmeticCurrentValues = undefined,
            current_flags: CosmeticComptutedValueFlags = .{},
            value_stack: CosmeticComputedValueStack = .{},
        },
    },
    current_stage: Stage,

    allocator: Allocator,
    viewport_size: ZssSize,

    element_index_to_box: []BoxType,
    anonymous_block_boxes: ArrayListUnmanaged(BlockBoxIndex) = .{},

    // Does not do deinitStage.
    fn deinit(self: *Self) void {
        self.element_stack.deinit(self.allocator);
        self.allocator.free(self.element_index_to_box);
        self.anonymous_block_boxes.deinit(self.allocator);
    }

    fn assertEmptyStage(self: Self, comptime stage: Stage) void {
        assert(self.current_stage == stage);
        assert(self.element_stack.items.len == 0);
        const current_stage = &@field(self.stage, @tagName(stage));
        inline for (std.meta.fields(@TypeOf(current_stage.value_stack))) |field_info| {
            assert(@field(current_stage.value_stack, field_info.name).items.len == 0);
        }
    }

    fn deinitStage(self: *Self, comptime stage: Stage) void {
        const current_stage = &@field(self.stage, @tagName(stage));
        inline for (std.meta.fields(@TypeOf(current_stage.value_stack))) |field_info| {
            @field(current_stage.value_stack, field_info.name).deinit(self.allocator);
        }
    }

    fn setElement(self: *Self, comptime stage: Stage, element: ElementIndex) void {
        self.this_element = .{
            .element = element,
            .all = if (self.seekers.all.getBinary(element)) |value| value.all else null,
        };

        assert(self.current_stage == stage);
        const current_stage = &@field(self.stage, @tagName(stage));
        current_stage.current_flags = .{};
        current_stage.current_values = undefined;
    }

    fn setComputedValue(self: *Self, comptime stage: Stage, comptime property: ValueTree.AggregatePropertyEnum, value: property.Value()) void {
        assert(self.current_stage == stage);
        const current_stage = &@field(self.stage, @tagName(stage));
        const flag = &@field(current_stage.current_flags, @tagName(property));
        assert(!flag.*);
        flag.* = true;
        @field(current_stage.current_values, @tagName(property)) = value;
    }

    fn pushElement(self: *Self, comptime stage: Stage) !void {
        assert(self.current_stage == stage);
        try self.element_stack.append(self.allocator, self.this_element);

        const current_stage = &@field(self.stage, @tagName(stage));
        const values = current_stage.current_values;
        const flags = current_stage.current_flags;

        inline for (std.meta.fields(@TypeOf(flags))) |field_info| {
            const flag = @field(flags, field_info.name);
            assert(flag);
            const value = @field(values, field_info.name);
            try @field(current_stage.value_stack, field_info.name).append(self.allocator, value);
        }
    }

    fn popElement(self: *Self, comptime stage: Stage) void {
        assert(self.current_stage == stage);
        _ = self.element_stack.pop();

        const current_stage = &@field(self.stage, @tagName(stage));

        inline for (std.meta.fields(@TypeOf(current_stage.value_stack))) |field_info| {
            _ = @field(current_stage.value_stack, field_info.name).pop();
        }
    }

    fn getText(self: Self) zss.value.Text {
        return if (self.seekers.text.getBinary(self.this_element.element)) |value| value.text else "";
    }

    fn getSpecifiedValue(
        self: Self,
        comptime stage: Stage,
        comptime property: ValueTree.AggregatePropertyEnum,
    ) property.Value() {
        assert(self.current_stage == stage);
        const Value = property.Value();
        const fields = std.meta.fields(Value);
        const inheritance_type = comptime property.inheritanceType();
        const current_stage = @field(self.stage, @tagName(stage));
        const seeker = @field(current_stage.seekers, @tagName(property));
        var cascaded_value = getCascadedValue(property, self.this_element, seeker);

        const initial_value = Value{};
        if (cascaded_value == .all_initial) return initial_value;

        const value_stack = @field(current_stage.value_stack, @tagName(property));
        const inherited_value = if (value_stack.items.len > 0)
            value_stack.items[value_stack.items.len - 1]
        else
            Value{};
        if (cascaded_value == .all_inherit) return inherited_value;

        inline for (fields) |field_info| {
            const sub_property = &@field(cascaded_value.value, field_info.name);
            switch (sub_property.*) {
                .inherit => sub_property.* = @field(inherited_value, field_info.name),
                .initial => sub_property.* = @field(initial_value, field_info.name),
                .unset => switch (inheritance_type) {
                    .inherited => sub_property.* = @field(inherited_value, field_info.name),
                    .not_inherited => sub_property.* = @field(initial_value, field_info.name),
                },
                else => {},
            }
        }
        return cascaded_value.value;
    }

    fn getCascadedValue(
        comptime property: ValueTree.AggregatePropertyEnum,
        element: ThisElement,
        seeker: anytype,
    ) union(enum) {
        value: property.Value(),
        all_inherit,
        all_initial,
    } {
        const Value = property.Value();
        const fields = std.meta.fields(Value);

        // Find the value using the cascaded value tree.
        // TODO: This always uses a binary search to look for values. There might be more efficient/complicated ways to do this.
        if (seeker.getBinary(element.element)) |value| {
            if (property == .color) {
                // CSS-COLOR-3§4.4: If the ‘currentColor’ keyword is set on the ‘color’ property itself, it is treated as ‘color: inherit’.
                comptime assert(fields.len == 1);
                if (value.color == .current_color) {
                    return .all_inherit;
                }
            }

            return .{ .value = value };
        }

        // Use the value of the 'all' property.
        // CSS-CASCADE-4§3.2: The all property is a shorthand that resets all CSS properties except direction and unicode-bidi.
        //                    [...] It does not reset custom properties.
        if (property != .direction and property != .unicode_bidi and property != .custom) {
            if (element.all) |all| switch (all) {
                .inherit => return .all_inherit,
                .initial => return .all_initial,
                .unset => {},
            };
        }

        // Just use the inheritance type.
        switch (comptime property.inheritanceType()) {
            .inherited => return .all_inherit,
            .not_inherited => return .all_initial,
        }
    }
};

const BlockLayoutContext = struct {
    inputs: *Inputs,

    layout_mode: ArrayListUnmanaged(LayoutMode) = .{},
    intervals: ArrayListUnmanaged(Interval) = .{},

    metadata: ArrayListUnmanaged(Metadata) = .{},
    stacking_context_index: ArrayListUnmanaged(StackingContextIndex) = .{},

    index: ArrayListUnmanaged(BlockBoxIndex) = .{},
    skip: ArrayListUnmanaged(BlockBoxSkip) = .{},

    flow_block_used_logical_width: ArrayListUnmanaged(ZssUnit) = .{},
    flow_block_auto_logical_height: ArrayListUnmanaged(ZssUnit) = .{},
    flow_block_used_logical_heights: ArrayListUnmanaged(UsedLogicalHeights) = .{},

    relative_positioned_descendants_indeces: ArrayListUnmanaged(BlockBoxIndex) = .{},
    relative_positioned_descendants_count: ArrayListUnmanaged(BlockBoxCount) = .{},

    shrink_to_fit_available_width: ArrayListUnmanaged(ZssUnit) = .{},
    shrink_to_fit_auto_width: ArrayListUnmanaged(ZssUnit) = .{},
    shrink_to_fit_base_width: ArrayListUnmanaged(ZssUnit) = .{},
    used_id_intervals: ArrayListUnmanaged(UsedIdInterval) = .{},

    fn deinit(self: *BlockLayoutContext) void {
        self.intervals.deinit(self.inputs.allocator);
        self.metadata.deinit(self.inputs.allocator);
        self.layout_mode.deinit(self.inputs.allocator);
        self.index.deinit(self.inputs.allocator);
        self.skip.deinit(self.inputs.allocator);
        self.stacking_context_index.deinit(self.inputs.allocator);
        self.flow_block_used_logical_width.deinit(self.inputs.allocator);
        self.flow_block_auto_logical_height.deinit(self.inputs.allocator);
        self.flow_block_used_logical_heights.deinit(self.inputs.allocator);
        self.relative_positioned_descendants_indeces.deinit(self.inputs.allocator);
        self.relative_positioned_descendants_count.deinit(self.inputs.allocator);
        self.shrink_to_fit_available_width.deinit(self.inputs.allocator);
        self.shrink_to_fit_auto_width.deinit(self.inputs.allocator);
        self.shrink_to_fit_base_width.deinit(self.inputs.allocator);
        self.used_id_intervals.deinit(self.inputs.allocator);
    }
};

fn doBoxGeneration(doc: *Document, context: *BlockLayoutContext) !void {
    if (context.inputs.element_tree_skips.len > 0) {
        doc.blocks.ensureTotalCapacity(doc.allocator, context.inputs.element_tree_skips[0] + 1) catch {};
    } else {
        try doc.blocks.ensureTotalCapacity(doc.allocator, 1);
    }

    // Initialize the context with some data.
    try context.layout_mode.append(context.inputs.allocator, .InitialContainingBlock);

    // Create the initial containing block.
    try createInitialContainingBlock(doc, context);
    if (context.layout_mode.items.len == 1) return;

    // Process the root element.
    try processElement(doc, context);
    const root_block_box_index = switch (context.inputs.element_index_to_box[root_element]) {
        .none => return,
        .block_box => |block_box_index| block_box_index,
        .inline_box => unreachable,
    };

    // Create the root stacking context.
    try doc.stacking_contexts.ensureTotalCapacity(doc.allocator, 1);
    const root_stacking_context_index = doc.stacking_contexts.createRootAssumeCapacity(.{ .z_index = 0, .block_box = root_block_box_index });
    doc.blocks.properties.items[root_block_box_index].creates_stacking_context = true;
    try context.stacking_context_index.append(context.inputs.allocator, root_stacking_context_index);

    // Process all other elements.
    while (context.layout_mode.items.len > 1) {
        try processElement(doc, context);
    }
}

fn doCosmeticLayout(doc: *Document, inputs: *Inputs) !void {
    const num_created_boxes = doc.blocks.skips.items[0];
    try doc.blocks.border_colors.resize(doc.allocator, num_created_boxes);
    try doc.blocks.background1.resize(doc.allocator, num_created_boxes);
    try doc.blocks.background2.resize(doc.allocator, num_created_boxes);

    for (doc.inlines.items) |inline_| {
        try inline_.background1.resize(doc.allocator, inline_.inline_start.items.len);
        inlineRootBoxSolveOtherProperties(inline_);
    }

    var interval_stack = ArrayListUnmanaged(Interval){};
    defer interval_stack.deinit(inputs.allocator);
    if (inputs.element_tree_skips.len > 0) {
        try interval_stack.append(inputs.allocator, .{ .begin = root_element, .end = root_element + inputs.element_tree_skips[root_element] });
    }

    while (interval_stack.items.len > 0) {
        const interval = &interval_stack.items[interval_stack.items.len - 1];

        if (interval.begin != interval.end) {
            const element = interval.begin;
            const skip = inputs.element_tree_skips[element];
            interval.begin += skip;

            inputs.setElement(.cosmetic, element);
            const box_type = inputs.element_index_to_box[element];
            switch (box_type) {
                .none => continue,
                .block_box => |index| try blockBoxSolveOtherProperties(doc, inputs, index),
                .inline_box => |box_spec| {
                    const inline_values = doc.inlines.items[box_spec.ifc_index];
                    try inlineBoxSolveOtherProperties(inline_values, inputs, box_spec.index);
                },
            }

            if (skip != 1) {
                try interval_stack.append(inputs.allocator, .{ .begin = element + 1, .end = element + skip });
                try inputs.pushElement(.cosmetic);
            }
        } else {
            if (interval_stack.items.len > 1) {
                inputs.popElement(.cosmetic);
            }
            _ = interval_stack.pop();
        }
    }

    for (inputs.anonymous_block_boxes.items) |anon_index| {
        blockBoxFillOtherPropertiesWithDefaults(doc, @intCast(BlockBoxIndex, anon_index));
    }
}

fn createInitialContainingBlock(doc: *Document, context: *BlockLayoutContext) !void {
    const width = context.inputs.viewport_size.w;
    const height = context.inputs.viewport_size.h;

    const block = try createBlock(doc);
    block.skip.* = undefined;
    block.properties.* = .{};
    block.box_offsets.* = .{
        .border_start = .{ .x = 0, .y = 0 },
        .content_start = .{ .x = 0, .y = 0 },
        .content_end = .{ .x = width, .y = height },
        .border_end = .{ .x = width, .y = height },
    };
    block.borders.* = .{};
    block.margins.* = .{};

    try context.inputs.anonymous_block_boxes.append(context.inputs.allocator, block.index);
    if (context.inputs.element_tree_skips.len == 0) return;

    const interval = Interval{ .begin = root_element, .end = root_element + context.inputs.element_tree_skips[root_element] };
    const logical_heights = UsedLogicalHeights{
        .height = height,
        .min_height = height,
        .max_height = height,
    };
    try pushFlowLayout(context, interval, block.index, width, logical_heights, null);
}

fn processElement(doc: *Document, context: *BlockLayoutContext) !void {
    const layout_mode = context.layout_mode.items[context.layout_mode.items.len - 1];
    switch (layout_mode) {
        .InitialContainingBlock => unreachable,
        .Flow => {
            const interval = &context.intervals.items[context.intervals.items.len - 1];
            if (interval.begin != interval.end) {
                context.inputs.setElement(.box_gen, interval.begin);
                const specified = context.inputs.getSpecifiedValue(.box_gen, .box_style);
                const computed = solveBoxStyle(specified, interval.begin == root_element);
                context.inputs.setComputedValue(.box_gen, .box_style, computed);

                switch (computed.display) {
                    .block => return processFlowBlock(doc, context, interval),
                    .inline_, .inline_block, .text => {
                        const containing_block_logical_width = context.flow_block_used_logical_width.items[context.flow_block_used_logical_width.items.len - 1];
                        return processInlineContainer(doc, context, interval, containing_block_logical_width, .Normal);
                    },
                    .none => return skipElement(context, interval),
                    .initial, .inherit, .unset => unreachable,
                }
            } else {
                popFlowBlock(doc, context);
            }
        },
        //        .ShrinkToFit1stPass => {
        //            const interval = &context.intervals.items[context.intervals.items.len - 1];
        //            if (interval.begin != interval.end) {
        //                const display = context.box_tree.display[interval.begin];
        //                return switch (display) {
        //                    .block => processShrinkToFit1stPassBlock(doc, context, interval),
        //                    .inline_, .inline_block, .text => {
        //                        const available_width = context.shrink_to_fit_available_width.items[context.shrink_to_fit_available_width.items.len - 1];
        //                        return processInlineContainer(doc, context, interval, available_width, .ShrinkToFit);
        //                    },
        //                    .none => skipElement(context, interval),
        //                };
        //            } else {
        //                try popShrinkToFit1stPassBlock(doc, context);
        //            }
        //        },
        //        .ShrinkToFit2ndPass => {
        //            const used_id_interval = &context.used_id_intervals.items[context.used_id_intervals.items.len - 1];
        //            if (used_id_interval.begin != used_id_interval.end) {
        //                try processShrinkToFit2ndPassBlock(doc, context, used_id_interval);
        //            } else {
        //                popShrinkToFit2ndPassBlock(doc, context);
        //            }
        //        },
        else => @panic("TODO: Other layout modes."),
    }
}

fn skipElement(context: *BlockLayoutContext, interval: *Interval) void {
    const element = interval.begin;
    const skip = context.inputs.element_tree_skips[element];
    interval.begin += skip;
    std.mem.set(BoxType, context.inputs.element_index_to_box[element .. element + skip], .none);
}

fn addBlockToFlow(box_offsets: *used_values.BoxOffsets, margin_end: ZssUnit, parent_auto_logical_height: *ZssUnit) void {
    box_offsets.border_start.y += parent_auto_logical_height.*;
    box_offsets.content_start.y += parent_auto_logical_height.*;
    box_offsets.content_end.y += parent_auto_logical_height.*;
    box_offsets.border_end.y += parent_auto_logical_height.*;
    parent_auto_logical_height.* = box_offsets.border_end.y + margin_end;
}

fn processFlowBlock(doc: *Document, context: *BlockLayoutContext, interval: *Interval) !void {
    const element = interval.begin;
    const skip = context.inputs.element_tree_skips[element];
    interval.begin += skip;

    const block = try createBlock(doc);
    context.inputs.element_index_to_box[element] = .{ .block_box = block.index };

    block.skip.* = undefined;
    block.properties.* = .{};

    const logical_width = try flowBlockSolveInlineSizes(context, block.box_offsets, block.borders, block.margins);
    const used_logical_heights = try flowBlockSolveBlockSizesPart1(context, block.box_offsets, block.borders, block.margins);

    // TODO: Move z-index computation to the cosmetic stage
    const specified_z_index = context.inputs.getSpecifiedValue(.box_gen, .z_index);
    context.inputs.setComputedValue(.box_gen, .z_index, specified_z_index);
    const position = context.inputs.stage.box_gen.current_values.box_style.position;
    const stacking_context_index = switch (position) {
        .static => null,
        .relative => blk: {
            if (element == root_element) {
                // TODO: Should maybe just treat position as static
                // This is the root element. Position must be 'static'.
                return error.InvalidValue;
            }

            context.relative_positioned_descendants_count.items[context.relative_positioned_descendants_count.items.len - 1] += 1;
            try context.relative_positioned_descendants_indeces.append(context.inputs.allocator, block.index);

            switch (specified_z_index.z_index) {
                .integer => |z_index| break :blk try createStackingContext(doc, context, block.index, z_index),
                .auto => {
                    _ = try createStackingContext(doc, context, block.index, 0);
                    break :blk null;
                },
                .initial, .inherit, .unset => unreachable,
            }
        },
        .absolute => @panic("TODO: absolute positioning"),
        .fixed => @panic("TODO: fixed positioning"),
        .sticky => @panic("TODO: sticky positioning"),
        .initial, .inherit, .unset => unreachable,
    };

    try context.inputs.pushElement(.box_gen);
    try pushFlowLayout(context, Interval{ .begin = element + 1, .end = element + skip }, block.index, logical_width, used_logical_heights, stacking_context_index);
}

fn pushFlowLayout(
    context: *BlockLayoutContext,
    interval: Interval,
    block_box_index: BlockBoxIndex,
    logical_width: ZssUnit,
    logical_heights: UsedLogicalHeights,
    stacking_context_index: ?StackingContextIndex,
) !void {
    // The allocations here must have corresponding deallocations in popFlowBlock.
    try context.layout_mode.append(context.inputs.allocator, .Flow);
    try context.intervals.append(context.inputs.allocator, interval);
    try context.index.append(context.inputs.allocator, block_box_index);
    try context.skip.append(context.inputs.allocator, 1);
    try context.flow_block_used_logical_width.append(context.inputs.allocator, logical_width);
    try context.flow_block_auto_logical_height.append(context.inputs.allocator, 0);
    // TODO don't need used_logical_heights
    try context.flow_block_used_logical_heights.append(context.inputs.allocator, logical_heights);
    try context.relative_positioned_descendants_count.append(context.inputs.allocator, 0);
    if (stacking_context_index) |id| {
        try context.stacking_context_index.append(context.inputs.allocator, id);
        try context.metadata.append(context.inputs.allocator, .{ .is_stacking_context_parent = true });
    } else {
        try context.metadata.append(context.inputs.allocator, .{ .is_stacking_context_parent = false });
    }
}

fn popFlowBlock(doc: *Document, context: *BlockLayoutContext) void {
    const block_box_index = context.index.items[context.index.items.len - 1];
    const skip = context.skip.items[context.skip.items.len - 1];
    doc.blocks.skips.items[block_box_index] = skip;

    const box_offsets = &doc.blocks.box_offsets.items[block_box_index];
    const margins = doc.blocks.margins.items[block_box_index];

    const parent_layout_mode = context.layout_mode.items[context.layout_mode.items.len - 2];
    switch (parent_layout_mode) {
        .InitialContainingBlock => {},
        .Flow => {
            context.skip.items[context.skip.items.len - 2] += skip;
            flowBlockFinishLayout(doc, context, box_offsets);
            const parent_auto_logical_height = &context.flow_block_auto_logical_height.items[context.flow_block_auto_logical_height.items.len - 2];
            addBlockToFlow(box_offsets, margins.block_end, parent_auto_logical_height);
            context.inputs.popElement(.box_gen);
        },
        .InlineFormattingContext => {
            context.skip.items[context.skip.items.len - 2] += skip;
            inlineBlockFinishLayout(doc, context, box_offsets);
            context.inputs.popElement(.box_gen);
        },
        //.ShrinkToFit1stPass => {
        //    context.skip.items[context.skip.items.len - 2] += skip;
        //    flowBlockFinishLayout(doc, context, box_offsets);
        //},
        //.ShrinkToFit2ndPass => unreachable,
    }

    // The deallocations here must correspond to allocations in pushFlowLayout.
    _ = context.layout_mode.pop();
    _ = context.intervals.pop();
    _ = context.index.pop();
    _ = context.skip.pop();
    _ = context.flow_block_used_logical_width.pop();
    _ = context.flow_block_auto_logical_height.pop();
    _ = context.flow_block_used_logical_heights.pop();
    const metadata = context.metadata.pop();
    if (metadata.is_stacking_context_parent) {
        _ = context.stacking_context_index.pop();
    }
    const relative_positioned_descendants_count = context.relative_positioned_descendants_count.pop();
    context.relative_positioned_descendants_indeces.shrinkRetainingCapacity(context.relative_positioned_descendants_indeces.items.len - relative_positioned_descendants_count);
}

/// This is an implementation of CSS2§10.2, CSS2§10.3.3, and CSS2§10.4.
fn flowBlockSolveInlineSizes(
    context: *BlockLayoutContext,
    box_offsets: *used_values.BoxOffsets,
    borders: *used_values.Borders,
    margins: *used_values.Margins,
) !ZssUnit {
    const containing_block_logical_width = context.flow_block_used_logical_width.items[context.flow_block_used_logical_width.items.len - 1];
    assert(containing_block_logical_width >= 0);

    // TODO: Also use the logical properties ('inline-size', 'border-inline-start', etc.) to determine lengths.
    // TODO: Any relative units must be converted to absolute units to form the computed value.
    const specified = .{
        .content_width = context.inputs.getSpecifiedValue(.box_gen, .content_width),
        .horizontal_edges = context.inputs.getSpecifiedValue(.box_gen, .horizontal_edges),
    };

    var computed: struct {
        content_width: ValueTree.ContentSize,
        horizontal_edges: ValueTree.BoxEdges,
    } = undefined;

    var used: struct {
        border_start: ZssUnit,
        border_end: ZssUnit,
        padding_start: ZssUnit,
        padding_end: ZssUnit,
        margin_start: ZssUnit,
        margin_end: ZssUnit,
        size: ZssUnit,
        min_size: ZssUnit,
        max_size: ZssUnit,
    } = undefined;

    // TODO: Border widths are '0' if the value of 'border-style' is 'none' or 'hidden'
    switch (specified.horizontal_edges.border_start) {
        .px => |value| {
            computed.horizontal_edges.border_start = .{ .px = value };
            used.border_start = try positiveLength(.px, value);
        },
        .thin => {
            const width = borderWidth(.thin);
            computed.horizontal_edges.border_start = .{ .px = width };
            used.border_start = positiveLength(.px, width) catch unreachable;
        },
        .medium => {
            const width = borderWidth(.medium);
            computed.horizontal_edges.border_start = .{ .px = width };
            used.border_start = positiveLength(.px, width) catch unreachable;
        },
        .thick => {
            const width = borderWidth(.thick);
            computed.horizontal_edges.border_start = .{ .px = width };
            used.border_start = positiveLength(.px, width) catch unreachable;
        },
        .initial, .inherit, .unset => unreachable,
    }
    switch (specified.horizontal_edges.border_end) {
        .px => |value| {
            computed.horizontal_edges.border_end = .{ .px = value };
            used.border_end = try positiveLength(.px, value);
        },
        .thin => {
            const width = borderWidth(.thin);
            computed.horizontal_edges.border_end = .{ .px = width };
            used.border_end = positiveLength(.px, width) catch unreachable;
        },
        .medium => {
            const width = borderWidth(.medium);
            computed.horizontal_edges.border_end = .{ .px = width };
            used.border_end = positiveLength(.px, width) catch unreachable;
        },
        .thick => {
            const width = borderWidth(.thick);
            computed.horizontal_edges.border_end = .{ .px = width };
            used.border_end = positiveLength(.px, width) catch unreachable;
        },
        .initial, .inherit, .unset => unreachable,
    }
    switch (specified.horizontal_edges.padding_start) {
        .px => |value| {
            computed.horizontal_edges.padding_start = .{ .px = value };
            used.padding_start = try positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.horizontal_edges.padding_start = .{ .percentage = value };
            used.padding_start = try positivePercentage(value, containing_block_logical_width);
        },
        .initial, .inherit, .unset => unreachable,
    }
    switch (specified.horizontal_edges.padding_end) {
        .px => |value| {
            computed.horizontal_edges.padding_end = .{ .px = value };
            used.padding_end = try positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.horizontal_edges.padding_end = .{ .percentage = value };
            used.padding_end = try positivePercentage(value, containing_block_logical_width);
        },
        .initial, .inherit, .unset => unreachable,
    }

    switch (specified.content_width.min_size) {
        .px => |value| {
            computed.content_width.min_size = .{ .px = value };
            used.min_size = try positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.content_width.min_size = .{ .percentage = value };
            used.min_size = try positivePercentage(value, containing_block_logical_width);
        },
        .initial, .inherit, .unset => unreachable,
    }
    switch (specified.content_width.max_size) {
        .px => |value| {
            computed.content_width.max_size = .{ .px = value };
            used.max_size = try positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.content_width.max_size = .{ .percentage = value };
            used.max_size = try positivePercentage(value, containing_block_logical_width);
        },
        .none => {
            computed.content_width.max_size = .none;
            used.max_size = std.math.maxInt(ZssUnit);
        },
        .initial, .inherit, .unset => unreachable,
    }

    var auto_bitfield: u3 = 0;
    const size_bit = 4;
    const margin_start_bit = 2;
    const margin_end_bit = 1;

    switch (specified.content_width.size) {
        .px => |value| {
            computed.content_width.size = .{ .px = value };
            used.size = try positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.content_width.size = .{ .percentage = value };
            used.size = try positivePercentage(value, containing_block_logical_width);
        },
        .auto => {
            computed.content_width.size = .auto;
            auto_bitfield |= size_bit;
            used.size = 0;
        },
        .initial, .inherit, .unset => unreachable,
    }
    switch (specified.horizontal_edges.margin_start) {
        .px => |value| {
            computed.horizontal_edges.margin_start = .{ .px = value };
            used.margin_start = length(.px, value);
        },
        .percentage => |value| {
            computed.horizontal_edges.margin_start = .{ .percentage = value };
            used.margin_start = percentage(value, containing_block_logical_width);
        },
        .auto => {
            computed.horizontal_edges.margin_start = .auto;
            auto_bitfield |= margin_start_bit;
            used.margin_start = 0;
        },
        .initial, .inherit, .unset => unreachable,
    }
    switch (specified.horizontal_edges.margin_end) {
        .px => |value| {
            computed.horizontal_edges.margin_end = .{ .px = value };
            used.margin_end = length(.px, value);
        },
        .percentage => |value| {
            computed.horizontal_edges.margin_end = .{ .percentage = value };
            used.margin_end = percentage(value, containing_block_logical_width);
        },
        .auto => {
            computed.horizontal_edges.margin_end = .auto;
            auto_bitfield |= margin_end_bit;
            used.margin_end = 0;
        },
        .initial, .inherit, .unset => unreachable,
    }

    context.inputs.setComputedValue(.box_gen, .content_width, computed.content_width);
    context.inputs.setComputedValue(.box_gen, .horizontal_edges, computed.horizontal_edges);

    const content_margin_space = containing_block_logical_width - (used.border_start + used.border_end + used.padding_start + used.padding_end);
    if (auto_bitfield == 0) {
        // None of the values were auto, so one of the margins must be set according to the other values.
        // TODO the margin that gets set is determined by the 'direction' property
        used.size = clampSize(used.size, used.min_size, used.max_size);
        used.margin_end = content_margin_space - used.size - used.margin_start;
    } else if (auto_bitfield & size_bit == 0) {
        // 'inline-size' is not auto, but at least one of 'margin-inline-start' and 'margin-inline-end' is.
        // If there is only one "auto", then that value gets the remaining margin space.
        // Else, there are 2 "auto"s, and both values get half the remaining margin space.
        const start = auto_bitfield & margin_start_bit;
        const end = auto_bitfield & margin_end_bit;
        const shr_amount = @boolToInt(start | end == margin_start_bit | margin_end_bit);
        used.size = clampSize(used.size, used.min_size, used.max_size);
        const leftover_margin = std.math.max(0, content_margin_space - (used.size + used.margin_start + used.margin_end));
        // TODO the margin that gets the extra 1 unit shall be determined by the 'direction' property
        if (start != 0) used.margin_start = leftover_margin >> shr_amount;
        if (end != 0) used.margin_end = (leftover_margin >> shr_amount) + @mod(leftover_margin, 2);
    } else {
        // 'inline-size' is auto, so it is set according to the other values.
        // The margin values don't need to change.
        used.size = clampSize(content_margin_space - used.margin_start - used.margin_end, used.min_size, used.max_size);
    }

    box_offsets.border_start.x = used.margin_start;
    box_offsets.content_start.x = used.margin_start + used.border_start + used.padding_start;
    box_offsets.content_end.x = box_offsets.content_start.x + used.size;
    box_offsets.border_end.x = box_offsets.content_end.x + used.padding_end + used.border_end;

    borders.inline_start = used.border_start;
    borders.inline_end = used.border_end;

    margins.inline_start = used.margin_start;
    margins.inline_end = used.margin_end;

    return used.size;
}

/// This is an implementation of CSS2§10.5 and CSS2§10.6.3.
fn flowBlockSolveBlockSizesPart1(
    context: *BlockLayoutContext,
    box_offsets: *used_values.BoxOffsets,
    borders: *used_values.Borders,
    margins: *used_values.Margins,
) !UsedLogicalHeights {
    const containing_block_logical_width = context.flow_block_used_logical_width.items[context.flow_block_used_logical_width.items.len - 1];
    const containing_block_logical_height = context.flow_block_used_logical_heights.items[context.flow_block_used_logical_heights.items.len - 1].height;
    assert(containing_block_logical_width >= 0);
    if (containing_block_logical_height) |h| assert(h >= 0);

    // TODO: Also use the logical properties ('block-size', 'border-block-end', etc.) to determine lengths.
    // TODO: Any relative units must be converted to absolute units to form the computed value.
    const specified = .{
        .content_height = context.inputs.getSpecifiedValue(.box_gen, .content_height),
        .vertical_edges = context.inputs.getSpecifiedValue(.box_gen, .vertical_edges),
    };

    var computed: struct {
        content_height: ValueTree.ContentSize,
        vertical_edges: ValueTree.BoxEdges,
    } = undefined;

    var used: struct {
        border_start: ZssUnit,
        border_end: ZssUnit,
        padding_start: ZssUnit,
        padding_end: ZssUnit,
        margin_start: ZssUnit,
        margin_end: ZssUnit,
        size: ?ZssUnit,
        min_size: ZssUnit,
        max_size: ZssUnit,
    } = undefined;

    // TODO: Border widths are '0' if the value of 'border-style' is 'none' or 'hidden'
    switch (specified.vertical_edges.border_start) {
        .px => |value| {
            computed.vertical_edges.border_start = .{ .px = value };
            used.border_start = try positiveLength(.px, value);
        },
        .thin => {
            const width = borderWidth(.thin);
            computed.vertical_edges.border_start = .{ .px = width };
            used.border_start = positiveLength(.px, width) catch unreachable;
        },
        .medium => {
            const width = borderWidth(.medium);
            computed.vertical_edges.border_start = .{ .px = width };
            used.border_start = positiveLength(.px, width) catch unreachable;
        },
        .thick => {
            const width = borderWidth(.thick);
            computed.vertical_edges.border_start = .{ .px = width };
            used.border_start = positiveLength(.px, width) catch unreachable;
        },
        .initial, .inherit, .unset => unreachable,
    }
    switch (specified.vertical_edges.border_end) {
        .px => |value| {
            computed.vertical_edges.border_end = .{ .px = value };
            used.border_end = try positiveLength(.px, value);
        },
        .thin => {
            const width = borderWidth(.thin);
            computed.vertical_edges.border_end = .{ .px = width };
            used.border_end = positiveLength(.px, width) catch unreachable;
        },
        .medium => {
            const width = borderWidth(.medium);
            computed.vertical_edges.border_end = .{ .px = width };
            used.border_end = positiveLength(.px, width) catch unreachable;
        },
        .thick => {
            const width = borderWidth(.thick);
            computed.vertical_edges.border_end = .{ .px = width };
            used.border_end = positiveLength(.px, width) catch unreachable;
        },
        .initial, .inherit, .unset => unreachable,
    }
    switch (specified.vertical_edges.padding_start) {
        .px => |value| {
            computed.vertical_edges.padding_start = .{ .px = value };
            used.padding_start = try positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.vertical_edges.padding_start = .{ .percentage = value };
            used.padding_start = try positivePercentage(value, containing_block_logical_width);
        },
        .initial, .inherit, .unset => unreachable,
    }
    switch (specified.vertical_edges.padding_end) {
        .px => |value| {
            computed.vertical_edges.padding_end = .{ .px = value };
            used.padding_end = try positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.vertical_edges.padding_end = .{ .percentage = value };
            used.padding_end = try positivePercentage(value, containing_block_logical_width);
        },
        .initial, .inherit, .unset => unreachable,
    }
    switch (specified.vertical_edges.margin_start) {
        .px => |value| {
            computed.vertical_edges.margin_start = .{ .px = value };
            used.margin_start = length(.px, value);
        },
        .percentage => |value| {
            computed.vertical_edges.margin_start = .{ .percentage = value };
            used.margin_start = percentage(value, containing_block_logical_width);
        },
        .auto => {
            computed.vertical_edges.margin_start = .auto;
            used.margin_start = 0;
        },
        .initial, .inherit, .unset => unreachable,
    }
    switch (specified.vertical_edges.margin_end) {
        .px => |value| {
            computed.vertical_edges.margin_end = .{ .px = value };
            used.margin_end = length(.px, value);
        },
        .percentage => |value| {
            computed.vertical_edges.margin_end = .{ .percentage = value };
            used.margin_end = percentage(value, containing_block_logical_width);
        },
        .auto => {
            computed.vertical_edges.margin_end = .auto;
            used.margin_end = 0;
        },
        .initial, .inherit, .unset => unreachable,
    }

    switch (specified.content_height.min_size) {
        .px => |value| {
            computed.content_height.min_size = .{ .px = value };
            used.min_size = try positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.content_height.min_size = .{ .percentage = value };
            used.min_size = if (containing_block_logical_height) |s|
                try positivePercentage(value, s)
            else
                0;
        },
        .initial, .inherit, .unset => unreachable,
    }
    switch (specified.content_height.max_size) {
        .px => |value| {
            computed.content_height.max_size = .{ .px = value };
            used.max_size = try positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.content_height.max_size = .{ .percentage = value };
            used.max_size = if (containing_block_logical_height) |s|
                try positivePercentage(value, s)
            else
                std.math.maxInt(ZssUnit);
        },
        .none => {
            computed.content_height.max_size = .none;
            used.max_size = std.math.maxInt(ZssUnit);
        },
        .initial, .inherit, .unset => unreachable,
    }
    switch (specified.content_height.size) {
        .px => |value| {
            computed.content_height.size = .{ .px = value };
            used.size = clampSize(try positiveLength(.px, value), used.min_size, used.max_size);
        },
        .percentage => |value| {
            computed.content_height.size = .{ .percentage = value };
            used.size = if (containing_block_logical_height) |h|
                clampSize(try positivePercentage(value, h), used.min_size, used.max_size)
            else
                null;
        },
        .auto => {
            computed.content_height.size = .auto;
            used.size = null;
        },
        .initial, .inherit, .unset => unreachable,
    }

    context.inputs.setComputedValue(.box_gen, .content_height, computed.content_height);
    context.inputs.setComputedValue(.box_gen, .vertical_edges, computed.vertical_edges);

    // NOTE These are not the actual offsets, just some values that can be
    // determined without knowing 'size'. The offsets are properly filled in
    // in 'flowBlockSolveSizesPart2'.
    box_offsets.border_start.y = used.margin_start;
    box_offsets.content_start.y = used.margin_start + used.border_start + used.padding_start;
    box_offsets.border_end.y = used.padding_end + used.border_end;

    borders.block_start = used.border_start;
    borders.block_end = used.border_end;

    margins.block_start = used.margin_start;
    margins.block_end = used.margin_end;

    return UsedLogicalHeights{
        .height = used.size,
        .min_height = used.min_size,
        .max_height = used.max_size,
    };
}

fn flowBlockSolveBlockSizesPart2(box_offsets: *used_values.BoxOffsets, used_logical_heights: UsedLogicalHeights, auto_logical_height: ZssUnit) ZssUnit {
    const used_logical_height = used_logical_heights.height orelse clampSize(auto_logical_height, used_logical_heights.min_height, used_logical_heights.max_height);
    box_offsets.content_end.y = box_offsets.content_start.y + used_logical_height;
    box_offsets.border_end.y += box_offsets.content_end.y;
    return used_logical_height;
}

fn flowBlockFinishLayout(doc: *Document, context: *BlockLayoutContext, box_offsets: *used_values.BoxOffsets) void {
    const used_logical_heights = context.flow_block_used_logical_heights.items[context.flow_block_used_logical_heights.items.len - 1];
    const auto_logical_height = context.flow_block_auto_logical_height.items[context.flow_block_auto_logical_height.items.len - 1];
    const logical_width = context.flow_block_used_logical_width.items[context.flow_block_used_logical_width.items.len - 1];
    const logical_height = flowBlockSolveBlockSizesPart2(box_offsets, used_logical_heights, auto_logical_height);
    _ = doc;
    _ = logical_width;
    _ = logical_height;
    //blockBoxApplyRelativePositioningToChildren(doc, context, logical_width, logical_height);
}

fn processShrinkToFit1stPassBlock(doc: *Document, context: *BlockLayoutContext, interval: *Interval) !void {
    const element = interval.begin;
    const skip = context.box_tree.structure[element];
    interval.begin += skip;

    const block = try createBlock(doc, context, element);
    block.skip.* = undefined;
    block.properties.* = .{};

    const width_info = try shrinkToFit1stPassGetWidth(context);

    if (width_info.width) |width| {
        const parent_shrink_to_fit_width = &context.shrink_to_fit_auto_width.items[context.shrink_to_fit_auto_width.items.len - 1];
        parent_shrink_to_fit_width.* = std.math.max(parent_shrink_to_fit_width.*, width + width_info.base_width);

        const logical_width = try flowBlockSolveInlineSizes(context, element, block.box_offsets, block.borders, block.margins);
        assert(logical_width == width);
        const used_logical_heights = try flowBlockSolveBlockSizesPart1(context, element, block.box_offsets, block.borders, block.margins);
        try pushFlowLayout(context, Interval{ .begin = element + 1, .end = element + skip }, block.index, logical_width, used_logical_heights, null);
    } else {
        block.properties.uses_shrink_to_fit_sizing = true;
        const parent_available_width = context.shrink_to_fit_available_width.items[context.shrink_to_fit_available_width.items.len - 1];
        const available_width = std.math.max(0, parent_available_width - width_info.base_width);
        const used_logical_heights = try shrinkToFit1stPassGetHeights(context, element);
        try pushShrinkToFit1stPassLayout(context, element, block.index, available_width, width_info.base_width, used_logical_heights);
    }
}

fn pushShrinkToFit1stPassLayout(
    context: *BlockLayoutContext,
    element: ElementIndex,
    block_box_index: BlockBoxIndex,
    available_width: ZssUnit,
    base_width: ZssUnit,
    used_logical_heights: UsedLogicalHeights,
) !void {
    const skip = context.inputs.element_tree_skips[element];
    // The allocations here must have corresponding deallocations in popShrinkToFit1stPassBlock.
    try context.layout_mode.append(context.inputs.allocator, .ShrinkToFit1stPass);
    try context.intervals.append(context.inputs.allocator, .{ .begin = element + 1, .end = element + skip });
    try context.index.append(context.inputs.allocator, block_box_index);
    try context.skip.append(context.inputs.allocator, 1);
    try context.shrink_to_fit_available_width.append(context.inputs.allocator, available_width);
    try context.shrink_to_fit_auto_width.append(context.inputs.allocator, 0);
    try context.shrink_to_fit_base_width.append(context.inputs.allocator, base_width);
    try context.flow_block_used_logical_heights.append(context.inputs.allocator, used_logical_heights);
}

fn popShrinkToFit1stPassBlock(doc: *Document, context: *BlockLayoutContext) !void {
    const block_box_index = context.index.items[context.index.items.len - 1];
    const skip = context.skip.items[context.skip.items.len - 1];
    doc.blocks.skips.items[block_box_index] = skip;

    const shrink_to_fit_width = context.shrink_to_fit_auto_width.items[context.shrink_to_fit_auto_width.items.len - 1];

    var go_to_2nd_pass = false;
    const parent_layout_mode = context.layout_mode.items[context.layout_mode.items.len - 2];
    switch (parent_layout_mode) {
        // Valid as long as flow blocks cannot directly contain shrink-to-fit blocks.
        // This might change when absolute blocks or floats are implemented.
        .Flow => unreachable,
        .ShrinkToFit1stPass => {
            context.skip.items[context.skip.items.len - 2] += skip;
            const parent_shrink_to_fit_width = &context.shrink_to_fit_auto_width.items[context.shrink_to_fit_auto_width.items.len - 2];
            const base_width = context.shrink_to_fit_base_width.items[context.shrink_to_fit_base_width.items.len - 1];
            parent_shrink_to_fit_width.* = std.math.max(parent_shrink_to_fit_width.*, shrink_to_fit_width + base_width);
        },
        .ShrinkToFit2ndPass => @panic("unimplemented"),
        .InlineContainer => {
            context.skip.items[context.skip.items.len - 2] += skip;
            go_to_2nd_pass = true;
        },
    }

    _ = context.layout_mode.pop();
    _ = context.intervals.pop();
    _ = context.shrink_to_fit_available_width.pop();
    _ = context.shrink_to_fit_auto_width.pop();
    _ = context.shrink_to_fit_base_width.pop();
    _ = context.index.pop();
    _ = context.skip.pop();
    const used_logical_heights = context.flow_block_used_logical_heights.pop();

    if (go_to_2nd_pass) {
        const used_id_interval = UsedIdInterval{ .begin = block_box_index + 1, .end = block_box_index + doc.blocks.skips.items[block_box_index] };
        try pushShrinkToFit2ndPassLayout(context, block_box_index, used_id_interval, shrink_to_fit_width, used_logical_heights);
    }
}

const ShrinkToFit1stPassGetWidthResult = struct {
    /// The sum of the widths of all horizontal borders, padding, and margins.
    base_width: ZssUnit,
    width: ?ZssUnit,
};

fn shrinkToFit1stPassGetWidth(
    context: *BlockLayoutContext,
) !ShrinkToFit1stPassGetWidthResult {
    const specified = .{
        .content_width = context.inputs.getSpecifiedValue(.box_gen, .content_width),
        .horizontal_edges = context.inputs.getSpecifiedValue(.box_gen, .horizontal_edges),
    };

    var computed: struct {
        content_width: ValueTree.ContentSize,
        horizontal_edges: ValueTree.BoxEdges,
    } = undefined;

    var used: struct {
        min_size: ZssUnit,
        max_size: ZssUnit,
    } = undefined;

    var result = ShrinkToFit1stPassGetWidthResult{ .base_width = 0, .width = undefined };

    switch (specified.horizontal_edges.border_start) {
        .px => |value| {
            computed.horizontal_edges.border_start = .{ .px = value };
            result.base_width += try positiveLength(.px, value);
        },
        .thin => {
            const width = borderWidth(.thin);
            computed.horizontal_edges.border_start = .{ .px = width };
            result.base_width += positiveLength(.px, width) catch unreachable;
        },
        .medium => {
            const width = borderWidth(.medium);
            computed.horizontal_edges.border_start = .{ .px = width };
            result.base_width += positiveLength(.px, width) catch unreachable;
        },
        .thick => {
            const width = borderWidth(.thick);
            computed.horizontal_edges.border_start = .{ .px = width };
            result.base_width += positiveLength(.px, width) catch unreachable;
        },
        .initial, .inherit, .unset => unreachable,
    }
    switch (specified.horizontal_edges.border_end) {
        .px => |value| {
            computed.horizontal_edges.border_end = .{ .px = value };
            result.base_width += try positiveLength(.px, value);
        },
        .thin => {
            const width = borderWidth(.thin);
            computed.horizontal_edges.border_end = .{ .px = width };
            result.base_width += positiveLength(.px, width) catch unreachable;
        },
        .medium => {
            const width = borderWidth(.medium);
            computed.horizontal_edges.border_end = .{ .px = width };
            result.base_width += positiveLength(.px, width) catch unreachable;
        },
        .thick => {
            const width = borderWidth(.thick);
            computed.horizontal_edges.border_end = .{ .px = width };
            result.base_width += positiveLength(.px, width) catch unreachable;
        },
        .initial, .inherit, .unset => unreachable,
    }
    switch (specified.horizontal_edges.padding_start) {
        .px => |value| {
            computed.horizontal_edges.padding_start = .{ .px = value };
            result.base_width += try positiveLength(.px, value);
        },
        .percentage => |value| computed.horizontal_edges.padding_start = .{ .percentage = value },
        .initial, .inherit, .unset => unreachable,
    }
    switch (specified.horizontal_edges.padding_end) {
        .px => |value| {
            computed.horizontal_edges.padding_end = .{ .px = value };
            result.base_width += try positiveLength(.px, value);
        },
        .percentage => |value| computed.horizontal_edges.padding_end = .{ .percentage = value },
        .initial, .inherit, .unset => unreachable,
    }
    switch (specified.horizontal_edges.margin_start) {
        .px => |value| {
            computed.horizontal_edges.margin_start = .{ .px = value };
            result.base_width += length(.px, value);
        },
        .percentage => |value| computed.horizontal_edges.margin_start = .{ .percentage = value },
        .auto => computed.horizontal_edges.margin_start = .auto,
        .initial, .inherit, .unset => unreachable,
    }
    switch (specified.horizontal_edges.margin_end) {
        .px => |value| {
            computed.horizontal_edges.margin_end = .{ .px = value };
            result.base_width += length(.px, value);
        },
        .percentage => |value| computed.horizontal_edges.margin_end = .{ .percentage = value },
        .auto => computed.horizontal_edges.margin_end = .auto,
        .initial, .inherit, .unset => unreachable,
    }

    switch (specified.content_width.min_size) {
        .px => |value| {
            computed.content_width.min_size = .{ .px = value };
            used.min_size = try positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.content_width.min_size = .{ .percentage = value };
            used.min_size = 0;
        },
        .initial, .inherit, .unset => unreachable,
    }
    switch (specified.content_width.max_size) {
        .px => |value| {
            computed.content_width.max_size = .{ .px = value };
            used.max_size = try positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.content_width.max_size = .{ .percentage = value };
            used.max_size = std.math.maxInt(ZssUnit);
        },
        .none => {
            computed.content_width.max_size = .none;
            used.max_size = std.math.maxInt(ZssUnit);
        },
        .initial, .inherit, .unset => unreachable,
    }
    switch (specified.content_width.size) {
        // TODO: Should min_size/max_size affect the base_width if size is percentage/auto?
        .px => |value| {
            computed.content_width.size = .{ .px = value };
            result.size = clampSize(try positiveLength(.px, value), used.min_size, used.max_size);
        },
        .percentage => |value| {
            computed.content_width.size = .{ .percentage = value };
            result.size = null;
        },
        .auto => {
            computed.content_width.size = .auto;
            result.size = null;
        },
        .initial, .inherit, .unset => unreachable,
    }

    context.inputs.setComputedValue(.box_gen, .content_width, specified.content_width);
    context.inputs.setComputedValue(.box_gen, .horizontal_edges, specified.horizontal_edges);

    return result;
}

fn shrinkToFit1stPassGetHeights(context: *BlockLayoutContext) !UsedLogicalHeights {
    const containing_block_logical_height = context.flow_block_used_logical_heights.items[context.flow_block_used_logical_heights.items.len - 1].height;
    if (containing_block_logical_height) |h| assert(h >= 0);

    const specified = .{
        .content_height = context.getSpecifiedValue(.box_gen, .content_height),
    };

    var computed: struct {
        content_height: ValueTree.ContentSize,
    } = undefined;

    var used: struct {
        size: ?ZssUnit,
        min_size: ZssUnit,
        max_size: ZssUnit,
    } = undefined;

    switch (specified.content_height.min_size) {
        .px => |value| {
            computed.content_height.min_size = .{ .px = value };
            used.min_size = try positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.content_height.min_size = .{ .percentage = value };
            used.min_size = if (containing_block_logical_height) |s|
                try positivePercentage(value, s)
            else
                0;
        },
        .initial, .inherit, .unset => unreachable,
    }
    switch (specified.content_height.max_size) {
        .px => |value| {
            computed.content_height.max_size = .{ .px = value };
            used.max_size = try positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.content_height.max_size = .{ .percentage = value };
            used.max_size = if (containing_block_logical_height) |s|
                try positivePercentage(value, s)
            else
                std.math.maxInt(ZssUnit);
        },
        .none => {
            computed.content_height.max_size = .none;
            used.max_size = std.math.maxInt(ZssUnit);
        },
        .initial, .inherit, .unset => unreachable,
    }
    switch (specified.content_height.size) {
        .px => |value| {
            computed.content_height.size = .{ .px = value };
            used.size = clampSize(try positiveLength(.px, value), used.min_size, used.max_size);
        },
        .percentage => |value| {
            computed.content_height.size = .{ .percentage = value };
            used.size = if (containing_block_logical_height) |h|
                clampSize(try positivePercentage(value, h), used.min_size, used.max_size)
            else
                null;
        },
        .auto => {
            computed.content_height.size = .auto;
            used.size = null;
        },
    }

    context.setComputedValue(.box_gen, .content_height, computed.content_height);

    return UsedLogicalHeights{
        .height = used.size,
        .min_height = used.min_size,
        .max_height = used.max_size,
    };
}

fn processShrinkToFit2ndPassBlock(doc: *Document, context: *BlockLayoutContext, used_id_interval: *UsedIdInterval) !void {
    const block_box_index = used_id_interval.begin;
    const skip = doc.blocks.skips.items[used_id_interval.begin];
    used_id_interval.begin += skip;

    const properties = doc.blocks.properties.items[block_box_index];
    const box_offsets = &doc.blocks.box_offsets.items[block_box_index];
    const borders = &doc.blocks.borders.items[block_box_index];
    const margins = &doc.blocks.margins.items[block_box_index];

    if (!properties.uses_shrink_to_fit_sizing or properties.inline_context_index != null) {
        const parent_auto_logical_height = &context.flow_block_auto_logical_height.items[context.flow_block_auto_logical_height.items.len - 1];
        addBlockToFlow(box_offsets, margins.block_end, parent_auto_logical_height);
    } else {
        const element = context.used_id_to_element_index.items[block_box_index];
        const logical_width = try flowBlockSolveInlineSizes(context, element, box_offsets, borders, margins);
        const used_logical_heights = try flowBlockSolveBlockSizesPart1(context, element, box_offsets, borders, margins);
        const new_interval = UsedIdInterval{ .begin = block_box_index + 1, .end = block_box_index + skip };
        try pushShrinkToFit2ndPassLayout(context, block_box_index, new_interval, logical_width, used_logical_heights);
    }
}

fn pushShrinkToFit2ndPassLayout(
    context: *BlockLayoutContext,
    block_box_index: BlockBoxIndex,
    used_id_interval: UsedIdInterval,
    logical_width: ZssUnit,
    logical_heights: UsedLogicalHeights,
) !void {
    // The allocations here must correspond to deallocations in popShrinkToFit2ndPassBlock.
    try context.layout_mode.append(context.inputs.allocator, .ShrinkToFit2ndPass);
    try context.index.append(context.inputs.allocator, block_box_index);
    try context.used_id_intervals.append(context.inputs.allocator, used_id_interval);
    try context.flow_block_used_logical_width.append(context.inputs.allocator, logical_width);
    try context.flow_block_auto_logical_height.append(context.inputs.allocator, 0);
    try context.flow_block_used_logical_heights.append(context.inputs.allocator, logical_heights);
}

fn popShrinkToFit2ndPassBlock(doc: *Document, context: *BlockLayoutContext) void {
    const block_box_index = context.index.items[context.index.items.len - 1];
    const box_offsets = &doc.blocks.box_offsets.items[block_box_index];
    const margins = doc.blocks.margins.items[block_box_index];

    const parent_layout_mode = context.layout_mode.items[context.layout_mode.items.len - 2];
    switch (parent_layout_mode) {
        // Valid as long as flow blocks cannot directly contain shrink-to-fit blocks.
        // This might change when absolute blocks or floats are implemented.
        .Flow => unreachable,
        .ShrinkToFit1stPass => @panic("unimplemented"),
        .ShrinkToFit2ndPass => {
            flowBlockFinishLayout(doc, context, box_offsets);
            const parent_auto_logical_height = &context.flow_block_auto_logical_height.items[context.flow_block_auto_logical_height.items.len - 2];
            addBlockToFlow(box_offsets, margins.block_end, parent_auto_logical_height);
        },
        .InlineContainer => {
            inlineBlockFinishLayout(doc, context, box_offsets);
            //const container = &context.inline_container.items[context.inline_container.items.len - 1];
            //addBlockToInlineContainer(container);
        },
    }

    _ = context.layout_mode.pop();
    _ = context.flow_block_used_logical_width.pop();
    _ = context.flow_block_auto_logical_height.pop();
    _ = context.flow_block_used_logical_heights.pop();
    _ = context.index.pop();
    _ = context.used_id_intervals.pop();
}

fn processInlineContainer(
    doc: *Document,
    context: *BlockLayoutContext,
    interval: *Interval,
    containing_block_logical_width: ZssUnit,
    mode: enum { Normal, ShrinkToFit },
) !void {
    assert(containing_block_logical_width >= 0);

    // Create an anonymous block box to contain this inline formatting context.
    const block = try createBlock(doc);
    try context.inputs.anonymous_block_boxes.append(context.inputs.allocator, block.index);

    try context.layout_mode.append(context.inputs.allocator, .InlineFormattingContext);
    try context.index.append(context.inputs.allocator, block.index);
    try context.skip.append(context.inputs.allocator, 1);

    const inline_values_ptr = try doc.allocator.create(InlineFormattingContext);
    errdefer doc.allocator.destroy(inline_values_ptr);
    inline_values_ptr.* = .{};
    errdefer inline_values_ptr.deinit(doc.allocator);
    const ifc_index = try std.math.cast(InlineFormattingContextIndex, doc.inlines.items.len);
    block.properties.* = .{ .inline_context_index = ifc_index };

    const percentage_base_unit: ZssUnit = switch (mode) {
        .Normal => containing_block_logical_width,
        .ShrinkToFit => 0,
    };

    var inline_context = InlineLayoutContext{
        .inputs = context.inputs,
        .block_context = context,
        .root_interval = interval.*,
        .percentage_base_unit = percentage_base_unit,
        .ifc_index = ifc_index,
    };
    defer inline_context.deinit();

    try createInlineFormattingContext(doc, &inline_context, inline_values_ptr);

    assert(context.layout_mode.pop() == .InlineFormattingContext);
    assert(context.index.pop() == block.index);
    block.skip.* = context.skip.pop();

    interval.begin = inline_context.next_element;
    try doc.inlines.append(doc.allocator, inline_values_ptr);

    const info = try splitIntoLineBoxes(doc, inline_values_ptr, containing_block_logical_width);
    const used_logical_width = switch (mode) {
        .Normal => containing_block_logical_width,
        .ShrinkToFit => info.longest_line_box_length,
    };
    const used_logical_height = info.logical_height;

    inlineFormattingContextPositionInlineBlocks(doc, inline_values_ptr);

    block.box_offsets.* = .{
        .border_start = .{ .x = 0, .y = 0 },
        .content_start = .{ .x = 0, .y = 0 },
        .content_end = .{ .x = used_logical_width, .y = used_logical_height },
        .border_end = .{ .x = used_logical_width, .y = used_logical_height },
    };
    block.borders.* = .{};
    block.margins.* = .{};

    const parent_layout_mode = context.layout_mode.items[context.layout_mode.items.len - 1];
    switch (parent_layout_mode) {
        .InitialContainingBlock => unreachable,
        .Flow => {
            context.skip.items[context.skip.items.len - 1] += block.skip.*;
            const parent_auto_logical_height = &context.flow_block_auto_logical_height.items[context.flow_block_auto_logical_height.items.len - 1];
            addBlockToFlow(block.box_offsets, 0, parent_auto_logical_height);
        },
        .InlineFormattingContext => unreachable,
        //.ShrinkToFit1stPass => {
        //    context.skip.items[context.skip.items.len - 1] += inline_context.block_skip;
        //    const parent_shrink_to_fit_width = &context.shrink_to_fit_auto_width.items[context.shrink_to_fit_auto_width.items.len - 1];
        //    parent_shrink_to_fit_width.* = std.math.max(parent_shrink_to_fit_width.*, used_logical_width);
        //},
        //.ShrinkToFit2ndPass => @panic("unimplemented"),
    }
}

fn inlineFormattingContextPositionInlineBlocks(doc: *Document, values: *InlineFormattingContext) void {
    // TODO: Searching through every glyph to find the inline blocks...
    for (values.line_boxes.items) |line_box| {
        var distance: ZssUnit = 0;
        var i = line_box.elements[0];
        while (i < line_box.elements[1]) : (i += 1) {
            const advance = values.metrics.items[i].advance;
            defer distance += advance;

            const gi = values.glyph_indeces.items[i];
            if (gi != 0) continue;

            i += 1;
            const special = InlineFormattingContext.Special.decode(values.glyph_indeces.items[i]);
            switch (special.kind) {
                .ZeroGlyphIndex, .BoxStart, .BoxEnd => continue,
                .InlineBlock => {},
                _ => continue,
            }
            const block_box_index = @as(BlockBoxIndex, special.data);
            const box_offsets = &doc.blocks.box_offsets.items[block_box_index];
            const margins = doc.blocks.margins.items[block_box_index];
            const translation_inline = distance + margins.inline_start;
            const translation_block = line_box.baseline - (box_offsets.border_end.y - box_offsets.border_start.y) - margins.block_start - margins.block_end;
            inline for (std.meta.fields(used_values.BoxOffsets)) |field| {
                const v = &@field(box_offsets.*, field.name);
                v.x += translation_inline;
                v.y += translation_block;
            }
        }
    }
}

fn processInlineBlock(doc: *Document, context: *BlockLayoutContext) !void {
    const element = context.inputs.this_element.element;
    const skip = context.inputs.element_tree_skips[element];

    const block = try createBlock(doc);
    block.skip.* = undefined;
    block.properties.* = .{};

    context.inputs.element_index_to_box[element] = .{ .block_box = block.index };

    const sizes = try inlineBlockSolveSizesPart1(context, block.box_offsets, block.borders, block.margins);

    // TODO: Move z-index computation to the cosmetic stage
    const specified_z_index = context.inputs.getSpecifiedValue(.box_gen, .z_index);
    context.inputs.setComputedValue(.box_gen, .z_index, specified_z_index);
    const position = context.inputs.stage.box_gen.current_values.box_style.position;
    const stacking_context_index = switch (position) {
        .static => try createStackingContext(doc, context, block.index, 0),
        .relative => blk: {
            if (element == root_element) {
                // TODO: Should maybe just treat position as static
                // This is the root element. Position must be 'static'.
                return error.InvalidValue;
            }

            context.relative_positioned_descendants_count.items[context.relative_positioned_descendants_count.items.len - 1] += 1;
            try context.relative_positioned_descendants_indeces.append(context.inputs.allocator, block.index);

            switch (specified_z_index.z_index) {
                .integer => |z_index| break :blk try createStackingContext(doc, context, block.index, z_index),
                .auto => {
                    _ = try createStackingContext(doc, context, block.index, 0);
                    break :blk null;
                },
                .initial, .inherit, .unset => unreachable,
            }
        },
        .absolute => @panic("TODO: absolute positioning"),
        .fixed => @panic("TODO: fixed positioning"),
        .sticky => @panic("TODO: sticky positioning"),
        .initial, .inherit, .unset => unreachable,
    };

    try context.inputs.pushElement(.box_gen);

    if (sizes.logical_width) |logical_width| {
        try pushFlowLayout(context, Interval{ .begin = element + 1, .end = element + skip }, block.index, logical_width, sizes.logical_heights, stacking_context_index);
    } else {
        @panic("TODO inline block shrink to fit");
        //const base_width = (block.box_offsets.content_start.x - block.box_offsets.border_start.x) + (block.box_offsets.border_end.x - block.box_offsets.content_end.x) + block.margins.inline_start + block.margins.inline_end;
        //const available_width = std.math.max(0, container.containing_block_logical_width - base_width);
        //try pushShrinkToFit1stPassLayout(context, element, block.index, available_width, base_width, sizes.logical_heights);
    }
}

const InlineBlockSolveSizesResult = struct {
    logical_width: ?ZssUnit,
    logical_heights: UsedLogicalHeights,
};

fn inlineBlockSolveSizesPart1(
    context: *BlockLayoutContext,
    box_offsets: *used_values.BoxOffsets,
    borders: *used_values.Borders,
    margins: *used_values.Margins,
) !InlineBlockSolveSizesResult {
    const max = std.math.max;
    const containing_block_logical_width = context.flow_block_used_logical_width.items[context.flow_block_used_logical_width.items.len - 1];
    assert(containing_block_logical_width >= 0);

    // TODO: Also use the logical properties ('padding-inline-start', 'border-block-end', etc.).
    const specified = .{
        .content_width = context.inputs.getSpecifiedValue(.box_gen, .content_width),
        .horizontal_edges = context.inputs.getSpecifiedValue(.box_gen, .horizontal_edges),
        .content_height = context.inputs.getSpecifiedValue(.box_gen, .content_height),
        .vertical_edges = context.inputs.getSpecifiedValue(.box_gen, .vertical_edges),
    };

    var computed: struct {
        content_width: ValueTree.ContentSize,
        horizontal_edges: ValueTree.BoxEdges,
        content_height: ValueTree.ContentSize,
        vertical_edges: ValueTree.BoxEdges,
    } = undefined;

    var used: struct {
        border_inline_start: ZssUnit,
        border_inline_end: ZssUnit,
        padding_inline_start: ZssUnit,
        padding_inline_end: ZssUnit,
        margin_inline_start: ZssUnit,
        margin_inline_end: ZssUnit,
        min_inline_size: ZssUnit,
        max_inline_size: ZssUnit,
        inline_size: ?ZssUnit,
        border_block_start: ZssUnit,
        border_block_end: ZssUnit,
        padding_block_start: ZssUnit,
        padding_block_end: ZssUnit,
        margin_block_start: ZssUnit,
        margin_block_end: ZssUnit,
        min_block_size: ZssUnit,
        max_block_size: ZssUnit,
        block_size: ?ZssUnit,
    } = undefined;

    switch (specified.horizontal_edges.border_start) {
        .px => |value| {
            computed.horizontal_edges.border_start = .{ .px = value };
            used.border_inline_start = try positiveLength(.px, value);
        },
        .thin => {
            const width = borderWidth(.thin);
            computed.horizontal_edges.border_start = .{ .px = width };
            used.border_inline_start = positiveLength(.px, width) catch unreachable;
        },
        .medium => {
            const width = borderWidth(.medium);
            computed.horizontal_edges.border_start = .{ .px = width };
            used.border_inline_start = positiveLength(.px, width) catch unreachable;
        },
        .thick => {
            const width = borderWidth(.thick);
            computed.horizontal_edges.border_start = .{ .px = width };
            used.border_inline_start = positiveLength(.px, width) catch unreachable;
        },
        .initial, .inherit, .unset => unreachable,
    }
    switch (specified.horizontal_edges.border_end) {
        .px => |value| {
            computed.horizontal_edges.border_end = .{ .px = value };
            used.border_inline_end = try positiveLength(.px, value);
        },
        .thin => {
            const width = borderWidth(.thin);
            computed.horizontal_edges.border_end = .{ .px = width };
            used.border_inline_end = positiveLength(.px, width) catch unreachable;
        },
        .medium => {
            const width = borderWidth(.medium);
            computed.horizontal_edges.border_end = .{ .px = width };
            used.border_inline_end = positiveLength(.px, width) catch unreachable;
        },
        .thick => {
            const width = borderWidth(.thick);
            computed.horizontal_edges.border_end = .{ .px = width };
            used.border_inline_end = positiveLength(.px, width) catch unreachable;
        },
        .initial, .inherit, .unset => unreachable,
    }
    switch (specified.horizontal_edges.padding_start) {
        .px => |value| {
            computed.horizontal_edges.padding_start = .{ .px = value };
            used.padding_inline_start = try positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.horizontal_edges.padding_start = .{ .percentage = value };
            used.padding_inline_start = try positivePercentage(value, containing_block_logical_width);
        },
        .initial, .inherit, .unset => unreachable,
    }
    switch (specified.horizontal_edges.padding_end) {
        .px => |value| {
            computed.horizontal_edges.padding_end = .{ .px = value };
            used.padding_inline_end = try positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.horizontal_edges.padding_end = .{ .percentage = value };
            used.padding_inline_end = try positivePercentage(value, containing_block_logical_width);
        },
        .initial, .inherit, .unset => unreachable,
    }
    switch (specified.horizontal_edges.margin_start) {
        .px => |value| {
            computed.horizontal_edges.margin_start = .{ .px = value };
            used.margin_inline_start = length(.px, value);
        },
        .percentage => |value| {
            computed.horizontal_edges.margin_start = .{ .percentage = value };
            used.margin_inline_start = percentage(value, containing_block_logical_width);
        },
        .auto => {
            computed.horizontal_edges.margin_start = .auto;
            used.margin_inline_start = 0;
        },
        .initial, .inherit, .unset => unreachable,
    }
    switch (specified.horizontal_edges.margin_end) {
        .px => |value| {
            computed.horizontal_edges.margin_end = .{ .px = value };
            used.margin_inline_end = length(.px, value);
        },
        .percentage => |value| {
            computed.horizontal_edges.margin_end = .{ .percentage = value };
            used.margin_inline_end = percentage(value, containing_block_logical_width);
        },
        .auto => {
            computed.horizontal_edges.margin_end = .auto;
            used.margin_inline_end = 0;
        },
        .initial, .inherit, .unset => unreachable,
    }
    switch (specified.content_width.min_size) {
        .px => |value| {
            computed.content_width.min_size = .{ .px = value };
            used.min_inline_size = try positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.content_width.min_size = .{ .percentage = value };
            used.min_inline_size = try positivePercentage(value, max(0, containing_block_logical_width));
        },
        .initial, .inherit, .unset => unreachable,
    }
    switch (specified.content_width.max_size) {
        .px => |value| {
            computed.content_width.max_size = .{ .px = value };
            used.max_inline_size = try positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.content_width.max_size = .{ .percentage = value };
            used.max_inline_size = try positivePercentage(value, max(0, containing_block_logical_width));
        },
        .none => {
            computed.content_width.max_size = .none;
            used.max_inline_size = std.math.maxInt(ZssUnit);
        },
        .initial, .inherit, .unset => unreachable,
    }
    switch (specified.content_width.size) {
        .px => |value| {
            computed.content_width.size = .{ .px = value };
            used.inline_size = clampSize(try positiveLength(.px, value), used.min_inline_size, used.max_inline_size);
        },
        .percentage => |value| {
            computed.content_width.size = .{ .percentage = value };
            used.inline_size = clampSize(try positivePercentage(value, containing_block_logical_width), used.min_inline_size, used.max_inline_size);
        },
        .auto => {
            computed.content_width.size = .auto;
            used.inline_size = null;
        },
        .initial, .inherit, .unset => unreachable,
    }

    switch (specified.vertical_edges.border_start) {
        .px => |value| {
            computed.vertical_edges.border_start = .{ .px = value };
            used.border_block_start = try positiveLength(.px, value);
        },
        .thin => {
            const width = borderWidth(.thin);
            computed.vertical_edges.border_start = .{ .px = width };
            used.border_block_start = positiveLength(.px, width) catch unreachable;
        },
        .medium => {
            const width = borderWidth(.medium);
            computed.vertical_edges.border_start = .{ .px = width };
            used.border_block_start = positiveLength(.px, width) catch unreachable;
        },
        .thick => {
            const width = borderWidth(.thick);
            computed.vertical_edges.border_start = .{ .px = width };
            used.border_block_start = positiveLength(.px, width) catch unreachable;
        },
        .initial, .inherit, .unset => unreachable,
    }
    switch (specified.vertical_edges.border_end) {
        .px => |value| {
            computed.vertical_edges.border_end = .{ .px = value };
            used.border_block_end = try positiveLength(.px, value);
        },
        .thin => {
            const width = borderWidth(.thin);
            computed.vertical_edges.border_end = .{ .px = width };
            used.border_block_end = positiveLength(.px, width) catch unreachable;
        },
        .medium => {
            const width = borderWidth(.medium);
            computed.vertical_edges.border_end = .{ .px = width };
            used.border_block_end = positiveLength(.px, width) catch unreachable;
        },
        .thick => {
            const width = borderWidth(.thick);
            computed.vertical_edges.border_end = .{ .px = width };
            used.border_block_end = positiveLength(.px, width) catch unreachable;
        },
        .initial, .inherit, .unset => unreachable,
    }
    switch (specified.vertical_edges.padding_start) {
        .px => |value| {
            computed.vertical_edges.padding_start = .{ .px = value };
            used.padding_block_start = try positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.vertical_edges.padding_start = .{ .percentage = value };
            used.padding_block_start = try positivePercentage(value, containing_block_logical_width);
        },
        .initial, .inherit, .unset => unreachable,
    }
    switch (specified.vertical_edges.padding_end) {
        .px => |value| {
            computed.vertical_edges.padding_end = .{ .px = value };
            used.padding_block_end = try positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.vertical_edges.padding_end = .{ .percentage = value };
            used.padding_block_end = try positivePercentage(value, containing_block_logical_width);
        },
        .initial, .inherit, .unset => unreachable,
    }
    switch (specified.vertical_edges.margin_start) {
        .px => |value| {
            computed.vertical_edges.margin_start = .{ .px = value };
            used.margin_block_start = length(.px, value);
        },
        .percentage => |value| {
            computed.vertical_edges.margin_start = .{ .percentage = value };
            used.margin_block_start = percentage(value, containing_block_logical_width);
        },
        .auto => {
            computed.vertical_edges.margin_start = .auto;
            used.margin_block_start = 0;
        },
        .initial, .inherit, .unset => unreachable,
    }
    switch (specified.vertical_edges.margin_end) {
        .px => |value| {
            computed.vertical_edges.margin_end = .{ .px = value };
            used.margin_block_end = length(.px, value);
        },
        .percentage => |value| {
            computed.vertical_edges.margin_end = .{ .percentage = value };
            used.margin_block_end = percentage(value, containing_block_logical_width);
        },
        .auto => {
            computed.vertical_edges.margin_end = .auto;
            used.margin_block_end = 0;
        },
        .initial, .inherit, .unset => unreachable,
    }
    switch (specified.content_height.min_size) {
        .px => |value| {
            computed.content_height.min_size = .{ .px = value };
            used.min_block_size = try positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.content_height.min_size = .{ .percentage = value };
            used.min_block_size = try positivePercentage(value, max(0, containing_block_logical_width));
        },
        .initial, .inherit, .unset => unreachable,
    }
    switch (specified.content_height.max_size) {
        .px => |value| {
            computed.content_height.max_size = .{ .px = value };
            used.max_block_size = try positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.content_height.max_size = .{ .percentage = value };
            used.max_block_size = try positivePercentage(value, max(0, containing_block_logical_width));
        },
        .none => {
            computed.content_height.max_size = .none;
            used.max_block_size = std.math.maxInt(ZssUnit);
        },
        .initial, .inherit, .unset => unreachable,
    }
    switch (specified.content_height.size) {
        .px => |value| {
            computed.content_height.size = .{ .px = value };
            used.block_size = clampSize(try positiveLength(.px, value), used.min_block_size, used.max_block_size);
        },
        .percentage => |value| {
            computed.content_height.size = .{ .percentage = value };
            used.block_size = clampSize(try positivePercentage(value, containing_block_logical_width), used.min_block_size, used.max_block_size);
        },
        .auto => {
            computed.content_height.size = .auto;
            used.block_size = null;
        },
        .initial, .inherit, .unset => unreachable,
    }

    context.inputs.setComputedValue(.box_gen, .content_width, computed.content_width);
    context.inputs.setComputedValue(.box_gen, .horizontal_edges, computed.horizontal_edges);
    context.inputs.setComputedValue(.box_gen, .content_height, computed.content_height);
    context.inputs.setComputedValue(.box_gen, .vertical_edges, computed.vertical_edges);

    box_offsets.border_start = .{ .x = used.margin_inline_start, .y = used.margin_block_start };
    box_offsets.content_start = .{
        .x = used.margin_inline_start + used.border_inline_start + used.padding_inline_start,
        .y = used.margin_block_start + used.border_block_start + used.padding_block_start,
    };
    box_offsets.content_end = .{ .x = box_offsets.content_start.x, .y = box_offsets.content_start.y };
    box_offsets.border_end = .{
        .x = box_offsets.content_end.x + used.border_inline_end + used.padding_inline_end,
        .y = box_offsets.content_end.y + used.border_block_end + used.padding_block_end,
    };
    borders.* = .{ .inline_start = used.border_inline_start, .inline_end = used.border_inline_end, .block_start = used.border_block_start, .block_end = used.border_block_end };
    margins.* = .{ .inline_start = used.margin_inline_start, .inline_end = used.margin_inline_end, .block_start = used.margin_block_start, .block_end = used.margin_block_end };

    return InlineBlockSolveSizesResult{
        .logical_width = used.inline_size,
        .logical_heights = UsedLogicalHeights{
            .height = used.block_size,
            .min_height = used.min_block_size,
            .max_height = used.max_block_size,
        },
    };
}

fn inlineBlockSolveSizesPart2(box_offsets: *used_values.BoxOffsets, used_logical_width: ZssUnit, used_logical_heights: UsedLogicalHeights, auto_logical_height: ZssUnit) ZssUnit {
    const used_logical_height = used_logical_heights.height orelse clampSize(auto_logical_height, used_logical_heights.min_height, used_logical_heights.max_height);
    box_offsets.content_end.x += used_logical_width;
    box_offsets.content_end.y += used_logical_height;
    box_offsets.border_end.x += used_logical_width;
    box_offsets.border_end.y += used_logical_height;
    return used_logical_height;
}

fn inlineBlockFinishLayout(doc: *Document, context: *BlockLayoutContext, box_offsets: *used_values.BoxOffsets) void {
    const used_logical_width = context.flow_block_used_logical_width.items[context.flow_block_used_logical_width.items.len - 1];
    const auto_logical_height = context.flow_block_auto_logical_height.items[context.flow_block_auto_logical_height.items.len - 1];
    const used_logical_heights = context.flow_block_used_logical_heights.items[context.flow_block_used_logical_heights.items.len - 1];
    const used_logical_height = inlineBlockSolveSizesPart2(box_offsets, used_logical_width, used_logical_heights, auto_logical_height);
    _ = doc;
    _ = used_logical_height;

    //blockBoxApplyRelativePositioningToChildren(doc, context, used_logical_width, used_logical_height);
}

const Block = struct {
    index: BlockBoxIndex,
    skip: *BlockBoxSkip,
    box_offsets: *used_values.BoxOffsets,
    borders: *used_values.Borders,
    margins: *used_values.Margins,
    properties: *BlockBoxTree.BoxProperties,
};

fn createBlock(doc: *Document) !Block {
    const index = try std.math.cast(BlockBoxIndex, doc.blocks.skips.items.len);
    return Block{
        .index = index,
        .skip = try doc.blocks.skips.addOne(doc.allocator),
        .box_offsets = try doc.blocks.box_offsets.addOne(doc.allocator),
        .borders = try doc.blocks.borders.addOne(doc.allocator),
        .margins = try doc.blocks.margins.addOne(doc.allocator),
        .properties = try doc.blocks.properties.addOne(doc.allocator),
    };
}

fn blockBoxSolveOtherProperties(doc: *Document, inputs: *Inputs, block_box_index: BlockBoxIndex) !void {
    const specified = .{
        .color = inputs.getSpecifiedValue(.cosmetic, .color),
        .border_colors = inputs.getSpecifiedValue(.cosmetic, .border_colors),
        .background1 = inputs.getSpecifiedValue(.cosmetic, .background1),
        .background2 = inputs.getSpecifiedValue(.cosmetic, .background2),
    };

    // TODO: Pretending that specified values are computed values...
    inputs.setComputedValue(.cosmetic, .color, specified.color);
    inputs.setComputedValue(.cosmetic, .border_colors, specified.border_colors);
    inputs.setComputedValue(.cosmetic, .background1, specified.background1);
    inputs.setComputedValue(.cosmetic, .background2, specified.background2);

    const current_color = getCurrentColor(specified.color.color);

    const box_offsets_ptr = &doc.blocks.box_offsets.items[block_box_index];
    const borders_ptr = &doc.blocks.borders.items[block_box_index];

    const border_colors_ptr = &doc.blocks.border_colors.items[block_box_index];
    border_colors_ptr.* = solveBorderColors(specified.border_colors, current_color);

    const background1_ptr = &doc.blocks.background1.items[block_box_index];
    const background2_ptr = &doc.blocks.background2.items[block_box_index];
    background1_ptr.* = solveBackground1(specified.background1, current_color);
    background2_ptr.* = try solveBackground2(specified.background2, box_offsets_ptr, borders_ptr);
}

fn blockBoxFillOtherPropertiesWithDefaults(doc: *Document, block_box_index: BlockBoxIndex) void {
    doc.blocks.border_colors.items[block_box_index] = .{};
    doc.blocks.background1.items[block_box_index] = .{};
    doc.blocks.background2.items[block_box_index] = .{};
}

fn inlineBoxSolveOtherProperties(values: *InlineFormattingContext, inputs: *Inputs, inline_box_index: InlineBoxIndex) !void {
    // TODO: Set the computed values for the element
    const specified = .{
        .color = inputs.getSpecifiedValue(.cosmetic, .color),
        .border_colors = inputs.getSpecifiedValue(.cosmetic, .border_colors),
        .background1 = inputs.getSpecifiedValue(.cosmetic, .background1),
        .background2 = inputs.getSpecifiedValue(.cosmetic, .background2), // TODO: Inline boxes don't need background2
    };

    // TODO: Pretending that specified values are computed values...
    inputs.setComputedValue(.cosmetic, .color, specified.color);
    inputs.setComputedValue(.cosmetic, .border_colors, specified.border_colors);
    inputs.setComputedValue(.cosmetic, .background1, specified.background1);
    inputs.setComputedValue(.cosmetic, .background2, specified.background2);

    const current_color = getCurrentColor(specified.color.color);

    const border_colors = solveBorderColors(specified.border_colors, current_color);
    values.inline_start.items[inline_box_index].border_color_rgba = border_colors.inline_start_rgba;
    values.inline_end.items[inline_box_index].border_color_rgba = border_colors.inline_end_rgba;
    values.block_start.items[inline_box_index].border_color_rgba = border_colors.block_start_rgba;
    values.block_end.items[inline_box_index].border_color_rgba = border_colors.block_end_rgba;

    const background1_ptr = &values.background1.items[inline_box_index];
    background1_ptr.* = solveBackground1(specified.background1, current_color);
}

fn inlineRootBoxSolveOtherProperties(values: *InlineFormattingContext) void {
    values.inline_start.items[0].border_color_rgba = 0;
    values.inline_end.items[0].border_color_rgba = 0;
    values.block_start.items[0].border_color_rgba = 0;
    values.block_end.items[0].border_color_rgba = 0;

    values.background1.items[0] = .{};
}

fn createStackingContext(doc: *Document, context: *BlockLayoutContext, block_box_index: BlockBoxIndex, z_index: ZIndex) !StackingContextIndex {
    try doc.stacking_contexts.ensureTotalCapacity(doc.allocator, doc.stacking_contexts.size() + 1);
    const sc_tree_slice = &doc.stacking_contexts.multi_list.slice();
    const sc_tree_skips = sc_tree_slice.items(.__skip);
    const sc_tree_z_index = sc_tree_slice.items(.z_index);

    const parent_stacking_context_index = context.stacking_context_index.items[context.stacking_context_index.items.len - 1];
    var current = parent_stacking_context_index + 1;
    const end = parent_stacking_context_index + sc_tree_skips[parent_stacking_context_index];
    while (current < end and z_index >= sc_tree_z_index[current]) {
        current += sc_tree_skips[current];
    }

    for (context.stacking_context_index.items) |index| {
        sc_tree_skips[index] += 1;
    }

    doc.stacking_contexts.multi_list.insertAssumeCapacity(current, .{ .__skip = 1, .z_index = z_index, .block_box = block_box_index });
    doc.blocks.properties.items[block_box_index].creates_stacking_context = true;
    return current;
}

fn blockBoxApplyRelativePositioningToChildren(doc: *Document, context: *BlockLayoutContext, containing_block_logical_width: ZssUnit, containing_block_logical_height: ZssUnit) void {
    const count = context.relative_positioned_descendants_count.items[context.relative_positioned_descendants_count.items.len - 1];
    var i: BlockBoxCount = 0;
    while (i < count) : (i += 1) {
        const block_box_index = context.relative_positioned_descendants_indeces.items[context.relative_positioned_descendants_indeces.items.len - 1 - i];
        const element = context.used_id_to_element_index.items[block_box_index];
        _ = element;
        // TODO: Also use the logical properties ('inset-inline-start', 'inset-block-end', etc.) to determine lengths.
        // TODO: Any relative units must be converted to absolute units to form the computed value.
        const specified = .{
            .insets = context.inputs.getSpecifiedValue(.insets),
        };
        const box_offsets = &doc.blocks.box_offsets.items[block_box_index];

        const inline_start = switch (specified.insets.left) {
            .px => |value| length(.px, value),
            .percentage => |value| percentage(value, containing_block_logical_width),
            .auto => null,
            .initial, .inherit, .unset => unreachable,
        };
        const inline_end = switch (specified.insets.right) {
            .px => |value| -length(.px, value),
            .percentage => |value| -percentage(value, containing_block_logical_width),
            .auto => null,
            .initial, .inherit, .unset => unreachable,
        };
        const block_start = switch (specified.insets.top) {
            .px => |value| length(.px, value),
            .percentage => |value| percentage(value, containing_block_logical_height),
            .auto => null,
            .initial, .inherit, .unset => unreachable,
        };
        const block_end = switch (specified.insets.bottom) {
            .px => |value| -length(.px, value),
            .percentage => |value| -percentage(value, containing_block_logical_height),
            .auto => null,
            .initial, .inherit, .unset => unreachable,
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

    inputs: *Inputs,
    block_context: *BlockLayoutContext,
    root_interval: Interval,
    percentage_base_unit: ZssUnit,
    ifc_index: InlineFormattingContextIndex,

    next_element: ElementIndex = undefined,

    intervals: ArrayListUnmanaged(Interval) = .{},
    index: ArrayListUnmanaged(InlineBoxIndex) = .{},

    fn deinit(self: *Self) void {
        self.intervals.deinit(self.inputs.allocator);
        self.index.deinit(self.inputs.allocator);
    }
};

pub fn createInlineBox(doc: *Document, ifc: *InlineFormattingContext) !InlineBoxIndex {
    const old_size = ifc.inline_start.items.len;
    _ = try ifc.inline_start.addOne(doc.allocator);
    _ = try ifc.inline_end.addOne(doc.allocator);
    _ = try ifc.block_start.addOne(doc.allocator);
    _ = try ifc.block_end.addOne(doc.allocator);
    _ = try ifc.margins.addOne(doc.allocator);
    return @intCast(InlineBoxIndex, old_size);
}

fn createInlineFormattingContext(doc: *Document, context: *InlineLayoutContext, ifc: *InlineFormattingContext) Error!void {
    const root_interval = context.root_interval;

    ifc.font = context.inputs.font.font;
    ifc.font_color_rgba = getCurrentColor(context.inputs.font.color);
    ifc.ensureTotalCapacity(doc.allocator, root_interval.end - root_interval.begin + 1) catch {};

    try inlineLevelRootElementPush(doc, context, ifc);

    while (context.intervals.items.len > 0) {
        const interval = &context.intervals.items[context.intervals.items.len - 1];
        if (interval.begin != interval.end) {
            if (try inlineLevelElementPush(doc, context, ifc, interval)) |terminating_element| {
                context.next_element = terminating_element;
                break;
            }
        } else {
            try inlineLevelElementPop(doc, context, ifc);
        }
    } else {
        context.next_element = root_interval.end;
    }

    try ifc.metrics.resize(doc.allocator, ifc.glyph_indeces.items.len);
    inlineValuesSolveMetrics(doc, ifc);
}

fn inlineLevelRootElementPush(doc: *Document, context: *InlineLayoutContext, ifc: *InlineFormattingContext) !void {
    const root_interval = context.root_interval;

    const inline_box_index = try createInlineBox(doc, ifc);
    setRootInlineBoxUsedData(ifc, inline_box_index);

    try addBoxStart(doc, ifc, inline_box_index);

    if (root_interval.begin != root_interval.end) {
        try context.intervals.append(context.inputs.allocator, root_interval);
        try context.index.append(context.inputs.allocator, inline_box_index);
    } else {
        try addBoxEnd(doc, ifc, inline_box_index);
    }
}

/// A non-null return value means that a terminating block box was encountered.
fn inlineLevelElementPush(doc: *Document, context: *InlineLayoutContext, ifc: *InlineFormattingContext, interval: *Interval) !?ElementIndex {
    const element = interval.begin;
    const skip = context.inputs.element_tree_skips[element];
    interval.begin += skip;

    context.inputs.setElement(.box_gen, element);
    const specified = context.inputs.getSpecifiedValue(.box_gen, .box_style);
    const computed = solveBoxStyle(specified, element == root_element);
    switch (computed.display) {
        .text => {
            assert(skip == 1);
            context.inputs.element_index_to_box[element] = .none;
            const text = context.inputs.getText();
            // TODO: Do proper font matching.
            try addText(doc, ifc, text, context.inputs.font);
        },
        .inline_ => {
            const inline_box_index = try createInlineBox(doc, ifc);
            context.inputs.element_index_to_box[element] = .{ .inline_box = .{ .ifc_index = context.ifc_index, .index = inline_box_index } };
            context.inputs.setComputedValue(.box_gen, .box_style, computed);
            try setInlineBoxUsedData(context, ifc, inline_box_index);
            { // TODO: Grabbing useless data to satisfy inheritance...
                const data = .{
                    .content_width = context.inputs.getSpecifiedValue(.box_gen, .content_width),
                    .content_height = context.inputs.getSpecifiedValue(.box_gen, .content_height),
                    .z_index = context.inputs.getSpecifiedValue(.box_gen, .z_index),
                };
                context.inputs.setComputedValue(.box_gen, .content_width, data.content_width);
                context.inputs.setComputedValue(.box_gen, .content_height, data.content_height);
                context.inputs.setComputedValue(.box_gen, .z_index, data.z_index);
            }

            try addBoxStart(doc, ifc, inline_box_index);

            if (skip != 1) {
                try context.inputs.pushElement(.box_gen);
                try context.intervals.append(context.inputs.allocator, .{ .begin = element + 1, .end = element + skip });
                try context.index.append(context.inputs.allocator, inline_box_index);
            } else {
                // Optimized path for elements that have no children. It is like a shorter version of inlineLevelElementPop.
                try addBoxEnd(doc, ifc, inline_box_index);
            }
        },
        .inline_block => {
            const block_context = context.block_context;
            const layout_mode_old_len = block_context.layout_mode.items.len;
            context.inputs.setComputedValue(.box_gen, .box_style, computed);
            try processInlineBlock(doc, block_context);
            while (context.block_context.layout_mode.items.len > layout_mode_old_len) {
                try processElement(doc, block_context);
            }
            switch (context.inputs.element_index_to_box[element]) {
                .none => {},
                .block_box => |block_box_index| try addInlineBlock(doc, ifc, block_box_index),
                .inline_box => unreachable,
            }
        },
        .block => {
            const is_terminating = context.index.items.len == 1;
            if (is_terminating) {
                try addBoxEnd(doc, ifc, 0);
                return element;
            } else {
                @panic("TODO: Blocks within inline contexts");
                //try ifc.glyph_indeces.appendSlice(doc.allocator, &.{ 0, undefined });
            }
        },
        .none => {},
        .initial, .inherit, .unset => unreachable,
    }

    return null;
}

fn inlineLevelElementPop(doc: *Document, context: *InlineLayoutContext, ifc: *InlineFormattingContext) !void {
    const inline_box_index = context.index.items[context.index.items.len - 1];
    try addBoxEnd(doc, ifc, inline_box_index);

    if (inline_box_index != 0) {
        context.inputs.popElement(.box_gen);
    }
    _ = context.intervals.pop();
    _ = context.index.pop();
}

fn addBoxStart(doc: *Document, ifc: *InlineFormattingContext, inline_box_index: InlineBoxIndex) !void {
    const glyphs = [2]GlyphIndex{ 0, InlineFormattingContext.Special.encodeBoxStart(inline_box_index) };
    try ifc.glyph_indeces.appendSlice(doc.allocator, &glyphs);
}

fn addBoxEnd(doc: *Document, ifc: *InlineFormattingContext, inline_box_index: InlineBoxIndex) !void {
    const glyphs = [2]GlyphIndex{ 0, InlineFormattingContext.Special.encodeBoxEnd(inline_box_index) };
    try ifc.glyph_indeces.appendSlice(doc.allocator, &glyphs);
}

fn addInlineBlock(doc: *Document, ifc: *InlineFormattingContext, block_box_index: BlockBoxIndex) !void {
    const glyphs = [2]GlyphIndex{ 0, InlineFormattingContext.Special.encodeInlineBlock(block_box_index) };
    try ifc.glyph_indeces.appendSlice(doc.allocator, &glyphs);
}

fn addLineBreak(doc: *Document, ifc: *InlineFormattingContext) !void {
    const glyphs = [2]GlyphIndex{ 0, InlineFormattingContext.Special.encodeLineBreak() };
    try ifc.glyph_indeces.appendSlice(doc.allocator, &glyphs);
}

fn addText(doc: *Document, ifc: *InlineFormattingContext, text: zss.value.Text, font: ValueTree.Font) !void {
    const buffer = hb.hb_buffer_create() orelse unreachable;
    defer hb.hb_buffer_destroy(buffer);
    _ = hb.hb_buffer_pre_allocate(buffer, @intCast(c_uint, text.len));
    // TODO direction, script, and language must be determined by examining the text itself
    hb.hb_buffer_set_direction(buffer, hb.HB_DIRECTION_LTR);
    hb.hb_buffer_set_script(buffer, hb.HB_SCRIPT_LATIN);
    hb.hb_buffer_set_language(buffer, hb.hb_language_from_string("en", -1));

    var run_begin: usize = 0;
    var run_end: usize = 0;
    while (run_end < text.len) : (run_end += 1) {
        const codepoint = text[run_end];
        switch (codepoint) {
            '\n' => {
                try endTextRun(doc, ifc, text, buffer, font.font, run_begin, run_end);
                try addLineBreak(doc, ifc);
                run_begin = run_end + 1;
            },
            '\r' => {
                try endTextRun(doc, ifc, text, buffer, font.font, run_begin, run_end);
                try addLineBreak(doc, ifc);
                run_end += @boolToInt(run_end + 1 < text.len and text[run_end + 1] == '\n');
                run_begin = run_end + 1;
            },
            '\t' => {
                try endTextRun(doc, ifc, text, buffer, font.font, run_begin, run_end);
                run_begin = run_end + 1;
                // TODO tab size should be determined by the 'tab-size' property
                const tab_size = 8;
                hb.hb_buffer_add_latin1(buffer, " " ** tab_size, tab_size, 0, tab_size);
                if (hb.hb_buffer_allocation_successful(buffer) == 0) return error.OutOfMemory;
                try addTextRun(doc, ifc, buffer, font.font);
                assert(hb.hb_buffer_set_length(buffer, 0) != 0);
            },
            else => {},
        }
    }

    try endTextRun(doc, ifc, text, buffer, font.font, run_begin, run_end);
}

fn endTextRun(doc: *Document, ifc: *InlineFormattingContext, text: zss.value.Text, buffer: *hb.hb_buffer_t, font: *hb.hb_font_t, run_begin: usize, run_end: usize) !void {
    if (run_end > run_begin) {
        hb.hb_buffer_add_latin1(buffer, text.ptr, @intCast(c_int, text.len), @intCast(c_uint, run_begin), @intCast(c_int, run_end - run_begin));
        if (hb.hb_buffer_allocation_successful(buffer) == 0) return error.OutOfMemory;
        try addTextRun(doc, ifc, buffer, font);
        assert(hb.hb_buffer_set_length(buffer, 0) != 0);
    }
}

fn addTextRun(doc: *Document, ifc: *InlineFormattingContext, buffer: *hb.hb_buffer_t, font: *hb.hb_font_t) !void {
    hb.hb_shape(font, buffer, null, 0);
    const glyph_infos = blk: {
        var n: c_uint = 0;
        const p = hb.hb_buffer_get_glyph_infos(buffer, &n);
        break :blk p[0..n];
    };

    // Allocate twice as much so that special glyph indeces always have space
    try ifc.glyph_indeces.ensureUnusedCapacity(doc.allocator, 2 * glyph_infos.len);

    for (glyph_infos) |info| {
        const glyph_index: GlyphIndex = info.codepoint;
        ifc.glyph_indeces.appendAssumeCapacity(glyph_index);
        if (glyph_index == 0) {
            ifc.glyph_indeces.appendAssumeCapacity(InlineFormattingContext.Special.encodeZeroGlyphIndex());
        }
    }
}

fn setRootInlineBoxUsedData(ifc: *InlineFormattingContext, inline_box_index: InlineBoxIndex) void {
    ifc.inline_start.items[inline_box_index] = .{ .border = 0, .padding = 0, .border_color_rgba = 0 };
    ifc.inline_end.items[inline_box_index] = .{ .border = 0, .padding = 0, .border_color_rgba = 0 };
    ifc.block_start.items[inline_box_index] = .{ .border = 0, .padding = 0, .border_color_rgba = 0 };
    ifc.block_end.items[inline_box_index] = .{ .border = 0, .padding = 0, .border_color_rgba = 0 };
    ifc.margins.items[inline_box_index] = .{ .start = 0, .end = 0 };
}

fn setInlineBoxUsedData(context: *InlineLayoutContext, ifc: *InlineFormattingContext, inline_box_index: InlineBoxIndex) !void {
    // TODO: Also use the logical properties ('padding-inline-start', 'border-block-end', etc.).
    // TODO: Border widths are '0' if the value of 'border-style' is 'none' or 'hidden'
    const specified = .{
        .horizontal_edges = context.inputs.getSpecifiedValue(.box_gen, .horizontal_edges),
        .vertical_edges = context.inputs.getSpecifiedValue(.box_gen, .vertical_edges),
    };

    var computed: struct {
        horizontal_edges: ValueTree.BoxEdges,
        vertical_edges: ValueTree.BoxEdges,
    } = undefined;

    var used: struct {
        margin_inline_start: ZssUnit,
        border_inline_start: ZssUnit,
        padding_inline_start: ZssUnit,
        margin_inline_end: ZssUnit,
        border_inline_end: ZssUnit,
        padding_inline_end: ZssUnit,
        border_block_start: ZssUnit,
        padding_block_start: ZssUnit,
        border_block_end: ZssUnit,
        padding_block_end: ZssUnit,
    } = undefined;

    switch (specified.horizontal_edges.margin_start) {
        .px => |value| {
            computed.horizontal_edges.margin_start = .{ .px = value };
            used.margin_inline_start = length(.px, value);
        },
        .percentage => |value| {
            computed.horizontal_edges.margin_start = .{ .percentage = value };
            used.margin_inline_start = percentage(value, context.percentage_base_unit);
        },
        .auto => {
            computed.horizontal_edges.margin_start = .auto;
            used.margin_inline_start = 0;
        },
        .initial, .inherit, .unset => unreachable,
    }
    switch (specified.horizontal_edges.border_start) {
        .px => |value| {
            computed.horizontal_edges.border_start = .{ .px = value };
            used.border_inline_start = try positiveLength(.px, value);
        },
        .thin => {
            const width = borderWidth(.thin);
            computed.horizontal_edges.border_start = .{ .px = width };
            used.border_inline_start = positiveLength(.px, width) catch unreachable;
        },
        .medium => {
            const width = borderWidth(.medium);
            computed.horizontal_edges.border_start = .{ .px = width };
            used.border_inline_start = positiveLength(.px, width) catch unreachable;
        },
        .thick => {
            const width = borderWidth(.thick);
            computed.horizontal_edges.border_start = .{ .px = width };
            used.border_inline_start = positiveLength(.px, width) catch unreachable;
        },
        .initial, .inherit, .unset => unreachable,
    }
    switch (specified.horizontal_edges.padding_start) {
        .px => |value| {
            computed.horizontal_edges.padding_start = .{ .px = value };
            used.padding_inline_start = try positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.horizontal_edges.padding_start = .{ .percentage = value };
            used.padding_inline_start = try positivePercentage(value, context.percentage_base_unit);
        },
        .initial, .inherit, .unset => unreachable,
    }
    switch (specified.horizontal_edges.margin_end) {
        .px => |value| {
            computed.horizontal_edges.margin_end = .{ .px = value };
            used.margin_inline_end = length(.px, value);
        },
        .percentage => |value| {
            computed.horizontal_edges.margin_end = .{ .percentage = value };
            used.margin_inline_end = percentage(value, context.percentage_base_unit);
        },
        .auto => {
            computed.horizontal_edges.margin_end = .auto;
            used.margin_inline_end = 0;
        },
        .initial, .inherit, .unset => unreachable,
    }
    switch (specified.horizontal_edges.border_end) {
        .px => |value| {
            computed.horizontal_edges.border_end = .{ .px = value };
            used.border_inline_end = try positiveLength(.px, value);
        },
        .thin => {
            const width = borderWidth(.thin);
            computed.horizontal_edges.border_end = .{ .px = width };
            used.border_inline_end = positiveLength(.px, width) catch unreachable;
        },
        .medium => {
            const width = borderWidth(.medium);
            computed.horizontal_edges.border_end = .{ .px = width };
            used.border_inline_end = positiveLength(.px, width) catch unreachable;
        },
        .thick => {
            const width = borderWidth(.thick);
            computed.horizontal_edges.border_end = .{ .px = width };
            used.border_inline_end = positiveLength(.px, width) catch unreachable;
        },
        .initial, .inherit, .unset => unreachable,
    }
    switch (specified.horizontal_edges.padding_end) {
        .px => |value| {
            computed.horizontal_edges.padding_end = .{ .px = value };
            used.padding_inline_end = try positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.horizontal_edges.padding_end = .{ .percentage = value };
            used.padding_inline_end = try positivePercentage(value, context.percentage_base_unit);
        },
        .initial, .inherit, .unset => unreachable,
    }

    switch (specified.vertical_edges.border_start) {
        .px => |value| {
            computed.vertical_edges.border_start = .{ .px = value };
            used.border_block_start = try positiveLength(.px, value);
        },
        .thin => {
            const width = borderWidth(.thin);
            computed.vertical_edges.border_start = .{ .px = width };
            used.border_block_start = positiveLength(.px, width) catch unreachable;
        },
        .medium => {
            const width = borderWidth(.medium);
            computed.vertical_edges.border_start = .{ .px = width };
            used.border_block_start = positiveLength(.px, width) catch unreachable;
        },
        .thick => {
            const width = borderWidth(.thick);
            computed.vertical_edges.border_start = .{ .px = width };
            used.border_block_start = positiveLength(.px, width) catch unreachable;
        },
        .initial, .inherit, .unset => unreachable,
    }
    switch (specified.vertical_edges.padding_start) {
        .px => |value| {
            computed.vertical_edges.padding_start = .{ .px = value };
            used.padding_block_start = try positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.vertical_edges.padding_start = .{ .percentage = value };
            used.padding_block_start = try positivePercentage(value, context.percentage_base_unit);
        },
        .initial, .inherit, .unset => unreachable,
    }
    switch (specified.vertical_edges.border_end) {
        .px => |value| {
            computed.vertical_edges.border_end = .{ .px = value };
            used.border_block_end = try positiveLength(.px, value);
        },
        .thin => {
            const width = borderWidth(.thin);
            computed.vertical_edges.border_end = .{ .px = width };
            used.border_block_end = positiveLength(.px, width) catch unreachable;
        },
        .medium => {
            const width = borderWidth(.medium);
            computed.vertical_edges.border_end = .{ .px = width };
            used.border_block_end = positiveLength(.px, width) catch unreachable;
        },
        .thick => {
            const width = borderWidth(.thick);
            computed.vertical_edges.border_end = .{ .px = width };
            used.border_block_end = positiveLength(.px, width) catch unreachable;
        },
        .initial, .inherit, .unset => unreachable,
    }
    switch (specified.vertical_edges.padding_end) {
        .px => |value| {
            computed.vertical_edges.padding_end = .{ .px = value };
            used.padding_block_end = try positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.vertical_edges.padding_end = .{ .percentage = value };
            used.padding_block_end = try positivePercentage(value, context.percentage_base_unit);
        },
        .initial, .inherit, .unset => unreachable,
    }

    computed.vertical_edges.margin_start = specified.vertical_edges.margin_start;
    computed.vertical_edges.margin_end = specified.vertical_edges.margin_end;

    context.inputs.setComputedValue(.box_gen, .horizontal_edges, computed.horizontal_edges);
    context.inputs.setComputedValue(.box_gen, .vertical_edges, computed.vertical_edges);

    ifc.inline_start.items[inline_box_index] = .{ .border = used.border_inline_start, .padding = used.padding_inline_start };
    ifc.inline_end.items[inline_box_index] = .{ .border = used.border_inline_end, .padding = used.padding_inline_end };
    ifc.block_start.items[inline_box_index] = .{ .border = used.border_block_start, .padding = used.padding_block_start };
    ifc.block_end.items[inline_box_index] = .{ .border = used.border_block_end, .padding = used.padding_block_end };
    ifc.margins.items[inline_box_index] = .{ .start = used.margin_inline_start, .end = used.margin_inline_end };
}

fn inlineValuesSolveMetrics(doc: *Document, ifc: *InlineFormattingContext) void {
    const num_glyphs = ifc.glyph_indeces.items.len;
    var i: usize = 0;
    while (i < num_glyphs) : (i += 1) {
        const glyph_index = ifc.glyph_indeces.items[i];
        const metrics = &ifc.metrics.items[i];

        if (glyph_index == 0) {
            i += 1;
            const special = InlineFormattingContext.Special.decode(ifc.glyph_indeces.items[i]);
            const kind = @intToEnum(InlineFormattingContext.Special.LayoutInternalKind, @enumToInt(special.kind));
            switch (kind) {
                .ZeroGlyphIndex => setMetricsGlyph(metrics, ifc.font, 0),
                .BoxStart => {
                    const inline_box_index = @as(InlineBoxIndex, special.data);
                    setMetricsBoxStart(metrics, ifc, inline_box_index);
                },
                .BoxEnd => {
                    const inline_box_index = @as(InlineBoxIndex, special.data);
                    setMetricsBoxEnd(metrics, ifc, inline_box_index);
                },
                .InlineBlock => {
                    const block_box_index = @as(BlockBoxIndex, special.data);
                    setMetricsInlineBlock(metrics, doc, block_box_index);
                },
                .LineBreak => setMetricsLineBreak(metrics),
                .ContinuationBlock => @panic("TODO Continuation block metrics"),
            }
        } else {
            setMetricsGlyph(metrics, ifc.font, glyph_index);
        }
    }
}
fn setMetricsGlyph(metrics: *InlineFormattingContext.Metrics, font: *hb.hb_font_t, glyph_index: GlyphIndex) void {
    var extents: hb.hb_glyph_extents_t = undefined;
    const extents_result = hb.hb_font_get_glyph_extents(font, glyph_index, &extents);
    if (extents_result == 0) {
        extents.width = 0;
        extents.x_bearing = 0;
    }
    metrics.* = .{
        .offset = @divFloor(extents.x_bearing * units_per_pixel, 64),
        .advance = @divFloor(hb.hb_font_get_glyph_h_advance(font, glyph_index) * units_per_pixel, 64),
        .width = @divFloor(extents.width * units_per_pixel, 64),
    };
}

fn setMetricsBoxStart(metrics: *InlineFormattingContext.Metrics, ifc: *InlineFormattingContext, inline_box_index: InlineBoxIndex) void {
    const inline_start = ifc.inline_start.items[inline_box_index];
    const margin = ifc.margins.items[inline_box_index].start;
    const width = inline_start.border + inline_start.padding;
    const advance = width + margin;
    metrics.* = .{ .offset = margin, .advance = advance, .width = width };
}

fn setMetricsBoxEnd(metrics: *InlineFormattingContext.Metrics, ifc: *InlineFormattingContext, inline_box_index: InlineBoxIndex) void {
    const inline_end = ifc.inline_end.items[inline_box_index];
    const margin = ifc.margins.items[inline_box_index].end;
    const width = inline_end.border + inline_end.padding;
    const advance = width + margin;
    metrics.* = .{ .offset = 0, .advance = advance, .width = width };
}

fn setMetricsLineBreak(metrics: *InlineFormattingContext.Metrics) void {
    metrics.* = .{ .offset = 0, .advance = 0, .width = 0 };
}

fn setMetricsInlineBlock(metrics: *InlineFormattingContext.Metrics, doc: *Document, block_box_index: BlockBoxIndex) void {
    const box_offsets = doc.blocks.box_offsets.items[block_box_index];
    const margins = doc.blocks.margins.items[block_box_index];

    const width = box_offsets.border_end.x - box_offsets.border_start.x;
    const advance = width + margins.inline_start + margins.inline_end;
    metrics.* = .{ .offset = margins.inline_start, .advance = advance, .width = width };
}

const InlineFormattingInfo = struct {
    logical_height: ZssUnit,
    longest_line_box_length: ZssUnit,
};

fn splitIntoLineBoxes(doc: *Document, ifc: *InlineFormattingContext, containing_block_logical_width: ZssUnit) !InlineFormattingInfo {
    assert(containing_block_logical_width >= 0);

    var font_extents: hb.hb_font_extents_t = undefined;
    // TODO assuming ltr direction
    assert(hb.hb_font_get_h_extents(ifc.font, &font_extents) != 0);
    ifc.ascender = @divFloor(font_extents.ascender * units_per_pixel, 64);
    ifc.descender = @divFloor(font_extents.descender * units_per_pixel, 64);
    const top_height: ZssUnit = @divFloor((font_extents.ascender + @divFloor(font_extents.line_gap, 2) + @mod(font_extents.line_gap, 2)) * units_per_pixel, 64);
    const bottom_height: ZssUnit = @divFloor((-font_extents.descender + @divFloor(font_extents.line_gap, 2)) * units_per_pixel, 64);

    var cursor: ZssUnit = 0;
    var line_box = InlineFormattingContext.LineBox{ .baseline = 0, .elements = [2]usize{ 0, 0 } };
    var max_top_height = top_height;
    var result = InlineFormattingInfo{ .logical_height = undefined, .longest_line_box_length = 0 };

    var i: usize = 0;
    while (i < ifc.glyph_indeces.items.len) : (i += 1) {
        const gi = ifc.glyph_indeces.items[i];
        const metrics = ifc.metrics.items[i];

        if (gi == 0) {
            i += 1;
            const special = InlineFormattingContext.Special.decode(ifc.glyph_indeces.items[i]);
            switch (@intToEnum(InlineFormattingContext.Special.LayoutInternalKind, @enumToInt(special.kind))) {
                .LineBreak => {
                    line_box.baseline += max_top_height;
                    result.longest_line_box_length = std.math.max(result.longest_line_box_length, cursor);
                    try ifc.line_boxes.append(doc.allocator, line_box);
                    cursor = 0;
                    line_box = .{ .baseline = line_box.baseline + bottom_height, .elements = [2]usize{ line_box.elements[1] + 2, line_box.elements[1] + 2 } };
                    max_top_height = top_height;
                    continue;
                },
                .ContinuationBlock => @panic("TODO Continuation blocks"),
                else => {},
            }
        }

        // TODO: (Bug) A glyph with a width of zero but an advance that is non-zero may overflow the width of the containing block
        if (cursor > 0 and metrics.width > 0 and cursor + metrics.offset + metrics.width > containing_block_logical_width and line_box.elements[1] > line_box.elements[0]) {
            line_box.baseline += max_top_height;
            result.longest_line_box_length = std.math.max(result.longest_line_box_length, cursor);
            try ifc.line_boxes.append(doc.allocator, line_box);
            cursor = 0;
            line_box = .{ .baseline = line_box.baseline + bottom_height, .elements = [2]usize{ line_box.elements[1], line_box.elements[1] } };
            max_top_height = top_height;
        }

        cursor += metrics.advance;

        if (gi == 0) {
            const special = InlineFormattingContext.Special.decode(ifc.glyph_indeces.items[i]);
            switch (@intToEnum(InlineFormattingContext.Special.LayoutInternalKind, @enumToInt(special.kind))) {
                .InlineBlock => {
                    const block_box_index = @as(BlockBoxIndex, special.data);
                    const box_offsets = doc.blocks.box_offsets.items[block_box_index];
                    const margins = doc.blocks.margins.items[block_box_index];
                    const margin_box_height = box_offsets.border_end.y - box_offsets.border_start.y + margins.block_start + margins.block_end;
                    max_top_height = std.math.max(max_top_height, margin_box_height);
                },
                .LineBreak => unreachable,
                .ContinuationBlock => @panic("TODO Continuation blocks"),
                else => {},
            }
            line_box.elements[1] += 2;
        } else {
            line_box.elements[1] += 1;
        }
    }

    if (line_box.elements[1] > line_box.elements[0]) {
        line_box.baseline += max_top_height;
        result.longest_line_box_length = std.math.max(result.longest_line_box_length, cursor);
        try ifc.line_boxes.append(doc.allocator, line_box);
    }

    if (ifc.line_boxes.items.len > 0) {
        result.logical_height = ifc.line_boxes.items[ifc.line_boxes.items.len - 1].baseline + bottom_height;
    } else {
        // TODO This is never reached because the root inline box always creates at least 1 line box.
        result.logical_height = 0;
    }

    return result;
}

fn solveBoxStyle(specified: ValueTree.BoxStyle, root: bool) ValueTree.BoxStyle {
    var computed: ValueTree.BoxStyle = .{
        .display = undefined,
        .position = specified.position,
        .float = specified.float,
    };
    if (specified.display == .none) {
        computed.display = .none;
    } else if (specified.position == .absolute or specified.position == .fixed) {
        computed.display = @"CSS2.2Section9.7Table"(specified.display);
        computed.float = .none;
    } else if (specified.float != .none) {
        computed.display = @"CSS2.2Section9.7Table"(specified.display);
    } else if (root) {
        // TODO: There should be a slightly different version of this function for the root element. (See rule 4 of secion 9.7)
        computed.display = @"CSS2.2Section9.7Table"(specified.display);
    } else {
        computed.display = specified.display;
    }
    return computed;
}

/// Given a specified value for 'display', returns the computed value according to the table found in section 9.7 of CSS2.2.
fn @"CSS2.2Section9.7Table"(display: zss.value.Display) zss.value.Display {
    // TODO: This is incomplete, fill in the rest when more values of the 'display' property are supported.
    // TODO: There should be a slightly different version of this switch table for the root element. (See rule 4 of secion 9.7)
    return switch (display) {
        .inline_, .inline_block, .text => .block,
        else => display,
    };
}

fn solveBorderColors(border_colors: ValueTree.BorderColors, current_color: used_values.Color) used_values.BorderColor {
    return used_values.BorderColor{
        .inline_start_rgba = color(border_colors.left, current_color),
        .inline_end_rgba = color(border_colors.right, current_color),
        .block_start_rgba = color(border_colors.top, current_color),
        .block_end_rgba = color(border_colors.bottom, current_color),
    };
}

fn solveBackground1(bg: ValueTree.Background1, current_color: used_values.Color) used_values.Background1 {
    return used_values.Background1{
        .color_rgba = color(bg.color, current_color),
        .clip = switch (bg.clip) {
            .border_box => .Border,
            .padding_box => .Padding,
            .content_box => .Content,
            .initial, .inherit, .unset => unreachable,
        },
    };
}

fn solveBackground2(bg: ValueTree.Background2, box_offsets: *const used_values.BoxOffsets, borders: *const used_values.Borders) !used_values.Background2 {
    var object = switch (bg.image) {
        .object => |object| object,
        .none => return used_values.Background2{},
        .initial, .inherit, .unset => unreachable,
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
        .initial, .inherit, .unset => unreachable,
    };

    const NaturalSize = struct {
        width: ZssUnit,
        height: ZssUnit,
        has_aspect_ratio: bool,

        fn init(obj: *zss.value.BackgroundImage.Object) !@This() {
            const n = obj.getNaturalSize();
            const width = try positiveLength(.px, n.width);
            const height = try positiveLength(.px, n.height);
            return @This(){
                .width = width,
                .height = height,
                .has_aspect_ratio = width != 0 and height != 0,
            };
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
            if (natural == null) natural = try NaturalSize.init(&object);
            if (!natural.?.has_aspect_ratio) break :blk used_values.Background2.Size{ .width = natural.?.width, .height = natural.?.height };

            const positioning_area_is_wider_than_image = positioning_area.width * natural.?.height > positioning_area.height * natural.?.width;
            const is_contain = (bg.size == .contain);

            if (positioning_area_is_wider_than_image == is_contain) {
                break :blk used_values.Background2.Size{ .width = @divFloor(positioning_area.height * natural.?.width, natural.?.height), .height = positioning_area.height };
            } else {
                break :blk used_values.Background2.Size{ .width = positioning_area.width, .height = @divFloor(positioning_area.width * natural.?.height, natural.?.width) };
            }
        },
        .initial, .inherit, .unset => unreachable,
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
        .initial, .inherit, .unset => unreachable,
    };

    if (width_was_auto or height_was_auto or repeat.x == .Round or repeat.y == .Round) {
        const divRound = zss.util.divRound;
        if (natural == null) natural = try NaturalSize.init(&object);

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
        .initial, .inherit, .unset => unreachable,
    };

    return used_values.Background2{
        .image = object.data,
        .origin = positioning_area.origin,
        .position = position,
        .size = size,
        .repeat = repeat,
    };
}
