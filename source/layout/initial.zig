const std = @import("std");
const assert = std.debug.assert;

const zss = @import("../zss.zig");
const Inputs = zss.layout.Inputs;

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

pub const InitialLayoutContext = struct {
    allocator: std.mem.Allocator,
    subtree_id: SubtreeId = undefined,
};

pub fn run(ctx: *InitialLayoutContext, sc: *StackingContexts, computer: *StyleComputer, box_tree: *BoxTree, inputs: Inputs) !void {
    const width = inputs.viewport.w;
    const height = inputs.viewport.h;

    const subtree_id = try box_tree.blocks.makeSubtree(box_tree.allocator, null);
    ctx.subtree_id = subtree_id;
    const subtree = box_tree.blocks.subtree(subtree_id);

    const block_index = try subtree.appendBlock(box_tree.allocator);
    const subtree_slice = subtree.slice();
    subtree_slice.items(.type)[block_index] = .block;
    subtree_slice.items(.stacking_context)[block_index] = null;
    subtree_slice.items(.box_offsets)[block_index] = .{
        .border_pos = .{ .x = 0, .y = 0 },
        .content_pos = .{ .x = 0, .y = 0 },
        .content_size = .{ .w = width, .h = height },
        .border_size = .{ .w = width, .h = height },
    };
    subtree_slice.items(.borders)[block_index] = .{};
    subtree_slice.items(.margins)[block_index] = .{};
    box_tree.blocks.initial_containing_block = .{ .subtree = subtree_id, .index = block_index };

    const skip = try analyzeRootElement(ctx, sc, computer, box_tree, inputs);
    subtree_slice.items(.skip)[block_index] = 1 + skip;
}

fn analyzeRootElement(
    ctx: *const InitialLayoutContext,
    sc: *StackingContexts,
    computer: *StyleComputer,
    box_tree: *BoxTree,
    inputs: Inputs,
) !BlockBoxSkip {
    if (inputs.root_element.eqlNull()) return 0;
    computer.setRootElement(.box_gen, inputs.root_element);
    const element = computer.getCurrentElement();

    const effective_display = blk: {
        if (computer.elementCategory(element) == .text) {
            break :blk .text;
        }

        const specified_box_style = computer.getSpecifiedValue(.box_gen, .box_style);
        const computed_box_style, const effective_display = solve.boxStyle(specified_box_style, .Root);
        computer.setComputedValue(.box_gen, .box_style, computed_box_style);
        break :blk effective_display;
    };

    const specified_font = computer.getSpecifiedValue(.box_gen, .font);
    computer.setComputedValue(.box_gen, .font, specified_font);

    switch (effective_display) {
        .block => {
            const used_sizes = flow.solveAllSizes(computer, inputs.viewport.w, inputs.viewport.h);
            const stacking_context = rootFlowBlockSolveStackingContext(computer);

            // TODO: The rest of this code block is repeated almost verbatim in at least 2 other places.
            const subtree = box_tree.blocks.subtree(ctx.subtree_id);
            const block_index = try subtree.appendBlock(box_tree.allocator);
            const generated_box = GeneratedBox{ .block_box = .{ .subtree = ctx.subtree_id, .index = block_index } };
            try box_tree.mapElementToBox(element, generated_box);

            const stacking_context_id = try sc.push(stacking_context, box_tree, generated_box.block_box);
            try computer.pushElement(.box_gen);
            const result = try flow.runFlowLayout(ctx.allocator, box_tree, sc, computer, inputs, ctx.subtree_id, used_sizes);
            sc.pop(box_tree);
            computer.popElement(.box_gen);

            const skip = 1 + result.skip_of_children;
            const width = flow.solveUsedWidth(used_sizes.get(.inline_size).?, used_sizes.min_inline_size, used_sizes.max_inline_size);
            const height = flow.solveUsedHeight(used_sizes.get(.block_size), used_sizes.min_block_size, used_sizes.max_block_size, result.auto_height);
            flow.writeBlockData(subtree.slice(), block_index, used_sizes, skip, width, height, stacking_context_id);

            return skip;
        },
        .none => {
            computer.advanceElement(.box_gen);
            return 0;
        },
        .text => {
            const subtree = box_tree.blocks.subtree(ctx.subtree_id);
            const ifc_container_index = try subtree.appendBlock(box_tree.allocator);

            const stacking_context: StackingContexts.Info = .{ .is_parent = 0 };
            const stacking_context_id = try sc.push(stacking_context, box_tree, .{ .subtree = ctx.subtree_id, .index = ifc_container_index });
            const result = try @"inline".runInlineLayout(
                ctx.allocator,
                sc,
                computer,
                box_tree,
                ctx.subtree_id,
                .Normal,
                inputs.viewport.w,
                inputs.viewport.h,
                inputs,
            );
            sc.pop(box_tree);

            const ifc = box_tree.ifc(result.ifc_id);
            const line_split_result =
                try @"inline".splitIntoLineBoxes(ctx.allocator, box_tree, subtree, ifc, inputs, inputs.viewport.w);
            ifc.parent_block = .{ .subtree = ctx.subtree_id, .index = ifc_container_index };

            const skip = 1 + result.total_inline_block_skip;
            subtree.setIfcContainer(
                result.ifc_id,
                ifc_container_index,
                skip,
                stacking_context_id,
                0,
                inputs.viewport.w,
                line_split_result.height,
            );

            return skip;
        },
        .@"inline", .inline_block => unreachable,
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
