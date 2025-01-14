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
const BoxStyle = BoxTree.BoxStyle;
const GeneratedBox = BoxTree.GeneratedBox;
const StackingContextTree = BoxTree.StackingContextTree;
const Subtree = BoxTree.Subtree;

pub const Context = struct {
    tree: ObjectTree = .empty,
    main_object: Stack(struct {
        index: Size,
        depth: Size,
    }) = .init(undefined),
    object: Stack(struct {
        object_index: Size,
        object_skip: Size,
        auto_width: Unit,
    }) = .init(undefined),

    const Size = u32;

    const Object = struct {
        skip: Size,
        tag: Tag,
        element: Element, // TODO: remove this field
        data: Data,

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
                // absolute_containing_block_id: ?Layout.Absolute.ContainingBlock.Id,
            },
            flow_normal: BlockRef,
            ifc: struct {
                subtree_id: Subtree.Id,
                layout_result: @"inline".Result,
            },
        };
    };
    const ObjectTree = MultiArrayList(Object);

    pub fn deinit(ctx: *Context, allocator: Allocator) void {
        ctx.main_object.deinit(allocator);
        ctx.object.deinit(allocator);
        ctx.tree.deinit(allocator);
    }

    fn end(ctx: *Context, main_object_index: Size) void {
        ctx.tree.shrinkRetainingCapacity(main_object_index);
    }

    fn pushMainObject(ctx: *Context, allocator: Allocator, object_index: Size) !void {
        try ctx.main_object.push(allocator, .{
            .index = object_index,
            .depth = 1,
        });
    }

    fn popMainObject(ctx: *Context) Size {
        const main_object = ctx.main_object.pop();
        assert(main_object.depth == 0);
        return main_object.index;
    }

    fn pushMainFlowObject(ctx: *Context, allocator: Allocator, sizes: BlockUsedSizes) !void {
        const index = try ctx.appendObject(allocator, .{
            .skip = undefined,
            .tag = .flow_stf,
            .element = undefined,
            .data = .{
                .flow_stf = .{
                    .width_clamped = undefined,
                    .used = sizes,
                    .stacking_context_id = undefined,
                    // .absolute_containing_block_id = undefined,
                },
            },
        });
        try ctx.pushMainObject(allocator, index);
        try ctx.object.push(allocator, .{
            .object_index = index,
            .object_skip = 1,
            .auto_width = 0,
        });
    }

    fn pushFlowObject(
        ctx: *Context,
        allocator: Allocator,
        element: Element,
        sizes: BlockUsedSizes,
        stacking_context_id: ?StackingContextTree.Id,
        // absolute_containing_block_id: ?Layout.Absolute.ContainingBlock.Id,
    ) !void {
        const index = try ctx.appendObject(allocator, .{
            .skip = undefined,
            .tag = .flow_stf,
            .element = element,
            .data = .{
                .flow_stf = .{
                    .width_clamped = undefined,
                    .used = sizes,
                    .stacking_context_id = stacking_context_id,
                    // .absolute_containing_block_id = absolute_containing_block_id,
                },
            },
        });
        try ctx.object.push(allocator, .{
            .object_index = index,
            .object_skip = 1,
            .auto_width = 0,
        });
        ctx.main_object.top.?.depth += 1;
    }

    fn appendFlowNormalObject(
        ctx: *Context,
        allocator: Allocator,
        ref: BlockRef,
        element: Element,
        full_width: Unit,
    ) !void {
        _ = try ctx.appendObject(allocator, .{
            .skip = 1,
            .tag = .flow_normal,
            .element = element,
            .data = .{ .flow_normal = ref },
        });

        const parent = &ctx.object.top.?;
        parent.object_skip += 1;
        parent.auto_width = @max(parent.auto_width, full_width);
    }

    fn appendIfcObject(ctx: *Context, allocator: Allocator, subtree: Subtree.Id) !void {
        _ = try ctx.appendObject(allocator, .{
            .skip = 1,
            .tag = .ifc,
            .element = undefined,
            .data = .{
                .ifc = .{
                    .subtree_id = subtree,
                    .layout_result = undefined,
                },
            },
        });

        const parent = &ctx.object.top.?;
        parent.object_skip += 1;
    }

    fn setIfcObjectResult(ctx: *Context, layout_result: @"inline".Result) void {
        ctx.tree.items(.data)[ctx.tree.len - 1].ifc.layout_result = layout_result;
        const parent = &ctx.object.top.?;
        parent.auto_width = @max(parent.auto_width, layout_result.min_width);
    }

    fn appendObject(ctx: *Context, allocator: Allocator, object: Object) !Size {
        const index: Size = std.math.cast(Size, ctx.tree.len) orelse return error.SizeLimitExceeded;
        try ctx.tree.append(allocator, object);
        return index;
    }

    fn popFlowObject(ctx: *Context, tree: ObjectTree.Slice) Size {
        const this = ctx.object.pop();
        ctx.main_object.top.?.depth -= 1;

        tree.items(.skip)[this.object_index] = this.object_skip;
        const data = &tree.items(.data)[this.object_index].flow_stf;
        const width = flow.solveUsedWidth(this.auto_width, data.used.min_inline_size, data.used.max_inline_size);
        data.width_clamped = width;

        return this.object_index;
    }

    fn addToParent(ctx: *Context, tree: ObjectTree.Slice, object_index: Size) void {
        const data = &tree.items(.data)[object_index].flow_stf;
        const parent = &ctx.object.top.?;
        const parent_object_tag = ctx.tree.items(.tag)[parent.object_index];
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
        const object_skip = tree.items(.skip)[object_index];
        parent.object_skip += object_skip;
    }
};

pub const Result = struct {
    auto_width: Unit,
};

pub fn beginMode(layout: *Layout, inner_block: BoxStyle.InnerBlock, used_sizes: BlockUsedSizes) !void {
    const ctx = &layout.stf_context;
    switch (inner_block) {
        .flow => try ctx.pushMainFlowObject(layout.allocator, used_sizes),
    }
}

pub fn endMode(layout: *Layout) !Result {
    const ctx = &layout.stf_context;
    const main_object_index = ctx.popMainObject();
    const result = try realizeObjects(layout, main_object_index);
    ctx.end(main_object_index);
    return result;
}

pub fn blockElement(layout: *Layout, element: Element, inner_block: BoxStyle.InnerBlock, position: BoxStyle.Position) !void {
    const ctx = &layout.stf_context;
    const object_index = ctx.object.top.?.object_index;
    const object_tag = ctx.tree.items(.tag)[object_index];
    switch (object_tag) {
        .flow_stf => try flowObject(layout, element, inner_block, position),
        .flow_normal, .ifc => unreachable,
    }
}

fn flowObject(layout: *Layout, element: Element, inner_block: BoxStyle.InnerBlock, position: BoxStyle.Position) !void {
    const containing_block_size = layout.containingBlockSize();
    const sizes = flow.solveAllSizes(&layout.computer, position, .ShrinkToFit, containing_block_size.height);
    const stacking_context = flow.solveStackingContext(&layout.computer, position);
    layout.computer.commitElement(.box_gen);

    const edge_width = sizes.margin_inline_start_untagged + sizes.margin_inline_end_untagged +
        sizes.border_inline_start + sizes.border_inline_end +
        sizes.padding_inline_start + sizes.padding_inline_end;

    switch (inner_block) {
        .flow => {
            if (sizes.get(.inline_size)) |inline_size| {
                _ = try layout.pushSubtree();
                const ref = try layout.pushFlowBlock(.Normal, sizes, {}, stacking_context);
                try layout.box_tree.setGeneratedBox(element, .{ .block_ref = ref });
                try layout.stf_context.appendFlowNormalObject(layout.allocator, ref, element, inline_size + edge_width);
                try layout.pushElement();
                return layout.pushFlowMode(.NonRoot);
            } else {
                const available_width = solve.clampSize(containing_block_size.width - edge_width, sizes.min_inline_size, sizes.max_inline_size);
                try pushFlowObject(layout, element, sizes, available_width, stacking_context);
            }
        },
    }
}

pub fn inlineElement(layout: *Layout) !void {
    const subtree = try layout.pushSubtree();
    try layout.stf_context.appendIfcObject(layout.allocator, subtree);
    return layout.pushInlineMode(.NonRoot, .ShrinkToFit, layout.containingBlockSize());
}

pub fn nullElement(layout: *Layout) !void {
    const tree = layout.stf_context.tree.slice();
    const object_index = layout.stf_context.popFlowObject(tree);
    if (layout.stf_context.main_object.top.?.depth == 0) return layout.popStfMode();
    popFlowObject(layout, tree, object_index);
}

pub fn afterFlowMode(layout: *Layout) void {
    layout.popFlowBlock(.Normal, {});
    layout.popSubtree();
    layout.popElement();
}

pub fn afterInlineMode(layout: *Layout, result: @"inline".Result) void {
    layout.popSubtree();
    layout.stf_context.setIfcObjectResult(result);
}

pub fn afterStfMode() noreturn {
    unreachable;
}

fn pushFlowObject(
    layout: *Layout,
    element: Element,
    sizes: BlockUsedSizes,
    available_width: Unit,
    stacking_context: SctBuilder.Type,
) !void {
    // The allocations here must have corresponding deallocations in popFlowObject.
    const stacking_context_id = try layout.pushStfFlowBlock(sizes, available_width, stacking_context);
    try layout.pushElement();
    try layout.stf_context.pushFlowObject(layout.allocator, element, sizes, stacking_context_id);
}

fn popFlowObject(layout: *Layout, tree: Context.ObjectTree.Slice, object_index: Context.Size) void {
    // The deallocations here must correspond to allocations in pushFlowObject.
    layout.popStfFlowBlock();
    layout.popElement();
    layout.stf_context.addToParent(tree, object_index);
}

const RealizeObjectsContext = struct {
    stack: Stack(StackItem) = .{},
    allocator: std.mem.Allocator,
    result: Result = undefined,

    const Interval = struct {
        begin: Context.Size,
        end: Context.Size,
    };

    const StackItem = struct {
        object_index: Context.Size,
        object_tag: Context.Object.Tag,
        object_interval: Interval,

        width: Unit,
        auto_height: Unit,
    };

    fn deinit(ctx: *RealizeObjectsContext) void {
        ctx.stack.deinit(ctx.allocator);
    }
};

fn realizeObjects(layout: *Layout, main_object_index: Context.Size) !Result {
    const object_tree_slice = layout.stf_context.tree.slice();
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

fn popFlowBlock(layout: *Layout, ctx: *RealizeObjectsContext, object_tree_slice: Context.ObjectTree.Slice) void {
    const this = ctx.stack.pop();
    if (ctx.stack.top == null) {
        ctx.result = .{
            .auto_width = this.width,
        };
        return;
    }

    const data = object_tree_slice.items(.data)[this.object_index].flow_stf;
    layout.popStfFlowBlock2(
        data.width_clamped,
        data.used,
        data.stacking_context_id,
        // data.absolute_containing_block_id,
    );
}
