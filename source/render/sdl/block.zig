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

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const assert = std.debug.assert;

const zss = @import("../../../zss.zig");
const BlockFormattingContext = zss.BlockFormattingContext;
const RenderTree = zss.RenderTree;
const sdl = zss.sdl;
usingnamespace sdl.sdl;
usingnamespace zss.properties;

const StackItem = struct {
    elem_id: BlockFormattingContext.IdPart,
    node: ?std.meta.fieldInfo(BlockFormattingContext, std.meta.stringToEnum(std.meta.FieldEnum(BlockFormattingContext), "tree").?).field_type,
    offset: sdl.Offset,
};

pub const BlockRenderState = struct {
    context: *const BlockFormattingContext,
    stack: ArrayList(?StackItem),
    id: ArrayList(BlockFormattingContext.IdPart),

    const Self = @This();

    pub fn init(blk_ctx: *const BlockFormattingContext, allocator: *Allocator) !Self {
        var result = Self{
            .context = blk_ctx,
            .stack = ArrayList(?StackItem).init(allocator),
            .id = ArrayList(BlockFormattingContext.IdPart).init(allocator),
        };

        try addChildrenToStack(&result, sdl.Offset{ .x = 0, .y = 0 }, blk_ctx.tree);

        return result;
    }

    pub fn deinit(self: Self) void {
        self.stack.deinit();
        self.id.deinit();
    }
};

pub fn renderBlockFormattingContext(
    state: *BlockRenderState,
    outer_state: *sdl.RenderState,
    renderer: *SDL_Renderer,
    pixel_format: *SDL_PixelFormat,
    outer_offset: sdl.Offset,
    this_id: RenderTree.ContextId,
) !bool {
    const stack = &state.stack;
    const id = &state.id;
    while (stack.items.len > 0) {
        const item = stack.pop() orelse {
            _ = id.pop();
            continue;
        };

        try id.append(item.elem_id);
        renderBlockElement(state.context, item.offset.add(outer_offset), id.items, renderer, pixel_format);

        const new_offset = updateState1(state.context, item.offset, id.items);
        if (item.node) |node| {
            try addChildrenToStack(state, new_offset, node);
        } else {
            if (outer_state.tree.getDescendantOrNull(RenderTree.BoxId{ .ctx = this_id, .box = id.items })) |desc| {
                try sdl.pushDescendant(outer_state, desc, new_offset.add(outer_offset));
                return false;
            }
        }
    }
    return true;
}

fn addChildrenToStack(
    state: *BlockRenderState,
    input_offset: sdl.Offset,
    node: std.meta.fieldInfo(BlockFormattingContext, std.meta.stringToEnum(std.meta.FieldEnum(BlockFormattingContext), "tree").?).field_type,
) !void {
    const stack = &state.stack;
    const prev_len = stack.items.len;
    const num_children = node.numChildren();
    try stack.resize(prev_len + 2 * num_children);

    const id = &state.id;
    try id.resize(id.items.len + 1);
    defer id.shrinkRetainingCapacity(id.items.len - 1);

    var offset = input_offset;
    var i: usize = 0;
    while (i < num_children) : (i += 1) {
        const dest = stack.items[prev_len..][2 * (num_children - 1 - i) ..][0..2];
        const part = node.parts.items[i];
        dest[0] = null;
        dest[1] = StackItem{
            .elem_id = part,
            .node = node.child(i),
            .offset = offset,
        };
        id.items[id.items.len - 1] = part;
        offset = updateState2(state.context, offset, id.items);
    }
}

fn updateState1(blk_ctx: *const BlockFormattingContext, offset: sdl.Offset, elem_id: BlockFormattingContext.Id) sdl.Offset {
    const bplr = blk_ctx.get(elem_id, .border_padding_left_right);
    const bptb = blk_ctx.get(elem_id, .border_padding_top_bottom);
    const mlr = blk_ctx.get(elem_id, .margin_left_right);
    const mtb = blk_ctx.get(elem_id, .margin_top_bottom);

    return sdl.Offset{
        .x = offset.x + mlr.margin_left + bplr.border_left + bplr.padding_left,
        .y = offset.y + mtb.margin_top + bptb.border_top + bptb.padding_top,
    };
}

fn updateState2(blk_ctx: *const BlockFormattingContext, offset: sdl.Offset, elem_id: BlockFormattingContext.Id) sdl.Offset {
    return sdl.Offset{
        .x = offset.x,
        .y = offset.y + getElementHeight(blk_ctx, elem_id),
    };
}

fn getElementHeight(blk_ctx: *const BlockFormattingContext, elem_id: BlockFormattingContext.Id) CSSUnit {
    const height = blk_ctx.get(elem_id, .height);
    const bptb = blk_ctx.get(elem_id, .border_padding_top_bottom);
    const mtb = blk_ctx.get(elem_id, .margin_top_bottom);
    return height.height + bptb.border_top + bptb.border_bottom + bptb.padding_top + bptb.padding_bottom + mtb.margin_top + mtb.margin_bottom;
}

fn renderBlockElement(
    blk_ctx: *const BlockFormattingContext,
    offset: sdl.Offset,
    elem_id: BlockFormattingContext.Id,
    renderer: *SDL_Renderer,
    pixel_format: *SDL_PixelFormat,
) void {
    const width = blk_ctx.get(elem_id, .width);
    const height = blk_ctx.get(elem_id, .height);
    const bplr = blk_ctx.get(elem_id, .border_padding_left_right);
    const bptb = blk_ctx.get(elem_id, .border_padding_top_bottom);
    const mlr = blk_ctx.get(elem_id, .margin_left_right);
    const mtb = blk_ctx.get(elem_id, .margin_top_bottom);
    const border_colors = blk_ctx.get(elem_id, .border_colors);
    const bg_color = blk_ctx.get(elem_id, .background_color);

    const border_x = offset.x + mlr.margin_left;
    const border_y = offset.y + mtb.margin_top;
    const padding_height = height.height + bptb.padding_top + bptb.padding_bottom;
    const full_width = width.width + bplr.border_left + bplr.border_right + bplr.padding_left + bplr.padding_right;
    const full_height = padding_height + bptb.border_top + bptb.border_bottom;

    const colors = [_]u32{
        sdl.rgbaMap(pixel_format, bg_color.rgba),
        sdl.rgbaMap(pixel_format, border_colors.top_rgba),
        sdl.rgbaMap(pixel_format, border_colors.right_rgba),
        sdl.rgbaMap(pixel_format, border_colors.bottom_rgba),
        sdl.rgbaMap(pixel_format, border_colors.left_rgba),
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
