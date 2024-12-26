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
const SctBuilder = Layout.StackingContextTreeBuilder;
const Stack = zss.Stack;
const StyleComputer = Layout.StyleComputer;
const Unit = zss.math.Unit;

const flow = @import("./flow.zig");
const @"inline" = @import("./inline.zig");
const solve = @import("./solve.zig");

const BoxTree = zss.BoxTree;
const BlockRef = BoxTree.BlockRef;
const GeneratedBox = BoxTree.GeneratedBox;
const StackingContextTree = BoxTree.StackingContextTree;
const Subtree = BoxTree.Subtree;

pub const Result = struct {
    auto_width: Unit,
    auto_height: Unit,
};

pub fn runShrinkToFitLayout(layout: *Layout, used_sizes: BlockUsedSizes, available_width: Unit) !Result {
    var object_tree = ObjectTree{};
    defer object_tree.deinit(layout.allocator);

    var ctx = BuildObjectTreeContext{};
    defer ctx.deinit(layout.allocator);

    try pushMainObject(&ctx, &object_tree, layout.allocator, used_sizes, available_width);
    try buildObjectTree(layout, &ctx, &object_tree);
    return try realizeObjects(layout, object_tree.slice(), layout.allocator);
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
            width_clamped: Unit,
            used: BlockUsedSizes,
            stacking_context_id: ?StackingContextTree.Id,
            absolute_containing_block_id: ?Layout.Absolute.ContainingBlock.Id,
        },
        flow_normal: BlockRef,
        ifc: struct {
            subtree_id: Subtree.Id,
            layout_result: @"inline".Result,
        },
    };
};

const ObjectTree = MultiArrayList(Object);

const BuildObjectTreeContext = struct {
    stack: Stack(StackItem) = .{},

    const StackItem = struct {
        object_index: Object.Index,
        object_skip: Object.Index,
        auto_width: Unit,
        available_width: Unit,
        height: ?Unit, // TODO: clamp the height
    };

    fn deinit(self: *BuildObjectTreeContext, allocator: Allocator) void {
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
            break :blk .{ undefined, BoxTree.BoxStyle.text };
        }

        const specified_box_style = layout.computer.getSpecifiedValue(.box_gen, .box_style);
        const computed_box_style, const used_box_style = solve.boxStyle(specified_box_style, .NonRoot);
        layout.computer.setComputedValue(.box_gen, .box_style, computed_box_style);
        break :blk .{ computed_box_style, used_box_style };
    };

    const parent = &ctx.stack.top.?;

    switch (used_box_style.outer) {
        .block => |inner| switch (inner) {
            .flow => {
                const used = solveBlockSizes(&layout.computer, used_box_style.position, parent.height);
                const stacking_context = flow.solveStackingContext(&layout.computer, computed.position);
                layout.computer.commitElement(.box_gen);

                const edge_width = used.margin_inline_start_untagged + used.margin_inline_end_untagged +
                    used.border_inline_start + used.border_inline_end +
                    used.padding_inline_start + used.padding_inline_end;

                if (used.get(.inline_size)) |inline_size| {
                    try layout.pushSubtree();
                    const ref = try layout.pushFlowBlock(used_box_style, used, stacking_context);
                    try layout.box_tree.setGeneratedBox(element, .{ .block_ref = ref });
                    try layout.pushElement();

                    try flow.runFlowLayout(layout);
                    layout.popFlowBlock();
                    layout.popSubtree();
                    layout.popElement();

                    parent.object_skip += 1;
                    parent.auto_width = @max(parent.auto_width, inline_size + edge_width);
                    try object_tree.append(layout.allocator, .{
                        .skip = 1,
                        .tag = .flow_normal,
                        .element = element,
                        .data = .{ .flow_normal = ref },
                    });
                } else {
                    const available_width = solve.clampSize(parent.available_width - edge_width, used.min_inline_size, used.max_inline_size);
                    try pushFlowObject(layout, ctx, object_tree, element, used_box_style, used, available_width, stacking_context);
                }
            },
        },
        .none => layout.advanceElement(),
        .@"inline" => {
            try layout.pushSubtree();
            const new_subtree_id = layout.currentSubtree();
            const result = try @"inline".runInlineLayout(layout, .ShrinkToFit, parent.available_width, parent.height);
            layout.popSubtree();

            parent.auto_width = @max(parent.auto_width, result.min_width);
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
    available_width: Unit,
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
            .width_clamped = undefined,
            .used = used_sizes,
            .stacking_context_id = undefined,
            .absolute_containing_block_id = undefined,
        } },
    });
}

fn pushFlowObject(
    layout: *Layout,
    ctx: *BuildObjectTreeContext,
    object_tree: *ObjectTree,
    element: Element,
    box_style: BoxTree.BoxStyle,
    used_sizes: BlockUsedSizes,
    available_width: Unit,
    stacking_context: SctBuilder.Type,
) !void {
    // The allocations here must have corresponding deallocations in popFlowObject.
    try ctx.stack.push(layout.allocator, .{
        .object_index = @intCast(object_tree.len),
        .object_skip = 1,
        .auto_width = 0,
        .available_width = available_width,
        .height = used_sizes.get(.block_size),
    });
    const stacking_context_id, const absolute_containing_block_id = try layout.pushStfFlowBlock(box_style, stacking_context);
    try layout.pushElement();

    try object_tree.append(layout.allocator, .{
        .skip = undefined,
        .tag = .flow_stf,
        .element = element,
        .data = .{ .flow_stf = .{
            .width_clamped = undefined,
            .used = used_sizes,
            .stacking_context_id = stacking_context_id,
            .absolute_containing_block_id = absolute_containing_block_id,
        } },
    });
}

fn popFlowObject(layout: *Layout, ctx: *BuildObjectTreeContext, object_tree: *ObjectTree) void {
    // The deallocations here must correspond to allocations in pushFlowObject.
    const this = ctx.stack.pop();
    const object_tree_slice = object_tree.slice();
    object_tree_slice.items(.skip)[this.object_index] = this.object_skip;
    const data = &object_tree_slice.items(.data)[this.object_index].flow_stf;
    data.width_clamped = flow.solveUsedWidth(this.auto_width, data.used.min_inline_size, data.used.max_inline_size);

    const parent = if (ctx.stack.top) |*top| top else return;

    layout.popStfFlowBlock();
    layout.popElement();

    const parent_object_tag = object_tree_slice.items(.tag)[parent.object_index];
    switch (parent_object_tag) {
        .flow_stf => {
            const full_width = data.width_clamped +
                data.used.padding_inline_start + data.used.padding_inline_end +
                data.used.border_inline_start + data.used.border_inline_end +
                data.used.margin_inline_start_untagged + data.used.margin_inline_end_untagged;
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

        width: Unit,
        auto_height: Unit,
    };

    fn deinit(ctx: *RealizeObjectsContext, allocator: Allocator) void {
        ctx.stack.deinit(allocator);
    }
};

fn realizeObjects(
    layout: *Layout,
    object_tree_slice: ObjectTree.Slice,
    allocator: Allocator,
) !Result {
    const object_skips = object_tree_slice.items(.skip);
    const object_tags = object_tree_slice.items(.tag);
    const elements = object_tree_slice.items(.element);
    const datas = object_tree_slice.items(.data);

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

                    .width = data.width_clamped,
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
                        // TODO: width/margins were used to set the parent block's auto_height earlier, but are being changed again here
                        flow.adjustWidthAndMargins(&data.used, containing_block_width);

                        const ref = try layout.pushStfFlowBlock2();
                        try layout.box_tree.setGeneratedBox(element, .{ .block_ref = ref });

                        try ctx.stack.push(allocator, .{
                            .object_index = object_index,
                            .object_tag = .flow_stf,
                            .object_interval = .{ .begin = object_index + 1, .end = object_index + object_skip },

                            .width = data.width_clamped,
                            .auto_height = 0,
                        });
                    },
                    .flow_normal => {
                        const data = &datas[object_index].flow_normal;
                        try layout.addSubtreeProxy(data.subtree);
                    },
                    .ifc => {
                        const data = datas[object_index].ifc;
                        try layout.addSubtreeProxy(data.subtree_id);
                    },
                }
            } else {
                popFlowBlock(layout, &ctx, object_tree_slice);
            },
            .flow_normal, .ifc => unreachable,
        }
    }

    return ctx.result;
}

fn popFlowBlock(layout: *Layout, ctx: *RealizeObjectsContext, object_tree_slice: ObjectTree.Slice) void {
    const this = ctx.stack.pop();
    if (ctx.stack.top == null) {
        ctx.result = .{
            .auto_width = this.width,
            .auto_height = this.auto_height,
        };
        return;
    }

    const data = object_tree_slice.items(.data)[this.object_index].flow_stf;
    layout.popStfFlowBlock2(
        data.width_clamped,
        data.used,
        data.stacking_context_id,
        data.absolute_containing_block_id,
    );
}

fn solveBlockSizes(
    computer: *StyleComputer,
    position: BoxTree.BoxStyle.Position,
    containing_block_height: ?Unit,
) BlockUsedSizes {
    const border_styles = computer.getSpecifiedValue(.box_gen, .border_styles);
    const specified = BlockComputedSizes{
        .content_width = computer.getSpecifiedValue(.box_gen, .content_width),
        .content_height = computer.getSpecifiedValue(.box_gen, .content_height),
        .horizontal_edges = computer.getSpecifiedValue(.box_gen, .horizontal_edges),
        .vertical_edges = computer.getSpecifiedValue(.box_gen, .vertical_edges),
        .insets = computer.getSpecifiedValue(.box_gen, .insets),
    };
    var computed: BlockComputedSizes = undefined;
    var used: BlockUsedSizes = undefined;

    flow.solveWidthAndHorizontalMargins(.ShrinkToFit, specified, {}, &computed, &used);
    flow.solveHorizontalBorderPadding(specified.horizontal_edges, 0, border_styles, &computed.horizontal_edges, &used);
    flow.solveHeight(specified.content_height, containing_block_height, &computed.content_height, &used);
    flow.solveVerticalEdges(specified.vertical_edges, 0, border_styles, &computed.vertical_edges, &used);

    computed.insets = solve.insets(specified.insets);
    flow.solveInsets(computed.insets, position, &used);

    computer.setComputedValue(.box_gen, .content_width, computed.content_width);
    computer.setComputedValue(.box_gen, .horizontal_edges, computed.horizontal_edges);
    computer.setComputedValue(.box_gen, .content_height, computed.content_height);
    computer.setComputedValue(.box_gen, .vertical_edges, computed.vertical_edges);
    computer.setComputedValue(.box_gen, .insets, computed.insets);
    computer.setComputedValue(.box_gen, .border_styles, border_styles);

    return used;
}
