const zss = @import("../zss.zig");
const BoxTree = zss.BoxTree;
const NodeId = zss.Environment.NodeId;
const StyleComputer = zss.Layout.StyleComputer;

const BoxGen = zss.Layout.BoxGen;
const SctBuilder = BoxGen.StackingContextTreeBuilder;

const flow = @import("./flow.zig");

pub fn beginMode(box_gen: *BoxGen) !void {
    const layout = box_gen.getLayout();
    try box_gen.pushInitialSubtree();
    const ref = try box_gen.pushInitialContainingBlock(layout.viewport);
    layout.box_tree.ptr.initial_containing_block = ref;
}

fn endMode(box_gen: *BoxGen) void {
    box_gen.popInitialContainingBlock();
    box_gen.popSubtree();
}

pub fn blockElement(box_gen: *BoxGen, node: NodeId, inner_block: BoxTree.BoxStyle.InnerBlock, position: BoxTree.BoxStyle.Position) !void {
    const layout = box_gen.getLayout();
    const sizes = flow.solveAllSizes(&layout.computer, position, .{ .normal = layout.viewport.w }, layout.viewport.h);
    const stacking_context = rootBlockSolveStackingContext(&layout.computer);
    layout.computer.commitNode(.box_gen);

    switch (inner_block) {
        .flow => {
            const ref = try box_gen.pushFlowBlock(sizes, .normal, stacking_context, node);
            try layout.box_tree.setGeneratedBox(node, .{ .block_ref = ref });
            try layout.pushNode();
            return box_gen.beginFlowMode(.root);
        },
    }
}

pub fn nullNode(box_gen: *BoxGen) void {
    endMode(box_gen);
}

pub fn afterFlowMode(box_gen: *BoxGen) void {
    box_gen.popFlowBlock(.normal);
    box_gen.getLayout().popNode();
}

pub fn afterStfMode() noreturn {
    unreachable;
}

pub fn beforeInlineMode() BoxGen.SizeMode {
    return .normal;
}

pub fn afterInlineMode() void {}

fn rootBlockSolveStackingContext(computer: *StyleComputer) SctBuilder.Type {
    const z_index = computer.getSpecifiedValue(.box_gen, .z_index);
    computer.setComputedValue(.box_gen, .z_index, z_index);
    // TODO: Use z-index?
    return .{ .parentable = 0 };
}
