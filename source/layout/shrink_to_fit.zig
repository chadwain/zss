const std = @import("std");
const assert = std.debug.assert;
const panic = std.debug.panic;
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const MultiArrayList = std.MultiArrayList;

const zss = @import("../zss.zig");
const aggregates = zss.properties.aggregates;
const ElementTree = zss.ElementTree;
const Element = ElementTree.Element;

const flow = @import("./flow.zig");
const BlockComputedSizes = flow.BlockComputedSizes;
const BlockUsedSizes = flow.BlockUsedSizes;

const inline_layout = @import("./inline.zig");

const solve = @import("./solve.zig");
const StackingContexts = @import("./StackingContexts.zig");
const StyleComputer = @import("./StyleComputer.zig");

const used_values = zss.used_values;
const ZssUnit = used_values.ZssUnit;
const BlockBoxIndex = used_values.BlockBoxIndex;
const BlockBoxSkip = used_values.BlockBoxSkip;
const BlockSubtreeIndex = used_values.SubtreeIndex;
const BlockBox = used_values.BlockBox;
const StackingContext = used_values.StackingContext;
const GeneratedBox = used_values.GeneratedBox;
const BoxTree = used_values.BoxTree;

pub const Result = struct {
    skip: BlockBoxSkip,
};

pub fn runShrinkToFitLayout(
    allocator: Allocator,
    box_tree: *BoxTree,
    sc: *StackingContexts,
    computer: *StyleComputer,
    element: Element,
    main_block: BlockBox,
    used_sizes: BlockUsedSizes,
    stacking_context_info: StackingContexts.Info,
    available_width: ZssUnit,
) !Result {
    var object_tree = ObjectTree{};
    defer object_tree.deinit(allocator);

    var ctx = BuildObjectTreeContext{};
    defer ctx.deinit(allocator);
    try pushFlowObject(&ctx, &object_tree, allocator, box_tree, sc, element, used_sizes, available_width, stacking_context_info, main_block);
    try buildObjectTree(&ctx, &object_tree, allocator, sc, computer, box_tree);
    return try realizeObjects(object_tree.slice(), allocator, box_tree, main_block);
}

const Object = struct {
    skip: Index,
    tag: Tag,
    element: Element,
    data: Data,

    // The object tree can store as many objects as ElementTree can.
    const Index = ElementTree.Size;

    const Tag = enum {
        flow_stf,
        flow_normal,
        ifc,
    };

    const Data = union {
        flow_stf: struct {
            used: BlockUsedSizes,
            stacking_context_id: ?StackingContext.Id,
        },
        flow_normal: struct {
            margins: UsedMargins,
            subtree_index: BlockSubtreeIndex,
        },
        ifc: struct {
            subtree_index: BlockSubtreeIndex,
            subtree_root_index: BlockBoxIndex,
            layout_result: inline_layout.InlineLayoutContext.Result,
            line_split_result: inline_layout.IFCLineSplitResult,
        },
    };
};

const ObjectTree = MultiArrayList(Object);

const UsedMargins = struct {
    inline_start_untagged: ZssUnit,
    inline_end_untagged: ZssUnit,
    auto_bitfield: u2,

    const Field = enum(u2) {
        inline_start = 1,
        inline_end = 2,
    };

    fn isFieldAuto(self: UsedMargins, comptime field: Field) bool {
        return self.auto_bitfield & @intFromEnum(field) != 0;
    }

    fn set(self: *UsedMargins, comptime field: Field, value: ZssUnit) void {
        self.auto_bitfield &= (~@intFromEnum(field));
        @field(self, @tagName(field) ++ "_untagged") = value;
    }

    fn get(self: UsedMargins, comptime field: Field) ?ZssUnit {
        return if (self.isFieldAuto(field)) null else @field(self, @tagName(field) ++ "_untagged");
    }

    fn fromBlockUsedSizes(sizes: BlockUsedSizes) UsedMargins {
        return UsedMargins{
            .inline_start_untagged = sizes.margin_inline_start_untagged,
            .inline_end_untagged = sizes.margin_inline_end_untagged,
            .auto_bitfield = (@as(u2, @intFromBool(sizes.isFieldAuto(.margin_inline_end))) << 1) |
                @as(u2, @intFromBool(sizes.isFieldAuto(.margin_inline_start))),
        };
    }
};

pub const BuildObjectTreeContext = struct {
    stack: MultiArrayList(StackItem) = .{},

    const StackItem = struct {
        object_index: Object.Index,
        object_skip: Object.Index,
        auto_width: ZssUnit,
        available_width: ZssUnit,
        height: ?ZssUnit,
    };

    pub fn deinit(self: *BuildObjectTreeContext, allocator: Allocator) void {
        self.stack.deinit(allocator);
    }
};

fn buildObjectTree(
    ctx: *BuildObjectTreeContext,
    object_tree: *ObjectTree,
    allocator: Allocator,
    sc: *StackingContexts,
    computer: *StyleComputer,
    box_tree: *BoxTree,
) !void {
    assert(ctx.stack.len > 0);
    while (ctx.stack.len > 0) {
        const object_index = ctx.stack.items(.object_index)[ctx.stack.len - 1];
        const object_tag = object_tree.items(.tag)[object_index];
        switch (object_tag) {
            .flow_stf => try flowObject(ctx, object_tree, allocator, sc, computer, box_tree),
            .flow_normal, .ifc => unreachable,
        }
    }
}

fn flowObject(
    ctx: *BuildObjectTreeContext,
    object_tree: *ObjectTree,
    allocator: Allocator,
    sc: *StackingContexts,
    computer: *StyleComputer,
    box_tree: *BoxTree,
) !void {
    const element_ptr = &computer.child_stack.items[computer.child_stack.items.len - 1];
    if (!element_ptr.eqlNull()) {
        const element = element_ptr.*;
        computer.setElementDirectChild(.box_gen, element);

        const specified = computer.getSpecifiedValue(.box_gen, .box_style);
        const computed = solve.boxStyle(specified, .NonRoot);
        computer.setComputedValue(.box_gen, .box_style, computed);

        const containing_block_available_width = ctx.stack.items(.available_width)[ctx.stack.len - 1];
        const containing_block_height = ctx.stack.items(.height)[ctx.stack.len - 1];

        switch (computed.display) {
            .block => {
                var used: BlockUsedSizes = undefined;
                try solveBlockSizes(computer, &used, containing_block_height);
                const stacking_context = flowBlockCreateStackingContext(computer, computed.position);

                { // TODO: Delete this
                    const stuff = .{
                        .font = computer.getSpecifiedValue(.box_gen, .font),
                    };
                    computer.setComputedValue(.box_gen, .font, stuff.font);
                }
                element_ptr.* = computer.element_tree_slice.nextSibling(element);
                try computer.pushElement(.box_gen);

                const edge_width = used.margin_inline_start_untagged + used.margin_inline_end_untagged +
                    used.border_inline_start + used.border_inline_end +
                    used.padding_inline_start + used.padding_inline_end;

                if (used.get(.inline_size)) |inline_size| {
                    const parent_auto_width = &ctx.stack.items(.auto_width)[ctx.stack.len - 1];
                    parent_auto_width.* = @max(parent_auto_width.*, inline_size + edge_width);

                    const new_subtree_index = try box_tree.blocks.makeSubtree(box_tree.allocator, .{ .parent = undefined });

                    ctx.stack.items(.object_skip)[ctx.stack.len - 1] += 1;
                    try object_tree.append(allocator, .{
                        .skip = 1,
                        .tag = .flow_normal,
                        .element = element,
                        .data = .{ .flow_normal = .{
                            .margins = UsedMargins.fromBlockUsedSizes(used),
                            .subtree_index = new_subtree_index,
                        } },
                    });

                    const new_subtree = box_tree.blocks.subtrees.items[new_subtree_index];
                    const new_subtree_block = try zss.layout.createBlock(box_tree, new_subtree);

                    const generated_box = GeneratedBox{ .block_box = .{ .subtree = new_subtree_index, .index = new_subtree_block.index } };
                    try box_tree.element_to_generated_box.putNoClobber(box_tree.allocator, element, generated_box);

                    // TODO: Recursive call here
                    _ = try flow.runFlowLayout(
                        allocator,
                        box_tree,
                        sc,
                        computer,
                        new_subtree_index,
                        new_subtree_block.index,
                        used,
                        stacking_context,
                    );
                } else {
                    const parent_available_width = ctx.stack.items(.available_width)[ctx.stack.len - 1];
                    const available_width = solve.clampSize(parent_available_width - edge_width, used.min_inline_size, used.max_inline_size);
                    try pushFlowObject(ctx, object_tree, allocator, box_tree, sc, element, used, available_width, stacking_context, undefined);
                }
            },
            .none => element_ptr.* = computer.element_tree_slice.nextSibling(element),
            .@"inline", .inline_block, .text => {
                const new_subtree_index = try box_tree.blocks.makeSubtree(box_tree.allocator, .{ .parent = undefined });
                const new_subtree = box_tree.blocks.subtrees.items[new_subtree_index];
                const new_ifc_container = try zss.layout.createBlock(box_tree, new_subtree);

                const result = try inline_layout.makeInlineFormattingContext(
                    allocator,
                    sc,
                    computer,
                    box_tree,
                    new_subtree_index,
                    .ShrinkToFit,
                    containing_block_available_width,
                    containing_block_height,
                );
                const ifc = box_tree.ifcs.items[result.ifc_index];
                const line_split_result = try inline_layout.splitIntoLineBoxes(allocator, box_tree, new_subtree, ifc, containing_block_available_width);

                const parent_auto_width = &ctx.stack.items(.auto_width)[ctx.stack.len - 1];
                parent_auto_width.* = @max(parent_auto_width.*, line_split_result.longest_line_box_length);

                // TODO: Store the IFC index as the element
                ctx.stack.items(.object_skip)[ctx.stack.len - 1] += 1;
                try object_tree.append(allocator, .{
                    .skip = 1,
                    .tag = .ifc,
                    .element = undefined,
                    .data = .{ .ifc = .{
                        .subtree_index = new_subtree_index,
                        .subtree_root_index = new_ifc_container.index,
                        .layout_result = result,
                        .line_split_result = line_split_result,
                    } },
                });
            },
            .initial, .inherit, .unset, .undeclared => unreachable,
        }
    } else {
        popFlowObject(ctx, object_tree, box_tree, sc);
        computer.popElement(.box_gen);
    }
}

fn pushFlowObject(
    ctx: *BuildObjectTreeContext,
    object_tree: *ObjectTree,
    allocator: Allocator,
    box_tree: *BoxTree,
    sc: *StackingContexts,
    element: Element,
    used_sizes: BlockUsedSizes,
    available_width: ZssUnit,
    stacking_context: StackingContexts.Info,
    block_box: BlockBox,
) !void {
    // The allocations here must have corresponding deallocations in popFlowObject.
    try ctx.stack.append(allocator, .{
        .object_index = @intCast(object_tree.len),
        .object_skip = 1,
        .auto_width = 0,
        .available_width = available_width,
        .height = used_sizes.get(.block_size),
    });
    const id = try sc.push(stacking_context, box_tree, block_box);

    try object_tree.append(allocator, .{
        .skip = undefined,
        .tag = .flow_stf,
        .element = element,
        .data = .{ .flow_stf = .{
            .used = used_sizes,
            .stacking_context_id = id,
        } },
    });
}

fn popFlowObject(ctx: *BuildObjectTreeContext, object_tree: *ObjectTree, box_tree: *BoxTree, sc: *StackingContexts) void {
    // The deallocations here must correspond to allocations in pushFlowObject.
    const this = ctx.stack.pop();
    sc.pop(box_tree);

    const object_tree_slice = object_tree.slice();
    object_tree_slice.items(.skip)[this.object_index] = this.object_skip;
    const data = &object_tree_slice.items(.data)[this.object_index].flow_stf;

    const used = &data.used;
    used.set(.inline_size, solve.clampSize(this.auto_width, used.min_inline_size, used.max_inline_size));

    if (ctx.stack.len > 0) {
        const parent_object_index = ctx.stack.items(.object_index)[ctx.stack.len - 1];
        const parent_object_tag = object_tree_slice.items(.tag)[parent_object_index];
        switch (parent_object_tag) {
            .flow_stf => {
                const full_width = used.inline_size_untagged +
                    used.padding_inline_start + used.padding_inline_end +
                    used.border_inline_start + used.border_inline_end +
                    used.margin_inline_start_untagged + used.margin_inline_end_untagged;
                const parent_auto_width = &ctx.stack.items(.auto_width)[ctx.stack.len - 1];
                parent_auto_width.* = @max(parent_auto_width.*, full_width);
            },
            .flow_normal, .ifc => unreachable,
        }

        ctx.stack.items(.object_skip)[ctx.stack.len - 1] += this.object_skip;
    }
}

const RealizeObjectsContext = struct {
    stack: MultiArrayList(StackItem) = .{},

    const Interval = struct {
        begin: Object.Index,
        end: Object.Index,
    };

    const StackItem = struct {
        object_index: Object.Index,
        object_tag: Object.Tag,
        object_interval: Interval,

        index: BlockBoxIndex,
        skip: BlockBoxSkip,
        width: ZssUnit,
        height: ?ZssUnit,
        auto_height: ZssUnit,
    };

    fn deinit(ctx: *RealizeObjectsContext, allocator: Allocator) void {
        ctx.stack.deinit(allocator);
    }
};

fn realizeObjects(
    object_tree_slice: ObjectTree.Slice,
    allocator: Allocator,
    box_tree: *BoxTree,
    main_block: BlockBox,
) !Result {
    const skips = object_tree_slice.items(.skip);
    const tags = object_tree_slice.items(.tag);
    const elements = object_tree_slice.items(.element);
    const datas = object_tree_slice.items(.data);

    const subtree = box_tree.blocks.subtrees.items[main_block.subtree];

    var ctx = RealizeObjectsContext{};
    defer ctx.deinit(allocator);

    {
        const skip = skips[0];
        const tag = tags[0];
        switch (tag) {
            .flow_stf => {
                const data = datas[0].flow_stf;

                const subtree_slice = subtree.slice();
                // TODO: Should we call flow.adjustWidthAndMargins?
                // Maybe. It depends on the outer context.
                const used_sizes = data.used;
                flow.writeBlockDataPart1(subtree_slice, main_block.index, used_sizes, data.stacking_context_id);

                try ctx.stack.append(allocator, .{
                    .object_index = 0,
                    .object_tag = tag,
                    .object_interval = .{ .begin = 1, .end = skip },

                    .index = main_block.index,
                    .skip = 1,
                    .width = used_sizes.get(.inline_size).?,
                    .height = used_sizes.get(.block_size),
                    .auto_height = 0,
                });
            },
            .flow_normal, .ifc => unreachable,
        }
    }

    var result: ?Result = null;
    while (result == null) {
        const parent = ctx.stack.get(ctx.stack.len - 1);
        switch (parent.object_tag) {
            .flow_stf => if (parent.object_interval.begin != parent.object_interval.end) {
                const object_index = parent.object_interval.begin;
                const skip = skips[object_index];
                const tag = tags[object_index];
                const element = elements[object_index];
                ctx.stack.items(.object_interval)[ctx.stack.len - 1].begin += skip;

                const containing_block_width = parent.width;
                switch (tag) {
                    .flow_stf => {
                        const data = datas[object_index].flow_stf;

                        const block = try zss.layout.createBlock(box_tree, subtree);
                        const block_box = BlockBox{ .subtree = main_block.subtree, .index = block.index };

                        const used_sizes = data.used;
                        const stacking_context = data.stacking_context_id;
                        var used_margins = UsedMargins.fromBlockUsedSizes(used_sizes);
                        flowBlockAdjustMargins(&used_margins, containing_block_width - block.box_offsets.border_size.w);
                        flowBlockSetData(box_tree, block_box, used_sizes, stacking_context, used_margins);

                        const generated_box = GeneratedBox{ .block_box = block_box };
                        try box_tree.element_to_generated_box.putNoClobber(box_tree.allocator, element, generated_box);

                        try ctx.stack.append(allocator, .{
                            .object_index = object_index,
                            .object_tag = .flow_stf,
                            .object_interval = .{ .begin = object_index + 1, .end = object_index + skip },

                            .index = block.index,
                            .skip = 1,
                            .width = used_sizes.get(.inline_size).?,
                            .height = used_sizes.get(.block_size),
                            .auto_height = 0,
                        });
                    },
                    .flow_normal => {
                        const data = &datas[object_index].flow_normal;
                        const new_subtree = box_tree.blocks.subtrees.items[data.subtree_index];

                        {
                            const proxy = try zss.layout.createBlock(box_tree, subtree);
                            proxy.type.* = .{ .subtree_proxy = data.subtree_index };
                            proxy.skip.* = 1;
                            new_subtree.parent = .{ .subtree = main_block.subtree, .index = proxy.index };
                            ctx.stack.items(.skip)[ctx.stack.len - 1] += 1;
                        }

                        const new_subtree_slice = new_subtree.slice();
                        const box_offsets = &new_subtree_slice.items(.box_offsets)[0];
                        flowBlockAdjustMargins(&data.margins, containing_block_width - box_offsets.border_size.w);
                        const margins = &new_subtree_slice.items(.margins)[0];
                        flowBlockSetHorizontalMargins(data.margins, margins);

                        const parent_auto_height = &ctx.stack.items(.auto_height)[ctx.stack.len - 1];
                        flow.addBlockToFlow(new_subtree_slice, 0, parent_auto_height);
                    },
                    .ifc => {
                        const data = datas[object_index].ifc;
                        const new_subtree = box_tree.blocks.subtrees.items[data.subtree_index];
                        const block_index = data.subtree_root_index;

                        // TODO: The proxy block should have its box_offsets value set, while the subtree root block should have default values
                        {
                            const proxy = try zss.layout.createBlock(box_tree, subtree);
                            proxy.skip.* = 1;
                            proxy.type.* = .{ .subtree_proxy = data.subtree_index };
                            new_subtree.parent = .{ .subtree = main_block.subtree, .index = proxy.index };
                            ctx.stack.items(.skip)[ctx.stack.len - 1] += 1;
                        }

                        const ifc = box_tree.ifcs.items[data.layout_result.ifc_index];
                        ifc.parent_block = .{ .subtree = main_block.subtree, .index = parent.index };

                        const new_subtree_slice = new_subtree.slice();
                        const parent_auto_height = &ctx.stack.items(.auto_height)[ctx.stack.len - 1];
                        new_subtree_slice.items(.type)[block_index] = .{ .ifc_container = data.layout_result.ifc_index };
                        new_subtree_slice.items(.skip)[block_index] = 1 + data.layout_result.total_inline_block_skip;
                        new_subtree_slice.items(.box_offsets)[block_index] = .{
                            .border_pos = .{ .x = 0, .y = parent_auto_height.* },
                            .border_size = .{ .w = data.line_split_result.longest_line_box_length, .h = data.line_split_result.height },
                            .content_pos = .{ .x = 0, .y = 0 },
                            .content_size = .{ .w = data.line_split_result.longest_line_box_length, .h = data.line_split_result.height },
                        };

                        flow.advanceFlow(parent_auto_height, data.line_split_result.height);
                    },
                }
            } else {
                const this = ctx.stack.pop();

                const data = object_tree_slice.items(.data)[this.object_index].flow_stf;
                const used_sizes = data.used;
                const subtree_slice = subtree.slice();
                flow.writeBlockDataPart2(subtree_slice, this.index, this.skip, used_sizes.getUsedContentHeight(), this.auto_height);

                if (ctx.stack.len > 0) {
                    switch (ctx.stack.items(.object_tag)[ctx.stack.len - 1]) {
                        .flow_stf => {
                            ctx.stack.items(.skip)[ctx.stack.len - 1] += this.skip;
                            const parent_auto_height = &ctx.stack.items(.auto_height)[ctx.stack.len - 1];
                            flow.addBlockToFlow(subtree_slice, this.index, parent_auto_height);
                        },
                        .flow_normal, .ifc => unreachable,
                    }
                } else {
                    result = .{ .skip = this.skip };
                }
            },
            .flow_normal, .ifc => unreachable,
        }
    }

    return result.?;
}

fn solveBlockSizes(
    computer: *StyleComputer,
    used: *BlockUsedSizes,
    containing_block_height: ?ZssUnit,
) !void {
    const specified = .{
        .content_width = computer.getSpecifiedValue(.box_gen, .content_width),
        .content_height = computer.getSpecifiedValue(.box_gen, .content_height),
        .horizontal_edges = computer.getSpecifiedValue(.box_gen, .horizontal_edges),
        .vertical_edges = computer.getSpecifiedValue(.box_gen, .vertical_edges),
        .border_styles = computer.getSpecifiedValue(.box_gen, .border_styles),
    };
    var computed: BlockComputedSizes = undefined;

    try flowBlockSolveContentWidth(specified.content_width, &computed.content_width, used);
    try flowBlockSolveHorizontalEdges(specified.horizontal_edges, specified.border_styles, &computed.horizontal_edges, used);
    try flow.solveContentHeight(specified.content_height, containing_block_height, &computed.content_height, used);
    try flow.solveVerticalEdges(specified.vertical_edges, 0, specified.border_styles, &computed.vertical_edges, used);

    computer.setComputedValue(.box_gen, .content_width, computed.content_width);
    computer.setComputedValue(.box_gen, .horizontal_edges, computed.horizontal_edges);
    computer.setComputedValue(.box_gen, .content_height, computed.content_height);
    computer.setComputedValue(.box_gen, .vertical_edges, computed.vertical_edges);
    computer.setComputedValue(.box_gen, .border_styles, specified.border_styles);
}

fn flowBlockSolveContentWidth(
    specified: aggregates.ContentWidth,
    computed: *aggregates.ContentWidth,
    used: *BlockUsedSizes,
) !void {
    switch (specified.min_width) {
        .px => |value| {
            computed.min_width = .{ .px = value };
            used.min_inline_size = try solve.positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.min_width = .{ .percentage = value };
            used.min_inline_size = 0;
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
    switch (specified.max_width) {
        .px => |value| {
            computed.max_width = .{ .px = value };
            used.max_inline_size = try solve.positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.max_width = .{ .percentage = value };
            used.max_inline_size = std.math.maxInt(ZssUnit);
        },
        .none => {
            computed.max_width = .none;
            used.max_inline_size = std.math.maxInt(ZssUnit);
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }

    switch (specified.width) {
        .px => |value| {
            computed.width = .{ .px = value };
            used.set(.inline_size, try solve.positiveLength(.px, value));
        },
        .percentage => |value| {
            computed.width = .{ .percentage = value };
            used.setAuto(.inline_size);
        },
        .auto => {
            computed.width = .auto;
            used.setAuto(.inline_size);
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
}

fn flowBlockSolveHorizontalEdges(
    specified: aggregates.HorizontalEdges,
    border_styles: aggregates.BorderStyles,
    computed: *aggregates.HorizontalEdges,
    used: *BlockUsedSizes,
) !void {
    {
        const multiplier = solve.borderWidthMultiplier(border_styles.left);
        switch (specified.border_left) {
            .px => |value| {
                const width = value * multiplier;
                computed.border_left = .{ .px = width };
                used.border_inline_start = try solve.positiveLength(.px, width);
            },
            inline .thin, .medium, .thick => |_, tag| {
                const width = solve.borderWidth(tag) * multiplier;
                computed.border_left = .{ .px = width };
                used.border_inline_start = solve.positiveLength(.px, width) catch unreachable;
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
                used.border_inline_end = try solve.positiveLength(.px, width);
            },
            inline .thin, .medium, .thick => |_, tag| {
                const width = solve.borderWidth(tag) * multiplier;
                computed.border_right = .{ .px = width };
                used.border_inline_end = solve.positiveLength(.px, width) catch unreachable;
            },
            .initial, .inherit, .unset, .undeclared => unreachable,
        }
    }

    switch (specified.padding_left) {
        .px => |value| {
            computed.padding_left = .{ .px = value };
            used.padding_inline_start = try solve.positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.padding_left = .{ .percentage = value };
            used.padding_inline_start = 0;
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
    switch (specified.padding_right) {
        .px => |value| {
            computed.padding_right = .{ .px = value };
            used.padding_inline_end = try solve.positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.padding_right = .{ .percentage = value };
            used.padding_inline_end = 0;
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }

    switch (specified.margin_left) {
        .px => |value| {
            computed.margin_left = .{ .px = value };
            used.set(.margin_inline_start, solve.length(.px, value));
        },
        .percentage => |value| {
            computed.margin_left = .{ .percentage = value };
            used.setAuto(.margin_inline_start);
        },
        .auto => {
            computed.margin_left = .auto;
            used.setAuto(.margin_inline_start);
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
    switch (specified.margin_right) {
        .px => |value| {
            computed.margin_right = .{ .px = value };
            used.set(.margin_inline_end, solve.length(.px, value));
        },
        .percentage => |value| {
            computed.margin_right = .{ .percentage = value };
            used.setAuto(.margin_inline_end);
        },
        .auto => {
            computed.margin_right = .auto;
            used.setAuto(.margin_inline_end);
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
}

/// Changes the used sizes of a flow block that is in normal flow.
/// Uses the assumption that inline-size is not auto.
/// This implements the constraints described in CSS2.2§10.3.3.
fn flowBlockAdjustMargins(margins: *UsedMargins, available_margin_space: ZssUnit) void {
    const start = margins.isFieldAuto(.inline_start);
    const end = margins.isFieldAuto(.inline_end);
    if (!start and !end) {
        // None of the values were auto, so one of the margins must be set according to the other values.
        // TODO the margin that gets set is determined by the 'direction' property
        margins.set(.inline_end, available_margin_space - margins.inline_start_untagged);
    } else {
        // 'inline-size' is not auto, but at least one of 'margin-inline-start' and 'margin-inline-end' is.
        // If there is only one "auto", then that value gets the remaining margin space.
        // Else, there are 2 "auto"s, and both values get half the remaining margin space.
        const shr_amount = @intFromBool(start and end);
        const leftover_margin = @max(0, available_margin_space - (margins.inline_start_untagged + margins.inline_end_untagged));
        // TODO the margin that gets the extra 1 unit shall be determined by the 'direction' property
        if (start) margins.set(.inline_start, leftover_margin >> shr_amount);
        if (end) margins.set(.inline_end, (leftover_margin >> shr_amount) + @mod(leftover_margin, 2));
    }
}

fn flowBlockCreateStackingContext(
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

fn flowBlockSetData(
    box_tree: *BoxTree,
    block_box: BlockBox,
    used: BlockUsedSizes,
    stacking_context: ?StackingContext.Id,
    used_margins: UsedMargins,
) void {
    const subtree_slice = box_tree.blocks.subtrees.items[block_box.subtree].slice();
    const @"type" = &subtree_slice.items(.type)[block_box.index];
    const box_offsets = &subtree_slice.items(.box_offsets)[block_box.index];
    const borders = &subtree_slice.items(.borders)[block_box.index];
    const margins = &subtree_slice.items(.margins)[block_box.index];

    @"type".* = .{ .block = .{
        .stacking_context = stacking_context,
    } };

    // horizontal
    box_offsets.border_pos.x = used.get(.margin_inline_start).?;
    box_offsets.content_pos.x = used.border_inline_start + used.padding_inline_start;
    box_offsets.content_size.w = used.get(.inline_size).?;
    box_offsets.border_size.w = box_offsets.content_pos.x + box_offsets.content_size.w + used.padding_inline_end + used.border_inline_end;

    borders.left = used.border_inline_start;
    borders.right = used.border_inline_end;

    flowBlockSetHorizontalMargins(used_margins, margins);

    // vertical
    box_offsets.border_pos.y = used.margin_block_start;
    box_offsets.content_pos.y = used.border_block_start + used.padding_block_start;
    box_offsets.content_size.h = undefined;
    box_offsets.border_size.h = box_offsets.content_pos.y + used.padding_block_end + used.border_block_end;

    borders.top = used.border_block_start;
    borders.bottom = used.border_block_end;

    margins.top = used.margin_block_start;
    margins.bottom = used.margin_block_end;

    if (stacking_context) |id| StackingContexts.fixup(box_tree, id, block_box);
}

fn flowBlockSetHorizontalMargins(used_margins: UsedMargins, margins: *used_values.Margins) void {
    margins.left = used_margins.get(.inline_start).?;
    margins.right = used_margins.get(.inline_end).?;
}
