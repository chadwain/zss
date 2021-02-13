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
const expect = std.testing.expect;

const zss = @import("../zss.zig");
usingnamespace zss.properties;
const ContextSpecificBoxIdPart = zss.context.ContextSpecificBoxIdPart;
const cmpPart = zss.context.cmpPart;
const Offset = zss.types.Offset;
const BlockFormattingContext = zss.BlockFormattingContext;
const PrefixTreeMapUnmanaged = @import("prefix-tree-map").PrefixTreeMapUnmanaged;

fn TreeMap(comptime V: type) type {
    return PrefixTreeMapUnmanaged(ContextSpecificBoxIdPart, V, cmpPart);
}

pub const OffsetTree = TreeMap(OffsetInfo);
pub const OffsetInfo = struct {
    border_top_left: Offset,
    border_bottom_right: Offset,
    content_top_left: Offset,
    content_bottom_right: Offset,
};

const dummy_margin_tb_node = TreeMap(MarginTopBottom){};
const dummy_margin_lr_node = TreeMap(MarginLeftRight){};
const dummy_borders_node = TreeMap(Borders){};
const dummy_padding_node = TreeMap(Padding){};
const dummy_dimension_node = TreeMap(Dimension){};

pub fn fromBlockContext(context: *const BlockFormattingContext, allocator: *Allocator) !OffsetTree {
    var result = OffsetTree{};
    errdefer result.deinitRecursive(allocator);

    const StackItem = struct {
        tree: *const TreeMap(bool),
        margin_tb: *const TreeMap(MarginTopBottom),
        margin_lr: *const TreeMap(MarginLeftRight),
        borders: *const TreeMap(Borders),
        padding: *const TreeMap(Padding),
        dimension: *const TreeMap(Dimension),
        destination: *OffsetTree,
    };

    var node_stack = ArrayList(StackItem).init(allocator);
    defer node_stack.deinit();
    try node_stack.append(StackItem{
        .tree = &context.tree,
        .margin_tb = &context.margin_top_bottom,
        .margin_lr = &context.margin_left_right,
        .borders = &context.borders,
        .padding = &context.padding,
        .dimension = &context.dimension,
        .destination = &result,
    });

    while (node_stack.items.len > 0) {
        const nodes = node_stack.pop();
        const origin = Offset{ .x = 0, .y = 0 };
        var offset_info = OffsetInfo{
            .border_top_left = origin,
            .border_bottom_right = origin,
            .content_top_left = origin,
            .content_bottom_right = origin,
        };

        var i: usize = 0;
        var i_margin_tb: usize = 0;
        var i_margin_lr: usize = 0;
        var i_borders: usize = 0;
        var i_padding: usize = 0;
        var i_dimension: usize = 0;
        while (i < nodes.tree.numChildren()) : (i += 1) {
            const part = nodes.tree.parts.items[i];
            if (!(i < nodes.destination.numChildren() and nodes.destination.parts.items[i] == part)) {
                assert(i == try nodes.destination.newEdge(allocator, part, undefined, null));
            }

            const dimension: struct { data: Dimension, child: *const TreeMap(Dimension) } =
                if (i_dimension < nodes.dimension.numChildren() and nodes.dimension.parts.items[i_dimension] == part)
            blk: {
                const data = nodes.dimension.value(i_dimension);
                const child = nodes.dimension.child(i_dimension);
                i_dimension += 1;
                break :blk .{ .data = data, .child = child orelse &dummy_dimension_node };
            } else .{ .data = Dimension{}, .child = &dummy_dimension_node };
            const borders: struct { data: Borders, child: *const TreeMap(Borders) } =
                if (i_borders < nodes.borders.numChildren() and nodes.borders.parts.items[i_borders] == part)
            blk: {
                const data = nodes.borders.value(i_borders);
                const child = nodes.borders.child(i_borders);
                i_borders += 1;
                break :blk .{ .data = data, .child = child orelse &dummy_borders_node };
            } else .{ .data = Borders{}, .child = &dummy_borders_node };
            const padding: struct { data: Padding, child: *const TreeMap(Padding) } =
                if (i_padding < nodes.padding.numChildren() and nodes.padding.parts.items[i_padding] == part)
            blk: {
                const data = nodes.padding.value(i_padding);
                const child = nodes.padding.child(i_padding);
                i_padding += 1;
                break :blk .{ .data = data, .child = child orelse &dummy_padding_node };
            } else .{ .data = Padding{}, .child = &dummy_padding_node };

            const mtb: struct { data: MarginTopBottom, child: *const TreeMap(MarginTopBottom) } =
                if (i_margin_tb < nodes.margin_tb.numChildren() and nodes.margin_tb.parts.items[i_margin_tb] == part)
            blk: {
                const data = nodes.margin_tb.value(i_margin_tb);
                const child = nodes.margin_tb.child(i_margin_tb);
                i_margin_tb += 1;
                break :blk .{ .data = data, .child = child orelse &dummy_margin_tb_node };
            } else .{ .data = MarginTopBottom{}, .child = &dummy_margin_tb_node };
            const mlr: struct { data: MarginLeftRight, child: *const TreeMap(MarginLeftRight) } =
                if (i_margin_lr < nodes.margin_lr.numChildren() and nodes.margin_lr.parts.items[i_margin_lr] == part)
            blk: {
                const data = nodes.margin_lr.value(i_margin_lr);
                const child = nodes.margin_lr.child(i_margin_lr);
                i_margin_lr += 1;
                break :blk .{ .data = data, .child = child orelse &dummy_margin_lr_node };
            } else .{ .data = MarginLeftRight{}, .child = &dummy_margin_lr_node };

            offset_info.border_top_left = Offset{ .x = mlr.data.left, .y = offset_info.border_top_left.y + mtb.data.top };
            offset_info.content_top_left = Offset{
                .x = offset_info.border_top_left.x + borders.data.left + padding.data.left,
                .y = offset_info.border_top_left.y + borders.data.top + padding.data.top,
            };
            offset_info.content_bottom_right = Offset{
                .x = offset_info.content_top_left.x + dimension.data.width,
                .y = offset_info.content_top_left.y + dimension.data.height,
            };
            offset_info.border_bottom_right = Offset{
                .x = offset_info.content_bottom_right.x + borders.data.right + padding.data.right,
                .y = offset_info.content_bottom_right.y + borders.data.bottom + padding.data.bottom,
            };
            nodes.destination.values.items[i] = offset_info;
            offset_info.border_top_left.y = offset_info.border_bottom_right.y + mtb.data.bottom;

            if (nodes.tree.child(i)) |child_tree| {
                const child_destination = try allocator.create(OffsetTree);
                child_destination.* = OffsetTree{};
                nodes.destination.child_nodes.items[i].s = child_destination;

                try node_stack.append(StackItem{
                    .tree = child_tree,
                    .margin_tb = mtb.child,
                    .margin_lr = mlr.child,
                    .borders = borders.child,
                    .padding = padding.child,
                    .dimension = dimension.child,
                    .destination = child_destination,
                });
            }
        }
    }

    return result;
}

test "fromBlockContext" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer expect(!gpa.deinit());
    const al = &gpa.allocator;

    var blkctx = BlockFormattingContext.init(al);
    defer blkctx.deinit();

    const keys = [_][]const ContextSpecificBoxIdPart{
        &[_]ContextSpecificBoxIdPart{0},
        &[_]ContextSpecificBoxIdPart{ 0, 0 },
        &[_]ContextSpecificBoxIdPart{ 0, 1 },
        &[_]ContextSpecificBoxIdPart{ 0, 2 },
        &[_]ContextSpecificBoxIdPart{1},
        &[_]ContextSpecificBoxIdPart{ 1, 0, 0 },
    };
    for (keys) |k| {
        try blkctx.new(k);
    }

    try blkctx.set(keys[0], .borders, Borders{ .left = 100 });
    try blkctx.set(keys[0], .dimension, Dimension{ .height = 400 });
    try blkctx.set(keys[2], .dimension, Dimension{ .height = 50 });

    var offsets = try fromBlockContext(&blkctx, al);
    defer offsets.deinitRecursive(al);

    for (keys) |k| {
        std.debug.print("{}\n", .{offsets.get(k).?});
    }
}
