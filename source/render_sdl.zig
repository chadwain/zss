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

pub const sdl = @cImport({
    @cInclude("SDL2/SDL.h");
});
usingnamespace sdl;

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const assert = std.debug.assert;

const BlockFormattingContext = @import("BlockFormattingContext.zig");
usingnamespace @import("properties.zig");

pub const SdlContext = struct {
    surface: *SDL_Surface,
};

const RenderState = struct {
    offset_x: i32,
    offset_y: i32,
};

pub fn renderBlockFormattingContext(
    blk_ctx: BlockFormattingContext,
    allocator: *Allocator,
    sdl_ctx: SdlContext,
) !void {
    var stack = ArrayList(BlockFormattingContext.TreeValue).init(allocator);
    defer stack.deinit();

    var tree_key = ArrayList(BlockFormattingContext.TreeValue).init(allocator);
    defer tree_key.deinit();

    const tree = &blk_ctx.tree;
    var state = RenderState{
        .offset_x = 0,
        .offset_y = 0,
    };

    {
        renderBlockElement(blk_ctx, BlockFormattingContext.root_map_key, sdl_ctx, &state);

        const root_node = tree.root;
        var i = root_node.child_nodes.items.len;
        while (i > 0) : (i -= 1) {
            std.debug.print("index {}\n", .{i});
            //if (root_node.child_nodes.items[i - 1].s) |_| {
            try stack.append(root_node.edges.items[i - 1]);
            //}
        }
    }

    // TODO fix this bad loop
    while (stack.items.len > 0) {
        const elem = stack.pop();
        renderBlockElement(blk_ctx, elem.map_key, sdl_ctx, &state);
        std.debug.print("key {}\n", .{elem.map_key});

        try tree_key.append(elem);
        defer _ = tree_key.pop();
        const tree_node = tree.getNode(tree_key.items) orelse continue;

        var i = tree_node.child_nodes.items.len;
        while (i > 0) : (i -= 1) {
            //if (tree_node.child_nodes.items[i - 1].s) |_| {
            try stack.append(tree_node.edges.items[i - 1]);
            //}
        }

        //state.offset_y += getElementHeight(blk_ctx, elem.map_key);
    }
}

fn getElementHeight(blk_ctx: BlockFormattingContext, elem_id: BlockFormattingContext.MapKey) i32 {
    const height = blk_ctx.height.get(elem_id) orelse Height{};
    const bptb = blk_ctx.border_padding_top_bottom.get(elem_id) orelse BorderPaddingTopBottom{};
    const mtb = blk_ctx.margin_top_bottom.get(elem_id) orelse MarginTopBottom{};
    return height.height + bptb.border_top + bptb.border_bottom + bptb.padding_top + bptb.padding_bottom + mtb.margin_top + mtb.margin_bottom;
}

fn rgbaMap(pixelFormat: *SDL_PixelFormat, color: u32) u32 {
    return SDL_MapRGBA(
        pixelFormat,
        @truncate(u8, color >> 24),
        @truncate(u8, color >> 16),
        @truncate(u8, color >> 8),
        @truncate(u8, color),
    );
}

fn renderBlockElement(
    blk_ctx: BlockFormattingContext,
    elem_id: BlockFormattingContext.MapKey,
    sdl_ctx: SdlContext,
    state: *RenderState,
) void {
    const width = blk_ctx.width.get(elem_id) orelse Width{};
    const height = blk_ctx.height.get(elem_id) orelse Height{};
    const bplr = blk_ctx.border_padding_left_right.get(elem_id) orelse BorderPaddingLeftRight{};
    const bptb = blk_ctx.border_padding_top_bottom.get(elem_id) orelse BorderPaddingTopBottom{};
    const mlr = blk_ctx.margin_left_right.get(elem_id) orelse MarginLeftRight{};
    const mtb = blk_ctx.margin_top_bottom.get(elem_id) orelse MarginTopBottom{};
    const border_colors = blk_ctx.border_colors.get(elem_id) orelse BorderColor{};
    const bg_color = blk_ctx.background_color.get(elem_id) orelse BackgroundColor{};

    const border_x = state.offset_x + mlr.margin_left;
    const border_y = state.offset_y + mtb.margin_top;
    const padding_height = height.height + bptb.padding_top + bptb.padding_bottom;
    const full_width = width.width + bplr.border_left + bplr.border_right + bplr.padding_left + bplr.padding_right;
    const full_height = padding_height + bptb.border_top + bptb.border_bottom;

    const pixel_format = sdl_ctx.surface.*.format;
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
        assert(SDL_FillRect(sdl_ctx.surface, &rects[i], colors[i]) == 0);
    }

    state.offset_y = border_y + full_height + mtb.margin_bottom;
}
