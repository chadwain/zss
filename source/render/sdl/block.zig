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

const zss = @import("../../../zss.zig");
const BlockFormattingContext = zss.BlockFormattingContext;
const TreeNode = @TypeOf(@as(BlockFormattingContext, undefined).tree);
const RenderTree = zss.RenderTree;
const Offset = zss.util.Offset;
const sdl = zss.sdl;
usingnamespace zss.properties;

usingnamespace @import("SDL2");

const StackItem = struct {
    id_part: BlockFormattingContext.IdPart,
    node: ?TreeNode,
    offset: Offset,
};

pub const DrawBlockState = struct {
    context: *const BlockFormattingContext,
    stack: ArrayList(?StackItem),
    id: ArrayList(BlockFormattingContext.IdPart),

    const Self = @This();

    pub fn init(context: *const BlockFormattingContext, allocator: *Allocator) !Self {
        var result = Self{
            .context = context,
            .stack = ArrayList(?StackItem).init(allocator),
            .id = ArrayList(BlockFormattingContext.IdPart).init(allocator),
        };

        try addChildrenToStack(&result, Offset{ .x = 0, .y = 0 }, context.tree);
        return result;
    }

    pub fn deinit(self: Self) void {
        self.stack.deinit();
        self.id.deinit();
    }
};

pub fn drawBlockContext(
    state: *DrawBlockState,
    outer_state: *sdl.RenderState,
    renderer: *SDL_Renderer,
    pixel_format: *SDL_PixelFormat,
    offset: Offset,
    this_id: RenderTree.ContextId,
) !bool {
    const stack = &state.stack;
    const id = &state.id;
    while (stack.items.len > 0) {
        const item = stack.pop() orelse {
            _ = id.pop();
            continue;
        };

        try id.append(item.id_part);
        drawBlockBox(state.context, item.offset.add(offset), id.items, renderer, pixel_format);

        const new_offset = getOffsetOfChildren(state.context, item.offset, id.items);
        if (item.node) |node| {
            try addChildrenToStack(state, new_offset, node);
        } else {
            if (outer_state.tree.getDescendantOrNull(RenderTree.BoxId{ .context_id = this_id, .specific_id = id.items })) |desc| {
                try sdl.pushDescendant(outer_state, desc, new_offset.add(offset));
                return false;
            }
        }
    }
    return true;
}

fn addChildrenToStack(
    state: *DrawBlockState,
    initial_offset: Offset,
    node: TreeNode,
) !void {
    const stack = &state.stack;
    const prev_len = stack.items.len;
    const num_children = node.numChildren();
    try stack.resize(prev_len + 2 * num_children);

    const id = &state.id;
    try id.resize(id.items.len + 1);
    defer id.shrinkRetainingCapacity(id.items.len - 1);

    var offset = initial_offset;
    var i: usize = 0;
    while (i < num_children) : (i += 1) {
        const dest = stack.items[prev_len..][2 * (num_children - 1 - i) ..][0..2];
        const part = node.parts.items[i];
        dest[0] = null;
        dest[1] = StackItem{
            .id_part = part,
            .node = node.child(i),
            .offset = offset,
        };
        id.items[id.items.len - 1] = part;
        offset = getOffsetOfSibling(state.context, offset, id.items);
    }
}

fn getOffsetOfChildren(context: *const BlockFormattingContext, offset: Offset, id: BlockFormattingContext.Id) Offset {
    const bplr = context.get(id, .border_padding_left_right);
    const bptb = context.get(id, .border_padding_top_bottom);
    const mlr = context.get(id, .margin_left_right);
    const mtb = context.get(id, .margin_top_bottom);

    return Offset{
        .x = offset.x + mlr.margin_left + bplr.border_left + bplr.padding_left,
        .y = offset.y + mtb.margin_top + bptb.border_top + bptb.padding_top,
    };
}

fn getOffsetOfSibling(context: *const BlockFormattingContext, offset: Offset, id: BlockFormattingContext.Id) Offset {
    return Offset{
        .x = offset.x,
        .y = offset.y + getMarginHeight(context, id),
    };
}

fn getMarginHeight(context: *const BlockFormattingContext, id: BlockFormattingContext.Id) CSSUnit {
    const height = context.get(id, .height);
    const bptb = context.get(id, .border_padding_top_bottom);
    const mtb = context.get(id, .margin_top_bottom);
    return height.height + bptb.border_top + bptb.border_bottom + bptb.padding_top + bptb.padding_bottom + mtb.margin_top + mtb.margin_bottom;
}

fn drawBlockBox(
    context: *const BlockFormattingContext,
    offset: Offset,
    id: BlockFormattingContext.Id,
    renderer: *SDL_Renderer,
    pixel_format: *SDL_PixelFormat,
) void {
    const width = context.get(id, .width);
    const height = context.get(id, .height);
    const bplr = context.get(id, .border_padding_left_right);
    const bptb = context.get(id, .border_padding_top_bottom);
    const mlr = context.get(id, .margin_left_right);
    const mtb = context.get(id, .margin_top_bottom);
    const border_colors = context.get(id, .border_colors);
    const bg_color = context.get(id, .background_color);

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
            .x = sdl.cssUnitToSdlPixel(border_x),
            .y = sdl.cssUnitToSdlPixel(border_y),
            .w = sdl.cssUnitToSdlPixel(full_width),
            .h = sdl.cssUnitToSdlPixel(full_height),
        },
        // top border
        SDL_Rect{
            .x = sdl.cssUnitToSdlPixel(border_x),
            .y = sdl.cssUnitToSdlPixel(border_y),
            .w = sdl.cssUnitToSdlPixel(full_width),
            .h = sdl.cssUnitToSdlPixel(bptb.border_top),
        },
        // right border
        SDL_Rect{
            .x = sdl.cssUnitToSdlPixel(border_x + full_width - bplr.border_right),
            .y = sdl.cssUnitToSdlPixel(border_y + bptb.border_top),
            .w = sdl.cssUnitToSdlPixel(bplr.border_right),
            .h = sdl.cssUnitToSdlPixel(padding_height),
        },
        // bottom border
        SDL_Rect{
            .x = sdl.cssUnitToSdlPixel(border_x),
            .y = sdl.cssUnitToSdlPixel(border_y + full_height - bptb.border_bottom),
            .w = sdl.cssUnitToSdlPixel(full_width),
            .h = sdl.cssUnitToSdlPixel(bptb.border_bottom),
        },
        //left border
        SDL_Rect{
            .x = sdl.cssUnitToSdlPixel(border_x),
            .y = sdl.cssUnitToSdlPixel(border_y + bptb.border_top),
            .w = sdl.cssUnitToSdlPixel(bplr.border_left),
            .h = sdl.cssUnitToSdlPixel(padding_height),
        },
    };

    for (rects) |_, i| {
        var rgba: [4]u8 = undefined;
        SDL_GetRGBA(colors[i], pixel_format, &rgba[0], &rgba[1], &rgba[2], &rgba[3]);
        assert(SDL_SetRenderDrawColor(renderer, rgba[0], rgba[1], rgba[2], rgba[3]) == 0);
        assert(SDL_RenderFillRect(renderer, &rects[i]) == 0);
    }
}
