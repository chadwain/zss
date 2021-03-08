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
const assert = std.debug.assert;

const zss = @import("../../zss.zig");
const computed = zss.properties;
const values = zss.values;
const BoxTree = zss.box_tree.BoxTree;
usingnamespace zss.types;

const used = @import("properties.zig");
const OffsetInfo = @import("offset_tree.zig").OffsetInfo;

const IdPart = u16;
const Id = []const BoxIdPart;
fn TreeMap(comptime V: type) type {
    const cmpFn = struct {
        fn f(a: IdPart, b: IdPart) std.math.Order {
            return std.math.order(a, b);
        }
    }.f;
    return @import("prefix-tree-map").PrefixTreeMapUnmanaged(IdPart, V, cmpFn);
}

const Result = struct {
    block_tree: TreeMap(bool) = .{},
    offset_tree: TreeMap(OffsetInfo) = .{},
    borders: TreeMap(used.Borders) = .{},

    fn deinit(self: *@This(), allocator: *Allocator) void {
        self.block_tree.deinitRecursive(allocator);
        self.offset_tree.deinitRecursive(allocator);
        self.borders.deinitRecursive(allocator);
    }
};

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
    node_indeces: ArrayList(usize),

    static_containing_block_inline_sizes: ArrayList(CSSUnit),
    static_containing_block_block_auto_sizes: ArrayList(CSSUnit),
    static_containing_block_block_size_margins: ArrayList(UsedSizeAndMargins),

    fn init(allocator: *Allocator, initial_containing_block: CSSSize) !Self {
        var stack = ArrayList(Interval).init(allocator);
        var node_indeces = ArrayList(usize).init(allocator);

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
            .node_indeces = node_indeces,
            .static_containing_block_inline_sizes = static_containing_block_inline_sizes,
            .static_containing_block_block_auto_sizes = static_containing_block_block_auto_sizes,
            .static_containing_block_block_size_margins = static_containing_block_block_size_margins,
        };
    }

    fn deinit(self: *Self) void {
        self.stack.deinit();
        self.node_indeces.deinit();
        self.static_containing_block_inline_sizes.deinit();
        self.static_containing_block_block_auto_sizes.deinit();
        self.static_containing_block_block_size_margins.deinit();
    }
};

fn generateUsedDataFromBoxTree(tree: *const BoxTree, allocator: *Allocator, initial_containing_block: CSSSize) !Result {
    var result = Result{};
    errdefer result.deinit(allocator);

    const TreeStackItem = struct {
        block: *TreeMap(bool),
        offset: *TreeMap(OffsetInfo),
        borders: *TreeMap(used.Borders),

        fn treesNewEdge(self: @This(), key: u16, al: *Allocator) !usize {
            const index = try self.block.newEdge(al, key, true, null);
            assert(index == try self.offset.newEdge(al, key, undefined, null));
            assert(index == try self.borders.newEdge(al, key, undefined, null));
            return index;
        }

        fn stackAppend(stack: *ArrayList(@This()), index: usize, al: *Allocator) !void {
            const nodes = &stack.items[stack.items.len - 1];

            const new_block = try al.create(TreeMap(bool));
            errdefer al.destroy(new_block);
            new_block.* = .{};
            nodes.block.child_nodes.items[index].s = new_block;

            const new_offset = try al.create(TreeMap(OffsetInfo));
            errdefer al.destroy(new_offset);
            new_offset.* = .{};
            nodes.offset.child_nodes.items[index].s = new_offset;

            const new_borders = try al.create(TreeMap(used.Borders));
            errdefer al.destroy(new_borders);
            new_borders.* = .{};
            nodes.borders.child_nodes.items[index].s = new_borders;

            try stack.append(.{
                .block = new_block,
                .offset = new_offset,
                .borders = new_borders,
            });
        }
    };

    var tree_stack = ArrayList(TreeStackItem).init(allocator);
    defer tree_stack.deinit();
    try tree_stack.append(.{
        .block = &result.block_tree,
        .offset = &result.offset_tree,
        .borders = &result.borders,
    });

    var context = try Context.init(allocator, initial_containing_block);
    defer context.deinit();

    {
        const nodes = tree_stack.items[tree_stack.items.len - 1];
        const index = try nodes.treesNewEdge(0, allocator);
        const offset_info_ptr = nodes.offset.valuePtr(index);
        const borders_ptr = nodes.borders.valuePtr(index);
        const inline_size = getInlineOffsets(tree, &context, 0, offset_info_ptr, borders_ptr);
        const size_margins = getBlockOffsets(tree, &context, 0, offset_info_ptr, borders_ptr);
        std.debug.print("horizontal {}\n", .{0});

        const distance = tree.preorder_array[0];
        try context.stack.append(Interval{ .index = 0, .begin = 1, .end = distance });
        try context.node_indeces.append(index);
        try context.static_containing_block_inline_sizes.append(inline_size);
        try context.static_containing_block_block_auto_sizes.append(0);
        try context.static_containing_block_block_size_margins.append(size_margins);
        try TreeStackItem.stackAppend(&tree_stack, index, allocator);
    }

    while (context.stack.items.len > 0) {
        const interval = &context.stack.items[context.stack.items.len - 1];
        if (interval.begin == interval.end) {
            defer {
                _ = context.stack.pop();
                _ = context.node_indeces.pop();
                _ = context.static_containing_block_inline_sizes.pop();
                _ = context.static_containing_block_block_auto_sizes.pop();
                _ = context.static_containing_block_block_size_margins.pop();
                _ = tree_stack.pop();
            }

            const nodes = tree_stack.items[tree_stack.items.len - 2];
            const node_index = context.node_indeces.items[context.node_indeces.items.len - 1];
            const offset_info_ptr = nodes.offset.valuePtr(node_index);
            const borders_ptr = nodes.borders.valuePtr(node_index);

            const size_margins = context.static_containing_block_block_size_margins.items[context.static_containing_block_block_size_margins.items.len - 1];
            const auto_block_size = context.static_containing_block_block_auto_sizes.items[context.static_containing_block_block_auto_sizes.items.len - 1];
            const parent_auto_block_size = &context.static_containing_block_block_auto_sizes.items[context.static_containing_block_block_auto_sizes.items.len - 2];

            const used_block_size = size_margins.size orelse auto_block_size;
            offset_info_ptr.border_top_left.y = parent_auto_block_size.* + size_margins.margin_start;
            offset_info_ptr.content_top_left.y += offset_info_ptr.border_top_left.y;
            offset_info_ptr.content_bottom_right.y = offset_info_ptr.content_top_left.y + used_block_size;
            offset_info_ptr.border_bottom_right.y += offset_info_ptr.content_bottom_right.y;
            parent_auto_block_size.* = offset_info_ptr.border_bottom_right.y + size_margins.margin_end;

            std.debug.print("vertical {}\n", .{interval.index});
            continue;
        }

        const nodes = tree_stack.items[tree_stack.items.len - 1];
        const index = try nodes.treesNewEdge(interval.begin, allocator);
        const offset_info_ptr = nodes.offset.valuePtr(index);
        const borders_ptr = nodes.borders.valuePtr(index);
        const inline_size = getInlineOffsets(tree, &context, interval.begin, offset_info_ptr, borders_ptr);
        const size_margins = getBlockOffsets(tree, &context, interval.begin, offset_info_ptr, borders_ptr);
        std.debug.print("horizontal {}\n", .{interval.begin});

        const distance = tree.preorder_array[interval.begin];
        const new_begin = interval.begin + distance;
        const interval_copy = interval.*;
        interval.begin = new_begin;
        if (distance != 1) {
            try context.stack.append(Interval{ .index = interval_copy.begin, .begin = interval_copy.begin + 1, .end = new_begin });
            try context.node_indeces.append(index);
            try context.static_containing_block_inline_sizes.append(inline_size);
            try context.static_containing_block_block_auto_sizes.append(0);
            try context.static_containing_block_block_size_margins.append(size_margins);
            try TreeStackItem.stackAppend(&tree_stack, index, allocator);
        } else {
            const parent_auto_block_size = &context.static_containing_block_block_auto_sizes.items[context.static_containing_block_block_auto_sizes.items.len - 1];
            const used_block_size = size_margins.size orelse 0;
            offset_info_ptr.border_top_left.y = parent_auto_block_size.* + size_margins.margin_start;
            offset_info_ptr.content_top_left.y += offset_info_ptr.border_top_left.y;
            offset_info_ptr.content_bottom_right.y = offset_info_ptr.content_top_left.y + used_block_size;
            offset_info_ptr.border_bottom_right.y += offset_info_ptr.content_bottom_right.y;
            parent_auto_block_size.* = offset_info_ptr.border_bottom_right.y + size_margins.margin_end;

            std.debug.print("vertical {}\n", .{interval_copy.begin});
        }
    }

    return result;
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

fn lineWidth(val: computed.BoxSize.BorderValue) CSSUnit {
    return switch (val) {
        .px => |px| length(.{ .px = px }),
        .thin => 1,
        .medium => 3,
        .thick => 5,
        .initial, .inherit, .unset => unreachable,
    };
}

fn getInlineOffsets(tree: *const BoxTree, context: *const Context, key: u16, offset_info: *OffsetInfo, borders: *used.Borders) CSSUnit {
    const solved = solveInlineSizes(
        &tree.inline_size[key],
        context.static_containing_block_inline_sizes.items[context.static_containing_block_inline_sizes.items.len - 1],
    );

    // TODO using physical property when we should be using a logical one
    offset_info.border_top_left.x = solved.margin_start;
    offset_info.content_top_left.x = offset_info.border_top_left.x + solved.border_start + solved.padding_start;
    offset_info.content_bottom_right.x = offset_info.content_top_left.x + solved.size;
    offset_info.border_bottom_right.x = offset_info.content_bottom_right.x + solved.padding_end + solved.border_end;

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

fn getBlockOffsets(tree: *const BoxTree, context: *const Context, key: u16, offset_info: *OffsetInfo, borders: *used.Borders) UsedSizeAndMargins {
    const solved = solveBlockSizes(
        &tree.block_size[key],
        context.static_containing_block_inline_sizes.items[context.static_containing_block_inline_sizes.items.len - 1],
        context.static_containing_block_block_size_margins.items[context.static_containing_block_block_size_margins.items.len - 1].size,
    );

    // TODO using physical property when we should be using a logical one
    offset_info.content_top_left.y = solved.border_start + solved.padding_start;
    offset_info.border_bottom_right.y = solved.padding_end + solved.border_end;

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
        .min_size = .{ .px = 0 },
        .max_size = .{ .none = {} },
        .margin_start = .{ .px = 20 },
        .margin_end = .{ .px = 20 },
        .border_start_width = .{ .px = 5 },
        .border_end_width = .{ .px = 5 },
        .padding_start = .{ .px = 0 },
        .padding_end = .{ .px = 0 },
    };
    const inline_size_2 = computed.LogicalSize{
        .size = .{ .auto = {} },
        .min_size = .{ .px = 0 },
        .max_size = .{ .none = {} },
        .margin_start = .{ .px = 20 },
        .margin_end = .{ .auto = {} },
        .border_start_width = .{ .px = 5 },
        .border_end_width = .{ .px = 5 },
        .padding_start = .{ .px = 0 },
        .padding_end = .{ .px = 0 },
    };
    const block_size_1 = computed.LogicalSize{
        .size = .{ .percentage = 0.9 },
        .min_size = .{ .px = 0 },
        .max_size = .{ .none = {} },
        .margin_start = .{ .auto = {} },
        .margin_end = .{ .auto = {} },
        .border_start_width = .{ .px = 5 },
        .border_end_width = .{ .px = 5 },
        .padding_start = .{ .px = 0 },
        .padding_end = .{ .px = 0 },
    };
    const block_size_2 = computed.LogicalSize{
        .size = .{ .auto = {} },
        .min_size = .{ .px = 0 },
        .max_size = .{ .none = {} },
        .margin_start = .{ .auto = {} },
        .margin_end = .{ .auto = {} },
        .border_start_width = .{ .px = 5 },
        .border_end_width = .{ .px = 5 },
        .padding_start = .{ .px = 0 },
        .padding_end = .{ .px = 0 },
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

    inline for ([4][]const u16{
        &[_]u16{0},
        &[_]u16{ 0, 1 },
        &[_]u16{ 0, 1, 2 },
        &[_]u16{ 0, 3 },
    }) |key| {
        std.debug.print("{}\n", .{result.offset_tree.get(key).?});
    }
}
