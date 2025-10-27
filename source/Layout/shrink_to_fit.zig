const std = @import("std");
const assert = std.debug.assert;
const panic = std.debug.panic;
const Allocator = std.mem.Allocator;
const MultiArrayList = std.MultiArrayList;

const zss = @import("../zss.zig");
const NodeId = zss.Environment.NodeId;
const Unit = zss.math.Unit;

const Layout = zss.Layout;
const StyleComputer = Layout.StyleComputer;

const BoxGen = Layout.BoxGen;
const BlockComputedSizes = BoxGen.BlockComputedSizes;
const BlockUsedSizes = BoxGen.BlockUsedSizes;
const SctBuilder = BoxGen.StackingContextTreeBuilder;

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
    main_object: zss.Stack(struct {
        index: Size,
        depth: Size,
    }) = .init(undefined),
    object: zss.Stack(struct {
        object_index: Size,
        object_skip: Size,
        auto_width: Unit,
    }) = .init(undefined),

    const Size = u32;

    const Object = struct {
        skip: Size,
        tag: Tag,
        node: NodeId, // TODO: remove this field
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
            .node = undefined,
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
        node: NodeId,
        sizes: BlockUsedSizes,
        stacking_context_id: ?StackingContextTree.Id,
        // absolute_containing_block_id: ?Layout.Absolute.ContainingBlock.Id,
    ) !void {
        const index = try ctx.appendObject(allocator, .{
            .skip = undefined,
            .tag = .flow_stf,
            .node = node,
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

    fn popFlowObject(ctx: *Context, tree: ObjectTree.Slice) ?Size {
        const this = ctx.object.pop();

        tree.items(.skip)[this.object_index] = this.object_skip;
        const data = &tree.items(.data)[this.object_index].flow_stf;
        const width = flow.solveUsedWidth(this.auto_width, data.used.min_inline_size, data.used.max_inline_size);
        data.width_clamped = width;

        const depth = &ctx.main_object.top.?.depth;
        depth.* -= 1;
        if (depth.* == 0) return null;

        return this.object_index;
    }

    fn appendFlowNormalObject(
        ctx: *Context,
        allocator: Allocator,
        ref: BlockRef,
        node: NodeId,
        full_width: Unit,
    ) !void {
        _ = try ctx.appendObject(allocator, .{
            .skip = 1,
            .tag = .flow_normal,
            .node = node,
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
            .node = undefined,
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

pub fn beginMode(box_gen: *BoxGen, inner_block: BoxStyle.InnerBlock, used_sizes: BlockUsedSizes) !void {
    const ctx = &box_gen.stf_context;
    switch (inner_block) {
        .flow => try ctx.pushMainFlowObject(box_gen.getLayout().allocator, used_sizes),
    }
}

fn endMode(box_gen: *BoxGen) !Result {
    const ctx = &box_gen.stf_context;
    const main_object_index = ctx.popMainObject();
    const result = try realizeObjects(box_gen, main_object_index);
    ctx.end(main_object_index);
    return result;
}

pub fn blockElement(box_gen: *BoxGen, node: NodeId, inner_block: BoxStyle.InnerBlock, position: BoxStyle.Position) !void {
    const ctx = &box_gen.stf_context;
    const object_index = ctx.object.top.?.object_index;
    const object_tag = ctx.tree.items(.tag)[object_index];
    switch (object_tag) {
        .flow_stf => try flowObject(box_gen, node, inner_block, position),
        .flow_normal, .ifc => unreachable,
    }
}

fn flowObject(box_gen: *BoxGen, node: NodeId, inner_block: BoxStyle.InnerBlock, position: BoxStyle.Position) !void {
    const computer = &box_gen.getLayout().computer;
    const containing_block_size = box_gen.containingBlockSize();
    const sizes = flow.solveAllSizes(computer, position, .stf, containing_block_size.height);
    const stacking_context = flow.solveStackingContext(computer, position);
    computer.commitNode(.box_gen);

    const edge_width = sizes.margin_inline_start_untagged + sizes.margin_inline_end_untagged +
        sizes.border_inline_start + sizes.border_inline_end +
        sizes.padding_inline_start + sizes.padding_inline_end;

    switch (inner_block) {
        .flow => {
            if (sizes.get(.inline_size)) |inline_size| {
                _ = try box_gen.pushSubtree();
                const ref = try box_gen.pushFlowBlock(sizes, .normal, stacking_context, node);
                try box_gen.getLayout().box_tree.setGeneratedBox(node, .{ .block_ref = ref });
                try box_gen.stf_context.appendFlowNormalObject(box_gen.getLayout().allocator, ref, node, inline_size + edge_width);
                try box_gen.getLayout().pushNode();
                return box_gen.beginFlowMode(.not_root);
            } else {
                const available_width = solve.clampSize(containing_block_size.width - edge_width, sizes.min_inline_size, sizes.max_inline_size);
                try pushFlowObject(box_gen, node, sizes, available_width, stacking_context);
            }
        },
    }
}

pub fn nullNode(box_gen: *BoxGen) !?Result {
    const tree = box_gen.stf_context.tree.slice();
    const object_index = box_gen.stf_context.popFlowObject(tree) orelse {
        return try endMode(box_gen);
    };
    popFlowObject(box_gen, tree, object_index);
    return null;
}

pub fn afterFlowMode(box_gen: *BoxGen) void {
    box_gen.popFlowBlock(.normal);
    box_gen.popSubtree();
    box_gen.getLayout().popNode();
}

pub fn beforeInlineMode(box_gen: *BoxGen) !BoxGen.SizeMode {
    const subtree = try box_gen.pushSubtree();
    try box_gen.stf_context.appendIfcObject(box_gen.getLayout().allocator, subtree);
    return .stf;
}

pub fn afterInlineMode(box_gen: *BoxGen, result: @"inline".Result) void {
    box_gen.popSubtree();
    box_gen.stf_context.setIfcObjectResult(result);
}

pub fn afterStfMode() noreturn {
    unreachable;
}

fn pushFlowObject(
    box_gen: *BoxGen,
    node: NodeId,
    sizes: BlockUsedSizes,
    available_width: Unit,
    stacking_context: SctBuilder.Type,
) !void {
    // The allocations here must have corresponding deallocations in popFlowObject.
    const stacking_context_id = try box_gen.pushStfFlowBlock(sizes, available_width, stacking_context);
    try box_gen.getLayout().pushNode();
    try box_gen.stf_context.pushFlowObject(box_gen.getLayout().allocator, node, sizes, stacking_context_id);
}

fn popFlowObject(box_gen: *BoxGen, tree: Context.ObjectTree.Slice, object_index: Context.Size) void {
    // The deallocations here must correspond to allocations in pushFlowObject.
    box_gen.popStfFlowBlock();
    box_gen.getLayout().popNode();
    box_gen.stf_context.addToParent(tree, object_index);
}

const RealizeObjectsContext = struct {
    stack: zss.Stack(StackItem) = .{},
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

fn realizeObjects(box_gen: *BoxGen, main_object_index: Context.Size) !Result {
    const object_tree_slice = box_gen.stf_context.tree.slice();
    const object_skips = object_tree_slice.items(.skip);
    const object_tags = object_tree_slice.items(.tag);
    const nodes = object_tree_slice.items(.node);
    const datas = object_tree_slice.items(.data);

    var ctx = RealizeObjectsContext{ .allocator = box_gen.getLayout().allocator };
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
                const node = nodes[object_index];
                parent.object_interval.begin += object_skip;

                const containing_block_width = parent.width;
                switch (object_tag) {
                    .flow_stf => {
                        const data = &datas[object_index].flow_stf;
                        // TODO: width/margins were used to set the parent block's auto_height earlier, but are being changed again here
                        flow.adjustWidthAndMargins(&data.used, containing_block_width);

                        const ref = try box_gen.pushStfFlowBlock2();
                        try box_gen.getLayout().box_tree.setGeneratedBox(node, .{ .block_ref = ref });

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
                        try box_gen.addSubtreeProxy(data.subtree);
                    },
                    .ifc => {
                        const data = datas[object_index].ifc;
                        try box_gen.addSubtreeProxy(data.subtree_id);
                    },
                }
            } else {
                popFlowBlock(box_gen, &ctx, object_tree_slice);
            },
            .flow_normal, .ifc => unreachable,
        }
    }

    return ctx.result;
}

fn popFlowBlock(box_gen: *BoxGen, ctx: *RealizeObjectsContext, object_tree_slice: Context.ObjectTree.Slice) void {
    const this = ctx.stack.pop();
    if (ctx.stack.top == null) {
        ctx.result = .{
            .auto_width = this.width,
        };
        return;
    }

    const data = object_tree_slice.items(.data)[this.object_index].flow_stf;
    const node = object_tree_slice.items(.node)[this.object_index];
    box_gen.popStfFlowBlock2(
        data.width_clamped,
        data.used,
        data.stacking_context_id,
        // data.absolute_containing_block_id,
        node,
    );
}
