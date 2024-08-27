const std = @import("std");
const assert = std.debug.assert;
const panic = std.debug.panic;
const Allocator = std.mem.Allocator;
const MultiArrayList = std.MultiArrayList;

const zss = @import("../zss.zig");
const aggregates = zss.properties.aggregates;
const BlockComputedSizes = zss.Layout.BlockComputedSizes;
const BlockUsedSizes = zss.Layout.BlockUsedSizes;
const ElementTree = zss.ElementTree;
const Element = ElementTree.Element;
const Layout = zss.Layout;
const Stack = zss.util.Stack;

const flow = @import("./flow.zig");
const @"inline" = @import("./inline.zig");
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

pub fn runShrinkToFitLayout(layout: *Layout, subtree_id: SubtreeId, used_sizes: BlockUsedSizes, available_width: ZssUnit) !Result {
    var object_tree = ObjectTree{};
    defer object_tree.deinit(layout.allocator);

    var ctx = BuildObjectTreeContext{};
    defer ctx.deinit(layout.allocator);

    try pushMainObject(&ctx, &object_tree, layout.allocator, used_sizes, available_width);
    try buildObjectTree(layout, &ctx, &object_tree);
    return try realizeObjects(object_tree.slice(), layout.allocator, layout.box_tree, subtree_id);
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
            layout_result: @"inline".Result,
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
    layout: *Layout,
    ctx: *BuildObjectTreeContext,
    object_tree: *ObjectTree,
) !void {
    while (ctx.stack.top) |this| {
        const object_tag = object_tree.items(.tag)[this.object_index];
        switch (object_tag) {
            .flow_stf => try flowObject(layout, ctx, object_tree),
            .flow_normal, .ifc => unreachable,
        }
    }
}

fn flowObject(layout: *Layout, ctx: *BuildObjectTreeContext, object_tree: *ObjectTree) !void {
    const element = layout.currentElement();
    if (element.eqlNull()) {
        return popFlowObject(layout, ctx, object_tree);
    }
    try layout.computer.setCurrentElement(.box_gen, element);

    const computed, const used_box_style = blk: {
        if (layout.computer.elementCategory(element) == .text) {
            break :blk .{ undefined, used_values.BoxStyle{ .@"inline" = .text } };
        }

        const specified_box_style = layout.computer.getSpecifiedValue(.box_gen, .box_style);
        const computed_box_style, const used_box_style = solve.boxStyle(specified_box_style, .NonRoot);
        layout.computer.setComputedValue(.box_gen, .box_style, computed_box_style);
        break :blk .{ computed_box_style, used_box_style };
    };

    const parent = &ctx.stack.top.?;

    switch (used_box_style) {
        .block => |inner| switch (inner) {
            .flow => {
                var used: BlockUsedSizes = undefined;
                solveBlockSizes(&layout.computer, &used, parent.height);
                const stacking_context = flow.solveStackingContext(&layout.computer, computed.position);

                { // TODO: Delete this
                    const stuff = .{
                        .font = layout.computer.getSpecifiedValue(.box_gen, .font),
                    };
                    layout.computer.setComputedValue(.box_gen, .font, stuff.font);

                    layout.computer.commitElement(.box_gen);
                }

                const edge_width = used.margin_inline_start_untagged + used.margin_inline_end_untagged +
                    used.border_inline_start + used.border_inline_end +
                    used.padding_inline_start + used.padding_inline_end;

                if (used.get(.inline_size)) |inline_size| {
                    const new_subtree_id = try layout.box_tree.blocks.makeSubtree(layout.box_tree.allocator, null);
                    const subtree = layout.box_tree.blocks.subtree(new_subtree_id);
                    const result = try layout.createBlock(subtree, .flow, used, stacking_context);

                    parent.object_skip += 1;
                    parent.auto_width = @max(parent.auto_width, inline_size + edge_width);
                    try object_tree.append(layout.allocator, .{
                        .skip = 1,
                        .tag = .flow_normal,
                        .element = element,
                        .data = .{ .flow_normal = .{
                            .subtree_id = new_subtree_id,
                            .index = result.index,
                        } },
                    });
                } else {
                    const available_width = solve.clampSize(parent.available_width - edge_width, used.min_inline_size, used.max_inline_size);
                    try pushFlowObject(layout, ctx, object_tree, element, used, available_width, stacking_context);
                }
            },
        },
        .none => layout.advanceElement(),
        .@"inline" => {
            const new_subtree_id = try layout.box_tree.blocks.makeSubtree(layout.box_tree.allocator, null);

            const result = try @"inline".runInlineLayout(layout, new_subtree_id, .ShrinkToFit, parent.available_width, parent.height);

            parent.auto_width = @max(parent.auto_width, result.min_width);

            // TODO: Store the IFC index as the element
            parent.object_skip += 1;
            try object_tree.append(layout.allocator, .{
                .skip = 1,
                .tag = .ifc,
                .element = undefined,
                .data = .{ .ifc = .{
                    .subtree_id = new_subtree_id,
                    .layout_result = result,
                } },
            });
        },
        .absolute => std.debug.panic("TODO: Absolute blocks within shrink-to-fit contexts", .{}),
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
    layout: *Layout,
    ctx: *BuildObjectTreeContext,
    object_tree: *ObjectTree,
    element: Element,
    used_sizes: BlockUsedSizes,
    available_width: ZssUnit,
    stacking_context: StackingContexts.Info,
) !void {
    // The allocations here must have corresponding deallocations in popFlowObject.
    try ctx.stack.push(layout.allocator, .{
        .object_index = @intCast(object_tree.len),
        .object_skip = 1,
        .auto_width = 0,
        .available_width = available_width,
        .height = used_sizes.get(.block_size),
    });
    const stacking_context_id = try layout.sc.push(stacking_context, layout.box_tree, undefined);
    try layout.pushElement();

    try object_tree.append(layout.allocator, .{
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

fn popFlowObject(layout: *Layout, ctx: *BuildObjectTreeContext, object_tree: *ObjectTree) void {
    // The deallocations here must correspond to allocations in pushFlowObject.
    const this = ctx.stack.pop();
    const object_tree_slice = object_tree.slice();
    object_tree_slice.items(.skip)[this.object_index] = this.object_skip;
    const data = &object_tree_slice.items(.data)[this.object_index].flow_stf;
    const used = data.used;
    data.width = solve.clampSize(this.auto_width, used.min_inline_size, used.max_inline_size);

    const parent = if (ctx.stack.top) |*top| top else return;
    layout.sc.pop(layout.box_tree);
    layout.popElement();

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
                            subtree.setSubtreeProxy(proxy_index, data.subtree_id);
                            new_subtree.parent = .{ .subtree = main_subtree_id, .index = proxy_index };
                            parent.skip += 1;
                        }

                        const new_subtree_slice = new_subtree.slice();
                        flow.addBlockToFlow(new_subtree_slice, data.index, &parent.auto_height);
                    },
                    .ifc => {
                        const data = datas[object_index].ifc;
                        const new_subtree = box_tree.blocks.subtree(data.subtree_id);

                        const proxy_index = try subtree.appendBlock(box_tree.allocator);
                        subtree.setSubtreeProxy(proxy_index, data.subtree_id);
                        new_subtree.parent = .{ .subtree = main_subtree_id, .index = proxy_index };
                        parent.skip += 1;

                        flow.advanceFlow(&parent.auto_height, data.layout_result.height);
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
