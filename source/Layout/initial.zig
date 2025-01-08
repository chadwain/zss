const zss = @import("../zss.zig");
const BoxTree = zss.BoxTree;
const Element = zss.ElementTree.Element;
const Layout = zss.Layout;
const SctBuilder = Layout.StackingContextTreeBuilder;
const StyleComputer = Layout.StyleComputer;

const flow = @import("./flow.zig");

pub fn beginMode(layout: *Layout) !void {
    try layout.pushInitialSubtree();
    const ref = try layout.pushInitialContainingBlock(layout.viewport);
    layout.box_tree.ptr.initial_containing_block = ref;
}

pub fn endMode(layout: *Layout) void {
    layout.popInitialContainingBlock();
    layout.popSubtree();
}

pub fn blockElement(layout: *Layout, element: Element, inner_block: BoxTree.BoxStyle.InnerBlock, position: BoxTree.BoxStyle.Position) !void {
    switch (inner_block) {
        .flow => {
            const sizes = flow.solveAllSizes(&layout.computer, position, layout.viewport.w, layout.viewport.h);
            const stacking_context = rootFlowBlockSolveStackingContext(&layout.computer);
            layout.computer.commitElement(.box_gen);

            const ref = try layout.pushFlowBlock(sizes, stacking_context);
            try layout.box_tree.setGeneratedBox(element, .{ .block_ref = ref });
            try layout.pushElement();
            return layout.pushFlowMode(.Root);
        },
    }
}

pub fn inlineElement(layout: *Layout) !void {
    return layout.pushInlineMode(.Root, .Normal, .{ .width = layout.viewport.w, .height = layout.viewport.h });
}

pub fn endFlowMode(layout: *Layout) void {
    layout.popFlowBlock();
    layout.popElement();
}

fn rootFlowBlockSolveStackingContext(computer: *StyleComputer) SctBuilder.Type {
    const z_index = computer.getSpecifiedValue(.box_gen, .z_index);
    computer.setComputedValue(.box_gen, .z_index, z_index);
    // TODO: Use z-index?
    return .{ .parentable = 0 };
}
