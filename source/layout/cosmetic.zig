const std = @import("std");
const assert = std.debug.assert;
const panic = std.debug.panic;
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

const zss = @import("../../zss.zig");
const root_element = @as(zss.ElementIndex, 0);

const solve = @import("./solve.zig");
const StyleComputer = @import("./StyleComputer.zig");

const used_values = @import("./used_values.zig");
const ZssUnit = used_values.ZssUnit;
const ZssSize = used_values.ZssSize;
const initial_containing_block = @as(used_values.BlockBoxIndex, 0);
const initial_subtree = @as(used_values.SubtreeIndex, 0);
const BlockBox = used_values.BlockBox;
const InlineBoxIndex = used_values.InlineBoxIndex;
const InlineFormattingContext = used_values.InlineFormattingContext;
const BoxTree = used_values.BoxTree;

const Mode = enum {
    InitialContainingBlock,
    Flow,
    InlineBox,
};

const Context = struct {
    mode: ArrayListUnmanaged(Mode) = .{},
    containing_block_size: ArrayListUnmanaged(ZssSize) = .{},

    fn deinit(context: *Context, allocator: Allocator) void {
        context.mode.deinit(allocator);
        context.containing_block_size.deinit(allocator);
    }
};

pub fn run(computer: *StyleComputer, box_tree: *BoxTree) !void {
    for (box_tree.blocks.subtrees.items) |*subtree| {
        const num_created_boxes = subtree.skip.items.len;
        try subtree.insets.resize(box_tree.allocator, num_created_boxes);
        try subtree.border_colors.resize(box_tree.allocator, num_created_boxes);
        try subtree.background1.resize(box_tree.allocator, num_created_boxes);
        try subtree.background2.resize(box_tree.allocator, num_created_boxes);
    }

    anonymousBlockBoxCosmeticLayout(box_tree, .{ .subtree = initial_subtree, .index = initial_containing_block });
    // TODO: Also process any anonymous block boxes.

    for (box_tree.ifcs.items) |ifc| {
        try ifc.background1.resize(box_tree.allocator, ifc.inline_start.items.len);
        try ifc.insets.resize(box_tree.allocator, ifc.inline_start.items.len);
        rootInlineBoxCosmeticLayout(ifc);
    }

    if (computer.element_tree_skips.len == 0) return;

    var context = Context{};
    defer context.deinit(computer.allocator);

    {
        const initial_containing_block_subtree = &box_tree.blocks.subtrees.items[initial_subtree];
        const box_offsets = initial_containing_block_subtree.box_offsets.items[initial_containing_block];
        try context.mode.append(computer.allocator, .InitialContainingBlock);
        try context.containing_block_size.append(computer.allocator, box_offsets.content_size);
    }

    {
        const skip = computer.element_tree_skips[root_element];
        computer.setElementDirectChild(.cosmetic, root_element);
        const box_type = box_tree.element_index_to_generated_box[root_element];
        switch (box_type) {
            .none => return,
            .block_box => |block_box| {
                try blockBoxCosmeticLayout(context, computer, box_tree, block_box, .Root);

                if (skip != 1) {
                    const subtree = &box_tree.blocks.subtrees.items[block_box.subtree];
                    const box_offsets = subtree.box_offsets.items[block_box.index];
                    try context.mode.append(computer.allocator, .Flow);
                    try context.containing_block_size.append(computer.allocator, box_offsets.content_size);
                    try computer.pushElement(.cosmetic);
                }
            },
            .inline_box, .text => unreachable,
        }

        // TODO: Temporary jank to set the text color.
        const computed_color = computer.stage.cosmetic.current_values.color;
        const used_color = solve.currentColor(computed_color.color);
        for (box_tree.ifcs.items) |ifc| {
            ifc.font_color_rgba = used_color;
        }
    }

    while (context.mode.items.len > 1) {
        const interval = &computer.intervals.items[computer.intervals.items.len - 1];

        if (interval.begin != interval.end) {
            const element = interval.begin;
            const skip = computer.element_tree_skips[element];
            interval.begin += skip;

            computer.setElementDirectChild(.cosmetic, element);
            const box_type = box_tree.element_index_to_generated_box[element];
            switch (box_type) {
                .none, .text => continue,
                .block_box => |block_box| {
                    try blockBoxCosmeticLayout(context, computer, box_tree, block_box, .NonRoot);

                    if (skip != 1) {
                        const subtree = &box_tree.blocks.subtrees.items[block_box.subtree];
                        const box_offsets = subtree.box_offsets.items[block_box.index];
                        try context.mode.append(computer.allocator, .Flow);
                        try context.containing_block_size.append(computer.allocator, box_offsets.content_size);
                        try computer.pushElement(.cosmetic);
                    }
                },
                .inline_box => |inline_box| {
                    const ifc = box_tree.ifcs.items[inline_box.ifc_index];
                    inlineBoxCosmeticLayout(context, computer, ifc, inline_box.index);

                    if (skip != 1) {
                        try context.mode.append(computer.allocator, .InlineBox);
                        try computer.pushElement(.cosmetic);
                    }
                },
            }
        } else {
            const mode = context.mode.pop();
            switch (mode) {
                .InitialContainingBlock => unreachable,
                .Flow => {
                    _ = context.containing_block_size.pop();
                },
                .InlineBox => {},
            }
            computer.popElement(.cosmetic);
        }
    }

    assert(context.mode.pop() == .InitialContainingBlock);
}

fn blockBoxCosmeticLayout(context: Context, computer: *StyleComputer, box_tree: *BoxTree, block_box: BlockBox, comptime is_root: solve.IsRoot) !void {
    const specified = .{
        .box_style = computer.getSpecifiedValue(.cosmetic, .box_style),
        .color = computer.getSpecifiedValue(.cosmetic, .color),
        .border_colors = computer.getSpecifiedValue(.cosmetic, .border_colors),
        .border_styles = computer.getSpecifiedValue(.cosmetic, .border_styles),
        .background1 = computer.getSpecifiedValue(.cosmetic, .background1),
        .background2 = computer.getSpecifiedValue(.cosmetic, .background2),
        .insets = computer.getSpecifiedValue(.cosmetic, .insets),
    };

    const subtree = &box_tree.blocks.subtrees.items[block_box.subtree];

    const computed_box_style = solve.boxStyle(specified.box_style, is_root);
    const current_color = solve.currentColor(specified.color.color);

    var computed_insets: zss.properties.Insets = undefined;
    {
        const used_insets = &subtree.insets.items[block_box.index];
        switch (computed_box_style.position) {
            .static => solveInsetsStatic(specified.insets, &computed_insets, used_insets),
            .relative => {
                const containing_block_size = context.containing_block_size.items[context.containing_block_size.items.len - 1];
                solveInsetsRelative(specified.insets, containing_block_size, &computed_insets, used_insets);
            },
            .initial, .inherit, .unset, .undeclared => unreachable,
            else => panic("TODO: Block insets with {s} positioning", .{@tagName(computed_box_style.position)}),
        }
    }

    const box_offsets_ptr = &subtree.box_offsets.items[block_box.index];
    const borders_ptr = &subtree.borders.items[block_box.index];

    {
        const border_colors_ptr = &subtree.border_colors.items[block_box.index];
        border_colors_ptr.* = solve.borderColors(specified.border_colors, current_color);
    }

    solve.borderStyles(specified.border_styles);

    {
        const background1_ptr = &subtree.background1.items[block_box.index];
        const background2_ptr = &subtree.background2.items[block_box.index];
        background1_ptr.* = solve.background1(specified.background1, current_color);
        background2_ptr.* = try solve.background2(specified.background2, box_offsets_ptr, borders_ptr);
    }

    computer.setComputedValue(.cosmetic, .box_style, computed_box_style);
    computer.setComputedValue(.cosmetic, .insets, computed_insets);
    // TODO: Pretending that specified values are computed values...
    computer.setComputedValue(.cosmetic, .color, specified.color);
    computer.setComputedValue(.cosmetic, .border_colors, specified.border_colors);
    computer.setComputedValue(.cosmetic, .border_styles, specified.border_styles);
    computer.setComputedValue(.cosmetic, .background1, specified.background1);
    computer.setComputedValue(.cosmetic, .background2, specified.background2);
}

fn solveInsetsStatic(
    specified: zss.properties.Insets,
    computed: *zss.properties.Insets,
    used: *used_values.Insets,
) void {
    switch (specified.left) {
        .px => |value| computed.left = .{ .px = value },
        .percentage => |value| computed.left = .{ .percentage = value },
        .auto => computed.left = .auto,
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
    switch (specified.right) {
        .px => |value| computed.right = .{ .px = value },
        .percentage => |value| computed.right = .{ .percentage = value },
        .auto => computed.right = .auto,
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
    switch (specified.top) {
        .px => |value| computed.top = .{ .px = value },
        .percentage => |value| computed.top = .{ .percentage = value },
        .auto => computed.top = .auto,
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
    switch (specified.bottom) {
        .px => |value| computed.bottom = .{ .px = value },
        .percentage => |value| computed.bottom = .{ .percentage = value },
        .auto => computed.bottom = .auto,
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
    used.* = .{};
}

fn solveInsetsRelative(
    specified: zss.properties.Insets,
    containing_block_size: ZssSize,
    computed: *zss.properties.Insets,
    used: *used_values.Insets,
) void {
    var left: ?ZssUnit = undefined;
    var right: ?ZssUnit = undefined;
    var top: ?ZssUnit = undefined;
    var bottom: ?ZssUnit = undefined;

    switch (specified.left) {
        .px => |value| {
            computed.left = .{ .px = value };
            left = solve.length(.px, value);
        },
        .percentage => |value| {
            computed.left = .{ .percentage = value };
            left = solve.percentage(value, containing_block_size.w);
        },
        .auto => {
            computed.left = .auto;
            left = null;
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
    switch (specified.right) {
        .px => |value| {
            computed.right = .{ .px = value };
            right = -solve.length(.px, value);
        },
        .percentage => |value| {
            computed.right = .{ .percentage = value };
            right = -solve.percentage(value, containing_block_size.w);
        },
        .auto => {
            computed.right = .auto;
            right = null;
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
    switch (specified.top) {
        .px => |value| {
            computed.top = .{ .px = value };
            top = solve.length(.px, value);
        },
        .percentage => |value| {
            computed.top = .{ .percentage = value };
            top = solve.percentage(value, containing_block_size.h);
        },
        .auto => {
            computed.top = .auto;
            top = null;
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
    switch (specified.bottom) {
        .px => |value| {
            computed.bottom = .{ .px = value };
            bottom = -solve.length(.px, value);
        },
        .percentage => |value| {
            computed.bottom = .{ .percentage = value };
            bottom = -solve.percentage(value, containing_block_size.h);
        },
        .auto => {
            computed.bottom = .auto;
            bottom = null;
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }

    used.* = .{
        // TODO: This depends on the writing mode of the containing block
        .x = left orelse right orelse 0,
        // TODO: This depends on the writing mode of the containing block
        .y = top orelse bottom orelse 0,
    };
}

fn anonymousBlockBoxCosmeticLayout(box_tree: *BoxTree, block_box: BlockBox) void {
    const subtree = &box_tree.blocks.subtrees.items[block_box.subtree];
    subtree.border_colors.items[block_box.index] = .{};
    subtree.background1.items[block_box.index] = .{};
    subtree.background2.items[block_box.index] = .{};
    subtree.insets.items[block_box.index] = .{};
}

fn inlineBoxCosmeticLayout(context: Context, computer: *StyleComputer, ifc: *InlineFormattingContext, inline_box_index: InlineBoxIndex) void {
    const specified = .{
        .box_style = computer.getSpecifiedValue(.cosmetic, .box_style),
        .color = computer.getSpecifiedValue(.cosmetic, .color),
        .border_colors = computer.getSpecifiedValue(.cosmetic, .border_colors),
        .border_styles = computer.getSpecifiedValue(.cosmetic, .border_styles),
        .background1 = computer.getSpecifiedValue(.cosmetic, .background1),
        .background2 = computer.getSpecifiedValue(.cosmetic, .background2), // TODO: Inline boxes don't need background2
        .insets = computer.getSpecifiedValue(.cosmetic, .insets),
    };

    const computed_box_style = solve.boxStyle(specified.box_style, .NonRoot);

    var computed_insets: zss.properties.Insets = undefined;
    {
        const used_insets = &ifc.insets.items[inline_box_index];
        switch (computed_box_style.position) {
            .static => solveInsetsStatic(specified.insets, &computed_insets, used_insets),
            .relative => {
                const containing_block_size = context.containing_block_size.items[context.containing_block_size.items.len - 1];
                solveInsetsRelative(specified.insets, containing_block_size, &computed_insets, used_insets);
            },
            .sticky => panic("TODO: Inline insets with {s} positioning", .{@tagName(computed_box_style.position)}),
            .absolute, .fixed => unreachable,
            .initial, .inherit, .unset, .undeclared => unreachable,
        }
    }

    const current_color = solve.currentColor(specified.color.color);

    const border_colors = solve.borderColors(specified.border_colors, current_color);
    ifc.inline_start.items[inline_box_index].border_color_rgba = border_colors.left_rgba;
    ifc.inline_end.items[inline_box_index].border_color_rgba = border_colors.right_rgba;
    ifc.block_start.items[inline_box_index].border_color_rgba = border_colors.top_rgba;
    ifc.block_end.items[inline_box_index].border_color_rgba = border_colors.bottom_rgba;

    solve.borderStyles(specified.border_styles);

    const background1_ptr = &ifc.background1.items[inline_box_index];
    background1_ptr.* = solve.background1(specified.background1, current_color);

    computer.setComputedValue(.cosmetic, .box_style, computed_box_style);
    computer.setComputedValue(.cosmetic, .insets, computed_insets);
    // TODO: Pretending that specified values are computed values...
    computer.setComputedValue(.cosmetic, .color, specified.color);
    computer.setComputedValue(.cosmetic, .border_colors, specified.border_colors);
    computer.setComputedValue(.cosmetic, .border_styles, specified.border_styles);
    computer.setComputedValue(.cosmetic, .background1, specified.background1);
    computer.setComputedValue(.cosmetic, .background2, specified.background2);
}

fn rootInlineBoxCosmeticLayout(ifc: *InlineFormattingContext) void {
    ifc.inline_start.items[0].border_color_rgba = 0;
    ifc.inline_end.items[0].border_color_rgba = 0;
    ifc.block_start.items[0].border_color_rgba = 0;
    ifc.block_end.items[0].border_color_rgba = 0;

    ifc.background1.items[0] = .{};
    ifc.insets.items[0] = .{};
}
