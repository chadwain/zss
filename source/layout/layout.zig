const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const MultiArrayList = std.MultiArrayList;

const zss = @import("../../zss.zig");
const ValueTree = zss.ValueTree;
const SSTSeeker = zss.SSTSeeker;
const sstSeeker = zss.sstSeeker;
const ElementTree = zss.ElementTree;
const ElementIndex = ElementTree.Index;

const BoxTree = zss.BoxTree;
const BoxId = BoxTree.BoxId;
const root_box_id = BoxTree.root_box_id;
const reserved_box_id = BoxTree.reserved_box_id;
const maximum_box_id = BoxTree.maximum_box_id;

const used_values = @import("./used_values.zig");
const ZssUnit = used_values.ZssUnit;
const ZssSize = used_values.ZssSize;
const unitsPerPixel = used_values.unitsPerPixel;
const UsedId = used_values.UsedId;
const UsedSubtreeSize = used_values.UsedSubtreeSize;
const UsedBoxCount = used_values.UsedBoxCount;
const StackingContextId = used_values.StackingContextId;
const InlineId = used_values.InlineId;
const ZIndex = used_values.ZIndex;
const BlockLevelUsedValues = used_values.BlockLevelUsedValues;
const InlineLevelUsedValues = used_values.InlineLevelUsedValues;
const GlyphIndex = InlineLevelUsedValues.GlyphIndex;
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
    const size = element_tree.size();
    // TODO: Decide if `size == 0` should be an error or not.
    if (size == 0 or size > maximum_box_id) return error.Overflow;
    var inputs = Inputs{
        .element_tree_skips = element_tree.skips(),
        .seekers = Seekers.init(cascaded_value_tree),
        .font = cascaded_value_tree.font,
        .allocator = allocator,
        .viewport_size = viewport_size,
    };
    defer inputs.deinit();
    var context = BlockLayoutContext{ .inputs = &inputs };
    defer context.deinit();
    var doc = Document{ .allocator = allocator };
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

fn clampSize(size: ZssUnit, min_size: ZssUnit, max_size: ZssUnit) ZssUnit {
    return std.math.max(min_size, std.math.min(size, max_size));
}

const BorderThickness = enum { thin, medium, thick };

fn borderWidthPx(comptime thickness: BorderThickness) f32 {
    return switch (thickness) {
        .thin => 1,
        .medium => 3,
        .thick => 5,
    };
}

fn borderWidth(comptime thickness: BorderThickness) ZssUnit {
    return length(.px, thickness);
}

fn color(col: zss.value.Color, current_color: u32) u32 {
    return switch (col) {
        .rgba => |rgba| rgba,
        .current_color => current_color,
        .initial, .inherit, .unset => unreachable,
    };
}

fn colorProperty(col: zss.value.Color) u32 {
    return switch (col) {
        .rgba => |rgba| rgba,
        .current_color => unreachable,
        .initial, .inherit, .unset => unreachable,
    };
}

const LayoutMode = enum {
    Flow,
    ShrinkToFit1stPass,
    ShrinkToFit2ndPass,
    InlineContainer,
};

const Interval = struct {
    begin: ElementIndex,
    end: ElementIndex,
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

const ContinuationBlock = struct {
    /// The element that created the continuation block.
    element: ElementIndex,
    /// The position within the glyph_indeces array of
    /// the special glyph index that represents the continuation block.
    index: usize,
};

const InlineBlock = struct {
    /// The element that created the inline block.
    element: ElementIndex,
    /// The position within the glyph_indeces array of
    /// the special glyph index that represents the inline block.
    index: usize,
};

const InlineContainer = struct {
    values: *InlineLevelUsedValues,
    inline_blocks: []InlineBlock,
    used_id_to_element_index: []ElementIndex,
    next_inline_block: usize,
    containing_block_logical_width: ZssUnit,
    shrink_to_fit: bool,

    fn deinit(self: *@This(), allocator: Allocator) void {
        allocator.free(self.inline_blocks);
        allocator.free(self.used_id_to_element_index);
    }
};

const Seekers = struct {
    const fields = std.meta.fields(ValueTree.Values);
    const Enum = std.meta.FieldEnum(ValueTree.Values);

    all: SSTSeeker(fields[@enumToInt(Enum.all)].field_type),
    text: SSTSeeker(fields[@enumToInt(Enum.text)].field_type),
    display_position_float: SSTSeeker(fields[@enumToInt(Enum.display_position_float)].field_type),
    widths: SSTSeeker(fields[@enumToInt(Enum.widths)].field_type),
    horizontal_sizes: SSTSeeker(fields[@enumToInt(Enum.horizontal_sizes)].field_type),
    heights: SSTSeeker(fields[@enumToInt(Enum.heights)].field_type),
    vertical_sizes: SSTSeeker(fields[@enumToInt(Enum.vertical_sizes)].field_type),
    z_index: SSTSeeker(fields[@enumToInt(Enum.z_index)].field_type),
    insets: SSTSeeker(fields[@enumToInt(Enum.insets)].field_type),
    color: SSTSeeker(fields[@enumToInt(Enum.color)].field_type),
    border_colors: SSTSeeker(fields[@enumToInt(Enum.border_colors)].field_type),
    background1: SSTSeeker(fields[@enumToInt(Enum.background1)].field_type),
    background2: SSTSeeker(fields[@enumToInt(Enum.background2)].field_type),

    fn init(cascaded_value_tree: *const ValueTree) Seekers {
        var result: Seekers = undefined;
        inline for (std.meta.fields(Seekers)) |seeker| {
            @field(result, seeker.name) = sstSeeker(@field(cascaded_value_tree.values, seeker.name));
        }
        return result;
    }
};

const ComputedValueStack = struct {
    display_position_float: ArrayListUnmanaged(ValueTree.DisplayPositionFloat) = .{},
    widths: ArrayListUnmanaged(ValueTree.Sizes) = .{},
    horizontal_sizes: ArrayListUnmanaged(ValueTree.PaddingBorderMargin) = .{},
    heights: ArrayListUnmanaged(ValueTree.Sizes) = .{},
    vertical_sizes: ArrayListUnmanaged(ValueTree.PaddingBorderMargin) = .{},
};

const ListOfComptutedValues = struct {
    display_position_float: bool = false,
    widths: bool = false,
    horizontal_sizes: bool = false,
    heights: bool = false,
    vertical_sizes: bool = false,
    insets: bool = false,
};

const ThisElement = struct {
    element: ElementIndex = undefined,
    all: ?zss.value.All = undefined,

    list_of_computed_values: ListOfComptutedValues = .{},
    computed: struct {
        display_position_float: ValueTree.DisplayPositionFloat = undefined,
        widths: ValueTree.Sizes = undefined,
        horizontal_sizes: ValueTree.PaddingBorderMargin = undefined,
        heights: ValueTree.Sizes = undefined,
        vertical_sizes: ValueTree.PaddingBorderMargin = undefined,
        insets: ValueTree.Insets = undefined,
    } = .{},
};

const Inputs = struct {
    const Self = @This();

    element_tree_skips: []const ElementIndex,
    seekers: Seekers,
    font: ValueTree.Font,

    computed_value_stack: ComputedValueStack = .{},
    element_stack: ArrayListUnmanaged(ElementIndex) = .{},
    list_of_computed_values_stack: MultiArrayList(ListOfComptutedValues) = .{},

    this_element: ThisElement = .{},

    allocator: Allocator,
    viewport_size: ZssSize,

    fn deinit(self: *Self) void {
        self.element_stack.deinit(self.allocator);
        self.list_of_computed_values_stack.deinit(self.allocator);
        inline for (std.meta.fields(ComputedValueStack)) |field_info| {
            @field(self.computed_value_stack, field_info.name).deinit(self.allocator);
        }
    }

    fn setElement(self: *Self, element: ElementIndex) void {
        self.this_element.element = element;

        const all_seeker = &self.seekers.all;
        if (all_seeker.seekBinary(element)) {
            self.this_element.all = all_seeker.get().all;
        } else {
            self.this_element.all = null;
        }
    }

    fn setComputedValue(self: *Self, comptime property: ValueTree.AggregatePropertyEnum, value: property.Value()) void {
        const flag = &@field(self.this_element.list_of_computed_values, @tagName(property));
        assert(!flag.*);
        flag.* = true;
        @field(self.this_element.computed, @tagName(property)) = value;
    }

    fn pushElement(self: *Self) !void {
        try self.element_stack.append(self.allocator, self.this_element.element);
        try self.list_of_computed_values_stack.append(self.allocator, self.this_element.list_of_computed_values);
        inline for (std.meta.fields(ListOfComptutedValues)) |field_info| {
            if (@field(self.this_element.list_of_computed_values, field_info.name)) {
                const value = @field(self.this_element.computed, field_info.name);
                try @field(self.computed_value_stack, field_info.name).append(self.allocator, value);
            }
        }

        self.this_element = .{};
    }

    fn popElement(self: *Self) void {
        self.element_stack.shrinkRetainingCapacity(self.element_stack.items.len - 1);
        const list = self.list_of_computed_values_stack.get(self.list_of_computed_values_stack.len - 1);
        self.list_of_computed_values_stack.shrinkRetainingCapacity(self.list_of_computed_values_stack.len - 1);

        inline for (std.meta.fields(ListOfComptutedValues)) |field_info| {
            if (@field(list, field_info.name)) {
                _ = @field(self.computed_value_stack, field_info.name).pop();
            }
        }
    }

    fn getSpecifiedValue(self: *Self, comptime property: ValueTree.AggregatePropertyEnum) property.Value() {
        const Value = property.Value();
        const fields = std.meta.fields(Value);
        const inheritance_type = comptime property.inheritanceType();

        var result: Value = undefined;
        switch (getCascadedValue(self, property)) {
            .value => |value| result = value,
            // TODO: Just copy the inherited value and return
            .all_inherit => result = comptime blk: {
                var v: Value = undefined;
                inline for (fields) |field_info| {
                    @field(v, field_info.name) = .inherit;
                }
                break :blk v;
            },
            .all_initial => return Value{},
        }

        inline for (fields) |field_info| {
            const value = &@field(result, field_info.name);
            switch (value.*) {
                .inherit => @panic("TODO: Get specified value via inheritance"),
                .initial => value.* = field_info.default_value.?,
                .unset => switch (inheritance_type) {
                    .inherited => @panic("TODO: Get specified value via inheritance"),
                    .not_inherited => value.* = field_info.default_value.?,
                    .neither => unreachable,
                },
                else => {},
            }
        }

        return result;
    }

    fn getCascadedValue(
        self: *Self,
        comptime property: ValueTree.AggregatePropertyEnum,
    ) union(enum) {
        value: property.Value(),
        all_inherit,
        all_initial,
    } {
        const Value = property.Value();
        const fields = std.meta.fields(Value);
        const inheritance_type = comptime property.inheritanceType();

        switch (inheritance_type) {
            .inherited, .not_inherited => {},
            .neither => @compileError("Cannot get cascaded value of '" ++ @tagName(property) ++ "'"),
        }

        // Find the value using the cascaded value tree.
        const seeker = &@field(self.seekers, @tagName(property));
        // TODO: This always uses a binary search to look for values. There might be more efficient/complicated ways to do seeking.
        if (seeker.seekBinary(self.this_element.element)) {
            const value = seeker.get();
            if (property == .color) {
                // CSS-COLOR-3§4.4: If the ‘currentColor’ keyword is set on the ‘color’ property itself, it is treated as ‘color: inherit’.
                comptime assert(fields.len == 1);
                if (value.color == .current_color) {
                    return .all_inherit;
                }
            }
            return .{ .value = value };
        }

        // Use the value of the 'all' property, if it is set.
        if (property != .direction and property != .unicode_bidi and property != .custom) {
            if (self.this_element.all) |all| switch (all) {
                .inherit => return .all_inherit,
                .initial => return .all_initial,
                .unset => {},
            };
        }

        // Just use the inheritance type.
        switch (inheritance_type) {
            .inherited => return .all_inherit,
            .not_inherited => return .all_initial,
            .neither => unreachable,
        }
    }

    fn getText(self: *Self, element: ElementIndex) zss.value.Text {
        const seeker = &self.seekers.text;
        if (seeker.seekBinary(element)) {
            return seeker.get().text;
        } else {
            return "";
        }
    }
};

const BlockLayoutContext = struct {
    inputs: *Inputs,

    layout_mode: ArrayListUnmanaged(LayoutMode) = .{},

    metadata: ArrayListUnmanaged(Metadata) = .{},
    stacking_context_id: ArrayListUnmanaged(StackingContextId) = .{},
    used_id_to_element_index: ArrayListUnmanaged(ElementIndex) = .{},

    intervals: ArrayListUnmanaged(Interval) = .{},
    used_id: ArrayListUnmanaged(UsedId) = .{},
    used_subtree_size: ArrayListUnmanaged(UsedSubtreeSize) = .{},

    flow_block_used_logical_width: ArrayListUnmanaged(ZssUnit) = .{},
    flow_block_auto_logical_height: ArrayListUnmanaged(ZssUnit) = .{},
    flow_block_used_logical_heights: ArrayListUnmanaged(UsedLogicalHeights) = .{},

    relative_positioned_descendants_ids: ArrayListUnmanaged(UsedId) = .{},
    relative_positioned_descendants_count: ArrayListUnmanaged(UsedBoxCount) = .{},

    shrink_to_fit_available_width: ArrayListUnmanaged(ZssUnit) = .{},
    shrink_to_fit_auto_width: ArrayListUnmanaged(ZssUnit) = .{},
    shrink_to_fit_base_width: ArrayListUnmanaged(ZssUnit) = .{},
    used_id_intervals: ArrayListUnmanaged(UsedIdInterval) = .{},

    inline_container: ArrayListUnmanaged(InlineContainer) = .{},

    fn deinit(self: *BlockLayoutContext) void {
        self.intervals.deinit(self.inputs.allocator);
        self.metadata.deinit(self.inputs.allocator);
        self.layout_mode.deinit(self.inputs.allocator);
        self.used_id.deinit(self.inputs.allocator);
        self.used_subtree_size.deinit(self.inputs.allocator);
        self.stacking_context_id.deinit(self.inputs.allocator);
        self.used_id_to_element_index.deinit(self.inputs.allocator);
        self.flow_block_used_logical_width.deinit(self.inputs.allocator);
        self.flow_block_auto_logical_height.deinit(self.inputs.allocator);
        self.flow_block_used_logical_heights.deinit(self.inputs.allocator);
        self.relative_positioned_descendants_ids.deinit(self.inputs.allocator);
        self.relative_positioned_descendants_count.deinit(self.inputs.allocator);
        self.shrink_to_fit_available_width.deinit(self.inputs.allocator);
        self.shrink_to_fit_auto_width.deinit(self.inputs.allocator);
        self.shrink_to_fit_base_width.deinit(self.inputs.allocator);
        self.used_id_intervals.deinit(self.inputs.allocator);
        for (self.inline_container.items) |*container| {
            container.deinit(self.inputs.allocator);
        }
        self.inline_container.deinit(self.inputs.allocator);
    }
};

fn createBlockLevelUsedValues(doc: *Document, context: *BlockLayoutContext) !void {
    doc.blocks.ensureTotalCapacity(doc.allocator, context.inputs.element_tree_skips[0] + 1) catch {};

    // Initialize the context with some data.
    try context.layout_mode.append(context.inputs.allocator, .Flow);
    try context.used_subtree_size.append(context.inputs.allocator, 1);
    try context.flow_block_auto_logical_height.append(context.inputs.allocator, 0);

    // Create the initial containing block.
    try createInitialContainingBlock(doc, context);

    // Process the root element.
    try processElement(doc, context);
    // TODO: This is not a good reason to return early
    //  * Root might generate more than one box
    //  * Root might have 'display: contents'
    if (doc.blocks.structure.items.len == 1) {
        // The root element has a 'display' value of 'none'.
        return;
    }

    // Create the root stacking context.
    // TODO: Don't assume that the principal box of the root element has a used_id of 1.
    try doc.stacking_context_tree.subtree.append(doc.allocator, 1);
    try doc.stacking_context_tree.stacking_contexts.append(doc.allocator, .{ .z_index = 0, .used_id = 1 });
    doc.blocks.properties.items[1].creates_stacking_context = true;
    try context.stacking_context_id.append(context.inputs.allocator, 0);

    // Process all other elements.
    while (context.layout_mode.items.len > 1) {
        try processElement(doc, context);
    }

    // Solve for all of the properties that don't affect layout.
    const num_created_boxes = doc.blocks.structure.items[0];
    assert(context.used_id_to_element_index.items.len == num_created_boxes);
    try doc.blocks.border_colors.resize(doc.allocator, num_created_boxes);
    try doc.blocks.background1.resize(doc.allocator, num_created_boxes);
    try doc.blocks.background2.resize(doc.allocator, num_created_boxes);
    for (context.used_id_to_element_index.items) |element, used_id| {
        _ = element;
        blockBoxFillOtherPropertiesWithDefaults(doc, @intCast(UsedId, used_id));
        // if (element != reserved_box_id) {
        //     try blockBoxSolveOtherProperties(doc, context.inputs, element, @intCast(UsedId, used_id));
        // } else {
        //     blockBoxFillOtherPropertiesWithDefaults(doc, @intCast(UsedId, used_id));
        // }
    }
}

fn createInitialContainingBlock(doc: *Document, context: *BlockLayoutContext) !void {
    const width = context.inputs.viewport_size.w;
    const height = context.inputs.viewport_size.h;

    const block = try createBlock(doc, context, reserved_box_id);
    block.structure.* = undefined;
    block.properties.* = .{};
    block.box_offsets.* = .{
        .border_start = .{ .x = 0, .y = 0 },
        .content_start = .{ .x = 0, .y = 0 },
        .content_end = .{ .x = width, .y = height },
        .border_end = .{ .x = width, .y = height },
    };
    block.borders.* = .{};
    block.margins.* = .{};

    const interval = Interval{ .begin = root_box_id, .end = root_box_id + context.inputs.element_tree_skips[root_box_id] };
    const logical_heights = UsedLogicalHeights{
        .height = height,
        .min_height = height,
        .max_height = height,
    };
    try pushFlowLayout(context, interval, block.used_id, width, logical_heights, null);
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

fn processElement(doc: *Document, context: *BlockLayoutContext) !void {
    const layout_mode = context.layout_mode.items[context.layout_mode.items.len - 1];
    switch (layout_mode) {
        .Flow => {
            const interval = &context.intervals.items[context.intervals.items.len - 1];
            if (interval.begin != interval.end) {
                context.inputs.setElement(interval.begin);
                const specified = context.inputs.getSpecifiedValue(.display_position_float);
                var computed: ValueTree.DisplayPositionFloat = .{
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
                } else if (interval.begin == root_box_id) {
                    // TODO: There should be a slightly different version of this function for the root element. (See rule 4 of secion 9.7)
                    computed.display = @"CSS2.2Section9.7Table"(specified.display);
                } else {
                    computed.display = specified.display;
                }
                context.inputs.setComputedValue(.display_position_float, computed);

                switch (computed.display) {
                    .block => return processFlowBlock(doc, context, interval),
                    .inline_, .inline_block, .text => {
                        @panic("TODO Inline layout");
                        //const containing_block_logical_width = context.flow_block_used_logical_width.items[context.flow_block_used_logical_width.items.len - 1];
                        //return processInlineContainer(doc, context, interval, containing_block_logical_width, .Normal);
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
        //.InlineContainer => {
        //    const container = context.inline_container.items[context.inline_container.items.len - 1];

        //    if (container.next_inline_block < container.inline_blocks.len) {
        //        return processInlineBlock(doc, context, container);
        //    }

        //    try popInlineContainer(doc, context);
        //},
        else => @panic("TODO: Other layout modes."),
    }
}

fn skipElement(context: *BlockLayoutContext, interval: *Interval) void {
    const element = interval.begin;
    interval.begin += context.inputs.element_tree_skips[element];
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

    const block = try createBlock(doc, context, element);
    block.structure.* = undefined;
    block.properties.* = .{};

    const logical_width = try flowBlockSolveInlineSizes(context, block.box_offsets, block.borders, block.margins);
    const used_logical_heights = try flowBlockSolveBlockSizesPart1(context, block.box_offsets, block.borders, block.margins);

    const position = context.inputs.this_element.computed.display_position_float.position;
    const stacking_context_id = switch (position) {
        .static => null,
        .relative => blk: {
            if (element == root_box_id) {
                // TODO: Should maybe just treat position as static
                // This is the root element. Position must be 'static'.
                return error.InvalidValue;
            }

            context.relative_positioned_descendants_count.items[context.relative_positioned_descendants_count.items.len - 1] += 1;
            try context.relative_positioned_descendants_ids.append(context.inputs.allocator, block.used_id);

            const specified_z_index = context.inputs.getSpecifiedValue(.z_index);
            context.inputs.setComputedValue(.z_index, specified_z_index);
            switch (specified_z_index.z_index) {
                .integer => |z_index| break :blk try createStackingContext(doc, context, block.used_id, z_index),
                .auto => {
                    _ = try createStackingContext(doc, context, block.used_id, 0);
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

    try pushFlowLayout(context, Interval{ .begin = element + 1, .end = element + skip }, block.used_id, logical_width, used_logical_heights, stacking_context_id);
}

fn pushFlowLayout(
    context: *BlockLayoutContext,
    interval: Interval,
    used_id: UsedId,
    logical_width: ZssUnit,
    logical_heights: UsedLogicalHeights,
    stacking_context_id: ?StackingContextId,
) !void {
    try context.inputs.pushElement();

    // The allocations here must have corresponding deallocations in popFlowBlock.
    try context.layout_mode.append(context.inputs.allocator, .Flow);
    try context.intervals.append(context.inputs.allocator, interval);
    try context.used_id.append(context.inputs.allocator, used_id);
    try context.used_subtree_size.append(context.inputs.allocator, 1);
    try context.flow_block_used_logical_width.append(context.inputs.allocator, logical_width);
    try context.flow_block_auto_logical_height.append(context.inputs.allocator, 0);
    // TODO don't need used_logical_heights
    try context.flow_block_used_logical_heights.append(context.inputs.allocator, logical_heights);
    try context.relative_positioned_descendants_count.append(context.inputs.allocator, 0);
    if (stacking_context_id) |id| {
        try context.stacking_context_id.append(context.inputs.allocator, id);
        try context.metadata.append(context.inputs.allocator, .{ .is_stacking_context_parent = true });
    } else {
        try context.metadata.append(context.inputs.allocator, .{ .is_stacking_context_parent = false });
    }
}

fn popFlowBlock(doc: *Document, context: *BlockLayoutContext) void {
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
        .ShrinkToFit1stPass => {
            flowBlockFinishLayout(doc, context, box_offsets);
        },
        .ShrinkToFit2ndPass => unreachable,
        .InlineContainer => {
            inlineBlockFinishLayout(doc, context, box_offsets);
            const container = &context.inline_container.items[context.inline_container.items.len - 1];
            addBlockToInlineContainer(container);
        },
    }

    context.inputs.popElement();

    // The deallocations here must correspond to allocations in pushFlowLayout.
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
        .widths = context.inputs.getSpecifiedValue(.widths),
        .horizontal_sizes = context.inputs.getSpecifiedValue(.horizontal_sizes),
    };

    var computed: struct {
        widths: ValueTree.Sizes = undefined,
        horizontal_sizes: ValueTree.PaddingBorderMargin = undefined,
    } = .{};

    var used: struct {
        border_start: ZssUnit = undefined,
        border_end: ZssUnit = undefined,
        padding_start: ZssUnit = undefined,
        padding_end: ZssUnit = undefined,
        margin_start: ZssUnit = undefined,
        margin_end: ZssUnit = undefined,
        size: ZssUnit = undefined,
        min_size: ZssUnit = undefined,
        max_size: ZssUnit = undefined,
    } = .{};

    // TODO: Border widths are '0' if the value of 'border-style' is 'none' or 'hidden'
    switch (specified.horizontal_sizes.border_start) {
        .px => |value| {
            computed.horizontal_sizes.border_start = .{ .px = value };
            used.border_start = try positiveLength(.px, value);
        },
        .thin => {
            const width = borderWidthPx(.thin);
            computed.horizontal_sizes.border_start = .{ .px = width };
            used.border_start = length(.px, width);
        },
        .medium => {
            const width = borderWidthPx(.medium);
            computed.horizontal_sizes.border_start = .{ .px = width };
            used.border_start = length(.px, width);
        },
        .thick => {
            const width = borderWidthPx(.thick);
            computed.horizontal_sizes.border_start = .{ .px = width };
            used.border_start = length(.px, width);
        },
        .initial, .inherit, .unset => unreachable,
    }
    switch (specified.horizontal_sizes.border_end) {
        .px => |value| {
            computed.horizontal_sizes.border_end = .{ .px = value };
            used.border_end = try positiveLength(.px, value);
        },
        .thin => {
            const width = borderWidthPx(.thin);
            computed.horizontal_sizes.border_end = .{ .px = width };
            used.border_end = length(.px, width);
        },
        .medium => {
            const width = borderWidthPx(.medium);
            computed.horizontal_sizes.border_end = .{ .px = width };
            used.border_end = length(.px, width);
        },
        .thick => {
            const width = borderWidthPx(.thick);
            computed.horizontal_sizes.border_end = .{ .px = width };
            used.border_end = length(.px, width);
        },
        .initial, .inherit, .unset => unreachable,
    }
    switch (specified.horizontal_sizes.padding_start) {
        .px => |value| {
            computed.horizontal_sizes.padding_start = .{ .px = value };
            used.padding_start = try positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.horizontal_sizes.padding_start = .{ .percentage = value };
            used.padding_start = try positivePercentage(value, containing_block_logical_width);
        },
        .initial, .inherit, .unset => unreachable,
    }
    switch (specified.horizontal_sizes.padding_end) {
        .px => |value| {
            computed.horizontal_sizes.padding_end = .{ .px = value };
            used.padding_end = try positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.horizontal_sizes.padding_end = .{ .percentage = value };
            used.padding_end = try positivePercentage(value, containing_block_logical_width);
        },
        .initial, .inherit, .unset => unreachable,
    }

    switch (specified.widths.min_size) {
        .px => |value| {
            computed.widths.min_size = .{ .px = value };
            used.min_size = try positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.widths.min_size = .{ .percentage = value };
            used.min_size = try positivePercentage(value, containing_block_logical_width);
        },
        .initial, .inherit, .unset => unreachable,
    }
    switch (specified.widths.max_size) {
        .px => |value| {
            computed.widths.max_size = .{ .px = value };
            used.max_size = try positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.widths.max_size = .{ .percentage = value };
            used.max_size = try positivePercentage(value, containing_block_logical_width);
        },
        .none => {
            computed.widths.max_size = .none;
            used.max_size = std.math.maxInt(ZssUnit);
        },
        .initial, .inherit, .unset => unreachable,
    }

    var auto_bitfield: u3 = 0;
    const size_bit = 4;
    const margin_start_bit = 2;
    const margin_end_bit = 1;

    switch (specified.widths.size) {
        .px => |value| {
            computed.widths.size = .{ .px = value };
            used.size = try positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.widths.size = .{ .percentage = value };
            used.size = try positivePercentage(value, containing_block_logical_width);
        },
        .auto => {
            computed.widths.size = .auto;
            auto_bitfield |= size_bit;
            used.size = 0;
        },
        .initial, .inherit, .unset => unreachable,
    }
    switch (specified.horizontal_sizes.margin_start) {
        .px => |value| {
            computed.horizontal_sizes.margin_start = .{ .px = value };
            used.margin_start = length(.px, value);
        },
        .percentage => |value| {
            computed.horizontal_sizes.margin_start = .{ .percentage = value };
            used.margin_start = percentage(value, containing_block_logical_width);
        },
        .auto => {
            computed.horizontal_sizes.margin_start = .auto;
            auto_bitfield |= margin_start_bit;
            used.margin_start = 0;
        },
        .initial, .inherit, .unset => unreachable,
    }
    switch (specified.horizontal_sizes.margin_end) {
        .px => |value| {
            computed.horizontal_sizes.margin_end = .{ .px = value };
            used.margin_end = length(.px, value);
        },
        .percentage => |value| {
            computed.horizontal_sizes.margin_end = .{ .percentage = value };
            used.margin_end = percentage(value, containing_block_logical_width);
        },
        .auto => {
            computed.horizontal_sizes.margin_end = .auto;
            auto_bitfield |= margin_end_bit;
            used.margin_end = 0;
        },
        .initial, .inherit, .unset => unreachable,
    }

    context.inputs.setComputedValue(.widths, computed.widths);
    context.inputs.setComputedValue(.horizontal_sizes, computed.horizontal_sizes);

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
        .heights = context.inputs.getSpecifiedValue(.heights),
        .vertical_sizes = context.inputs.getSpecifiedValue(.vertical_sizes),
    };

    var computed: struct {
        heights: ValueTree.Sizes = undefined,
        vertical_sizes: ValueTree.PaddingBorderMargin = undefined,
    } = .{};

    var used: struct {
        border_start: ZssUnit = undefined,
        border_end: ZssUnit = undefined,
        padding_start: ZssUnit = undefined,
        padding_end: ZssUnit = undefined,
        margin_start: ZssUnit = undefined,
        margin_end: ZssUnit = undefined,
        size: ?ZssUnit = undefined,
        min_size: ZssUnit = undefined,
        max_size: ZssUnit = undefined,
    } = .{};

    // TODO: Border widths are '0' if the value of 'border-style' is 'none' or 'hidden'
    switch (specified.vertical_sizes.border_start) {
        .px => |value| {
            computed.vertical_sizes.border_start = .{ .px = value };
            used.border_start = try positiveLength(.px, value);
        },
        .thin => {
            const width = borderWidthPx(.thin);
            computed.vertical_sizes.border_start = .{ .px = width };
            used.border_start = length(.px, width);
        },
        .medium => {
            const width = borderWidthPx(.medium);
            computed.vertical_sizes.border_start = .{ .px = width };
            used.border_start = length(.px, width);
        },
        .thick => {
            const width = borderWidthPx(.thick);
            computed.vertical_sizes.border_start = .{ .px = width };
            used.border_start = length(.px, width);
        },
        .initial, .inherit, .unset => unreachable,
    }
    switch (specified.vertical_sizes.border_end) {
        .px => |value| {
            computed.vertical_sizes.border_end = .{ .px = value };
            used.border_end = try positiveLength(.px, value);
        },
        .thin => {
            const width = borderWidthPx(.thin);
            computed.vertical_sizes.border_end = .{ .px = width };
            used.border_end = length(.px, width);
        },
        .medium => {
            const width = borderWidthPx(.medium);
            computed.vertical_sizes.border_end = .{ .px = width };
            used.border_end = length(.px, width);
        },
        .thick => {
            const width = borderWidthPx(.thick);
            computed.vertical_sizes.border_end = .{ .px = width };
            used.border_end = length(.px, width);
        },
        .initial, .inherit, .unset => unreachable,
    }
    switch (specified.vertical_sizes.padding_start) {
        .px => |value| {
            computed.vertical_sizes.padding_start = .{ .px = value };
            used.padding_start = try positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.vertical_sizes.padding_start = .{ .percentage = value };
            used.padding_start = try positivePercentage(value, containing_block_logical_width);
        },
        .initial, .inherit, .unset => unreachable,
    }
    switch (specified.vertical_sizes.padding_end) {
        .px => |value| {
            computed.vertical_sizes.padding_end = .{ .px = value };
            used.padding_end = try positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.vertical_sizes.padding_end = .{ .percentage = value };
            used.padding_end = try positivePercentage(value, containing_block_logical_width);
        },
        .initial, .inherit, .unset => unreachable,
    }
    switch (specified.vertical_sizes.margin_start) {
        .px => |value| {
            computed.vertical_sizes.margin_start = .{ .px = value };
            used.margin_start = length(.px, value);
        },
        .percentage => |value| {
            computed.vertical_sizes.margin_start = .{ .percentage = value };
            used.margin_start = percentage(value, containing_block_logical_width);
        },
        .auto => {
            computed.vertical_sizes.margin_start = .auto;
            used.margin_start = 0;
        },
        .initial, .inherit, .unset => unreachable,
    }
    switch (specified.vertical_sizes.margin_end) {
        .px => |value| {
            computed.vertical_sizes.margin_end = .{ .px = value };
            used.margin_end = length(.px, value);
        },
        .percentage => |value| {
            computed.vertical_sizes.margin_end = .{ .percentage = value };
            used.margin_end = percentage(value, containing_block_logical_width);
        },
        .auto => {
            computed.vertical_sizes.margin_end = .auto;
            used.margin_end = 0;
        },
        .initial, .inherit, .unset => unreachable,
    }

    switch (specified.heights.min_size) {
        .px => |value| {
            computed.heights.min_size = .{ .px = value };
            used.min_size = try positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.heights.min_size = .{ .percentage = value };
            used.min_size = if (containing_block_logical_height) |s|
                try positivePercentage(value, s)
            else
                0;
        },
        .initial, .inherit, .unset => unreachable,
    }
    switch (specified.heights.max_size) {
        .px => |value| {
            computed.heights.max_size = .{ .px = value };
            used.max_size = try positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.heights.max_size = .{ .percentage = value };
            used.max_size = if (containing_block_logical_height) |s|
                try positivePercentage(value, s)
            else
                std.math.maxInt(ZssUnit);
        },
        .none => {
            computed.heights.max_size = .none;
            used.max_size = std.math.maxInt(ZssUnit);
        },
        .initial, .inherit, .unset => unreachable,
    }
    switch (specified.heights.size) {
        .px => |value| {
            computed.heights.size = .{ .px = value };
            used.size = clampSize(try positiveLength(.px, value), used.min_size, used.max_size);
        },
        .percentage => |value| {
            computed.heights.size = .{ .percentage = value };
            used.size = if (containing_block_logical_height) |h|
                clampSize(try positivePercentage(value, h), used.min_size, used.max_size)
            else
                null;
        },
        .auto => {
            computed.heights.size = .auto;
            used.size = null;
        },
        .initial, .inherit, .unset => unreachable,
    }

    context.inputs.setComputedValue(.heights, computed.heights);
    context.inputs.setComputedValue(.vertical_sizes, computed.vertical_sizes);

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
    blockBoxApplyRelativePositioningToChildren(doc, context, logical_width, logical_height);
}

fn processShrinkToFit1stPassBlock(doc: *Document, context: *BlockLayoutContext, interval: *Interval) !void {
    const box_id = interval.begin;
    const subtree_size = context.box_tree.structure[box_id];
    interval.begin += subtree_size;

    const block = try createBlock(doc, context, box_id);
    block.structure.* = undefined;
    block.properties.* = .{};

    const width_info = try shrinkToFit1stPassGetWidth(context, box_id);

    if (width_info.width) |width| {
        const parent_shrink_to_fit_width = &context.shrink_to_fit_auto_width.items[context.shrink_to_fit_auto_width.items.len - 1];
        parent_shrink_to_fit_width.* = std.math.max(parent_shrink_to_fit_width.*, width + width_info.base_width);

        const logical_width = try flowBlockSolveInlineSizes(context, box_id, block.box_offsets, block.borders, block.margins);
        assert(logical_width == width);
        const used_logical_heights = try flowBlockSolveBlockSizesPart1(context, box_id, block.box_offsets, block.borders, block.margins);
        try pushFlowLayout(context, Interval{ .begin = box_id + 1, .end = box_id + subtree_size }, block.used_id, logical_width, used_logical_heights, null);
    } else {
        block.properties.uses_shrink_to_fit_sizing = true;
        const parent_available_width = context.shrink_to_fit_available_width.items[context.shrink_to_fit_available_width.items.len - 1];
        const available_width = std.math.max(0, parent_available_width - width_info.base_width);
        const used_logical_heights = try shrinkToFit1stPassGetHeights(context, box_id);
        try pushShrinkToFit1stPassLayout(context, box_id, block.used_id, available_width, width_info.base_width, used_logical_heights);
    }
}

fn pushShrinkToFit1stPassLayout(
    context: *BlockLayoutContext,
    element: ElementIndex,
    used_id: UsedId,
    available_width: ZssUnit,
    base_width: ZssUnit,
    used_logical_heights: UsedLogicalHeights,
) !void {
    const skip = context.inputs.element_tree_skips[element];
    // The allocations here must have corresponding deallocations in popShrinkToFit1stPassBlock.
    try context.layout_mode.append(context.inputs.allocator, .ShrinkToFit1stPass);
    try context.intervals.append(context.inputs.allocator, .{ .begin = element + 1, .end = element + skip });
    try context.used_id.append(context.inputs.allocator, used_id);
    try context.used_subtree_size.append(context.inputs.allocator, 1);
    try context.shrink_to_fit_available_width.append(context.inputs.allocator, available_width);
    try context.shrink_to_fit_auto_width.append(context.inputs.allocator, 0);
    try context.shrink_to_fit_base_width.append(context.inputs.allocator, base_width);
    try context.flow_block_used_logical_heights.append(context.inputs.allocator, used_logical_heights);
}

fn popShrinkToFit1stPassBlock(doc: *Document, context: *BlockLayoutContext) !void {
    const used_id = context.used_id.items[context.used_id.items.len - 1];
    const used_subtree_size = context.used_subtree_size.items[context.used_subtree_size.items.len - 1];
    doc.blocks.structure.items[used_id] = used_subtree_size;
    context.used_subtree_size.items[context.used_subtree_size.items.len - 2] += used_subtree_size;

    const shrink_to_fit_width = context.shrink_to_fit_auto_width.items[context.shrink_to_fit_auto_width.items.len - 1];

    var go_to_2nd_pass = false;
    const parent_layout_mode = context.layout_mode.items[context.layout_mode.items.len - 2];
    switch (parent_layout_mode) {
        // Valid as long as flow blocks cannot directly contain shrink-to-fit blocks.
        // This might change when absolute blocks or floats are implemented.
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
    _ = context.used_id.pop();
    _ = context.used_subtree_size.pop();
    const used_logical_heights = context.flow_block_used_logical_heights.pop();

    if (go_to_2nd_pass) {
        const used_id_interval = UsedIdInterval{ .begin = used_id + 1, .end = used_id + doc.blocks.structure.items[used_id] };
        try pushShrinkToFit2ndPassLayout(context, used_id, used_id_interval, shrink_to_fit_width, used_logical_heights);
    }
}

const ShrinkToFit1stPassGetWidthResult = struct {
    /// The sum of the widths of all horizontal borders, padding, and margins.
    base_width: ZssUnit,
    width: ?ZssUnit,
};

fn shrinkToFit1stPassGetWidth(
    context: *const BlockLayoutContext,
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

fn shrinkToFit1stPassGetHeights(context: *BlockLayoutContext, box_id: BoxId) !UsedLogicalHeights {
    const block_size = context.box_tree.block_size[box_id];
    const containing_block_logical_height = context.flow_block_used_logical_heights.items[context.flow_block_used_logical_heights.items.len - 1].height;
    if (containing_block_logical_height) |h| assert(h >= 0);

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
    const size = switch (block_size.size) {
        .px => |value| clampSize(try positiveLength(.px, value), min_size, max_size),
        .percentage => |value| if (containing_block_logical_height) |h|
            clampSize(try positivePercentage(value, h), min_size, max_size)
        else
            null,
        .auto => null,
    };

    return UsedLogicalHeights{
        .height = size,
        .min_height = min_size,
        .max_height = max_size,
    };
}

fn processShrinkToFit2ndPassBlock(doc: *Document, context: *BlockLayoutContext, used_id_interval: *UsedIdInterval) !void {
    const used_id = used_id_interval.begin;
    const used_subtree_size = doc.blocks.structure.items[used_id_interval.begin];
    used_id_interval.begin += used_subtree_size;

    const properties = doc.blocks.properties.items[used_id];
    const box_offsets = &doc.blocks.box_offsets.items[used_id];
    const borders = &doc.blocks.borders.items[used_id];
    const margins = &doc.blocks.margins.items[used_id];

    if (!properties.uses_shrink_to_fit_sizing or properties.inline_context_index != null) {
        const parent_auto_logical_height = &context.flow_block_auto_logical_height.items[context.flow_block_auto_logical_height.items.len - 1];
        addBlockToFlow(box_offsets, margins.block_end, parent_auto_logical_height);
    } else {
        const box_id = context.used_id_to_element_index.items[used_id];
        const logical_width = try flowBlockSolveInlineSizes(context, box_id, box_offsets, borders, margins);
        const used_logical_heights = try flowBlockSolveBlockSizesPart1(context, box_id, box_offsets, borders, margins);
        const new_interval = UsedIdInterval{ .begin = used_id + 1, .end = used_id + used_subtree_size };
        try pushShrinkToFit2ndPassLayout(context, used_id, new_interval, logical_width, used_logical_heights);
    }
}

fn pushShrinkToFit2ndPassLayout(
    context: *BlockLayoutContext,
    used_id: UsedId,
    used_id_interval: UsedIdInterval,
    logical_width: ZssUnit,
    logical_heights: UsedLogicalHeights,
) !void {
    // The allocations here must correspond to deallocations in popShrinkToFit2ndPassBlock.
    try context.layout_mode.append(context.inputs.allocator, .ShrinkToFit2ndPass);
    try context.used_id.append(context.inputs.allocator, used_id);
    try context.used_id_intervals.append(context.inputs.allocator, used_id_interval);
    try context.flow_block_used_logical_width.append(context.inputs.allocator, logical_width);
    try context.flow_block_auto_logical_height.append(context.inputs.allocator, 0);
    try context.flow_block_used_logical_heights.append(context.inputs.allocator, logical_heights);
}

fn popShrinkToFit2ndPassBlock(doc: *Document, context: *BlockLayoutContext) void {
    const used_id = context.used_id.items[context.used_id.items.len - 1];
    const box_offsets = &doc.blocks.box_offsets.items[used_id];
    const margins = doc.blocks.margins.items[used_id];

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
            const container = &context.inline_container.items[context.inline_container.items.len - 1];
            addBlockToInlineContainer(container);
        },
    }

    _ = context.layout_mode.pop();
    _ = context.flow_block_used_logical_width.pop();
    _ = context.flow_block_auto_logical_height.pop();
    _ = context.flow_block_used_logical_heights.pop();
    _ = context.used_id.pop();
    _ = context.used_id_intervals.pop();
}

fn processInlineContainer(
    doc: *Document,
    context: *BlockLayoutContext,
    interval: *Interval,
    containing_block_logical_width: ZssUnit,
    mode: enum { Normal, ShrinkToFit },
) !void {
    var continuation_blocks = ArrayListUnmanaged(ContinuationBlock){};
    errdefer continuation_blocks.deinit(context.inputs.allocator);

    var inline_blocks = ArrayListUnmanaged(InlineBlock){};
    errdefer inline_blocks.deinit(context.inputs.allocator);

    var used_id_to_element_index = ArrayListUnmanaged(BoxId){};
    errdefer used_id_to_element_index.deinit(context.inputs.allocator);

    var inline_context = InlineLayoutContext.init(context, interval.*, &continuation_blocks, &inline_blocks, &used_id_to_element_index);
    defer inline_context.deinit();

    const inline_values_ptr = try doc.allocator.create(InlineLevelUsedValues);
    errdefer doc.allocator.destroy(inline_values_ptr);
    inline_values_ptr.* = .{};
    errdefer inline_values_ptr.deinit(doc.allocator);

    try createInlineLevelUsedValues(doc, &inline_context, inline_values_ptr);

    if (continuation_blocks.items.len > 0) {
        @panic("TODO Continuation blocks");
    }
    interval.begin = inline_context.next_element;
    try doc.inlines.append(doc.allocator, inline_values_ptr);

    // Create an "anonymous block box" to contain this inline formatting context.
    const block = try createBlock(doc, context, reserved_box_id);
    block.structure.* = undefined;
    block.properties.* = .{ .inline_context_index = try std.math.cast(InlineId, doc.inlines.items.len - 1) };
    block.box_offsets.* = undefined;
    block.borders.* = undefined;
    block.margins.* = undefined;

    const is_shrink_to_fit = switch (mode) {
        .Normal => false,
        .ShrinkToFit => true,
    };
    try pushInlineContainerLayout(context, inline_values_ptr, block.used_id, &inline_blocks, &used_id_to_element_index, containing_block_logical_width, is_shrink_to_fit);
}

fn pushInlineContainerLayout(
    context: *BlockLayoutContext,
    values: *InlineLevelUsedValues,
    used_id: UsedId,
    inline_blocks_list: *ArrayListUnmanaged(InlineBlock),
    used_id_to_element_index_list: *ArrayListUnmanaged(BoxId),
    containing_block_logical_width: ZssUnit,
    shrink_to_fit: bool,
) !void {
    const inline_blocks = inline_blocks_list.toOwnedSlice(context.inputs.allocator);
    errdefer context.inputs.allocator.free(inline_blocks);

    const used_id_to_element_index = used_id_to_element_index_list.toOwnedSlice(context.inputs.allocator);
    errdefer context.inputs.allocator.free(used_id_to_element_index);

    // The allocations here must have corresponding deallocations in popInlineContainer.
    try context.layout_mode.append(context.inputs.allocator, .InlineContainer);
    try context.used_id.append(context.inputs.allocator, used_id);
    try context.used_subtree_size.append(context.inputs.allocator, 1);
    try context.inline_container.append(context.inputs.allocator, .{
        .values = values,
        .inline_blocks = inline_blocks,
        .used_id_to_element_index = used_id_to_element_index,
        .next_inline_block = 0,
        .containing_block_logical_width = containing_block_logical_width,
        .shrink_to_fit = shrink_to_fit,
    });
}

fn popInlineContainer(doc: *Document, context: *BlockLayoutContext) !void {
    const used_id = context.used_id.items[context.used_id.items.len - 1];
    const used_subtree_size = context.used_subtree_size.items[context.used_subtree_size.items.len - 1];
    doc.blocks.structure.items[used_id] = used_subtree_size;
    context.used_subtree_size.items[context.used_subtree_size.items.len - 2] += used_subtree_size;

    const container = &context.inline_container.items[context.inline_container.items.len - 1];
    const percentage_base_unit = if (container.shrink_to_fit) 0 else container.containing_block_logical_width;
    try inlineValuesFinishLayout(doc, context, container, percentage_base_unit);

    const info = try splitIntoLineBoxes(doc, container.values, container.containing_block_logical_width);
    const used_logical_width = if (container.shrink_to_fit) info.longest_line_box_length else container.containing_block_logical_width;
    const used_logical_height = info.logical_height;

    inlineContainerPositionInlineBlocks(doc, container.*);

    const box_offsets = &doc.blocks.box_offsets.items[used_id];
    const borders = &doc.blocks.borders.items[used_id];
    const margins = &doc.blocks.margins.items[used_id];
    box_offsets.* = .{
        .border_start = .{ .x = 0, .y = 0 },
        .content_start = .{ .x = 0, .y = 0 },
        .content_end = .{ .x = used_logical_width, .y = used_logical_height },
        .border_end = .{ .x = used_logical_width, .y = used_logical_height },
    };
    borders.* = .{};
    margins.* = .{};

    const parent_layout_mode = context.layout_mode.items[context.layout_mode.items.len - 2];
    switch (parent_layout_mode) {
        .Flow => {
            const parent_auto_logical_height = &context.flow_block_auto_logical_height.items[context.flow_block_auto_logical_height.items.len - 1];
            addBlockToFlow(box_offsets, 0, parent_auto_logical_height);
        },
        .ShrinkToFit1stPass => {
            const parent_shrink_to_fit_width = &context.shrink_to_fit_auto_width.items[context.shrink_to_fit_auto_width.items.len - 1];
            parent_shrink_to_fit_width.* = std.math.max(parent_shrink_to_fit_width.*, used_logical_width);
        },
        .ShrinkToFit2ndPass => @panic("unimplemented"),
        .InlineContainer => unreachable,
    }

    // The deallocations here must correspond to allocations in pushInlineContainerLayout.
    _ = context.layout_mode.pop();
    _ = context.used_id.pop();
    _ = context.used_subtree_size.pop();
    container.deinit(context.inputs.allocator);
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

fn addBlockToInlineContainer(container: *InlineContainer) void {
    container.next_inline_block += 1;
}

fn processInlineBlock(doc: *Document, context: *BlockLayoutContext, container: InlineContainer) !void {
    const inline_block = container.inline_blocks[container.next_inline_block];
    const element = inline_block.element;
    const skip = context.inputs.element_tree_skips[element];

    const block = try createBlock(doc, context, element);
    block.structure.* = undefined;
    block.properties.* = .{};

    _ = try createStackingContext(doc, context, block.used_id, 0);
    container.values.glyph_indeces.items[inline_block.index + 1] = InlineLevelUsedValues.Special.encodeInlineBlock(block.used_id);

    const sizes = try inlineBlockSolveSizesPart1(context, inline_block.element, block.box_offsets, block.borders, block.margins);

    if (sizes.logical_width) |logical_width| {
        try pushFlowLayout(context, Interval{ .begin = element + 1, .end = element + skip }, block.used_id, logical_width, sizes.logical_heights, null);
    } else {
        const base_width = (block.box_offsets.content_start.x - block.box_offsets.border_start.x) + (block.box_offsets.border_end.x - block.box_offsets.content_end.x) + block.margins.inline_start + block.margins.inline_end;
        const available_width = std.math.max(0, container.containing_block_logical_width - base_width);
        try pushShrinkToFit1stPassLayout(context, element, block.used_id, available_width, base_width, sizes.logical_heights);
    }
}

const InlineBlockSolveSizesResult = struct {
    logical_width: ?ZssUnit,
    logical_heights: UsedLogicalHeights,
};

fn inlineBlockSolveSizesPart1(
    context: *BlockLayoutContext,
    element: ElementIndex,
    box_offsets: *used_values.BoxOffsets,
    borders: *used_values.Borders,
    margins: *used_values.Margins,
) !InlineBlockSolveSizesResult {
    const max = std.math.max;
    // TODO: Also use the logical properties ('padding-inline-start', 'border-block-end', etc.).
    const specified = .{
        .widths = context.inputs.getSpecifiedValue(.widths, element),
        .horizontal_sizes = context.inputs.getSpecifiedValue(.horizontal_sizes, element),
        .heights = context.inputs.getSpecifiedValue(.heights, element),
        .vertical_sizes = context.inputs.getSpecifiedValue(.vertical_sizes, element),
    };
    const containing_block_logical_width = context.flow_block_used_logical_width.items[context.flow_block_used_logical_width.items.len - 1];
    assert(containing_block_logical_width >= 0);

    const border_inline_start = switch (specified.horizontal_sizes.border_start) {
        .px => |value| try positiveLength(.px, value),
        .thin => borderWidth(.thin),
        .medium => borderWidth(.medium),
        .thick => borderWidth(.thick),
        .initial, .inherit, .unset => unreachable,
    };
    const border_inline_end = switch (specified.horizontal_sizes.border_end) {
        .px => |value| try positiveLength(.px, value),
        .thin => borderWidth(.thin),
        .medium => borderWidth(.medium),
        .thick => borderWidth(.thick),
        .initial, .inherit, .unset => unreachable,
    };
    const padding_inline_start = switch (specified.horizontal_sizes.padding_start) {
        .px => |value| try positiveLength(.px, value),
        .percentage => |value| try positivePercentage(value, containing_block_logical_width),
        .initial, .inherit, .unset => unreachable,
    };
    const padding_inline_end = switch (specified.horizontal_sizes.padding_end) {
        .px => |value| try positiveLength(.px, value),
        .percentage => |value| try positivePercentage(value, containing_block_logical_width),
        .initial, .inherit, .unset => unreachable,
    };
    const margin_inline_start = switch (specified.horizontal_sizes.margin_start) {
        .px => |value| length(.px, value),
        .percentage => |value| percentage(value, containing_block_logical_width),
        .auto => 0,
        .initial, .inherit, .unset => unreachable,
    };
    const margin_inline_end = switch (specified.horizontal_sizes.margin_end) {
        .px => |value| length(.px, value),
        .percentage => |value| percentage(value, containing_block_logical_width),
        .auto => 0,
        .initial, .inherit, .unset => unreachable,
    };
    const min_inline_size = switch (specified.widths.min_size) {
        .px => |value| try positiveLength(.px, value),
        .percentage => |value| try positivePercentage(value, max(0, containing_block_logical_width)),
        .initial, .inherit, .unset => unreachable,
    };
    const max_inline_size = switch (specified.widths.max_size) {
        .px => |value| try positiveLength(.px, value),
        .percentage => |value| try positivePercentage(value, max(0, containing_block_logical_width)),
        .none => std.math.maxInt(ZssUnit),
        .initial, .inherit, .unset => unreachable,
    };
    const inline_size = switch (specified.widths.size) {
        .px => |value| clampSize(try positiveLength(.px, value), min_inline_size, max_inline_size),
        .percentage => |value| clampSize(try positivePercentage(value, containing_block_logical_width), min_inline_size, max_inline_size),
        .auto => null,
        .initial, .inherit, .unset => unreachable,
    };

    const border_block_start = switch (specified.vertical_sizes.border_start) {
        .px => |value| try positiveLength(.px, value),
        .thin => borderWidth(.thin),
        .medium => borderWidth(.medium),
        .thick => borderWidth(.thick),
        .initial, .inherit, .unset => unreachable,
    };
    const border_block_end = switch (specified.vertical_sizes.border_end) {
        .px => |value| try positiveLength(.px, value),
        .thin => borderWidth(.thin),
        .medium => borderWidth(.medium),
        .thick => borderWidth(.thick),
        .initial, .inherit, .unset => unreachable,
    };
    const padding_block_start = switch (specified.vertical_sizes.padding_start) {
        .px => |value| try positiveLength(.px, value),
        .percentage => |value| try positivePercentage(value, containing_block_logical_width),
        .initial, .inherit, .unset => unreachable,
    };
    const padding_block_end = switch (specified.vertical_sizes.padding_end) {
        .px => |value| try positiveLength(.px, value),
        .percentage => |value| try positivePercentage(value, containing_block_logical_width),
        .initial, .inherit, .unset => unreachable,
    };
    const margin_block_start = switch (specified.vertical_sizes.margin_start) {
        .px => |value| length(.px, value),
        .percentage => |value| percentage(value, containing_block_logical_width),
        .auto => 0,
        .initial, .inherit, .unset => unreachable,
    };
    const margin_block_end = switch (specified.vertical_sizes.margin_end) {
        .px => |value| length(.px, value),
        .percentage => |value| percentage(value, containing_block_logical_width),
        .auto => 0,
        .initial, .inherit, .unset => unreachable,
    };
    const min_block_size = switch (specified.heights.min_size) {
        .px => |value| try positiveLength(.px, value),
        .percentage => |value| try positivePercentage(value, max(0, containing_block_logical_width)),
        .initial, .inherit, .unset => unreachable,
    };
    const max_block_size = switch (specified.heights.max_size) {
        .px => |value| try positiveLength(.px, value),
        .percentage => |value| try positivePercentage(value, max(0, containing_block_logical_width)),
        .none => std.math.maxInt(ZssUnit),
        .initial, .inherit, .unset => unreachable,
    };
    const block_size = switch (specified.heights.size) {
        .px => |value| clampSize(try positiveLength(.px, value), min_block_size, max_block_size),
        .percentage => |value| clampSize(try positivePercentage(value, containing_block_logical_width), min_block_size, max_block_size),
        .auto => null,
        .initial, .inherit, .unset => unreachable,
    };

    box_offsets.border_start = .{ .x = margin_inline_start, .y = margin_block_start };
    box_offsets.content_start = .{
        .x = margin_inline_start + border_inline_start + padding_inline_start,
        .y = margin_block_start + border_block_start + padding_block_start,
    };
    box_offsets.content_end = .{ .x = box_offsets.content_start.x, .y = box_offsets.content_start.y };
    box_offsets.border_end = .{
        .x = box_offsets.content_end.x + border_inline_end + padding_inline_end,
        .y = box_offsets.content_end.y + border_block_end + padding_block_end,
    };
    borders.* = .{ .inline_start = border_inline_start, .inline_end = border_inline_end, .block_start = border_block_start, .block_end = border_block_end };
    margins.* = .{ .inline_start = margin_inline_start, .inline_end = margin_inline_end, .block_start = margin_block_start, .block_end = margin_block_end };

    return InlineBlockSolveSizesResult{
        .logical_width = inline_size,
        .logical_heights = UsedLogicalHeights{
            .height = block_size,
            .min_height = min_block_size,
            .max_height = max_block_size,
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

fn createBlock(doc: *Document, context: *BlockLayoutContext, box_id: BoxId) !Block {
    assert(doc.blocks.structure.items.len == context.used_id_to_element_index.items.len);
    const used_id = try std.math.cast(UsedId, doc.blocks.structure.items.len);
    try context.used_id_to_element_index.append(context.inputs.allocator, box_id);
    return Block{
        .used_id = used_id,
        .structure = try doc.blocks.structure.addOne(doc.allocator),
        .box_offsets = try doc.blocks.box_offsets.addOne(doc.allocator),
        .borders = try doc.blocks.borders.addOne(doc.allocator),
        .margins = try doc.blocks.margins.addOne(doc.allocator),
        .properties = try doc.blocks.properties.addOne(doc.allocator),
    };
}

fn blockBoxSolveOtherProperties(doc: *Document, inputs: *Inputs, element: ElementIndex, used_id: UsedId) !void {
    const specified = .{
        .color = inputs.getSpecifiedValue(.color, element),
        .border_colors = inputs.getSpecifiedValue(.border_colors, element),
        .background1 = inputs.getSpecifiedValue(.background1, element),
        .background2 = inputs.getSpecifiedValue(.background2, element),
    };
    const current_color = colorProperty(specified.color.color);

    const box_offsets_ptr = &doc.blocks.box_offsets.items[used_id];
    const borders_ptr = &doc.blocks.borders.items[used_id];

    const border_colors_ptr = &doc.blocks.border_colors.items[used_id];
    border_colors_ptr.* = solveBorderColors(specified.border_colors, current_color);

    const background1_ptr = &doc.blocks.background1.items[used_id];
    const background2_ptr = &doc.blocks.background2.items[used_id];
    background1_ptr.* = solveBackground1(specified.background1, current_color);
    background2_ptr.* = try solveBackground2(specified.background2, box_offsets_ptr, borders_ptr);
}

fn blockBoxFillOtherPropertiesWithDefaults(doc: *Document, used_id: UsedId) void {
    doc.blocks.borders.items[used_id] = .{};
    doc.blocks.background1.items[used_id] = .{};
    doc.blocks.background2.items[used_id] = .{};
}

fn createStackingContext(doc: *Document, context: *BlockLayoutContext, used_id: UsedId, z_index: ZIndex) !StackingContextId {
    const sc_tree = &doc.stacking_context_tree;
    const parent_stacking_context_id = context.stacking_context_id.items[context.stacking_context_id.items.len - 1];
    var current = parent_stacking_context_id + 1;
    const end = parent_stacking_context_id + sc_tree.subtree.items[parent_stacking_context_id];
    while (current < end and z_index >= sc_tree.stacking_contexts.items[current].z_index) : (current += sc_tree.subtree.items[current]) {}

    for (context.stacking_context_id.items) |index| {
        sc_tree.subtree.items[index] += 1;
    }
    try sc_tree.subtree.insert(doc.allocator, current, 1);
    try sc_tree.stacking_contexts.insert(doc.allocator, current, .{ .z_index = z_index, .used_id = used_id });
    doc.blocks.properties.items[used_id].creates_stacking_context = true;
    return current;
}

fn blockBoxApplyRelativePositioningToChildren(doc: *Document, context: *BlockLayoutContext, containing_block_logical_width: ZssUnit, containing_block_logical_height: ZssUnit) void {
    const count = context.relative_positioned_descendants_count.items[context.relative_positioned_descendants_count.items.len - 1];
    var i: UsedBoxCount = 0;
    while (i < count) : (i += 1) {
        const used_id = context.relative_positioned_descendants_ids.items[context.relative_positioned_descendants_ids.items.len - 1 - i];
        const element = context.used_id_to_element_index.items[used_id];
        // TODO: Also use the logical properties ('inset-inline-start', 'inset-block-end', etc.) to determine lengths.
        // TODO: Any relative units must be converted to absolute units to form the computed value.
        const specified = .{
            .insets = context.inputs.getSpecifiedValue(.insets),
        };
        const box_offsets = &doc.blocks.box_offsets.items[used_id];

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
    root_interval: Interval,

    intervals: ArrayListUnmanaged(Interval),
    used_ids: ArrayListUnmanaged(UsedId),

    continuation_blocks: *ArrayListUnmanaged(ContinuationBlock),
    inline_blocks: *ArrayListUnmanaged(InlineBlock),
    used_id_to_element_index: *ArrayListUnmanaged(BoxId),
    next_element: ElementIndex,

    fn init(
        context: *const BlockLayoutContext,
        block_container_interval: Interval,
        continuation_blocks: *ArrayListUnmanaged(ContinuationBlock),
        inline_blocks: *ArrayListUnmanaged(InlineBlock),
        used_id_to_element_index: *ArrayListUnmanaged(BoxId),
    ) Self {
        return Self{
            .inputs = context.inputs,
            .root_interval = Interval{ .begin = block_container_interval.begin, .end = block_container_interval.end },
            .intervals = .{},
            .used_ids = .{},
            .continuation_blocks = continuation_blocks,
            .inline_blocks = inline_blocks,
            .used_id_to_element_index = used_id_to_element_index,
            .next_element = block_container_interval.end,
        };
    }

    fn deinit(self: *Self) void {
        self.intervals.deinit(self.inputs.allocator);
        self.used_ids.deinit(self.inputs.allocator);
    }
};

fn createInlineLevelUsedValues(doc: *Document, context: *InlineLayoutContext, values: *InlineLevelUsedValues) Error!void {
    const root_interval = context.root_interval;

    values.ensureTotalCapacity(doc.allocator, root_interval.end - root_interval.begin + 1) catch {};

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

fn inlineLevelRootElementPush(doc: *Document, context: *InlineLayoutContext, values: *InlineLevelUsedValues, root_interval: Interval) !void {
    const root_used_id = try std.math.cast(UsedId, context.used_id_to_element_index.items.len);
    try context.used_id_to_element_index.append(context.inputs.allocator, reserved_box_id);
    try addBoxStart(doc, values, root_used_id);

    if (root_interval.begin != root_interval.end) {
        try context.intervals.append(context.inputs.allocator, root_interval);
        try context.used_ids.append(context.inputs.allocator, root_used_id);
    } else {
        try addBoxEnd(doc, values, root_used_id);
    }
}

fn inlineLevelElementPush(doc: *Document, context: *InlineLayoutContext, values: *InlineLevelUsedValues, interval: *Interval) !bool {
    const element = interval.begin;
    const skip = context.inputs.element_tree_skips[element];
    interval.begin += skip;

    const dps = context.inputs.getSpecifiedValue(.display_position_float, element);
    // TODO: Use the computed value of display.
    switch (dps.display) {
        .text => {
            assert(skip == 1);
            const text = context.inputs.getText(element);
            // TODO: Do proper font matching.
            try addText(doc, values, text, context.inputs.font);
        },
        .inline_ => {
            const used_id = try std.math.cast(UsedId, context.used_id_to_element_index.items.len);
            try context.used_id_to_element_index.append(context.inputs.allocator, element);
            try addBoxStart(doc, values, used_id);

            if (skip != 1) {
                try context.intervals.append(context.inputs.allocator, .{ .begin = element + 1, .end = element + skip });
                try context.used_ids.append(context.inputs.allocator, used_id);
            } else {
                // Optimized path for elements that have no children. It is like a shorter version of inlineLevelElementPop.
                try addBoxEnd(doc, values, used_id);
            }
        },
        .inline_block => {
            try values.glyph_indeces.appendSlice(doc.allocator, &.{ 0, undefined });
            try context.inline_blocks.append(context.inputs.allocator, .{ .element = element, .index = values.glyph_indeces.items.len - 2 });
        },
        .block => {
            const is_top_level = context.used_ids.items.len == 1;
            if (is_top_level) {
                context.next_element = element;
                var i = context.used_ids.items.len;
                while (i > 0) : (i -= 1) {
                    try addBoxEnd(doc, values, context.used_ids.items[i - 1]);
                }
                return true;
            } else {
                try values.glyph_indeces.appendSlice(doc.allocator, &.{ 0, undefined });
                try context.continuation_blocks.append(context.inputs.allocator, .{ .element = element, .index = values.glyph_indeces.items.len - 2 });
            }
        },
        .none => {},
        .initial, .inherit, .unset => unreachable,
    }

    return false;
}

fn inlineLevelElementPop(doc: *Document, context: *InlineLayoutContext, values: *InlineLevelUsedValues) !void {
    const used_id = context.used_ids.items[context.used_ids.items.len - 1];
    try addBoxEnd(doc, values, used_id);

    _ = context.intervals.pop();
    _ = context.used_ids.pop();
}

fn addBoxStart(doc: *Document, values: *InlineLevelUsedValues, used_id: UsedId) !void {
    const glyphs = [2]GlyphIndex{ 0, InlineLevelUsedValues.Special.encodeBoxStart(used_id) };
    try values.glyph_indeces.appendSlice(doc.allocator, &glyphs);
}

fn addBoxEnd(doc: *Document, values: *InlineLevelUsedValues, used_id: UsedId) !void {
    const glyphs = [2]GlyphIndex{ 0, InlineLevelUsedValues.Special.encodeBoxEnd(used_id) };
    try values.glyph_indeces.appendSlice(doc.allocator, &glyphs);
}

fn addLineBreak(doc: *Document, values: *InlineLevelUsedValues) !void {
    const glyphs = [2]GlyphIndex{ 0, InlineLevelUsedValues.Special.encodeLineBreak() };
    try values.glyph_indeces.appendSlice(doc.allocator, &glyphs);
}

fn addText(doc: *Document, values: *InlineLevelUsedValues, text: zss.value.Text, font: ValueTree.Font) !void {
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
                try endTextRun(doc, values, text, buffer, font.font, run_begin, run_end);
                try addLineBreak(doc, values);
                run_begin = run_end + 1;
            },
            '\r' => {
                try endTextRun(doc, values, text, buffer, font.font, run_begin, run_end);
                try addLineBreak(doc, values);
                run_end += @boolToInt(run_end + 1 < text.len and text[run_end + 1] == '\n');
                run_begin = run_end + 1;
            },
            '\t' => {
                try endTextRun(doc, values, text, buffer, font.font, run_begin, run_end);
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

    try endTextRun(doc, values, text, buffer, font.font, run_begin, run_end);
}

fn endTextRun(doc: *Document, values: *InlineLevelUsedValues, text: zss.value.Text, buffer: *hb.hb_buffer_t, font: *hb.hb_font_t, run_begin: usize, run_end: usize) !void {
    if (run_end > run_begin) {
        hb.hb_buffer_add_latin1(buffer, text.ptr, @intCast(c_int, text.len), @intCast(c_uint, run_begin), @intCast(c_int, run_end - run_begin));
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

    // Allocate twice as much so that special glyph indeces always have space
    try values.glyph_indeces.ensureUnusedCapacity(doc.allocator, 2 * glyph_infos.len);

    for (glyph_infos) |info| {
        const glyph_index: GlyphIndex = info.codepoint;
        values.glyph_indeces.appendAssumeCapacity(glyph_index);
        if (glyph_index == 0) {
            values.glyph_indeces.appendAssumeCapacity(InlineLevelUsedValues.Special.encodeZeroGlyphIndex());
        }
    }
}

fn inlineValuesFinishLayout(doc: *Document, context: *BlockLayoutContext, container: *InlineContainer, percentage_base_unit: ZssUnit) !void {
    const values = container.values;

    const num_glyphs = values.glyph_indeces.items.len;
    try values.metrics.resize(doc.allocator, num_glyphs);

    const num_boxes = container.used_id_to_element_index.len;
    try values.inline_start.resize(doc.allocator, num_boxes);
    try values.inline_end.resize(doc.allocator, num_boxes);
    try values.block_start.resize(doc.allocator, num_boxes);
    try values.block_end.resize(doc.allocator, num_boxes);
    try values.margins.resize(doc.allocator, num_boxes);
    try values.background1.resize(doc.allocator, num_boxes);

    values.font = context.inputs.font.font;
    values.font_color_rgba = colorProperty(context.inputs.font.color);

    // Set the used values for all inline elements
    assert(container.used_id_to_element_index[0] == reserved_box_id);
    setRootInlineBoxUsedData(values, 0);
    for (container.used_id_to_element_index[1..]) |box_id, used_id| {
        try setInlineBoxUsedData(context, values, box_id, @intCast(UsedId, used_id + 1), percentage_base_unit);
    }

    { // Set the metrics data for all glyphs
        var i: usize = 0;
        while (i < num_glyphs) : (i += 1) {
            const glyph_index = values.glyph_indeces.items[i];
            const metrics = &values.metrics.items[i];

            if (glyph_index == 0) {
                i += 1;
                const special = InlineLevelUsedValues.Special.decode(values.glyph_indeces.items[i]);
                const kind = @intToEnum(InlineLevelUsedValues.Special.LayoutInternalKind, @enumToInt(special.kind));
                switch (kind) {
                    .ZeroGlyphIndex => setMetricsGlyph(metrics, values.font, 0),
                    .BoxStart => {
                        const used_id = special.data;
                        setMetricsBoxStart(metrics, values, used_id);
                    },
                    .BoxEnd => {
                        const used_id = special.data;
                        setMetricsBoxEnd(metrics, values, used_id);
                    },
                    .InlineBlock => {
                        const used_id = special.data;
                        setMetricsInlineBlock(metrics, doc, used_id);
                    },
                    .LineBreak => setMetricsLineBreak(metrics),
                    .ContinuationBlock => @panic("TODO Continuation block metrics"),
                }
            } else {
                setMetricsGlyph(metrics, values.font, glyph_index);
            }
        }
    }
}

fn setRootInlineBoxUsedData(values: *InlineLevelUsedValues, used_id: UsedId) void {
    values.inline_start.items[used_id] = .{ .border = 0, .padding = 0, .border_color_rgba = 0 };
    values.inline_end.items[used_id] = .{ .border = 0, .padding = 0, .border_color_rgba = 0 };
    values.block_start.items[used_id] = .{ .border = 0, .padding = 0, .border_color_rgba = 0 };
    values.block_end.items[used_id] = .{ .border = 0, .padding = 0, .border_color_rgba = 0 };
    values.margins.items[used_id] = .{ .start = 0, .end = 0 };
    values.background1.items[used_id] = .{};
}

fn setInlineBoxUsedData(context: *BlockLayoutContext, values: *InlineLevelUsedValues, element: ElementIndex, used_id: UsedId, containing_block_logical_width: ZssUnit) !void {
    assert(containing_block_logical_width >= 0);
    // TODO: Also use the logical properties ('padding-inline-start', 'border-block-end', etc.).
    // TODO: Border/Background colors don't affect layout, solve for them later.
    const specified = .{
        .horizontal_sizes = context.inputs.getSpecifiedValue(.horizontal_sizes, element),
        .vertical_sizes = context.inputs.getSpecifiedValue(.vertical_sizes, element),
        .border_colors = context.inputs.getSpecifiedValue(.border_colors, element),
        .color = context.inputs.getSpecifiedValue(.color, element),
        .background1 = context.inputs.getSpecifiedValue(.background1, element),
    };

    const margin_inline_start = switch (specified.horizontal_sizes.margin_start) {
        .px => |value| length(.px, value),
        .percentage => |value| percentage(value, containing_block_logical_width),
        .auto => 0,
        .initial, .inherit, .unset => unreachable,
    };
    const border_inline_start = switch (specified.horizontal_sizes.border_start) {
        .px => |value| try positiveLength(.px, value),
        .thin => borderWidth(.thin),
        .medium => borderWidth(.medium),
        .thick => borderWidth(.thick),
        .initial, .inherit, .unset => unreachable,
    };
    const padding_inline_start = switch (specified.horizontal_sizes.padding_start) {
        .px => |value| try positiveLength(.px, value),
        .percentage => |value| try positivePercentage(value, containing_block_logical_width),
        .initial, .inherit, .unset => unreachable,
    };
    const margin_inline_end = switch (specified.horizontal_sizes.margin_end) {
        .px => |value| length(.px, value),
        .percentage => |value| percentage(value, containing_block_logical_width),
        .auto => 0,
        .initial, .inherit, .unset => unreachable,
    };
    const border_inline_end = switch (specified.horizontal_sizes.border_end) {
        .px => |value| try positiveLength(.px, value),
        .thin => borderWidth(.thin),
        .medium => borderWidth(.medium),
        .thick => borderWidth(.thick),
        .initial, .inherit, .unset => unreachable,
    };
    const padding_inline_end = switch (specified.horizontal_sizes.padding_end) {
        .px => |value| try positiveLength(.px, value),
        .percentage => |value| try positivePercentage(value, containing_block_logical_width),
        .initial, .inherit, .unset => unreachable,
    };

    const border_block_start = switch (specified.vertical_sizes.border_start) {
        .px => |value| try positiveLength(.px, value),
        .thin => borderWidth(.thin),
        .medium => borderWidth(.medium),
        .thick => borderWidth(.thick),
        .initial, .inherit, .unset => unreachable,
    };
    const padding_block_start = switch (specified.vertical_sizes.padding_start) {
        .px => |value| try positiveLength(.px, value),
        .percentage => |value| try positivePercentage(value, containing_block_logical_width),
        .initial, .inherit, .unset => unreachable,
    };
    const border_block_end = switch (specified.vertical_sizes.border_end) {
        .px => |value| try positiveLength(.px, value),
        .thin => borderWidth(.thin),
        .medium => borderWidth(.medium),
        .thick => borderWidth(.thick),
        .initial, .inherit, .unset => unreachable,
    };
    const padding_block_end = switch (specified.vertical_sizes.padding_end) {
        .px => |value| try positiveLength(.px, value),
        .percentage => |value| try positivePercentage(value, containing_block_logical_width),
        .initial, .inherit, .unset => unreachable,
    };

    const current_color = colorProperty(specified.color.color);
    const border_inline_start_color = color(specified.border_colors.left, current_color);
    const border_inline_end_color = color(specified.border_colors.right, current_color);
    const border_block_start_color = color(specified.border_colors.top, current_color);
    const border_block_end_color = color(specified.border_colors.bottom, current_color);

    values.inline_start.items[used_id] = .{ .border = border_inline_start, .padding = padding_inline_start, .border_color_rgba = border_inline_start_color };
    values.inline_end.items[used_id] = .{ .border = border_inline_end, .padding = padding_inline_end, .border_color_rgba = border_inline_end_color };
    values.block_start.items[used_id] = .{ .border = border_block_start, .padding = padding_block_start, .border_color_rgba = border_block_start_color };
    values.block_end.items[used_id] = .{ .border = border_block_end, .padding = padding_block_end, .border_color_rgba = border_block_end_color };
    values.margins.items[used_id] = .{ .start = margin_inline_start, .end = margin_inline_end };
    values.background1.items[used_id] = solveBackground1(specified.background1, current_color);
}

fn setMetricsGlyph(metrics: *InlineLevelUsedValues.Metrics, font: *hb.hb_font_t, glyph_index: GlyphIndex) void {
    var extents: hb.hb_glyph_extents_t = undefined;
    const extents_result = hb.hb_font_get_glyph_extents(font, glyph_index, &extents);
    if (extents_result == 0) {
        extents.width = 0;
        extents.x_bearing = 0;
    }
    metrics.* = .{
        .offset = @divFloor(extents.x_bearing * unitsPerPixel, 64),
        .advance = @divFloor(hb.hb_font_get_glyph_h_advance(font, glyph_index) * unitsPerPixel, 64),
        .width = @divFloor(extents.width * unitsPerPixel, 64),
    };
}

fn setMetricsBoxStart(metrics: *InlineLevelUsedValues.Metrics, values: *InlineLevelUsedValues, used_id: UsedId) void {
    const inline_start = values.inline_start.items[used_id];
    const margin = values.margins.items[used_id].start;
    const width = inline_start.border + inline_start.padding;
    const advance = width + margin;
    metrics.* = .{ .offset = margin, .advance = advance, .width = width };
}

fn setMetricsBoxEnd(metrics: *InlineLevelUsedValues.Metrics, values: *InlineLevelUsedValues, used_id: UsedId) void {
    const inline_end = values.inline_end.items[used_id];
    const margin = values.margins.items[used_id].end;
    const width = inline_end.border + inline_end.padding;
    const advance = width + margin;
    metrics.* = .{ .offset = 0, .advance = advance, .width = width };
}

fn setMetricsLineBreak(metrics: *InlineLevelUsedValues.Metrics) void {
    metrics.* = .{ .offset = 0, .advance = 0, .width = 0 };
}

fn setMetricsInlineBlock(metrics: *InlineLevelUsedValues.Metrics, doc: *Document, used_id: UsedId) void {
    const box_offsets = doc.blocks.box_offsets.items[used_id];
    const margins = doc.blocks.margins.items[used_id];

    const width = box_offsets.border_end.x - box_offsets.border_start.x;
    const advance = width + margins.inline_start + margins.inline_end;
    metrics.* = .{ .offset = margins.inline_start, .advance = advance, .width = width };
}

const InlineFormattingInfo = struct {
    logical_height: ZssUnit,
    longest_line_box_length: ZssUnit,
};

fn splitIntoLineBoxes(doc: *Document, values: *InlineLevelUsedValues, containing_block_logical_width: ZssUnit) !InlineFormattingInfo {
    assert(containing_block_logical_width >= 0);

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
    var result = InlineFormattingInfo{ .logical_height = undefined, .longest_line_box_length = 0 };

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
                    result.longest_line_box_length = std.math.max(result.longest_line_box_length, cursor);
                    try values.line_boxes.append(doc.allocator, line_box);
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
        try values.line_boxes.append(doc.allocator, line_box);
    }

    if (values.line_boxes.items.len > 0) {
        result.logical_height = values.line_boxes.items[values.line_boxes.items.len - 1].baseline + bottom_height;
    } else {
        // TODO This is never reached because the root inline box always creates at least 1 line box.
        result.logical_height = 0;
    }

    return result;
}

fn solveBorderColors(border_colors: ValueTree.BorderColors, current_color: u32) used_values.BorderColor {
    return used_values.BorderColor{
        .inline_start_rgba = color(border_colors.left, current_color),
        .inline_end_rgba = color(border_colors.right, current_color),
        .block_start_rgba = color(border_colors.top, current_color),
        .block_end_rgba = color(border_colors.bottom, current_color),
    };
}

fn solveBackground1(bg: ValueTree.Background1, current_color: u32) used_values.Background1 {
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
