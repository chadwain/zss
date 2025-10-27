const BoxGen = @This();

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const MultiArrayList = std.MultiArrayList;

const zss = @import("../zss.zig");
const math = zss.math;
const Environment = zss.Environment;
const Fonts = zss.Fonts;
const Images = zss.Images;
const NodeId = Environment.NodeId;
const Stack = zss.Stack;

const Layout = @import("../Layout.zig");
const IsRoot = Layout.IsRoot;

const flow = @import("flow.zig");
const initial = @import("initial.zig");
const @"inline" = @import("inline.zig");
const solve = @import("solve.zig");
const stf = @import("shrink_to_fit.zig");
pub const Absolute = @import("AbsoluteContainingBlocks.zig");
pub const StackingContextTreeBuilder = @import("StackingContextTreeBuilder.zig");

const BoxTree = zss.BoxTree;
const BackgroundImage = BoxTree.BackgroundImage;
const BackgroundImages = BoxTree.BackgroundImages;
const BlockRef = BoxTree.BlockRef;
const GeneratedBox = BoxTree.GeneratedBox;
const Ifc = BoxTree.InlineFormattingContext;
const StackingContext = BoxTree.StackingContext;
const StackingContextTree = BoxTree.StackingContextTree;
const Subtree = BoxTree.Subtree;

/// A stack used to keep track of block formatting contexts.
bfc_stack: zss.Stack(usize) = .init(undefined),
inline_context: @"inline".Context = .{},
stf_context: stf.Context = .{},
stacks: Stacks = .{},
sct_builder: StackingContextTreeBuilder = .{},
absolute: Absolute = .{},

const Stacks = struct {
    mode: zss.Stack(Mode) = .{},
    subtree: zss.Stack(struct {
        id: Subtree.Id,
        depth: Subtree.Size,
    }) = .{},
    block: zss.Stack(Block) = .{},
    block_info: zss.Stack(BlockInfo) = .{},

    containing_block_size: zss.Stack(ContainingBlockSize) = .{},
};

const Mode = enum {
    flow,
    stf,
    @"inline",
};

pub fn getLayout(box_gen: *BoxGen) *Layout {
    return @fieldParentPtr("box_gen", box_gen);
}

pub fn deinit(box_gen: *BoxGen) void {
    const allocator = box_gen.getLayout().allocator;
    box_gen.bfc_stack.deinit(allocator);
    box_gen.inline_context.deinit(allocator);
    box_gen.stf_context.deinit(allocator);
    box_gen.stacks.mode.deinit(allocator);
    box_gen.stacks.subtree.deinit(allocator);
    box_gen.stacks.block.deinit(allocator);
    box_gen.stacks.block_info.deinit(allocator);
    box_gen.stacks.containing_block_size.deinit(allocator);
    box_gen.sct_builder.deinit(allocator);
    box_gen.absolute.deinit(allocator);
}

pub fn run(box_gen: *BoxGen) !void {
    try analyzeAllNodes(box_gen);
    box_gen.sct_builder.endFrame();
}

fn analyzeAllNodes(box_gen: *BoxGen) !void {
    {
        try initial.beginMode(box_gen);
        const root_node, const root_box_style = (try analyzeNode(box_gen.getLayout(), .root)) orelse {
            try box_gen.dispatchNullNode(.root, {});
            return;
        };
        try box_gen.dispatch(.root, {}, root_node, root_box_style);
    }

    while (box_gen.stacks.mode.top) |mode| {
        const node, const box_style = (try analyzeNode(box_gen.getLayout(), .not_root)) orelse {
            try box_gen.dispatchNullNode(.not_root, mode);
            continue;
        };
        try box_gen.dispatch(.not_root, mode, node, box_style);
    }

    try box_gen.dispatchNullNode(.root, {});
}

/// Returns the next node and its box style, or `null` if there is no next node.
fn analyzeNode(layout: *Layout, comptime is_root: IsRoot) !?struct { NodeId, BoxTree.BoxStyle } {
    const node = layout.currentNode() orelse return null;
    try layout.computer.setCurrentNode(.box_gen, node);

    switch (layout.inputs.env.getNodeProperty(.category, node)) {
        .text => {
            return .{ node, .text };
        },
        .element => {
            const specified_box_style = layout.computer.getSpecifiedValue(.box_gen, .box_style);
            const computed_box_style, const used_box_style = solve.boxStyle(specified_box_style, is_root);
            layout.computer.setComputedValue(.box_gen, .box_style, computed_box_style);
            return .{ node, used_box_style };
        },
    }
}

fn dispatch(
    box_gen: *BoxGen,
    comptime is_root: IsRoot,
    current_mode: switch (is_root) {
        .root => void,
        .not_root => Mode,
    },
    node: NodeId,
    box_style: BoxTree.BoxStyle,
) !void {
    switch (box_style.outer) {
        .none => box_gen.getLayout().advanceNode(),
        .block => try box_gen.dispatchBlockElement(is_root, current_mode, node, box_style),
        .@"inline" => try box_gen.dispatchInlineElement(is_root, current_mode, node, box_style),
        .absolute => std.debug.panic("TODO: Absolute blocks", .{}),
    }
}

fn dispatchBlockElement(
    box_gen: *BoxGen,
    comptime is_root: IsRoot,
    current_mode: switch (is_root) {
        .root => void,
        .not_root => Mode,
    },
    node: NodeId,
    box_style: BoxTree.BoxStyle,
) !void {
    const inner_box_style = box_style.outer.block;
    switch (is_root) {
        .root => try initial.blockElement(box_gen, node, inner_box_style, box_style.position),
        .not_root => sw: switch (current_mode) {
            .flow => try flow.blockElement(box_gen, node, inner_box_style, box_style.position),
            .stf => try stf.blockElement(box_gen, node, inner_box_style, box_style.position),
            .@"inline" => {
                const result = try @"inline".blockElement(box_gen);
                box_gen.afterInlineMode(result);
                const parent_mode = box_gen.stacks.mode.top orelse {
                    return dispatchBlockElement(box_gen, .root, {}, node, box_style);
                };
                continue :sw parent_mode;
            },
        },
    }
}

fn dispatchInlineElement(
    box_gen: *BoxGen,
    comptime is_root: IsRoot,
    current_mode: switch (is_root) {
        .root => void,
        .not_root => Mode,
    },
    node: NodeId,
    box_style: BoxTree.BoxStyle,
) !void {
    switch (is_root) {
        .root => {
            const size_mode = initial.beforeInlineMode();
            try beginInlineMode(box_gen, .root, size_mode);
        },
        .not_root => blk: {
            const size_mode: SizeMode = switch (current_mode) {
                .flow => flow.beforeInlineMode(),
                .stf => try stf.beforeInlineMode(box_gen),
                .@"inline" => break :blk,
            };
            try beginInlineMode(box_gen, .not_root, size_mode);
        },
    }
    return @"inline".inlineElement(box_gen, node, box_style.outer.@"inline", box_style.position);
}

fn dispatchNullNode(
    box_gen: *BoxGen,
    comptime is_root: IsRoot,
    current_mode: switch (is_root) {
        .root => void,
        .not_root => Mode,
    },
) !void {
    switch (is_root) {
        .root => initial.nullNode(box_gen),
        .not_root => switch (current_mode) {
            .flow => {
                flow.nullNode(box_gen) orelse return;
                afterFlowMode(box_gen);
            },
            .stf => {
                const result = (try stf.nullNode(box_gen)) orelse return;
                afterStfMode(box_gen, result);
            },
            .@"inline" => {
                const result = (try @"inline".nullNode(box_gen)) orelse return;
                afterInlineMode(box_gen, result);
            },
        },
    }
}

pub fn beginFlowMode(box_gen: *BoxGen, comptime is_root: IsRoot) !void {
    switch (is_root) {
        .root => box_gen.stacks.mode.top = .flow,
        .not_root => try box_gen.stacks.mode.push(box_gen.getLayout().allocator, .flow),
    }
    try flow.beginMode(box_gen);
}

fn afterFlowMode(box_gen: *BoxGen) void {
    assert(box_gen.stacks.mode.pop() == .flow);
    const parent_mode = box_gen.stacks.mode.top orelse {
        return initial.afterFlowMode(box_gen);
    };
    switch (parent_mode) {
        .flow => flow.afterFlowMode(),
        .stf => stf.afterFlowMode(box_gen),
        .@"inline" => @"inline".afterFlowMode(box_gen),
    }
}

pub fn beginStfMode(box_gen: *BoxGen, inner_block: BoxTree.BoxStyle.InnerBlock, sizes: BlockUsedSizes) !void {
    try box_gen.stacks.mode.push(box_gen.getLayout().allocator, .stf);
    try stf.beginMode(box_gen, inner_block, sizes);
}

fn afterStfMode(box_gen: *BoxGen, result: stf.Result) void {
    assert(box_gen.stacks.mode.pop() == .stf);
    const parent_mode = box_gen.stacks.mode.top orelse {
        return initial.afterStfMode();
    };
    switch (parent_mode) {
        .flow => flow.afterStfMode(),
        .stf => stf.afterStfMode(),
        .@"inline" => @"inline".afterStfMode(box_gen, result),
    }
}

fn beginInlineMode(box_gen: *BoxGen, comptime is_root: IsRoot, size_mode: SizeMode) !void {
    switch (is_root) {
        .root => box_gen.stacks.mode.top = .@"inline",
        .not_root => try box_gen.stacks.mode.push(box_gen.getLayout().allocator, .@"inline"),
    }
    try @"inline".beginMode(box_gen, size_mode, box_gen.containingBlockSize());
}

fn afterInlineMode(box_gen: *BoxGen, result: @"inline".Result) void {
    assert(box_gen.stacks.mode.pop() == .@"inline");
    const parent_mode = box_gen.stacks.mode.top orelse {
        return initial.afterInlineMode();
    };
    switch (parent_mode) {
        .flow => flow.afterInlineMode(),
        .stf => stf.afterInlineMode(box_gen, result),
        .@"inline" => @"inline".afterInlineMode(),
    }
}

pub const SizeMode = enum { normal, stf };

pub fn currentSubtree(box_gen: *BoxGen) Subtree.Id {
    return box_gen.stacks.subtree.top.?.id;
}

pub fn pushInitialSubtree(box_gen: *BoxGen) !void {
    const subtree = try box_gen.getLayout().box_tree.newSubtree();
    box_gen.stacks.subtree.top = .{ .id = subtree.id, .depth = 0 };
}

pub fn pushSubtree(box_gen: *BoxGen) !Subtree.Id {
    const layout = box_gen.getLayout();
    const subtree = try layout.box_tree.newSubtree();
    try box_gen.stacks.subtree.push(layout.allocator, .{ .id = subtree.id, .depth = 0 });
    return subtree.id;
}

pub fn popSubtree(box_gen: *BoxGen) void {
    const item = box_gen.stacks.subtree.pop();
    assert(item.depth == 0);
    const layout = box_gen.getLayout();
    const subtree = layout.box_tree.ptr.getSubtree(item.id).view();
    subtree.items(.offset)[0] = .zero;
}

pub const ContainingBlockSize = struct {
    width: math.Unit,
    height: ?math.Unit,
};

pub fn containingBlockSize(box_gen: *BoxGen) ContainingBlockSize {
    return box_gen.stacks.containing_block_size.top.?;
}

const Block = struct {
    index: Subtree.Size,
    skip: Subtree.Size,
};

const BlockInfo = struct {
    sizes: BlockUsedSizes,
    stacking_context_id: ?StackingContextTree.Id,
    // absolute_containing_block_id: ?Absolute.ContainingBlock.Id,
    node: NodeId,
};

fn newBlock(box_gen: *BoxGen) !BlockRef {
    const layout = box_gen.getLayout();
    const subtree = layout.box_tree.ptr.getSubtree(box_gen.stacks.subtree.top.?.id);
    const index = try layout.box_tree.appendBlockBox(subtree);
    return .{ .subtree = subtree.id, .index = index };
}

fn pushBlock(box_gen: *BoxGen) !BlockRef {
    const ref = try box_gen.newBlock();
    try box_gen.stacks.block.push(box_gen.getLayout().allocator, .{
        .index = ref.index,
        .skip = 1,
    });
    box_gen.stacks.subtree.top.?.depth += 1;
    return ref;
}

fn popBlock(box_gen: *BoxGen) Block {
    const block = box_gen.stacks.block.pop();
    box_gen.stacks.subtree.top.?.depth -= 1;
    box_gen.addSkip(block.skip);
    return block;
}

fn addSkip(box_gen: *BoxGen, skip: Subtree.Size) void {
    if (box_gen.stacks.subtree.top.?.depth > 0) {
        box_gen.stacks.block.top.?.skip += skip;
    }
}

pub fn pushInitialContainingBlock(box_gen: *BoxGen, size: math.Size) !BlockRef {
    const ref = try box_gen.newBlock();
    box_gen.stacks.block.top = .{
        .index = ref.index,
        .skip = 1,
    };
    assert(box_gen.stacks.subtree.top.?.depth == 0);
    box_gen.stacks.subtree.top.?.depth += 1;

    const layout = box_gen.getLayout();
    const stacking_context_id = try box_gen.sct_builder.pushInitial(layout.box_tree.ptr, ref);
    // const absolute_containing_block_id = try box_gen.absolute.pushInitialContainingBlock(layout.allocator, ref);
    box_gen.stacks.block_info.top = .{
        .sizes = BlockUsedSizes.icb(size),
        .stacking_context_id = stacking_context_id,
        // .absolute_containing_block_id = absolute_containing_block_id,
        .node = undefined,
    };
    box_gen.stacks.containing_block_size.top = .{
        .width = size.w,
        .height = size.h,
    };

    return ref;
}

pub fn popInitialContainingBlock(box_gen: *BoxGen) void {
    box_gen.sct_builder.popInitial();
    // box_gen.popAbsoluteContainingBlock();
    const block = box_gen.stacks.block.pop();
    box_gen.stacks.subtree.top.?.depth -= 1;
    assert(box_gen.stacks.subtree.top.?.depth == 0);
    const block_info = box_gen.stacks.block_info.pop();
    _ = box_gen.stacks.containing_block_size.pop();

    const box_tree = box_gen.getLayout().box_tree;
    const subtree = box_tree.ptr.getSubtree(box_gen.stacks.subtree.top.?.id).view();
    const index = block.index;
    _ = flow.offsetChildBlocks(subtree, index, block.skip);
    const width = block_info.sizes.get(.inline_size).?;
    const height = block_info.sizes.get(.block_size).?;
    subtree.items(.skip)[index] = block.skip;
    subtree.items(.type)[index] = .block;
    subtree.items(.stacking_context)[index] = block_info.stacking_context_id;
    subtree.items(.node)[index] = null;
    subtree.items(.box_offsets)[index] = .{
        .border_pos = .{ .x = 0, .y = 0 },
        .content_pos = .{ .x = 0, .y = 0 },
        .content_size = .{ .w = width, .h = height },
        .border_size = .{ .w = width, .h = height },
    };
    subtree.items(.borders)[index] = .{};
    subtree.items(.margins)[index] = .{};
}

pub fn pushFlowBlock(
    box_gen: *BoxGen,
    // box_style: BoxTree.BoxStyle,
    sizes: BlockUsedSizes,
    available_width: union(SizeMode) {
        normal,
        stf: math.Unit,
    },
    stacking_context: StackingContextTreeBuilder.Type,
    node: NodeId,
) !BlockRef {
    const ref = try box_gen.pushBlock();

    const layout = box_gen.getLayout();
    const stacking_context_id = try box_gen.sct_builder.push(layout.allocator, stacking_context, layout.box_tree.ptr, ref);
    // const absolute_containing_block_id = try box_gen.pushAbsoluteContainingBlock(box_style, ref);
    try box_gen.stacks.block_info.push(layout.allocator, .{
        .sizes = sizes,
        .stacking_context_id = stacking_context_id,
        // .absolute_containing_block_id = absolute_containing_block_id,
        .node = node,
    });
    try box_gen.stacks.containing_block_size.push(layout.allocator, .{
        .width = switch (available_width) {
            .normal => sizes.get(.inline_size).?,
            .stf => |aw| aw,
        },
        .height = sizes.get(.block_size),
    });

    return ref;
}

pub fn popFlowBlock(
    box_gen: *BoxGen,
    auto_width: union(SizeMode) {
        normal,
        stf: math.Unit,
    },
) void {
    const layout = box_gen.getLayout();
    box_gen.sct_builder.pop(layout.box_tree.ptr);
    // box_gen.popAbsoluteContainingBlock();
    const block = box_gen.popBlock();
    const block_info = box_gen.stacks.block_info.pop();
    _ = box_gen.stacks.containing_block_size.pop();

    const subtree = layout.box_tree.ptr.getSubtree(box_gen.currentSubtree()).view();
    const auto_height = flow.offsetChildBlocks(subtree, block.index, block.skip);
    const width = switch (auto_width) {
        .normal => block_info.sizes.get(.inline_size).?,
        .stf => |aw| flow.solveUsedWidth(aw, block_info.sizes.min_inline_size, block_info.sizes.max_inline_size),
    };
    const height = flow.solveUsedHeight(block_info.sizes, auto_height);
    setDataBlock(subtree, block.index, block_info.sizes, block.skip, width, height, block_info.stacking_context_id, block_info.node);
}

pub fn pushStfFlowBlock(
    box_gen: *BoxGen,
    // box_style: BoxTree.BoxStyle,
    sizes: BlockUsedSizes,
    available_width: math.Unit,
    stacking_context: StackingContextTreeBuilder.Type,
) !?StackingContextTree.Id {
    const layout = box_gen.getLayout();
    try box_gen.stacks.containing_block_size.push(layout.allocator, .{
        .width = available_width,
        .height = sizes.get(.block_size),
    });
    const stacking_context_id = try box_gen.sct_builder.pushWithoutBlock(layout.allocator, stacking_context, layout.box_tree.ptr);
    // const absolute_containing_block_id = try box_gen.pushAbsoluteContainingBlock(box_style, undefined);
    return stacking_context_id;
}

pub fn popStfFlowBlock(box_gen: *BoxGen) void {
    _ = box_gen.stacks.containing_block_size.pop();
    box_gen.sct_builder.pop(box_gen.getLayout().box_tree.ptr);
    // box_gen.popAbsoluteContainingBlock();
}

pub fn pushStfFlowBlock2(box_gen: *BoxGen) !BlockRef {
    return box_gen.pushBlock();
}

pub fn popStfFlowBlock2(
    box_gen: *BoxGen,
    auto_width: math.Unit,
    sizes: BlockUsedSizes,
    stacking_context_id: ?StackingContextTree.Id,
    // absolute_containing_block_id: ?Absolute.ContainingBlock.Id,
    node: NodeId,
) void {
    const block = box_gen.popBlock();

    const box_tree = box_gen.getLayout().box_tree;
    const subtree_id = box_gen.stacks.subtree.top.?.id;
    const subtree = box_tree.ptr.getSubtree(subtree_id).view();
    const auto_height = flow.offsetChildBlocks(subtree, block.index, block.skip);
    const width = flow.solveUsedWidth(auto_width, sizes.min_inline_size, sizes.max_inline_size); // TODO This is probably redundant
    const height = flow.solveUsedHeight(sizes, auto_height);
    setDataBlock(subtree, block.index, sizes, block.skip, width, height, stacking_context_id, node);

    const ref: BlockRef = .{ .subtree = subtree_id, .index = block.index };
    if (stacking_context_id) |id| box_gen.sct_builder.setBlock(id, box_tree.ptr, ref);
    // if (absolute_containing_block_id) |id| box_gen.fixupAbsoluteContainingBlock(id, ref);
}

pub fn addSubtreeProxy(box_gen: *BoxGen, id: Subtree.Id) !void {
    box_gen.addSkip(1);

    const box_tree = box_gen.getLayout().box_tree;
    const ref = try box_gen.newBlock();
    const parent_subtree = box_tree.ptr.getSubtree(box_gen.stacks.subtree.top.?.id);
    const child_subtree = box_tree.ptr.getSubtree(id);
    setDataSubtreeProxy(parent_subtree.view(), ref.index, child_subtree);
    child_subtree.parent = ref;
}

pub fn pushIfc(box_gen: *BoxGen) !*Ifc {
    const box_tree = box_gen.getLayout().box_tree;
    const container = try box_gen.pushBlock();
    const ifc = try box_tree.newIfc(container);
    try box_gen.sct_builder.addIfc(box_tree.ptr, ifc.id);
    return ifc;
}

pub fn popIfc(box_gen: *BoxGen, ifc: Ifc.Id, containing_block_width: math.Unit, height: math.Unit) void {
    const block = box_gen.popBlock();

    const box_tree = box_gen.getLayout().box_tree;
    const subtree = box_tree.ptr.getSubtree(box_gen.stacks.subtree.top.?.id).view();
    setDataIfcContainer(subtree, ifc, block.index, block.skip, containing_block_width, height);
}

pub fn pushAbsoluteContainingBlock(
    box_gen: *BoxGen,
    box_style: BoxTree.BoxStyle,
    ref: BlockRef,
) !?Absolute.ContainingBlock.Id {
    return box_gen.absolute.pushContainingBlock(box_gen.getLayout().allocator, box_style, ref);
}

pub fn pushInitialAbsoluteContainingBlock(box_gen: *BoxGen, ref: BlockRef) !?Absolute.ContainingBlock.Id {
    return try box_gen.absolute.pushInitialContainingBlock(box_gen.getLayout().allocator, ref);
}

pub fn popAbsoluteContainingBlock(box_gen: *BoxGen) void {
    return box_gen.absolute.popContainingBlock();
}

pub fn fixupAbsoluteContainingBlock(box_gen: *BoxGen, id: Absolute.ContainingBlock.Id, ref: BlockRef) void {
    return box_gen.absolute.fixupContainingBlock(id, ref);
}

pub fn addAbsoluteBlock(box_gen: *BoxGen, node: NodeId, inner_box_style: BoxTree.BoxStyle.InnerBlock) !void {
    return box_gen.absolute.addBlock(box_gen.getLayout().allocator, node, inner_box_style);
}

pub const BlockComputedSizes = struct {
    content_width: ComputedValues(.content_width),
    horizontal_edges: ComputedValues(.horizontal_edges),
    content_height: ComputedValues(.content_height),
    vertical_edges: ComputedValues(.vertical_edges),
    insets: ComputedValues(.insets),

    const ComputedValues = zss.values.groups.Tag.ComputedValues;
};

/// Fields ending with `_untagged` each have an associated flag.
/// If the flag is `.auto`, then the field will have a value of `0`.
// TODO: The field names of this struct are misleading.
//       zss currently does not support logical properties.
pub const BlockUsedSizes = struct {
    border_inline_start: math.Unit,
    border_inline_end: math.Unit,
    padding_inline_start: math.Unit,
    padding_inline_end: math.Unit,
    margin_inline_start_untagged: math.Unit,
    margin_inline_end_untagged: math.Unit,
    inline_size_untagged: math.Unit,
    min_inline_size: math.Unit,
    max_inline_size: math.Unit,

    border_block_start: math.Unit,
    border_block_end: math.Unit,
    padding_block_start: math.Unit,
    padding_block_end: math.Unit,
    margin_block_start: math.Unit,
    margin_block_end: math.Unit,
    block_size_untagged: math.Unit,
    min_block_size: math.Unit,
    max_block_size: math.Unit,

    inset_inline_start_untagged: math.Unit,
    inset_inline_end_untagged: math.Unit,
    inset_block_start_untagged: math.Unit,
    inset_block_end_untagged: math.Unit,

    flags: Flags,

    pub const Flags = packed struct {
        inline_size: IsAutoTag,
        margin_inline_start: IsAutoTag,
        margin_inline_end: IsAutoTag,
        block_size: IsAutoTag,
        inset_inline_start: IsAutoOrPercentageTag,
        inset_inline_end: IsAutoOrPercentageTag,
        inset_block_start: IsAutoOrPercentageTag,
        inset_block_end: IsAutoOrPercentageTag,

        const Field = std.meta.FieldEnum(Flags);
    };

    pub const IsAutoTag = enum(u1) { value, auto };
    pub const IsAuto = union(IsAutoTag) {
        value: math.Unit,
        auto,
    };

    pub const IsAutoOrPercentageTag = enum(u2) { value, auto, percentage };
    pub const IsAutoOrPercentage = union(IsAutoOrPercentageTag) {
        value: math.Unit,
        auto,
        percentage: f32,
    };

    pub fn setValue(self: *BlockUsedSizes, comptime field: Flags.Field, value: math.Unit) void {
        @field(self.flags, @tagName(field)) = .value;
        const clamped_value = switch (field) {
            .inline_size => solve.clampSize(value, self.min_inline_size, self.max_inline_size),
            .margin_inline_start, .margin_inline_end => value,
            .block_size => solve.clampSize(value, self.min_block_size, self.max_block_size),
            .inset_inline_start, .inset_inline_end, .inset_block_start, .inset_block_end => value,
        };
        @field(self, @tagName(field) ++ "_untagged") = clamped_value;
    }

    pub fn setValueFlagOnly(self: *BlockUsedSizes, comptime field: Flags.Field) void {
        @field(self.flags, @tagName(field)) = .value;
    }

    pub fn setAuto(self: *BlockUsedSizes, comptime field: Flags.Field) void {
        @field(self.flags, @tagName(field)) = .auto;
        @field(self, @tagName(field) ++ "_untagged") = 0;
    }

    pub fn setPercentage(self: *BlockUsedSizes, comptime field: Flags.Field, value: f32) void {
        @field(self.flags, @tagName(field)) = .percentage;
        @field(self, @tagName(field) ++ "_untagged") = @bitCast(value);
    }

    pub fn GetReturnType(comptime field: Flags.Field) type {
        return switch (@FieldType(Flags, @tagName(field))) {
            IsAutoTag => ?math.Unit,
            IsAutoOrPercentageTag => IsAutoOrPercentage,
            else => comptime unreachable,
        };
    }

    pub fn get(self: BlockUsedSizes, comptime field: Flags.Field) GetReturnType(field) {
        const flag = @field(self.flags, @tagName(field));
        const value = @field(self, @tagName(field) ++ "_untagged");
        return switch (@FieldType(Flags, @tagName(field))) {
            IsAutoTag => switch (flag) {
                .value => value,
                .auto => null,
            },
            IsAutoOrPercentageTag => switch (flag) {
                .value => .{ .value = value },
                .auto => .auto,
                .percentage => .{ .percentage = @bitCast(value) },
            },
            else => comptime unreachable,
        };
    }

    pub fn isAuto(self: BlockUsedSizes, comptime field: Flags.Field) bool {
        return @field(self.flags, @tagName(field)) == .auto;
    }

    fn icb(size: math.Size) BlockUsedSizes {
        return .{
            .border_inline_start = 0,
            .border_inline_end = 0,
            .padding_inline_start = 0,
            .padding_inline_end = 0,
            .margin_inline_start_untagged = 0,
            .margin_inline_end_untagged = 0,
            .inline_size_untagged = size.w,
            .min_inline_size = size.w,
            .max_inline_size = size.w,

            .border_block_start = 0,
            .border_block_end = 0,
            .padding_block_start = 0,
            .padding_block_end = 0,
            .margin_block_start = 0,
            .margin_block_end = 0,
            .block_size_untagged = size.h,
            .min_block_size = size.h,
            .max_block_size = size.h,

            .inset_inline_start_untagged = 0,
            .inset_inline_end_untagged = 0,
            .inset_block_start_untagged = 0,
            .inset_block_end_untagged = 0,

            .flags = .{
                .inline_size = .value,
                .margin_inline_start = .value,
                .margin_inline_end = .value,
                .block_size = .value,
                .inset_inline_start = .value,
                .inset_inline_end = .value,
                .inset_block_start = .value,
                .inset_block_end = .value,
            },
        };
    }
};

/// Writes all of a block's data to the BoxTree.
fn setDataBlock(
    subtree: Subtree.View,
    index: Subtree.Size,
    used: BlockUsedSizes,
    skip: Subtree.Size,
    width: math.Unit,
    height: math.Unit,
    stacking_context: ?StackingContextTree.Id,
    node: NodeId,
) void {
    subtree.items(.skip)[index] = skip;
    subtree.items(.type)[index] = .block;
    subtree.items(.stacking_context)[index] = stacking_context;
    subtree.items(.node)[index] = node;

    const box_offsets = &subtree.items(.box_offsets)[index];
    const borders = &subtree.items(.borders)[index];
    const margins = &subtree.items(.margins)[index];

    // Horizontal sizes
    box_offsets.border_pos.x = used.get(.margin_inline_start).?;
    box_offsets.content_pos.x = used.border_inline_start + used.padding_inline_start;
    box_offsets.content_size.w = width;
    box_offsets.border_size.w = box_offsets.content_pos.x + box_offsets.content_size.w + used.padding_inline_end + used.border_inline_end;

    borders.left = used.border_inline_start;
    borders.right = used.border_inline_end;

    margins.left = used.get(.margin_inline_start).?;
    margins.right = used.get(.margin_inline_end).?;

    // Vertical sizes
    box_offsets.border_pos.y = used.margin_block_start;
    box_offsets.content_pos.y = used.border_block_start + used.padding_block_start;
    box_offsets.content_size.h = height;
    box_offsets.border_size.h = box_offsets.content_pos.y + box_offsets.content_size.h + used.padding_block_end + used.border_block_end;

    borders.top = used.border_block_start;
    borders.bottom = used.border_block_end;

    margins.top = used.margin_block_start;
    margins.bottom = used.margin_block_end;
}

fn setDataIfcContainer(
    subtree: Subtree.View,
    ifc: Ifc.Id,
    index: Subtree.Size,
    skip: Subtree.Size,
    width: math.Unit,
    height: math.Unit,
) void {
    subtree.items(.skip)[index] = skip;
    subtree.items(.type)[index] = .{ .ifc_container = ifc };
    subtree.items(.stacking_context)[index] = null;
    subtree.items(.box_offsets)[index] = .{
        .border_pos = .{ .x = 0, .y = 0 },
        .border_size = .{ .w = width, .h = height },
        .content_pos = .{ .x = 0, .y = 0 },
        .content_size = .{ .w = width, .h = height },
    };
    subtree.items(.borders)[index] = .{};
    subtree.items(.margins)[index] = .{};
}

fn setDataSubtreeProxy(
    subtree: Subtree.View,
    index: Subtree.Size,
    proxied_subtree: *Subtree,
) void {
    const border_size = blk: {
        const view = proxied_subtree.view();
        var border_size = view.items(.box_offsets)[0].border_size;
        const margins = view.items(.margins)[0];
        border_size.w += margins.left + margins.right;
        border_size.h += margins.top + margins.bottom;
        break :blk border_size;
    };

    subtree.items(.skip)[index] = 1;
    subtree.items(.type)[index] = .{ .subtree_proxy = proxied_subtree.id };
    subtree.items(.stacking_context)[index] = null;
    subtree.items(.box_offsets)[index] = .{
        .border_pos = .{ .x = 0, .y = 0 },
        .border_size = border_size,
        .content_pos = .{ .x = 0, .y = 0 },
        .content_size = border_size,
    };
    subtree.items(.borders)[index] = .{};
    subtree.items(.margins)[index] = .{};
}
