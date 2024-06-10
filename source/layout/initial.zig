const std = @import("std");
const assert = std.debug.assert;

const zss = @import("../zss.zig");
const Inputs = zss.layout.Inputs;

const flow = @import("./flow.zig");
const solve = @import("./solve.zig");
const StyleComputer = @import("./StyleComputer.zig");
const StackingContexts = @import("./StackingContexts.zig");

const used_values = zss.used_values;
const BlockBox = used_values.BlockBox;
const BlockBoxSkip = used_values.BlockBoxSkip;
const BoxTree = used_values.BoxTree;
const SubtreeId = used_values.SubtreeId;

const hb = @import("mach-harfbuzz").c;

pub const InitialLayoutContext = struct {
    allocator: std.mem.Allocator,
    subtree_id: SubtreeId = undefined,
};

pub fn run(layout: *InitialLayoutContext, sc: *StackingContexts, computer: *StyleComputer, box_tree: *BoxTree, inputs: Inputs) !void {
    const width = inputs.viewport.w;
    const height = inputs.viewport.h;

    const subtree_id = try box_tree.blocks.makeSubtree(box_tree.allocator, .{ .parent = null });
    layout.subtree_id = subtree_id;
    const subtree = box_tree.blocks.subtree(subtree_id);

    const block_index = try subtree.appendBlock(box_tree.allocator);
    const subtree_slice = subtree.slice();
    subtree_slice.items(.type)[block_index] = .{ .block = .{ .stacking_context = null } };
    subtree_slice.items(.box_offsets)[block_index] = .{
        .border_pos = .{ .x = 0, .y = 0 },
        .content_pos = .{ .x = 0, .y = 0 },
        .content_size = .{ .w = width, .h = height },
        .border_size = .{ .w = width, .h = height },
    };
    subtree_slice.items(.borders)[block_index] = .{};
    subtree_slice.items(.margins)[block_index] = .{};
    box_tree.blocks.initial_containing_block = .{ .subtree = subtree_id, .index = block_index };

    const skip = try analyzeRootElement(layout, sc, computer, box_tree, inputs);
    subtree_slice.items(.skip)[block_index] = 1 + skip;
}

fn analyzeRootElement(
    layout: *const InitialLayoutContext,
    sc: *StackingContexts,
    computer: *StyleComputer,
    box_tree: *BoxTree,
    inputs: Inputs,
) !BlockBoxSkip {
    if (inputs.root_element.eqlNull()) return 0;
    computer.setRootElement(.box_gen, inputs.root_element);
    const element = computer.getCurrentElement();

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
            const used_sizes = flow.solveAllSizes(computer, inputs.viewport.w, inputs.viewport.h);
            const stacking_context = rootFlowBlockSolveStackingContext(computer);
            try computer.pushElement(.box_gen);

            const result = try flow.runFlowLayout(
                layout.allocator,
                box_tree,
                sc,
                computer,
                element,
                layout.subtree_id,
                used_sizes,
                stacking_context,
            );

            return result.skip;
        },
        .none => return 0,
        .@"inline", .inline_block, .text => unreachable,
        .initial, .inherit, .unset, .undeclared => unreachable,
    }

    computer.popElement(.box_gen);
}

fn rootFlowBlockSolveStackingContext(
    computer: *StyleComputer,
) StackingContexts.Info {
    const z_index = computer.getSpecifiedValue(.box_gen, .z_index);
    computer.setComputedValue(.box_gen, .z_index, z_index);
    // TODO: Use z-index?
    return .{ .is_parent = 0 };
}
