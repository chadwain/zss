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
const ContextSpecificBoxIdPart = zss.RenderTree.ContextSpecificBoxIdPart;
const cmpPart = zss.RenderTree.cmpPart;
const Offset = zss.util.Offset;
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
const dummy_bord_padd_tb_node = TreeMap(BorderPaddingTopBottom){};
const dummy_bord_padd_lr_node = TreeMap(BorderPaddingLeftRight){};
const dummy_height_node = TreeMap(Height){};
const dummy_width_node = TreeMap(Width){};

pub fn fromBlockContext(context: *const BlockFormattingContext, allocator: *Allocator) !*OffsetTree {
    var result = try OffsetTree.init(allocator);
    errdefer result.deinitRecursive(allocator);

    const StackItem = struct {
        tree: *const TreeMap(bool),
        margin_tb: *const TreeMap(MarginTopBottom),
        margin_lr: *const TreeMap(MarginLeftRight),
        bord_padd_tb: *const TreeMap(BorderPaddingTopBottom),
        bord_padd_lr: *const TreeMap(BorderPaddingLeftRight),
        height: *const TreeMap(Height),
        width: *const TreeMap(Width),
        destination: *OffsetTree,
    };

    var node_stack = ArrayList(StackItem).init(allocator);
    defer node_stack.deinit();
    try node_stack.append(StackItem{
        .tree = context.tree,
        .margin_tb = context.margin_top_bottom,
        .margin_lr = context.margin_left_right,
        .bord_padd_tb = context.border_padding_top_bottom,
        .bord_padd_lr = context.border_padding_left_right,
        .height = context.height,
        .width = context.width,
        .destination = result,
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
        var i_bord_padd_tb: usize = 0;
        var i_bord_padd_lr: usize = 0;
        var i_height: usize = 0;
        var i_width: usize = 0;
        while (i < nodes.tree.numChildren()) : (i += 1) {
            const part = nodes.tree.parts.items[i];
            if (!(i < nodes.destination.numChildren() and nodes.destination.parts.items[i] == part)) {
                assert(i == try nodes.destination.newEdge(allocator, part, undefined, null));
            }

            const mtb: struct { data: MarginTopBottom, child: *const TreeMap(MarginTopBottom) } =
                if (i_margin_tb < nodes.margin_tb.numChildren() and nodes.margin_tb.parts.items[i_margin_tb] == part)
            blk: {
                const data = nodes.margin_tb.value(i_margin_tb);
                const child = nodes.margin_tb.child(i_margin_tb);
                i_margin_tb += 1;
                break :blk .{ .data = data, .child = child orelse &dummy_margin_tb_node };
            } else .{ .data = MarginTopBottom{}, .child = &dummy_margin_tb_node };
            const bptb: struct { data: BorderPaddingTopBottom, child: *const TreeMap(BorderPaddingTopBottom) } =
                if (i_bord_padd_tb < nodes.bord_padd_tb.numChildren() and nodes.bord_padd_tb.parts.items[i_bord_padd_tb] == part)
            blk: {
                const data = nodes.bord_padd_tb.value(i_bord_padd_tb);
                const child = nodes.bord_padd_tb.child(i_bord_padd_tb);
                i_bord_padd_tb += 1;
                break :blk .{ .data = data, .child = child orelse &dummy_bord_padd_tb_node };
            } else .{ .data = BorderPaddingTopBottom{}, .child = &dummy_bord_padd_tb_node };
            const height: struct { data: Height, child: *const TreeMap(Height) } =
                if (i_height < nodes.height.numChildren() and nodes.height.parts.items[i_height] == part)
            blk: {
                const data = nodes.height.value(i_height);
                const child = nodes.height.child(i_height);
                i_height += 1;
                break :blk .{ .data = data, .child = child orelse &dummy_height_node };
            } else .{ .data = Height{}, .child = &dummy_height_node };

            const mlr: struct { data: MarginLeftRight, child: *const TreeMap(MarginLeftRight) } =
                if (i_margin_lr < nodes.margin_lr.numChildren() and nodes.margin_lr.parts.items[i_margin_lr] == part)
            blk: {
                const data = nodes.margin_lr.value(i_margin_lr);
                const child = nodes.margin_lr.child(i_margin_lr);
                i_margin_lr += 1;
                break :blk .{ .data = data, .child = child orelse &dummy_margin_lr_node };
            } else .{ .data = MarginLeftRight{}, .child = &dummy_margin_lr_node };
            const bplr: struct { data: BorderPaddingLeftRight, child: *const TreeMap(BorderPaddingLeftRight) } =
                if (i_bord_padd_lr < nodes.bord_padd_lr.numChildren() and nodes.bord_padd_lr.parts.items[i_bord_padd_lr] == part)
            blk: {
                const data = nodes.bord_padd_lr.value(i_bord_padd_lr);
                const child = nodes.bord_padd_lr.child(i_bord_padd_lr);
                i_bord_padd_lr += 1;
                break :blk .{ .data = data, .child = child orelse &dummy_bord_padd_lr_node };
            } else .{ .data = BorderPaddingLeftRight{}, .child = &dummy_bord_padd_lr_node };
            const width: struct { data: Width, child: *const TreeMap(Width) } =
                if (i_width < nodes.width.numChildren() and nodes.width.parts.items[i_width] == part)
            blk: {
                const data = nodes.width.value(i_width);
                const child = nodes.width.child(i_width);
                i_width += 1;
                break :blk .{ .data = data, .child = child orelse &dummy_width_node };
            } else .{ .data = Width{}, .child = &dummy_width_node };

            offset_info.border_top_left = Offset{ .x = mlr.data.margin_left, .y = offset_info.border_top_left.y + mtb.data.margin_top };
            offset_info.content_top_left = Offset{
                .x = offset_info.border_top_left.x + bplr.data.border_left + bplr.data.padding_left,
                .y = offset_info.border_top_left.y + bptb.data.border_top + bptb.data.padding_top,
            };
            offset_info.content_bottom_right = Offset{
                .x = offset_info.content_top_left.x + width.data.width,
                .y = offset_info.content_top_left.y + height.data.height,
            };
            offset_info.border_bottom_right = Offset{
                .x = offset_info.content_bottom_right.x + bplr.data.border_right + bplr.data.padding_right,
                .y = offset_info.content_bottom_right.y + bptb.data.border_bottom + bptb.data.padding_bottom,
            };
            nodes.destination.values.items[i] = offset_info;
            offset_info.border_top_left.y = offset_info.border_bottom_right.y + mtb.data.margin_bottom;

            if (nodes.tree.child(i)) |child_tree| {
                const child_destination = try OffsetTree.init(allocator);
                nodes.destination.child_nodes.items[i].s = child_destination;

                try node_stack.append(StackItem{
                    .tree = child_tree,
                    .margin_tb = mtb.child,
                    .margin_lr = mlr.child,
                    .bord_padd_tb = bptb.child,
                    .bord_padd_lr = bplr.child,
                    .height = height.child,
                    .width = width.child,
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

    var blkctx = try BlockFormattingContext.init(al);
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

    try blkctx.set(keys[0], .border_padding_left_right, BorderPaddingLeftRight{ .border_left = 100 });
    try blkctx.set(keys[0], .height, Height{ .height = 400 });
    try blkctx.set(keys[2], .height, Height{ .height = 50 });

    var offsets = try fromBlockContext(&blkctx, al);
    defer offsets.deinitRecursive(al);

    for (keys) |k| {
        std.debug.print("{}\n", .{offsets.get(k).?});
    }
}
