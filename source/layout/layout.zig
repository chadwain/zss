const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const ArrayListAlignedUnmanaged = std.ArrayListAlignedUnmanaged;
const MultiArrayList = std.MultiArrayList;

const zss = @import("../../zss.zig");
const ElementTree = zss.ElementTree;
const ElementIndex = zss.ElementIndex;
const ElementRef = zss.ElementRef;
const root_element = @as(ElementIndex, 0);
const CascadedValueStore = zss.CascadedValueStore;
const StyleComputer = @import("./StyleComputer.zig");

const used_values = @import("./used_values.zig");
const ZssUnit = used_values.ZssUnit;
const ZssSize = used_values.ZssSize;
const ZssVector = used_values.ZssVector;
const units_per_pixel = used_values.units_per_pixel;
const BlockBoxIndex = used_values.BlockBoxIndex;
const initial_containing_block = @as(BlockBoxIndex, 0);
const BlockBoxSkip = used_values.BlockBoxSkip;
const BlockBoxCount = used_values.BlockBoxCount;
const BlockBoxTree = used_values.BlockBoxTree;
const StackingContextIndex = used_values.StackingContextIndex;
const ZIndex = used_values.ZIndex;
const InlineBoxIndex = used_values.InlineBoxIndex;
const InlineFormattingContext = used_values.InlineFormattingContext;
const InlineFormattingContextIndex = used_values.InlineFormattingContextIndex;
const GlyphIndex = InlineFormattingContext.GlyphIndex;
const GeneratedBox = used_values.GeneratedBox;
const BoxTree = used_values.BoxTree;

const hb = @import("harfbuzz");

pub const Error = error{
    InvalidValue,
    OutOfMemory,
    TooManyBlocks,
    TooManyIfcs,
};

pub const ViewportSize = struct {
    width: u32,
    height: u32,
};

pub fn doLayout(
    element_tree: ElementTree,
    cascaded_value_tree: CascadedValueStore,
    allocator: Allocator,
    /// The size of the viewport in pixels.
    viewport_size: ViewportSize,
) Error!BoxTree {
    var computer = StyleComputer{
        .element_tree_skips = element_tree.tree.list.items(.__skip),
        .element_tree_refs = element_tree.tree.list.items(.__ref),
        .cascaded_values = &cascaded_value_tree,
        .viewport_size = viewport_size,
        .stage = undefined,
        .allocator = allocator,
    };
    defer computer.deinit();

    var sc = StackingContexts{ .allocator = allocator };
    defer sc.deinit();

    var layout = BlockLayoutContext{ .allocator = allocator };
    defer layout.deinit();

    const element_index_to_generated_box = try allocator.alloc(GeneratedBox, element_tree.size());
    var box_tree = BoxTree{
        .allocator = allocator,
        .element_index_to_generated_box = element_index_to_generated_box,
    };
    errdefer box_tree.deinit();

    {
        computer.stage = .{ .box_gen = .{} };
        defer computer.deinitStage(.box_gen);

        try doBoxGeneration(&layout, &sc, &computer, &box_tree);
        computer.assertEmptyStage(.box_gen);
    }

    {
        computer.stage = .{ .cosmetic = .{} };
        defer computer.deinitStage(.cosmetic);

        try doCosmeticLayout(&layout, &computer, &box_tree);
        computer.assertEmptyStage(.cosmetic);
    }

    return box_tree;
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

pub fn borderWidth(comptime thickness: BorderThickness) f32 {
    return switch (thickness) {
        // TODO: Let these values be user-customizable.
        .thin => 1,
        .medium => 3,
        .thick => 5,
    };
}

pub fn borderWidthMultiplier(border_styles: zss.values.BorderStyle) f32 {
    return switch (border_styles) {
        .none, .hidden => 0,
        .initial, .inherit, .unset, .undeclared => unreachable,
        else => 1,
    };
}

fn color(col: zss.values.Color, current_color: used_values.Color) used_values.Color {
    return switch (col) {
        .rgba => |rgba| rgba,
        .current_color => current_color,
        .initial, .inherit, .unset, .undeclared => unreachable,
    };
}

fn getCurrentColor(col: zss.values.Color) used_values.Color {
    return switch (col) {
        .rgba => |rgba| rgba,
        .current_color => unreachable,
        .initial, .inherit, .unset, .undeclared => unreachable,
    };
}

const LayoutMode = enum {
    InitialContainingBlock,
    Flow,
    ContainingBlock,
};

const IsRoot = enum { Root, NonRoot };

const UsedContentHeight = struct {
    height: ?ZssUnit,
    min_height: ZssUnit,
    max_height: ZssUnit,
};

const BlockLayoutContext = struct {
    allocator: Allocator,

    processed_root_element: bool = false,
    anonymous_block_boxes: ArrayListUnmanaged(BlockBoxIndex) = .{},
    layout_mode: ArrayListUnmanaged(LayoutMode) = .{},

    index: ArrayListUnmanaged(BlockBoxIndex) = .{},
    skip: ArrayListUnmanaged(BlockBoxSkip) = .{},

    width: ArrayListUnmanaged(ZssUnit) = .{},
    auto_height: ArrayListUnmanaged(ZssUnit) = .{},
    heights: ArrayListUnmanaged(UsedContentHeight) = .{},

    fn deinit(self: *BlockLayoutContext) void {
        self.anonymous_block_boxes.deinit(self.allocator);
        self.layout_mode.deinit(self.allocator);

        self.index.deinit(self.allocator);
        self.skip.deinit(self.allocator);

        self.width.deinit(self.allocator);
        self.auto_height.deinit(self.allocator);
        self.heights.deinit(self.allocator);
    }
};

fn doBoxGeneration(layout: *BlockLayoutContext, sc: *StackingContexts, computer: *StyleComputer, box_tree: *BoxTree) !void {
    if (computer.element_tree_skips.len > 0) {
        box_tree.blocks.ensureTotalCapacity(box_tree.allocator, computer.element_tree_skips[root_element] + 1) catch {};
    }

    try makeInitialContainingBlock(layout, computer, box_tree);
    if (layout.layout_mode.items.len == 0) return;

    try runFully(layout, sc, computer, box_tree);
}

fn doCosmeticLayout(layout: *BlockLayoutContext, computer: *StyleComputer, box_tree: *BoxTree) !void {
    const num_created_boxes = box_tree.blocks.skips.items[0];
    try box_tree.blocks.border_colors.resize(box_tree.allocator, num_created_boxes);
    try box_tree.blocks.background1.resize(box_tree.allocator, num_created_boxes);
    try box_tree.blocks.background2.resize(box_tree.allocator, num_created_boxes);

    for (box_tree.ifcs.items) |ifc| {
        try ifc.background1.resize(box_tree.allocator, ifc.inline_start.items.len);
        inlineRootBoxSolveOtherProperties(ifc);
    }

    // TODO: Don't make another interval stack
    var interval_stack = ArrayListUnmanaged(StyleComputer.Interval){};
    defer interval_stack.deinit(computer.allocator);
    if (computer.element_tree_skips.len > 0) {
        try interval_stack.append(computer.allocator, .{ .begin = root_element, .end = root_element + computer.element_tree_skips[root_element] });
    }

    while (interval_stack.items.len > 0) {
        const interval = &interval_stack.items[interval_stack.items.len - 1];

        if (interval.begin != interval.end) {
            const element = interval.begin;
            const skip = computer.element_tree_skips[element];
            interval.begin += skip;

            computer.setElementDirectChild(.cosmetic, element);
            const box_type = box_tree.element_index_to_generated_box[element];
            switch (box_type) {
                .none, .text => continue,
                .block_box => |index| try blockBoxSolveOtherProperties(computer, box_tree, index),
                .inline_box => |box_spec| {
                    const ifc = box_tree.ifcs.items[box_spec.ifc_index];
                    inlineBoxSolveOtherProperties(computer, ifc, box_spec.index);
                },
            }

            // TODO: Temporary jank to set the text color.
            if (element == root_element) {
                const computed_color = computer.stage.cosmetic.current_values.color;
                const used_color = getCurrentColor(computed_color.color);
                for (box_tree.ifcs.items) |ifc| {
                    ifc.font_color_rgba = used_color;
                }
            }

            if (skip != 1) {
                try interval_stack.append(computer.allocator, .{ .begin = element + 1, .end = element + skip });
                try computer.pushElement(.cosmetic);
            }
        } else {
            if (interval_stack.items.len > 1) {
                computer.popElement(.cosmetic);
            }
            _ = interval_stack.pop();
        }
    }

    blockBoxFillOtherPropertiesWithDefaults(box_tree, initial_containing_block);
    for (layout.anonymous_block_boxes.items) |anon_index| {
        blockBoxFillOtherPropertiesWithDefaults(box_tree, anon_index);
    }
}

fn runFully(layout: *BlockLayoutContext, sc: *StackingContexts, computer: *StyleComputer, box_tree: *BoxTree) !void {
    assert(layout.layout_mode.items.len > 0);
    while (layout.layout_mode.items.len > 0) {
        try runOnce(layout, sc, computer, box_tree);
    }
}

fn runOnce(layout: *BlockLayoutContext, sc: *StackingContexts, computer: *StyleComputer, box_tree: *BoxTree) !void {
    const layout_mode = layout.layout_mode.items[layout.layout_mode.items.len - 1];
    switch (layout_mode) {
        .InitialContainingBlock => {
            if (!layout.processed_root_element) {
                layout.processed_root_element = true;

                const element = root_element;
                const skip = computer.element_tree_skips[element];
                computer.setElementDirectChild(.box_gen, element);

                const font = computer.getSpecifiedValue(.box_gen, .font);
                computer.setComputedValue(.box_gen, .font, font);
                computer.root_font.font = switch (font.font) {
                    .font => |f| f,
                    .zss_default => hb.hb_font_get_empty().?, // TODO: Provide a text-rendering-backend-specific default font.
                    .initial, .inherit, .unset, .undeclared => unreachable,
                };

                const specified = .{
                    .box_style = computer.getSpecifiedValue(.box_gen, .box_style),
                };
                const computed = .{
                    .box_style = solveBoxStyle(specified.box_style, .Root),
                };
                computer.setComputedValue(.box_gen, .box_style, computed.box_style);

                const containing_block_width = layout.width.items[layout.width.items.len - 1];
                const containing_block_height = layout.heights.items[layout.heights.items.len - 1].height;

                switch (computed.box_style.display) {
                    .block => {
                        const box = try makeFlowBlock(layout, computer, box_tree, containing_block_width, containing_block_height);
                        box_tree.element_index_to_generated_box[element] = box;

                        const z_index = computer.getSpecifiedValue(.box_gen, .z_index); // TODO: Useless info
                        computer.setComputedValue(.box_gen, .z_index, z_index);
                        const stacking_context_type = StackingContexts.Data{ .is_parent = try StackingContexts.createRootStackingContext(box_tree, box.block_box, 0) };
                        try sc.pushStackingContext(stacking_context_type);

                        try computer.pushElement(.box_gen);
                    },
                    .none => std.mem.set(GeneratedBox, box_tree.element_index_to_generated_box[element .. element + skip], .none),
                    .inline_, .inline_block, .text => unreachable,
                    .initial, .inherit, .unset, .undeclared => unreachable,
                }
            } else {
                popInitialContainingBlock(layout, box_tree);
            }
        },
        .Flow => {
            const interval = &computer.intervals.items[computer.intervals.items.len - 1];
            if (interval.begin != interval.end) {
                const element = interval.begin;
                const skip = computer.element_tree_skips[element];
                computer.setElementDirectChild(.box_gen, element);

                const font = computer.getSpecifiedValue(.box_gen, .font);
                computer.setComputedValue(.box_gen, .font, font);

                const specified = .{
                    .box_style = computer.getSpecifiedValue(.box_gen, .box_style),
                };
                const computed = .{
                    .box_style = solveBoxStyle(specified.box_style, .NonRoot),
                };
                computer.setComputedValue(.box_gen, .box_style, computed.box_style);

                const containing_block_width = layout.width.items[layout.width.items.len - 1];
                const containing_block_height = layout.heights.items[layout.heights.items.len - 1].height;

                switch (computed.box_style.display) {
                    .block => {
                        const box = try makeFlowBlock(layout, computer, box_tree, containing_block_width, containing_block_height);
                        box_tree.element_index_to_generated_box[element] = box;

                        const specified_z_index = computer.getSpecifiedValue(.box_gen, .z_index);
                        computer.setComputedValue(.box_gen, .z_index, specified_z_index);
                        const stacking_context_type: StackingContexts.Data = switch (computed.box_style.position) {
                            .static => .none,
                            // TODO: Position the block using the values of the 'inset' family of properties.
                            .relative => switch (specified_z_index.z_index) {
                                .integer => |z_index| StackingContexts.Data{ .is_parent = try sc.createStackingContext(box_tree, box.block_box, z_index) },
                                .auto => StackingContexts.Data{ .is_non_parent = try sc.createStackingContext(box_tree, box.block_box, 0) },
                                .initial, .inherit, .unset, .undeclared => unreachable,
                            },
                            .absolute => @panic("TODO: absolute positioning"),
                            .fixed => @panic("TODO: fixed positioning"),
                            .sticky => @panic("TODO: sticky positioning"),
                            .initial, .inherit, .unset, .undeclared => unreachable,
                        };
                        try sc.pushStackingContext(stacking_context_type);

                        interval.begin += skip;
                        try computer.pushElement(.box_gen);
                    },
                    .inline_, .inline_block, .text => {
                        const result = try makeInlineFormattingContext(layout.allocator, sc, computer, box_tree, .Normal, containing_block_width, containing_block_height);

                        layout.skip.items[layout.skip.items.len - 1] += result.total_inline_block_skip;

                        const ifc = box_tree.ifcs.items[result.ifc_index];
                        const parent_auto_height = &layout.auto_height.items[layout.auto_height.items.len - 1];
                        ifc.parent_block = layout.index.items[layout.index.items.len - 1];
                        ifc.origin = ZssVector{ .x = 0, .y = parent_auto_height.* };
                        const line_split_result = try splitIntoLineBoxes(layout.allocator, box_tree, ifc, containing_block_width);
                        advanceFlow(parent_auto_height, line_split_result.height);
                    },
                    .none => {
                        std.mem.set(GeneratedBox, box_tree.element_index_to_generated_box[element .. element + skip], .none);
                        interval.begin += skip;
                    },
                    .initial, .inherit, .unset, .undeclared => unreachable,
                }
            } else {
                popFlowBlock(layout, box_tree);
                sc.popStackingContext();
                computer.popElement(.box_gen);
            }
        },
        .ContainingBlock => popContainingBlock(layout),
    }
}

fn makeInitialContainingBlock(layout: *BlockLayoutContext, computer: *StyleComputer, box_tree: *BoxTree) !void {
    const width = @intCast(ZssUnit, computer.viewport_size.width * units_per_pixel);
    const height = @intCast(ZssUnit, computer.viewport_size.height * units_per_pixel);

    const block = try createBlock(box_tree);
    assert(block.index == initial_containing_block);
    block.skip.* = undefined;
    block.properties.* = .{};
    block.box_offsets.* = .{
        .border_pos = .{ .x = 0, .y = 0 },
        .content_pos = .{ .x = 0, .y = 0 },
        .content_size = .{ .w = width, .h = height },
        .border_size = .{ .w = width, .h = height },
    };
    block.borders.* = .{};
    block.margins.* = .{};

    if (computer.element_tree_skips.len == 0) {
        block.skip.* = 1;
        return;
    }

    try layout.layout_mode.append(layout.allocator, .InitialContainingBlock);
    try layout.index.append(layout.allocator, block.index);
    try layout.skip.append(layout.allocator, 1);
    try layout.width.append(layout.allocator, width);
    try layout.heights.append(layout.allocator, UsedContentHeight{
        .height = height,
        .min_height = height,
        .max_height = height,
    });
}

fn popInitialContainingBlock(layout: *BlockLayoutContext, box_tree: *BoxTree) void {
    assert(layout.layout_mode.pop() == .InitialContainingBlock);
    assert(layout.index.pop() == initial_containing_block);
    const skip = layout.skip.pop();
    _ = layout.width.pop();
    _ = layout.heights.pop();

    box_tree.blocks.skips.items[initial_containing_block] = skip;
}

fn pushContainingBlock(layout: *BlockLayoutContext, width: ZssUnit, height: ?ZssUnit) !void {
    try layout.layout_mode.append(layout.allocator, .ContainingBlock);
    try layout.width.append(layout.allocator, width);
    try layout.heights.append(layout.allocator, .{
        .height = height,
        .min_height = undefined,
        .max_height = undefined,
    });
}

fn popContainingBlock(layout: *BlockLayoutContext) void {
    assert(layout.layout_mode.pop() == .ContainingBlock);
    _ = layout.width.pop();
    _ = layout.heights.pop();
}

fn makeFlowBlock(
    layout: *BlockLayoutContext,
    computer: *StyleComputer,
    box_tree: *BoxTree,
    containing_block_width: ZssUnit,
    containing_block_height: ?ZssUnit,
) !GeneratedBox {
    const block = try createBlock(box_tree);
    block.skip.* = undefined;
    block.properties.* = .{};

    const border_styles = computer.getSpecifiedValue(.box_gen, .border_styles);
    const specified_sizes = FlowBlockComputedSizes{
        .content_width = computer.getSpecifiedValue(.box_gen, .content_width),
        .horizontal_edges = computer.getSpecifiedValue(.box_gen, .horizontal_edges),
        .content_height = computer.getSpecifiedValue(.box_gen, .content_height),
        .vertical_edges = computer.getSpecifiedValue(.box_gen, .vertical_edges),
    };
    var computed_sizes: FlowBlockComputedSizes = undefined;
    var used_sizes: FlowBlockUsedSizes = undefined;
    try flowBlockSolveWidths(specified_sizes, containing_block_width, border_styles, &computed_sizes, &used_sizes);
    try flowBlockSolveContentHeight(specified_sizes.content_height, containing_block_height, &computed_sizes.content_height, &used_sizes);
    try flowBlockSolveVerticalEdges(specified_sizes.vertical_edges, containing_block_width, border_styles, &computed_sizes.vertical_edges, &used_sizes);
    flowBlockAdjustWidthAndMargins(&used_sizes, containing_block_width);
    flowBlockSetData(used_sizes, block.box_offsets, block.borders, block.margins);

    computer.setComputedValue(.box_gen, .content_width, computed_sizes.content_width);
    computer.setComputedValue(.box_gen, .horizontal_edges, computed_sizes.horizontal_edges);
    computer.setComputedValue(.box_gen, .content_height, computed_sizes.content_height);
    computer.setComputedValue(.box_gen, .vertical_edges, computed_sizes.vertical_edges);
    computer.setComputedValue(.box_gen, .border_styles, border_styles);

    try pushFlowBlock(layout, block.index, used_sizes);
    return GeneratedBox{ .block_box = block.index };
}

fn pushFlowBlock(
    layout: *BlockLayoutContext,
    block_box_index: BlockBoxIndex,
    used_sizes: FlowBlockUsedSizes,
) !void {
    // The allocations here must have corresponding deallocations in popFlowBlock.
    try layout.layout_mode.append(layout.allocator, .Flow);
    try layout.index.append(layout.allocator, block_box_index);
    try layout.skip.append(layout.allocator, 1);
    try layout.width.append(layout.allocator, used_sizes.get(.inline_size).?);
    try layout.auto_height.append(layout.allocator, 0);
    try layout.heights.append(layout.allocator, used_sizes.getUsedContentHeight());
}

fn popFlowBlock(layout: *BlockLayoutContext, box_tree: *BoxTree) void {
    // The deallocations here must correspond to allocations in pushFlowBlock.
    assert(layout.layout_mode.pop() == .Flow);
    const block_box_index = layout.index.pop();
    const skip = layout.skip.pop();
    const width = layout.width.pop();
    const auto_height = layout.auto_height.pop();
    const heights = layout.heights.pop();

    box_tree.blocks.skips.items[block_box_index] = skip;
    const box_offsets = &box_tree.blocks.box_offsets.items[block_box_index];
    assert(box_offsets.content_size.w == width);
    flowBlockFinishLayout(box_offsets, heights, auto_height);

    const parent_layout_mode = layout.layout_mode.items[layout.layout_mode.items.len - 1];
    switch (parent_layout_mode) {
        .InitialContainingBlock => layout.skip.items[layout.skip.items.len - 1] += skip,
        .Flow => {
            layout.skip.items[layout.skip.items.len - 1] += skip;
            const parent_auto_height = &layout.auto_height.items[layout.auto_height.items.len - 1];
            const margin_bottom = box_tree.blocks.margins.items[block_box_index].bottom;
            addBlockToFlow(box_offsets, margin_bottom, parent_auto_height);
        },
        .ContainingBlock => {},
    }
}

const FlowBlockComputedSizes = struct {
    content_width: zss.properties.ContentSize,
    horizontal_edges: zss.properties.BoxEdges,
    content_height: zss.properties.ContentSize,
    vertical_edges: zss.properties.BoxEdges,
};

// TODO: Move this to used_values.zig
const FlowBlockUsedSizes = struct {
    border_inline_start: ZssUnit,
    border_inline_end: ZssUnit,
    padding_inline_start: ZssUnit,
    padding_inline_end: ZssUnit,
    margin_inline_start_untagged: ZssUnit,
    margin_inline_end_untagged: ZssUnit,
    inline_size_untagged: ZssUnit,
    min_inline_size: ZssUnit,
    max_inline_size: ZssUnit,

    border_block_start: ZssUnit,
    border_block_end: ZssUnit,
    padding_block_start: ZssUnit,
    padding_block_end: ZssUnit,
    margin_block_start: ZssUnit,
    margin_block_end: ZssUnit,
    block_size_untagged: ZssUnit,
    min_block_size: ZssUnit,
    max_block_size: ZssUnit,

    auto_bitfield: u4,

    const Bit = enum(u4) {
        inline_size = 1,
        margin_inline_start = 2,
        margin_inline_end = 4,
        block_size = 8,
    };

    fn set(self: *FlowBlockUsedSizes, comptime bit: Bit, value: ?ZssUnit) void {
        const clamped_value = clamped_value: {
            if (value) |v| {
                self.auto_bitfield &= (~@enumToInt(bit));
                break :clamped_value switch (bit) {
                    .inline_size => clampSize(v, self.min_inline_size, self.max_inline_size),
                    .margin_inline_start, .margin_inline_end => v,
                    .block_size => clampSize(v, self.min_block_size, self.max_block_size),
                };
            } else {
                self.auto_bitfield |= @enumToInt(bit);
                break :clamped_value 0;
            }
        };

        @field(self, @tagName(bit) ++ "_untagged") = clamped_value;
    }

    fn get(self: FlowBlockUsedSizes, comptime bit: Bit) ?ZssUnit {
        return if (self.isAutoBitSet(bit)) null else @field(self, @tagName(bit) ++ "_untagged");
    }

    fn inlineSizeAndMarginsAreNotAuto(self: FlowBlockUsedSizes) bool {
        const mask = @enumToInt(Bit.inline_size) | @enumToInt(Bit.margin_inline_start) | @enumToInt(Bit.margin_inline_end);
        return self.auto_bitfield & mask == 0;
    }

    fn isAutoBitSet(self: FlowBlockUsedSizes, comptime bit: Bit) bool {
        return self.auto_bitfield & @enumToInt(bit) != 0;
    }

    fn getUsedContentHeight(self: FlowBlockUsedSizes) UsedContentHeight {
        return UsedContentHeight{
            .height = self.get(.block_size),
            .min_height = self.min_block_size,
            .max_height = self.max_block_size,
        };
    }
};

/// This is an implementation of CSS2§10.2, CSS2§10.3.3, and CSS2§10.4.
fn flowBlockSolveWidths(
    specified: FlowBlockComputedSizes,
    containing_block_width: ZssUnit,
    border_styles: zss.properties.BorderStyles,
    computed: *FlowBlockComputedSizes,
    used: *FlowBlockUsedSizes,
) !void {
    // TODO: Also use the logical properties ('inline-size', 'border-inline-start', etc.) to determine lengths.

    assert(containing_block_width >= 0);

    {
        const multiplier = borderWidthMultiplier(border_styles.left);
        switch (specified.horizontal_edges.border_start) {
            .px => |value| {
                const width = value * multiplier;
                computed.horizontal_edges.border_start = .{ .px = width };
                used.border_inline_start = try positiveLength(.px, width);
            },
            .thin => {
                const width = borderWidth(.thin) * multiplier;
                computed.horizontal_edges.border_start = .{ .px = width };
                used.border_inline_start = positiveLength(.px, width) catch unreachable;
            },
            .medium => {
                const width = borderWidth(.medium) * multiplier;
                computed.horizontal_edges.border_start = .{ .px = width };
                used.border_inline_start = positiveLength(.px, width) catch unreachable;
            },
            .thick => {
                const width = borderWidth(.thick) * multiplier;
                computed.horizontal_edges.border_start = .{ .px = width };
                used.border_inline_start = positiveLength(.px, width) catch unreachable;
            },
            .initial, .inherit, .unset, .undeclared => unreachable,
        }
    }
    {
        const multiplier = borderWidthMultiplier(border_styles.right);
        switch (specified.horizontal_edges.border_end) {
            .px => |value| {
                const width = value * multiplier;
                computed.horizontal_edges.border_end = .{ .px = width };
                used.border_inline_end = try positiveLength(.px, width);
            },
            .thin => {
                const width = borderWidth(.thin) * multiplier;
                computed.horizontal_edges.border_end = .{ .px = width };
                used.border_inline_end = positiveLength(.px, width) catch unreachable;
            },
            .medium => {
                const width = borderWidth(.medium) * multiplier;
                computed.horizontal_edges.border_end = .{ .px = width };
                used.border_inline_end = positiveLength(.px, width) catch unreachable;
            },
            .thick => {
                const width = borderWidth(.thick) * multiplier;
                computed.horizontal_edges.border_end = .{ .px = width };
                used.border_inline_end = positiveLength(.px, width) catch unreachable;
            },
            .initial, .inherit, .unset, .undeclared => unreachable,
        }
    }
    switch (specified.horizontal_edges.padding_start) {
        .px => |value| {
            computed.horizontal_edges.padding_start = .{ .px = value };
            used.padding_inline_start = try positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.horizontal_edges.padding_start = .{ .percentage = value };
            used.padding_inline_start = try positivePercentage(value, containing_block_width);
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
    switch (specified.horizontal_edges.padding_end) {
        .px => |value| {
            computed.horizontal_edges.padding_end = .{ .px = value };
            used.padding_inline_end = try positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.horizontal_edges.padding_end = .{ .percentage = value };
            used.padding_inline_end = try positivePercentage(value, containing_block_width);
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }

    switch (specified.content_width.min_size) {
        .px => |value| {
            computed.content_width.min_size = .{ .px = value };
            used.min_inline_size = try positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.content_width.min_size = .{ .percentage = value };
            used.min_inline_size = try positivePercentage(value, containing_block_width);
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
    switch (specified.content_width.max_size) {
        .px => |value| {
            computed.content_width.max_size = .{ .px = value };
            used.max_inline_size = try positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.content_width.max_size = .{ .percentage = value };
            used.max_inline_size = try positivePercentage(value, containing_block_width);
        },
        .none => {
            computed.content_width.max_size = .none;
            used.max_inline_size = std.math.maxInt(ZssUnit);
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }

    switch (specified.content_width.size) {
        .px => |value| {
            computed.content_width.size = .{ .px = value };
            used.set(.inline_size, try positiveLength(.px, value));
        },
        .percentage => |value| {
            computed.content_width.size = .{ .percentage = value };
            used.set(.inline_size, try positivePercentage(value, containing_block_width));
        },
        .auto => {
            computed.content_width.size = .auto;
            used.set(.inline_size, null);
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
    switch (specified.horizontal_edges.margin_start) {
        .px => |value| {
            computed.horizontal_edges.margin_start = .{ .px = value };
            used.set(.margin_inline_start, length(.px, value));
        },
        .percentage => |value| {
            computed.horizontal_edges.margin_start = .{ .percentage = value };
            used.set(.margin_inline_start, percentage(value, containing_block_width));
        },
        .auto => {
            computed.horizontal_edges.margin_start = .auto;
            used.set(.margin_inline_start, null);
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
    switch (specified.horizontal_edges.margin_end) {
        .px => |value| {
            computed.horizontal_edges.margin_end = .{ .px = value };
            used.set(.margin_inline_end, length(.px, value));
        },
        .percentage => |value| {
            computed.horizontal_edges.margin_end = .{ .percentage = value };
            used.set(.margin_inline_end, percentage(value, containing_block_width));
        },
        .auto => {
            computed.horizontal_edges.margin_end = .auto;
            used.set(.margin_inline_end, null);
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
}

fn flowBlockSolveContentHeight(
    specified: zss.properties.ContentSize,
    containing_block_height: ?ZssUnit,
    computed: *zss.properties.ContentSize,
    used: *FlowBlockUsedSizes,
) !void {
    if (containing_block_height) |h| assert(h >= 0);

    switch (specified.min_size) {
        .px => |value| {
            computed.min_size = .{ .px = value };
            used.min_block_size = try positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.min_size = .{ .percentage = value };
            used.min_block_size = if (containing_block_height) |s|
                try positivePercentage(value, s)
            else
                0;
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
    switch (specified.max_size) {
        .px => |value| {
            computed.max_size = .{ .px = value };
            used.max_block_size = try positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.max_size = .{ .percentage = value };
            used.max_block_size = if (containing_block_height) |s|
                try positivePercentage(value, s)
            else
                std.math.maxInt(ZssUnit);
        },
        .none => {
            computed.max_size = .none;
            used.max_block_size = std.math.maxInt(ZssUnit);
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
    switch (specified.size) {
        .px => |value| {
            computed.size = .{ .px = value };
            used.set(.block_size, try positiveLength(.px, value));
        },
        .percentage => |value| {
            computed.size = .{ .percentage = value };
            used.set(.block_size, if (containing_block_height) |h|
                try positivePercentage(value, h)
            else
                null);
        },
        .auto => {
            computed.size = .auto;
            used.set(.block_size, null);
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
}

/// This is an implementation of CSS2§10.5 and CSS2§10.6.3.
fn flowBlockSolveVerticalEdges(
    specified: zss.properties.BoxEdges,
    containing_block_width: ZssUnit,
    border_styles: zss.properties.BorderStyles,
    computed: *zss.properties.BoxEdges,
    used: *FlowBlockUsedSizes,
) !void {
    // TODO: Also use the logical properties ('block-size', 'border-block-start', etc.) to determine lengths.

    assert(containing_block_width >= 0);

    {
        const multiplier = borderWidthMultiplier(border_styles.top);
        switch (specified.border_start) {
            .px => |value| {
                const width = value * multiplier;
                computed.border_start = .{ .px = width };
                used.border_block_start = try positiveLength(.px, width);
            },
            .thin => {
                const width = borderWidth(.thin) * multiplier;
                computed.border_start = .{ .px = width };
                used.border_block_start = positiveLength(.px, width) catch unreachable;
            },
            .medium => {
                const width = borderWidth(.medium) * multiplier;
                computed.border_start = .{ .px = width };
                used.border_block_start = positiveLength(.px, width) catch unreachable;
            },
            .thick => {
                const width = borderWidth(.thick) * multiplier;
                computed.border_start = .{ .px = width };
                used.border_block_start = positiveLength(.px, width) catch unreachable;
            },
            .initial, .inherit, .unset, .undeclared => unreachable,
        }
    }
    {
        const multiplier = borderWidthMultiplier(border_styles.bottom);
        switch (specified.border_end) {
            .px => |value| {
                const width = value * multiplier;
                computed.border_end = .{ .px = width };
                used.border_block_end = try positiveLength(.px, width);
            },
            .thin => {
                const width = borderWidth(.thin) * multiplier;
                computed.border_end = .{ .px = width };
                used.border_block_end = positiveLength(.px, width) catch unreachable;
            },
            .medium => {
                const width = borderWidth(.medium) * multiplier;
                computed.border_end = .{ .px = width };
                used.border_block_end = positiveLength(.px, width) catch unreachable;
            },
            .thick => {
                const width = borderWidth(.thick) * multiplier;
                computed.border_end = .{ .px = width };
                used.border_block_end = positiveLength(.px, width) catch unreachable;
            },
            .initial, .inherit, .unset, .undeclared => unreachable,
        }
    }
    switch (specified.padding_start) {
        .px => |value| {
            computed.padding_start = .{ .px = value };
            used.padding_block_start = try positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.padding_start = .{ .percentage = value };
            used.padding_block_start = try positivePercentage(value, containing_block_width);
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
    switch (specified.padding_end) {
        .px => |value| {
            computed.padding_end = .{ .px = value };
            used.padding_block_end = try positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.padding_end = .{ .percentage = value };
            used.padding_block_end = try positivePercentage(value, containing_block_width);
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
    switch (specified.margin_start) {
        .px => |value| {
            computed.margin_start = .{ .px = value };
            used.margin_block_start = length(.px, value);
        },
        .percentage => |value| {
            computed.margin_start = .{ .percentage = value };
            used.margin_block_start = percentage(value, containing_block_width);
        },
        .auto => {
            computed.margin_start = .auto;
            used.margin_block_start = 0;
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
    switch (specified.margin_end) {
        .px => |value| {
            computed.margin_end = .{ .px = value };
            used.margin_block_end = length(.px, value);
        },
        .percentage => |value| {
            computed.margin_end = .{ .percentage = value };
            used.margin_block_end = percentage(value, containing_block_width);
        },
        .auto => {
            computed.margin_end = .auto;
            used.margin_block_end = 0;
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
}

/// This implements the constraints described in CSS2.2§10.3.3.
fn flowBlockAdjustWidthAndMargins(used: *FlowBlockUsedSizes, containing_block_width: ZssUnit) void {
    const content_margin_space = containing_block_width -
        (used.border_inline_start + used.border_inline_end + used.padding_inline_start + used.padding_inline_end);
    if (used.inlineSizeAndMarginsAreNotAuto()) {
        // None of the values were auto, so one of the margins must be set according to the other values.
        // TODO the margin that gets set is determined by the 'direction' property
        used.set(.margin_inline_end, content_margin_space - used.inline_size_untagged - used.margin_inline_start_untagged);
    } else if (!used.isAutoBitSet(.inline_size)) {
        // 'inline-size' is not auto, but at least one of 'margin-inline-start' and 'margin-inline-end' is.
        // If there is only one "auto", then that value gets the remaining margin space.
        // Else, there are 2 "auto"s, and both values get half the remaining margin space.
        const start = used.isAutoBitSet(.margin_inline_start);
        const end = used.isAutoBitSet(.margin_inline_end);
        const shr_amount = @boolToInt(start and end);
        const leftover_margin = std.math.max(0, content_margin_space -
            (used.inline_size_untagged + used.margin_inline_start_untagged + used.margin_inline_end_untagged));
        // TODO the margin that gets the extra 1 unit shall be determined by the 'direction' property
        if (start) used.set(.margin_inline_start, leftover_margin >> shr_amount);
        if (end) used.set(.margin_inline_end, (leftover_margin >> shr_amount) + @mod(leftover_margin, 2));
    } else {
        // 'inline-size' is auto, so it is set according to the other values.
        // The margin values don't need to change.
        used.set(.inline_size, content_margin_space - used.margin_inline_start_untagged - used.margin_inline_end_untagged);
    }
}

fn flowBlockSetData(
    used: FlowBlockUsedSizes,
    box_offsets: *used_values.BoxOffsets,
    borders: *used_values.Borders,
    margins: *used_values.Margins,
) void {
    // horizontal
    box_offsets.border_pos.x = used.get(.margin_inline_start).?;
    box_offsets.content_pos.x = used.border_inline_start + used.padding_inline_start;
    box_offsets.content_size.w = used.get(.inline_size).?;
    box_offsets.border_size.w = box_offsets.content_pos.x + box_offsets.content_size.w + used.padding_inline_end + used.border_inline_end;

    borders.left = used.border_inline_start;
    borders.right = used.border_inline_end;

    margins.left = used.get(.margin_inline_start).?;
    margins.right = used.get(.margin_inline_end).?;

    // vertical
    box_offsets.border_pos.y = used.margin_block_start;
    box_offsets.content_pos.y = used.border_block_start + used.padding_block_start;
    box_offsets.border_size.h = box_offsets.content_pos.y + used.padding_block_end + used.border_block_end;

    borders.top = used.border_block_start;
    borders.bottom = used.border_block_end;

    margins.top = used.margin_block_start;
    margins.bottom = used.margin_block_end;
}

fn flowBlockSetData2(used_height: ZssUnit, box_offsets: *used_values.BoxOffsets) void {
    box_offsets.content_size.h = used_height;
    box_offsets.border_size.h += used_height;
}

fn flowBlockFinishLayout(box_offsets: *used_values.BoxOffsets, heights: UsedContentHeight, auto_height: ZssUnit) void {
    const used_height = heights.height orelse clampSize(auto_height, heights.min_height, heights.max_height);
    flowBlockSetData2(used_height, box_offsets);
}

fn addBlockToFlow(box_offsets: *used_values.BoxOffsets, margin_bottom: ZssUnit, parent_auto_height: *ZssUnit) void {
    const margin_top = box_offsets.border_pos.y;
    box_offsets.border_pos.y += parent_auto_height.*;
    advanceFlow(parent_auto_height, box_offsets.border_size.h + margin_top + margin_bottom);
}

fn advanceFlow(parent_auto_height: *ZssUnit, amount: ZssUnit) void {
    parent_auto_height.* += amount;
}

fn makeInlineFormattingContext(
    allocator: Allocator,
    sc: *StackingContexts,
    computer: *StyleComputer,
    box_tree: *BoxTree,
    mode: enum { Normal, ShrinkToFit },
    containing_block_width: ZssUnit,
    containing_block_height: ?ZssUnit,
) !InlineLayoutContext.Result {
    assert(containing_block_width >= 0);
    assert(if (containing_block_height) |h| h >= 0 else true);

    const ifc_index = std.math.cast(InlineFormattingContextIndex, box_tree.ifcs.items.len) orelse return error.TooManyIfcs;
    const ifc = ifc: {
        const result_ptr = try box_tree.ifcs.addOne(box_tree.allocator);
        errdefer _ = box_tree.ifcs.pop();
        const result = try box_tree.allocator.create(InlineFormattingContext);
        errdefer box_tree.allocator.destroy(result);
        result.* = .{ .parent_block = undefined, .origin = undefined };
        errdefer result.deinit(box_tree.allocator);
        result_ptr.* = result;
        break :ifc result;
    };

    const sc_ifcs = &box_tree.stacking_contexts.multi_list.items(.ifcs)[sc.current];
    try sc_ifcs.append(box_tree.allocator, ifc_index);

    const percentage_base_unit: ZssUnit = switch (mode) {
        .Normal => containing_block_width,
        .ShrinkToFit => 0,
    };

    var inline_layout = InlineLayoutContext{
        .allocator = allocator,
        .containing_block_width = containing_block_width,
        .containing_block_height = containing_block_height,
        .percentage_base_unit = percentage_base_unit,
        .result = .{
            .ifc_index = ifc_index,
        },
    };
    defer inline_layout.deinit();

    try createInlineFormattingContext(&inline_layout, sc, computer, box_tree, ifc);

    return inline_layout.result;
}

const IFCLineSplitState = struct {
    cursor: ZssUnit,
    line_box: InlineFormattingContext.LineBox,
    inline_blocks_in_this_line_box: ArrayListUnmanaged(InlineBlockInfo),
    top_height: ZssUnit,
    max_top_height: ZssUnit,
    bottom_height: ZssUnit,
    longest_line_box_length: ZssUnit,

    const InlineBlockInfo = struct {
        box_offsets: *used_values.BoxOffsets,
        cursor: ZssUnit,
        height: ZssUnit,
    };

    fn init(top_height: ZssUnit, bottom_height: ZssUnit) IFCLineSplitState {
        return IFCLineSplitState{
            .cursor = 0,
            .line_box = .{ .baseline = 0, .elements = [2]usize{ 0, 0 } },
            .inline_blocks_in_this_line_box = .{},
            .top_height = top_height,
            .max_top_height = top_height,
            .bottom_height = bottom_height,
            .longest_line_box_length = 0,
        };
    }

    fn deinit(self: *IFCLineSplitState, allocator: Allocator) void {
        self.inline_blocks_in_this_line_box.deinit(allocator);
    }

    fn finishLineBox(self: *IFCLineSplitState, origin: ZssVector) void {
        self.line_box.baseline += self.max_top_height;
        self.longest_line_box_length = std.math.max(self.longest_line_box_length, self.cursor);

        for (self.inline_blocks_in_this_line_box.items) |info| {
            const offset_x = origin.x + info.cursor;
            const offset_y = origin.y + self.line_box.baseline - info.height;
            info.box_offsets.border_pos.x += offset_x;
            info.box_offsets.border_pos.y += offset_y;
        }
    }

    fn newLineBox(self: *IFCLineSplitState, skipped_glyphs: usize) void {
        self.cursor = 0;
        self.line_box = .{
            .baseline = self.line_box.baseline + self.bottom_height,
            .elements = [2]usize{ self.line_box.elements[1] + skipped_glyphs, self.line_box.elements[1] + skipped_glyphs },
        };
        self.max_top_height = self.top_height;
        self.inline_blocks_in_this_line_box.clearRetainingCapacity();
    }
};

const IFCLineSplitResult = struct {
    height: ZssUnit,
    longest_line_box_length: ZssUnit,
};

fn splitIntoLineBoxes(
    allocator: Allocator,
    box_tree: *BoxTree,
    ifc: *InlineFormattingContext,
    max_line_box_length: ZssUnit,
) !IFCLineSplitResult {
    assert(max_line_box_length >= 0);

    var font_extents: hb.hb_font_extents_t = undefined;
    // TODO assuming ltr direction
    assert(hb.hb_font_get_h_extents(ifc.font, &font_extents) != 0);
    ifc.ascender = @divFloor(font_extents.ascender * units_per_pixel, 64);
    ifc.descender = @divFloor(font_extents.descender * units_per_pixel, 64);
    const top_height: ZssUnit = @divFloor((font_extents.ascender + @divFloor(font_extents.line_gap, 2) + @mod(font_extents.line_gap, 2)) * units_per_pixel, 64);
    const bottom_height: ZssUnit = @divFloor((-font_extents.descender + @divFloor(font_extents.line_gap, 2)) * units_per_pixel, 64);

    var s = IFCLineSplitState.init(top_height, bottom_height);
    defer s.deinit(allocator);

    var i: usize = 0;
    while (i < ifc.glyph_indeces.items.len) : (i += 1) {
        const gi = ifc.glyph_indeces.items[i];
        const metrics = ifc.metrics.items[i];

        if (gi == 0) {
            i += 1;
            const special = InlineFormattingContext.Special.decode(ifc.glyph_indeces.items[i]);
            switch (@intToEnum(InlineFormattingContext.Special.LayoutInternalKind, @enumToInt(special.kind))) {
                .LineBreak => {
                    s.finishLineBox(ifc.origin);
                    try ifc.line_boxes.append(box_tree.allocator, s.line_box);
                    s.newLineBox(2);
                    continue;
                },
                .ContinuationBlock => @panic("TODO Continuation blocks"),
                else => {},
            }
        }

        // TODO: (Bug) A glyph with a width of zero but an advance that is non-zero may overflow the width of the containing block
        if (s.cursor > 0 and metrics.width > 0 and s.cursor + metrics.offset + metrics.width > max_line_box_length and s.line_box.elements[1] > s.line_box.elements[0]) {
            s.finishLineBox(ifc.origin);
            try ifc.line_boxes.append(box_tree.allocator, s.line_box);
            s.newLineBox(0);
        }

        if (gi == 0) {
            const special = InlineFormattingContext.Special.decode(ifc.glyph_indeces.items[i]);
            switch (@intToEnum(InlineFormattingContext.Special.LayoutInternalKind, @enumToInt(special.kind))) {
                .InlineBlock => {
                    const block_box_index = @as(BlockBoxIndex, special.data);
                    const box_offsets = &box_tree.blocks.box_offsets.items[block_box_index];
                    const margins = box_tree.blocks.margins.items[block_box_index];
                    const margin_box_height = box_offsets.border_size.h + margins.top + margins.bottom;
                    s.max_top_height = std.math.max(s.max_top_height, margin_box_height);
                    try s.inline_blocks_in_this_line_box.append(
                        allocator,
                        .{ .box_offsets = box_offsets, .cursor = s.cursor, .height = margin_box_height - margins.top },
                    );
                },
                .LineBreak => unreachable,
                .ContinuationBlock => @panic("TODO Continuation blocks"),
                else => {},
            }
            s.line_box.elements[1] += 2;
        } else {
            s.line_box.elements[1] += 1;
        }

        s.cursor += metrics.advance;
    }

    if (s.line_box.elements[1] > s.line_box.elements[0]) {
        s.finishLineBox(ifc.origin);
        try ifc.line_boxes.append(box_tree.allocator, s.line_box);
    }

    return IFCLineSplitResult{
        .height = if (ifc.line_boxes.items.len > 0)
            ifc.line_boxes.items[ifc.line_boxes.items.len - 1].baseline + s.bottom_height
        else
            0, // TODO: This is never reached because the root inline box always creates at least 1 line box.
        .longest_line_box_length = s.longest_line_box_length,
    };
}

fn makeInlineBlock(
    computer: *StyleComputer,
    containing_block_width: ZssUnit,
    containing_block_height: ?ZssUnit,
) !FlowBlockUsedSizes {
    const specified = FlowBlockComputedSizes{
        .content_width = computer.getSpecifiedValue(.box_gen, .content_width),
        .horizontal_edges = computer.getSpecifiedValue(.box_gen, .horizontal_edges),
        .content_height = computer.getSpecifiedValue(.box_gen, .content_height),
        .vertical_edges = computer.getSpecifiedValue(.box_gen, .vertical_edges),
    };
    const border_styles = computer.getSpecifiedValue(.box_gen, .border_styles);
    var computed: FlowBlockComputedSizes = undefined;
    var used: FlowBlockUsedSizes = undefined;
    try inlineBlockSolveSizes(
        specified,
        containing_block_width,
        containing_block_height,
        border_styles,
        &computed,
        &used,
    );

    computer.setComputedValue(.box_gen, .content_width, computed.content_width);
    computer.setComputedValue(.box_gen, .horizontal_edges, computed.horizontal_edges);
    computer.setComputedValue(.box_gen, .content_height, computed.content_height);
    computer.setComputedValue(.box_gen, .vertical_edges, computed.vertical_edges);
    computer.setComputedValue(.box_gen, .border_styles, border_styles);

    return used;
}

fn inlineBlockSolveSizes(
    specified: FlowBlockComputedSizes,
    containing_block_width: ZssUnit,
    containing_block_height: ?ZssUnit,
    border_styles: zss.properties.BorderStyles,
    computed: *FlowBlockComputedSizes,
    used: *FlowBlockUsedSizes,
) !void {
    assert(containing_block_width >= 0);
    if (containing_block_height) |h| assert(h >= 0);

    // TODO: Also use the logical properties ('padding-inline-start', 'border-block-end', etc.).

    {
        const multiplier = borderWidthMultiplier(border_styles.left);
        switch (specified.horizontal_edges.border_start) {
            .px => |value| {
                const width = value * multiplier;
                computed.horizontal_edges.border_start = .{ .px = width };
                used.border_inline_start = try positiveLength(.px, width);
            },
            .thin => {
                const width = borderWidth(.thin) * multiplier;
                computed.horizontal_edges.border_start = .{ .px = width };
                used.border_inline_start = positiveLength(.px, width) catch unreachable;
            },
            .medium => {
                const width = borderWidth(.medium) * multiplier;
                computed.horizontal_edges.border_start = .{ .px = width };
                used.border_inline_start = positiveLength(.px, width) catch unreachable;
            },
            .thick => {
                const width = borderWidth(.thick) * multiplier;
                computed.horizontal_edges.border_start = .{ .px = width };
                used.border_inline_start = positiveLength(.px, width) catch unreachable;
            },
            .initial, .inherit, .unset, .undeclared => unreachable,
        }
    }
    {
        const multiplier = borderWidthMultiplier(border_styles.right);
        switch (specified.horizontal_edges.border_end) {
            .px => |value| {
                const width = value * multiplier;
                computed.horizontal_edges.border_end = .{ .px = width };
                used.border_inline_end = try positiveLength(.px, width);
            },
            .thin => {
                const width = borderWidth(.thin) * multiplier;
                computed.horizontal_edges.border_end = .{ .px = width };
                used.border_inline_end = positiveLength(.px, width) catch unreachable;
            },
            .medium => {
                const width = borderWidth(.medium) * multiplier;
                computed.horizontal_edges.border_end = .{ .px = width };
                used.border_inline_end = positiveLength(.px, width) catch unreachable;
            },
            .thick => {
                const width = borderWidth(.thick) * multiplier;
                computed.horizontal_edges.border_end = .{ .px = width };
                used.border_inline_end = positiveLength(.px, width) catch unreachable;
            },
            .initial, .inherit, .unset, .undeclared => unreachable,
        }
    }
    switch (specified.horizontal_edges.padding_start) {
        .px => |value| {
            computed.horizontal_edges.padding_start = .{ .px = value };
            used.padding_inline_start = try positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.horizontal_edges.padding_start = .{ .percentage = value };
            used.padding_inline_start = try positivePercentage(value, containing_block_width);
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
    switch (specified.horizontal_edges.padding_end) {
        .px => |value| {
            computed.horizontal_edges.padding_end = .{ .px = value };
            used.padding_inline_end = try positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.horizontal_edges.padding_end = .{ .percentage = value };
            used.padding_inline_end = try positivePercentage(value, containing_block_width);
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
    switch (specified.horizontal_edges.margin_start) {
        .px => |value| {
            computed.horizontal_edges.margin_start = .{ .px = value };
            used.set(.margin_inline_start, length(.px, value));
        },
        .percentage => |value| {
            computed.horizontal_edges.margin_start = .{ .percentage = value };
            used.set(.margin_inline_start, percentage(value, containing_block_width));
        },
        .auto => {
            computed.horizontal_edges.margin_start = .auto;
            used.set(.margin_inline_start, 0);
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
    switch (specified.horizontal_edges.margin_end) {
        .px => |value| {
            computed.horizontal_edges.margin_end = .{ .px = value };
            used.set(.margin_inline_end, length(.px, value));
        },
        .percentage => |value| {
            computed.horizontal_edges.margin_end = .{ .percentage = value };
            used.set(.margin_inline_end, percentage(value, containing_block_width));
        },
        .auto => {
            computed.horizontal_edges.margin_end = .auto;
            used.set(.margin_inline_end, 0);
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
    switch (specified.content_width.min_size) {
        .px => |value| {
            computed.content_width.min_size = .{ .px = value };
            used.min_inline_size = try positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.content_width.min_size = .{ .percentage = value };
            used.min_inline_size = try positivePercentage(value, containing_block_width);
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
    switch (specified.content_width.max_size) {
        .px => |value| {
            computed.content_width.max_size = .{ .px = value };
            used.max_inline_size = try positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.content_width.max_size = .{ .percentage = value };
            used.max_inline_size = try positivePercentage(value, containing_block_width);
        },
        .none => {
            computed.content_width.max_size = .none;
            used.max_inline_size = std.math.maxInt(ZssUnit);
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }

    switch (specified.content_width.size) {
        .px => |value| {
            computed.content_width.size = .{ .px = value };
            used.set(.inline_size, try positiveLength(.px, value));
        },
        .percentage => |value| {
            computed.content_width.size = .{ .percentage = value };
            used.set(.inline_size, try positivePercentage(value, containing_block_width));
        },
        .auto => {
            computed.content_width.size = .auto;
            used.set(.inline_size, null);
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }

    {
        const multiplier = borderWidthMultiplier(border_styles.top);
        switch (specified.vertical_edges.border_start) {
            .px => |value| {
                const width = value * multiplier;
                computed.vertical_edges.border_start = .{ .px = width };
                used.border_block_start = try positiveLength(.px, width);
            },
            .thin => {
                const width = borderWidth(.thin) * multiplier;
                computed.vertical_edges.border_start = .{ .px = width };
                used.border_block_start = positiveLength(.px, width) catch unreachable;
            },
            .medium => {
                const width = borderWidth(.medium) * multiplier;
                computed.vertical_edges.border_start = .{ .px = width };
                used.border_block_start = positiveLength(.px, width) catch unreachable;
            },
            .thick => {
                const width = borderWidth(.thick) * multiplier;
                computed.vertical_edges.border_start = .{ .px = width };
                used.border_block_start = positiveLength(.px, width) catch unreachable;
            },
            .initial, .inherit, .unset, .undeclared => unreachable,
        }
    }
    {
        const multiplier = borderWidthMultiplier(border_styles.bottom);
        switch (specified.vertical_edges.border_end) {
            .px => |value| {
                const width = value * multiplier;
                computed.vertical_edges.border_end = .{ .px = width };
                used.border_block_end = try positiveLength(.px, width);
            },
            .thin => {
                const width = borderWidth(.thin) * multiplier;
                computed.vertical_edges.border_end = .{ .px = width };
                used.border_block_end = positiveLength(.px, width) catch unreachable;
            },
            .medium => {
                const width = borderWidth(.medium) * multiplier;
                computed.vertical_edges.border_end = .{ .px = width };
                used.border_block_end = positiveLength(.px, width) catch unreachable;
            },
            .thick => {
                const width = borderWidth(.thick) * multiplier;
                computed.vertical_edges.border_end = .{ .px = width };
                used.border_block_end = positiveLength(.px, width) catch unreachable;
            },
            .initial, .inherit, .unset, .undeclared => unreachable,
        }
    }
    switch (specified.vertical_edges.padding_start) {
        .px => |value| {
            computed.vertical_edges.padding_start = .{ .px = value };
            used.padding_block_start = try positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.vertical_edges.padding_start = .{ .percentage = value };
            used.padding_block_start = try positivePercentage(value, containing_block_width);
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
    switch (specified.vertical_edges.padding_end) {
        .px => |value| {
            computed.vertical_edges.padding_end = .{ .px = value };
            used.padding_block_end = try positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.vertical_edges.padding_end = .{ .percentage = value };
            used.padding_block_end = try positivePercentage(value, containing_block_width);
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
    switch (specified.vertical_edges.margin_start) {
        .px => |value| {
            computed.vertical_edges.margin_start = .{ .px = value };
            used.margin_block_start = length(.px, value);
        },
        .percentage => |value| {
            computed.vertical_edges.margin_start = .{ .percentage = value };
            used.margin_block_start = percentage(value, containing_block_width);
        },
        .auto => {
            computed.vertical_edges.margin_start = .auto;
            used.margin_block_start = 0;
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
    switch (specified.vertical_edges.margin_end) {
        .px => |value| {
            computed.vertical_edges.margin_end = .{ .px = value };
            used.margin_block_end = length(.px, value);
        },
        .percentage => |value| {
            computed.vertical_edges.margin_end = .{ .percentage = value };
            used.margin_block_end = percentage(value, containing_block_width);
        },
        .auto => {
            computed.vertical_edges.margin_end = .auto;
            used.margin_block_end = 0;
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
    switch (specified.content_height.min_size) {
        .px => |value| {
            computed.content_height.min_size = .{ .px = value };
            used.min_block_size = try positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.content_height.min_size = .{ .percentage = value };
            used.min_block_size = if (containing_block_height) |h|
                try positivePercentage(value, h)
            else
                0;
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
    switch (specified.content_height.max_size) {
        .px => |value| {
            computed.content_height.max_size = .{ .px = value };
            used.max_block_size = try positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.content_height.max_size = .{ .percentage = value };
            used.max_block_size = if (containing_block_height) |h|
                try positivePercentage(value, h)
            else
                std.math.maxInt(ZssUnit);
        },
        .none => {
            computed.content_height.max_size = .none;
            used.max_block_size = std.math.maxInt(ZssUnit);
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
    switch (specified.content_height.size) {
        .px => |value| {
            computed.content_height.size = .{ .px = value };
            used.set(.block_size, try positiveLength(.px, value));
        },
        .percentage => |value| {
            computed.content_height.size = .{ .percentage = value };
            used.set(.block_size, if (containing_block_height) |h|
                try positivePercentage(value, h)
            else
                null);
        },
        .auto => {
            computed.content_height.size = .auto;
            used.set(.block_size, null);
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
}

const StfObjects = struct {
    tree: MultiArrayList(Object) = .{},
    data: ArrayListAlignedUnmanaged([data_chunk_size]u8, data_max_alignment) = .{},

    const data_chunk_size = 4;
    const data_max_alignment = 4;

    const Index = ElementIndex;
    const Skip = Index;
    const DataIndex = usize;

    const Tag = enum {
        flow_normal,
        flow_stf,
        ifc,
        none,
    };

    const DataTag = enum {
        flow,
        ifc,

        fn Type(comptime tag: DataTag) type {
            return switch (tag) {
                .flow => FlowBlockUsedSizes,
                .ifc => struct { layout_result: InlineLayoutContext.Result, line_split_result: IFCLineSplitResult },
            };
        }
    };

    const Object = struct {
        skip: Skip,
        tag: Tag,
        element: ElementIndex,
    };

    fn allocData(objects: *StfObjects, allocator: Allocator, comptime tag: DataTag) !DataIndex {
        const Data = tag.Type();
        const size = @sizeOf(Data);
        const num_chunks = zss.util.divCeil(size, data_chunk_size);
        try objects.data.ensureUnusedCapacity(allocator, num_chunks);
        defer objects.data.items.len += num_chunks;
        return objects.data.items.len;
    }

    fn getData(objects: *const StfObjects, comptime tag: DataTag, data_index: DataIndex) *tag.Type() {
        const Data = tag.Type();
        const size = @sizeOf(Data);
        const num_chunks = zss.util.divCeil(size, data_chunk_size);
        const chunks = objects.data.items[data_index..][0..num_chunks];
        const bytes = @ptrCast([*]align(data_max_alignment) u8, chunks)[0..size];
        return std.mem.bytesAsValue(Data, bytes);
    }

    fn getData2(objects: *const StfObjects, comptime tag: DataTag, data_index: *DataIndex) *tag.Type() {
        const Data = tag.Type();
        const size = @sizeOf(Data);
        const num_chunks = zss.util.divCeil(size, data_chunk_size);
        defer data_index.* += num_chunks;
        return getData(objects, tag, data_index.*);
    }
};

const ShrinkToFitLayoutContext = struct {
    objects: StfObjects = .{},
    object_stack: MultiArrayList(ObjectStackItem) = .{},

    widths: MultiArrayList(Widths) = .{},
    heights: ArrayListUnmanaged(?ZssUnit) = .{},

    allocator: Allocator,

    const ObjectStackItem = struct {
        index: StfObjects.Index,
        skip: StfObjects.Skip,
        data_index: StfObjects.DataIndex,
    };

    const Widths = struct {
        auto: ZssUnit,
        available: ZssUnit,
    };

    fn initFlow(allocator: Allocator, computer: *StyleComputer, used_sizes: FlowBlockUsedSizes, available_width: ZssUnit) !ShrinkToFitLayoutContext {
        const element = computer.this_element.index;
        try computer.pushElement(.box_gen);

        var result = ShrinkToFitLayoutContext{ .allocator = allocator };
        errdefer result.deinit();
        try result.objects.tree.append(result.allocator, .{ .skip = undefined, .tag = .flow_stf, .element = element });
        const data_index = try result.objects.allocData(result.allocator, .flow);
        const data_ptr = result.objects.getData(.flow, data_index);
        data_ptr.* = used_sizes;
        try result.object_stack.append(result.allocator, .{ .index = 0, .skip = 1, .data_index = data_index });
        try stfPushFlowBlock(&result, used_sizes, available_width);
        return result;
    }

    fn deinit(self: *ShrinkToFitLayoutContext) void {
        self.objects.tree.deinit(self.allocator);
        self.objects.data.deinit(self.allocator);
        self.object_stack.deinit(self.allocator);

        self.widths.deinit(self.allocator);
        self.heights.deinit(self.allocator);
    }
};

fn shrinkToFitLayout(layout: *ShrinkToFitLayoutContext, sc: *StackingContexts, computer: *StyleComputer, box_tree: *BoxTree) !void {
    const stf_root_element = computer.this_element.index;
    const saved_element_stack_len = computer.element_stack.items.len;
    try stfBuildObjectTree(layout, sc, computer, box_tree);
    computer.setElementDirectChild(.box_gen, stf_root_element);
    try computer.computeAndPushElement(.box_gen);
    try stfRealizeObjects(layout.objects, layout.allocator, sc, computer, box_tree);

    while (computer.element_stack.items.len > saved_element_stack_len) {
        computer.popElement(.box_gen);
    }
    computer.popElement(.box_gen);
}

fn stfBuildObjectTree(layout: *ShrinkToFitLayoutContext, sc: *StackingContexts, computer: *StyleComputer, box_tree: *BoxTree) !void {
    assert(layout.objects.tree.len == 1);
    assert(layout.object_stack.len > 0);
    while (layout.object_stack.len > 0) {
        const object_index = layout.object_stack.items(.index)[layout.object_stack.len - 1];
        const object_tag = layout.objects.tree.items(.tag)[object_index];
        switch (object_tag) {
            .flow_stf => {
                const interval = &computer.intervals.items[computer.intervals.items.len - 1];
                if (interval.begin != interval.end) {
                    const element = interval.begin;
                    const skip = computer.element_tree_skips[element];
                    computer.setElementDirectChild(.box_gen, element);

                    const specified = computer.getSpecifiedValue(.box_gen, .box_style);
                    const computed = solveBoxStyle(specified, .NonRoot);
                    computer.setComputedValue(.box_gen, .box_style, computed);

                    const containing_block_available_width = layout.widths.items(.available)[layout.widths.len - 1];
                    const containing_block_height = layout.heights.items[layout.heights.items.len - 1];

                    switch (computed.display) {
                        .block => {
                            const data_index = try layout.objects.allocData(layout.allocator, .flow);
                            const used: *FlowBlockUsedSizes = layout.objects.getData(.flow, data_index);
                            try stfAnalyzeFlowBlock(computer, used, containing_block_height);

                            // TODO: Handle stacking contexts

                            const edge_width = used.margin_inline_start_untagged + used.margin_inline_end_untagged +
                                used.border_inline_start + used.border_inline_end +
                                used.padding_inline_start + used.padding_inline_end;

                            if (used.get(.inline_size)) |inline_size| {
                                const parent_auto_width = &layout.widths.items(.auto)[layout.widths.len - 1];
                                parent_auto_width.* = std.math.max(parent_auto_width.*, inline_size + edge_width);

                                try layout.objects.tree.append(layout.allocator, .{ .skip = 1, .tag = .flow_normal, .element = element });
                                layout.object_stack.items(.skip)[layout.object_stack.len - 1] += 1;
                                interval.begin += skip;
                            } else {
                                const parent_available_width = layout.widths.items(.available)[layout.widths.len - 1];
                                const available_width = std.math.max(0, parent_available_width - edge_width);
                                try stfPushFlowBlock(layout, used.*, available_width);

                                try layout.object_stack.append(layout.allocator, .{
                                    .index = @intCast(StfObjects.Index, layout.objects.tree.len),
                                    .skip = 1,
                                    .data_index = data_index,
                                });
                                try layout.objects.tree.append(layout.allocator, .{ .skip = undefined, .tag = .flow_stf, .element = element });

                                { // TODO: Delete this
                                    const stuff = .{
                                        .z_index = computer.getSpecifiedValue(.box_gen, .z_index),
                                        .font = computer.getSpecifiedValue(.box_gen, .font),
                                    };
                                    computer.setComputedValue(.box_gen, .z_index, stuff.z_index);
                                    computer.setComputedValue(.box_gen, .font, stuff.font);
                                }

                                interval.begin += skip;
                                try computer.pushElement(.box_gen);
                            }
                        },
                        .none => {
                            try layout.objects.tree.append(layout.allocator, .{ .skip = 1, .tag = .none, .element = element });
                            layout.object_stack.items(.skip)[layout.object_stack.len - 1] += 1;
                            interval.begin += skip;
                        },
                        .inline_, .inline_block, .text => {
                            _ = sc;
                            _ = box_tree;
                            _ = containing_block_available_width;
                            @panic("TODO: Shrink to fit text");

                            // If this IFC contained inline-block elements, this code would create them before
                            // their parent block was created, which would be problematic.

                            // const result = try makeInlineFormattingContext(
                            //     layout.allocator,
                            //     sc,
                            //     computer,
                            //     box_tree,
                            //     .ShrinkToFit,
                            //     containing_block_available_width,
                            //     containing_block_height,
                            // );
                            // const ifc = box_tree.ifcs.items[result.ifc_index];
                            // const line_split_result = try splitIntoLineBoxes(layout.allocator, box_tree, ifc, containing_block_available_width);

                            // const parent_auto_width = &layout.widths.items(.auto)[layout.widths.len - 1];
                            // parent_auto_width.* = std.math.max(parent_auto_width.*, line_split_result.longest_line_box_length);

                            // const data_index = try layout.objects.allocData(layout.allocator, .ifc);
                            // const data = layout.objects.getData(.ifc, data_index);
                            // data.* = .{ .layout_result = result, .line_split_result = line_split_result };
                            // try layout.objects.tree.append(layout.allocator, .{ .skip = 1, .tag = .ifc, .element = undefined });
                            // layout.object_stack.items(.skip)[layout.object_stack.len - 1] += 1;
                        },
                        .initial, .inherit, .unset, .undeclared => unreachable,
                    }
                } else {
                    const object_info = layout.object_stack.pop();
                    layout.objects.tree.items(.skip)[object_info.index] = object_info.skip;

                    const block_info = stfPopFlowBlock(layout);
                    const used: *FlowBlockUsedSizes = layout.objects.getData(.flow, object_info.data_index);
                    used.set(.inline_size, block_info.auto_width);

                    computer.popElement(.box_gen);

                    if (layout.object_stack.len > 0) {
                        const parent_object_index = layout.object_stack.items(.index)[layout.object_stack.len - 1];
                        const parent_object_tag = layout.objects.tree.items(.tag)[parent_object_index];
                        switch (parent_object_tag) {
                            .flow_stf => {
                                const parent_auto_width = &layout.widths.items(.auto)[layout.widths.len - 1];
                                parent_auto_width.* = std.math.max(parent_auto_width.*, used.get(.inline_size).?);
                            },
                            .flow_normal, .ifc, .none => unreachable,
                        }

                        layout.object_stack.items(.skip)[layout.object_stack.len - 1] += object_info.skip;
                    }
                }
            },
            .flow_normal, .ifc, .none => unreachable,
        }
    }
}

const ShrinkToFitLayoutContext2 = struct {
    objects: MultiArrayList(struct { tag: StfObjects.Tag, interval: Interval, data_index: StfObjects.DataIndex }) = .{},
    blocks: MultiArrayList(struct { index: BlockBoxIndex, skip: BlockBoxSkip }) = .{},
    width: ArrayListUnmanaged(ZssUnit) = .{},
    height: ArrayListUnmanaged(?ZssUnit) = .{},
    auto_height: ArrayListUnmanaged(ZssUnit) = .{},

    const Interval = struct {
        begin: StfObjects.Index,
        end: StfObjects.Index,
    };

    fn deinit(layout: *ShrinkToFitLayoutContext2, allocator: Allocator) void {
        layout.objects.deinit(allocator);
        layout.blocks.deinit(allocator);
        layout.width.deinit(allocator);
        layout.height.deinit(allocator);
        layout.auto_height.deinit(allocator);
    }
};

fn stfRealizeObjects(objects: StfObjects, allocator: Allocator, sc: *StackingContexts, computer: *StyleComputer, box_tree: *BoxTree) !void {
    const skips = objects.tree.items(.skip);
    const tags = objects.tree.items(.tag);
    const elements = objects.tree.items(.element);

    var data_index_mutable: StfObjects.DataIndex = 0;
    var layout = ShrinkToFitLayoutContext2{};
    defer layout.deinit(allocator);

    {
        const skip = skips[0];
        const tag = tags[0];
        const element = elements[0];
        const data_index = data_index_mutable;
        switch (tag) {
            .flow_stf => {
                const block = try createBlock(box_tree);
                block.properties.* = .{};

                const used_sizes: *FlowBlockUsedSizes = objects.getData2(.flow, &data_index_mutable);
                flowBlockSetData(used_sizes.*, block.box_offsets, block.borders, block.margins);
                box_tree.element_index_to_generated_box[element] = .{ .block_box = block.index };

                try layout.blocks.append(allocator, .{ .index = block.index, .skip = 1 });
                try layout.width.append(allocator, used_sizes.get(.inline_size).?);
                try layout.height.append(allocator, used_sizes.get(.block_size));
                try layout.auto_height.append(allocator, 0);
            },
            .flow_normal, .ifc, .none => unreachable,
        }

        try layout.objects.append(allocator, .{ .tag = tag, .interval = .{ .begin = 1, .end = skip }, .data_index = data_index });
    }

    while (layout.objects.len > 0) {
        const parent_tag = layout.objects.items(.tag)[layout.objects.len - 1];
        const interval = &layout.objects.items(.interval)[layout.objects.len - 1];
        switch (parent_tag) {
            .flow_stf => if (interval.begin != interval.end) {
                const index = interval.begin;
                const skip = skips[index];
                const tag = tags[index];
                const element = elements[index];
                const data_index = data_index_mutable;
                interval.begin += skip;

                const containing_block_width = layout.width.items[layout.width.items.len - 1];
                switch (tag) {
                    .flow_stf => {
                        const block = try createBlock(box_tree);
                        block.properties.* = .{};

                        const used_sizes: *FlowBlockUsedSizes = objects.getData2(.flow, &data_index_mutable);
                        flowBlockAdjustWidthAndMargins(used_sizes, containing_block_width);
                        flowBlockSetData(used_sizes.*, block.box_offsets, block.borders, block.margins);
                        box_tree.element_index_to_generated_box[element] = .{ .block_box = block.index };

                        try layout.objects.append(allocator, .{ .tag = .flow_stf, .interval = .{ .begin = index + 1, .end = index + skip }, .data_index = data_index });
                        try layout.blocks.append(allocator, .{ .index = block.index, .skip = 1 });
                        try layout.width.append(allocator, used_sizes.get(.inline_size).?);
                        try layout.height.append(allocator, used_sizes.get(.block_size));
                        try layout.auto_height.append(allocator, 0);
                    },
                    .flow_normal => {
                        const block = try createBlock(box_tree);
                        block.properties.* = .{};

                        const used_sizes: *FlowBlockUsedSizes = objects.getData2(.flow, &data_index_mutable);
                        flowBlockAdjustWidthAndMargins(used_sizes, containing_block_width);
                        flowBlockSetData(used_sizes.*, block.box_offsets, block.borders, block.margins);
                        box_tree.element_index_to_generated_box[element] = .{ .block_box = block.index };

                        var new_block_layout = BlockLayoutContext{ .allocator = allocator };
                        defer new_block_layout.deinit();
                        const containing_block_height = layout.height.items[layout.height.items.len - 1];
                        try pushContainingBlock(&new_block_layout, containing_block_width, containing_block_height);
                        try pushFlowBlock(&new_block_layout, block.index, used_sizes.*);
                        // TODO: The stacking context that gets pushed should be determined when building the object tree.
                        try sc.pushStackingContext(.none);
                        try computer.setElementAny(.box_gen, element);
                        try computer.computeAndPushElement(.box_gen);
                        try runFully(&new_block_layout, sc, computer, box_tree);

                        computer.popElement(.box_gen);

                        const block_skip = box_tree.blocks.skips.items[block.index];
                        layout.blocks.items(.skip)[layout.blocks.len - 1] += block_skip;
                        const parent_auto_height = &layout.auto_height.items[layout.auto_height.items.len - 1];
                        const box_offsets = &box_tree.blocks.box_offsets.items[block.index];
                        const margin_bottom = box_tree.blocks.margins.items[block.index].bottom;
                        addBlockToFlow(box_offsets, margin_bottom, parent_auto_height);
                    },
                    .ifc => {
                        @panic("TODO");
                        // const data = objects.getData2(.ifc, &data_index_mutable);
                        // const parent_auto_height = &layout.auto_height.items[layout.auto_height.items.len - 1];
                        // const ifc = box_tree.ifcs.items[data.layout_result.ifc_index];
                        // ifc.origin = .{ .x = 0, .y = parent_auto_height.* };
                        // ifc.parent_block = layout.blocks.items(.index)[layout.blocks.len - 1];
                        // layout.blocks.items(.skip)[layout.blocks.len - 1] += data.layout_result.total_inline_block_skip;
                        // advanceFlow(parent_auto_height, data.line_split_result.height);
                    },
                    .none => {
                        std.mem.set(GeneratedBox, box_tree.element_index_to_generated_box[element..][0..computer.element_tree_skips[element]], .none);
                    },
                }
            } else {
                const data_index = layout.objects.pop().data_index;
                const block = layout.blocks.pop();
                _ = layout.width.pop();
                _ = layout.height.pop();
                const auto_height = layout.auto_height.pop();

                const used_sizes = objects.getData(.flow, data_index);
                const box_offsets = &box_tree.blocks.box_offsets.items[block.index];

                box_tree.blocks.skips.items[block.index] = block.skip;
                flowBlockFinishLayout(box_offsets, used_sizes.getUsedContentHeight(), auto_height);

                if (layout.objects.len > 0) {
                    switch (layout.objects.items(.tag)[layout.objects.len - 1]) {
                        .flow_stf => {
                            layout.blocks.items(.skip)[layout.blocks.len - 1] += block.skip;
                            const parent_auto_height = &layout.auto_height.items[layout.auto_height.items.len - 1];
                            const margin_bottom = box_tree.blocks.margins.items[block.index].bottom;
                            addBlockToFlow(box_offsets, margin_bottom, parent_auto_height);
                        },
                        .flow_normal, .ifc, .none => unreachable,
                    }
                }
            },
            .flow_normal, .ifc, .none => unreachable,
        }
    }
}

fn stfAnalyzeFlowBlock(
    computer: *StyleComputer,
    used: *FlowBlockUsedSizes,
    containing_block_height: ?ZssUnit,
) !void {
    const specified = .{
        .content_width = computer.getSpecifiedValue(.box_gen, .content_width),
        .content_height = computer.getSpecifiedValue(.box_gen, .content_height),
        .horizontal_edges = computer.getSpecifiedValue(.box_gen, .horizontal_edges),
        .vertical_edges = computer.getSpecifiedValue(.box_gen, .vertical_edges),
        .border_styles = computer.getSpecifiedValue(.box_gen, .border_styles),
    };
    var computed: FlowBlockComputedSizes = undefined;

    try stfFlowBlockSolveContentWidth(specified.content_width, &computed.content_width, used);
    try stfFlowBlockSolveHorizontalEdges(specified.horizontal_edges, specified.border_styles, &computed.horizontal_edges, used);
    try flowBlockSolveContentHeight(specified.content_height, containing_block_height, &computed.content_height, used);
    try flowBlockSolveVerticalEdges(specified.vertical_edges, 0, specified.border_styles, &computed.vertical_edges, used);

    computer.setComputedValue(.box_gen, .content_width, computed.content_width);
    computer.setComputedValue(.box_gen, .horizontal_edges, computed.horizontal_edges);
    computer.setComputedValue(.box_gen, .content_height, computed.content_height);
    computer.setComputedValue(.box_gen, .vertical_edges, computed.vertical_edges);
    computer.setComputedValue(.box_gen, .border_styles, specified.border_styles);
}

fn stfPushFlowBlock(layout: *ShrinkToFitLayoutContext, used_sizes: FlowBlockUsedSizes, available_width: ZssUnit) !void {
    // The allocations here must have corresponding deallocations in stfPopFlowBlock.
    try layout.widths.append(layout.allocator, .{ .auto = 0, .available = available_width });
    try layout.heights.append(layout.allocator, used_sizes.get(.block_size));
}

fn stfPopFlowBlock(layout: *ShrinkToFitLayoutContext) struct { auto_width: ZssUnit } {
    // The deallocations here must correspond to allocations in stfPushFlowBlock.
    _ = layout.heights.pop();
    return .{
        .auto_width = layout.widths.pop().auto,
    };
}

fn stfFlowBlockSolveContentWidth(
    specified: zss.properties.ContentSize,
    computed: *zss.properties.ContentSize,
    used: *FlowBlockUsedSizes,
) !void {
    switch (specified.min_size) {
        .px => |value| {
            computed.min_size = .{ .px = value };
            used.min_inline_size = try positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.min_size = .{ .percentage = value };
            used.min_inline_size = 0;
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
    switch (specified.max_size) {
        .px => |value| {
            computed.max_size = .{ .px = value };
            used.max_inline_size = try positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.max_size = .{ .percentage = value };
            used.max_inline_size = std.math.maxInt(ZssUnit);
        },
        .none => {
            computed.max_size = .none;
            used.max_inline_size = std.math.maxInt(ZssUnit);
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }

    switch (specified.size) {
        .px => |value| {
            computed.size = .{ .px = value };
            used.set(.inline_size, try positiveLength(.px, value));
        },
        .percentage => |value| {
            computed.size = .{ .percentage = value };
            used.set(.inline_size, null);
        },
        .auto => {
            computed.size = .auto;
            used.set(.inline_size, null);
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
}

fn stfFlowBlockSolveHorizontalEdges(
    specified: zss.properties.BoxEdges,
    border_styles: zss.properties.BorderStyles,
    computed: *zss.properties.BoxEdges,
    used: *FlowBlockUsedSizes,
) !void {
    {
        const multiplier = borderWidthMultiplier(border_styles.left);
        switch (specified.border_start) {
            .px => |value| {
                const width = value * multiplier;
                computed.border_start = .{ .px = width };
                used.border_inline_start = try positiveLength(.px, width);
            },
            .thin => {
                const width = borderWidth(.thin) * multiplier;
                computed.border_start = .{ .px = width };
                used.border_inline_start = positiveLength(.px, width) catch unreachable;
            },
            .medium => {
                const width = borderWidth(.medium) * multiplier;
                computed.border_start = .{ .px = width };
                used.border_inline_start = positiveLength(.px, width) catch unreachable;
            },
            .thick => {
                const width = borderWidth(.thick) * multiplier;
                computed.border_start = .{ .px = width };
                used.border_inline_start = positiveLength(.px, width) catch unreachable;
            },
            .initial, .inherit, .unset, .undeclared => unreachable,
        }
    }
    {
        const multiplier = borderWidthMultiplier(border_styles.right);
        switch (specified.border_end) {
            .px => |value| {
                const width = value * multiplier;
                computed.border_end = .{ .px = width };
                used.border_inline_end = try positiveLength(.px, width);
            },
            .thin => {
                const width = borderWidth(.thin) * multiplier;
                computed.border_end = .{ .px = width };
                used.border_inline_end = positiveLength(.px, width) catch unreachable;
            },
            .medium => {
                const width = borderWidth(.medium) * multiplier;
                computed.border_end = .{ .px = width };
                used.border_inline_end = positiveLength(.px, width) catch unreachable;
            },
            .thick => {
                const width = borderWidth(.thick) * multiplier;
                computed.border_end = .{ .px = width };
                used.border_inline_end = positiveLength(.px, width) catch unreachable;
            },
            .initial, .inherit, .unset, .undeclared => unreachable,
        }
    }

    switch (specified.padding_start) {
        .px => |value| {
            computed.padding_start = .{ .px = value };
            used.padding_inline_start = try positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.padding_start = .{ .percentage = value };
            used.padding_inline_start = 0;
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
    switch (specified.padding_end) {
        .px => |value| {
            computed.padding_end = .{ .px = value };
            used.padding_inline_end = try positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.padding_end = .{ .percentage = value };
            used.padding_inline_end = 0;
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }

    switch (specified.margin_start) {
        .px => |value| {
            computed.margin_start = .{ .px = value };
            used.set(.margin_inline_start, length(.px, value));
        },
        .percentage => |value| {
            computed.margin_start = .{ .percentage = value };
            used.set(.margin_inline_start, null);
        },
        .auto => {
            computed.margin_start = .auto;
            used.set(.margin_inline_start, null);
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
    switch (specified.margin_end) {
        .px => |value| {
            computed.margin_end = .{ .px = value };
            used.set(.margin_inline_end, length(.px, value));
        },
        .percentage => |value| {
            computed.margin_end = .{ .percentage = value };
            used.set(.margin_inline_end, null);
        },
        .auto => {
            computed.margin_end = .auto;
            used.set(.margin_inline_end, null);
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
}

const Block = struct {
    index: BlockBoxIndex,
    skip: *BlockBoxSkip,
    box_offsets: *used_values.BoxOffsets,
    borders: *used_values.Borders,
    margins: *used_values.Margins,
    properties: *BlockBoxTree.BoxProperties,
};

fn createBlock(box_tree: *BoxTree) !Block {
    const index = std.math.cast(BlockBoxIndex, box_tree.blocks.skips.items.len) orelse return error.TooManyBlocks;
    return Block{
        .index = index,
        .skip = try box_tree.blocks.skips.addOne(box_tree.allocator),
        .box_offsets = try box_tree.blocks.box_offsets.addOne(box_tree.allocator),
        .borders = try box_tree.blocks.borders.addOne(box_tree.allocator),
        .margins = try box_tree.blocks.margins.addOne(box_tree.allocator),
        .properties = try box_tree.blocks.properties.addOne(box_tree.allocator),
    };
}

fn blockBoxSolveOtherProperties(computer: *StyleComputer, box_tree: *BoxTree, block_box_index: BlockBoxIndex) !void {
    const specified = .{
        .color = computer.getSpecifiedValue(.cosmetic, .color),
        .border_colors = computer.getSpecifiedValue(.cosmetic, .border_colors),
        .border_styles = computer.getSpecifiedValue(.cosmetic, .border_styles),
        .background1 = computer.getSpecifiedValue(.cosmetic, .background1),
        .background2 = computer.getSpecifiedValue(.cosmetic, .background2),
    };

    const current_color = getCurrentColor(specified.color.color);

    const box_offsets_ptr = &box_tree.blocks.box_offsets.items[block_box_index];
    const borders_ptr = &box_tree.blocks.borders.items[block_box_index];

    const border_colors_ptr = &box_tree.blocks.border_colors.items[block_box_index];
    border_colors_ptr.* = solveBorderColors(specified.border_colors, current_color);

    solveBorderStyles(specified.border_styles);

    const background1_ptr = &box_tree.blocks.background1.items[block_box_index];
    const background2_ptr = &box_tree.blocks.background2.items[block_box_index];
    background1_ptr.* = solveBackground1(specified.background1, current_color);
    background2_ptr.* = try solveBackground2(specified.background2, box_offsets_ptr, borders_ptr);

    // TODO: Pretending that specified values are computed values...
    computer.setComputedValue(.cosmetic, .color, specified.color);
    computer.setComputedValue(.cosmetic, .border_colors, specified.border_colors);
    computer.setComputedValue(.cosmetic, .border_styles, specified.border_styles);
    computer.setComputedValue(.cosmetic, .background1, specified.background1);
    computer.setComputedValue(.cosmetic, .background2, specified.background2);
}

fn blockBoxFillOtherPropertiesWithDefaults(box_tree: *BoxTree, block_box_index: BlockBoxIndex) void {
    box_tree.blocks.border_colors.items[block_box_index] = .{};
    box_tree.blocks.background1.items[block_box_index] = .{};
    box_tree.blocks.background2.items[block_box_index] = .{};
}

fn inlineBoxSolveOtherProperties(computer: *StyleComputer, ifc: *InlineFormattingContext, inline_box_index: InlineBoxIndex) void {
    const specified = .{
        .color = computer.getSpecifiedValue(.cosmetic, .color),
        .border_colors = computer.getSpecifiedValue(.cosmetic, .border_colors),
        .border_styles = computer.getSpecifiedValue(.cosmetic, .border_styles),
        .background1 = computer.getSpecifiedValue(.cosmetic, .background1),
        .background2 = computer.getSpecifiedValue(.cosmetic, .background2), // TODO: Inline boxes don't need background2
    };

    // TODO: Pretending that specified values are computed values...
    computer.setComputedValue(.cosmetic, .color, specified.color);
    computer.setComputedValue(.cosmetic, .border_colors, specified.border_colors);
    computer.setComputedValue(.cosmetic, .border_styles, specified.border_styles);
    computer.setComputedValue(.cosmetic, .background1, specified.background1);
    computer.setComputedValue(.cosmetic, .background2, specified.background2);

    const current_color = getCurrentColor(specified.color.color);

    const border_colors = solveBorderColors(specified.border_colors, current_color);
    ifc.inline_start.items[inline_box_index].border_color_rgba = border_colors.left_rgba;
    ifc.inline_end.items[inline_box_index].border_color_rgba = border_colors.right_rgba;
    ifc.block_start.items[inline_box_index].border_color_rgba = border_colors.top_rgba;
    ifc.block_end.items[inline_box_index].border_color_rgba = border_colors.bottom_rgba;

    solveBorderStyles(specified.border_styles);

    const background1_ptr = &ifc.background1.items[inline_box_index];
    background1_ptr.* = solveBackground1(specified.background1, current_color);
}

fn inlineRootBoxSolveOtherProperties(ifc: *InlineFormattingContext) void {
    ifc.inline_start.items[0].border_color_rgba = 0;
    ifc.inline_end.items[0].border_color_rgba = 0;
    ifc.block_start.items[0].border_color_rgba = 0;
    ifc.block_end.items[0].border_color_rgba = 0;

    ifc.background1.items[0] = .{};
}

const StackingContexts = struct {
    tag: ArrayListUnmanaged(Tag) = .{},
    index: ArrayListUnmanaged(StackingContextIndex) = .{},
    current: StackingContextIndex = undefined,
    allocator: Allocator,

    const Tag = enum { none, is_parent, is_non_parent };
    const Data = union(Tag) {
        none: void,
        is_parent: StackingContextIndex,
        is_non_parent: StackingContextIndex,
    };

    fn deinit(sc: *StackingContexts) void {
        sc.tag.deinit(sc.allocator);
        sc.index.deinit(sc.allocator);
    }

    fn createRootStackingContext(box_tree: *BoxTree, block_box_index: BlockBoxIndex, z_index: ZIndex) !StackingContextIndex {
        assert(box_tree.stacking_contexts.size() == 0);
        try box_tree.stacking_contexts.ensureTotalCapacity(box_tree.allocator, 1);
        const result = box_tree.stacking_contexts.createRootAssumeCapacity(.{ .z_index = z_index, .block_box = block_box_index, .ifcs = .{} });
        box_tree.blocks.properties.items[block_box_index].creates_stacking_context = true;
        return result;
    }

    fn createStackingContext(sc: *StackingContexts, box_tree: *BoxTree, block_box_index: BlockBoxIndex, z_index: ZIndex) !StackingContextIndex {
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

        box_tree.stacking_contexts.multi_list.insertAssumeCapacity(current, .{ .__skip = 1, .z_index = z_index, .block_box = block_box_index, .ifcs = .{} });
        box_tree.blocks.properties.items[block_box_index].creates_stacking_context = true;
        return current;
    }

    fn pushStackingContext(sc: *StackingContexts, data: Data) !void {
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

    fn popStackingContext(sc: *StackingContexts) void {
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
};

const InlineLayoutContext = struct {
    const Self = @This();

    allocator: Allocator,
    containing_block_width: ZssUnit,
    containing_block_height: ?ZssUnit,
    percentage_base_unit: ZssUnit,

    inline_box_depth: InlineBoxIndex = 0,
    index: ArrayListUnmanaged(InlineBoxIndex) = .{},

    result: Result,

    const Result = struct {
        ifc_index: InlineFormattingContextIndex,
        total_inline_block_skip: BlockBoxSkip = 0,
    };

    fn deinit(self: *Self) void {
        self.index.deinit(self.allocator);
    }
};

pub fn createInlineBox(box_tree: *BoxTree, ifc: *InlineFormattingContext) !InlineBoxIndex {
    const old_size = ifc.inline_start.items.len;
    _ = try ifc.inline_start.addOne(box_tree.allocator);
    _ = try ifc.inline_end.addOne(box_tree.allocator);
    _ = try ifc.block_start.addOne(box_tree.allocator);
    _ = try ifc.block_end.addOne(box_tree.allocator);
    _ = try ifc.margins.addOne(box_tree.allocator);
    return @intCast(InlineBoxIndex, old_size);
}

fn createInlineFormattingContext(
    layout: *InlineLayoutContext,
    sc: *StackingContexts,
    computer: *StyleComputer,
    box_tree: *BoxTree,
    ifc: *InlineFormattingContext,
) Error!void {
    ifc.font = computer.root_font.font;
    {
        const initial_interval = computer.intervals.items[computer.intervals.items.len - 1];
        ifc.ensureTotalCapacity(box_tree.allocator, initial_interval.end - initial_interval.begin + 1) catch {};
    }

    try ifcPushRootInlineBox(layout, box_tree, ifc);
    while (true) {
        const interval = &computer.intervals.items[computer.intervals.items.len - 1];
        if (layout.inline_box_depth == 0) {
            if (interval.begin != interval.end) {
                const should_terminate = try ifcRunOnce(layout, sc, computer, interval, box_tree, ifc);
                if (should_terminate) break;
            } else break;
        } else {
            if (interval.begin != interval.end) {
                const should_terminate = try ifcRunOnce(layout, sc, computer, interval, box_tree, ifc);
                assert(!should_terminate);
            } else {
                try ifcPopInlineBox(layout, computer, box_tree, ifc);
            }
        }
    }
    try ifcPopRootInlineBox(layout, box_tree, ifc);

    try ifc.metrics.resize(box_tree.allocator, ifc.glyph_indeces.items.len);
    ifcSolveMetrics(box_tree, ifc);
}

fn ifcPushRootInlineBox(layout: *InlineLayoutContext, box_tree: *BoxTree, ifc: *InlineFormattingContext) !void {
    assert(layout.inline_box_depth == 0);
    const root_inline_box_index = try createInlineBox(box_tree, ifc);
    rootInlineBoxSetData(ifc, root_inline_box_index);
    try ifcAddBoxStart(box_tree, ifc, root_inline_box_index);
    try layout.index.append(layout.allocator, root_inline_box_index);
}

fn ifcPopRootInlineBox(layout: *InlineLayoutContext, box_tree: *BoxTree, ifc: *InlineFormattingContext) !void {
    assert(layout.inline_box_depth == 0);
    const root_inline_box_index = layout.index.pop();
    try ifcAddBoxEnd(box_tree, ifc, root_inline_box_index);
}

/// A return value of true means that a terminating element was encountered.
fn ifcRunOnce(
    layout: *InlineLayoutContext,
    sc: *StackingContexts,
    computer: *StyleComputer,
    interval: *StyleComputer.Interval,
    box_tree: *BoxTree,
    ifc: *InlineFormattingContext,
) !bool {
    const element = interval.begin;
    const skip = computer.element_tree_skips[element];

    computer.setElementDirectChild(.box_gen, element);
    const specified = computer.getSpecifiedValue(.box_gen, .box_style);
    const computed = solveBoxStyle(specified, .NonRoot);
    // TODO: Check position and float properties
    switch (computed.display) {
        .text => {
            assert(skip == 1);
            interval.begin += skip;
            box_tree.element_index_to_generated_box[element] = .text;
            const text = computer.getText();
            // TODO: Do proper font matching.
            if (ifc.font == hb.hb_font_get_empty()) @panic("TODO: Found text, but no font was specified.");
            try ifcAddText(box_tree, ifc, text, ifc.font);
        },
        .inline_ => {
            interval.begin += skip;
            const inline_box_index = try createInlineBox(box_tree, ifc);
            try inlineBoxSetData(layout, computer, ifc, inline_box_index);

            box_tree.element_index_to_generated_box[element] = .{ .inline_box = .{ .ifc_index = layout.result.ifc_index, .index = inline_box_index } };
            computer.setComputedValue(.box_gen, .box_style, computed);
            { // TODO: Grabbing useless data to satisfy inheritance...
                const data = .{
                    .content_width = computer.getSpecifiedValue(.box_gen, .content_width),
                    .content_height = computer.getSpecifiedValue(.box_gen, .content_height),
                    .z_index = computer.getSpecifiedValue(.box_gen, .z_index),
                    .font = computer.getSpecifiedValue(.box_gen, .font),
                };
                computer.setComputedValue(.box_gen, .content_width, data.content_width);
                computer.setComputedValue(.box_gen, .content_height, data.content_height);
                computer.setComputedValue(.box_gen, .z_index, data.z_index);
                computer.setComputedValue(.box_gen, .font, data.font);
            }

            try ifcAddBoxStart(box_tree, ifc, inline_box_index);

            if (skip != 1) {
                layout.inline_box_depth += 1;
                try layout.index.append(layout.allocator, inline_box_index);
                try computer.pushElement(.box_gen);
            } else {
                // Optimized path for inline boxes with no children.
                // It is a shorter version of ifcPopInlineBox.
                try ifcAddBoxEnd(box_tree, ifc, inline_box_index);
            }
        },
        .inline_block => {
            interval.begin += skip;
            computer.setComputedValue(.box_gen, .box_style, computed);
            const used_sizes = try makeInlineBlock(
                computer,
                layout.containing_block_width,
                layout.containing_block_height,
            );

            if (!used_sizes.isAutoBitSet(.inline_size)) {
                const z_index = computer.getSpecifiedValue(.box_gen, .z_index);
                computer.setComputedValue(.box_gen, .z_index, z_index);
                // TODO: Grabbing useless data to satisfy inheritance...
                const font = computer.getSpecifiedValue(.box_gen, .font);
                computer.setComputedValue(.box_gen, .font, font);
                try computer.pushElement(.box_gen);

                const block = try createBlock(box_tree);
                block.skip.* = undefined;
                block.properties.* = .{};
                flowBlockSetData(used_sizes, block.box_offsets, block.borders, block.margins);

                const stacking_context_type: StackingContexts.Data = switch (computed.position) {
                    .static => StackingContexts.Data{ .is_non_parent = try sc.createStackingContext(box_tree, block.index, 0) },
                    // TODO: Position the block using the values of the 'inset' family of properties.
                    .relative => switch (z_index.z_index) {
                        .integer => |integer| StackingContexts.Data{ .is_parent = try sc.createStackingContext(box_tree, block.index, integer) },
                        .auto => StackingContexts.Data{ .is_non_parent = try sc.createStackingContext(box_tree, block.index, 0) },
                        .initial, .inherit, .unset, .undeclared => unreachable,
                    },
                    .absolute => @panic("TODO: absolute positioning"),
                    .fixed => @panic("TODO: fixed positioning"),
                    .sticky => @panic("TODO: sticky positioning"),
                    .initial, .inherit, .unset, .undeclared => unreachable,
                };
                try sc.pushStackingContext(stacking_context_type);

                var child_layout = BlockLayoutContext{ .allocator = layout.allocator };
                defer child_layout.deinit();
                try pushContainingBlock(&child_layout, layout.containing_block_width, layout.containing_block_height);
                try pushFlowBlock(&child_layout, block.index, used_sizes);

                try runFully(&child_layout, sc, computer, box_tree);

                box_tree.element_index_to_generated_box[element] = .{ .block_box = block.index };
            } else {
                // TODO: Create a stacking context
                { // TODO: Grabbing useless data to satisfy inheritance...
                    const specified_z_index = computer.getSpecifiedValue(.box_gen, .z_index);
                    computer.setComputedValue(.box_gen, .z_index, specified_z_index);
                    const specified_font = computer.getSpecifiedValue(.box_gen, .font);
                    computer.setComputedValue(.box_gen, .font, specified_font);
                }

                const available_width = layout.containing_block_width -
                    (used_sizes.margin_inline_start_untagged + used_sizes.margin_inline_end_untagged +
                    used_sizes.border_inline_start + used_sizes.border_inline_end +
                    used_sizes.padding_inline_start + used_sizes.padding_inline_end);
                var stf_layout = try ShrinkToFitLayoutContext.initFlow(layout.allocator, computer, used_sizes, available_width);
                defer stf_layout.deinit();
                try shrinkToFitLayout(&stf_layout, sc, computer, box_tree);
            }

            const generated_box = box_tree.element_index_to_generated_box[element];
            const block_box_index = generated_box.block_box;
            layout.result.total_inline_block_skip += box_tree.blocks.skips.items[block_box_index];
            try ifcAddInlineBlock(box_tree, ifc, block_box_index);
        },
        .block => {
            if (layout.inline_box_depth == 0) {
                return true;
            } else {
                @panic("TODO: Blocks within inline contexts");
                //try ifc.glyph_indeces.appendSlice(box_tree.allocator, &.{ 0, undefined });
            }
        },
        .none => {
            interval.begin += skip;
            std.mem.set(GeneratedBox, box_tree.element_index_to_generated_box[element .. element + skip], .none);
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }

    return false;
}

fn ifcPopInlineBox(layout: *InlineLayoutContext, computer: *StyleComputer, box_tree: *BoxTree, ifc: *InlineFormattingContext) !void {
    layout.inline_box_depth -= 1;
    const inline_box_index = layout.index.pop();
    try ifcAddBoxEnd(box_tree, ifc, inline_box_index);
    computer.popElement(.box_gen);
}

fn ifcAddBoxStart(box_tree: *BoxTree, ifc: *InlineFormattingContext, inline_box_index: InlineBoxIndex) !void {
    const glyphs = [2]GlyphIndex{ 0, InlineFormattingContext.Special.encodeBoxStart(inline_box_index) };
    try ifc.glyph_indeces.appendSlice(box_tree.allocator, &glyphs);
}

fn ifcAddBoxEnd(box_tree: *BoxTree, ifc: *InlineFormattingContext, inline_box_index: InlineBoxIndex) !void {
    const glyphs = [2]GlyphIndex{ 0, InlineFormattingContext.Special.encodeBoxEnd(inline_box_index) };
    try ifc.glyph_indeces.appendSlice(box_tree.allocator, &glyphs);
}

fn ifcAddInlineBlock(box_tree: *BoxTree, ifc: *InlineFormattingContext, block_box_index: BlockBoxIndex) !void {
    const glyphs = [2]GlyphIndex{ 0, InlineFormattingContext.Special.encodeInlineBlock(block_box_index) };
    try ifc.glyph_indeces.appendSlice(box_tree.allocator, &glyphs);
}

fn ifcAddLineBreak(box_tree: *BoxTree, ifc: *InlineFormattingContext) !void {
    const glyphs = [2]GlyphIndex{ 0, InlineFormattingContext.Special.encodeLineBreak() };
    try ifc.glyph_indeces.appendSlice(box_tree.allocator, &glyphs);
}

fn ifcAddText(box_tree: *BoxTree, ifc: *InlineFormattingContext, text: zss.values.Text, font: *hb.hb_font_t) !void {
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
                try ifcEndTextRun(box_tree, ifc, text, buffer, font, run_begin, run_end);
                try ifcAddLineBreak(box_tree, ifc);
                run_begin = run_end + 1;
            },
            '\r' => {
                try ifcEndTextRun(box_tree, ifc, text, buffer, font, run_begin, run_end);
                try ifcAddLineBreak(box_tree, ifc);
                run_end += @boolToInt(run_end + 1 < text.len and text[run_end + 1] == '\n');
                run_begin = run_end + 1;
            },
            '\t' => {
                try ifcEndTextRun(box_tree, ifc, text, buffer, font, run_begin, run_end);
                run_begin = run_end + 1;
                // TODO tab size should be determined by the 'tab-size' property
                const tab_size = 8;
                hb.hb_buffer_add_latin1(buffer, " " ** tab_size, tab_size, 0, tab_size);
                if (hb.hb_buffer_allocation_successful(buffer) == 0) return error.OutOfMemory;
                try ifcAddTextRun(box_tree, ifc, buffer, font);
                assert(hb.hb_buffer_set_length(buffer, 0) != 0);
            },
            else => {},
        }
    }

    try ifcEndTextRun(box_tree, ifc, text, buffer, font, run_begin, run_end);
}

fn ifcEndTextRun(box_tree: *BoxTree, ifc: *InlineFormattingContext, text: zss.values.Text, buffer: *hb.hb_buffer_t, font: *hb.hb_font_t, run_begin: usize, run_end: usize) !void {
    if (run_end > run_begin) {
        hb.hb_buffer_add_latin1(buffer, text.ptr, @intCast(c_int, text.len), @intCast(c_uint, run_begin), @intCast(c_int, run_end - run_begin));
        if (hb.hb_buffer_allocation_successful(buffer) == 0) return error.OutOfMemory;
        try ifcAddTextRun(box_tree, ifc, buffer, font);
        assert(hb.hb_buffer_set_length(buffer, 0) != 0);
    }
}

fn ifcAddTextRun(box_tree: *BoxTree, ifc: *InlineFormattingContext, buffer: *hb.hb_buffer_t, font: *hb.hb_font_t) !void {
    hb.hb_shape(font, buffer, null, 0);
    const glyph_infos = blk: {
        var n: c_uint = 0;
        const p = hb.hb_buffer_get_glyph_infos(buffer, &n);
        break :blk p[0..n];
    };

    // Allocate twice as much so that special glyph indeces always have space
    try ifc.glyph_indeces.ensureUnusedCapacity(box_tree.allocator, 2 * glyph_infos.len);

    for (glyph_infos) |info| {
        const glyph_index: GlyphIndex = info.codepoint;
        ifc.glyph_indeces.appendAssumeCapacity(glyph_index);
        if (glyph_index == 0) {
            ifc.glyph_indeces.appendAssumeCapacity(InlineFormattingContext.Special.encodeZeroGlyphIndex());
        }
    }
}

fn rootInlineBoxSetData(ifc: *InlineFormattingContext, inline_box_index: InlineBoxIndex) void {
    ifc.inline_start.items[inline_box_index] = .{ .border = 0, .padding = 0, .border_color_rgba = 0 };
    ifc.inline_end.items[inline_box_index] = .{ .border = 0, .padding = 0, .border_color_rgba = 0 };
    ifc.block_start.items[inline_box_index] = .{ .border = 0, .padding = 0, .border_color_rgba = 0 };
    ifc.block_end.items[inline_box_index] = .{ .border = 0, .padding = 0, .border_color_rgba = 0 };
    ifc.margins.items[inline_box_index] = .{ .start = 0, .end = 0 };
}

fn inlineBoxSetData(layout: *InlineLayoutContext, computer: *StyleComputer, ifc: *InlineFormattingContext, inline_box_index: InlineBoxIndex) !void {
    // TODO: Also use the logical properties ('padding-inline-start', 'border-block-end', etc.).
    const specified = .{
        .horizontal_edges = computer.getSpecifiedValue(.box_gen, .horizontal_edges),
        .vertical_edges = computer.getSpecifiedValue(.box_gen, .vertical_edges),
        .border_styles = computer.getSpecifiedValue(.box_gen, .border_styles),
    };

    var computed: struct {
        horizontal_edges: zss.properties.BoxEdges,
        vertical_edges: zss.properties.BoxEdges,
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
            used.margin_inline_start = percentage(value, layout.percentage_base_unit);
        },
        .auto => {
            computed.horizontal_edges.margin_start = .auto;
            used.margin_inline_start = 0;
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
    {
        const multiplier = borderWidthMultiplier(specified.border_styles.left);
        switch (specified.horizontal_edges.border_start) {
            .px => |value| {
                const width = value * multiplier;
                computed.horizontal_edges.border_start = .{ .px = width };
                used.border_inline_start = try positiveLength(.px, width);
            },
            .thin => {
                const width = borderWidth(.thin) * multiplier;
                computed.horizontal_edges.border_start = .{ .px = width };
                used.border_inline_start = positiveLength(.px, width) catch unreachable;
            },
            .medium => {
                const width = borderWidth(.medium) * multiplier;
                computed.horizontal_edges.border_start = .{ .px = width };
                used.border_inline_start = positiveLength(.px, width) catch unreachable;
            },
            .thick => {
                const width = borderWidth(.thick) * multiplier;
                computed.horizontal_edges.border_start = .{ .px = width };
                used.border_inline_start = positiveLength(.px, width) catch unreachable;
            },
            .initial, .inherit, .unset, .undeclared => unreachable,
        }
    }
    switch (specified.horizontal_edges.padding_start) {
        .px => |value| {
            computed.horizontal_edges.padding_start = .{ .px = value };
            used.padding_inline_start = try positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.horizontal_edges.padding_start = .{ .percentage = value };
            used.padding_inline_start = try positivePercentage(value, layout.percentage_base_unit);
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
    switch (specified.horizontal_edges.margin_end) {
        .px => |value| {
            computed.horizontal_edges.margin_end = .{ .px = value };
            used.margin_inline_end = length(.px, value);
        },
        .percentage => |value| {
            computed.horizontal_edges.margin_end = .{ .percentage = value };
            used.margin_inline_end = percentage(value, layout.percentage_base_unit);
        },
        .auto => {
            computed.horizontal_edges.margin_end = .auto;
            used.margin_inline_end = 0;
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
    {
        const multiplier = borderWidthMultiplier(specified.border_styles.right);
        switch (specified.horizontal_edges.border_end) {
            .px => |value| {
                const width = value * multiplier;
                computed.horizontal_edges.border_end = .{ .px = width };
                used.border_inline_end = try positiveLength(.px, width);
            },
            .thin => {
                const width = borderWidth(.thin) * multiplier;
                computed.horizontal_edges.border_end = .{ .px = width };
                used.border_inline_end = positiveLength(.px, width) catch unreachable;
            },
            .medium => {
                const width = borderWidth(.medium) * multiplier;
                computed.horizontal_edges.border_end = .{ .px = width };
                used.border_inline_end = positiveLength(.px, width) catch unreachable;
            },
            .thick => {
                const width = borderWidth(.thick) * multiplier;
                computed.horizontal_edges.border_end = .{ .px = width };
                used.border_inline_end = positiveLength(.px, width) catch unreachable;
            },
            .initial, .inherit, .unset, .undeclared => unreachable,
        }
    }
    switch (specified.horizontal_edges.padding_end) {
        .px => |value| {
            computed.horizontal_edges.padding_end = .{ .px = value };
            used.padding_inline_end = try positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.horizontal_edges.padding_end = .{ .percentage = value };
            used.padding_inline_end = try positivePercentage(value, layout.percentage_base_unit);
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }

    {
        const multiplier = borderWidthMultiplier(specified.border_styles.top);
        switch (specified.vertical_edges.border_start) {
            .px => |value| {
                const width = value * multiplier;
                computed.vertical_edges.border_start = .{ .px = width };
                used.border_block_start = try positiveLength(.px, width);
            },
            .thin => {
                const width = borderWidth(.thin) * multiplier;
                computed.vertical_edges.border_start = .{ .px = width };
                used.border_block_start = positiveLength(.px, width) catch unreachable;
            },
            .medium => {
                const width = borderWidth(.medium) * multiplier;
                computed.vertical_edges.border_start = .{ .px = width };
                used.border_block_start = positiveLength(.px, width) catch unreachable;
            },
            .thick => {
                const width = borderWidth(.thick) * multiplier;
                computed.vertical_edges.border_start = .{ .px = width };
                used.border_block_start = positiveLength(.px, width) catch unreachable;
            },
            .initial, .inherit, .unset, .undeclared => unreachable,
        }
    }
    switch (specified.vertical_edges.padding_start) {
        .px => |value| {
            computed.vertical_edges.padding_start = .{ .px = value };
            used.padding_block_start = try positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.vertical_edges.padding_start = .{ .percentage = value };
            used.padding_block_start = try positivePercentage(value, layout.percentage_base_unit);
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
    {
        const multiplier = borderWidthMultiplier(specified.border_styles.bottom);
        switch (specified.vertical_edges.border_end) {
            .px => |value| {
                const width = value * multiplier;
                computed.vertical_edges.border_end = .{ .px = width };
                used.border_block_end = try positiveLength(.px, width);
            },
            .thin => {
                const width = borderWidth(.thin) * multiplier;
                computed.vertical_edges.border_end = .{ .px = width };
                used.border_block_end = positiveLength(.px, width) catch unreachable;
            },
            .medium => {
                const width = borderWidth(.medium) * multiplier;
                computed.vertical_edges.border_end = .{ .px = width };
                used.border_block_end = positiveLength(.px, width) catch unreachable;
            },
            .thick => {
                const width = borderWidth(.thick) * multiplier;
                computed.vertical_edges.border_end = .{ .px = width };
                used.border_block_end = positiveLength(.px, width) catch unreachable;
            },
            .initial, .inherit, .unset, .undeclared => unreachable,
        }
    }
    switch (specified.vertical_edges.padding_end) {
        .px => |value| {
            computed.vertical_edges.padding_end = .{ .px = value };
            used.padding_block_end = try positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.vertical_edges.padding_end = .{ .percentage = value };
            used.padding_block_end = try positivePercentage(value, layout.percentage_base_unit);
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }

    computed.vertical_edges.margin_start = specified.vertical_edges.margin_start;
    computed.vertical_edges.margin_end = specified.vertical_edges.margin_end;

    computer.setComputedValue(.box_gen, .horizontal_edges, computed.horizontal_edges);
    computer.setComputedValue(.box_gen, .vertical_edges, computed.vertical_edges);
    computer.setComputedValue(.box_gen, .border_styles, specified.border_styles);

    ifc.inline_start.items[inline_box_index] = .{ .border = used.border_inline_start, .padding = used.padding_inline_start };
    ifc.inline_end.items[inline_box_index] = .{ .border = used.border_inline_end, .padding = used.padding_inline_end };
    ifc.block_start.items[inline_box_index] = .{ .border = used.border_block_start, .padding = used.padding_block_start };
    ifc.block_end.items[inline_box_index] = .{ .border = used.border_block_end, .padding = used.padding_block_end };
    ifc.margins.items[inline_box_index] = .{ .start = used.margin_inline_start, .end = used.margin_inline_end };
}

fn ifcSolveMetrics(box_tree: *BoxTree, ifc: *InlineFormattingContext) void {
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
                    setMetricsInlineBlock(metrics, box_tree, block_box_index);
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

fn setMetricsInlineBlock(metrics: *InlineFormattingContext.Metrics, box_tree: *BoxTree, block_box_index: BlockBoxIndex) void {
    const box_offsets = box_tree.blocks.box_offsets.items[block_box_index];
    const margins = box_tree.blocks.margins.items[block_box_index];

    const width = box_offsets.border_size.w;
    const advance = width + margins.left + margins.right;
    metrics.* = .{ .offset = margins.left, .advance = advance, .width = width };
}

pub fn solveBoxStyle(specified: zss.properties.BoxStyle, comptime is_root: IsRoot) zss.properties.BoxStyle {
    var computed: zss.properties.BoxStyle = .{
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
    } else if (is_root == .Root) {
        // TODO: There should be a slightly different version of this function for the root element. (See rule 4 of secion 9.7)
        computed.display = @"CSS2.2Section9.7Table"(specified.display);
    } else {
        computed.display = specified.display;
    }
    return computed;
}

/// Given a specified value for 'display', returns the computed value according to the table found in section 9.7 of CSS2.2.
fn @"CSS2.2Section9.7Table"(display: zss.values.Display) zss.values.Display {
    // TODO: This is incomplete, fill in the rest when more values of the 'display' property are supported.
    // TODO: There should be a slightly different version of this switch table for the root element. (See rule 4 of secion 9.7)
    return switch (display) {
        .inline_, .inline_block, .text => .block,
        .initial, .inherit, .unset, .undeclared => unreachable,
        else => display,
    };
}

fn solveBorderColors(border_colors: zss.properties.BorderColors, current_color: used_values.Color) used_values.BorderColor {
    return used_values.BorderColor{
        .left_rgba = color(border_colors.left, current_color),
        .right_rgba = color(border_colors.right, current_color),
        .top_rgba = color(border_colors.top, current_color),
        .bottom_rgba = color(border_colors.bottom, current_color),
    };
}

fn solveBorderStyles(border_styles: zss.properties.BorderStyles) void {
    const solveOne = struct {
        fn f(border_style: zss.values.BorderStyle) void {
            switch (border_style) {
                .none, .hidden, .solid => {},
                .initial, .inherit, .unset, .undeclared => unreachable,
                else => std.debug.panic("TODO: border-style: {s}", .{@tagName(border_style)}),
            }
        }
    }.f;

    inline for (std.meta.fields(zss.properties.BorderStyles)) |field_info| {
        solveOne(@field(border_styles, field_info.name));
    }
}

fn solveBackground1(bg: zss.properties.Background1, current_color: used_values.Color) used_values.Background1 {
    return used_values.Background1{
        .color_rgba = color(bg.color, current_color),
        .clip = switch (bg.clip) {
            .border_box => .Border,
            .padding_box => .Padding,
            .content_box => .Content,
            .initial, .inherit, .unset, .undeclared => unreachable,
        },
    };
}

fn solveBackground2(bg: zss.properties.Background2, box_offsets: *const used_values.BoxOffsets, borders: *const used_values.Borders) !used_values.Background2 {
    var object = switch (bg.image) {
        .object => |object| object,
        .none => return used_values.Background2{},
        .initial, .inherit, .unset, .undeclared => unreachable,
    };

    const border_width = box_offsets.border_size.w;
    const border_height = box_offsets.border_size.h;
    const padding_width = border_width - borders.left - borders.right;
    const padding_height = border_height - borders.top - borders.bottom;
    const content_width = box_offsets.content_size.w;
    const content_height = box_offsets.content_size.h;
    const positioning_area: struct { origin: used_values.Background2.Origin, width: ZssUnit, height: ZssUnit } = switch (bg.origin) {
        .border_box => .{ .origin = .Border, .width = border_width, .height = border_height },
        .padding_box => .{ .origin = .Padding, .width = padding_width, .height = padding_height },
        .content_box => .{ .origin = .Content, .width = content_width, .height = content_height },
        .initial, .inherit, .unset, .undeclared => unreachable,
    };

    const NaturalSize = struct {
        width: ZssUnit,
        height: ZssUnit,
        has_aspect_ratio: bool,

        fn init(obj: *zss.values.BackgroundImage.Object) !@This() {
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
        .initial, .inherit, .unset, .undeclared => unreachable,
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
        .initial, .inherit, .unset, .undeclared => unreachable,
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
        .initial, .inherit, .unset, .undeclared => unreachable,
    };

    return used_values.Background2{
        .image = object.data,
        .origin = positioning_area.origin,
        .position = position,
        .size = size,
        .repeat = repeat,
    };
}
