const std = @import("std");
const assert = std.debug.assert;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

const zss = @import("../../zss.zig");
const root_element = @as(zss.ElementIndex, 0);

const solve = @import("./solve.zig");
const StyleComputer = @import("./StyleComputer.zig");

const used_values = @import("./used_values.zig");
const initial_containing_block = @as(used_values.BlockBoxIndex, 0);
const initial_subtree = @as(used_values.SubtreeIndex, 0);
const BlockBox = used_values.BlockBox;
const InlineBoxIndex = used_values.InlineBoxIndex;
const InlineFormattingContext = used_values.InlineFormattingContext;
const BoxTree = used_values.BoxTree;

pub fn run(computer: *StyleComputer, box_tree: *BoxTree) !void {
    for (box_tree.blocks.subtrees.items) |*subtree| {
        const num_created_boxes = subtree.skip.items.len;
        try subtree.border_colors.resize(box_tree.allocator, num_created_boxes);
        try subtree.background1.resize(box_tree.allocator, num_created_boxes);
        try subtree.background2.resize(box_tree.allocator, num_created_boxes);
    }

    anonymousBlockBoxCosmeticLayout(box_tree, .{ .subtree = initial_subtree, .index = initial_containing_block });
    // TODO: Also process any anonymous block boxes.

    for (box_tree.ifcs.items) |ifc| {
        try ifc.background1.resize(box_tree.allocator, ifc.inline_start.items.len);
        rootInlineBoxCosmeticLayout(ifc);
    }

    if (computer.element_tree_skips.len == 0) return;

    {
        const skip = computer.element_tree_skips[root_element];
        computer.setElementDirectChild(.cosmetic, root_element);
        const box_type = box_tree.element_index_to_generated_box[root_element];
        switch (box_type) {
            .none => return,
            .block_box => |block_box| try blockBoxCosmeticLayout(computer, box_tree, block_box),
            .inline_box, .text => unreachable,
        }

        // TODO: Temporary jank to set the text color.
        const computed_color = computer.stage.cosmetic.current_values.color;
        const used_color = solve.currentColor(computed_color.color);
        for (box_tree.ifcs.items) |ifc| {
            ifc.font_color_rgba = used_color;
        }

        if (skip != 1) {
            try computer.pushElement(.cosmetic);
        }
    }

    while (computer.intervals.items.len > 0) {
        const interval = &computer.intervals.items[computer.intervals.items.len - 1];

        if (interval.begin != interval.end) {
            const element = interval.begin;
            const skip = computer.element_tree_skips[element];
            interval.begin += skip;

            computer.setElementDirectChild(.cosmetic, element);
            const box_type = box_tree.element_index_to_generated_box[element];
            switch (box_type) {
                .none, .text => continue,
                .block_box => |block_box| try blockBoxCosmeticLayout(computer, box_tree, block_box),
                .inline_box => |box_spec| {
                    const ifc = box_tree.ifcs.items[box_spec.ifc_index];
                    inlineBoxCosmeticLayout(computer, ifc, box_spec.index);
                },
            }

            if (skip != 1) {
                try computer.pushElement(.cosmetic);
            }
        } else {
            computer.popElement(.cosmetic);
        }
    }
}

fn blockBoxCosmeticLayout(computer: *StyleComputer, box_tree: *BoxTree, block_box: BlockBox) !void {
    const specified = .{
        .color = computer.getSpecifiedValue(.cosmetic, .color),
        .border_colors = computer.getSpecifiedValue(.cosmetic, .border_colors),
        .border_styles = computer.getSpecifiedValue(.cosmetic, .border_styles),
        .background1 = computer.getSpecifiedValue(.cosmetic, .background1),
        .background2 = computer.getSpecifiedValue(.cosmetic, .background2),
    };

    const current_color = solve.currentColor(specified.color.color);

    const subtree = &box_tree.blocks.subtrees.items[block_box.subtree];

    const box_offsets_ptr = &subtree.box_offsets.items[block_box.index];
    const borders_ptr = &subtree.borders.items[block_box.index];

    const border_colors_ptr = &subtree.border_colors.items[block_box.index];
    border_colors_ptr.* = solve.borderColors(specified.border_colors, current_color);

    solve.borderStyles(specified.border_styles);

    const background1_ptr = &subtree.background1.items[block_box.index];
    const background2_ptr = &subtree.background2.items[block_box.index];
    background1_ptr.* = solve.background1(specified.background1, current_color);
    background2_ptr.* = try solve.background2(specified.background2, box_offsets_ptr, borders_ptr);

    // TODO: Pretending that specified values are computed values...
    computer.setComputedValue(.cosmetic, .color, specified.color);
    computer.setComputedValue(.cosmetic, .border_colors, specified.border_colors);
    computer.setComputedValue(.cosmetic, .border_styles, specified.border_styles);
    computer.setComputedValue(.cosmetic, .background1, specified.background1);
    computer.setComputedValue(.cosmetic, .background2, specified.background2);
}

fn anonymousBlockBoxCosmeticLayout(box_tree: *BoxTree, block_box: BlockBox) void {
    const subtree = &box_tree.blocks.subtrees.items[block_box.subtree];
    subtree.border_colors.items[block_box.index] = .{};
    subtree.background1.items[block_box.index] = .{};
    subtree.background2.items[block_box.index] = .{};
}

fn inlineBoxCosmeticLayout(computer: *StyleComputer, ifc: *InlineFormattingContext, inline_box_index: InlineBoxIndex) void {
    const specified = .{
        .color = computer.getSpecifiedValue(.cosmetic, .color),
        .border_colors = computer.getSpecifiedValue(.cosmetic, .border_colors),
        .border_styles = computer.getSpecifiedValue(.cosmetic, .border_styles),
        .background1 = computer.getSpecifiedValue(.cosmetic, .background1),
        .background2 = computer.getSpecifiedValue(.cosmetic, .background2), // TODO: Inline boxes don't need background2
    };

    // TODO: Pretending that specified values are computed values...
    computer.setComputedValue(.cosmetic, .color, specified.color);
    computer.setComputedValue(.cosmetic, .border_colors, specified.border_colors);
    computer.setComputedValue(.cosmetic, .border_styles, specified.border_styles);
    computer.setComputedValue(.cosmetic, .background1, specified.background1);
    computer.setComputedValue(.cosmetic, .background2, specified.background2);

    const current_color = solve.currentColor(specified.color.color);

    const border_colors = solve.borderColors(specified.border_colors, current_color);
    ifc.inline_start.items[inline_box_index].border_color_rgba = border_colors.left_rgba;
    ifc.inline_end.items[inline_box_index].border_color_rgba = border_colors.right_rgba;
    ifc.block_start.items[inline_box_index].border_color_rgba = border_colors.top_rgba;
    ifc.block_end.items[inline_box_index].border_color_rgba = border_colors.bottom_rgba;

    solve.borderStyles(specified.border_styles);

    const background1_ptr = &ifc.background1.items[inline_box_index];
    background1_ptr.* = solve.background1(specified.background1, current_color);
}

fn rootInlineBoxCosmeticLayout(ifc: *InlineFormattingContext) void {
    ifc.inline_start.items[0].border_color_rgba = 0;
    ifc.inline_end.items[0].border_color_rgba = 0;
    ifc.block_start.items[0].border_color_rgba = 0;
    ifc.block_end.items[0].border_color_rgba = 0;

    ifc.background1.items[0] = .{};
}
