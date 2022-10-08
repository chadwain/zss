const std = @import("std");
const assert = std.debug.assert;
const panic = std.debug.panic;
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const ArrayListAlignedUnmanaged = std.ArrayListAlignedUnmanaged;
const MultiArrayList = std.MultiArrayList;

const zss = @import("../../zss.zig");
const ElementIndex = zss.ElementIndex;

const normal = @import("./normal.zig");
const BlockLayoutContext = normal.BlockLayoutContext;
const FlowBlockComputedSizes = normal.FlowBlockComputedSizes;
const FlowBlockUsedSizes = normal.FlowBlockUsedSizes;

const inline_layout = @import("./inline.zig");

const solve = @import("./solve.zig");
const StackingContexts = @import("./StackingContexts.zig");
const StyleComputer = @import("./StyleComputer.zig");

const used_values = @import("./used_values.zig");
const ZssUnit = used_values.ZssUnit;
const units_per_pixel = used_values.units_per_pixel;
const BlockBoxIndex = used_values.BlockBoxIndex;
const BlockBoxSkip = used_values.BlockBoxSkip;
const BlockBoxTree = used_values.BlockBoxTree;
const BlockSubtreeIndex = used_values.SubtreeIndex;
const StackingContextIndex = used_values.StackingContextIndex;
const InlineFormattingContext = used_values.InlineFormattingContext;
const GeneratedBox = used_values.GeneratedBox;
const BoxTree = used_values.BoxTree;

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
                .ifc => struct { layout_result: inline_layout.InlineLayoutContext.Result, line_split_result: inline_layout.IFCLineSplitResult },
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

pub const ShrinkToFitLayoutContext = struct {
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

    pub fn initFlow(allocator: Allocator, computer: *const StyleComputer, element: ElementIndex, used_sizes: FlowBlockUsedSizes, available_width: ZssUnit) !ShrinkToFitLayoutContext {
        var result = ShrinkToFitLayoutContext{ .allocator = allocator };
        errdefer result.deinit();

        try result.objects.tree.ensureTotalCapacity(result.allocator, computer.element_tree_skips[element]);
        result.objects.tree.appendAssumeCapacity(.{ .skip = undefined, .tag = .flow_stf, .element = element });
        const data_index = try result.objects.allocData(result.allocator, .flow);
        const data_ptr = result.objects.getData(.flow, data_index);
        data_ptr.* = used_sizes;
        try result.object_stack.append(result.allocator, .{ .index = 0, .skip = 1, .data_index = data_index });
        try stfPushFlowBlock(&result, used_sizes, available_width);
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
    subtree_index: BlockSubtreeIndex,
) !void {
    const stf_root_element = computer.this_element.index;
    const saved_element_stack_len = computer.element_stack.items.len;
    try stfBuildObjectTree(layout, sc, computer, box_tree);
    computer.setElementDirectChild(.box_gen, stf_root_element);
    try computer.computeAndPushElement(.box_gen);
    try stfRealizeObjects(layout.objects, layout.allocator, sc, computer, box_tree, subtree_index);

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
                    const computed = solve.boxStyle(specified, .NonRoot);
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

                                layout.objects.tree.appendAssumeCapacity(.{ .skip = 1, .tag = .flow_normal, .element = element });
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
                                layout.objects.tree.appendAssumeCapacity(.{ .skip = undefined, .tag = .flow_stf, .element = element });

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
                            layout.objects.tree.appendAssumeCapacity(.{ .skip = 1, .tag = .none, .element = element });
                            layout.object_stack.items(.skip)[layout.object_stack.len - 1] += 1;
                            interval.begin += skip;
                        },
                        .inline_, .inline_block, .text => {
                            const result = try inline_layout.makeInlineFormattingContext(
                                layout.allocator,
                                sc,
                                computer,
                                box_tree,
                                .ShrinkToFit,
                                containing_block_available_width,
                                containing_block_height,
                            );
                            const ifc = box_tree.ifcs.items[result.ifc_index];
                            const line_split_result = try inline_layout.splitIntoLineBoxes(layout.allocator, box_tree, ifc, containing_block_available_width);

                            const parent_auto_width = &layout.widths.items(.auto)[layout.widths.len - 1];
                            parent_auto_width.* = std.math.max(parent_auto_width.*, line_split_result.longest_line_box_length);

                            const data_index = try layout.objects.allocData(layout.allocator, .ifc);
                            const data = layout.objects.getData(.ifc, data_index);
                            data.* = .{ .layout_result = result, .line_split_result = line_split_result };
                            try layout.objects.tree.append(layout.allocator, .{ .skip = 1, .tag = .ifc, .element = undefined });
                            layout.object_stack.items(.skip)[layout.object_stack.len - 1] += 1;
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
    blocks: MultiArrayList(struct { subtree: BlockSubtreeIndex, index: BlockBoxIndex, skip: BlockBoxSkip }) = .{},
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

fn stfRealizeObjects(
    objects: StfObjects,
    allocator: Allocator,
    sc: *StackingContexts,
    computer: *StyleComputer,
    box_tree: *BoxTree,
    initial_subtree: BlockSubtreeIndex,
) !void {
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
                const block = try normal.createBlock(box_tree, &box_tree.blocks.subtrees.items[initial_subtree]);
                block.properties.* = .{};

                const used_sizes: *FlowBlockUsedSizes = objects.getData2(.flow, &data_index_mutable);
                // NOTE: Should we call normal.flowBlockAdjustWidthAndMargins?
                // Maybe. It depends on the outer context.
                normal.flowBlockSetData(used_sizes.*, block.box_offsets, block.borders, block.margins);
                box_tree.element_index_to_generated_box[element] = .{ .block_box = .{ .subtree = initial_subtree, .index = block.index } };

                try layout.blocks.append(allocator, .{ .subtree = initial_subtree, .index = block.index, .skip = 1 });
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
                        const subtree_index = layout.blocks.items(.subtree)[layout.blocks.len - 1];
                        const subtree = &box_tree.blocks.subtrees.items[subtree_index];
                        const block = try normal.createBlock(box_tree, subtree);
                        block.properties.* = .{};

                        const used_sizes: *FlowBlockUsedSizes = objects.getData2(.flow, &data_index_mutable);
                        normal.flowBlockAdjustWidthAndMargins(used_sizes, containing_block_width);
                        normal.flowBlockSetData(used_sizes.*, block.box_offsets, block.borders, block.margins);
                        box_tree.element_index_to_generated_box[element] = .{ .block_box = .{ .subtree = subtree_index, .index = block.index } };

                        try layout.objects.append(allocator, .{ .tag = .flow_stf, .interval = .{ .begin = index + 1, .end = index + skip }, .data_index = data_index });
                        try layout.blocks.append(allocator, .{ .subtree = subtree_index, .index = block.index, .skip = 1 });
                        try layout.width.append(allocator, used_sizes.get(.inline_size).?);
                        try layout.height.append(allocator, used_sizes.get(.block_size));
                        try layout.auto_height.append(allocator, 0);
                    },
                    .flow_normal => {
                        const subtree_index = layout.blocks.items(.subtree)[layout.blocks.len - 1];
                        const subtree = &box_tree.blocks.subtrees.items[subtree_index];
                        const block = try normal.createBlock(box_tree, subtree);
                        block.properties.* = .{};

                        const used_sizes: *FlowBlockUsedSizes = objects.getData2(.flow, &data_index_mutable);
                        normal.flowBlockAdjustWidthAndMargins(used_sizes, containing_block_width);
                        normal.flowBlockSetData(used_sizes.*, block.box_offsets, block.borders, block.margins);
                        box_tree.element_index_to_generated_box[element] = .{ .block_box = .{ .subtree = subtree_index, .index = block.index } };

                        var new_block_layout = BlockLayoutContext{ .allocator = allocator };
                        defer new_block_layout.deinit();
                        const containing_block_height = layout.height.items[layout.height.items.len - 1];
                        try normal.pushContainingBlock(&new_block_layout, containing_block_width, containing_block_height);
                        try normal.pushFlowBlock(&new_block_layout, subtree_index, block.index, used_sizes.*);
                        // TODO: The stacking context that gets pushed should be determined when building the object tree.
                        try sc.pushStackingContext(.none);
                        try computer.setElementAny(.box_gen, element);
                        try computer.computeAndPushElement(.box_gen);
                        var frame = try allocator.create(@Frame(normal.mainLoop));
                        defer allocator.destroy(frame);

                        nosuspend {
                            frame.* = async normal.mainLoop(&new_block_layout, sc, computer, box_tree);
                            try await frame.*;
                        }

                        computer.popElement(.box_gen);

                        const block_skip = subtree.skips.items[block.index];
                        layout.blocks.items(.skip)[layout.blocks.len - 1] += block_skip;
                        const parent_auto_height = &layout.auto_height.items[layout.auto_height.items.len - 1];
                        const box_offsets = &subtree.box_offsets.items[block.index];
                        const margin_bottom = subtree.margins.items[block.index].bottom;
                        normal.addBlockToFlow(box_offsets, margin_bottom, parent_auto_height);
                    },
                    .ifc => {
                        const subtree_index = layout.blocks.items(.subtree)[layout.blocks.len - 1];
                        const subtree = &box_tree.blocks.subtrees.items[subtree_index];
                        const data = objects.getData2(.ifc, &data_index_mutable);
                        const ifc = box_tree.ifcs.items[data.layout_result.ifc_index];

                        {
                            const block = try normal.createBlock(box_tree, subtree);
                            block.skip.* = 1;
                            block.properties.* = .{ .subtree_root = ifc.subtree_index };
                            layout.blocks.items(.skip)[layout.blocks.len - 1] += 1;
                        }

                        const parent_auto_height = &layout.auto_height.items[layout.auto_height.items.len - 1];
                        ifc.origin = .{ .x = 0, .y = parent_auto_height.* };
                        ifc.parent_block = .{ .subtree = subtree_index, .index = layout.blocks.items(.index)[layout.blocks.len - 1] };

                        {
                            const ifc_subtree = &box_tree.blocks.subtrees.items[ifc.subtree_index];
                            ifc_subtree.box_offsets.items[0] = .{
                                .border_pos = .{ .x = 0, .y = parent_auto_height.* },
                                .border_size = .{ .w = containing_block_width, .h = data.line_split_result.height },
                                .content_pos = .{ .x = 0, .y = 0 },
                                .content_size = .{ .w = containing_block_width, .h = data.line_split_result.height },
                            };
                        }

                        normal.advanceFlow(parent_auto_height, data.line_split_result.height);
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

                const subtree = &box_tree.blocks.subtrees.items[block.subtree];
                const used_sizes = objects.getData(.flow, data_index);
                const box_offsets = &subtree.box_offsets.items[block.index];

                subtree.skips.items[block.index] = block.skip;
                normal.flowBlockFinishLayout(box_offsets, used_sizes.getUsedContentHeight(), auto_height);

                if (layout.objects.len > 0) {
                    switch (layout.objects.items(.tag)[layout.objects.len - 1]) {
                        .flow_stf => {
                            layout.blocks.items(.skip)[layout.blocks.len - 1] += block.skip;
                            const parent_auto_height = &layout.auto_height.items[layout.auto_height.items.len - 1];
                            const margin_bottom = subtree.margins.items[block.index].bottom;
                            normal.addBlockToFlow(box_offsets, margin_bottom, parent_auto_height);
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
    try normal.flowBlockSolveContentHeight(specified.content_height, containing_block_height, &computed.content_height, used);
    try normal.flowBlockSolveVerticalEdges(specified.vertical_edges, 0, specified.border_styles, &computed.vertical_edges, used);

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
            used.min_inline_size = try solve.positiveLength(.px, value);
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
            used.max_inline_size = try solve.positiveLength(.px, value);
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
            used.set(.inline_size, try solve.positiveLength(.px, value));
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
        const multiplier = solve.borderWidthMultiplier(border_styles.left);
        switch (specified.border_start) {
            .px => |value| {
                const width = value * multiplier;
                computed.border_start = .{ .px = width };
                used.border_inline_start = try solve.positiveLength(.px, width);
            },
            .thin => {
                const width = solve.borderWidth(.thin) * multiplier;
                computed.border_start = .{ .px = width };
                used.border_inline_start = solve.positiveLength(.px, width) catch unreachable;
            },
            .medium => {
                const width = solve.borderWidth(.medium) * multiplier;
                computed.border_start = .{ .px = width };
                used.border_inline_start = solve.positiveLength(.px, width) catch unreachable;
            },
            .thick => {
                const width = solve.borderWidth(.thick) * multiplier;
                computed.border_start = .{ .px = width };
                used.border_inline_start = solve.positiveLength(.px, width) catch unreachable;
            },
            .initial, .inherit, .unset, .undeclared => unreachable,
        }
    }
    {
        const multiplier = solve.borderWidthMultiplier(border_styles.right);
        switch (specified.border_end) {
            .px => |value| {
                const width = value * multiplier;
                computed.border_end = .{ .px = width };
                used.border_inline_end = try solve.positiveLength(.px, width);
            },
            .thin => {
                const width = solve.borderWidth(.thin) * multiplier;
                computed.border_end = .{ .px = width };
                used.border_inline_end = solve.positiveLength(.px, width) catch unreachable;
            },
            .medium => {
                const width = solve.borderWidth(.medium) * multiplier;
                computed.border_end = .{ .px = width };
                used.border_inline_end = solve.positiveLength(.px, width) catch unreachable;
            },
            .thick => {
                const width = solve.borderWidth(.thick) * multiplier;
                computed.border_end = .{ .px = width };
                used.border_inline_end = solve.positiveLength(.px, width) catch unreachable;
            },
            .initial, .inherit, .unset, .undeclared => unreachable,
        }
    }

    switch (specified.padding_start) {
        .px => |value| {
            computed.padding_start = .{ .px = value };
            used.padding_inline_start = try solve.positiveLength(.px, value);
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
            used.padding_inline_end = try solve.positiveLength(.px, value);
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
            used.set(.margin_inline_start, solve.length(.px, value));
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
            used.set(.margin_inline_end, solve.length(.px, value));
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
