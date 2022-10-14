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

    const Index = ElementIndex;
    const Skip = Index;
    const DataIndex = usize;

    const Tag = enum {
        flow_stf,
        flow_normal,
        ifc,
        none,
    };

    const DataTag = enum {
        flow_stf,
        flow_normal,
        ifc,

        fn Type(comptime tag: DataTag) type {
            return switch (tag) {
                .flow_stf => struct { used: FlowBlockUsedSizes, stacking_context_ref: ?StackingContextRef },
                .flow_normal => struct { margins: UsedMargins, subtree_index: BlockSubtreeIndex },
                .ifc => struct { subtree_index: BlockSubtreeIndex, layout_result: inline_layout.InlineLayoutContext.Result, line_split_result: inline_layout.IFCLineSplitResult },
            };
        }
    };

    const Object = struct {
        skip: Skip,
        tag: Tag,
        element: ElementIndex,
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
        const bytes = @ptrCast([*]align(data_max_alignment) u8, chunks)[0..size];
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
        return self.auto_bitfield & @enumToInt(field) != 0;
    }

    fn set(self: *UsedMargins, comptime field: Field, value: ZssUnit) void {
        self.auto_bitfield &= (~@enumToInt(field));
        @field(self, @tagName(field) ++ "_untagged") = value;
    }

    fn get(self: UsedMargins, comptime field: Field) ?ZssUnit {
        return if (self.isFieldAuto(field)) null else @field(self, @tagName(field) ++ "_untagged");
    }

    fn fromFlowBlockUsedSizes(sizes: FlowBlockUsedSizes) UsedMargins {
        return UsedMargins{
            .inline_start_untagged = sizes.margin_inline_start_untagged,
            .inline_end_untagged = sizes.margin_inline_end_untagged,
            .auto_bitfield = (@as(u2, @boolToInt(sizes.isFieldAuto(.margin_inline_end))) << 1) |
                @as(u2, @boolToInt(sizes.isFieldAuto(.margin_inline_start))),
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
        computer: *const StyleComputer,
        element: ElementIndex,
        root_block_box: BlockBox,
        used_sizes: FlowBlockUsedSizes,
        available_width: ZssUnit,
    ) !ShrinkToFitLayoutContext {
        var result = ShrinkToFitLayoutContext{ .allocator = allocator, .root_block_box = root_block_box };
        errdefer result.deinit();

        try result.objects.tree.ensureTotalCapacity(result.allocator, computer.element_tree_skips[element]);
        result.objects.tree.appendAssumeCapacity(.{ .skip = undefined, .tag = .flow_stf, .element = element });
        const data_index = try result.objects.allocData(result.allocator, .flow_stf);
        const data_ptr = result.objects.getData(.flow_stf, data_index);
        data_ptr.* = .{ .used = used_sizes, .stacking_context_ref = undefined };
        try result.object_stack.append(result.allocator, .{ .index = 0, .skip = 1, .data_index = data_index });
        try pushFlowBlock(&result, used_sizes, available_width);
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
    try createObjects(layout.objects, layout.allocator, computer.element_tree_skips, box_tree, layout.root_block_box);
}

fn buildObjectTree(layout: *ShrinkToFitLayoutContext, sc: *StackingContexts, computer: *StyleComputer, box_tree: *BoxTree) !void {
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
                            var used: FlowBlockUsedSizes = undefined;
                            try solveFlowBlockSizes(computer, &used, containing_block_height);

                            const z_index = computer.getSpecifiedValue(.box_gen, .z_index);
                            computer.setComputedValue(.box_gen, .z_index, z_index);
                            const stacking_context_optional = stacking_context_optional: {
                                switch (computed.position) {
                                    .static => {
                                        try sc.pushStackingContext(.none, {});
                                        break :stacking_context_optional null;
                                    },
                                    // TODO: Position the block using the values of the 'inset' family of properties.
                                    .relative => switch (z_index.z_index) {
                                        .integer => |integer| {
                                            const stacking_context = try sc.createStackingContext(box_tree, undefined, integer);
                                            try sc.pushStackingContext(.is_parent, stacking_context.index);
                                            break :stacking_context_optional stacking_context;
                                        },
                                        .auto => {
                                            const stacking_context = try sc.createStackingContext(box_tree, undefined, 0);
                                            try sc.pushStackingContext(.is_non_parent, stacking_context.index);
                                            break :stacking_context_optional stacking_context;
                                        },
                                        .initial, .inherit, .unset, .undeclared => unreachable,
                                    },
                                    .absolute, .fixed, .sticky => panic("TODO: {s} positioning", .{@tagName(computed.position)}),
                                    .initial, .inherit, .unset, .undeclared => unreachable,
                                }
                            };

                            { // TODO: Delete this
                                const stuff = .{
                                    .font = computer.getSpecifiedValue(.box_gen, .font),
                                };
                                computer.setComputedValue(.box_gen, .font, stuff.font);
                            }
                            interval.begin += skip;
                            try computer.pushElement(.box_gen);

                            const edge_width = used.margin_inline_start_untagged + used.margin_inline_end_untagged +
                                used.border_inline_start + used.border_inline_end +
                                used.padding_inline_start + used.padding_inline_end;

                            if (used.get(.inline_size)) |inline_size| {
                                const parent_auto_width = &layout.widths.items(.auto)[layout.widths.len - 1];
                                parent_auto_width.* = std.math.max(parent_auto_width.*, inline_size + edge_width);

                                layout.objects.tree.appendAssumeCapacity(.{ .skip = 1, .tag = .flow_normal, .element = element });
                                layout.object_stack.items(.skip)[layout.object_stack.len - 1] += 1;

                                const data_index = try layout.objects.allocData(layout.allocator, .flow_normal);
                                const data = layout.objects.getData(.flow_normal, data_index);
                                data.* = .{
                                    .margins = UsedMargins.fromFlowBlockUsedSizes(used),
                                    .subtree_index = std.math.cast(BlockSubtreeIndex, box_tree.blocks.subtrees.items.len) orelse return error.TooManyBlockSubtrees,
                                };

                                const new_subtree = try box_tree.blocks.subtrees.addOne(box_tree.allocator);
                                new_subtree.* = .{ .parent = undefined };
                                const new_subtree_block = try normal.createBlock(box_tree, new_subtree);
                                new_subtree_block.type.* = .{ .block = .{ .stacking_context = undefined } };
                                normal.flowBlockSetData(used, new_subtree_block.box_offsets, new_subtree_block.borders, new_subtree_block.margins);

                                const generated_box = GeneratedBox{ .block_box = .{ .subtree = data.subtree_index, .index = new_subtree_block.index } };
                                box_tree.element_index_to_generated_box[element] = generated_box;
                                if (stacking_context_optional) |stacking_context| {
                                    StackingContexts.fixupStackingContextIndex(box_tree, stacking_context.index, generated_box.block_box);
                                    new_subtree_block.type.block.stacking_context = stacking_context.ref;
                                } else {
                                    new_subtree_block.type.block.stacking_context = null;
                                }

                                var new_block_layout = BlockLayoutContext{ .allocator = layout.allocator };
                                defer new_block_layout.deinit();
                                try normal.pushContainingBlock(&new_block_layout, 0, containing_block_height);
                                try normal.pushFlowBlock(&new_block_layout, data.subtree_index, new_subtree_block.index, used);

                                var frame = try layout.allocator.create(@Frame(normal.mainLoop));
                                defer layout.allocator.destroy(frame);
                                nosuspend {
                                    frame.* = async normal.mainLoop(&new_block_layout, sc, computer, box_tree);
                                    try await frame.*;
                                }
                            } else {
                                const parent_available_width = layout.widths.items(.available)[layout.widths.len - 1];
                                const available_width = solve.clampSize(parent_available_width - edge_width, used.min_inline_size, used.max_inline_size);
                                try pushFlowBlock(layout, used, available_width);

                                const data_index = try layout.objects.allocData(layout.allocator, .flow_stf);
                                const data = layout.objects.getData(.flow_stf, data_index);
                                data.* = .{
                                    .used = used,
                                    .stacking_context_ref = if (stacking_context_optional) |stacking_context| stacking_context.ref else null,
                                };

                                try layout.object_stack.append(layout.allocator, .{
                                    .index = @intCast(Objects.Index, layout.objects.tree.len),
                                    .skip = 1,
                                    .data_index = data_index,
                                });
                                layout.objects.tree.appendAssumeCapacity(.{ .skip = undefined, .tag = .flow_stf, .element = element });
                            }
                        },
                        .none => {
                            layout.objects.tree.appendAssumeCapacity(.{ .skip = 1, .tag = .none, .element = element });
                            layout.object_stack.items(.skip)[layout.object_stack.len - 1] += 1;
                            interval.begin += skip;
                        },
                        .inline_, .inline_block, .text => {
                            const new_subtree_index = std.math.cast(BlockSubtreeIndex, box_tree.blocks.subtrees.items.len) orelse return error.TooManyBlockSubtrees;
                            const new_subtree = try box_tree.blocks.subtrees.addOne(box_tree.allocator);
                            new_subtree.* = .{ .parent = undefined };

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
                            parent_auto_width.* = std.math.max(parent_auto_width.*, line_split_result.longest_line_box_length);

                            const data_index = try layout.objects.allocData(layout.allocator, .ifc);
                            const data = layout.objects.getData(.ifc, data_index);
                            data.* = .{ .subtree_index = new_subtree_index, .layout_result = result, .line_split_result = line_split_result };
                            // TODO: Store the IFC index as the element
                            layout.objects.tree.appendAssumeCapacity(.{ .skip = 1, .tag = .ifc, .element = undefined });
                            layout.object_stack.items(.skip)[layout.object_stack.len - 1] += 1;
                        },
                        .initial, .inherit, .unset, .undeclared => unreachable,
                    }
                } else {
                    const object_info = layout.object_stack.pop();
                    layout.objects.tree.items(.skip)[object_info.index] = object_info.skip;

                    const block_info = popFlowBlock(layout);
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
                                parent_auto_width.* = std.math.max(parent_auto_width.*, full_width);
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
    element_tree_skips: []const ElementIndex,
    box_tree: *BoxTree,
    root_block_box: BlockBox,
) !void {
    const skips = objects.tree.items(.skip);
    const tags = objects.tree.items(.tag);
    const elements = objects.tree.items(.element);

    const subtree = &box_tree.blocks.subtrees.items[root_block_box.subtree];

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

                const box_offsets = &subtree.box_offsets.items[root_block_box.index];
                const borders = &subtree.borders.items[root_block_box.index];
                const margins = &subtree.margins.items[root_block_box.index];
                // NOTE: Should we call normal.flowBlockAdjustWidthAndMargins?
                // Maybe. It depends on the outer context.
                const used_sizes = &data.used;
                normal.flowBlockSetData(used_sizes.*, box_offsets, borders, margins);

                try layout.blocks.append(allocator, .{ .index = root_block_box.index, .skip = 1 });
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
                        const data = objects.getData2(.flow_stf, &data_index_mutable);

                        const block = try normal.createBlock(box_tree, subtree);
                        block.type.* = .{ .block = .{ .stacking_context = data.stacking_context_ref } };

                        const used_sizes = data.used;
                        var used_margins = UsedMargins.fromFlowBlockUsedSizes(used_sizes);
                        flowBlockAdjustMargins(&used_margins, containing_block_width - block.box_offsets.border_size.w);
                        flowBlockSetData(used_sizes, used_margins, block.box_offsets, block.borders, block.margins);

                        const generated_box = GeneratedBox{ .block_box = .{ .subtree = root_block_box.subtree, .index = block.index } };
                        box_tree.element_index_to_generated_box[element] = generated_box;

                        if (data.stacking_context_ref) |stacking_context_ref| {
                            StackingContexts.fixupStackingContextRef(box_tree, stacking_context_ref, generated_box.block_box);
                        }

                        try layout.objects.append(allocator, .{ .tag = .flow_stf, .interval = .{ .begin = index + 1, .end = index + skip }, .data_index = data_index });
                        try layout.blocks.append(allocator, .{ .index = block.index, .skip = 1 });
                        try layout.width.append(allocator, used_sizes.get(.inline_size).?);
                        try layout.height.append(allocator, used_sizes.get(.block_size));
                        try layout.auto_height.append(allocator, 0);
                    },
                    .flow_normal => {
                        const data = objects.getData2(.flow_normal, &data_index_mutable);
                        const new_subtree = &box_tree.blocks.subtrees.items[data.subtree_index];

                        {
                            const proxy = try normal.createBlock(box_tree, subtree);
                            proxy.type.* = .{ .subtree_proxy = data.subtree_index };
                            proxy.skip.* = 1;
                            new_subtree.parent = .{ .subtree = root_block_box.subtree, .index = proxy.index };
                            layout.blocks.items(.skip)[layout.blocks.len - 1] += 1;
                        }

                        const box_offsets = &new_subtree.box_offsets.items[0];
                        flowBlockAdjustMargins(&data.margins, containing_block_width - box_offsets.border_size.w);
                        const margins = &new_subtree.margins.items[0];
                        flowBlockSetHorizontalMargins(data.margins, margins);

                        const parent_auto_height = &layout.auto_height.items[layout.auto_height.items.len - 1];
                        normal.addBlockToFlow(box_offsets, margins.bottom, parent_auto_height);
                    },
                    .ifc => {
                        const data = objects.getData2(.ifc, &data_index_mutable);
                        const new_subtree = &box_tree.blocks.subtrees.items[data.subtree_index];

                        {
                            const proxy = try normal.createBlock(box_tree, subtree);
                            proxy.skip.* = 1;
                            proxy.type.* = .{ .subtree_proxy = data.subtree_index };
                            new_subtree.parent = .{ .subtree = root_block_box.subtree, .index = proxy.index };
                            layout.blocks.items(.skip)[layout.blocks.len - 1] += 1;
                        }

                        const ifc = box_tree.ifcs.items[data.layout_result.ifc_index];
                        const parent_auto_height = &layout.auto_height.items[layout.auto_height.items.len - 1];
                        ifc.origin = .{ .x = 0, .y = parent_auto_height.* };
                        ifc.parent_block = .{ .subtree = root_block_box.subtree, .index = layout.blocks.items(.index)[layout.blocks.len - 1] };

                        normal.advanceFlow(parent_auto_height, data.line_split_result.height);
                    },
                    .none => {
                        std.mem.set(GeneratedBox, box_tree.element_index_to_generated_box[element..][0..element_tree_skips[element]], .none);
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
                const box_offsets = &subtree.box_offsets.items[block.index];

                subtree.skip.items[block.index] = block.skip;
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

fn pushFlowBlock(layout: *ShrinkToFitLayoutContext, used_sizes: FlowBlockUsedSizes, available_width: ZssUnit) !void {
    // The allocations here must have corresponding deallocations in popFlowBlock.
    try layout.widths.append(layout.allocator, .{ .auto = 0, .available = available_width });
    try layout.heights.append(layout.allocator, used_sizes.get(.block_size));
}

fn popFlowBlock(layout: *ShrinkToFitLayoutContext) struct { auto_width: ZssUnit } {
    // The deallocations here must correspond to allocations in pushFlowBlock.
    _ = layout.heights.pop();
    return .{
        .auto_width = layout.widths.pop().auto,
    };
}

fn flowBlockSolveContentWidth(
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
            used.setAuto(.inline_size);
        },
        .auto => {
            computed.size = .auto;
            used.setAuto(.inline_size);
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
}

fn flowBlockSolveHorizontalEdges(
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
            used.setAuto(.margin_inline_start);
        },
        .auto => {
            computed.margin_start = .auto;
            used.setAuto(.margin_inline_start);
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
            used.setAuto(.margin_inline_end);
        },
        .auto => {
            computed.margin_end = .auto;
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
        const shr_amount = @boolToInt(start and end);
        const leftover_margin = std.math.max(0, available_margin_space - (margins.inline_start_untagged + margins.inline_end_untagged));
        // TODO the margin that gets the extra 1 unit shall be determined by the 'direction' property
        if (start) margins.set(.inline_start, leftover_margin >> shr_amount);
        if (end) margins.set(.inline_end, (leftover_margin >> shr_amount) + @mod(leftover_margin, 2));
    }
}

fn flowBlockSetData(
    used: FlowBlockUsedSizes,
    used_margins: UsedMargins,
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
