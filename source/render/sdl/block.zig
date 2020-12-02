// This file is a part of zss.
// Copyright (C) 2020 Chadwain Holness
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

usingnamespace zss.sdl.sdl;

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const assert = std.debug.assert;

const zss = @import("../../../zss.zig");
const BlockFormattingContext = zss.BlockFormattingContext;
usingnamespace zss.properties;

const RenderState = struct {
    offset_x: CSSUnit,
    offset_y: CSSUnit,
};

const StackItem = struct {
    value: BlockFormattingContext.MapKey,
    node: ?std.meta.fieldInfo(BlockFormattingContext.Tree, "root").field_type,
    state: RenderState,
};

pub fn renderBlockFormattingContext(
    blk_ctx: BlockFormattingContext,
    allocator: *Allocator,
    surface: *SDL_Surface,
) !void {
    var stack = ArrayList(StackItem).init(allocator);
    defer stack.deinit();

    {
        const state = RenderState{
            .offset_x = 0,
            .offset_y = 0,
        };
        try addChildrenToStack(&stack, state, blk_ctx, blk_ctx.tree.root);
    }

    while (stack.items.len > 0) {
        const item = stack.pop();
        renderBlockElement(blk_ctx, item.value, surface, item.state);

        const node = item.node orelse continue;
        const new_state = updateState1(blk_ctx, item.state, item.value);
        try addChildrenToStack(&stack, new_state, blk_ctx, node);
    }
}

fn addChildrenToStack(
    stack: *ArrayList(StackItem),
    input_state: RenderState,
    blk_ctx: BlockFormattingContext,
    node: std.meta.fieldInfo(BlockFormattingContext.Tree, "root").field_type,
) !void {
    var state = input_state;
    const prev_len = stack.items.len;
    const num_children = node.edges.items.len;
    try stack.resize(prev_len + num_children);

    var i: usize = 0;
    while (i < num_children) : (i += 1) {
        const dest = &stack.items[prev_len..][num_children - 1 - i];
        dest.* = .{
            .value = node.edges.items[i].map_key,
            .node = node.child_nodes.items[i].s,
            .state = state,
        };
        state = updateState2(blk_ctx, state, dest.value);
    }
}

fn updateState1(blk_ctx: BlockFormattingContext, state: RenderState, elem_id: BlockFormattingContext.MapKey) RenderState {
    const bplr = blk_ctx.get(elem_id, .border_padding_left_right);
    const bptb = blk_ctx.get(elem_id, .border_padding_top_bottom);
    const mlr = blk_ctx.get(elem_id, .margin_left_right);
    const mtb = blk_ctx.get(elem_id, .margin_top_bottom);

    return RenderState{
        .offset_x = state.offset_x + mlr.margin_left + bplr.border_left + bplr.padding_left,
        .offset_y = state.offset_y + mtb.margin_top + bptb.border_top + bptb.padding_top,
    };
}

fn updateState2(blk_ctx: BlockFormattingContext, state: RenderState, elem_id: BlockFormattingContext.MapKey) RenderState {
    return RenderState{
        .offset_x = state.offset_x,
        .offset_y = state.offset_y + getElementHeight(blk_ctx, elem_id),
    };
}

fn getElementHeight(blk_ctx: BlockFormattingContext, elem_id: BlockFormattingContext.MapKey) CSSUnit {
    const height = blk_ctx.get(elem_id, .height);
    const bptb = blk_ctx.get(elem_id, .border_padding_top_bottom);
    const mtb = blk_ctx.get(elem_id, .margin_top_bottom);
    return height.height + bptb.border_top + bptb.border_bottom + bptb.padding_top + bptb.padding_bottom + mtb.margin_top + mtb.margin_bottom;
}

fn rgbaMap(pixelFormat: *SDL_PixelFormat, color: u32) u32 {
    const color_le = std.mem.nativeToLittle(u32, color);
    return SDL_MapRGBA(
        pixelFormat,
        @truncate(u8, color_le >> 24),
        @truncate(u8, color_le >> 16),
        @truncate(u8, color_le >> 8),
        @truncate(u8, color_le),
    );
}

fn renderBlockElement(
    blk_ctx: BlockFormattingContext,
    elem_id: BlockFormattingContext.MapKey,
    surface: *SDL_Surface,
    state: RenderState,
) void {
    const width = blk_ctx.get(elem_id, .width);
    const height = blk_ctx.get(elem_id, .height);
    const bplr = blk_ctx.get(elem_id, .border_padding_left_right);
    const bptb = blk_ctx.get(elem_id, .border_padding_top_bottom);
    const mlr = blk_ctx.get(elem_id, .margin_left_right);
    const mtb = blk_ctx.get(elem_id, .margin_top_bottom);
    const border_colors = blk_ctx.get(elem_id, .border_colors);
    const bg_color = blk_ctx.get(elem_id, .background_color);

    const border_x = state.offset_x + mlr.margin_left;
    const border_y = state.offset_y + mtb.margin_top;
    const padding_height = height.height + bptb.padding_top + bptb.padding_bottom;
    const full_width = width.width + bplr.border_left + bplr.border_right + bplr.padding_left + bplr.padding_right;
    const full_height = padding_height + bptb.border_top + bptb.border_bottom;

    const pixel_format = surface.*.format;
    const colors = [_]u32{
        rgbaMap(pixel_format, bg_color.rgba),
        rgbaMap(pixel_format, border_colors.top_rgba),
        rgbaMap(pixel_format, border_colors.right_rgba),
        rgbaMap(pixel_format, border_colors.bottom_rgba),
        rgbaMap(pixel_format, border_colors.left_rgba),
    };

    const rects = [_]SDL_Rect{
        // background
        SDL_Rect{
            .x = border_x,
            .y = border_y,
            .w = full_width,
            .h = full_height,
        },
        // top border
        SDL_Rect{
            .x = border_x,
            .y = border_y,
            .w = full_width,
            .h = bptb.border_top,
        },
        // right border
        SDL_Rect{
            .x = border_x + full_width - bplr.border_right,
            .y = border_y + bptb.border_top,
            .w = bplr.border_right,
            .h = padding_height,
        },
        // bottom border
        SDL_Rect{
            .x = border_x,
            .y = border_y + full_height - bptb.border_bottom,
            .w = full_width,
            .h = bptb.border_bottom,
        },
        //left border
        SDL_Rect{
            .x = border_x,
            .y = border_y + bptb.border_top,
            .w = bplr.border_left,
            .h = padding_height,
        },
    };

    for (rects) |_, i| {
        assert(SDL_FillRect(surface, &rects[i], colors[i]) == 0);
    }
}
