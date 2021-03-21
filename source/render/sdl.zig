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

const zss = @import("../../zss.zig");
const Ratio = zss.types.Ratio;
const divCeil = zss.util.divCeil;

usingnamespace @import("SDL2");

pub fn rgbaMap(pixel_format: *SDL_PixelFormat, color: u32) [4]u8 {
    const color_le = std.mem.nativeToLittle(u32, color);
    const mapped = SDL_MapRGBA(
        pixel_format,
        @truncate(u8, color_le >> 24),
        @truncate(u8, color_le >> 16),
        @truncate(u8, color_le >> 8),
        @truncate(u8, color_le),
    );
    var rgba = @as([4]u8, undefined);
    SDL_GetRGBA(mapped, pixel_format, &rgba[0], &rgba[1], &rgba[2], &rgba[3]);
    return rgba;
}

pub const BorderWidths = struct {
    top: c_int,
    right: c_int,
    bottom: c_int,
    left: c_int,
};

pub const BorderColor = struct {
    top_rgba: c_uint,
    right_rgba: c_uint,
    bottom_rgba: c_uint,
    left_rgba: c_uint,
};

pub fn drawBordersSolid(renderer: *SDL_Renderer, pixel_format: *SDL_PixelFormat, border_rect: *const SDL_Rect, widths: *const BorderWidths, colors: *const BorderColor) void {
    const outer_left = border_rect.x;
    const inner_left = border_rect.x + widths.left;
    const inner_right = border_rect.x + border_rect.w - widths.right;
    const outer_right = border_rect.x + border_rect.w;

    const outer_top = border_rect.y;
    const inner_top = border_rect.y + widths.top;
    const inner_bottom = border_rect.y + border_rect.h - widths.bottom;
    const outer_bottom = border_rect.y + border_rect.h;

    const color_mapped = [_][4]u8{
        rgbaMap(pixel_format, colors.top_rgba),
        rgbaMap(pixel_format, colors.right_rgba),
        rgbaMap(pixel_format, colors.bottom_rgba),
        rgbaMap(pixel_format, colors.left_rgba),
    };

    const rects = [_]SDL_Rect{
        // top border
        SDL_Rect{
            .x = inner_left,
            .y = outer_top,
            .w = inner_right - inner_left,
            .h = inner_top - outer_top,
        },
        // right border
        SDL_Rect{
            .x = inner_right,
            .y = inner_top,
            .w = outer_right - inner_right,
            .h = inner_bottom - inner_top,
        },
        // bottom border
        SDL_Rect{
            .x = inner_left,
            .y = inner_bottom,
            .w = inner_right - inner_left,
            .h = outer_bottom - inner_bottom,
        },
        //left border
        SDL_Rect{
            .x = outer_left,
            .y = inner_top,
            .w = inner_left - outer_left,
            .h = inner_bottom - inner_top,
        },
    };

    comptime var i = 0;
    inline while (i < 4) : (i += 1) {
        const c = color_mapped[i];
        assert(SDL_SetRenderDrawColor(renderer, c[0], c[1], c[2], c[3]) == 0);
        assert(SDL_RenderFillRect(renderer, &rects[i]) == 0);
    }

    drawBordersSolidCorners(renderer, outer_left, inner_left, outer_top, inner_top, color_mapped[3], color_mapped[0], true);
    drawBordersSolidCorners(renderer, inner_right, outer_right, inner_bottom, outer_bottom, color_mapped[2], color_mapped[1], true);
    drawBordersSolidCorners(renderer, outer_right, inner_right, outer_top, inner_top, color_mapped[1], color_mapped[0], false);
    drawBordersSolidCorners(renderer, inner_left, outer_left, inner_bottom, outer_bottom, color_mapped[2], color_mapped[3], false);
}

// TODO This function doesn't draw in a very satisfactory way.
// It ends up making borders look asymmetrical by 1 pixel.
// It's also probably slow because it draws every point 1-by-1
// instead of drawing lines. In the future I hope to get rid of
// this function entirely, replacing it with a function that masks
// out the portion of a border image that shouldn't be drawn. This
// would allow me to draw all kinds of border styles without
// needing specific code for each one.
fn drawBordersSolidCorners(
    renderer: *SDL_Renderer,
    x1: c_int,
    x2: c_int,
    y_low: c_int,
    y_high: c_int,
    first_color: [4]u8,
    second_color: [4]u8,
    comptime isTopLeftOrBottomRight: bool,
) void {
    const dx = if (isTopLeftOrBottomRight) x2 - x1 else x1 - x2;
    const dy = y_high - y_low;

    if (isTopLeftOrBottomRight) {
        var x = x1;
        while (x < x2) : (x += 1) {
            const num = (x - x1) * dy;
            const mod = @mod(num, dx);
            const y = y_low + @divFloor(num, dx) + @boolToInt(2 * mod >= dx);
            drawVerticalLine(renderer, x, y, y_low, y_high, first_color, second_color);
        }
    } else {
        var x = x2;
        while (x < x1) : (x += 1) {
            const num = (x1 - 1 - x) * dy;
            const mod = @mod(num, dx);
            const y = y_low + @divFloor(num, dx) + @boolToInt(2 * mod >= dx);
            drawVerticalLine(renderer, x, y, y_low, y_high, first_color, second_color);
        }
    }
}

fn drawVerticalLine(renderer: *SDL_Renderer, x: c_int, y: c_int, y_low: c_int, y_high: c_int, first_color: [4]u8, second_color: [4]u8) void {
    assert(SDL_SetRenderDrawColor(renderer, first_color[0], first_color[1], first_color[2], first_color[3]) == 0);
    var i = y;
    while (i < y_high) : (i += 1) {
        assert(SDL_RenderDrawPoint(renderer, x, i) == 0);
    }

    assert(SDL_SetRenderDrawColor(renderer, second_color[0], second_color[1], second_color[2], second_color[3]) == 0);
    i = y_low;
    while (i < y) : (i += 1) {
        assert(SDL_RenderDrawPoint(renderer, x, i) == 0);
    }
}

pub fn drawBackgroundColor(
    renderer: *SDL_Renderer,
    pixel_format: *SDL_PixelFormat,
    painting_area: SDL_Rect,
    color_rgba: u32,
) void {
    const color_mapped = rgbaMap(pixel_format, color_rgba);
    assert(SDL_SetRenderDrawColor(renderer, color_mapped[0], color_mapped[1], color_mapped[2], color_mapped[3]) == 0);
    assert(SDL_RenderFillRect(renderer, &painting_area) == 0);
}

/// Represents one of the ways in which background images can be repeated.
/// Note that "background-repeat: round" is not explicitly supported, but can
/// be achieved by first resizing the image and using '.Repeat'.
pub const Repeat = enum { NoRepeat, Repeat, Space };

pub fn drawBackgroundImage(
    renderer: *SDL_Renderer,
    texture: *SDL_Texture,
    positioning_area: SDL_Rect,
    painting_area: SDL_Rect,
    position: SDL_Point,
    size: SDL_Point,
    repeat: struct { x: Repeat, y: Repeat },
) void {
    if (size.x == 0 or size.y == 0) return;
    const dimensions = blk: {
        var w: c_int = undefined;
        var h: c_int = undefined;
        assert(SDL_QueryTexture(texture, null, null, &w, &h) == 0);
        break :blk .{ .w = w, .h = h };
    };
    if (dimensions.w == 0 or dimensions.h == 0) return;

    const info_x = getBackgroundImageRepeatInfo(
        repeat.x,
        @intCast(c_uint, painting_area.w),
        positioning_area.x - painting_area.x,
        @intCast(c_uint, positioning_area.w),
        position.x - positioning_area.x,
        @intCast(c_uint, size.x),
    );
    const info_y = getBackgroundImageRepeatInfo(
        repeat.y,
        @intCast(c_uint, painting_area.h),
        positioning_area.y - painting_area.y,
        @intCast(c_uint, positioning_area.h),
        position.y - positioning_area.y,
        @intCast(c_uint, size.y),
    );

    var i: c_int = info_x.start_index;
    while (i < info_x.start_index + @intCast(c_int, info_x.count)) : (i += 1) {
        var j: c_int = info_y.start_index;
        while (j < info_y.start_index + @intCast(c_int, info_y.count)) : (j += 1) {
            const image_rect = SDL_Rect{
                .x = positioning_area.x + info_x.offset + @divFloor(i * (size.x * @intCast(c_int, info_x.space.den) + @intCast(c_int, info_x.space.num)), @intCast(c_int, info_x.space.den)),
                .y = positioning_area.y + info_y.offset + @divFloor(j * (size.y * @intCast(c_int, info_y.space.den) + @intCast(c_int, info_y.space.num)), @intCast(c_int, info_y.space.den)),
                .w = size.x,
                .h = size.y,
            };
            var intersection = @as(SDL_Rect, undefined);
            // TODO check this assertion
            assert(SDL_IntersectRect(&painting_area, &image_rect, &intersection) == .SDL_TRUE);
            assert(SDL_RenderCopy(
                renderer,
                texture,
                &SDL_Rect{
                    .x = @divFloor((intersection.x - image_rect.x) * dimensions.w, size.x),
                    .y = @divFloor((intersection.y - image_rect.y) * dimensions.h, size.y),
                    .w = @divFloor(intersection.w * dimensions.w, size.x),
                    .h = @divFloor(intersection.h * dimensions.h, size.y),
                },
                &intersection,
            ) == 0);
        }
    }
}

fn getBackgroundImageRepeatInfo(
    repeat: Repeat,
    painting_area_size: c_uint,
    positioning_area_offset: c_int,
    positioning_area_size: c_uint,
    image_offset: c_int,
    image_size: c_uint,
) struct {
    count: c_uint,
    space: Ratio(c_uint),
    offset: c_int,
    start_index: c_int,
} {
    return switch (repeat) {
        .NoRepeat => .{
            .count = 1,
            .space = Ratio(c_uint){ .num = 0, .den = 1 },
            .offset = image_offset,
            .start_index = 0,
        },
        .Repeat => blk: {
            const before = divCeil(c_int, image_offset + positioning_area_offset, @intCast(c_int, image_size));
            const after = divCeil(c_int, @intCast(c_int, painting_area_size) - positioning_area_offset - image_offset - @intCast(c_int, image_size), @intCast(c_int, image_size));
            break :blk .{
                .count = @intCast(c_uint, before + after + 1),
                .space = Ratio(c_uint){ .num = 0, .den = 1 },
                .offset = image_offset,
                .start_index = -before,
            };
        },
        .Space => blk: {
            const positioning_area_count = positioning_area_size / image_size;
            const space = positioning_area_size % image_size;
            const before = divCeil(c_int, @intCast(c_int, positioning_area_count) * positioning_area_offset, @intCast(c_int, positioning_area_size));
            const after = divCeil(c_int, @intCast(c_int, positioning_area_size) * (@intCast(c_int, painting_area_size) - @intCast(c_int, positioning_area_size) - positioning_area_offset), @intCast(c_int, positioning_area_size));
            const count = @intCast(c_uint, before + after + @intCast(c_int, std.math.max(1, positioning_area_count)));
            break :blk .{
                .count = count,
                .space = Ratio(c_uint){ .num = space, .den = std.math.max(2, positioning_area_count) - 1 },
                .offset = image_offset * @boolToInt(count == 1),
                .start_index = -before,
            };
        },
    };
}
