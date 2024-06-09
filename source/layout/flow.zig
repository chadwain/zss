const std = @import("std");
const assert = std.debug.assert;
const panic = std.debug.panic;
const Allocator = std.mem.Allocator;
const MultiArrayList = std.MultiArrayList;

const zss = @import("../zss.zig");
const aggregates = zss.properties.aggregates;
const Element = zss.ElementTree.Element;
const Stack = zss.util.Stack;

const solve = @import("./solve.zig");
const inline_layout = @import("./inline.zig");
const StyleComputer = @import("./StyleComputer.zig");
const StackingContexts = @import("./StackingContexts.zig");

const used_values = zss.used_values;
const BlockBox = used_values.BlockBox;
const BlockBoxIndex = used_values.BlockBoxIndex;
const BlockBoxSkip = used_values.BlockBoxSkip;
const SubtreeId = used_values.SubtreeId;
const BoxTree = used_values.BoxTree;
const StackingContext = used_values.StackingContext;
const SubtreeSlice = used_values.BlockSubtree.Slice;
const ZssUnit = used_values.ZssUnit;

pub const Result = struct {
    skip: BlockBoxSkip,
    index: BlockBoxIndex,
};

pub fn runFlowLayout(
    allocator: Allocator,
    box_tree: *BoxTree,
    sc: *StackingContexts,
    computer: *StyleComputer,
    element: Element,
    subtree_index: SubtreeId,
    used_sizes: BlockUsedSizes,
    stacking_context: StackingContexts.Info,
) !Result {
    var ctx = Context{ .allocator = allocator };
    defer ctx.deinit();

    try pushBlock(true, &ctx, box_tree, sc, element, subtree_index, used_sizes, stacking_context);
    while (ctx.stack.top) |_| {
        try analyzeElement(&ctx, sc, computer, box_tree);
    }

    return ctx.result;
}

const Context = struct {
    allocator: Allocator,
    result: Result = undefined,
    stack: Stack(StackItem) = .{},

    const StackItem = struct {
        subtree: SubtreeId,
        index: BlockBoxIndex,
        skip: BlockBoxSkip,

        width: ZssUnit,
        auto_height: ZssUnit,
        heights: UsedContentHeight,
    };

    fn deinit(ctx: *Context) void {
        ctx.stack.deinit(ctx.allocator);
    }
};

fn analyzeElement(ctx: *Context, sc: *StackingContexts, computer: *StyleComputer, box_tree: *BoxTree) !void {
    const element = computer.getCurrentElement();
    if (!element.eqlNull()) {
        const specified = .{
            .box_style = computer.getSpecifiedValue(.box_gen, .box_style),
            .font = computer.getSpecifiedValue(.box_gen, .font),
        };
        const computed_box_style = solve.boxStyle(specified.box_style, .NonRoot);
        computer.setComputedValue(.box_gen, .box_style, computed_box_style);
        computer.setComputedValue(.box_gen, .font, specified.font);

        const parent = &ctx.stack.top.?;
        const subtree_index = parent.subtree;
        const containing_block_width = parent.width;
        const containing_block_height = parent.heights.height;

        switch (computed_box_style.display) {
            .block => {
                const used_sizes = try solveAllSizes(computer, containing_block_width, containing_block_height);
                const stacking_context = createStackingContext(computer, computed_box_style.position);

                try pushBlock(false, ctx, box_tree, sc, element, subtree_index, used_sizes, stacking_context);
                try computer.pushElement(.box_gen);
            },
            .@"inline", .inline_block, .text => {
                const subtree = box_tree.blocks.subtree(subtree_index);
                const ifc_container_index = try subtree.appendBlock(box_tree.allocator);

                const result = try inline_layout.makeInlineFormattingContext(
                    ctx.allocator,
                    sc,
                    computer,
                    box_tree,
                    subtree_index,
                    .Normal,
                    containing_block_width,
                    containing_block_height,
                );
                const ifc = box_tree.ifcs.items[result.ifc_index];
                const line_split_result =
                    try inline_layout.splitIntoLineBoxes(ctx.allocator, box_tree, subtree, ifc, containing_block_width);
                ifc.parent_block = .{ .subtree = subtree_index, .index = ifc_container_index };

                const subtree_slice = subtree.slice();
                const skip = 1 + result.total_inline_block_skip;
                subtree_slice.items(.type)[ifc_container_index] = .{ .ifc_container = result.ifc_index };
                subtree_slice.items(.skip)[ifc_container_index] = skip;
                subtree_slice.items(.box_offsets)[ifc_container_index] = .{
                    .border_pos = .{ .x = 0, .y = parent.auto_height },
                    .border_size = .{ .w = containing_block_width, .h = line_split_result.height },
                    .content_pos = .{ .x = 0, .y = 0 },
                    .content_size = .{ .w = containing_block_width, .h = line_split_result.height },
                };

                parent.skip += skip;

                advanceFlow(&parent.auto_height, line_split_result.height);
            },
            .none => computer.advanceElement(.box_gen),
            .initial, .inherit, .unset, .undeclared => unreachable,
        }
    } else {
        popBlock(ctx, sc, box_tree);
        computer.popElement(.box_gen);
    }
}

fn pushBlock(
    comptime initial_push: bool,
    ctx: *Context,
    box_tree: *BoxTree,
    sc: *StackingContexts,
    element: Element,
    subtree_index: SubtreeId,
    used_sizes: BlockUsedSizes,
    stacking_context: StackingContexts.Info,
) !void {
    const subtree = box_tree.blocks.subtree(subtree_index);
    const block_index = try subtree.appendBlock(box_tree.allocator);
    const block_box = BlockBox{ .subtree = subtree_index, .index = block_index };
    try box_tree.element_to_generated_box.putNoClobber(box_tree.allocator, element, .{ .block_box = block_box });

    // The allocations here must have corresponding deallocations in popBlock.
    const stack_item = Context.StackItem{
        .subtree = subtree_index,
        .index = block_index,
        .skip = 1,
        .width = used_sizes.get(.inline_size).?,
        .auto_height = 0,
        .heights = used_sizes.getUsedContentHeight(),
    };
    if (initial_push) {
        ctx.stack.top = stack_item;
    } else {
        try ctx.stack.push(ctx.allocator, stack_item);
    }
    const stacking_context_id = try sc.push(stacking_context, box_tree, block_box);

    writeBlockDataPart1(subtree.slice(), block_index, used_sizes, stacking_context_id);
}

fn popBlock(ctx: *Context, sc: *StackingContexts, box_tree: *BoxTree) void {
    // The deallocations here must correspond to allocations in pushBlock.
    const this = ctx.stack.pop();
    sc.pop(box_tree);

    const subtree_slice = box_tree.blocks.subtree(this.subtree).slice();
    assert(subtree_slice.items(.box_offsets)[this.index].content_size.w == this.width);
    writeBlockDataPart2(subtree_slice, this.index, this.skip, this.heights, this.auto_height);

    if (ctx.stack.top) |*parent| {
        parent.skip += this.skip;
        addBlockToFlow(subtree_slice, this.index, &parent.auto_height);
    } else {
        ctx.result = .{
            .skip = this.skip,
            .index = this.index,
        };
    }
}

pub const UsedContentHeight = struct {
    height: ?ZssUnit,
    min_height: ZssUnit,
    max_height: ZssUnit,
};

pub const BlockComputedSizes = struct {
    content_width: aggregates.ContentWidth,
    horizontal_edges: aggregates.HorizontalEdges,
    content_height: aggregates.ContentHeight,
    vertical_edges: aggregates.VerticalEdges,
};

pub const BlockUsedSizes = struct {
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

    pub fn set(self: *BlockUsedSizes, comptime field: PossiblyAutoField, value: ZssUnit) void {
        self.auto_bitfield &= (~@intFromEnum(field));
        const clamped_value = switch (field) {
            .inline_size => solve.clampSize(value, self.min_inline_size, self.max_inline_size),
            .margin_inline_start, .margin_inline_end => value,
            .block_size => solve.clampSize(value, self.min_block_size, self.max_block_size),
        };
        @field(self, @tagName(field) ++ "_untagged") = clamped_value;
    }

    pub fn setAuto(self: *BlockUsedSizes, comptime field: PossiblyAutoField) void {
        self.auto_bitfield |= @intFromEnum(field);
        @field(self, @tagName(field) ++ "_untagged") = 0;
    }

    pub fn get(self: BlockUsedSizes, comptime field: PossiblyAutoField) ?ZssUnit {
        return if (self.isFieldAuto(field)) null else @field(self, @tagName(field) ++ "_untagged");
    }

    pub fn inlineSizeAndMarginsAreAllNotAuto(self: BlockUsedSizes) bool {
        const mask = @intFromEnum(PossiblyAutoField.inline_size) |
            @intFromEnum(PossiblyAutoField.margin_inline_start) |
            @intFromEnum(PossiblyAutoField.margin_inline_end);
        return self.auto_bitfield & mask == 0;
    }

    pub fn isFieldAuto(self: BlockUsedSizes, comptime field: PossiblyAutoField) bool {
        return self.auto_bitfield & @intFromEnum(field) != 0;
    }

    pub fn getUsedContentHeight(self: BlockUsedSizes) UsedContentHeight {
        return UsedContentHeight{
            .height = self.get(.block_size),
            .min_height = self.min_block_size,
            .max_height = self.max_block_size,
        };
    }
};

pub fn solveAllSizes(
    computer: *StyleComputer,
    containing_block_width: ZssUnit,
    containing_block_height: ?ZssUnit,
) !BlockUsedSizes {
    const border_styles = computer.getSpecifiedValue(.box_gen, .border_styles);
    const specified_sizes = BlockComputedSizes{
        .content_width = computer.getSpecifiedValue(.box_gen, .content_width),
        .horizontal_edges = computer.getSpecifiedValue(.box_gen, .horizontal_edges),
        .content_height = computer.getSpecifiedValue(.box_gen, .content_height),
        .vertical_edges = computer.getSpecifiedValue(.box_gen, .vertical_edges),
    };

    var computed_sizes: BlockComputedSizes = undefined;
    var used_sizes: BlockUsedSizes = undefined;
    try solveWidths(specified_sizes, containing_block_width, border_styles, &computed_sizes, &used_sizes);

    try solveContentHeight(specified_sizes.content_height, containing_block_height, &computed_sizes.content_height, &used_sizes);
    try solveVerticalEdges(
        specified_sizes.vertical_edges,
        containing_block_width,
        border_styles,
        &computed_sizes.vertical_edges,
        &used_sizes,
    );
    adjustWidthAndMargins(&used_sizes, containing_block_width);

    computer.setComputedValue(.box_gen, .content_width, computed_sizes.content_width);
    computer.setComputedValue(.box_gen, .horizontal_edges, computed_sizes.horizontal_edges);
    computer.setComputedValue(.box_gen, .content_height, computed_sizes.content_height);
    computer.setComputedValue(.box_gen, .vertical_edges, computed_sizes.vertical_edges);
    computer.setComputedValue(.box_gen, .border_styles, border_styles);

    return used_sizes;
}

/// This is an implementation of CSS2§10.2, CSS2§10.3.3, and CSS2§10.4.
pub fn solveWidths(
    specified: BlockComputedSizes,
    containing_block_width: ZssUnit,
    border_styles: aggregates.BorderStyles,
    computed: *BlockComputedSizes,
    used: *BlockUsedSizes,
) !void {
    // TODO: Also use the logical properties ('inline-size', 'border-inline-start', etc.) to determine lengths.

    assert(containing_block_width >= 0);

    {
        const multiplier = solve.borderWidthMultiplier(border_styles.left);
        switch (specified.horizontal_edges.border_left) {
            .px => |value| {
                const width = value * multiplier;
                computed.horizontal_edges.border_left = .{ .px = width };
                used.border_inline_start = try solve.positiveLength(.px, width);
            },
            inline .thin, .medium, .thick => |_, tag| {
                const width = solve.borderWidth(tag) * multiplier;
                computed.horizontal_edges.border_left = .{ .px = width };
                used.border_inline_start = solve.positiveLength(.px, width) catch unreachable;
            },
            .initial, .inherit, .unset, .undeclared => unreachable,
        }
    }
    {
        const multiplier = solve.borderWidthMultiplier(border_styles.right);
        switch (specified.horizontal_edges.border_right) {
            .px => |value| {
                const width = value * multiplier;
                computed.horizontal_edges.border_right = .{ .px = width };
                used.border_inline_end = try solve.positiveLength(.px, width);
            },
            inline .thin, .medium, .thick => |_, tag| {
                const width = solve.borderWidth(tag) * multiplier;
                computed.horizontal_edges.border_right = .{ .px = width };
                used.border_inline_end = solve.positiveLength(.px, width) catch unreachable;
            },
            .initial, .inherit, .unset, .undeclared => unreachable,
        }
    }
    switch (specified.horizontal_edges.padding_left) {
        .px => |value| {
            computed.horizontal_edges.padding_left = .{ .px = value };
            used.padding_inline_start = try solve.positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.horizontal_edges.padding_left = .{ .percentage = value };
            used.padding_inline_start = try solve.positivePercentage(value, containing_block_width);
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
    switch (specified.horizontal_edges.padding_right) {
        .px => |value| {
            computed.horizontal_edges.padding_right = .{ .px = value };
            used.padding_inline_end = try solve.positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.horizontal_edges.padding_right = .{ .percentage = value };
            used.padding_inline_end = try solve.positivePercentage(value, containing_block_width);
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }

    switch (specified.content_width.min_width) {
        .px => |value| {
            computed.content_width.min_width = .{ .px = value };
            used.min_inline_size = try solve.positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.content_width.min_width = .{ .percentage = value };
            used.min_inline_size = try solve.positivePercentage(value, containing_block_width);
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
    switch (specified.content_width.max_width) {
        .px => |value| {
            computed.content_width.max_width = .{ .px = value };
            used.max_inline_size = try solve.positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.content_width.max_width = .{ .percentage = value };
            used.max_inline_size = try solve.positivePercentage(value, containing_block_width);
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
            used.set(.inline_size, try solve.positiveLength(.px, value));
        },
        .percentage => |value| {
            computed.content_width.width = .{ .percentage = value };
            used.set(.inline_size, try solve.positivePercentage(value, containing_block_width));
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

pub fn solveContentHeight(
    specified: aggregates.ContentHeight,
    containing_block_height: ?ZssUnit,
    computed: *aggregates.ContentHeight,
    used: *BlockUsedSizes,
) !void {
    if (containing_block_height) |h| assert(h >= 0);

    switch (specified.min_height) {
        .px => |value| {
            computed.min_height = .{ .px = value };
            used.min_block_size = try solve.positiveLength(.px, value);
        },

        .percentage => |value| {
            computed.min_height = .{ .percentage = value };
            used.min_block_size = if (containing_block_height) |s|
                try solve.positivePercentage(value, s)
            else
                0;
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
    switch (specified.max_height) {
        .px => |value| {
            computed.max_height = .{ .px = value };
            used.max_block_size = try solve.positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.max_height = .{ .percentage = value };
            used.max_block_size = if (containing_block_height) |s|
                try solve.positivePercentage(value, s)
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
            used.set(.block_size, try solve.positiveLength(.px, value));
        },
        .percentage => |value| {
            computed.height = .{ .percentage = value };
            if (containing_block_height) |h|
                used.set(.block_size, try solve.positivePercentage(value, h))
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
) !void {
    // TODO: Also use the logical properties ('block-size', 'border-block-start', etc.) to determine lengths.

    assert(containing_block_width >= 0);

    {
        const multiplier = solve.borderWidthMultiplier(border_styles.top);
        switch (specified.border_top) {
            .px => |value| {
                const width = value * multiplier;
                computed.border_top = .{ .px = width };
                used.border_block_start = try solve.positiveLength(.px, width);
            },
            inline .thin, .medium, .thick => |_, tag| {
                const width = solve.borderWidth(tag) * multiplier;
                computed.border_top = .{ .px = width };
                used.border_block_start = solve.positiveLength(.px, width) catch unreachable;
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
                used.border_block_end = try solve.positiveLength(.px, width);
            },
            inline .thin, .medium, .thick => |_, tag| {
                const width = solve.borderWidth(tag) * multiplier;
                computed.border_bottom = .{ .px = width };
                used.border_block_end = solve.positiveLength(.px, width) catch unreachable;
            },
            .initial, .inherit, .unset, .undeclared => unreachable,
        }
    }
    switch (specified.padding_top) {
        .px => |value| {
            computed.padding_top = .{ .px = value };
            used.padding_block_start = try solve.positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.padding_top = .{ .percentage = value };
            used.padding_block_start = try solve.positivePercentage(value, containing_block_width);
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
    switch (specified.padding_bottom) {
        .px => |value| {
            computed.padding_bottom = .{ .px = value };
            used.padding_block_end = try solve.positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.padding_bottom = .{ .percentage = value };
            used.padding_block_end = try solve.positivePercentage(value, containing_block_width);
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

/// Changes the used sizes of a flow block that is in normal flow.
/// This implements the constraints described in CSS2.2§10.3.3.
pub fn adjustWidthAndMargins(used: *BlockUsedSizes, containing_block_width: ZssUnit) void {
    const content_margin_space = containing_block_width -
        (used.border_inline_start + used.border_inline_end + used.padding_inline_start + used.padding_inline_end);
    if (used.inlineSizeAndMarginsAreAllNotAuto()) {
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

fn createStackingContext(
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

/// Partially writes a flow block's data to the BoxTree.
/// Must eventually be followed by a call to writeBlockDataPart2.
pub fn writeBlockDataPart1(
    subtree_slice: SubtreeSlice,
    index: BlockBoxIndex,
    used: BlockUsedSizes,
    stacking_context: ?StackingContext.Id,
) void {
    const @"type" = &subtree_slice.items(.type)[index];
    const box_offsets = &subtree_slice.items(.box_offsets)[index];
    const borders = &subtree_slice.items(.borders)[index];
    const margins = &subtree_slice.items(.margins)[index];

    @"type".* = .{ .block = .{
        .stacking_context = stacking_context,
    } };

    // Horizontal sizes
    box_offsets.border_pos.x = used.get(.margin_inline_start).?;
    box_offsets.content_pos.x = used.border_inline_start + used.padding_inline_start;
    box_offsets.content_size.w = used.get(.inline_size).?;
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

/// Writes data to the BoxTree that was left out during writeBlockDataPart1.
pub fn writeBlockDataPart2(
    subtree_slice: SubtreeSlice,
    index: BlockBoxIndex,
    skip: BlockBoxSkip,
    heights: UsedContentHeight,
    auto_height: ZssUnit,
) void {
    const skip_ptr = &subtree_slice.items(.skip)[index];
    const box_offsets_ptr = &subtree_slice.items(.box_offsets)[index];

    skip_ptr.* = skip;

    const used_height = if (heights.height) |h| blk: {
        assert(solve.clampSize(h, heights.min_height, heights.max_height) == h);
        break :blk h;
    } else solve.clampSize(auto_height, heights.min_height, heights.max_height);
    box_offsets_ptr.content_size.h = used_height;
    box_offsets_ptr.border_size.h += used_height;
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
