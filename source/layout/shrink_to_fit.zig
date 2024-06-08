const std = @import("std");
const assert = std.debug.assert;
const panic = std.debug.panic;
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const ArrayListAlignedUnmanaged = std.ArrayListAlignedUnmanaged;
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
const units_per_pixel = used_values.units_per_pixel;
const BlockBoxIndex = used_values.BlockBoxIndex;
const BlockBoxSkip = used_values.BlockBoxSkip;
const BlockBoxTree = used_values.BlockBoxTree;
const BlockSubtreeIndex = used_values.SubtreeIndex;
const BlockSubtree = used_values.BlockSubtree;
const BlockBox = used_values.BlockBox;
const StackingContext = used_values.StackingContext;
const StackingContextIndex = used_values.StackingContextIndex;
const StackingContextRef = used_values.StackingContextRef;
const InlineFormattingContext = used_values.InlineFormattingContext;
const GeneratedBox = used_values.GeneratedBox;
const BoxTree = used_values.BoxTree;

const Objects = struct {
    tree: MultiArrayList(Object) = .{},
    data: ArrayListUnmanaged(Data) = .{},

    // This tree can store as many objects as ElementTree can.
    const Index = ElementTree.Size;
    const Skip = Index;

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

    const Object = struct {
        skip: Skip,
        tag: Tag,
        element: Element,
    };
};

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

pub const ShrinkToFitLayoutContext = struct {
    objects: Objects = .{},
    object_stack: MultiArrayList(ObjectStackItem) = .{},

    widths: MultiArrayList(Widths) = .{},
    heights: ArrayListUnmanaged(?ZssUnit) = .{},

    main_block: BlockBox,
    allocator: Allocator,

    const ObjectStackItem = struct {
        index: Objects.Index,
        skip: Objects.Skip,
    };

    const Widths = struct {
        auto: ZssUnit,
        available: ZssUnit,
    };

    pub fn initFlow(
        allocator: Allocator,
        box_tree: *BoxTree,
        sc: *StackingContexts,
        element: Element,
        main_block: BlockBox,
        used_sizes: BlockUsedSizes,
        stacking_context_info: StackingContexts.Info,
        available_width: ZssUnit,
    ) !ShrinkToFitLayoutContext {
        var result = ShrinkToFitLayoutContext{ .allocator = allocator, .main_block = main_block };
        errdefer result.deinit();

        const id = try pushBlock(&result, box_tree, sc, used_sizes, available_width, stacking_context_info, main_block);
        try result.object_stack.append(result.allocator, .{ .index = 0, .skip = 1 });
        try result.objects.tree.append(result.allocator, .{ .skip = undefined, .tag = .flow_stf, .element = element });
        try result.objects.data.append(result.allocator, .{ .flow_stf = .{ .used = used_sizes, .stacking_context_id = id } });
        return result;
    }

    pub fn deinit(self: *ShrinkToFitLayoutContext) void {
        self.objects.tree.deinit(self.allocator);
        self.objects.data.deinit(self.allocator);
        self.object_stack.deinit(self.allocator);

        self.widths.deinit(self.allocator);
        self.heights.deinit(self.allocator);
    }
};

pub fn shrinkToFitLayout(
    layout: *ShrinkToFitLayoutContext,
    sc: *StackingContexts,
    computer: *StyleComputer,
    box_tree: *BoxTree,
) !void {
    try buildObjectTree(layout, sc, computer, box_tree);
    try realizeObjects(layout.objects, layout.allocator, box_tree, layout.main_block);
}

fn buildObjectTree(layout: *ShrinkToFitLayoutContext, sc: *StackingContexts, computer: *StyleComputer, box_tree: *BoxTree) !void {
    assert(layout.objects.tree.len == 1);
    assert(layout.object_stack.len > 0);
    while (layout.object_stack.len > 0) {
        const object_index = layout.object_stack.items(.index)[layout.object_stack.len - 1];
        const object_tag = layout.objects.tree.items(.tag)[object_index];
        switch (object_tag) {
            .flow_stf => {
                const element_ptr = &computer.child_stack.items[computer.child_stack.items.len - 1];
                if (!element_ptr.eqlNull()) {
                    const element = element_ptr.*;
                    computer.setElementDirectChild(.box_gen, element);

                    const specified = computer.getSpecifiedValue(.box_gen, .box_style);
                    const computed = solve.boxStyle(specified, .NonRoot);
                    computer.setComputedValue(.box_gen, .box_style, computed);

                    const containing_block_available_width = layout.widths.items(.available)[layout.widths.len - 1];
                    const containing_block_height = layout.heights.items[layout.heights.items.len - 1];

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
                                const parent_auto_width = &layout.widths.items(.auto)[layout.widths.len - 1];
                                parent_auto_width.* = @max(parent_auto_width.*, inline_size + edge_width);

                                const new_subtree_index = try box_tree.blocks.makeSubtree(box_tree.allocator, .{ .parent = undefined });

                                layout.object_stack.items(.skip)[layout.object_stack.len - 1] += 1;
                                try layout.objects.tree.append(layout.allocator, .{ .skip = 1, .tag = .flow_normal, .element = element });
                                try layout.objects.data.append(
                                    layout.allocator,
                                    .{ .flow_normal = .{
                                        .margins = UsedMargins.fromBlockUsedSizes(used),
                                        .subtree_index = new_subtree_index,
                                    } },
                                );

                                const new_subtree = box_tree.blocks.subtrees.items[new_subtree_index];
                                const new_subtree_block = try zss.layout.createBlock(box_tree, new_subtree);

                                const generated_box = GeneratedBox{ .block_box = .{ .subtree = new_subtree_index, .index = new_subtree_block.index } };
                                try box_tree.element_to_generated_box.putNoClobber(box_tree.allocator, element, generated_box);

                                // TODO: Recursive call here
                                _ = try flow.runFlowLayout(
                                    layout.allocator,
                                    box_tree,
                                    sc,
                                    computer,
                                    new_subtree_index,
                                    new_subtree_block.index,
                                    used,
                                    stacking_context,
                                );
                            } else {
                                const parent_available_width = layout.widths.items(.available)[layout.widths.len - 1];
                                const available_width = solve.clampSize(parent_available_width - edge_width, used.min_inline_size, used.max_inline_size);
                                const id = try pushBlock(layout, box_tree, sc, used, available_width, stacking_context, undefined);

                                try layout.object_stack.append(layout.allocator, .{ .index = @intCast(layout.objects.tree.len), .skip = 1 });
                                try layout.objects.tree.append(layout.allocator, .{ .skip = undefined, .tag = .flow_stf, .element = element });
                                try layout.objects.data.append(
                                    layout.allocator,
                                    .{ .flow_stf = .{
                                        .used = used,
                                        .stacking_context_id = id,
                                    } },
                                );
                            }
                        },
                        .none => element_ptr.* = computer.element_tree_slice.nextSibling(element),
                        .@"inline", .inline_block, .text => {
                            const new_subtree_index = try box_tree.blocks.makeSubtree(box_tree.allocator, .{ .parent = undefined });
                            const new_subtree = box_tree.blocks.subtrees.items[new_subtree_index];
                            const new_ifc_container = try zss.layout.createBlock(box_tree, new_subtree);

                            const result = try inline_layout.makeInlineFormattingContext(
                                layout.allocator,
                                sc,
                                computer,
                                box_tree,
                                new_subtree_index,
                                .ShrinkToFit,
                                containing_block_available_width,
                                containing_block_height,
                            );
                            const ifc = box_tree.ifcs.items[result.ifc_index];
                            const line_split_result = try inline_layout.splitIntoLineBoxes(layout.allocator, box_tree, new_subtree, ifc, containing_block_available_width);

                            const parent_auto_width = &layout.widths.items(.auto)[layout.widths.len - 1];
                            parent_auto_width.* = @max(parent_auto_width.*, line_split_result.longest_line_box_length);

                            // TODO: Store the IFC index as the element
                            layout.object_stack.items(.skip)[layout.object_stack.len - 1] += 1;
                            try layout.objects.tree.append(layout.allocator, .{ .skip = 1, .tag = .ifc, .element = undefined });
                            try layout.objects.data.append(
                                layout.allocator,
                                .{ .ifc = .{
                                    .subtree_index = new_subtree_index,
                                    .subtree_root_index = new_ifc_container.index,
                                    .layout_result = result,
                                    .line_split_result = line_split_result,
                                } },
                            );
                        },
                        .initial, .inherit, .unset, .undeclared => unreachable,
                    }
                } else {
                    const object_info = layout.object_stack.pop();
                    layout.objects.tree.items(.skip)[object_info.index] = object_info.skip;

                    const block_info = popBlock(layout, box_tree, sc);
                    const data = &layout.objects.data.items[object_info.index].flow_stf;

                    const used = &data.used;
                    used.set(.inline_size, solve.clampSize(block_info.auto_width, used.min_inline_size, used.max_inline_size));

                    computer.popElement(.box_gen);

                    if (layout.object_stack.len > 0) {
                        const parent_object_index = layout.object_stack.items(.index)[layout.object_stack.len - 1];
                        const parent_object_tag = layout.objects.tree.items(.tag)[parent_object_index];
                        switch (parent_object_tag) {
                            .flow_stf => {
                                const full_width = used.inline_size_untagged +
                                    used.padding_inline_start + used.padding_inline_end +
                                    used.border_inline_start + used.border_inline_end +
                                    used.margin_inline_start_untagged + used.margin_inline_end_untagged;
                                const parent_auto_width = &layout.widths.items(.auto)[layout.widths.len - 1];
                                parent_auto_width.* = @max(parent_auto_width.*, full_width);
                            },
                            .flow_normal, .ifc => unreachable,
                        }

                        layout.object_stack.items(.skip)[layout.object_stack.len - 1] += object_info.skip;
                    }
                }
            },
            .flow_normal, .ifc => unreachable,
        }
    }
}

const ShrinkToFitLayoutContext2 = struct {
    objects: MultiArrayList(struct { index: Objects.Index, tag: Objects.Tag, interval: Interval }) = .{},
    blocks: MultiArrayList(struct { index: BlockBoxIndex, skip: BlockBoxSkip }) = .{},
    width: ArrayListUnmanaged(ZssUnit) = .{},
    height: ArrayListUnmanaged(?ZssUnit) = .{},
    auto_height: ArrayListUnmanaged(ZssUnit) = .{},

    const Interval = struct {
        begin: Objects.Index,
        end: Objects.Index,
    };

    fn deinit(layout: *ShrinkToFitLayoutContext2, allocator: Allocator) void {
        layout.objects.deinit(allocator);
        layout.blocks.deinit(allocator);
        layout.width.deinit(allocator);
        layout.height.deinit(allocator);
        layout.auto_height.deinit(allocator);
    }
};

fn realizeObjects(
    objects: Objects,
    allocator: Allocator,
    box_tree: *BoxTree,
    main_block: BlockBox,
) !void {
    const skips = objects.tree.items(.skip);
    const tags = objects.tree.items(.tag);
    const elements = objects.tree.items(.element);
    const datas = objects.data.items;

    const subtree = box_tree.blocks.subtrees.items[main_block.subtree];

    var layout = ShrinkToFitLayoutContext2{};
    defer layout.deinit(allocator);

    {
        const skip = skips[0];
        const tag = tags[0];
        switch (tag) {
            .flow_stf => {
                const data = datas[0].flow_stf;

                const subtree_slice = subtree.slice();
                // NOTE: Should we call flow.adjustWidthAndMargins?
                // Maybe. It depends on the outer context.
                const used_sizes = data.used;
                flow.writeBlockDataPart1(subtree_slice, main_block.index, used_sizes, data.stacking_context_id);

                try layout.blocks.append(allocator, .{ .index = main_block.index, .skip = 1 });
                try layout.width.append(allocator, used_sizes.get(.inline_size).?);
                try layout.height.append(allocator, used_sizes.get(.block_size));
                try layout.auto_height.append(allocator, 0);
            },
            .flow_normal, .ifc => unreachable,
        }

        try layout.objects.append(allocator, .{ .index = 0, .tag = tag, .interval = .{ .begin = 1, .end = skip } });
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
                interval.begin += skip;

                const containing_block_width = layout.width.items[layout.width.items.len - 1];
                switch (tag) {
                    .flow_stf => {
                        const data = datas[index].flow_stf;

                        const block = try zss.layout.createBlock(box_tree, subtree);

                        const used_sizes = data.used;
                        const stacking_context = data.stacking_context_id;
                        var used_margins = UsedMargins.fromBlockUsedSizes(used_sizes);
                        flowBlockAdjustMargins(&used_margins, containing_block_width - block.box_offsets.border_size.w);
                        flowBlockSetData(used_sizes, stacking_context, used_margins, block.box_offsets, block.borders, block.margins, block.type);

                        const generated_box = GeneratedBox{ .block_box = .{ .subtree = main_block.subtree, .index = block.index } };
                        try box_tree.element_to_generated_box.putNoClobber(box_tree.allocator, element, generated_box);

                        if (stacking_context) |id| {
                            StackingContexts.fixup(box_tree, id, generated_box.block_box);
                        }

                        try layout.objects.append(allocator, .{ .index = index, .tag = .flow_stf, .interval = .{ .begin = index + 1, .end = index + skip } });
                        try layout.blocks.append(allocator, .{ .index = block.index, .skip = 1 });
                        try layout.width.append(allocator, used_sizes.get(.inline_size).?);
                        try layout.height.append(allocator, used_sizes.get(.block_size));
                        try layout.auto_height.append(allocator, 0);
                    },
                    .flow_normal => {
                        const data = &datas[index].flow_normal;
                        const new_subtree = box_tree.blocks.subtrees.items[data.subtree_index];

                        {
                            const proxy = try zss.layout.createBlock(box_tree, subtree);
                            proxy.type.* = .{ .subtree_proxy = data.subtree_index };
                            proxy.skip.* = 1;
                            new_subtree.parent = .{ .subtree = main_block.subtree, .index = proxy.index };
                            layout.blocks.items(.skip)[layout.blocks.len - 1] += 1;
                        }

                        const new_subtree_slice = new_subtree.slice();
                        const box_offsets = &new_subtree_slice.items(.box_offsets)[0];
                        flowBlockAdjustMargins(&data.margins, containing_block_width - box_offsets.border_size.w);
                        const margins = &new_subtree_slice.items(.margins)[0];
                        flowBlockSetHorizontalMargins(data.margins, margins);

                        const parent_auto_height = &layout.auto_height.items[layout.auto_height.items.len - 1];
                        flow.addBlockToFlow(new_subtree_slice, 0, parent_auto_height);
                    },
                    .ifc => {
                        const data = datas[index].ifc;
                        const new_subtree = box_tree.blocks.subtrees.items[data.subtree_index];
                        const block_index = data.subtree_root_index;

                        // TODO: The proxy block should have its box_offsets value set, while the subtree root block should have default values
                        {
                            const proxy = try zss.layout.createBlock(box_tree, subtree);
                            proxy.skip.* = 1;
                            proxy.type.* = .{ .subtree_proxy = data.subtree_index };
                            new_subtree.parent = .{ .subtree = main_block.subtree, .index = proxy.index };
                            layout.blocks.items(.skip)[layout.blocks.len - 1] += 1;
                        }

                        const ifc = box_tree.ifcs.items[data.layout_result.ifc_index];
                        ifc.parent_block = .{ .subtree = main_block.subtree, .index = layout.blocks.items(.index)[layout.blocks.len - 1] };

                        const new_subtree_slice = new_subtree.slice();
                        const parent_auto_height = &layout.auto_height.items[layout.auto_height.items.len - 1];
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
                const index = layout.objects.pop().index;
                const block = layout.blocks.pop();
                _ = layout.width.pop();
                _ = layout.height.pop();
                const auto_height = layout.auto_height.pop();

                const data = objects.data.items[index].flow_stf;
                const used_sizes = data.used;
                const subtree_slice = subtree.slice();
                flow.writeBlockDataPart2(subtree_slice, block.index, block.skip, used_sizes.getUsedContentHeight(), auto_height);

                if (layout.objects.len > 0) {
                    switch (layout.objects.items(.tag)[layout.objects.len - 1]) {
                        .flow_stf => {
                            layout.blocks.items(.skip)[layout.blocks.len - 1] += block.skip;
                            const parent_auto_height = &layout.auto_height.items[layout.auto_height.items.len - 1];
                            flow.addBlockToFlow(subtree_slice, block.index, parent_auto_height);
                        },
                        .flow_normal, .ifc => unreachable,
                    }
                }
            },
            .flow_normal, .ifc => unreachable,
        }
    }
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

fn pushBlock(
    layout: *ShrinkToFitLayoutContext,
    box_tree: *BoxTree,
    sc: *StackingContexts,
    used_sizes: BlockUsedSizes,
    available_width: ZssUnit,
    stacking_context: StackingContexts.Info,
    block_box: BlockBox,
) !?StackingContext.Id {
    // The allocations here must have corresponding deallocations in popBlock.
    try layout.widths.append(layout.allocator, .{ .auto = 0, .available = available_width });
    try layout.heights.append(layout.allocator, used_sizes.get(.block_size));
    const id = try sc.push(stacking_context, box_tree, block_box);
    return id;
}

fn popBlock(layout: *ShrinkToFitLayoutContext, box_tree: *BoxTree, sc: *StackingContexts) struct { auto_width: ZssUnit } {
    // The deallocations here must correspond to allocations in pushBlock.
    _ = layout.heights.pop();
    sc.pop(box_tree);
    return .{
        .auto_width = layout.widths.pop().auto,
    };
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
    used: BlockUsedSizes,
    stacking_context: ?StackingContext.Id,
    used_margins: UsedMargins,
    box_offsets: *used_values.BoxOffsets,
    borders: *used_values.Borders,
    margins: *used_values.Margins,
    @"type": *used_values.BlockType,
) void {
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
}

fn flowBlockSetHorizontalMargins(used_margins: UsedMargins, margins: *used_values.Margins) void {
    margins.left = used_margins.get(.inline_start).?;
    margins.right = used_margins.get(.inline_end).?;
}
