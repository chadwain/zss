const std = @import("std");
const assert = std.debug.assert;

const zss = @import("../zss.zig");
const Layout = zss.layout.Layout;

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

pub fn run(layout: *Layout, ctx: *InitialLayoutContext) !void {
    const width = layout.inputs.viewport.w;
    const height = layout.inputs.viewport.h;

    const subtree_id = try layout.box_tree.blocks.makeSubtree(layout.box_tree.allocator, null);
    ctx.subtree_id = subtree_id;
    const subtree = layout.box_tree.blocks.subtree(subtree_id);

    const block_index = try subtree.appendBlock(layout.box_tree.allocator);
    layout.box_tree.blocks.initial_containing_block = .{ .subtree = subtree_id, .index = block_index };

    const stacking_context: StackingContexts.Info = .{ .is_parent = 0 };

    const stacking_context_id = try layout.sc.push(stacking_context, layout.box_tree, layout.box_tree.blocks.initial_containing_block);
    const skip = try analyzeRootElement(layout, ctx);
    layout.sc.pop(layout.box_tree);

    const subtree_slice = subtree.slice();
    subtree_slice.items(.skip)[block_index] = 1 + skip;
    subtree_slice.items(.type)[block_index] = .block;
    subtree_slice.items(.stacking_context)[block_index] = stacking_context_id;
    subtree_slice.items(.box_offsets)[block_index] = .{
        .border_pos = .{ .x = 0, .y = 0 },
        .content_pos = .{ .x = 0, .y = 0 },
        .content_size = .{ .w = width, .h = height },
        .border_size = .{ .w = width, .h = height },
    };
    subtree_slice.items(.borders)[block_index] = .{};
    subtree_slice.items(.margins)[block_index] = .{};
}

fn analyzeRootElement(layout: *Layout, ctx: *const InitialLayoutContext) !BlockBoxSkip {
    const element = layout.currentElement();
    if (element.eqlNull()) return 0;
    layout.computer.setCurrentElement(.box_gen, element);

    const used_box_style: used_values.BoxStyle = blk: {
        if (layout.computer.elementCategory(element) == .text) {
            break :blk .{ .@"inline" = .text };
        }

        const specified_box_style = layout.computer.getSpecifiedValue(.box_gen, .box_style);
        const specified_font = layout.computer.getSpecifiedValue(.box_gen, .font);
        const computed_box_style, const used_box_style = solve.boxStyle(specified_box_style, .Root);
        layout.computer.setComputedValue(.box_gen, .box_style, computed_box_style);
        layout.computer.setComputedValue(.box_gen, .font, specified_font);
        break :blk used_box_style;
    };

    switch (used_box_style) {
        .block => |inner| switch (inner) {
            .flow => {
                const used_sizes = flow.solveAllSizes(&layout.computer, layout.inputs.viewport.w, layout.inputs.viewport.h);
                const stacking_context = rootFlowBlockSolveStackingContext(&layout.computer);
                try layout.computer.commitElement(.box_gen);

                // TODO: The rest of this code block is repeated almost verbatim in at least 2 other places.
                const subtree = layout.box_tree.blocks.subtree(ctx.subtree_id);
                const block_index = try subtree.appendBlock(layout.box_tree.allocator);
                const generated_box = GeneratedBox{ .block_box = .{ .subtree = ctx.subtree_id, .index = block_index } };
                try layout.box_tree.mapElementToBox(element, generated_box);

                const stacking_context_id = try layout.sc.push(stacking_context, layout.box_tree, generated_box.block_box);
                try layout.pushElement();
                const result = try flow.runFlowLayout(layout, ctx.subtree_id, used_sizes);
                layout.sc.pop(layout.box_tree);
                layout.popElement();

                const skip = 1 + result.skip_of_children;
                const width = flow.solveUsedWidth(used_sizes.get(.inline_size).?, used_sizes.min_inline_size, used_sizes.max_inline_size);
                const height = flow.solveUsedHeight(used_sizes.get(.block_size), used_sizes.min_block_size, used_sizes.max_block_size, result.auto_height);
                flow.writeBlockData(subtree.slice(), block_index, used_sizes, skip, width, height, stacking_context_id.?);

                return skip;
            },
        },
        .none => {
            layout.advanceElement();
            return 0;
        },
        .@"inline" => |inner| switch (inner) {
            .text => {
                const result = try @"inline".runInlineLayout(layout, ctx.subtree_id, .Normal, layout.inputs.viewport.w, layout.inputs.viewport.h);
                return result.skip;
            },
            .@"inline", .flow => unreachable,
        },
        .absolute => unreachable,
    }

    layout.popElement();
}

fn rootFlowBlockSolveStackingContext(computer: *StyleComputer) StackingContexts.Info {
    const z_index = computer.getSpecifiedValue(.box_gen, .z_index);
    computer.setComputedValue(.box_gen, .z_index, z_index);
    // TODO: Use z-index?
    return .{ .is_parent = 0 };
}
