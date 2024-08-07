const std = @import("std");
const assert = std.debug.assert;
const panic = std.debug.panic;
const Allocator = std.mem.Allocator;
const MultiArrayList = std.MultiArrayList;

const zss = @import("../zss.zig");
const aggregates = zss.properties.aggregates;
const BlockComputedSizes = zss.layout.BlockComputedSizes;
const BlockUsedSizes = zss.layout.BlockUsedSizes;
const Element = zss.ElementTree.Element;
const Inputs = zss.layout.Inputs;
const Stack = zss.util.Stack;

const solve = @import("./solve.zig");
const @"inline" = @import("./inline.zig");
const StyleComputer = @import("./StyleComputer.zig");
const StackingContexts = @import("./StackingContexts.zig");

const used_values = zss.used_values;
const BlockBox = used_values.BlockBox;
const BlockBoxIndex = used_values.BlockBoxIndex;
const BlockBoxSkip = used_values.BlockBoxSkip;
const SubtreeId = used_values.SubtreeId;
const BoxTree = used_values.BoxTree;
const GeneratedBox = used_values.GeneratedBox;
const StackingContext = used_values.StackingContext;
const SubtreeSlice = used_values.BlockSubtree.Slice;
const ZssUnit = used_values.ZssUnit;

pub const Result = struct {
    skip_of_children: BlockBoxSkip,
    auto_height: ZssUnit,
};

pub fn runFlowLayout(
    allocator: Allocator,
    box_tree: *BoxTree,
    sc: *StackingContexts,
    computer: *StyleComputer,
    inputs: Inputs,
    subtree_id: SubtreeId,
    used_sizes: BlockUsedSizes,
) !Result {
    var ctx = Context{ .allocator = allocator, .subtree_id = subtree_id };
    defer ctx.deinit();

    pushMainBlock(&ctx, used_sizes);
    while (ctx.stack.top) |_| {
        try analyzeElement(&ctx, sc, computer, box_tree, inputs);
    }

    return ctx.result;
}

const Context = struct {
    allocator: Allocator,
    subtree_id: SubtreeId,
    result: Result = undefined,
    stack: Stack(StackItem) = .{},

    const StackItem = struct {
        index: BlockBoxIndex,
        skip: BlockBoxSkip,
        used: BlockUsedSizesSlim,
        auto_height: ZssUnit,
    };

    fn deinit(ctx: *Context) void {
        ctx.stack.deinit(ctx.allocator);
    }
};

fn analyzeElement(ctx: *Context, sc: *StackingContexts, computer: *StyleComputer, box_tree: *BoxTree, inputs: Inputs) !void {
    const element = computer.getCurrentElement();
    if (element.eqlNull()) {
        return popBlock(ctx, computer, sc, box_tree);
    }

    const computed_box_style, const effective_display = blk: {
        if (computer.elementCategory(element) == .text) {
            break :blk .{ undefined, .text };
        }

        const specified_box_style = computer.getSpecifiedValue(.box_gen, .box_style);
        const specified_font = computer.getSpecifiedValue(.box_gen, .font);
        const computed_box_style, const effective_display = solve.boxStyle(specified_box_style, .NonRoot);
        computer.setComputedValue(.box_gen, .box_style, computed_box_style);
        computer.setComputedValue(.box_gen, .font, specified_font);
        break :blk .{ computed_box_style, effective_display };
    };

    const parent = &ctx.stack.top.?;
    const containing_block_width = parent.used.inline_size_clamped;
    const containing_block_height = parent.used.block_size;

    switch (effective_display) {
        .block => {
            const used_sizes = solveAllSizes(computer, containing_block_width, containing_block_height);
            const stacking_context = solveStackingContext(computer, computed_box_style.position);
            try pushBlock(ctx, computer, box_tree, sc, element, used_sizes, stacking_context);
        },
        .@"inline", .inline_block, .text => {
            const subtree = box_tree.blocks.subtree(ctx.subtree_id);
            const ifc_container_index = try subtree.appendBlock(box_tree.allocator);

            const result = try @"inline".runInlineLayout(
                ctx.allocator,
                sc,
                computer,
                box_tree,
                ctx.subtree_id,
                .Normal,
                containing_block_width,
                containing_block_height,
                inputs,
            );
            const ifc = box_tree.ifc(result.ifc_id);
            const line_split_result =
                try @"inline".splitIntoLineBoxes(ctx.allocator, box_tree, subtree, ifc, inputs, containing_block_width);
            ifc.parent_block = .{ .subtree = ctx.subtree_id, .index = ifc_container_index };

            const skip = 1 + result.total_inline_block_skip;
            subtree.setIfcContainer(
                result.ifc_id,
                ifc_container_index,
                skip,
                null,
                parent.auto_height,
                containing_block_width,
                line_split_result.height,
            );

            parent.skip += skip;
            advanceFlow(&parent.auto_height, line_split_result.height);
        },
        .none => computer.advanceElement(.box_gen),
    }
}

fn pushMainBlock(ctx: *Context, used_sizes: BlockUsedSizes) void {
    // The allocations here must have corresponding deallocations in popBlock.
    ctx.stack.top = .{
        .index = undefined,
        .skip = 0,
        .used = BlockUsedSizesSlim.fromFull(used_sizes),
        .auto_height = 0,
    };
}

fn pushBlock(
    ctx: *Context,
    computer: *StyleComputer,
    box_tree: *BoxTree,
    sc: *StackingContexts,
    element: Element,
    used_sizes: BlockUsedSizes,
    stacking_context: StackingContexts.Info,
) !void {
    const subtree = box_tree.blocks.subtree(ctx.subtree_id);
    const block_index = try subtree.appendBlock(box_tree.allocator);
    const generated_box = GeneratedBox{ .block_box = .{ .subtree = ctx.subtree_id, .index = block_index } };
    try box_tree.mapElementToBox(element, generated_box);

    // The allocations here must have corresponding deallocations in popBlock.
    try ctx.stack.push(ctx.allocator, .{
        .index = block_index,
        .skip = 1,
        .used = BlockUsedSizesSlim.fromFull(used_sizes),
        .auto_height = 0,
    });
    const stacking_context_id = try sc.push(stacking_context, box_tree, generated_box.block_box);
    try computer.pushElement(.box_gen);

    const width = solveUsedWidth(used_sizes.get(.inline_size).?, used_sizes.min_inline_size, used_sizes.max_inline_size);
    writeBlockDataPart1(subtree.slice(), block_index, used_sizes, width, stacking_context_id);
}

fn popBlock(ctx: *Context, computer: *StyleComputer, sc: *StackingContexts, box_tree: *BoxTree) void {
    // The deallocations here must correspond to allocations in pushBlock.
    const this = ctx.stack.pop();
    const parent = if (ctx.stack.top) |*top| top else {
        ctx.result = .{
            .skip_of_children = this.skip,
            .auto_height = this.auto_height,
        };
        return;
    };

    sc.pop(box_tree);
    computer.popElement(.box_gen);

    const subtree_slice = box_tree.blocks.subtree(ctx.subtree_id).slice();
    const height = solveUsedHeight(this.used.block_size, this.used.min_block_size, this.used.max_block_size, this.auto_height);
    writeBlockDataPart2(subtree_slice, this.index, this.skip, height);

    parent.skip += this.skip;
    addBlockToFlow(subtree_slice, this.index, &parent.auto_height);
}

const BlockUsedSizesSlim = struct {
    inline_size_clamped: ZssUnit,
    block_size: ?ZssUnit,
    min_block_size: ZssUnit,
    max_block_size: ZssUnit,

    fn fromFull(used: BlockUsedSizes) BlockUsedSizesSlim {
        return .{
            .inline_size_clamped = solve.clampSize(used.get(.inline_size).?, used.min_inline_size, used.max_inline_size),
            .block_size = used.get(.block_size),
            .min_block_size = used.min_block_size,
            .max_block_size = used.max_block_size,
        };
    }
};

pub fn solveAllSizes(
    computer: *StyleComputer,
    containing_block_width: ZssUnit,
    containing_block_height: ?ZssUnit,
) BlockUsedSizes {
    const border_styles = computer.getSpecifiedValue(.box_gen, .border_styles);
    const specified_sizes = BlockComputedSizes{
        .content_width = computer.getSpecifiedValue(.box_gen, .content_width),
        .horizontal_edges = computer.getSpecifiedValue(.box_gen, .horizontal_edges),
        .content_height = computer.getSpecifiedValue(.box_gen, .content_height),
        .vertical_edges = computer.getSpecifiedValue(.box_gen, .vertical_edges),
    };

    var computed_sizes: BlockComputedSizes = undefined;
    var used_sizes: BlockUsedSizes = undefined;
    solveWidthAndHorizontalMargins(specified_sizes, containing_block_width, &computed_sizes, &used_sizes);
    solveHorizontalBorderPadding(specified_sizes.horizontal_edges, containing_block_width, border_styles, &computed_sizes.horizontal_edges, &used_sizes);
    solveHeight(specified_sizes.content_height, containing_block_height, &computed_sizes.content_height, &used_sizes);
    solveVerticalEdges(specified_sizes.vertical_edges, containing_block_width, border_styles, &computed_sizes.vertical_edges, &used_sizes);
    adjustWidthAndMargins(&used_sizes, containing_block_width);

    computer.setComputedValue(.box_gen, .content_width, computed_sizes.content_width);
    computer.setComputedValue(.box_gen, .horizontal_edges, computed_sizes.horizontal_edges);
    computer.setComputedValue(.box_gen, .content_height, computed_sizes.content_height);
    computer.setComputedValue(.box_gen, .vertical_edges, computed_sizes.vertical_edges);
    computer.setComputedValue(.box_gen, .border_styles, border_styles);

    return used_sizes;
}

/// Solves the following list of properties according to CSS2§10.2, CSS2§10.3.3, and CSS2§10.4.
/// Properties: 'min-width', 'max-width', 'width', 'margin-left', 'margin-right'
fn solveWidthAndHorizontalMargins(
    specified: BlockComputedSizes,
    containing_block_width: ZssUnit,
    computed: *BlockComputedSizes,
    used: *BlockUsedSizes,
) void {
    // TODO: Also use the logical properties ('inline-size', 'border-inline-start', etc.) to determine lengths.

    assert(containing_block_width >= 0);

    switch (specified.content_width.min_width) {
        .px => |value| {
            computed.content_width.min_width = .{ .px = value };
            used.min_inline_size = solve.positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.content_width.min_width = .{ .percentage = value };
            used.min_inline_size = solve.positivePercentage(value, containing_block_width);
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
    switch (specified.content_width.max_width) {
        .px => |value| {
            computed.content_width.max_width = .{ .px = value };
            used.max_inline_size = solve.positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.content_width.max_width = .{ .percentage = value };
            used.max_inline_size = solve.positivePercentage(value, containing_block_width);
        },
        .none => {
            computed.content_width.max_width = .none;
            used.max_inline_size = std.math.maxInt(ZssUnit);
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }

    switch (specified.content_width.width) {
        .px => |value| {
            computed.content_width.width = .{ .px = value };
            used.set(.inline_size, solve.positiveLength(.px, value));
        },
        .percentage => |value| {
            computed.content_width.width = .{ .percentage = value };
            used.set(.inline_size, solve.positivePercentage(value, containing_block_width));
        },
        .auto => {
            computed.content_width.width = .auto;
            used.setAuto(.inline_size);
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
    switch (specified.horizontal_edges.margin_left) {
        .px => |value| {
            computed.horizontal_edges.margin_left = .{ .px = value };
            used.set(.margin_inline_start, solve.length(.px, value));
        },
        .percentage => |value| {
            computed.horizontal_edges.margin_left = .{ .percentage = value };
            used.set(.margin_inline_start, solve.percentage(value, containing_block_width));
        },
        .auto => {
            computed.horizontal_edges.margin_left = .auto;
            used.setAuto(.margin_inline_start);
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
    switch (specified.horizontal_edges.margin_right) {
        .px => |value| {
            computed.horizontal_edges.margin_right = .{ .px = value };
            used.set(.margin_inline_end, solve.length(.px, value));
        },
        .percentage => |value| {
            computed.horizontal_edges.margin_right = .{ .percentage = value };
            used.set(.margin_inline_end, solve.percentage(value, containing_block_width));
        },
        .auto => {
            computed.horizontal_edges.margin_right = .auto;
            used.setAuto(.margin_inline_end);
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
}

pub fn solveHorizontalBorderPadding(
    specified: aggregates.HorizontalEdges,
    containing_block_width: ZssUnit,
    border_styles: aggregates.BorderStyles,
    computed: *aggregates.HorizontalEdges,
    used: *BlockUsedSizes,
) void {
    assert(containing_block_width >= 0);

    {
        const multiplier = solve.borderWidthMultiplier(border_styles.left);
        switch (specified.border_left) {
            .px => |value| {
                const width = value * multiplier;
                computed.border_left = .{ .px = width };
                used.border_inline_start = solve.positiveLength(.px, width);
            },
            inline .thin, .medium, .thick => |_, tag| {
                const width = solve.borderWidth(tag) * multiplier;
                computed.border_left = .{ .px = width };
                used.border_inline_start = solve.positiveLength(.px, width);
            },
            .initial, .inherit, .unset, .undeclared => unreachable,
        }
    }
    {
        const multiplier = solve.borderWidthMultiplier(border_styles.right);
        switch (specified.border_right) {
            .px => |value| {
                const width = value * multiplier;
                computed.border_right = .{ .px = width };
                used.border_inline_end = solve.positiveLength(.px, width);
            },
            inline .thin, .medium, .thick => |_, tag| {
                const width = solve.borderWidth(tag) * multiplier;
                computed.border_right = .{ .px = width };
                used.border_inline_end = solve.positiveLength(.px, width);
            },
            .initial, .inherit, .unset, .undeclared => unreachable,
        }
    }

    switch (specified.padding_left) {
        .px => |value| {
            computed.padding_left = .{ .px = value };
            used.padding_inline_start = solve.positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.padding_left = .{ .percentage = value };
            used.padding_inline_start = solve.positivePercentage(value, containing_block_width);
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
    switch (specified.padding_right) {
        .px => |value| {
            computed.padding_right = .{ .px = value };
            used.padding_inline_end = solve.positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.padding_right = .{ .percentage = value };
            used.padding_inline_end = solve.positivePercentage(value, containing_block_width);
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
}

pub fn solveHeight(
    specified: aggregates.ContentHeight,
    containing_block_height: ?ZssUnit,
    computed: *aggregates.ContentHeight,
    used: *BlockUsedSizes,
) void {
    if (containing_block_height) |h| assert(h >= 0);

    switch (specified.min_height) {
        .px => |value| {
            computed.min_height = .{ .px = value };
            used.min_block_size = solve.positiveLength(.px, value);
        },

        .percentage => |value| {
            computed.min_height = .{ .percentage = value };
            used.min_block_size = if (containing_block_height) |s|
                solve.positivePercentage(value, s)
            else
                0;
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
    switch (specified.max_height) {
        .px => |value| {
            computed.max_height = .{ .px = value };
            used.max_block_size = solve.positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.max_height = .{ .percentage = value };
            used.max_block_size = if (containing_block_height) |s|
                solve.positivePercentage(value, s)
            else
                std.math.maxInt(ZssUnit);
        },
        .none => {
            computed.max_height = .none;
            used.max_block_size = std.math.maxInt(ZssUnit);
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
    switch (specified.height) {
        .px => |value| {
            computed.height = .{ .px = value };
            used.set(.block_size, solve.positiveLength(.px, value));
        },
        .percentage => |value| {
            computed.height = .{ .percentage = value };
            if (containing_block_height) |h|
                used.set(.block_size, solve.positivePercentage(value, h))
            else
                used.setAuto(.block_size);
        },
        .auto => {
            computed.height = .auto;
            used.setAuto(.block_size);
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
}

/// This is an implementation of CSS2§10.5 and CSS2§10.6.3.
pub fn solveVerticalEdges(
    specified: aggregates.VerticalEdges,
    containing_block_width: ZssUnit,
    border_styles: aggregates.BorderStyles,
    computed: *aggregates.VerticalEdges,
    used: *BlockUsedSizes,
) void {
    // TODO: Also use the logical properties ('block-size', 'border-block-start', etc.) to determine lengths.

    assert(containing_block_width >= 0);

    {
        const multiplier = solve.borderWidthMultiplier(border_styles.top);
        switch (specified.border_top) {
            .px => |value| {
                const width = value * multiplier;
                computed.border_top = .{ .px = width };
                used.border_block_start = solve.positiveLength(.px, width);
            },
            inline .thin, .medium, .thick => |_, tag| {
                const width = solve.borderWidth(tag) * multiplier;
                computed.border_top = .{ .px = width };
                used.border_block_start = solve.positiveLength(.px, width);
            },
            .initial, .inherit, .unset, .undeclared => unreachable,
        }
    }
    {
        const multiplier = solve.borderWidthMultiplier(border_styles.bottom);
        switch (specified.border_bottom) {
            .px => |value| {
                const width = value * multiplier;
                computed.border_bottom = .{ .px = width };
                used.border_block_end = solve.positiveLength(.px, width);
            },
            inline .thin, .medium, .thick => |_, tag| {
                const width = solve.borderWidth(tag) * multiplier;
                computed.border_bottom = .{ .px = width };
                used.border_block_end = solve.positiveLength(.px, width);
            },
            .initial, .inherit, .unset, .undeclared => unreachable,
        }
    }
    switch (specified.padding_top) {
        .px => |value| {
            computed.padding_top = .{ .px = value };
            used.padding_block_start = solve.positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.padding_top = .{ .percentage = value };
            used.padding_block_start = solve.positivePercentage(value, containing_block_width);
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
    switch (specified.padding_bottom) {
        .px => |value| {
            computed.padding_bottom = .{ .px = value };
            used.padding_block_end = solve.positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.padding_bottom = .{ .percentage = value };
            used.padding_block_end = solve.positivePercentage(value, containing_block_width);
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
    switch (specified.margin_top) {
        .px => |value| {
            computed.margin_top = .{ .px = value };
            used.margin_block_start = solve.length(.px, value);
        },
        .percentage => |value| {
            computed.margin_top = .{ .percentage = value };
            used.margin_block_start = solve.percentage(value, containing_block_width);
        },
        .auto => {
            computed.margin_top = .auto;
            used.margin_block_start = 0;
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
    switch (specified.margin_bottom) {
        .px => |value| {
            computed.margin_bottom = .{ .px = value };
            used.margin_block_end = solve.length(.px, value);
        },
        .percentage => |value| {
            computed.margin_bottom = .{ .percentage = value };
            used.margin_block_end = solve.percentage(value, containing_block_width);
        },
        .auto => {
            computed.margin_bottom = .auto;
            used.margin_block_end = 0;
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
}

/// Changes the used sizes of a block that is in normal flow.
/// This implements the constraints described in CSS2.2§10.3.3.
pub fn adjustWidthAndMargins(used: *BlockUsedSizes, containing_block_width: ZssUnit) void {
    const width_margin_space = containing_block_width -
        (used.border_inline_start + used.border_inline_end + used.padding_inline_start + used.padding_inline_end);
    if (used.inlineSizeAndMarginsAreAllNotAuto()) {
        // None of the values were auto, so one of the margins must be set according to the other values.
        // TODO the margin that gets set is determined by the 'direction' property
        used.set(.margin_inline_end, width_margin_space - used.inline_size_untagged - used.margin_inline_start_untagged);
    } else if (!used.isFieldAuto(.inline_size)) {
        // 'inline-size' is not auto, but at least one of 'margin-inline-start' and 'margin-inline-end' is.
        // If there is only one "auto", then that value gets the remaining margin space.
        // Else, there are 2 "auto"s, and both values get half the remaining margin space.
        const start = used.isFieldAuto(.margin_inline_start);
        const end = used.isFieldAuto(.margin_inline_end);
        const shr_amount = @intFromBool(start and end);
        const leftover_margin = @max(0, width_margin_space -
            (used.inline_size_untagged + used.margin_inline_start_untagged + used.margin_inline_end_untagged));
        // TODO the margin that gets the extra 1 unit shall be determined by the 'direction' property
        if (start) used.set(.margin_inline_start, leftover_margin >> shr_amount);
        if (end) used.set(.margin_inline_end, (leftover_margin >> shr_amount) + @mod(leftover_margin, 2));
    } else {
        // 'inline-size' is auto, so it is set according to the other values.
        // The margin values don't need to change.
        used.set(.inline_size, width_margin_space - used.margin_inline_start_untagged - used.margin_inline_end_untagged);
        used.setOnly(.margin_inline_start);
        used.setOnly(.margin_inline_end);
    }
}

pub fn solveStackingContext(
    computer: *StyleComputer,
    position: zss.values.types.Position,
) StackingContexts.Info {
    const z_index = computer.getSpecifiedValue(.box_gen, .z_index);
    computer.setComputedValue(.box_gen, .z_index, z_index);

    switch (position) {
        .static => return .none,
        // TODO: Position the block using the values of the 'inset' family of properties.
        .relative => switch (z_index.z_index) {
            .integer => |integer| return .{ .is_parent = integer },
            .auto => return .{ .is_non_parent = 0 },
            .initial, .inherit, .unset, .undeclared => unreachable,
        },
        .absolute, .fixed, .sticky => panic("TODO: {s} positioning", .{@tagName(position)}),
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
}

/// Writes all of a flow block's data to the BoxTree.
pub fn writeBlockData(
    subtree_slice: SubtreeSlice,
    index: BlockBoxIndex,
    used: BlockUsedSizes,
    skip: BlockBoxSkip,
    width: ZssUnit,
    height: ZssUnit,
    stacking_context: ?StackingContext.Id,
) void {
    writeBlockDataPart1(subtree_slice, index, used, width, stacking_context);
    writeBlockDataPart2(subtree_slice, index, skip, height);
}

/// Partially writes a flow block's data to the BoxTree.
/// Must eventually be followed by a call to writeBlockDataPart2.
fn writeBlockDataPart1(
    subtree_slice: SubtreeSlice,
    index: BlockBoxIndex,
    used: BlockUsedSizes,
    width: ZssUnit,
    stacking_context: ?StackingContext.Id,
) void {
    subtree_slice.items(.type)[index] = .block;
    subtree_slice.items(.stacking_context)[index] = stacking_context;

    const box_offsets = &subtree_slice.items(.box_offsets)[index];
    const borders = &subtree_slice.items(.borders)[index];
    const margins = &subtree_slice.items(.margins)[index];

    // Horizontal sizes
    box_offsets.border_pos.x = used.get(.margin_inline_start).?;
    box_offsets.content_pos.x = used.border_inline_start + used.padding_inline_start;
    box_offsets.content_size.w = width;
    box_offsets.border_size.w = box_offsets.content_pos.x + box_offsets.content_size.w + used.padding_inline_end + used.border_inline_end;

    borders.left = used.border_inline_start;
    borders.right = used.border_inline_end;

    margins.left = used.get(.margin_inline_start).?;
    margins.right = used.get(.margin_inline_end).?;

    // Vertical sizes
    box_offsets.border_pos.y = used.margin_block_start;
    box_offsets.content_pos.y = used.border_block_start + used.padding_block_start;
    box_offsets.content_size.h = undefined;
    box_offsets.border_size.h = box_offsets.content_pos.y + used.padding_block_end + used.border_block_end;

    borders.top = used.border_block_start;
    borders.bottom = used.border_block_end;

    margins.top = used.margin_block_start;
    margins.bottom = used.margin_block_end;
}

pub fn solveUsedWidth(width: ZssUnit, min_width: ZssUnit, max_width: ZssUnit) ZssUnit {
    return solve.clampSize(width, min_width, max_width);
}

pub fn solveUsedHeight(height: ?ZssUnit, min_height: ZssUnit, max_height: ZssUnit, auto_height: ZssUnit) ZssUnit {
    return solve.clampSize(height orelse auto_height, min_height, max_height);
}

/// Writes data to the BoxTree that was left out during writeBlockDataPart1.
fn writeBlockDataPart2(
    subtree_slice: SubtreeSlice,
    index: BlockBoxIndex,
    skip: BlockBoxSkip,
    height: ZssUnit,
) void {
    subtree_slice.items(.skip)[index] = skip;

    const box_offsets_ptr = &subtree_slice.items(.box_offsets)[index];
    box_offsets_ptr.content_size.h = height;
    box_offsets_ptr.border_size.h += height;
}

pub fn addBlockToFlow(subtree_slice: SubtreeSlice, index: BlockBoxIndex, parent_auto_height: *ZssUnit) void {
    const box_offsets = &subtree_slice.items(.box_offsets)[index];
    const margin_bottom = subtree_slice.items(.margins)[index].bottom;

    const margin_top = box_offsets.border_pos.y;
    box_offsets.border_pos.y += parent_auto_height.*;
    advanceFlow(parent_auto_height, box_offsets.border_size.h + margin_top + margin_bottom);
}

pub fn advanceFlow(parent_auto_height: *ZssUnit, amount: ZssUnit) void {
    parent_auto_height.* += amount;
}
