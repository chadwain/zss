const std = @import("std");
const assert = std.debug.assert;
const panic = std.debug.panic;
const Allocator = std.mem.Allocator;
const MultiArrayList = std.MultiArrayList;

const zss = @import("../zss.zig");
const aggregates = zss.properties.aggregates;
const BlockComputedSizes = zss.layout.BlockComputedSizes;
const BlockUsedSizes = zss.layout.BlockUsedSizes;
const ElementTree = zss.ElementTree;
const Element = ElementTree.Element;
const Stack = zss.util.Stack;

const flow = @import("./flow.zig");
const inline_layout = @import("./inline.zig");
const solve = @import("./solve.zig");
const StackingContexts = @import("./StackingContexts.zig");
const StyleComputer = @import("./StyleComputer.zig");

const used_values = zss.used_values;
const ZssUnit = used_values.ZssUnit;
const BlockBoxIndex = used_values.BlockBoxIndex;
const BlockBoxSkip = used_values.BlockBoxSkip;
const BlockSubtree = used_values.BlockSubtree;
const SubtreeId = used_values.SubtreeId;
const BlockBox = used_values.BlockBox;
const StackingContext = used_values.StackingContext;
const GeneratedBox = used_values.GeneratedBox;
const BoxTree = used_values.BoxTree;

pub const Result = struct {
    skip: BlockBoxSkip,
    index: BlockBoxIndex,
};

pub fn runShrinkToFitLayout(
    allocator: Allocator,
    box_tree: *BoxTree,
    sc: *StackingContexts,
    computer: *StyleComputer,
    element: Element,
    subtree_id: SubtreeId,
    used_sizes: BlockUsedSizes,
    stacking_context_info: StackingContexts.Info,
    available_width: ZssUnit,
) !Result {
    var object_tree = ObjectTree{};
    defer object_tree.deinit(allocator);

    var ctx = BuildObjectTreeContext{};
    defer ctx.deinit(allocator);
    try pushFlowObject(true, &ctx, &object_tree, allocator, box_tree, sc, element, used_sizes, available_width, stacking_context_info);
    try buildObjectTree(&ctx, &object_tree, allocator, sc, computer, box_tree);
    return try realizeObjects(object_tree.slice(), allocator, box_tree, subtree_id);
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
            subtree_id: SubtreeId,
            index: BlockBoxIndex,
        },
        ifc: struct {
            subtree_id: SubtreeId,
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
    stack: Stack(StackItem) = .{},

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
    while (ctx.stack.top) |this| {
        const object_tag = object_tree.items(.tag)[this.object_index];
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
    const element = computer.getCurrentElement();
    if (!element.eqlNull()) {
        const specified = computer.getSpecifiedValue(.box_gen, .box_style);
        const computed = solve.boxStyle(specified, .NonRoot);
        computer.setComputedValue(.box_gen, .box_style, computed);

        const parent = &ctx.stack.top.?;

        switch (computed.display) {
            .block => {
                var used: BlockUsedSizes = undefined;
                solveBlockSizes(computer, &used, parent.height);
                const stacking_context = flowBlockCreateStackingContext(computer, computed.position);

                { // TODO: Delete this
                    const stuff = .{
                        .font = computer.getSpecifiedValue(.box_gen, .font),
                    };
                    computer.setComputedValue(.box_gen, .font, stuff.font);
                }
                try computer.pushElement(.box_gen);

                const edge_width = used.margin_inline_start_untagged + used.margin_inline_end_untagged +
                    used.border_inline_start + used.border_inline_end +
                    used.padding_inline_start + used.padding_inline_end;

                if (used.get(.inline_size)) |inline_size| {
                    const new_subtree_id = try box_tree.blocks.makeSubtree(box_tree.allocator, undefined);
                    // TODO: Recursive call here
                    const result = try flow.runFlowLayout(
                        allocator,
                        box_tree,
                        sc,
                        computer,
                        element,
                        new_subtree_id,
                        used,
                        stacking_context,
                    );

                    parent.object_skip += 1;
                    parent.auto_width = @max(parent.auto_width, inline_size + edge_width);
                    try object_tree.append(allocator, .{
                        .skip = 1,
                        .tag = .flow_normal,
                        .element = element,
                        .data = .{ .flow_normal = .{
                            .margins = UsedMargins.fromBlockUsedSizes(used),
                            .subtree_id = new_subtree_id,
                            .index = result.index,
                        } },
                    });
                } else {
                    const available_width = solve.clampSize(parent.available_width - edge_width, used.min_inline_size, used.max_inline_size);
                    try pushFlowObject(false, ctx, object_tree, allocator, box_tree, sc, element, used, available_width, stacking_context);
                }
            },
            .none => computer.advanceElement(.box_gen),
            .@"inline", .inline_block, .text => {
                const new_subtree_id = try box_tree.blocks.makeSubtree(box_tree.allocator, undefined);
                const new_subtree = box_tree.blocks.subtree(new_subtree_id);
                const new_ifc_container_index = try new_subtree.appendBlock(box_tree.allocator);

                const result = try inline_layout.makeInlineFormattingContext(
                    allocator,
                    sc,
                    computer,
                    box_tree,
                    new_subtree_id,
                    .ShrinkToFit,
                    parent.available_width,
                    parent.height,
                );
                const ifc = box_tree.ifcs.items[result.ifc_index];
                const line_split_result = try inline_layout.splitIntoLineBoxes(
                    allocator,
                    box_tree,
                    new_subtree,
                    ifc,
                    parent.available_width,
                );

                parent.auto_width = @max(parent.auto_width, line_split_result.longest_line_box_length);

                // TODO: Store the IFC index as the element
                parent.object_skip += 1;
                try object_tree.append(allocator, .{
                    .skip = 1,
                    .tag = .ifc,
                    .element = undefined,
                    .data = .{ .ifc = .{
                        .subtree_id = new_subtree_id,
                        .subtree_root_index = new_ifc_container_index,
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
    comptime initial_push: bool,
    ctx: *BuildObjectTreeContext,
    object_tree: *ObjectTree,
    allocator: Allocator,
    box_tree: *BoxTree,
    sc: *StackingContexts,
    element: Element,
    used_sizes: BlockUsedSizes,
    available_width: ZssUnit,
    stacking_context: StackingContexts.Info,
) !void {
    // The allocations here must have corresponding deallocations in popFlowObject.
    const stack_item = BuildObjectTreeContext.StackItem{
        .object_index = @intCast(object_tree.len),
        .object_skip = 1,
        .auto_width = 0,
        .available_width = available_width,
        .height = used_sizes.get(.block_size),
    };
    if (initial_push) {
        ctx.stack.top = stack_item;
    } else {
        try ctx.stack.push(allocator, stack_item);
    }
    const id = try sc.push(stacking_context, box_tree, undefined);

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

    if (ctx.stack.top) |*parent| {
        const parent_object_tag = object_tree_slice.items(.tag)[parent.object_index];
        switch (parent_object_tag) {
            .flow_stf => {
                const full_width = used.inline_size_untagged +
                    used.padding_inline_start + used.padding_inline_end +
                    used.border_inline_start + used.border_inline_end +
                    used.margin_inline_start_untagged + used.margin_inline_end_untagged;
                parent.auto_width = @max(parent.auto_width, full_width);
            },
            .flow_normal, .ifc => unreachable,
        }
        parent.object_skip += this.object_skip;
    }
}

const RealizeObjectsContext = struct {
    stack: Stack(StackItem) = .{},
    result: Result = undefined,

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
    main_subtree_id: SubtreeId,
) !Result {
    const object_skips = object_tree_slice.items(.skip);
    const object_tags = object_tree_slice.items(.tag);
    const elements = object_tree_slice.items(.element);
    const datas = object_tree_slice.items(.data);

    const subtree = box_tree.blocks.subtree(main_subtree_id);

    var ctx = RealizeObjectsContext{};
    defer ctx.deinit(allocator);

    {
        const object_skip = object_skips[0];
        const object_tag = object_tags[0];
        const element = elements[0];
        switch (object_tag) {
            .flow_stf => {
                const data = datas[0].flow_stf;

                const block_index = try subtree.appendBlock(box_tree.allocator);
                const block_box = BlockBox{ .subtree = main_subtree_id, .index = block_index };
                const generated_box = GeneratedBox{ .block_box = block_box };
                try box_tree.element_to_generated_box.putNoClobber(box_tree.allocator, element, generated_box);

                ctx.stack.top = .{
                    .object_index = 0,
                    .object_tag = object_tag,
                    .object_interval = .{ .begin = 1, .end = object_skip },

                    .index = block_index,
                    .skip = 1,
                    .width = data.used.get(.inline_size).?,
                    .height = data.used.get(.block_size),
                    .auto_height = 0,
                };
            },
            .flow_normal, .ifc => unreachable,
        }
    }

    while (ctx.stack.top) |*parent| {
        switch (parent.object_tag) {
            .flow_stf => if (parent.object_interval.begin != parent.object_interval.end) {
                const object_index = parent.object_interval.begin;
                const object_skip = object_skips[object_index];
                const object_tag = object_tags[object_index];
                const element = elements[object_index];
                parent.object_interval.begin += object_skip;

                const containing_block_width = parent.width;
                switch (object_tag) {
                    .flow_stf => {
                        const data = &datas[object_index].flow_stf;

                        flow.adjustWidthAndMargins(&data.used, containing_block_width);

                        const block_index = try subtree.appendBlock(box_tree.allocator);
                        const block_box = BlockBox{ .subtree = main_subtree_id, .index = block_index };
                        const generated_box = GeneratedBox{ .block_box = block_box };
                        try box_tree.element_to_generated_box.putNoClobber(box_tree.allocator, element, generated_box);
                        flowBlockSetData(box_tree, block_box, data.used, data.stacking_context_id);
                        flowBlockFixStackingContext(box_tree, block_box, data.stacking_context_id);

                        try ctx.stack.push(allocator, .{
                            .object_index = object_index,
                            .object_tag = .flow_stf,
                            .object_interval = .{ .begin = object_index + 1, .end = object_index + object_skip },

                            .index = block_index,
                            .skip = 1,
                            .width = data.used.get(.inline_size).?,
                            .height = data.used.get(.block_size),
                            .auto_height = 0,
                        });
                    },
                    .flow_normal => {
                        const data = &datas[object_index].flow_normal;
                        const new_subtree = box_tree.blocks.subtree(data.subtree_id);

                        {
                            const proxy_index = try subtree.appendBlock(box_tree.allocator);
                            const subtree_slice = subtree.slice();
                            subtree_slice.items(.type)[proxy_index] = .{ .subtree_proxy = data.subtree_id };
                            subtree_slice.items(.skip)[proxy_index] = 1;
                            new_subtree.parent = .{ .subtree = main_subtree_id, .index = proxy_index };
                            parent.skip += 1;
                        }

                        const new_subtree_slice = new_subtree.slice();
                        flow.addBlockToFlow(new_subtree_slice, data.index, &parent.auto_height);
                    },
                    .ifc => {
                        const data = datas[object_index].ifc;
                        const new_subtree = box_tree.blocks.subtree(data.subtree_id);
                        const block_index = data.subtree_root_index;

                        // TODO: The proxy block should have its box_offsets value set, while the subtree root block should have default values
                        {
                            const proxy_index = try subtree.appendBlock(box_tree.allocator);
                            const subtree_slice = subtree.slice();
                            subtree_slice.items(.skip)[proxy_index] = 1;
                            subtree_slice.items(.type)[proxy_index] = .{ .subtree_proxy = data.subtree_id };
                            new_subtree.parent = .{ .subtree = main_subtree_id, .index = proxy_index };
                            parent.skip += 1;
                        }

                        const ifc = box_tree.ifcs.items[data.layout_result.ifc_index];
                        ifc.parent_block = .{ .subtree = main_subtree_id, .index = parent.index };

                        const new_subtree_slice = new_subtree.slice();
                        new_subtree_slice.items(.type)[block_index] = .{ .ifc_container = data.layout_result.ifc_index };
                        new_subtree_slice.items(.skip)[block_index] = 1 + data.layout_result.total_inline_block_skip;
                        new_subtree_slice.items(.box_offsets)[block_index] = .{
                            .border_pos = .{ .x = 0, .y = parent.auto_height },
                            .border_size = .{ .w = data.line_split_result.longest_line_box_length, .h = data.line_split_result.height },
                            .content_pos = .{ .x = 0, .y = 0 },
                            .content_size = .{ .w = data.line_split_result.longest_line_box_length, .h = data.line_split_result.height },
                        };

                        flow.advanceFlow(&parent.auto_height, data.line_split_result.height);
                    },
                }
            } else {
                popFlowBlock(&ctx, box_tree, object_tree_slice, subtree);
            },
            .flow_normal, .ifc => unreachable,
        }
    }

    return ctx.result;
}

fn popFlowBlock(ctx: *RealizeObjectsContext, box_tree: *BoxTree, object_tree_slice: ObjectTree.Slice, subtree: *BlockSubtree) void {
    const this = ctx.stack.pop();

    const data = object_tree_slice.items(.data)[this.object_index].flow_stf;
    const used_sizes = data.used;
    const subtree_slice = subtree.slice();
    const height = flow.solveUsedHeight(used_sizes.get(.block_size), used_sizes.min_block_size, used_sizes.max_block_size, this.auto_height);

    if (ctx.stack.top) |*parent| {
        flow.writeBlockDataPart2(subtree_slice, this.index, this.skip, height);
        switch (parent.object_tag) {
            .flow_stf => {
                parent.skip += this.skip;
                flow.addBlockToFlow(subtree_slice, this.index, &parent.auto_height);
            },
            .flow_normal, .ifc => unreachable,
        }
    } else {
        flow.writeBlockData(subtree_slice, this.index, used_sizes, this.skip, used_sizes.get(.inline_size).?, height, data.stacking_context_id);
        flowBlockFixStackingContext(box_tree, .{ .subtree = subtree.id, .index = this.index }, data.stacking_context_id);
        ctx.result = .{
            .skip = this.skip,
            .index = this.index,
        };
    }
}

fn solveBlockSizes(
    computer: *StyleComputer,
    used: *BlockUsedSizes,
    containing_block_height: ?ZssUnit,
) void {
    const border_styles = computer.getSpecifiedValue(.box_gen, .border_styles);
    const specified = BlockComputedSizes{
        .content_width = computer.getSpecifiedValue(.box_gen, .content_width),
        .content_height = computer.getSpecifiedValue(.box_gen, .content_height),
        .horizontal_edges = computer.getSpecifiedValue(.box_gen, .horizontal_edges),
        .vertical_edges = computer.getSpecifiedValue(.box_gen, .vertical_edges),
    };
    var computed: BlockComputedSizes = undefined;

    flowBlockSolveWidthAndHorizontalMargins(specified, &computed, used);
    flow.solveHorizontalBorderPadding(specified.horizontal_edges, 0, border_styles, &computed.horizontal_edges, used);
    flow.solveHeight(specified.content_height, containing_block_height, &computed.content_height, used);
    flow.solveVerticalEdges(specified.vertical_edges, 0, border_styles, &computed.vertical_edges, used);

    computer.setComputedValue(.box_gen, .content_width, computed.content_width);
    computer.setComputedValue(.box_gen, .horizontal_edges, computed.horizontal_edges);
    computer.setComputedValue(.box_gen, .content_height, computed.content_height);
    computer.setComputedValue(.box_gen, .vertical_edges, computed.vertical_edges);
    computer.setComputedValue(.box_gen, .border_styles, border_styles);
}

fn flowBlockSolveWidthAndHorizontalMargins(
    specified: BlockComputedSizes,
    computed: *BlockComputedSizes,
    used: *BlockUsedSizes,
) void {
    switch (specified.content_width.min_width) {
        .px => |value| {
            computed.content_width.min_width = .{ .px = value };
            used.min_inline_size = solve.positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.content_width.min_width = .{ .percentage = value };
            used.min_inline_size = 0;
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
            used.max_inline_size = std.math.maxInt(ZssUnit);
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
            used.setAuto(.inline_size);
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
            used.setAuto(.margin_inline_start);
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
            used.setAuto(.margin_inline_end);
        },
        .auto => {
            computed.horizontal_edges.margin_right = .auto;
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
) void {
    const subtree_slice = box_tree.blocks.subtree(block_box.subtree).slice();
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

    margins.left = used.get(.margin_inline_start).?;
    margins.right = used.get(.margin_inline_end).?;

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

fn flowBlockFixStackingContext(
    box_tree: *BoxTree,
    block_box: BlockBox,
    stacking_context: ?StackingContext.Id,
) void {
    if (stacking_context) |id| StackingContexts.fixup(box_tree, id, block_box);
}
