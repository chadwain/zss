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
const assert = std.debug.assert;

const zss = @import("zss");
const CSSUnit = zss.types.CSSUnit;
const CSSRect = zss.types.CSSRect;
const Offset = zss.types.Offset;
const InlineRenderingContext = zss.InlineRenderingContext;
const BoxMeasures = InlineRenderingContext.BoxMeasures;
const Text = InlineRenderingContext.InlineBoxFragment.Text;

const sdl = @import("SDL2");
const hb = @import("harfbuzz");
const render_sdl = @import("./render_sdl.zig");

pub fn drawInlineContext(
    context: *const InlineRenderingContext,
    cumulative_offset: Offset,
    renderer: *sdl.SDL_Renderer,
    pixel_format: *sdl.SDL_PixelFormat,
) void {
    for (context.fragments) |fragment| {
        const box_id = fragment.inline_box_id;

        const top: BoxMeasures = if (fragment.include_top) context.measures_top[box_id] else .{ .border = 0, .padding = 0, .border_color_rgba = 0 };
        const right: BoxMeasures = if (fragment.include_right) context.measures_right[box_id] else .{ .border = 0, .padding = 0, .border_color_rgba = 0 };
        const bottom: BoxMeasures = if (fragment.include_bottom) context.measures_bottom[box_id] else .{ .border = 0, .padding = 0, .border_color_rgba = 0 };
        const left: BoxMeasures = if (fragment.include_left) context.measures_left[box_id] else .{ .border = 0, .padding = 0, .border_color_rgba = 0 };
        const heights = context.heights[box_id];
        const background_color = context.background_color[box_id];
        //const background_image = context.background_image[box_id];
        const baseline = cumulative_offset.add(fragment.baseline_pos);

        const content_rect = CSSRect{
            .x = cumulative_offset.x + baseline.x,
            .y = cumulative_offset.y + baseline.y - heights.above_baseline,
            .w = fragment.width,
            .h = heights.above_baseline + heights.below_baseline,
        };
        const border_rect = CSSRect{
            .x = content_rect.x - left.padding - left.border,
            .y = content_rect.y - top.padding - top.border,
            .w = left.border + left.padding + fragment.width + right.padding + right.border,
            .h = top.border + top.padding + content_rect.h + bottom.padding + bottom.border,
        };
        // TODO const painting_area = switch (background_image.clip) { ... };
        const painting_area = border_rect;

        zss.sdl.drawBackgroundColor(renderer, pixel_format, render_sdl.cssRectToSdlRect(painting_area), background_color.rgba);

        const should_draw_borders = fragment.include_top or fragment.include_right or fragment.include_bottom or fragment.include_left;
        if (should_draw_borders) {
            zss.sdl.drawBordersSolid(
                renderer,
                pixel_format,
                &render_sdl.cssRectToSdlRect(border_rect),
                &zss.sdl.BorderWidths{
                    .top = render_sdl.cssUnitToSdlPixel(top.border),
                    .right = render_sdl.cssUnitToSdlPixel(right.border),
                    .bottom = render_sdl.cssUnitToSdlPixel(bottom.border),
                    .left = render_sdl.cssUnitToSdlPixel(left.border),
                },
                &zss.sdl.BorderColor{
                    .top_rgba = top.border_color_rgba,
                    .right_rgba = right.border_color_rgba,
                    .bottom_rgba = bottom.border_color_rgba,
                    .left_rgba = left.border_color_rgba,
                },
            );
        }

        if (fragment.text) |text| {
            drawTextHorizontally(text, baseline, renderer, pixel_format);
        }
    }
}

fn addCSSUnitAndHarfBuzzUnitToSdlPixel(css: CSSUnit, harf: hb.hb_position_t) i32 {
    return css + @divFloor(harf, 64);
}

fn drawTextHorizontally(text: Text, baseline: Offset, renderer: *sdl.SDL_Renderer, pixel_format: *sdl.SDL_PixelFormat) void {
    const face = hb.hb_ft_font_get_face(text.font);
    var cursor: c_int = 0;
    for (text.infos) |_, i| {
        const codepoint = text.infos[i].codepoint;
        const position = text.positions[i];
        assert(hb.FT_Load_Glyph(face, codepoint, hb.FT_LOAD_DEFAULT | hb.FT_LOAD_NO_HINTING) == hb.FT_Err_Ok);
        assert(hb.FT_Render_Glyph(face.*.glyph, hb.FT_Render_Mode.FT_RENDER_MODE_NORMAL) == 0);

        const final_position = sdl.SDL_Point{
            .x = addCSSUnitAndHarfBuzzUnitToSdlPixel(baseline.x, cursor + position.x_offset),
            .y = addCSSUnitAndHarfBuzzUnitToSdlPixel(baseline.y - face.*.glyph.*.bitmap_top, position.y_offset),
        };
        drawGlyph(face.*.glyph.*.bitmap, final_position, renderer, pixel_format);
        cursor += position.x_advance;
    }
}

fn drawGlyph(bitmap: hb.FT_Bitmap, position: sdl.SDL_Point, renderer: *sdl.SDL_Renderer, pixel_format: *sdl.SDL_PixelFormat) void {
    const glyph_surface = makeGlyphSurface(bitmap, pixel_format) catch @panic("TODO unhandled out of memory error");
    defer sdl.SDL_FreeSurface(glyph_surface);

    const glyph_texture = sdl.SDL_CreateTextureFromSurface(renderer, glyph_surface) orelse @panic("TODO unhandled out of memory error");
    // NOTE Is it a bug to destroy this texture before calling SDL_RenderPresent?
    defer sdl.SDL_DestroyTexture(glyph_texture);

    assert(sdl.SDL_RenderCopy(renderer, glyph_texture, null, &sdl.SDL_Rect{
        .x = position.x,
        .y = position.y,
        .w = glyph_surface.*.w,
        .h = glyph_surface.*.h,
    }) == 0);
}

// TODO Find a better way to render glyphs than to allocate a new surface
fn makeGlyphSurface(bitmap: hb.FT_Bitmap, pixel_format: *sdl.SDL_PixelFormat) error{OutOfMemory}!*sdl.SDL_Surface {
    assert(bitmap.pixel_mode == hb.FT_PIXEL_MODE_GRAY);
    const result = sdl.SDL_CreateRGBSurfaceWithFormat(
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
            dest_row[i] = sdl.SDL_MapRGBA(pixel_format, 0xff, 0xff, 0xff, src_row[i]);
        }
    }
    return result;
}
