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

const IdAndSkipLength = struct {
    id: u16,
    skip_length: u16,
};

const UsedSizeAndMargins = struct {
    size: ?CSSUnit,
    min_size: CSSUnit,
    max_size: CSSUnit,
    margin_start: CSSUnit,
    margin_end: CSSUnit,
};

const InFlowInsets = struct {
    const BlockInset = union(enum) {
        length: CSSUnit,
        percentage: f32,
    };
    inline_axis: CSSUnit,
    block_axis: BlockInset,
};

const InFlowPositioningData = struct {
    insets: InFlowInsets,
    box_id: u16,
};

const Context = struct {
    const Self = @This();

    stack: ArrayList(Interval),

    result_ids_and_skip_lengths: ArrayList(IdAndSkipLength),
    static_containing_block_inline_sizes: ArrayList(CSSUnit),
    static_containing_block_block_auto_sizes: ArrayList(CSSUnit),
    static_containing_block_block_size_margins: ArrayList(UsedSizeAndMargins),
    in_flow_positioning_data: ArrayList(InFlowPositioningData),
    in_flow_positioning_data_count: ArrayList(u16),

    fn init(allocator: *Allocator, initial_containing_block: CSSSize) !Self {
        var stack = ArrayList(Interval).init(allocator);
        var in_flow_positioning_data = ArrayList(InFlowPositioningData).init(allocator);

        var in_flow_positioning_data_count = ArrayList(u16).init(allocator);
        try in_flow_positioning_data_count.append(0);
        errdefer in_flow_positioning_data_count.deinit();

        var result_ids_and_skip_lengths = ArrayList(IdAndSkipLength).init(allocator);
        try result_ids_and_skip_lengths.append(IdAndSkipLength{
            .id = undefined,
            .skip_length = 0,
        });
        errdefer result_ids_and_skip_lengths.deinit();

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
            .min_size = undefined,
            .max_size = undefined,
            .margin_start = undefined,
            .margin_end = undefined,
        });
        errdefer static_containing_block_block_size_margins.deinit();

        return Self{
            .stack = stack,
            .result_ids_and_skip_lengths = result_ids_and_skip_lengths,
            .static_containing_block_inline_sizes = static_containing_block_inline_sizes,
            .static_containing_block_block_auto_sizes = static_containing_block_block_auto_sizes,
            .static_containing_block_block_size_margins = static_containing_block_block_size_margins,
            .in_flow_positioning_data = in_flow_positioning_data,
            .in_flow_positioning_data_count = in_flow_positioning_data_count,
        };
    }

    fn deinit(self: *Self) void {
        self.stack.deinit();
        self.result_ids_and_skip_lengths.deinit();
        self.static_containing_block_inline_sizes.deinit();
        self.static_containing_block_block_auto_sizes.deinit();
        self.static_containing_block_block_size_margins.deinit();
        self.in_flow_positioning_data.deinit();
        self.in_flow_positioning_data_count.deinit();
    }
};

const IntermediateResult = struct {
    const Self = @This();

    preorder_array: ArrayListUnmanaged(u16) = .{},
    box_offsets: ArrayListUnmanaged(BoxOffsets) = .{},
    borders: ArrayListUnmanaged(used.Borders) = .{},
    border_colors: ArrayListUnmanaged(used.BorderColor) = .{},
    background_color: ArrayListUnmanaged(used.BackgroundColor) = .{},
    background_image: ArrayListUnmanaged(used.BackgroundImage) = .{},
    visual_effect: ArrayListUnmanaged(used.VisualEffect) = .{},

    fn deinit(self: *Self, allocator: *Allocator) void {
        self.preorder_array.deinit(allocator);
        self.box_offsets.deinit(allocator);
        self.borders.deinit(allocator);
        self.border_colors.deinit(allocator);
        self.background_color.deinit(allocator);
        self.background_image.deinit(allocator);
        self.visual_effect.deinit(allocator);
    }

    fn ensureCapacity(self: *Self, allocator: *Allocator, capacity: usize) !void {
        try self.preorder_array.ensureCapacity(allocator, capacity);
        try self.box_offsets.ensureCapacity(allocator, capacity);
        try self.borders.ensureCapacity(allocator, capacity);
        try self.border_colors.ensureCapacity(allocator, capacity);
        try self.background_color.ensureCapacity(allocator, capacity);
        try self.background_image.ensureCapacity(allocator, capacity);
        try self.visual_effect.ensureCapacity(allocator, capacity);
    }
};

pub fn generateUsedDataFromBoxTree(tree: *const BoxTree, allocator: *Allocator, initial_containing_block: CSSSize, root_id: u16) !BlockFormattingContext {
    const root_skip_length = tree.preorder_array[root_id];

    var result = IntermediateResult{};
    errdefer result.deinit(allocator);
    try result.ensureCapacity(allocator, root_skip_length);

    var context = try Context.init(allocator, initial_containing_block);
    defer context.deinit();

    {
        switch (tree.display[root_id]) {
            .inner_outer => {},
            .none => @panic("TODO display: none on root element"),
            .initial, .inherit, .unset => unreachable,
        }
        const preorder_array_ptr = try result.preorder_array.addOne(allocator);
        const box_offsets_ptr = try result.box_offsets.addOne(allocator);
        const borders_ptr = try result.borders.addOne(allocator);
        const inline_size = getInlineOffsets(tree, &context, root_id, box_offsets_ptr, borders_ptr);
        const size_margins = getBlockOffsets(tree, &context, root_id, box_offsets_ptr, borders_ptr);

        if (root_skip_length != 1) {
            try context.stack.append(Interval{ .index = root_id, .begin = root_id + 1, .end = root_id + root_skip_length });
            try context.static_containing_block_inline_sizes.append(inline_size);
            // TODO don't add elements to this stack unconditionally
            try context.static_containing_block_block_auto_sizes.append(0);
            // TODO don't add elements to this stack unconditionally
            try context.static_containing_block_block_size_margins.append(size_margins);
            try context.result_ids_and_skip_lengths.append(IdAndSkipLength{
                .id = 0,
                .skip_length = 1,
            });
            // TODO don't add elements to this stack unconditionally
            try context.in_flow_positioning_data_count.append(0);
        } else {
            preorder_array_ptr.* = 1;
            const parent_auto_block_size = &context.static_containing_block_block_auto_sizes.items[context.static_containing_block_block_auto_sizes.items.len - 1];
            _ = blockContainerFinalizeBlockSizes(box_offsets_ptr, size_margins, 0, parent_auto_block_size);
        }
    }

    while (context.stack.items.len > 0) {
        const interval = &context.stack.items[context.stack.items.len - 1];
        if (interval.begin == interval.end) {
            const id_skip_length = context.result_ids_and_skip_lengths.items[context.result_ids_and_skip_lengths.items.len - 1];
            const result_id = id_skip_length.id;
            const result_skip_length = id_skip_length.skip_length;
            result.preorder_array.items[result_id] = result_skip_length;
            context.result_ids_and_skip_lengths.items[context.result_ids_and_skip_lengths.items.len - 2].skip_length += result_skip_length;

            const box_offsets_ptr = &result.box_offsets.items[result_id];
            const size_margins = context.static_containing_block_block_size_margins.items[context.static_containing_block_block_size_margins.items.len - 1];
            const auto_block_size = context.static_containing_block_block_auto_sizes.items[context.static_containing_block_block_auto_sizes.items.len - 1];
            const parent_auto_block_size = &context.static_containing_block_block_auto_sizes.items[context.static_containing_block_block_auto_sizes.items.len - 2];
            const used_block_size = blockContainerFinalizeBlockSizes(box_offsets_ptr, size_margins, auto_block_size, parent_auto_block_size);

            {
                applyInFlowPositioningToChildren(&context, result.box_offsets.items, used_block_size);
                const count = context.in_flow_positioning_data_count.pop();
                context.in_flow_positioning_data.shrinkRetainingCapacity(context.in_flow_positioning_data.items.len - count);
            }

            _ = context.result_ids_and_skip_lengths.pop();
            _ = context.static_containing_block_inline_sizes.pop();
            _ = context.static_containing_block_block_auto_sizes.pop();
            _ = context.static_containing_block_block_size_margins.pop();
            _ = context.stack.pop();
            continue;
        }

        const original_id = interval.begin;
        const skip_length = tree.preorder_array[original_id];
        defer interval.begin += skip_length;
        switch (tree.display[original_id]) {
            .inner_outer => {},
            .none => continue,
            .initial, .inherit, .unset => unreachable,
        }

        const result_id = try std.math.cast(u16, result.preorder_array.items.len);

        const position_inset = &tree.position_inset[original_id];
        switch (position_inset.position) {
            .static => {},
            .relative => {
                const insets = resolveRelativePositionInset(&context, position_inset);
                try context.in_flow_positioning_data.append(InFlowPositioningData{
                    .insets = insets,
                    .box_id = result_id,
                });
                context.in_flow_positioning_data_count.items[context.in_flow_positioning_data_count.items.len - 1] += 1;
            },
            .sticky => @panic("TODO: sticky positioning"),
            .absolute => @panic("TODO: absolute positioning"),
            .fixed => @panic("TODO: fixed positioning"),
            .initial, .inherit, .unset => unreachable,
        }

        const preorder_array_ptr = try result.preorder_array.addOne(allocator);
        const box_offsets_ptr = try result.box_offsets.addOne(allocator);
        const borders_ptr = try result.borders.addOne(allocator);
        const inline_size = getInlineOffsets(tree, &context, original_id, box_offsets_ptr, borders_ptr);
        const size_margins = getBlockOffsets(tree, &context, original_id, box_offsets_ptr, borders_ptr);

        if (skip_length != 1) {
            try context.stack.append(Interval{ .index = original_id, .begin = original_id + 1, .end = original_id + skip_length });
            try context.static_containing_block_inline_sizes.append(inline_size);
            // TODO don't add elements to this stack unconditionally
            try context.static_containing_block_block_auto_sizes.append(0);
            // TODO don't add elements to this stack unconditionally
            try context.static_containing_block_block_size_margins.append(size_margins);
            try context.result_ids_and_skip_lengths.append(IdAndSkipLength{
                .id = result_id,
                .skip_length = 1,
            });
            // TODO don't add elements to this stack unconditionally
            try context.in_flow_positioning_data_count.append(0);
        } else {
            preorder_array_ptr.* = 1;
            context.result_ids_and_skip_lengths.items[context.result_ids_and_skip_lengths.items.len - 1].skip_length += 1;
            const parent_auto_block_size = &context.static_containing_block_block_auto_sizes.items[context.static_containing_block_block_auto_sizes.items.len - 1];
            _ = blockContainerFinalizeBlockSizes(box_offsets_ptr, size_margins, 0, parent_auto_block_size);
        }
    }

    result.border_colors.expandToCapacity();
    result.background_color.expandToCapacity();
    result.background_image.expandToCapacity();
    result.visual_effect.expandToCapacity();
    std.mem.set(used.BorderColor, result.border_colors.items, used.BorderColor{});
    std.mem.set(used.BackgroundColor, result.background_color.items, used.BackgroundColor{});
    std.mem.set(used.BackgroundImage, result.background_image.items, used.BackgroundImage{});
    std.mem.set(used.VisualEffect, result.visual_effect.items, used.VisualEffect{});
    return BlockFormattingContext{
        .preorder_array = result.preorder_array.toOwnedSlice(allocator),
        .box_offsets = result.box_offsets.toOwnedSlice(allocator),
        .borders = result.borders.toOwnedSlice(allocator),
        .border_colors = result.border_colors.toOwnedSlice(allocator),
        .background_color = result.background_color.toOwnedSlice(allocator),
        .background_image = result.background_image.toOwnedSlice(allocator),
        .visual_effect = result.visual_effect.toOwnedSlice(allocator),
    };
}

fn blockContainerFinalizeBlockSizes(box_offsets: *BoxOffsets, size_margins: UsedSizeAndMargins, auto_block_size: CSSUnit, parent_auto_block_size: *CSSUnit) CSSUnit {
    const used_block_size = std.math.clamp(size_margins.size orelse auto_block_size, size_margins.min_size, size_margins.max_size);
    box_offsets.border_top_left.y = parent_auto_block_size.* + size_margins.margin_start;
    box_offsets.content_top_left.y += box_offsets.border_top_left.y;
    box_offsets.content_bottom_right.y = box_offsets.content_top_left.y + used_block_size;
    box_offsets.border_bottom_right.y += box_offsets.content_bottom_right.y;
    parent_auto_block_size.* = box_offsets.border_bottom_right.y + size_margins.margin_end;
    return used_block_size;
}

fn applyInFlowPositioningToChildren(context: *const Context, box_offsets: []BoxOffsets, containing_block_block_size: CSSUnit) void {
    const count = context.in_flow_positioning_data_count.items[context.in_flow_positioning_data_count.items.len - 1];
    var i: u16 = 0;
    while (i < count) : (i += 1) {
        const positioning_data = context.in_flow_positioning_data.items[context.in_flow_positioning_data.items.len - 1 - i];
        const positioning_offset = zss.types.Offset{
            // TODO using physical property when we should be using a logical one
            .x = positioning_data.insets.inline_axis,
            // TODO using physical property when we should be using a logical one
            .y = switch (positioning_data.insets.block_axis) {
                .length => |l| l,
                .percentage => |p| percentage(.{ .percentage = p }, containing_block_block_size),
            },
        };
        const box_offset = &box_offsets[positioning_data.box_id];
        inline for (std.meta.fields(BoxOffsets)) |field| {
            const offset = &@field(box_offset, field.name);
            offset.* = offset.add(positioning_offset);
        }
    }
}

fn resolveRelativePositionInset(context: *Context, position_inset: *computed.PositionInset) InFlowInsets {
    const containing_block_inline_size = context.static_containing_block_inline_sizes.items[context.static_containing_block_inline_sizes.items.len - 1];
    const containing_block_block_size = context.static_containing_block_block_size_margins.items[context.static_containing_block_block_size_margins.items.len - 1].size;
    const inline_start = switch (position_inset.inline_start) {
        .px => |px| length(.{ .px = px }),
        .percentage => |p| percentage(.{ .percentage = p }, containing_block_inline_size),
        .auto => null,
        .initial, .inherit, .unset => unreachable,
    };
    const inline_end = switch (position_inset.inline_end) {
        .px => |px| -length(.{ .px = px }),
        .percentage => |p| -percentage(.{ .percentage = p }, containing_block_inline_size),
        .auto => null,
        .initial, .inherit, .unset => unreachable,
    };
    const block_start: ?InFlowInsets.BlockInset = switch (position_inset.block_start) {
        .px => |px| InFlowInsets.BlockInset{ .length = length(.{ .px = px }) },
        .percentage => |p| if (containing_block_block_size) |s|
            InFlowInsets.BlockInset{ .length = percentage(.{ .percentage = p }, s) }
        else
            InFlowInsets.BlockInset{ .percentage = p },
        .auto => null,
        .initial, .inherit, .unset => unreachable,
    };
    const block_end: ?InFlowInsets.BlockInset = switch (position_inset.block_end) {
        .px => |px| InFlowInsets.BlockInset{ .length = -length(.{ .px = px }) },
        .percentage => |p| if (containing_block_block_size) |s|
            InFlowInsets.BlockInset{ .length = -percentage(.{ .percentage = p }, s) }
        else
            InFlowInsets.BlockInset{ .percentage = -p },
        .auto => null,
        .initial, .inherit, .unset => unreachable,
    };
    return InFlowInsets{
        .inline_axis = inline_start orelse inline_end orelse 0,
        .block_axis = block_start orelse block_end orelse InFlowInsets.BlockInset{ .length = 0 },
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

fn getInlineOffsets(tree: *const BoxTree, context: *const Context, id: u16, box_offsets: *BoxOffsets, borders: *used.Borders) CSSUnit {
    const solved = solveInlineSizes(
        &tree.inline_size[id],
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

    const min_size = switch (sizes.min_size) {
        .px => |px| length(.{ .px = px }),
        .percentage => |p| percentage(.{ .percentage = p }, std.math.max(0, containing_block_size)),
        .initial, .inherit, .unset => unreachable,
    };
    const max_size = switch (sizes.max_size) {
        .px => |px| length(.{ .px = px }),
        .percentage => |p| percentage(.{ .percentage = p }, std.math.max(0, containing_block_size)),
        .none => std.math.maxInt(CSSUnit),
        .initial, .inherit, .unset => unreachable,
    };

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
        size = std.math.clamp(size, min_size, max_size);
        margin_end = cm_space - size - margin_start;
    } else if (autos & size_bit == 0) {
        const start = autos & margin_start_bit;
        const end = autos & margin_end_bit;
        const shr_amount = @boolToInt(start | end == margin_start_bit | margin_end_bit);
        size = std.math.clamp(size, min_size, max_size);
        const leftover_margin = std.math.max(0, cm_space - (size + margin_start + margin_end));
        // NOTE: which margin gets the extra 1 unit shall be affected by the 'direction' property
        if (start == 0) margin_start = leftover_margin >> shr_amount;
        if (end == 0) margin_end = (leftover_margin >> shr_amount) + @mod(leftover_margin, 2);
    } else {
        size = std.math.clamp(cm_space - margin_start - margin_end, min_size, max_size);
    }

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

fn getBlockOffsets(tree: *const BoxTree, context: *const Context, id: u16, box_offsets: *BoxOffsets, borders: *used.Borders) UsedSizeAndMargins {
    const solved = solveBlockSizes(
        &tree.block_size[id],
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
        .min_size = solved.min_size,
        .max_size = solved.max_size,
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
    min_size: CSSUnit,
    max_size: CSSUnit,
    border_start: CSSUnit,
    border_end: CSSUnit,
    padding_start: CSSUnit,
    padding_end: CSSUnit,
    margin_start: CSSUnit,
    margin_end: CSSUnit,
} {
    var size = switch (sizes.size) {
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

    const min_size = switch (sizes.min_size) {
        .px => |px| length(.{ .px = px }),
        .percentage => |p| if (containing_block_block_size) |s|
            percentage(.{ .percentage = p }, s)
        else
            0,
        .initial, .inherit, .unset => unreachable,
    };
    const max_size = switch (sizes.max_size) {
        .px => |px| length(.{ .px = px }),
        .percentage => |p| if (containing_block_block_size) |s|
            percentage(.{ .percentage = p }, s)
        else
            std.math.maxInt(CSSUnit),
        .none => std.math.maxInt(CSSUnit),
        .initial, .inherit, .unset => unreachable,
    };

    return .{
        .size = size,
        .min_size = min_size,
        .max_size = max_size,
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
    var display = [_]computed.Display{
        .{ .inner_outer = .{ .inner = .flow_root, .outer = .block } },
        .{ .inner_outer = .{ .inner = .flow, .outer = .block } },
        .{ .inner_outer = .{ .inner = .flow, .outer = .block } },
        .{ .inner_outer = .{ .inner = .flow, .outer = .block } },
    };
    var result = try generateUsedDataFromBoxTree(
        &BoxTree{
            .preorder_array = &preorder_array,
            .inline_size = &inline_size,
            .block_size = &block_size,
            .display = &display,
        },
        al,
        CSSSize{ .w = 400, .h = 400 },
        0,
    );
    defer result.deinit(al);

    for (result.box_offsets) |box_offset| {
        std.debug.print("{}\n", .{box_offset});
    }
}
