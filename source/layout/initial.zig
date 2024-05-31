const std = @import("std");
const assert = std.debug.assert;

const zss = @import("../zss.zig");
const root_element = @as(zss.ElementIndex, 0);

const Inputs = zss.layout.Inputs;
const flow = @import("./flow.zig");
const solve = @import("./solve.zig");
const inline_layout = @import("./inline.zig");
const StyleComputer = @import("./StyleComputer.zig");
const StackingContexts = @import("./StackingContexts.zig");

const used_values = zss.used_values;
const ZssUnit = used_values.ZssUnit;
const BlockBoxIndex = used_values.BlockBoxIndex;
const initial_containing_block = @as(BlockBoxIndex, 0);
const BlockBox = used_values.BlockBox;
const BlockBoxSkip = used_values.BlockBoxSkip;
const BlockSubtreeIndex = used_values.SubtreeIndex;
const initial_subtree = @as(BlockSubtreeIndex, 0);
const BoxTree = used_values.BoxTree;

const hb = @import("mach-harfbuzz").c;

pub const InitialLayoutContext = struct {
    allocator: std.mem.Allocator,

    width: ZssUnit = undefined,
    height: ZssUnit = undefined,
};

pub fn run(layout: *InitialLayoutContext, sc: *StackingContexts, computer: *StyleComputer, box_tree: *BoxTree, inputs: Inputs) !void {
    const width = inputs.viewport.w;
    const height = inputs.viewport.h;

    const subtree_index = try box_tree.blocks.makeSubtree(box_tree.allocator, .{ .parent = null });
    assert(subtree_index == initial_subtree);
    const subtree = box_tree.blocks.subtrees.items[subtree_index];

    const block = try zss.layout.createBlock(box_tree, subtree);
    assert(block.index == initial_containing_block);
    block.skip.* = undefined;
    block.type.* = .{ .block = .{ .stacking_context = null } };
    block.box_offsets.* = .{
        .border_pos = .{ .x = 0, .y = 0 },
        .content_pos = .{ .x = 0, .y = 0 },
        .content_size = .{ .w = width, .h = height },
        .border_size = .{ .w = width, .h = height },
    };
    block.borders.* = .{};
    block.margins.* = .{};

    layout.width = width;
    layout.height = height;
    const skip = try analyzeRootBlock(layout, sc, computer, box_tree);
    block.skip.* = 1 + skip;
}

fn analyzeRootBlock(layout: *const InitialLayoutContext, sc: *StackingContexts, computer: *StyleComputer, box_tree: *BoxTree) !BlockBoxSkip {
    if (computer.root_element.eqlNull()) return 0;

    const element = computer.root_element;
    computer.setElementDirectChild(.box_gen, element);

    const font = computer.getSpecifiedValue(.box_gen, .font);
    computer.setComputedValue(.box_gen, .font, font);
    computer.root_font.font = switch (font.font) {
        .font => |f| f,
        .zss_default => hb.hb_font_get_empty().?, // TODO: Provide a text-rendering-backend-specific default font.
        .initial, .inherit, .unset, .undeclared => unreachable,
    };

    const specified = .{
        .box_style = computer.getSpecifiedValue(.box_gen, .box_style),
    };
    const computed = .{
        .box_style = solve.boxStyle(specified.box_style, .Root),
    };
    computer.setComputedValue(.box_gen, .box_style, computed.box_style);

    switch (computed.box_style.display) {
        .block => {
            const subtree = box_tree.blocks.subtrees.items[initial_subtree];
            const block = try zss.layout.createBlock(box_tree, subtree);
            const block_box = BlockBox{ .subtree = initial_subtree, .index = block.index };
            try box_tree.element_to_generated_box.putNoClobber(box_tree.allocator, element, .{ .block_box = block_box });

            const used_sizes = try flow.solveAllSizes(computer, layout.width, layout.height);
            const stacking_context = try rootFlowBlockCreateStackingContext(box_tree, computer, sc, block_box);
            try computer.pushElement(.box_gen);

            const result = try flow.runFlowLayout(
                layout.allocator,
                box_tree,
                sc,
                computer,
                block,
                initial_subtree,
                block.index,
                used_sizes,
                stacking_context,
            );
            return result.skip;
        },
        .none => return 0,
        .@"inline", .inline_block, .text => unreachable,
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
}

fn rootFlowBlockCreateStackingContext(
    box_tree: *BoxTree,
    computer: *StyleComputer,
    sc: *StackingContexts,
    block_box: BlockBox,
) !StackingContexts.Info {
    const z_index = computer.getSpecifiedValue(.box_gen, .z_index);
    computer.setComputedValue(.box_gen, .z_index, z_index);
    // TODO: Use z-index?
    return sc.createRoot(box_tree, block_box);
}
