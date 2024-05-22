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

const normal = @import("./normal.zig");
const BlockLayoutContext = normal.BlockLayoutContext;
const FlowBlockComputedSizes = normal.FlowBlockComputedSizes;
const FlowBlockUsedSizes = normal.FlowBlockUsedSizes;

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
const StackingContextIndex = used_values.StackingContextIndex;
const StackingContextRef = used_values.StackingContextRef;
const InlineFormattingContext = used_values.InlineFormattingContext;
const GeneratedBox = used_values.GeneratedBox;
const BoxTree = used_values.BoxTree;

const Objects = struct {
    tree: MultiArrayList(Object) = .{},
    data: ArrayListAlignedUnmanaged([data_chunk_size]u8, data_max_alignment) = .{},

    const data_chunk_size = 4;
    const data_max_alignment = 4;

    // This tree can store as many objects as ElementTree can.
    const Index = ElementTree.Size;
    const Skip = Index;
    const DataIndex = usize;

    const Tag = enum {
        flow_stf,
        flow_normal,
        ifc,
    };

    const DataTag = enum {
        flow_stf,
        flow_normal,
        ifc,

        fn Type(comptime tag: DataTag) type {
            return switch (tag) {
                .flow_stf => struct { used: FlowBlockUsedSizes, stacking_context_info: StackingContexts.Info },
                .flow_normal => struct { margins: UsedMargins, subtree_index: BlockSubtreeIndex },
                .ifc => struct {
                    subtree_index: BlockSubtreeIndex,
                    subtree_root_index: BlockBoxIndex,
                    layout_result: inline_layout.InlineLayoutContext.Result,
                    line_split_result: inline_layout.IFCLineSplitResult,
                },
            };
        }
    };

    const Object = struct {
        skip: Skip,
        tag: Tag,
        element: Element,
    };

    fn allocData(objects: *Objects, allocator: Allocator, comptime tag: DataTag) !DataIndex {
        const Data = tag.Type();
        const size = @sizeOf(Data);
        const num_chunks = zss.util.divCeil(size, data_chunk_size);
        try objects.data.ensureUnusedCapacity(allocator, num_chunks);
        defer objects.data.items.len += num_chunks;
        return objects.data.items.len;
    }

    fn getData(objects: *const Objects, comptime tag: DataTag, data_index: DataIndex) *tag.Type() {
        const Data = tag.Type();
        const size = @sizeOf(Data);
        const num_chunks = zss.util.divCeil(size, data_chunk_size);
        const chunks = objects.data.items[data_index..][0..num_chunks];
        const bytes = @as([*]align(data_max_alignment) u8, @ptrCast(chunks))[0..size];
        return std.mem.bytesAsValue(Data, bytes);
    }

    fn getData2(objects: *const Objects, comptime tag: DataTag, data_index: *DataIndex) *tag.Type() {
        const Data = tag.Type();
        const size = @sizeOf(Data);
        const num_chunks = zss.util.divCeil(size, data_chunk_size);
        defer data_index.* += num_chunks;
        return getData(objects, tag, data_index.*);
    }
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

    fn fromFlowBlockUsedSizes(sizes: FlowBlockUsedSizes) UsedMargins {
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

    root_block_box: BlockBox,
    allocator: Allocator,

    const ObjectStackItem = struct {
        index: Objects.Index,
        skip: Objects.Skip,
        data_index: Objects.DataIndex,
    };

    const Widths = struct {
        auto: ZssUnit,
        available: ZssUnit,
    };

    pub fn initFlow(
        allocator: Allocator,
        sc: *StackingContexts,
        element: Element,
        root_block_box: BlockBox,
        used_sizes: FlowBlockUsedSizes,
        stacking_context_info: StackingContexts.Info,
        available_width: ZssUnit,
    ) !ShrinkToFitLayoutContext {
        var result = ShrinkToFitLayoutContext{ .allocator = allocator, .root_block_box = root_block_box };
        errdefer result.deinit();

        try result.objects.tree.append(result.allocator, .{ .skip = undefined, .tag = .flow_stf, .element = element });
        const data_index = try result.objects.allocData(result.allocator, .flow_stf);
        const data_ptr = result.objects.getData(.flow_stf, data_index);
        data_ptr.* = .{ .used = used_sizes, .stacking_context_info = stacking_context_info };
        try result.object_stack.append(result.allocator, .{ .index = 0, .skip = 1, .data_index = data_index });
        try pushFlowBlock(&result, sc, used_sizes, available_width, stacking_context_info);
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
    try createObjects(layout.objects, layout.allocator, box_tree, layout.root_block_box);
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
                            var used: FlowBlockUsedSizes = undefined;
                            try solveFlowBlockSizes(computer, &used, containing_block_height);

                            const stacking_context = try flowBlockCreateStackingContext(box_tree, computer, sc, computed.position);

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

                                try layout.objects.tree.append(layout.allocator, .{ .skip = 1, .tag = .flow_normal, .element = element });
                                layout.object_stack.items(.skip)[layout.object_stack.len - 1] += 1;

                                const new_subtree_index = try box_tree.blocks.makeSubtree(box_tree.allocator, .{ .parent = undefined });
                                const new_subtree = box_tree.blocks.subtrees.items[new_subtree_index];

                                const data_index = try layout.objects.allocData(layout.allocator, .flow_normal);
                                const data = layout.objects.getData(.flow_normal, data_index);
                                data.* = .{
                                    .margins = UsedMargins.fromFlowBlockUsedSizes(used),
                                    .subtree_index = new_subtree_index,
                                };

                                const new_subtree_block = try normal.createBlock(box_tree, new_subtree);
                                normal.flowBlockSetData(
                                    used,
                                    stacking_context,
                                    new_subtree_block.box_offsets,
                                    new_subtree_block.borders,
                                    new_subtree_block.margins,
                                    new_subtree_block.type,
                                );

                                const generated_box = GeneratedBox{ .block_box = .{ .subtree = data.subtree_index, .index = new_subtree_block.index } };
                                try box_tree.element_to_generated_box.putNoClobber(box_tree.allocator, element, generated_box);
                                switch (stacking_context) {
                                    .none => {},
                                    .is_parent, .is_non_parent => |info| StackingContexts.fixupStackingContextRef(box_tree, info.ref, generated_box.block_box),
                                }

                                var new_block_layout = BlockLayoutContext{ .allocator = layout.allocator };
                                defer new_block_layout.deinit();
                                try normal.pushContainingBlock(&new_block_layout, 0, containing_block_height);
                                try normal.pushFlowBlock(&new_block_layout, sc, data.subtree_index, new_subtree_block.index, used, stacking_context);

                                // TODO: Recursive call here
                                try normal.mainLoop(&new_block_layout, sc, computer, box_tree);
                            } else {
                                const parent_available_width = layout.widths.items(.available)[layout.widths.len - 1];
                                const available_width = solve.clampSize(parent_available_width - edge_width, used.min_inline_size, used.max_inline_size);
                                try pushFlowBlock(layout, sc, used, available_width, stacking_context);

                                const data_index = try layout.objects.allocData(layout.allocator, .flow_stf);
                                const data = layout.objects.getData(.flow_stf, data_index);
                                data.* = .{
                                    .used = used,
                                    .stacking_context_info = stacking_context,
                                };

                                try layout.object_stack.append(layout.allocator, .{
                                    .index = @intCast(layout.objects.tree.len),
                                    .skip = 1,
                                    .data_index = data_index,
                                });
                                try layout.objects.tree.append(layout.allocator, .{ .skip = undefined, .tag = .flow_stf, .element = element });
                            }
                        },
                        .none => element_ptr.* = computer.element_tree_slice.nextSibling(element),
                        .inline_, .inline_block, .text => {
                            const new_subtree_index = try box_tree.blocks.makeSubtree(box_tree.allocator, .{ .parent = undefined });
                            const new_subtree = box_tree.blocks.subtrees.items[new_subtree_index];
                            const new_ifc_container = try normal.createBlock(box_tree, new_subtree);

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

                            const data_index = try layout.objects.allocData(layout.allocator, .ifc);
                            const data = layout.objects.getData(.ifc, data_index);
                            data.* = .{
                                .subtree_index = new_subtree_index,
                                .subtree_root_index = new_ifc_container.index,
                                .layout_result = result,
                                .line_split_result = line_split_result,
                            };
                            // TODO: Store the IFC index as the element
                            try layout.objects.tree.append(layout.allocator, .{ .skip = 1, .tag = .ifc, .element = undefined });
                            layout.object_stack.items(.skip)[layout.object_stack.len - 1] += 1;
                        },
                        .initial, .inherit, .unset, .undeclared => unreachable,
                    }
                } else {
                    const object_info = layout.object_stack.pop();
                    layout.objects.tree.items(.skip)[object_info.index] = object_info.skip;

                    const block_info = popFlowBlock(layout, sc);
                    const data = layout.objects.getData(.flow_stf, object_info.data_index);

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
    objects: MultiArrayList(struct { tag: Objects.Tag, interval: Interval, data_index: Objects.DataIndex }) = .{},
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

fn createObjects(
    objects: Objects,
    allocator: Allocator,
    box_tree: *BoxTree,
    root_block_box: BlockBox,
) !void {
    const skips = objects.tree.items(.skip);
    const tags = objects.tree.items(.tag);
    const elements = objects.tree.items(.element);

    const subtree = box_tree.blocks.subtrees.items[root_block_box.subtree];

    var data_index_mutable: Objects.DataIndex = 0;
    var layout = ShrinkToFitLayoutContext2{};
    defer layout.deinit(allocator);

    {
        const skip = skips[0];
        const tag = tags[0];
        const data_index = data_index_mutable;
        switch (tag) {
            .flow_stf => {
                const data = objects.getData2(.flow_stf, &data_index_mutable);

                const subtree_slice = subtree.slice();
                const box_offsets = &subtree_slice.items(.box_offsets)[root_block_box.index];
                const borders = &subtree_slice.items(.borders)[root_block_box.index];
                const margins = &subtree_slice.items(.margins)[root_block_box.index];
                const @"type" = &subtree_slice.items(.type)[root_block_box.index];
                // NOTE: Should we call normal.flowBlockAdjustWidthAndMargins?
                // Maybe. It depends on the outer context.
                const used_sizes = data.used;
                normal.flowBlockSetData(used_sizes, data.stacking_context_info, box_offsets, borders, margins, @"type");

                try layout.blocks.append(allocator, .{ .index = root_block_box.index, .skip = 1 });
                try layout.width.append(allocator, used_sizes.get(.inline_size).?);
                try layout.height.append(allocator, used_sizes.get(.block_size));
                try layout.auto_height.append(allocator, 0);
            },
            .flow_normal, .ifc => unreachable,
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
                        const data = objects.getData2(.flow_stf, &data_index_mutable);

                        const block = try normal.createBlock(box_tree, subtree);

                        const used_sizes = data.used;
                        const stacking_context = data.stacking_context_info;
                        var used_margins = UsedMargins.fromFlowBlockUsedSizes(used_sizes);
                        flowBlockAdjustMargins(&used_margins, containing_block_width - block.box_offsets.border_size.w);
                        flowBlockSetData(used_sizes, stacking_context, used_margins, block.box_offsets, block.borders, block.margins, block.type);

                        const generated_box = GeneratedBox{ .block_box = .{ .subtree = root_block_box.subtree, .index = block.index } };
                        try box_tree.element_to_generated_box.putNoClobber(box_tree.allocator, element, generated_box);

                        switch (data.stacking_context_info) {
                            .none => {},
                            .is_parent, .is_non_parent => |info| StackingContexts.fixupStackingContextRef(box_tree, info.ref, generated_box.block_box),
                        }

                        try layout.objects.append(allocator, .{ .tag = .flow_stf, .interval = .{ .begin = index + 1, .end = index + skip }, .data_index = data_index });
                        try layout.blocks.append(allocator, .{ .index = block.index, .skip = 1 });
                        try layout.width.append(allocator, used_sizes.get(.inline_size).?);
                        try layout.height.append(allocator, used_sizes.get(.block_size));
                        try layout.auto_height.append(allocator, 0);
                    },
                    .flow_normal => {
                        const data = objects.getData2(.flow_normal, &data_index_mutable);
                        const new_subtree = box_tree.blocks.subtrees.items[data.subtree_index];

                        {
                            const proxy = try normal.createBlock(box_tree, subtree);
                            proxy.type.* = .{ .subtree_proxy = data.subtree_index };
                            proxy.skip.* = 1;
                            new_subtree.parent = .{ .subtree = root_block_box.subtree, .index = proxy.index };
                            layout.blocks.items(.skip)[layout.blocks.len - 1] += 1;
                        }

                        const new_subtree_slice = new_subtree.slice();
                        const box_offsets = &new_subtree_slice.items(.box_offsets)[0];
                        flowBlockAdjustMargins(&data.margins, containing_block_width - box_offsets.border_size.w);
                        const margins = &new_subtree_slice.items(.margins)[0];
                        flowBlockSetHorizontalMargins(data.margins, margins);

                        const parent_auto_height = &layout.auto_height.items[layout.auto_height.items.len - 1];
                        normal.addBlockToFlow(box_offsets, margins.bottom, parent_auto_height);
                    },
                    .ifc => {
                        const data = objects.getData2(.ifc, &data_index_mutable);
                        const new_subtree = box_tree.blocks.subtrees.items[data.subtree_index];
                        const block_index = data.subtree_root_index;

                        // TODO: The proxy block should have its box_offsets value set, while the subtree root block should have default values
                        {
                            const proxy = try normal.createBlock(box_tree, subtree);
                            proxy.skip.* = 1;
                            proxy.type.* = .{ .subtree_proxy = data.subtree_index };
                            new_subtree.parent = .{ .subtree = root_block_box.subtree, .index = proxy.index };
                            layout.blocks.items(.skip)[layout.blocks.len - 1] += 1;
                        }

                        const ifc = box_tree.ifcs.items[data.layout_result.ifc_index];
                        ifc.parent_block = .{ .subtree = root_block_box.subtree, .index = layout.blocks.items(.index)[layout.blocks.len - 1] };

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

                        normal.advanceFlow(parent_auto_height, data.line_split_result.height);
                    },
                }
            } else {
                const data_index = layout.objects.pop().data_index;
                const block = layout.blocks.pop();
                _ = layout.width.pop();
                _ = layout.height.pop();
                const auto_height = layout.auto_height.pop();

                const data = objects.getData(.flow_stf, data_index);
                const used_sizes = data.used;
                const subtree_slice = subtree.slice();
                const box_offsets = &subtree_slice.items(.box_offsets)[block.index];

                subtree_slice.items(.skip)[block.index] = block.skip;
                normal.flowBlockFinishLayout(box_offsets, used_sizes.getUsedContentHeight(), auto_height);

                if (layout.objects.len > 0) {
                    switch (layout.objects.items(.tag)[layout.objects.len - 1]) {
                        .flow_stf => {
                            layout.blocks.items(.skip)[layout.blocks.len - 1] += block.skip;
                            const parent_auto_height = &layout.auto_height.items[layout.auto_height.items.len - 1];
                            const margin_bottom = subtree_slice.items(.margins)[block.index].bottom;
                            normal.addBlockToFlow(box_offsets, margin_bottom, parent_auto_height);
                        },
                        .flow_normal, .ifc => unreachable,
                    }
                }
            },
            .flow_normal, .ifc => unreachable,
        }
    }
}

fn solveFlowBlockSizes(
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

    try flowBlockSolveContentWidth(specified.content_width, &computed.content_width, used);
    try flowBlockSolveHorizontalEdges(specified.horizontal_edges, specified.border_styles, &computed.horizontal_edges, used);
    try normal.flowBlockSolveContentHeight(specified.content_height, containing_block_height, &computed.content_height, used);
    try normal.flowBlockSolveVerticalEdges(specified.vertical_edges, 0, specified.border_styles, &computed.vertical_edges, used);

    computer.setComputedValue(.box_gen, .content_width, computed.content_width);
    computer.setComputedValue(.box_gen, .horizontal_edges, computed.horizontal_edges);
    computer.setComputedValue(.box_gen, .content_height, computed.content_height);
    computer.setComputedValue(.box_gen, .vertical_edges, computed.vertical_edges);
    computer.setComputedValue(.box_gen, .border_styles, specified.border_styles);
}

fn pushFlowBlock(
    layout: *ShrinkToFitLayoutContext,
    sc: *StackingContexts,
    used_sizes: FlowBlockUsedSizes,
    available_width: ZssUnit,
    stacking_context: StackingContexts.Info,
) !void {
    // The allocations here must have corresponding deallocations in popFlowBlock.
    try layout.widths.append(layout.allocator, .{ .auto = 0, .available = available_width });
    try layout.heights.append(layout.allocator, used_sizes.get(.block_size));
    try sc.pushStackingContext(stacking_context);
}

fn popFlowBlock(layout: *ShrinkToFitLayoutContext, sc: *StackingContexts) struct { auto_width: ZssUnit } {
    // The deallocations here must correspond to allocations in pushFlowBlock.
    _ = layout.heights.pop();
    sc.popStackingContext();
    return .{
        .auto_width = layout.widths.pop().auto,
    };
}

fn flowBlockSolveContentWidth(
    specified: aggregates.ContentWidth,
    computed: *aggregates.ContentWidth,
    used: *FlowBlockUsedSizes,
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
    used: *FlowBlockUsedSizes,
) !void {
    {
        const multiplier = solve.borderWidthMultiplier(border_styles.left);
        switch (specified.border_left) {
            .px => |value| {
                const width = value * multiplier;
                computed.border_left = .{ .px = width };
                used.border_inline_start = try solve.positiveLength(.px, width);
            },
            .thin => {
                const width = solve.borderWidth(.thin) * multiplier;
                computed.border_left = .{ .px = width };
                used.border_inline_start = solve.positiveLength(.px, width) catch unreachable;
            },
            .medium => {
                const width = solve.borderWidth(.medium) * multiplier;
                computed.border_left = .{ .px = width };
                used.border_inline_start = solve.positiveLength(.px, width) catch unreachable;
            },
            .thick => {
                const width = solve.borderWidth(.thick) * multiplier;
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
            .thin => {
                const width = solve.borderWidth(.thin) * multiplier;
                computed.border_right = .{ .px = width };
                used.border_inline_end = solve.positiveLength(.px, width) catch unreachable;
            },
            .medium => {
                const width = solve.borderWidth(.medium) * multiplier;
                computed.border_right = .{ .px = width };
                used.border_inline_end = solve.positiveLength(.px, width) catch unreachable;
            },
            .thick => {
                const width = solve.borderWidth(.thick) * multiplier;
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
    box_tree: *BoxTree,
    computer: *StyleComputer,
    sc: *StackingContexts,
    position: zss.values.types.Position,
) !StackingContexts.Info {
    const z_index = computer.getSpecifiedValue(.box_gen, .z_index);
    computer.setComputedValue(.box_gen, .z_index, z_index);

    switch (position) {
        .static => return .none,
        // TODO: Position the block using the values of the 'inset' family of properties.
        .relative => switch (z_index.z_index) {
            .integer => |integer| return sc.createStackingContext(.is_parent, box_tree, undefined, integer),
            .auto => return sc.createStackingContext(.is_non_parent, box_tree, undefined, 0),
            .initial, .inherit, .unset, .undeclared => unreachable,
        },
        .absolute, .fixed, .sticky => panic("TODO: {s} positioning", .{@tagName(position)}),
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
}

fn flowBlockSetData(
    used: FlowBlockUsedSizes,
    stacking_context: StackingContexts.Info,
    used_margins: UsedMargins,
    box_offsets: *used_values.BoxOffsets,
    borders: *used_values.Borders,
    margins: *used_values.Margins,
    @"type": *used_values.BlockType,
) void {
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

    @"type".* = .{ .block = .{
        .stacking_context = switch (stacking_context) {
            .none => null,
            .is_parent, .is_non_parent => |info| info.ref,
        },
    } };
}

fn flowBlockSetHorizontalMargins(used_margins: UsedMargins, margins: *used_values.Margins) void {
    margins.left = used_margins.get(.inline_start).?;
    margins.right = used_margins.get(.inline_end).?;
}
