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

const zss = @import("zss");
const CSSRect = zss.types.CSSRect;
const Offset = zss.types.Offset;
const InlineRenderingContext = zss.InlineRenderingContext;
const BoxMeasures = InlineRenderingContext.BoxMeasures;

const sdl = @import("SDL2");
const render_sdl = @import("./render_sdl.zig");

pub fn drawInlineContext(
    context: *const InlineRenderingContext,
    cumulative_offset: Offset,
    renderer: *sdl.SDL_Renderer,
    pixel_format: *sdl.SDL_PixelFormat,
) void {
    for (context.fragments) |fragment| {
        const box_id = fragment.inline_box_id;

        const top: BoxMeasures = if (context.include_top) context.measures_top[box_id] else .{ .border = 0, .margin = 0, .border_color_rgba = 0 };
        const right: BoxMeasures = if (context.include_right) context.measures_right[box_id] else .{ .border = 0, .margin = 0, .border_color_rgba = 0 };
        const bottom: BoxMeasures = if (context.include_bottom) context.measures_bottom[box_id] else .{ .border = 0, .margin = 0, .border_color_rgba = 0 };
        const left: BoxMeasures = if (context.include_left) context.measures_left[box_id] else .{ .border = 0, .margin = 0, .border_color_rgba = 0 };
        const background_color = context.background_color[box_id];
        //const background_image = context.background_image[box_id];

        const border_rect = CSSRect{
            .x = cumulative_offset.x + fragment.offset.x,
            .y = cumulative_offset.y + fragment.offset.y,
            .w = left.border + left.padding + fragment.width + right.padding + right.border,
            .h = top.border + top.padding + fragment.height + bottom.padding + bottom.border,
        };
        const painting_area = border_rect;
        //const painting_area = switch (background_image.clip) {
        //    .Border => border_rect,
        //    .Padding => CSSRect{
        //        .x = border_rect.x + left.border,
        //        .y = border_rect.y + top.border,
        //        .w = left.padding + fragment.width + right.padding,
        //        .h = top.padding + fragment.height + bottom.padding,
        //    },
        //    .Context => CSSRect{
        //        .x = border_rect.x + left.border + left.padding,
        //        .y = border_rect.y + top.border + top.padding,
        //        .w = fragment.width,
        //        .h = fragment.height,
        //    },
        //};

        zss.sdl.drawBackgroundColor(renderer, pixel_format, render_sdl.cssRectToSdlRect(painting_area), background_color.rgba);

        const should_draw_borders = fragment.include_top or fragment.include_right or fragment.include_bottom or fragment.include_left;
        if (should_draw_borders)
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
}
