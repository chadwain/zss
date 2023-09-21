const std = @import("std");
const assert = std.debug.assert;
const panic = std.debug.panic;
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const ArrayListAlignedUnmanaged = std.ArrayListAlignedUnmanaged;
const MultiArrayList = std.MultiArrayList;

const zss = @import("../../zss.zig");
const aggregates = zss.values.aggregates;
const root_element = @as(zss.ElementIndex, 0);

const solve = @import("./solve.zig");
const inline_layout = @import("./inline.zig");
const StyleComputer = @import("./StyleComputer.zig");
const StackingContexts = @import("./StackingContexts.zig");

const used_values = @import("./used_values.zig");
const ZssUnit = used_values.ZssUnit;
const ZssSize = used_values.ZssSize;
const ZssVector = used_values.ZssVector;
const units_per_pixel = used_values.units_per_pixel;
const BlockBoxIndex = used_values.BlockBoxIndex;
const initial_containing_block = @as(BlockBoxIndex, 0);
const BlockBox = used_values.BlockBox;
const BlockBoxSkip = used_values.BlockBoxSkip;
const BlockSubtree = used_values.BlockSubtree;
const BlockSubtreeIndex = used_values.SubtreeIndex;
const initial_subtree = @as(BlockSubtreeIndex, 0);
const BlockBoxTree = used_values.BlockBoxTree;
const StackingContextIndex = used_values.StackingContextIndex;
const GeneratedBox = used_values.GeneratedBox;
const BoxTree = used_values.BoxTree;

const hb = @import("harfbuzz");

const LayoutMode = enum {
    InitialContainingBlock,
    Flow,
    ContainingBlock,
};

pub const UsedContentHeight = struct {
    height: ?ZssUnit,
    min_height: ZssUnit,
    max_height: ZssUnit,
};

pub const BlockLayoutContext = struct {
    allocator: Allocator,

    initial_containing_block_action: enum { Push, Pop } = .Push,
    layout_mode: ArrayListUnmanaged(LayoutMode) = .{},

    subtree: ArrayListUnmanaged(BlockSubtreeIndex) = .{},
    index: ArrayListUnmanaged(BlockBoxIndex) = .{},
    skip: ArrayListUnmanaged(BlockBoxSkip) = .{},

    width: ArrayListUnmanaged(ZssUnit) = .{},
    auto_height: ArrayListUnmanaged(ZssUnit) = .{},
    heights: ArrayListUnmanaged(UsedContentHeight) = .{},

    pub fn deinit(self: *BlockLayoutContext) void {
        self.layout_mode.deinit(self.allocator);

        self.subtree.deinit(self.allocator);
        self.index.deinit(self.allocator);
        self.skip.deinit(self.allocator);

        self.width.deinit(self.allocator);
        self.auto_height.deinit(self.allocator);
        self.heights.deinit(self.allocator);
    }
};

pub fn mainLoop(layout: *BlockLayoutContext, sc: *StackingContexts, computer: *StyleComputer, box_tree: *BoxTree) !void {
    while (layout.layout_mode.items.len > 0) {
        try mainLoopOneIteration(layout, sc, computer, box_tree);
    }
}

fn mainLoopOneIteration(layout: *BlockLayoutContext, sc: *StackingContexts, computer: *StyleComputer, box_tree: *BoxTree) !void {
    const layout_mode = layout.layout_mode.items[layout.layout_mode.items.len - 1];
    switch (layout_mode) {
        .InitialContainingBlock => switch (layout.initial_containing_block_action) {
            .Push => {
                layout.initial_containing_block_action = .Pop;
                if (computer.root_element.eqlNull()) return;

                const element = computer.root_element;
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
                    .box_style = solve.boxStyle(specified.box_style, .Root),
                };
                computer.setComputedValue(.box_gen, .box_style, computed.box_style);

                const subtree_index = layout.subtree.items[layout.subtree.items.len - 1];
                const containing_block_width = layout.width.items[layout.width.items.len - 1];
                const containing_block_height = layout.heights.items[layout.heights.items.len - 1].height;

                switch (computed.box_style.display) {
                    .block => {
                        const box = try makeFlowBlock(layout, computer, box_tree, subtree_index, containing_block_width, containing_block_height);
                        try box_tree.element_to_generated_box.putNoClobber(box_tree.allocator, element, box);

                        const z_index = computer.getSpecifiedValue(.box_gen, .z_index); // TODO: Useless info
                        computer.setComputedValue(.box_gen, .z_index, z_index);
                        const stacking_context = try StackingContexts.createRootStackingContext(box_tree, box.block_box, 0);
                        try sc.pushStackingContext(.is_parent, stacking_context.index);
                        box_tree.blocks.subtrees.items[box.block_box.subtree].type.items[box.block_box.index].block.stacking_context = stacking_context.ref;

                        try computer.pushElement(.box_gen);
                    },
                    .none => {},
                    .inline_, .inline_block, .text => unreachable,
                    .initial, .inherit, .unset, .undeclared => unreachable,
                }
            },
            .Pop => popInitialContainingBlock(layout, box_tree),
        },
        .Flow => {
            const element_ptr = &computer.child_stack.items[computer.child_stack.items.len - 1];
            if (!element_ptr.eqlNull()) {
                const element = element_ptr.*;
                computer.setElementDirectChild(.box_gen, element);

                const font = computer.getSpecifiedValue(.box_gen, .font);
                computer.setComputedValue(.box_gen, .font, font);

                const specified = .{
                    .box_style = computer.getSpecifiedValue(.box_gen, .box_style),
                };
                const computed = .{
                    .box_style = solve.boxStyle(specified.box_style, .NonRoot),
                };
                computer.setComputedValue(.box_gen, .box_style, computed.box_style);

                const subtree_index = layout.subtree.items[layout.subtree.items.len - 1];
                const containing_block_width = layout.width.items[layout.width.items.len - 1];
                const containing_block_height = layout.heights.items[layout.heights.items.len - 1].height;

                switch (computed.box_style.display) {
                    .block => {
                        const box = try makeFlowBlock(layout, computer, box_tree, subtree_index, containing_block_width, containing_block_height);
                        try box_tree.element_to_generated_box.putNoClobber(box_tree.allocator, element, box);
                        const block_info = &box_tree.blocks.subtrees.items[box.block_box.subtree].type.items[box.block_box.index].block;

                        const specified_z_index = computer.getSpecifiedValue(.box_gen, .z_index);
                        computer.setComputedValue(.box_gen, .z_index, specified_z_index);
                        switch (computed.box_style.position) {
                            .static => {
                                try sc.pushStackingContext(.none, {});
                                block_info.stacking_context = null;
                            },
                            // TODO: Position the block using the values of the 'inset' family of properties.
                            .relative => switch (specified_z_index.z_index) {
                                .integer => |z_index| {
                                    const stacking_context = try sc.createStackingContext(box_tree, box.block_box, z_index);
                                    try sc.pushStackingContext(.is_parent, stacking_context.index);
                                    block_info.stacking_context = stacking_context.ref;
                                },
                                .auto => {
                                    const stacking_context = try sc.createStackingContext(box_tree, box.block_box, 0);
                                    try sc.pushStackingContext(.is_non_parent, stacking_context.index);
                                    block_info.stacking_context = stacking_context.ref;
                                },
                                .initial, .inherit, .unset, .undeclared => unreachable,
                            },
                            .absolute, .fixed, .sticky => panic("TODO: {s} positioning", .{@tagName(computed.box_style.position)}),
                            .initial, .inherit, .unset, .undeclared => unreachable,
                        }

                        element_ptr.* = computer.element_tree_slice.nextSibling(element);
                        try computer.pushElement(.box_gen);
                    },
                    .inline_, .inline_block, .text => {
                        const subtree = box_tree.blocks.subtrees.items[subtree_index];
                        const ifc_container = try createBlock(box_tree, subtree);

                        const result = try inline_layout.makeInlineFormattingContext(
                            layout.allocator,
                            sc,
                            computer,
                            box_tree,
                            subtree_index,
                            .Normal,
                            containing_block_width,
                            containing_block_height,
                        );
                        const ifc = box_tree.ifcs.items[result.ifc_index];
                        const line_split_result = try inline_layout.splitIntoLineBoxes(layout.allocator, box_tree, subtree, ifc, containing_block_width);
                        ifc.parent_block = .{ .subtree = subtree_index, .index = ifc_container.index };

                        const skip = 1 + result.total_inline_block_skip;
                        const parent_auto_height = &layout.auto_height.items[layout.auto_height.items.len - 1];
                        ifc_container.type.* = .{ .ifc_container = result.ifc_index };
                        ifc_container.skip.* = skip;
                        ifc_container.box_offsets.* = .{
                            .border_pos = .{ .x = 0, .y = parent_auto_height.* },
                            .border_size = .{ .w = containing_block_width, .h = line_split_result.height },
                            .content_pos = .{ .x = 0, .y = 0 },
                            .content_size = .{ .w = containing_block_width, .h = line_split_result.height },
                        };

                        layout.skip.items[layout.skip.items.len - 1] += skip;

                        advanceFlow(parent_auto_height, line_split_result.height);
                    },
                    .none => element_ptr.* = computer.element_tree_slice.nextSibling(element),
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

pub fn makeInitialContainingBlock(layout: *BlockLayoutContext, computer: *StyleComputer, box_tree: *BoxTree) !void {
    const width = @as(ZssUnit, @intCast(computer.viewport_size.width * units_per_pixel));
    const height = @as(ZssUnit, @intCast(computer.viewport_size.height * units_per_pixel));

    const subtree_index = try box_tree.blocks.makeSubtree(box_tree.allocator, .{ .parent = null });
    assert(subtree_index == initial_subtree);
    const subtree = box_tree.blocks.subtrees.items[subtree_index];

    const block = try createBlock(box_tree, subtree);
    assert(block.index == initial_containing_block);
    block.skip.* = undefined;
    block.type.* = .{ .block = .{ .stacking_context = null } };
    block.box_offsets.* = .{
        .border_pos = .{ .x = 0, .y = 0 },
        .content_pos = .{ .x = 0, .y = 0 },
        .content_size = .{ .w = width, .h = height },
        .border_size = .{ .w = width, .h = height },
    };
    block.borders.* = .{};
    block.margins.* = .{};

    try layout.layout_mode.append(layout.allocator, .InitialContainingBlock);
    try layout.subtree.append(layout.allocator, subtree_index);
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
    assert(layout.subtree.pop() == initial_subtree);
    assert(layout.index.pop() == initial_containing_block);
    const skip = layout.skip.pop();
    _ = layout.width.pop();
    _ = layout.heights.pop();

    box_tree.blocks.subtrees.items[initial_subtree].skip.items[initial_containing_block] = skip;
}

pub fn pushContainingBlock(layout: *BlockLayoutContext, width: ZssUnit, height: ?ZssUnit) !void {
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
    subtree_index: BlockSubtreeIndex,
    containing_block_width: ZssUnit,
    containing_block_height: ?ZssUnit,
) !GeneratedBox {
    const subtree = box_tree.blocks.subtrees.items[subtree_index];
    const block = try createBlock(box_tree, subtree);
    block.skip.* = undefined;
    block.type.* = .{ .block = .{ .stacking_context = undefined } };

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

    try pushFlowBlock(layout, subtree_index, block.index, used_sizes);
    // TODO: Returning the subtree_index is redundant
    return GeneratedBox{ .block_box = .{ .subtree = subtree_index, .index = block.index } };
}

pub fn pushFlowBlock(
    layout: *BlockLayoutContext,
    subtree_index: BlockSubtreeIndex,
    block_box_index: BlockBoxIndex,
    used_sizes: FlowBlockUsedSizes,
) !void {
    // The allocations here must have corresponding deallocations in popFlowBlock.
    try layout.layout_mode.append(layout.allocator, .Flow);
    try layout.subtree.append(layout.allocator, subtree_index);
    try layout.index.append(layout.allocator, block_box_index);
    try layout.skip.append(layout.allocator, 1);
    try layout.width.append(layout.allocator, used_sizes.get(.inline_size).?);
    try layout.auto_height.append(layout.allocator, 0);
    try layout.heights.append(layout.allocator, used_sizes.getUsedContentHeight());
}

fn popFlowBlock(layout: *BlockLayoutContext, box_tree: *BoxTree) void {
    // The deallocations here must correspond to allocations in pushFlowBlock.
    assert(layout.layout_mode.pop() == .Flow);
    const subtree_index = layout.subtree.pop();
    const block_box_index = layout.index.pop();
    const skip = layout.skip.pop();
    const width = layout.width.pop();
    const auto_height = layout.auto_height.pop();
    const heights = layout.heights.pop();

    const subtree = box_tree.blocks.subtrees.items[subtree_index];
    subtree.skip.items[block_box_index] = skip;
    const box_offsets = &subtree.box_offsets.items[block_box_index];
    assert(box_offsets.content_size.w == width);
    flowBlockFinishLayout(box_offsets, heights, auto_height);

    const parent_layout_mode = layout.layout_mode.items[layout.layout_mode.items.len - 1];
    switch (parent_layout_mode) {
        .InitialContainingBlock => layout.skip.items[layout.skip.items.len - 1] += skip,
        .Flow => {
            layout.skip.items[layout.skip.items.len - 1] += skip;
            const parent_auto_height = &layout.auto_height.items[layout.auto_height.items.len - 1];
            const margin_bottom = subtree.margins.items[block_box_index].bottom;
            addBlockToFlow(box_offsets, margin_bottom, parent_auto_height);
        },
        .ContainingBlock => {},
    }
}

pub const FlowBlockComputedSizes = struct {
    content_width: aggregates.ContentSize,
    horizontal_edges: aggregates.BoxEdges,
    content_height: aggregates.ContentSize,
    vertical_edges: aggregates.BoxEdges,
};

pub const FlowBlockUsedSizes = struct {
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

    pub const PossiblyAutoField = enum(u4) {
        inline_size = 1,
        margin_inline_start = 2,
        margin_inline_end = 4,
        block_size = 8,
    };

    pub fn set(self: *FlowBlockUsedSizes, comptime field: PossiblyAutoField, value: ZssUnit) void {
        self.auto_bitfield &= (~@intFromEnum(field));
        const clamped_value = switch (field) {
            .inline_size => solve.clampSize(value, self.min_inline_size, self.max_inline_size),
            .margin_inline_start, .margin_inline_end => value,
            .block_size => solve.clampSize(value, self.min_block_size, self.max_block_size),
        };
        @field(self, @tagName(field) ++ "_untagged") = clamped_value;
    }

    pub fn setAuto(self: *FlowBlockUsedSizes, comptime field: PossiblyAutoField) void {
        self.auto_bitfield |= @intFromEnum(field);
        @field(self, @tagName(field) ++ "_untagged") = 0;
    }

    pub fn get(self: FlowBlockUsedSizes, comptime field: PossiblyAutoField) ?ZssUnit {
        return if (self.isFieldAuto(field)) null else @field(self, @tagName(field) ++ "_untagged");
    }

    pub fn inlineSizeAndMarginsAreNotAuto(self: FlowBlockUsedSizes) bool {
        const mask = @intFromEnum(PossiblyAutoField.inline_size) |
            @intFromEnum(PossiblyAutoField.margin_inline_start) |
            @intFromEnum(PossiblyAutoField.margin_inline_end);
        return self.auto_bitfield & mask == 0;
    }

    pub fn isFieldAuto(self: FlowBlockUsedSizes, comptime field: PossiblyAutoField) bool {
        return self.auto_bitfield & @intFromEnum(field) != 0;
    }

    pub fn getUsedContentHeight(self: FlowBlockUsedSizes) UsedContentHeight {
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
    border_styles: aggregates.BorderStyles,
    computed: *FlowBlockComputedSizes,
    used: *FlowBlockUsedSizes,
) !void {
    // TODO: Also use the logical properties ('inline-size', 'border-inline-start', etc.) to determine lengths.

    assert(containing_block_width >= 0);

    {
        const multiplier = solve.borderWidthMultiplier(border_styles.left);
        switch (specified.horizontal_edges.border_start) {
            .px => |value| {
                const width = value * multiplier;
                computed.horizontal_edges.border_start = .{ .px = width };
                used.border_inline_start = try solve.positiveLength(.px, width);
            },
            .thin => {
                const width = solve.borderWidth(.thin) * multiplier;
                computed.horizontal_edges.border_start = .{ .px = width };
                used.border_inline_start = solve.positiveLength(.px, width) catch unreachable;
            },
            .medium => {
                const width = solve.borderWidth(.medium) * multiplier;
                computed.horizontal_edges.border_start = .{ .px = width };
                used.border_inline_start = solve.positiveLength(.px, width) catch unreachable;
            },
            .thick => {
                const width = solve.borderWidth(.thick) * multiplier;
                computed.horizontal_edges.border_start = .{ .px = width };
                used.border_inline_start = solve.positiveLength(.px, width) catch unreachable;
            },
            .initial, .inherit, .unset, .undeclared => unreachable,
        }
    }
    {
        const multiplier = solve.borderWidthMultiplier(border_styles.right);
        switch (specified.horizontal_edges.border_end) {
            .px => |value| {
                const width = value * multiplier;
                computed.horizontal_edges.border_end = .{ .px = width };
                used.border_inline_end = try solve.positiveLength(.px, width);
            },
            .thin => {
                const width = solve.borderWidth(.thin) * multiplier;
                computed.horizontal_edges.border_end = .{ .px = width };
                used.border_inline_end = solve.positiveLength(.px, width) catch unreachable;
            },
            .medium => {
                const width = solve.borderWidth(.medium) * multiplier;
                computed.horizontal_edges.border_end = .{ .px = width };
                used.border_inline_end = solve.positiveLength(.px, width) catch unreachable;
            },
            .thick => {
                const width = solve.borderWidth(.thick) * multiplier;
                computed.horizontal_edges.border_end = .{ .px = width };
                used.border_inline_end = solve.positiveLength(.px, width) catch unreachable;
            },
            .initial, .inherit, .unset, .undeclared => unreachable,
        }
    }
    switch (specified.horizontal_edges.padding_start) {
        .px => |value| {
            computed.horizontal_edges.padding_start = .{ .px = value };
            used.padding_inline_start = try solve.positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.horizontal_edges.padding_start = .{ .percentage = value };
            used.padding_inline_start = try solve.positivePercentage(value, containing_block_width);
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
    switch (specified.horizontal_edges.padding_end) {
        .px => |value| {
            computed.horizontal_edges.padding_end = .{ .px = value };
            used.padding_inline_end = try solve.positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.horizontal_edges.padding_end = .{ .percentage = value };
            used.padding_inline_end = try solve.positivePercentage(value, containing_block_width);
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }

    switch (specified.content_width.min_size) {
        .px => |value| {
            computed.content_width.min_size = .{ .px = value };
            used.min_inline_size = try solve.positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.content_width.min_size = .{ .percentage = value };
            used.min_inline_size = try solve.positivePercentage(value, containing_block_width);
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
    switch (specified.content_width.max_size) {
        .px => |value| {
            computed.content_width.max_size = .{ .px = value };
            used.max_inline_size = try solve.positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.content_width.max_size = .{ .percentage = value };
            used.max_inline_size = try solve.positivePercentage(value, containing_block_width);
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
            used.set(.inline_size, try solve.positiveLength(.px, value));
        },
        .percentage => |value| {
            computed.content_width.size = .{ .percentage = value };
            used.set(.inline_size, try solve.positivePercentage(value, containing_block_width));
        },
        .auto => {
            computed.content_width.size = .auto;
            used.setAuto(.inline_size);
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
    switch (specified.horizontal_edges.margin_start) {
        .px => |value| {
            computed.horizontal_edges.margin_start = .{ .px = value };
            used.set(.margin_inline_start, solve.length(.px, value));
        },
        .percentage => |value| {
            computed.horizontal_edges.margin_start = .{ .percentage = value };
            used.set(.margin_inline_start, solve.percentage(value, containing_block_width));
        },
        .auto => {
            computed.horizontal_edges.margin_start = .auto;
            used.setAuto(.margin_inline_start);
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
    switch (specified.horizontal_edges.margin_end) {
        .px => |value| {
            computed.horizontal_edges.margin_end = .{ .px = value };
            used.set(.margin_inline_end, solve.length(.px, value));
        },
        .percentage => |value| {
            computed.horizontal_edges.margin_end = .{ .percentage = value };
            used.set(.margin_inline_end, solve.percentage(value, containing_block_width));
        },
        .auto => {
            computed.horizontal_edges.margin_end = .auto;
            used.setAuto(.margin_inline_end);
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
}

pub fn flowBlockSolveContentHeight(
    specified: aggregates.ContentSize,
    containing_block_height: ?ZssUnit,
    computed: *aggregates.ContentSize,
    used: *FlowBlockUsedSizes,
) !void {
    if (containing_block_height) |h| assert(h >= 0);

    switch (specified.min_size) {
        .px => |value| {
            computed.min_size = .{ .px = value };
            used.min_block_size = try solve.positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.min_size = .{ .percentage = value };
            used.min_block_size = if (containing_block_height) |s|
                try solve.positivePercentage(value, s)
            else
                0;
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
    switch (specified.max_size) {
        .px => |value| {
            computed.max_size = .{ .px = value };
            used.max_block_size = try solve.positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.max_size = .{ .percentage = value };
            used.max_block_size = if (containing_block_height) |s|
                try solve.positivePercentage(value, s)
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
            used.set(.block_size, try solve.positiveLength(.px, value));
        },
        .percentage => |value| {
            computed.size = .{ .percentage = value };
            if (containing_block_height) |h|
                used.set(.block_size, try solve.positivePercentage(value, h))
            else
                used.setAuto(.block_size);
        },
        .auto => {
            computed.size = .auto;
            used.setAuto(.block_size);
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
}

/// This is an implementation of CSS2§10.5 and CSS2§10.6.3.
pub fn flowBlockSolveVerticalEdges(
    specified: aggregates.BoxEdges,
    containing_block_width: ZssUnit,
    border_styles: aggregates.BorderStyles,
    computed: *aggregates.BoxEdges,
    used: *FlowBlockUsedSizes,
) !void {
    // TODO: Also use the logical properties ('block-size', 'border-block-start', etc.) to determine lengths.

    assert(containing_block_width >= 0);

    {
        const multiplier = solve.borderWidthMultiplier(border_styles.top);
        switch (specified.border_start) {
            .px => |value| {
                const width = value * multiplier;
                computed.border_start = .{ .px = width };
                used.border_block_start = try solve.positiveLength(.px, width);
            },
            .thin => {
                const width = solve.borderWidth(.thin) * multiplier;
                computed.border_start = .{ .px = width };
                used.border_block_start = solve.positiveLength(.px, width) catch unreachable;
            },
            .medium => {
                const width = solve.borderWidth(.medium) * multiplier;
                computed.border_start = .{ .px = width };
                used.border_block_start = solve.positiveLength(.px, width) catch unreachable;
            },
            .thick => {
                const width = solve.borderWidth(.thick) * multiplier;
                computed.border_start = .{ .px = width };
                used.border_block_start = solve.positiveLength(.px, width) catch unreachable;
            },
            .initial, .inherit, .unset, .undeclared => unreachable,
        }
    }
    {
        const multiplier = solve.borderWidthMultiplier(border_styles.bottom);
        switch (specified.border_end) {
            .px => |value| {
                const width = value * multiplier;
                computed.border_end = .{ .px = width };
                used.border_block_end = try solve.positiveLength(.px, width);
            },
            .thin => {
                const width = solve.borderWidth(.thin) * multiplier;
                computed.border_end = .{ .px = width };
                used.border_block_end = solve.positiveLength(.px, width) catch unreachable;
            },
            .medium => {
                const width = solve.borderWidth(.medium) * multiplier;
                computed.border_end = .{ .px = width };
                used.border_block_end = solve.positiveLength(.px, width) catch unreachable;
            },
            .thick => {
                const width = solve.borderWidth(.thick) * multiplier;
                computed.border_end = .{ .px = width };
                used.border_block_end = solve.positiveLength(.px, width) catch unreachable;
            },
            .initial, .inherit, .unset, .undeclared => unreachable,
        }
    }
    switch (specified.padding_start) {
        .px => |value| {
            computed.padding_start = .{ .px = value };
            used.padding_block_start = try solve.positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.padding_start = .{ .percentage = value };
            used.padding_block_start = try solve.positivePercentage(value, containing_block_width);
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
    switch (specified.padding_end) {
        .px => |value| {
            computed.padding_end = .{ .px = value };
            used.padding_block_end = try solve.positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.padding_end = .{ .percentage = value };
            used.padding_block_end = try solve.positivePercentage(value, containing_block_width);
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
    switch (specified.margin_start) {
        .px => |value| {
            computed.margin_start = .{ .px = value };
            used.margin_block_start = solve.length(.px, value);
        },
        .percentage => |value| {
            computed.margin_start = .{ .percentage = value };
            used.margin_block_start = solve.percentage(value, containing_block_width);
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
            used.margin_block_end = solve.length(.px, value);
        },
        .percentage => |value| {
            computed.margin_end = .{ .percentage = value };
            used.margin_block_end = solve.percentage(value, containing_block_width);
        },
        .auto => {
            computed.margin_end = .auto;
            used.margin_block_end = 0;
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
}

/// Changes the used sizes of a flow block that is in normal flow.
/// This implements the constraints described in CSS2.2§10.3.3.
fn flowBlockAdjustWidthAndMargins(used: *FlowBlockUsedSizes, containing_block_width: ZssUnit) void {
    const content_margin_space = containing_block_width -
        (used.border_inline_start + used.border_inline_end + used.padding_inline_start + used.padding_inline_end);
    if (used.inlineSizeAndMarginsAreNotAuto()) {
        // None of the values were auto, so one of the margins must be set according to the other values.
        // TODO the margin that gets set is determined by the 'direction' property
        used.set(.margin_inline_end, content_margin_space - used.inline_size_untagged - used.margin_inline_start_untagged);
    } else if (!used.isFieldAuto(.inline_size)) {
        // 'inline-size' is not auto, but at least one of 'margin-inline-start' and 'margin-inline-end' is.
        // If there is only one "auto", then that value gets the remaining margin space.
        // Else, there are 2 "auto"s, and both values get half the remaining margin space.
        const start = used.isFieldAuto(.margin_inline_start);
        const end = used.isFieldAuto(.margin_inline_end);
        const shr_amount = @intFromBool(start and end);
        const leftover_margin = @max(0, content_margin_space -
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

pub fn flowBlockSetData(
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

pub fn flowBlockFinishLayout(box_offsets: *used_values.BoxOffsets, heights: UsedContentHeight, auto_height: ZssUnit) void {
    const used_height = heights.height orelse solve.clampSize(auto_height, heights.min_height, heights.max_height);
    box_offsets.content_size.h = used_height;
    box_offsets.border_size.h += used_height;
}

pub fn addBlockToFlow(box_offsets: *used_values.BoxOffsets, margin_bottom: ZssUnit, parent_auto_height: *ZssUnit) void {
    const margin_top = box_offsets.border_pos.y;
    box_offsets.border_pos.y += parent_auto_height.*;
    advanceFlow(parent_auto_height, box_offsets.border_size.h + margin_top + margin_bottom);
}

pub fn advanceFlow(parent_auto_height: *ZssUnit, amount: ZssUnit) void {
    parent_auto_height.* += amount;
}

pub const Block = struct {
    index: BlockBoxIndex,
    skip: *BlockBoxSkip,
    box_offsets: *used_values.BoxOffsets,
    borders: *used_values.Borders,
    margins: *used_values.Margins,
    type: *used_values.BlockType,
};

// TODO: Make this return only the index, and move it to layout.zig
pub fn createBlock(box_tree: *BoxTree, subtree: *BlockSubtree) !Block {
    const index = std.math.cast(BlockBoxIndex, subtree.skip.items.len) orelse return error.TooManyBlocks;
    return Block{
        .index = index,
        .skip = try subtree.skip.addOne(box_tree.allocator),
        .box_offsets = try subtree.box_offsets.addOne(box_tree.allocator),
        .borders = try subtree.borders.addOne(box_tree.allocator),
        .margins = try subtree.margins.addOne(box_tree.allocator),
        .type = try subtree.type.addOne(box_tree.allocator),
    };
}
