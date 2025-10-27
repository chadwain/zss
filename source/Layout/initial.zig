const zss = @import("../zss.zig");
const BoxTree = zss.BoxTree;
const Layout = zss.Layout;
const NodeId = zss.Environment.NodeId;
const SctBuilder = Layout.StackingContextTreeBuilder;
const StyleComputer = Layout.StyleComputer;

const flow = @import("./flow.zig");

pub fn beginMode(layout: *Layout) !void {
    try layout.pushInitialSubtree();
    const ref = try layout.pushInitialContainingBlock(layout.viewport);
    layout.box_tree.ptr.initial_containing_block = ref;
}

fn endMode(layout: *Layout) void {
    layout.popInitialContainingBlock();
    layout.popSubtree();
}

pub fn blockElement(layout: *Layout, element: NodeId, inner_block: BoxTree.BoxStyle.InnerBlock, position: BoxTree.BoxStyle.Position) !void {
    const sizes = flow.solveAllSizes(&layout.computer, position, .{ .normal = layout.viewport.w }, layout.viewport.h);
    const stacking_context = rootBlockSolveStackingContext(&layout.computer);
    layout.computer.commitNode(.box_gen);

    switch (inner_block) {
        .flow => {
            const ref = try layout.pushFlowBlock(sizes, .normal, stacking_context, element);
            try layout.box_tree.setGeneratedBox(element, .{ .block_ref = ref });
            try layout.pushNode();
            return layout.beginFlowMode(.root);
        },
    }
}

pub fn nullNode(layout: *Layout) void {
    endMode(layout);
}

pub fn afterFlowMode(layout: *Layout) void {
    layout.popFlowBlock(.normal);
    layout.popNode();
}

pub fn afterStfMode() noreturn {
    unreachable;
}

pub fn beforeInlineMode() Layout.SizeMode {
    return .normal;
}

pub fn afterInlineMode() void {}

fn rootBlockSolveStackingContext(computer: *StyleComputer) SctBuilder.Type {
    const z_index = computer.getSpecifiedValue(.box_gen, .z_index);
    computer.setComputedValue(.box_gen, .z_index, z_index);
    // TODO: Use z-index?
    return .{ .parentable = 0 };
}
