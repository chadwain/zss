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
const rgbaMap = zss.sdl.rgbaMap;
usingnamespace zss.properties;

const BlockRenderState = struct {
    offset_x: CSSUnit,
    offset_y: CSSUnit,
};

const StackItem = struct {
    value: BlockFormattingContext.MapKey,
    node: ?*BlockFormattingContext.Tree,
    state: BlockRenderState,
};

pub fn renderBlockFormattingContext(
    blk_ctx: BlockFormattingContext,
    allocator: *Allocator,
    renderer: *SDL_Renderer,
    pixel_format: *SDL_PixelFormat,
) !void {
    var stack = ArrayList(StackItem).init(allocator);
    defer stack.deinit();

    {
        const state = BlockRenderState{
            .offset_x = 0,
            .offset_y = 0,
        };
        try addChildrenToStack(&stack, state, blk_ctx, blk_ctx.tree);
    }

    while (stack.items.len > 0) {
        const item = stack.pop();
        renderBlockElement(blk_ctx, item.value, renderer, pixel_format, item.state);

        const node = item.node orelse continue;
        const new_state = updateState1(blk_ctx, item.state, item.value);
        try addChildrenToStack(&stack, new_state, blk_ctx, node);
    }
}

fn addChildrenToStack(
    stack: *ArrayList(StackItem),
    input_state: BlockRenderState,
    blk_ctx: BlockFormattingContext,
    node: *BlockFormattingContext.Tree,
) !void {
    var state = input_state;
    const prev_len = stack.items.len;
    const num_children = node.numChildren();
    try stack.resize(prev_len + num_children);

    var i: usize = 0;
    while (i < num_children) : (i += 1) {
        const dest = &stack.items[prev_len..][num_children - 1 - i];
        dest.* = .{
            .value = node.get(i).map_key,
            .node = node.child(i),
            .state = state,
        };
        state = updateState2(blk_ctx, state, dest.value);
    }
}

fn updateState1(blk_ctx: BlockFormattingContext, state: BlockRenderState, elem_id: BlockFormattingContext.MapKey) BlockRenderState {
    const bplr = blk_ctx.get(elem_id, .border_padding_left_right);
    const bptb = blk_ctx.get(elem_id, .border_padding_top_bottom);
    const mlr = blk_ctx.get(elem_id, .margin_left_right);
    const mtb = blk_ctx.get(elem_id, .margin_top_bottom);

    return BlockRenderState{
        .offset_x = state.offset_x + mlr.margin_left + bplr.border_left + bplr.padding_left,
        .offset_y = state.offset_y + mtb.margin_top + bptb.border_top + bptb.padding_top,
    };
}

fn updateState2(blk_ctx: BlockFormattingContext, state: BlockRenderState, elem_id: BlockFormattingContext.MapKey) BlockRenderState {
    return BlockRenderState{
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

fn renderBlockElement(
    blk_ctx: BlockFormattingContext,
    elem_id: BlockFormattingContext.MapKey,
    renderer: *SDL_Renderer,
    pixel_format: *SDL_PixelFormat,
    state: BlockRenderState,
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
        var rgba: [4]u8 = undefined;
        SDL_GetRGBA(colors[i], pixel_format, &rgba[0], &rgba[1], &rgba[2], &rgba[3]);
        assert(SDL_SetRenderDrawColor(renderer, rgba[0], rgba[1], rgba[2], rgba[3]) == 0);
        assert(SDL_RenderFillRect(renderer, &rects[i]) == 0);
    }
}
