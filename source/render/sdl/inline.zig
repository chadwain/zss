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
const InlineFormattingContext = zss.InlineFormattingContext;
usingnamespace zss.properties;

const RenderState = struct {
    offset_x: CSSUnit,
    offset_y: CSSUnit,
};

const StackItem = struct {
    value: InlineFormattingContext.MapKey,
    node: ?std.meta.fieldInfo(InlineFormattingContext.Tree, "root").field_type,
};

pub fn renderInlineFormattingContext(
    inl_ctx: InlineFormattingContext,
    allocator: *Allocator,
    surface: *SDL_Surface,
    state: RenderState,
) !void {
    var stack = ArrayList(StackItem).init(allocator);
    defer stack.deinit();

    try addChildrenToStack(&stack, inl_ctx, inl_ctx.tree.root);

    while (stack.items.len > 0) {
        const item = stack.pop();
        renderInlineElement(inl_ctx, item.value, surface, state);

        const node = item.node orelse continue;
        try addChildrenToStack(&stack, inl_ctx, node);
    }
}

fn addChildrenToStack(
    stack: *ArrayList(StackItem),
    inl_ctx: InlineFormattingContext,
    node: std.meta.fieldInfo(InlineFormattingContext.Tree, "root").field_type,
) !void {
    const prev_len = stack.items.len;
    const num_children = node.edges.items.len;
    try stack.resize(prev_len + num_children);

    var i: usize = 0;
    while (i < num_children) : (i += 1) {
        const dest = &stack.items[prev_len..][num_children - 1 - i];
        dest.* = .{
            .value = node.edges.items[i].map_key,
            .node = node.child_nodes.items[i].s,
        };
    }
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

fn renderInlineElement(
    inl_ctx: InlineFormattingContext,
    elem_id: InlineFormattingContext.MapKey,
    surface: *SDL_Surface,
    state: RenderState,
) void {
    const width = inl_ctx.get(elem_id, .width);
    const height = inl_ctx.get(elem_id, .height);
    const mbplr = inl_ctx.get(elem_id, .margin_border_padding_left_right);
    const mbptb = inl_ctx.get(elem_id, .margin_border_padding_top_bottom);
    const border_colors = inl_ctx.get(elem_id, .border_colors);
    const bg_color = inl_ctx.get(elem_id, .background_color);
    const position = inl_ctx.get(elem_id, .position);
    //const data = inl_ctx.get(elem_id, .data);

    const line_box = inl_ctx.line_boxes.items[position.line_box_index];
    const margin_x = state.offset_x + position.advance;
    const margin_y = state.offset_y + line_box.y_pos + line_box.baseline - position.ascender;

    const border_x = margin_x + mbplr.margin_left;
    const border_y = margin_y + mbptb.margin_top;
    const padding_height = height.height + mbptb.padding_top + mbptb.padding_bottom;
    const full_width = width.width + mbplr.border_left + mbplr.border_right + mbplr.padding_left + mbplr.padding_right;
    const full_height = padding_height + mbptb.border_top + mbptb.border_bottom;

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
            .h = mbptb.border_top,
        },
        // right border
        SDL_Rect{
            .x = border_x + full_width - mbplr.border_right,
            .y = border_y + mbptb.border_top,
            .w = mbplr.border_right,
            .h = padding_height,
        },
        // bottom border
        SDL_Rect{
            .x = border_x,
            .y = border_y + full_height - mbptb.border_bottom,
            .w = full_width,
            .h = mbptb.border_bottom,
        },
        //left border
        SDL_Rect{
            .x = border_x,
            .y = border_y + mbptb.border_top,
            .w = mbplr.border_left,
            .h = padding_height,
        },
    };

    for (rects) |_, i| {
        assert(SDL_FillRect(surface, &rects[i], colors[i]) == 0);
    }
}
