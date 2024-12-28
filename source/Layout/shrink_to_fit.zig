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
    var ctx = BuildObjectTreeContext{};
    defer ctx.deinit(layout.allocator);

    const main_object_index = try pushMainObject(layout, &ctx, used_sizes, available_width);
    try buildObjectTree(layout, &ctx);
    const result = try realizeObjects(layout, main_object_index);
    layout.endStfFlow();
    return result;
}

pub const Object = struct {
    skip: Index,
    tag: Tag,
    element: Element, // TODO: remove this field
    data: Data,

    // The object tree can store as many objects as ElementTree can.
    pub const Index = ElementTree.Size;

    pub const Tag = enum {
        flow_stf,
        flow_normal,
        ifc,
    };

    pub const Data = union {
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
) !void {
    while (ctx.stack.top) |this| {
        const object_tag = layout.stf_tree.items(.tag)[this.object_index];
        switch (object_tag) {
            .flow_stf => try flowObject(layout, ctx),
            .flow_normal, .ifc => unreachable,
        }
    }
}

fn flowObject(layout: *Layout, ctx: *BuildObjectTreeContext) !void {
    const element = layout.currentElement();
    if (element.eqlNull()) {
        return popFlowObject(layout, ctx);
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
                    try layout.appendStfFlowNormalBlock(ref, element);
                } else {
                    const available_width = solve.clampSize(parent.available_width - edge_width, used.min_inline_size, used.max_inline_size);
                    try pushFlowObject(layout, ctx, element, used_box_style, used, available_width, stacking_context);
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
            try layout.appendStfIfc(new_subtree_id, result);
        },
        .absolute => std.debug.panic("TODO: Absolute blocks within shrink-to-fit contexts", .{}),
    }
}

fn pushMainObject(
    layout: *Layout,
    ctx: *BuildObjectTreeContext,
    used_sizes: BlockUsedSizes,
    available_width: Unit,
) !Object.Index {
    // The allocations here must have corresponding deallocations in popFlowObject.
    const object_index = try layout.beginStfFlow(used_sizes);
    ctx.stack.top = .{
        .object_index = object_index,
        .object_skip = 1,
        .auto_width = 0,
        .available_width = available_width,
        .height = used_sizes.get(.block_size),
    };
    return object_index;
}

fn pushFlowObject(
    layout: *Layout,
    ctx: *BuildObjectTreeContext,
    element: Element,
    box_style: BoxTree.BoxStyle,
    used_sizes: BlockUsedSizes,
    available_width: Unit,
    stacking_context: SctBuilder.Type,
) !void {
    // The allocations here must have corresponding deallocations in popFlowObject.
    const object_index = try layout.pushStfFlowBlock(box_style, used_sizes, stacking_context, element);
    try layout.pushElement();
    try ctx.stack.push(layout.allocator, .{
        .object_index = object_index,
        .object_skip = 1,
        .auto_width = 0,
        .available_width = available_width,
        .height = used_sizes.get(.block_size),
    });
}

fn popFlowObject(layout: *Layout, ctx: *BuildObjectTreeContext) void {
    // The deallocations here must correspond to allocations in pushFlowObject.
    const this = ctx.stack.pop();
    layout.finishStfFlowObject(this.object_index, this.object_skip, this.auto_width);

    const parent = if (ctx.stack.top) |*top| top else return;

    const full_width = layout.popStfFlowBlock(this.object_index);
    layout.popElement();

    const parent_object_tag = layout.stf_tree.items(.tag)[this.object_index];
    switch (parent_object_tag) {
        .flow_stf => parent.auto_width = @max(parent.auto_width, full_width),
        .flow_normal, .ifc => unreachable,
    }
    parent.object_skip += this.object_skip;
}

const RealizeObjectsContext = struct {
    stack: Stack(StackItem) = .{},
    allocator: std.mem.Allocator,
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

    fn deinit(ctx: *RealizeObjectsContext) void {
        ctx.stack.deinit(ctx.allocator);
    }
};

fn realizeObjects(layout: *Layout, main_object_index: Object.Index) !Result {
    const object_tree_slice = layout.stf_tree.slice();
    const object_skips = object_tree_slice.items(.skip);
    const object_tags = object_tree_slice.items(.tag);
    const elements = object_tree_slice.items(.element);
    const datas = object_tree_slice.items(.data);

    var ctx = RealizeObjectsContext{ .allocator = layout.allocator };
    defer ctx.deinit();

    {
        const object_skip = object_skips[main_object_index];
        const object_tag = object_tags[main_object_index];
        switch (object_tag) {
            .flow_stf => {
                const data = datas[main_object_index].flow_stf;
                ctx.stack.top = .{
                    .object_index = main_object_index,
                    .object_tag = object_tag,
                    .object_interval = .{ .begin = main_object_index + 1, .end = main_object_index + object_skip },

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

                        try ctx.stack.push(ctx.allocator, .{
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
