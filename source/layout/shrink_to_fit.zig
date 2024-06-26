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
const BoxTree = used_values.BoxTree;
const BlockBox = used_values.BlockBox;
const BlockBoxIndex = used_values.BlockBoxIndex;
const BlockBoxSkip = used_values.BlockBoxSkip;
const BlockSubtree = used_values.BlockSubtree;
const GeneratedBox = used_values.GeneratedBox;
const StackingContext = used_values.StackingContext;
const SubtreeId = used_values.SubtreeId;
const ZssUnit = used_values.ZssUnit;

pub const Result = struct {
    skip_of_children: BlockBoxSkip,
    width: ZssUnit,
    auto_height: ZssUnit,
};

pub fn runShrinkToFitLayout(
    allocator: Allocator,
    box_tree: *BoxTree,
    sc: *StackingContexts,
    computer: *StyleComputer,
    subtree_id: SubtreeId,
    used_sizes: BlockUsedSizes,
    available_width: ZssUnit,
) !Result {
    var object_tree = ObjectTree{};
    defer object_tree.deinit(allocator);

    var ctx = BuildObjectTreeContext{};
    defer ctx.deinit(allocator);

    try pushMainObject(&ctx, &object_tree, allocator, used_sizes, available_width);
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
            width: ZssUnit,
            used: BlockUsedSizes,
            stacking_context_id: ?StackingContext.Id,
        },
        flow_normal: struct {
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
                const stacking_context = flow.solveStackingContext(computer, computed.position);

                { // TODO: Delete this
                    const stuff = .{
                        .font = computer.getSpecifiedValue(.box_gen, .font),
                    };
                    computer.setComputedValue(.box_gen, .font, stuff.font);
                }

                const edge_width = used.margin_inline_start_untagged + used.margin_inline_end_untagged +
                    used.border_inline_start + used.border_inline_end +
                    used.padding_inline_start + used.padding_inline_end;

                if (used.get(.inline_size)) |inline_size| {
                    const new_subtree_id = try box_tree.blocks.makeSubtree(box_tree.allocator, undefined);
                    const subtree = box_tree.blocks.subtree(new_subtree_id);
                    const block_index = try subtree.appendBlock(box_tree.allocator);
                    const generated_box = GeneratedBox{ .block_box = .{ .subtree = new_subtree_id, .index = block_index } };
                    try box_tree.mapElementToBox(element, generated_box);

                    const stacking_context_id = try sc.push(stacking_context, box_tree, generated_box.block_box);
                    try computer.pushElement(.box_gen);
                    // TODO: Recursive call here
                    const result = try flow.runFlowLayout(allocator, box_tree, sc, computer, new_subtree_id, used);
                    sc.pop(box_tree);
                    computer.popElement(.box_gen);

                    const skip = 1 + result.skip_of_children;
                    const width = flow.solveUsedWidth(inline_size, used.min_inline_size, used.max_inline_size);
                    const height = flow.solveUsedHeight(used.get(.block_size), used.min_block_size, used.max_block_size, result.auto_height);
                    flow.writeBlockData(subtree.slice(), block_index, used, skip, width, height, stacking_context_id);

                    parent.object_skip += 1;
                    parent.auto_width = @max(parent.auto_width, inline_size + edge_width);
                    try object_tree.append(allocator, .{
                        .skip = 1,
                        .tag = .flow_normal,
                        .element = element,
                        .data = .{ .flow_normal = .{
                            .subtree_id = new_subtree_id,
                            .index = block_index,
                        } },
                    });
                } else {
                    const available_width = solve.clampSize(parent.available_width - edge_width, used.min_inline_size, used.max_inline_size);
                    try pushFlowObject(ctx, object_tree, allocator, computer, box_tree, sc, element, used, available_width, stacking_context);
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
        popFlowObject(ctx, object_tree, computer, box_tree, sc);
    }
}

fn pushMainObject(
    ctx: *BuildObjectTreeContext,
    object_tree: *ObjectTree,
    allocator: Allocator,
    used_sizes: BlockUsedSizes,
    available_width: ZssUnit,
) !void {
    // The allocations here must have corresponding deallocations in popFlowObject.
    ctx.stack.top = .{
        .object_index = @intCast(object_tree.len),
        .object_skip = 1,
        .auto_width = 0,
        .available_width = available_width,
        .height = used_sizes.get(.block_size),
    };
    try object_tree.append(allocator, .{
        .skip = undefined,
        .tag = .flow_stf,
        .element = undefined,
        .data = .{ .flow_stf = .{
            .width = undefined,
            .used = used_sizes,
            .stacking_context_id = undefined,
        } },
    });
}

fn pushFlowObject(
    ctx: *BuildObjectTreeContext,
    object_tree: *ObjectTree,
    allocator: Allocator,
    computer: *StyleComputer,
    box_tree: *BoxTree,
    sc: *StackingContexts,
    element: Element,
    used_sizes: BlockUsedSizes,
    available_width: ZssUnit,
    stacking_context: StackingContexts.Info,
) !void {
    // The allocations here must have corresponding deallocations in popFlowObject.
    try ctx.stack.push(allocator, .{
        .object_index = @intCast(object_tree.len),
        .object_skip = 1,
        .auto_width = 0,
        .available_width = available_width,
        .height = used_sizes.get(.block_size),
    });
    const stacking_context_id = try sc.push(stacking_context, box_tree, undefined);
    try computer.pushElement(.box_gen);

    try object_tree.append(allocator, .{
        .skip = undefined,
        .tag = .flow_stf,
        .element = element,
        .data = .{ .flow_stf = .{
            .width = undefined,
            .used = used_sizes,
            .stacking_context_id = stacking_context_id,
        } },
    });
}

fn popFlowObject(ctx: *BuildObjectTreeContext, object_tree: *ObjectTree, computer: *StyleComputer, box_tree: *BoxTree, sc: *StackingContexts) void {
    // The deallocations here must correspond to allocations in pushFlowObject.
    const this = ctx.stack.pop();
    const object_tree_slice = object_tree.slice();
    object_tree_slice.items(.skip)[this.object_index] = this.object_skip;
    const data = &object_tree_slice.items(.data)[this.object_index].flow_stf;
    const used = data.used;
    data.width = solve.clampSize(this.auto_width, used.min_inline_size, used.max_inline_size);

    const parent = if (ctx.stack.top) |*top| top else return;
    sc.pop(box_tree);
    computer.popElement(.box_gen);

    const parent_object_tag = object_tree_slice.items(.tag)[parent.object_index];
    switch (parent_object_tag) {
        .flow_stf => {
            const full_width = data.width +
                used.padding_inline_start + used.padding_inline_end +
                used.border_inline_start + used.border_inline_end +
                used.margin_inline_start_untagged + used.margin_inline_end_untagged;
            parent.auto_width = @max(parent.auto_width, full_width);
        },
        .flow_normal, .ifc => unreachable,
    }
    parent.object_skip += this.object_skip;
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
        const object_index: Object.Index = 0;
        const object_skip = object_skips[object_index];
        const object_tag = object_tags[object_index];
        switch (object_tag) {
            .flow_stf => {
                const data = datas[object_index].flow_stf;
                ctx.stack.top = .{
                    .object_index = 0,
                    .object_tag = object_tag,
                    .object_interval = .{ .begin = 1, .end = object_skip },

                    .index = undefined,
                    .skip = 0,
                    .width = data.width,
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
                        const generated_box = GeneratedBox{ .block_box = .{ .subtree = main_subtree_id, .index = block_index } };
                        try box_tree.mapElementToBox(element, generated_box);

                        try ctx.stack.push(allocator, .{
                            .object_index = object_index,
                            .object_tag = .flow_stf,
                            .object_interval = .{ .begin = object_index + 1, .end = object_index + object_skip },

                            .index = block_index,
                            .skip = 1,
                            .width = data.width,
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
    const parent = if (ctx.stack.top) |*top| top else {
        ctx.result = .{
            .skip_of_children = this.skip,
            .width = this.width,
            .auto_height = this.auto_height,
        };
        return;
    };

    const used_sizes = data.used;
    const subtree_slice = subtree.slice();
    const width = flow.solveUsedWidth(data.width, used_sizes.min_inline_size, used_sizes.max_inline_size);
    const height = flow.solveUsedHeight(used_sizes.get(.block_size), used_sizes.min_block_size, used_sizes.max_block_size, this.auto_height);
    flow.writeBlockData(subtree_slice, this.index, used_sizes, this.skip, width, height, data.stacking_context_id);
    flowBlockFixStackingContext(box_tree, .{ .subtree = subtree.id, .index = this.index }, data.stacking_context_id);

    switch (parent.object_tag) {
        .flow_stf => {
            parent.skip += this.skip;
            flow.addBlockToFlow(subtree_slice, this.index, &parent.auto_height);
        },
        .flow_normal, .ifc => unreachable,
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

fn flowBlockFixStackingContext(
    box_tree: *BoxTree,
    block_box: BlockBox,
    stacking_context: ?StackingContext.Id,
) void {
    if (stacking_context) |id| StackingContexts.fixup(box_tree, id, block_box);
}
