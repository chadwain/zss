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
const hb = zss.harfbuzz.harfbuzz;

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const assert = std.debug.assert;

const zss = @import("../../../zss.zig");
const RenderTree = zss.RenderTree;
const InlineFormattingContext = zss.InlineFormattingContext;
const rgbaMap = zss.sdl.rgbaMap;
usingnamespace zss.properties;

const InlineRenderState = struct {
    offset_x: CSSUnit,
    offset_y: CSSUnit,
};

const StackItem = struct {
    value: RenderTree.BoxId,
    node: ?*InlineFormattingContext.Tree,
};

pub fn renderInlineFormattingContext(
    inl_ctx: InlineFormattingContext,
    allocator: *Allocator,
    renderer: *SDL_Renderer,
    pixel_format: *SDL_PixelFormat,
    state: InlineRenderState,
) !void {
    var stack = ArrayList(StackItem).init(allocator);
    defer stack.deinit();

    try addChildrenToStack(&stack, inl_ctx, inl_ctx.tree);

    while (stack.items.len > 0) {
        const item = stack.pop();
        try renderInlineElement(inl_ctx, item.value, renderer, pixel_format, state);

        const node = item.node orelse continue;
        try addChildrenToStack(&stack, inl_ctx, node);
    }
}

fn addChildrenToStack(
    stack: *ArrayList(StackItem),
    inl_ctx: InlineFormattingContext,
    node: *InlineFormattingContext.Tree,
) !void {
    const prev_len = stack.items.len;
    const num_children = node.numChildren();
    try stack.resize(prev_len + num_children);

    var i: usize = 0;
    while (i < num_children) : (i += 1) {
        const dest = &stack.items[prev_len..][num_children - 1 - i];
        dest.* = .{
            .value = node.value(i),
            .node = node.child(i),
        };
    }
}

fn renderInlineElement(
    inl_ctx: InlineFormattingContext,
    elem_id: RenderTree.BoxId,
    renderer: *SDL_Renderer,
    pixel_format: *SDL_PixelFormat,
    state: InlineRenderState,
) !void {
    const width = inl_ctx.get(elem_id, .width);
    const height = inl_ctx.get(elem_id, .height);
    const mbplr = inl_ctx.get(elem_id, .margin_border_padding_left_right);
    const mbptb = inl_ctx.get(elem_id, .margin_border_padding_top_bottom);
    const border_colors = inl_ctx.get(elem_id, .border_colors);
    const bg_color = inl_ctx.get(elem_id, .background_color);
    const position = inl_ctx.get(elem_id, .position);
    const data = inl_ctx.get(elem_id, .data);

    const line_box = inl_ctx.line_boxes.items[position.line_box_index];
    const baseline = state.offset_y + line_box.y_pos + line_box.baseline;
    const ascender_top = baseline - position.ascender;

    const margin_x = state.offset_x + position.advance;
    // NOTE This makes the assumption that the top of the content box equals the top of the ascender
    const content_y = ascender_top;
    const border_x = margin_x + mbplr.margin_left;
    const border_y = content_y - mbptb.padding_top - mbptb.border_top;
    const padding_height = height.height + mbptb.padding_top + mbptb.padding_bottom;
    const full_width = width.width + mbplr.border_left + mbplr.border_right + mbplr.padding_left + mbplr.padding_right;
    const full_height = padding_height + mbptb.border_top + mbptb.border_bottom;

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
        var rgba: [4]u8 = undefined;
        SDL_GetRGBA(colors[i], pixel_format, &rgba[0], &rgba[1], &rgba[2], &rgba[3]);
        assert(SDL_SetRenderDrawColor(renderer, rgba[0], rgba[1], rgba[2], rgba[3]) == 0);
        assert(SDL_RenderFillRect(renderer, &rects[i]) == 0);
    }

    try renderInlineElementData(
        data,
        .{ .x = border_x + mbplr.border_left + mbplr.padding_left, .y = content_y },
        baseline,
        renderer,
        pixel_format,
    );
}

fn renderInlineElementData(
    data: InlineFormattingContext.Data,
    offsets: struct { x: CSSUnit, y: CSSUnit },
    line_box_baseline: CSSUnit,
    renderer: *SDL_Renderer,
    pixel_format: *SDL_PixelFormat,
) !void {
    switch (data) {
        .empty_space => {},
        .text => |glyphs| {
            const texture = SDL_GetRenderTarget(renderer);

            for (glyphs) |g| {
                const glyph_surface = try makeGlyphSurface(g.*.bitmap, pixel_format);
                defer SDL_FreeSurface(glyph_surface);

                const glyph_texture = SDL_CreateTextureFromSurface(renderer, glyph_surface) orelse return error.OutOfMemory;
                // NOTE Is it a bug to destroy this texture before calling SDL_RenderPresent?
                defer SDL_DestroyTexture(glyph_texture);

                assert(SDL_RenderCopy(
                    renderer,
                    glyph_texture,
                    null,
                    &SDL_Rect{
                        .x = offsets.x + g.*.left,
                        .y = line_box_baseline - g.*.top,
                        .w = glyph_surface.*.w,
                        .h = glyph_surface.*.h,
                    },
                ) == 0);
            }
        },
    }
}

// TODO Find a better way to render glyphs than to allocate a new surface
fn makeGlyphSurface(bitmap: hb.FT_Bitmap, pixel_format: *SDL_PixelFormat) error{OutOfMemory}!*SDL_Surface {
    assert(bitmap.pixel_mode == hb.FT_PIXEL_MODE_GRAY);
    const result = SDL_CreateRGBSurfaceWithFormat(
        0,
        @intCast(c_int, bitmap.width),
        @intCast(c_int, bitmap.rows),
        32,
        pixel_format.*.format,
    ) orelse return error.OutOfMemory;

    var src_index: usize = 0;
    var dest_index: usize = 0;
    while (dest_index < result.*.pitch * result.*.h) : ({
        dest_index += @intCast(usize, result.*.pitch);
        src_index += @intCast(usize, bitmap.pitch);
    }) {
        const src_row = bitmap.buffer[src_index .. src_index + bitmap.width];
        const dest_row = @ptrCast([*]u32, @alignCast(4, @ptrCast([*]u8, result.*.pixels.?) + dest_index))[0..bitmap.width];
        for (src_row) |_, i| {
            dest_row[i] = rgbaMap(pixel_format, @as(u32, 0xffffff00) | src_row[i]);
        }
    }
    return result;
}
