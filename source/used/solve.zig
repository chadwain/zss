// This file is a part of zss.
// Copyright (C) 2020-2021 Chadwain Holness
//
// This library is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this library.  If not, see <https://www.gnu.org/licenses/>.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const assert = std.debug.assert;

const zss = @import("../../zss.zig");
const computed = zss.properties;
const values = zss.values;
const BoxTree = zss.box_tree.BoxTree;
usingnamespace zss.types;

const used = @import("properties.zig");
const StackingContext = @import("stacking_context.zig").StackingContext;
const BlockFormattingContext = @import("BlockFormattingContext.zig");

const Interval = struct {
    index: u16,
    begin: u16,
    end: u16,
};

const UsedSizeAndMargins = struct {
    size: ?CSSUnit,
    margin_start: CSSUnit,
    margin_end: CSSUnit,
};

const Context = struct {
    const Self = @This();

    stack: ArrayList(Interval),

    static_containing_block_inline_sizes: ArrayList(CSSUnit),
    static_containing_block_block_auto_sizes: ArrayList(CSSUnit),
    static_containing_block_block_size_margins: ArrayList(UsedSizeAndMargins),

    fn init(allocator: *Allocator, initial_containing_block: CSSSize) !Self {
        var stack = ArrayList(Interval).init(allocator);

        var static_containing_block_inline_sizes = ArrayList(CSSUnit).init(allocator);
        // TODO using physical property when we should be using a logical one
        try static_containing_block_inline_sizes.append(initial_containing_block.w);
        errdefer static_containing_block_inline_sizes.deinit();

        var static_containing_block_block_auto_sizes = ArrayList(CSSUnit).init(allocator);
        try static_containing_block_block_auto_sizes.append(0);
        errdefer static_containing_block_block_auto_sizes.deinit();

        var static_containing_block_block_size_margins = ArrayList(UsedSizeAndMargins).init(allocator);
        // TODO using physical property when we should be using a logical one
        try static_containing_block_block_size_margins.append(UsedSizeAndMargins{
            .size = initial_containing_block.h,
            .margin_start = undefined,
            .margin_end = undefined,
        });
        errdefer static_containing_block_block_size_margins.deinit();

        return Self{
            .stack = stack,
            .static_containing_block_inline_sizes = static_containing_block_inline_sizes,
            .static_containing_block_block_auto_sizes = static_containing_block_block_auto_sizes,
            .static_containing_block_block_size_margins = static_containing_block_block_size_margins,
        };
    }

    fn deinit(self: *Self) void {
        self.stack.deinit();
        self.static_containing_block_inline_sizes.deinit();
        self.static_containing_block_block_auto_sizes.deinit();
        self.static_containing_block_block_size_margins.deinit();
    }
};

pub fn generateUsedDataFromBoxTree(tree: *const BoxTree, allocator: *Allocator, initial_containing_block: CSSSize) !BlockFormattingContext {
    const out_preorder_array = try allocator.dupe(u16, tree.preorder_array[0..tree.preorder_array[0]]);
    errdefer allocator.free(out_preorder_array);

    var out_box_offsets = ArrayListUnmanaged(BoxOffsets){};
    errdefer out_box_offsets.deinit(allocator);
    try out_box_offsets.ensureCapacity(allocator, out_preorder_array.len);

    var out_borders = ArrayListUnmanaged(used.Borders){};
    errdefer out_borders.deinit(allocator);
    try out_borders.ensureCapacity(allocator, out_preorder_array.len);

    var out_border_colors = ArrayListUnmanaged(used.BorderColor){};
    errdefer out_border_colors.deinit(allocator);
    try out_border_colors.ensureCapacity(allocator, out_preorder_array.len);

    var out_background_color = ArrayListUnmanaged(used.BackgroundColor){};
    errdefer out_background_color.deinit(allocator);
    try out_background_color.ensureCapacity(allocator, out_preorder_array.len);

    var out_background_image = ArrayListUnmanaged(used.BackgroundImage){};
    errdefer out_background_image.deinit(allocator);
    try out_background_image.ensureCapacity(allocator, out_preorder_array.len);

    var out_visual_effect = ArrayListUnmanaged(used.VisualEffect){};
    errdefer out_visual_effect.deinit(allocator);
    try out_visual_effect.ensureCapacity(allocator, out_preorder_array.len);

    var context = try Context.init(allocator, initial_containing_block);
    defer context.deinit();

    {
        const box_offsets_ptr = try out_box_offsets.addOne(allocator);
        const borders_ptr = try out_borders.addOne(allocator);

        const inline_size = getInlineOffsets(tree, &context, 0, box_offsets_ptr, borders_ptr);
        const size_margins = getBlockOffsets(tree, &context, 0, box_offsets_ptr, borders_ptr);

        const num_descendants = tree.preorder_array[0];
        try context.stack.append(Interval{ .index = 0, .begin = 1, .end = num_descendants });
        try context.static_containing_block_inline_sizes.append(inline_size);
        try context.static_containing_block_block_auto_sizes.append(0);
        try context.static_containing_block_block_size_margins.append(size_margins);
    }

    while (context.stack.items.len > 0) {
        const interval = &context.stack.items[context.stack.items.len - 1];
        if (interval.begin == interval.end) {
            defer {
                _ = context.stack.pop();
                _ = context.static_containing_block_inline_sizes.pop();
                _ = context.static_containing_block_block_auto_sizes.pop();
                _ = context.static_containing_block_block_size_margins.pop();
            }

            const box_offsets_ptr = &out_box_offsets.items[interval.index];
            const borders_ptr = &out_borders.items[interval.index];

            const size_margins = context.static_containing_block_block_size_margins.items[context.static_containing_block_block_size_margins.items.len - 1];
            const auto_block_size = context.static_containing_block_block_auto_sizes.items[context.static_containing_block_block_auto_sizes.items.len - 1];
            const parent_auto_block_size = &context.static_containing_block_block_auto_sizes.items[context.static_containing_block_block_auto_sizes.items.len - 2];

            // TODO stop repeating code
            const used_block_size = size_margins.size orelse auto_block_size;
            box_offsets_ptr.border_top_left.y = parent_auto_block_size.* + size_margins.margin_start;
            box_offsets_ptr.content_top_left.y += box_offsets_ptr.border_top_left.y;
            box_offsets_ptr.content_bottom_right.y = box_offsets_ptr.content_top_left.y + used_block_size;
            box_offsets_ptr.border_bottom_right.y += box_offsets_ptr.content_bottom_right.y;
            parent_auto_block_size.* = box_offsets_ptr.border_bottom_right.y + size_margins.margin_end;

            continue;
        }

        const box_offsets_ptr = try out_box_offsets.addOne(allocator);
        const borders_ptr = try out_borders.addOne(allocator);

        const inline_size = getInlineOffsets(tree, &context, interval.begin, box_offsets_ptr, borders_ptr);
        const size_margins = getBlockOffsets(tree, &context, interval.begin, box_offsets_ptr, borders_ptr);

        const num_descendants = tree.preorder_array[interval.begin];
        defer interval.begin += num_descendants;
        if (num_descendants != 1) {
            try context.stack.append(Interval{ .index = interval.begin, .begin = interval.begin + 1, .end = interval.begin + num_descendants });
            try context.static_containing_block_inline_sizes.append(inline_size);
            try context.static_containing_block_block_auto_sizes.append(0);
            try context.static_containing_block_block_size_margins.append(size_margins);
        } else {
            // TODO stop repeating code
            const parent_auto_block_size = &context.static_containing_block_block_auto_sizes.items[context.static_containing_block_block_auto_sizes.items.len - 1];
            const used_block_size = size_margins.size orelse 0;
            box_offsets_ptr.border_top_left.y = parent_auto_block_size.* + size_margins.margin_start;
            box_offsets_ptr.content_top_left.y += box_offsets_ptr.border_top_left.y;
            box_offsets_ptr.content_bottom_right.y = box_offsets_ptr.content_top_left.y + used_block_size;
            box_offsets_ptr.border_bottom_right.y += box_offsets_ptr.content_bottom_right.y;
            parent_auto_block_size.* = box_offsets_ptr.border_bottom_right.y + size_margins.margin_end;
        }
    }

    out_border_colors.expandToCapacity();
    out_background_color.expandToCapacity();
    out_background_image.expandToCapacity();
    out_visual_effect.expandToCapacity();
    std.mem.set(used.BorderColor, out_border_colors.items, used.BorderColor{});
    std.mem.set(used.BackgroundColor, out_background_color.items, used.BackgroundColor{});
    std.mem.set(used.BackgroundImage, out_background_image.items, used.BackgroundImage{});
    std.mem.set(used.VisualEffect, out_visual_effect.items, used.VisualEffect{});
    return BlockFormattingContext{
        .preorder_array = out_preorder_array,
        .box_offsets = out_box_offsets.toOwnedSlice(allocator),
        .borders = out_borders.toOwnedSlice(allocator),
        .border_colors = out_border_colors.toOwnedSlice(allocator),
        .background_color = out_background_color.toOwnedSlice(allocator),
        .background_image = out_background_image.toOwnedSlice(allocator),
        .visual_effect = out_visual_effect.toOwnedSlice(allocator),
    };
}

fn length(val: values.Length) CSSUnit {
    return switch (val) {
        .px => |px| @floatToInt(CSSUnit, @round(px)),
    };
}

fn percentage(val: values.Percentage, unit: CSSUnit) CSSUnit {
    return switch (val) {
        .percentage => |p| @floatToInt(CSSUnit, @round(@intToFloat(f32, unit) * p)),
    };
}

fn lineWidth(val: computed.LogicalSize.BorderValue) CSSUnit {
    return switch (val) {
        .px => |px| length(.{ .px = px }),
        .thin => 1,
        .medium => 3,
        .thick => 5,
        .initial, .inherit, .unset => unreachable,
    };
}

fn getInlineOffsets(tree: *const BoxTree, context: *const Context, key: u16, box_offsets: *BoxOffsets, borders: *used.Borders) CSSUnit {
    const solved = solveInlineSizes(
        &tree.inline_size[key],
        context.static_containing_block_inline_sizes.items[context.static_containing_block_inline_sizes.items.len - 1],
    );

    // TODO using physical property when we should be using a logical one
    box_offsets.border_top_left.x = solved.margin_start;
    box_offsets.content_top_left.x = box_offsets.border_top_left.x + solved.border_start + solved.padding_start;
    box_offsets.content_bottom_right.x = box_offsets.content_top_left.x + solved.size;
    box_offsets.border_bottom_right.x = box_offsets.content_bottom_right.x + solved.padding_end + solved.border_end;

    // TODO using physical property when we should be using a logical one
    borders.left = solved.border_start;
    borders.right = solved.border_end;

    return solved.size;
}

/// This implements CSS2§10.3.3
fn solveInlineSizes(
    sizes: *const computed.LogicalSize,
    containing_block_size: CSSUnit,
) struct {
    size: CSSUnit,
    border_start: CSSUnit,
    border_end: CSSUnit,
    padding_start: CSSUnit,
    padding_end: CSSUnit,
    margin_start: CSSUnit,
    margin_end: CSSUnit,
} {
    const border_start = lineWidth(sizes.border_start_width);
    const border_end = lineWidth(sizes.border_end_width);
    const padding_start = switch (sizes.padding_start) {
        .px => |px| length(.{ .px = px }),
        .percentage => |p| percentage(.{ .percentage = p }, containing_block_size),
        .initial, .inherit, .unset => unreachable,
    };
    const padding_end = switch (sizes.padding_end) {
        .px => |px| length(.{ .px = px }),
        .percentage => |p| percentage(.{ .percentage = p }, containing_block_size),
        .initial, .inherit, .unset => unreachable,
    };
    const cm_space = containing_block_size - (border_start + border_end + padding_start + padding_end);

    var autos: u3 = 0;
    const size_bit = 4;
    const margin_start_bit = 2;
    const margin_end_bit = 1;

    var size = switch (sizes.size) {
        .px => |px| length(.{ .px = px }),
        .percentage => |p| percentage(.{ .percentage = p }, containing_block_size),
        .auto => blk: {
            autos |= size_bit;
            break :blk 0;
        },
        .initial, .inherit, .unset => unreachable,
    };
    var margin_start = switch (sizes.margin_start) {
        .px => |px| length(.{ .px = px }),
        .percentage => |p| percentage(.{ .percentage = p }, containing_block_size),
        .auto => blk: {
            autos |= margin_start_bit;
            break :blk 0;
        },
        .initial, .inherit, .unset => unreachable,
    };
    var margin_end = switch (sizes.margin_end) {
        .px => |px| length(.{ .px = px }),
        .percentage => |p| percentage(.{ .percentage = p }, containing_block_size),
        .auto => blk: {
            autos |= margin_end_bit;
            break :blk 0;
        },
        .initial, .inherit, .unset => unreachable,
    };

    if (autos == 0) {
        // TODO(§10.3.3): which margin gets set is affected by the 'direction' property
        margin_end = cm_space - size - margin_start;
    } else if (autos & size_bit == 0) {
        const start = autos & margin_start_bit;
        const end = autos & margin_end_bit;
        const shr_amount = @boolToInt(start | end == margin_start_bit | margin_end_bit);
        const leftover_margin = std.math.max(0, cm_space - (size + margin_start + margin_end));
        // NOTE: which margin gets the extra 1 unit shall be affected by the 'direction' property
        if (start == 0) margin_start = leftover_margin >> shr_amount;
        if (end == 0) margin_end = (leftover_margin >> shr_amount) + @mod(leftover_margin, 2);
    } else {
        size = cm_space - margin_start - margin_end;
    }

    // TODO use the min-size and max-size properties

    return .{
        .size = size,
        .border_start = border_start,
        .border_end = border_end,
        .padding_start = padding_start,
        .padding_end = padding_end,
        .margin_start = margin_start,
        .margin_end = margin_end,
    };
}

fn getBlockOffsets(tree: *const BoxTree, context: *const Context, key: u16, box_offsets: *BoxOffsets, borders: *used.Borders) UsedSizeAndMargins {
    const solved = solveBlockSizes(
        &tree.block_size[key],
        context.static_containing_block_inline_sizes.items[context.static_containing_block_inline_sizes.items.len - 1],
        context.static_containing_block_block_size_margins.items[context.static_containing_block_block_size_margins.items.len - 1].size,
    );

    // TODO using physical property when we should be using a logical one
    box_offsets.content_top_left.y = solved.border_start + solved.padding_start;
    box_offsets.border_bottom_right.y = solved.padding_end + solved.border_end;

    // TODO using physical property when we should be using a logical one
    borders.top = solved.border_start;
    borders.bottom = solved.border_end;

    // TODO using physical property when we should be using a logical one
    return UsedSizeAndMargins{
        .size = solved.size,
        .margin_start = solved.margin_start,
        .margin_end = solved.margin_end,
    };
}

/// This implements CSS2§10.6.3
fn solveBlockSizes(
    sizes: *const computed.LogicalSize,
    containing_block_inline_size: CSSUnit,
    containing_block_block_size: ?CSSUnit,
) struct {
    size: ?CSSUnit,
    border_start: CSSUnit,
    border_end: CSSUnit,
    padding_start: CSSUnit,
    padding_end: CSSUnit,
    margin_start: CSSUnit,
    margin_end: CSSUnit,
} {
    const size = switch (sizes.size) {
        .px => |px| length(.{ .px = px }),
        .percentage => |p| if (containing_block_block_size) |s|
            percentage(.{ .percentage = p }, s)
        else
            null,
        .auto => null,
        .initial, .inherit, .unset => unreachable,
    };
    const border_start = lineWidth(sizes.border_start_width);
    const border_end = lineWidth(sizes.border_end_width);
    const padding_start = switch (sizes.padding_start) {
        .px => |px| length(.{ .px = px }),
        .percentage => |p| percentage(.{ .percentage = p }, containing_block_inline_size),
        .initial, .inherit, .unset => unreachable,
    };
    const padding_end = switch (sizes.padding_end) {
        .px => |px| length(.{ .px = px }),
        .percentage => |p| percentage(.{ .percentage = p }, containing_block_inline_size),
        .initial, .inherit, .unset => unreachable,
    };
    const margin_start = switch (sizes.margin_start) {
        .px => |px| length(.{ .px = px }),
        .percentage => |p| percentage(.{ .percentage = p }, containing_block_inline_size),
        .auto => 0,
        .initial, .inherit, .unset => unreachable,
    };
    const margin_end = switch (sizes.margin_end) {
        .px => |px| length(.{ .px = px }),
        .percentage => |p| percentage(.{ .percentage = p }, containing_block_inline_size),
        .auto => 0,
        .initial, .inherit, .unset => unreachable,
    };

    // TODO use the min-size and max-size properties

    return .{
        .size = size,
        .border_start = border_start,
        .border_end = border_end,
        .padding_start = padding_start,
        .padding_end = padding_end,
        .margin_start = margin_start,
        .margin_end = margin_end,
    };
}

test "used data" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.testing.expect(!gpa.deinit());
    const al = &gpa.allocator;

    var preorder_array = [_]u16{ 4, 2, 1, 1 };
    const inline_size_1 = computed.LogicalSize{
        .size = .{ .percentage = 0.7 },
        .margin_start = .{ .px = 20 },
        .margin_end = .{ .px = 20 },
        .border_start_width = .{ .px = 5 },
        .border_end_width = .{ .px = 5 },
    };
    const inline_size_2 = computed.LogicalSize{
        .margin_start = .{ .px = 20 },
        .border_start_width = .{ .px = 5 },
        .border_end_width = .{ .px = 5 },
    };
    const block_size_1 = computed.LogicalSize{
        .size = .{ .percentage = 0.9 },
        .border_start_width = .{ .px = 5 },
        .border_end_width = .{ .px = 5 },
    };
    const block_size_2 = computed.LogicalSize{
        .border_start_width = .{ .px = 5 },
        .border_end_width = .{ .px = 5 },
    };

    var inline_size = [_]computed.LogicalSize{ inline_size_1, inline_size_2, inline_size_1, inline_size_1 };
    var block_size = [_]computed.LogicalSize{ block_size_1, block_size_2, block_size_1, block_size_1 };
    var result = try generateUsedDataFromBoxTree(
        &BoxTree{
            .preorder_array = &preorder_array,
            .inline_size = &inline_size,
            .block_size = &block_size,
        },
        al,
        CSSSize{ .w = 400, .h = 400 },
    );
    defer result.deinit(al);

    for (result.box_offsets) |box_offset| {
        std.debug.print("{}\n", .{box_offset});
    }
}
