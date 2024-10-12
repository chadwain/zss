const std = @import("std");
const assert = std.debug.assert;

const zss = @import("../zss.zig");
const Layout = zss.Layout;

const flow = @import("./flow.zig");
const @"inline" = @import("./inline.zig");
const solve = @import("./solve.zig");
const StyleComputer = @import("./StyleComputer.zig");
const StackingContexts = @import("./StackingContexts.zig");

const used_values = zss.used_values;
const BlockBox = used_values.BlockBox;
const BlockBoxSkip = used_values.BlockBoxSkip;
const BoxTree = used_values.BoxTree;
const GeneratedBox = used_values.GeneratedBox;
const SubtreeId = used_values.SubtreeId;

const hb = @import("mach-harfbuzz").c;

pub fn run(layout: *Layout) !void {
    try layout.pushInitialSubtree();
    const block_box = try layout.pushInitialContainingBlock(layout.viewport);
    layout.box_tree.blocks.initial_containing_block = block_box;

    try analyzeRootElement(layout);
    layout.popInitialContainingBlock();
    layout.popSubtree();
}

fn analyzeRootElement(layout: *Layout) !void {
    const element = layout.currentElement();
    if (element.eqlNull()) return;
    try layout.computer.setCurrentElement(.box_gen, element);

    const used_box_style: used_values.BoxStyle = blk: {
        if (layout.computer.elementCategory(element) == .text) {
            break :blk used_values.BoxStyle.text;
        }

        const specified_box_style = layout.computer.getSpecifiedValue(.box_gen, .box_style);
        const computed_box_style, const used_box_style = solve.boxStyle(specified_box_style, .Root);
        layout.computer.setComputedValue(.box_gen, .box_style, computed_box_style);
        break :blk used_box_style;
    };

    switch (used_box_style.outer) {
        .block => |inner| switch (inner) {
            .flow => {
                const used_sizes = flow.solveAllSizes(&layout.computer, used_box_style.position, layout.viewport.w, layout.viewport.h);
                const stacking_context = rootFlowBlockSolveStackingContext(&layout.computer);
                layout.computer.commitElement(.box_gen);

                const block_box = try layout.pushFlowBlock(used_box_style, used_sizes, stacking_context);
                try layout.box_tree.mapElementToBox(element, .{ .block_box = block_box });
                try layout.pushElement();
                const result = try flow.runFlowLayout(layout, used_sizes);
                _ = layout.popFlowBlock(result.auto_height);
                layout.popElement();
            },
        },
        .none => {
            layout.advanceElement();
        },
        .@"inline" => |inner| switch (inner) {
            .text => {
                const result = try @"inline".runInlineLayout(layout, .Normal, layout.viewport.w, layout.viewport.h);
                _ = result;
            },
            .@"inline", .block => unreachable,
        },
        .absolute => unreachable,
    }
}

fn rootFlowBlockSolveStackingContext(computer: *StyleComputer) StackingContexts.Info {
    const z_index = computer.getSpecifiedValue(.box_gen, .z_index);
    computer.setComputedValue(.box_gen, .z_index, z_index);
    // TODO: Use z-index?
    return .{ .is_parent = 0 };
}
