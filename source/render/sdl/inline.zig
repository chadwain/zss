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
const CSSUnit = zss.types.CSSUnit;
const InlineFormattingContext = zss.InlineFormattingContext;
const TreeNode = @TypeOf(@as(InlineFormattingContext, undefined).tree);
const Offset = zss.types.Offset;
const cssUnitToSdlPixel = zss.sdl.cssUnitToSdlPixel;
const rgbaMap = zss.sdl.rgbaMap;
usingnamespace zss.properties;

usingnamespace @import("SDL2");
const ft = @import("freetype");

const StackItem = struct {
    id_part: InlineFormattingContext.IdPart,
    node: ?*const TreeNode,
};

pub const DrawInlineState = struct {
    context: *const InlineFormattingContext,
    stack: ArrayList(?StackItem),
    id: ArrayList(InlineFormattingContext.IdPart),

    pub fn init(context: *const InlineFormattingContext, allocator: *Allocator) !@This() {
        var result = @This(){
            .context = context,
            .stack = ArrayList(?StackItem).init(allocator),
            .id = ArrayList(InlineFormattingContext.IdPart).init(allocator),
        };

        try addChildrenToStack(&result.stack, &result.context.tree);
        return result;
    }

    pub fn deinit(self: *@This()) void {
        self.stack.deinit();
        self.id.deinit();
    }
};

// TODO According to §Appendix E Step 7.2.1, the elements of inline contexts
// are not drawn in tree order, but rather line box order then tree order.
pub fn drawInlineContext(
    context: *const InlineFormattingContext,
    allocator: *Allocator,
    offset: Offset,
    renderer: *SDL_Renderer,
    pixel_format: *SDL_PixelFormat,
) !void {
    var state = try DrawInlineState.init(context, allocator);
    defer state.deinit();

    const stack = &state.stack;
    const id = &state.id;
    while (stack.items.len > 0) {
        const item = stack.pop() orelse {
            _ = id.pop();
            continue;
        };
        try id.append(item.id_part);
        try drawInlineElement(state.context, id.items, renderer, pixel_format, offset);

        const node = item.node orelse continue;
        try addChildrenToStack(stack, node);
    }
}

fn addChildrenToStack(
    stack: *ArrayList(?StackItem),
    node: *const TreeNode,
) !void {
    const prev_len = stack.items.len;
    const num_children = node.numChildren();
    try stack.resize(prev_len + 2 * num_children);

    var i: usize = 0;
    while (i < num_children) : (i += 1) {
        const dest = stack.items[prev_len..][2 * (num_children - 1 - i) ..][0..2];
        dest[0] = null;
        dest[1] = StackItem{
            .id_part = node.parts.items[i],
            .node = node.child(i),
        };
    }
}

fn drawInlineElement(
    context: *const InlineFormattingContext,
    id: InlineFormattingContext.Id,
    renderer: *SDL_Renderer,
    pixel_format: *SDL_PixelFormat,
    offset: Offset,
) !void {
    const dimension = context.get(id, .dimension);
    const mbplr = context.get(id, .margin_border_padding_left_right);
    const mbptb = context.get(id, .margin_border_padding_top_bottom);
    const border_colors = context.get(id, .border_colors);
    const bg_color = context.get(id, .background_color);
    const position = context.get(id, .position);
    const data = context.get(id, .data);

    const line_box = context.line_boxes.items[position.line_box_index];
    const baseline = offset.y + line_box.y_pos + line_box.baseline;
    const ascender_top = baseline - position.ascender;

    const margin_x = offset.x + position.advance;
    // NOTE This makes the assumption that the top of the content box equals the top of the ascender
    const content_y = ascender_top;
    const border_x = margin_x + mbplr.margin_left;
    const border_y = content_y - mbptb.padding_top - mbptb.border_top;
    const padding_height = dimension.height + mbptb.padding_top + mbptb.padding_bottom;
    const full_width = dimension.width + mbplr.border_left + mbplr.border_right + mbplr.padding_left + mbplr.padding_right;
    const full_height = padding_height + mbptb.border_top + mbptb.border_bottom;

    const colors = [_][4]u8{
        rgbaMap(pixel_format, bg_color.rgba),
        rgbaMap(pixel_format, border_colors.top_rgba),
        rgbaMap(pixel_format, border_colors.right_rgba),
        rgbaMap(pixel_format, border_colors.bottom_rgba),
        rgbaMap(pixel_format, border_colors.left_rgba),
    };

    const rects = [_]SDL_Rect{
        // background
        SDL_Rect{
            .x = cssUnitToSdlPixel(border_x),
            .y = cssUnitToSdlPixel(border_y),
            .w = cssUnitToSdlPixel(full_width),
            .h = cssUnitToSdlPixel(full_height),
        },
        // top border
        SDL_Rect{
            .x = cssUnitToSdlPixel(border_x),
            .y = cssUnitToSdlPixel(border_y),
            .w = cssUnitToSdlPixel(full_width),
            .h = cssUnitToSdlPixel(mbptb.border_top),
        },
        // right border
        SDL_Rect{
            .x = cssUnitToSdlPixel(border_x + full_width - mbplr.border_right),
            .y = cssUnitToSdlPixel(border_y + mbptb.border_top),
            .w = cssUnitToSdlPixel(mbplr.border_right),
            .h = cssUnitToSdlPixel(padding_height),
        },
        // bottom border
        SDL_Rect{
            .x = cssUnitToSdlPixel(border_x),
            .y = cssUnitToSdlPixel(border_y + full_height - mbptb.border_bottom),
            .w = cssUnitToSdlPixel(full_width),
            .h = cssUnitToSdlPixel(mbptb.border_bottom),
        },
        //left border
        SDL_Rect{
            .x = cssUnitToSdlPixel(border_x),
            .y = cssUnitToSdlPixel(border_y + mbptb.border_top),
            .w = cssUnitToSdlPixel(mbplr.border_left),
            .h = cssUnitToSdlPixel(padding_height),
        },
    };

    for (rects) |_, i| {
        const c = colors[i];
        assert(SDL_SetRenderDrawColor(renderer, c[0], c[1], c[2], c[3]) == 0);
        assert(SDL_RenderFillRect(renderer, &rects[i]) == 0);
    }

    try drawInlineElementData(
        data,
        baseline,
        renderer,
        pixel_format,
        Offset{ .x = border_x + mbplr.border_left + mbplr.padding_left, .y = content_y },
    );
}

fn drawInlineElementData(
    data: InlineFormattingContext.Data,
    line_box_baseline: CSSUnit,
    renderer: *SDL_Renderer,
    pixel_format: *SDL_PixelFormat,
    offset: Offset,
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
                        .x = cssUnitToSdlPixel(offset.x) + g.*.left,
                        .y = cssUnitToSdlPixel(line_box_baseline) - g.*.top,
                        .w = glyph_surface.*.w,
                        .h = glyph_surface.*.h,
                    },
                ) == 0);
            }
        },
    }
}

// TODO Find a better way to render glyphs than to allocate a new surface
fn makeGlyphSurface(bitmap: ft.FT_Bitmap, pixel_format: *SDL_PixelFormat) error{OutOfMemory}!*SDL_Surface {
    assert(bitmap.pixel_mode == ft.FT_PIXEL_MODE_GRAY);
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
            dest_row[i] = SDL_MapRGBA(pixel_format, 0xff, 0xff, 0xff, src_row[i]);
        }
    }
    return result;
}
