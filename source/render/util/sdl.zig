const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const zss = @import("../../../zss.zig");
const UsedId = zss.used_values.UsedId;
const ZssUnit = zss.used_values.ZssUnit;
const ZssVector = zss.used_values.ZssVector;
const ZssFlowRelativeVector = zss.used_values.ZssFlowRelativeVector;
const ZssRect = zss.used_values.ZssRect;
const BlockLevelUsedValues = zss.used_values.BlockLevelUsedValues;
const InlineLevelUsedValues = zss.used_values.InlineLevelUsedValues;

const sdl = @import("SDL2");

pub fn zssUnitToPixel(unit: ZssUnit) i32 {
    return @divFloor(unit, zss.used_values.unitsPerPixel);
}

pub fn pixelToZssUnit(pixels: c_int) ZssUnit {
    return pixels * zss.used_values.unitsPerPixel;
}

pub fn sdlPointToZssVector(point: sdl.SDL_Point) ZssVector {
    return ZssVector{
        .x = pixelToZssUnit(point.x),
        .y = pixelToZssUnit(point.y),
    };
}

pub fn sdlRectToZssRect(rect: sdl.SDL_Rect) ZssRect {
    return ZssRect{
        .x = pixelToZssUnit(rect.x),
        .y = pixelToZssUnit(rect.y),
        .w = pixelToZssUnit(rect.w),
        .h = pixelToZssUnit(rect.h),
    };
}

pub fn zssRectToSdlRect(rect: ZssRect) sdl.SDL_Rect {
    return sdl.SDL_Rect{
        .x = zssUnitToPixel(rect.x),
        .y = zssUnitToPixel(rect.y),
        .w = zssUnitToPixel(rect.w),
        .h = zssUnitToPixel(rect.h),
    };
}

// The only supported writing mode is horizontal-tb, so this function
// lets us ignore the logical coords and move into physical coords.
pub fn zssFlowRelativeVectorToZssVector(flow_vector: ZssFlowRelativeVector) ZssVector {
    return ZssVector{
        .x = flow_vector.inline_dir,
        .y = flow_vector.block_dir,
    };
}

pub fn rgbaMap(pixel_format: *sdl.SDL_PixelFormat, color: u32) [4]u8 {
    const color_le = std.mem.nativeToLittle(u32, color);
    const mapped = sdl.SDL_MapRGBA(
        pixel_format,
        @truncate(u8, color_le >> 24),
        @truncate(u8, color_le >> 16),
        @truncate(u8, color_le >> 8),
        @truncate(u8, color_le),
    );
    var rgba = @as([4]u8, undefined);
    sdl.SDL_GetRGBA(mapped, pixel_format, &rgba[0], &rgba[1], &rgba[2], &rgba[3]);
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

pub fn drawBordersSolid(renderer: *sdl.SDL_Renderer, pixel_format: *sdl.SDL_PixelFormat, border_rect: *const sdl.SDL_Rect, widths: *const BorderWidths, colors: *const BorderColor) void {
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

    const rects = [_]sdl.SDL_Rect{
        // top border
        sdl.SDL_Rect{
            .x = inner_left,
            .y = outer_top,
            .w = inner_right - inner_left,
            .h = inner_top - outer_top,
        },
        // right border
        sdl.SDL_Rect{
            .x = inner_right,
            .y = inner_top,
            .w = outer_right - inner_right,
            .h = inner_bottom - inner_top,
        },
        // bottom border
        sdl.SDL_Rect{
            .x = inner_left,
            .y = inner_bottom,
            .w = inner_right - inner_left,
            .h = outer_bottom - inner_bottom,
        },
        //left border
        sdl.SDL_Rect{
            .x = outer_left,
            .y = inner_top,
            .w = inner_left - outer_left,
            .h = inner_bottom - inner_top,
        },
    };

    comptime var i = 0;
    inline while (i < 4) : (i += 1) {
        const c = color_mapped[i];
        assert(sdl.SDL_SetRenderDrawColor(renderer, c[0], c[1], c[2], c[3]) == 0);
        assert(sdl.SDL_RenderFillRect(renderer, &rects[i]) == 0);
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
    renderer: *sdl.SDL_Renderer,
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

fn drawVerticalLine(renderer: *sdl.SDL_Renderer, x: c_int, y: c_int, y_low: c_int, y_high: c_int, first_color: [4]u8, second_color: [4]u8) void {
    assert(sdl.SDL_SetRenderDrawColor(renderer, first_color[0], first_color[1], first_color[2], first_color[3]) == 0);
    var i = y;
    while (i < y_high) : (i += 1) {
        assert(sdl.SDL_RenderDrawPoint(renderer, x, i) == 0);
    }

    assert(sdl.SDL_SetRenderDrawColor(renderer, second_color[0], second_color[1], second_color[2], second_color[3]) == 0);
    i = y_low;
    while (i < y) : (i += 1) {
        assert(sdl.SDL_RenderDrawPoint(renderer, x, i) == 0);
    }
}

pub fn drawBackgroundColor(
    renderer: *sdl.SDL_Renderer,
    pixel_format: *sdl.SDL_PixelFormat,
    painting_area: sdl.SDL_Rect,
    color_rgba: u32,
) void {
    const color_mapped = rgbaMap(pixel_format, color_rgba);
    assert(sdl.SDL_SetRenderDrawColor(renderer, color_mapped[0], color_mapped[1], color_mapped[2], color_mapped[3]) == 0);
    assert(sdl.SDL_RenderFillRect(renderer, &painting_area) == 0);
}

pub const ImageSize = struct {
    w: c_int,
    h: c_int,
};

pub fn drawBackgroundImage(
    renderer: *sdl.SDL_Renderer,
    texture: *sdl.SDL_Texture,
    positioning_area: sdl.SDL_Rect,
    painting_area: sdl.SDL_Rect,
    position: sdl.SDL_Point,
    size: ImageSize,
    repeat: zss.used_values.Background2.Repeat,
) void {
    if (size.w == 0 or size.h == 0) return;
    const unscaled_size = blk: {
        var w: c_int = undefined;
        var h: c_int = undefined;
        assert(sdl.SDL_QueryTexture(texture, null, null, &w, &h) == 0);
        break :blk .{ .w = w, .h = h };
    };
    if (unscaled_size.w == 0 or unscaled_size.h == 0) return;

    const info_x = getBackgroundImageRepeatInfo(
        repeat.x,
        painting_area.w,
        positioning_area.x - painting_area.x,
        positioning_area.w,
        position.x - positioning_area.x,
        size.w,
    );
    const info_y = getBackgroundImageRepeatInfo(
        repeat.y,
        painting_area.h,
        positioning_area.y - painting_area.y,
        positioning_area.h,
        position.y - positioning_area.y,
        size.h,
    );

    var i = info_x.start_index;
    while (i < info_x.start_index + info_x.count) : (i += 1) {
        var j = info_y.start_index;
        while (j < info_y.start_index + info_y.count) : (j += 1) {
            const image_rect = sdl.SDL_Rect{
                .x = positioning_area.x + info_x.offset + @divFloor(i * (size.w * info_x.space.den + info_x.space.num), info_x.space.den),
                .y = positioning_area.y + info_y.offset + @divFloor(j * (size.h * info_y.space.den + info_y.space.num), info_y.space.den),
                .w = size.w,
                .h = size.h,
            };
            var intersection = @as(sdl.SDL_Rect, undefined);
            // getBackgroundImageRepeatInfo should never return info that would make us draw
            // an image that is completely outside of the background painting area.
            assert(sdl.SDL_IntersectRect(&painting_area, &image_rect, &intersection) == .SDL_TRUE);
            assert(sdl.SDL_RenderCopy(
                renderer,
                texture,
                &sdl.SDL_Rect{
                    .x = @divFloor((intersection.x - image_rect.x) * unscaled_size.w, size.w),
                    .y = @divFloor((intersection.y - image_rect.y) * unscaled_size.h, size.h),
                    .w = @divFloor(intersection.w * unscaled_size.w, size.w),
                    .h = @divFloor(intersection.h * unscaled_size.h, size.h),
                },
                &intersection,
            ) == 0);
        }
    }
}

const GetBackgroundImageRepeatInfoReturnType = struct {
    /// The index of the left-most/top-most image to be drawn.
    start_index: c_int,
    /// The number of images to draw. Always positive.
    count: c_int,
    /// The amount of space to leave between each image. Always positive.
    space: zss.util.Ratio(c_int),
    /// The offset of the top/left of the image with index 0 from the top/left of the positioning area.
    offset: c_int,
};

fn getBackgroundImageRepeatInfo(
    repeat: zss.used_values.Background2.Repeat.Style,
    /// Must be greater than or equal to 0.
    painting_area_size: c_int,
    /// The offset of the top/left of the positioning area from the top/left of the painting area.
    positioning_area_offset: c_int,
    /// Must be greater than or equal to 0.
    positioning_area_size: c_int,
    /// The offset of the top/left of the image with index 0 from the top/left of the positioning area.
    image_offset: c_int,
    /// Must be strictly greater than 0.
    image_size: c_int,
) GetBackgroundImageRepeatInfoReturnType {
    return switch (repeat) {
        .None => .{
            .start_index = 0,
            .count = 1,
            .space = zss.util.Ratio(c_int){ .num = 0, .den = 1 },
            .offset = image_offset,
        },
        .Repeat => blk: {
            const before = zss.util.divCeil(image_offset + positioning_area_offset, image_size);
            const after = zss.util.divCeil(painting_area_size - positioning_area_offset - image_offset - image_size, image_size);
            break :blk .{
                .start_index = -before,
                .count = before + after + 1,
                .space = zss.util.Ratio(c_int){ .num = 0, .den = 1 },
                .offset = image_offset,
            };
        },
        .Space => blk: {
            const positioning_area_count = @divFloor(positioning_area_size, image_size);
            if (positioning_area_count <= 1) {
                break :blk GetBackgroundImageRepeatInfoReturnType{
                    .start_index = 0,
                    .count = 1,
                    .space = zss.util.Ratio(c_int){ .num = 0, .den = 1 },
                    .offset = image_offset,
                };
            } else {
                const space = @mod(positioning_area_size, image_size);
                const before = zss.util.divCeil(
                    (positioning_area_count - 1) * positioning_area_offset - space,
                    positioning_area_size - image_size,
                );
                const after = zss.util.divCeil(
                    (positioning_area_count - 1) * (painting_area_size - positioning_area_size - positioning_area_offset) - space,
                    positioning_area_size - image_size,
                );
                break :blk GetBackgroundImageRepeatInfoReturnType{
                    .start_index = -before,
                    .count = before + after + positioning_area_count,
                    .space = zss.util.Ratio(c_int){ .num = space, .den = positioning_area_count - 1 },
                    .offset = 0,
                };
            }
        },
        .Round => @panic("TODO SDL: Background image round repeat style"),
    };
}

pub fn drawInlineBox(
    renderer: *sdl.SDL_Renderer,
    pixel_format: *sdl.SDL_PixelFormat,
    values: *const InlineLevelUsedValues,
    used_id: UsedId,
    position: ZssVector,
    middle_length: ZssUnit,
    draw_start: bool,
    draw_end: bool,
) void {
    const block_start = values.block_start[used_id];
    const block_end = values.block_end[used_id];

    const content_top_y = position.y - values.ascender;
    const padding_top_y = content_top_y - block_start.padding;
    const border_top_y = padding_top_y - block_start.border;
    const content_bottom_y = position.y + values.descender;
    const padding_bottom_y = content_bottom_y + block_end.padding;
    const border_bottom_y = padding_bottom_y + block_end.border;

    const inline_start = values.inline_start[used_id];
    const inline_end = values.inline_end[used_id];

    {
        const background1 = values.background1[used_id];
        var background_clip_rect = ZssRect{
            .x = position.x,
            .y = undefined,
            .w = middle_length,
            .h = undefined,
        };
        switch (background1.clip) {
            .Border => {
                background_clip_rect.y = border_top_y;
                background_clip_rect.h = border_bottom_y - border_top_y;
                if (draw_start) background_clip_rect.w += inline_start.padding + inline_start.border;
                if (draw_end) background_clip_rect.w += inline_end.padding + inline_end.border;
            },
            .Padding => {
                background_clip_rect.y = padding_top_y;
                background_clip_rect.h = padding_bottom_y - padding_top_y;
                if (draw_start) {
                    background_clip_rect.x += inline_start.border;
                    background_clip_rect.w += inline_start.padding;
                }
                if (draw_end) background_clip_rect.w += inline_end.padding;
            },
            .Content => {
                background_clip_rect.y = content_top_y;
                background_clip_rect.h = content_bottom_y - content_top_y;
                if (draw_start) background_clip_rect.x += inline_start.padding + inline_start.border;
            },
        }

        const color = rgbaMap(pixel_format, background1.color_rgba);
        assert(sdl.SDL_SetRenderDrawColor(renderer, color[0], color[1], color[2], color[3]) == 0);
        assert(sdl.SDL_RenderFillRect(renderer, &zssRectToSdlRect(background_clip_rect)) == 0);
    }

    const top_color = rgbaMap(pixel_format, block_start.border_color_rgba);
    const bottom_color = rgbaMap(pixel_format, block_end.border_color_rgba);
    var top_bottom_border_x = position.x;
    var top_bottom_border_w = middle_length;
    var section_start_x = position.x;

    if (draw_start) {
        const rect = sdl.SDL_Rect{
            .x = zssUnitToPixel(section_start_x),
            .y = zssUnitToPixel(padding_top_y),
            .w = zssUnitToPixel(inline_start.border),
            .h = zssUnitToPixel(values.ascender + values.descender + block_start.padding + block_end.padding),
        };
        const left_color = rgbaMap(pixel_format, inline_start.border_color_rgba);

        // left
        assert(sdl.SDL_SetRenderDrawColor(renderer, left_color[0], left_color[1], left_color[2], left_color[3]) == 0);
        assert(sdl.SDL_RenderFillRect(renderer, &rect) == 0);

        // top left
        drawBordersSolidCorners(
            renderer,
            zssUnitToPixel(section_start_x),
            zssUnitToPixel(section_start_x + inline_start.border),
            zssUnitToPixel(border_top_y),
            zssUnitToPixel(padding_top_y),
            left_color,
            top_color,
            true,
        );
        // bottom left
        drawBordersSolidCorners(
            renderer,
            zssUnitToPixel(section_start_x + inline_start.border),
            zssUnitToPixel(section_start_x),
            zssUnitToPixel(padding_bottom_y),
            zssUnitToPixel(border_bottom_y),
            bottom_color,
            left_color,
            false,
        );

        top_bottom_border_x += inline_start.border;
        top_bottom_border_w += inline_start.padding;
        section_start_x += inline_start.border + inline_start.padding;
    }

    section_start_x += middle_length;

    if (draw_end) {
        const rect = sdl.SDL_Rect{
            .x = zssUnitToPixel(section_start_x + inline_end.padding),
            .y = zssUnitToPixel(padding_top_y),
            .w = zssUnitToPixel(inline_end.border),
            .h = zssUnitToPixel(values.ascender + values.descender + block_start.padding + block_end.padding),
        };
        const right_color = rgbaMap(pixel_format, inline_end.border_color_rgba);

        // right
        assert(sdl.SDL_SetRenderDrawColor(renderer, right_color[0], right_color[1], right_color[2], right_color[3]) == 0);
        assert(sdl.SDL_RenderFillRect(renderer, &rect) == 0);

        // top right
        drawBordersSolidCorners(
            renderer,
            zssUnitToPixel(section_start_x + inline_end.padding + inline_end.border),
            zssUnitToPixel(section_start_x + inline_end.padding),
            zssUnitToPixel(border_top_y),
            zssUnitToPixel(padding_top_y),
            right_color,
            top_color,
            false,
        );
        // bottom right
        drawBordersSolidCorners(
            renderer,
            zssUnitToPixel(section_start_x + inline_end.padding),
            zssUnitToPixel(section_start_x + inline_end.padding + inline_end.border),
            zssUnitToPixel(padding_bottom_y),
            zssUnitToPixel(border_bottom_y),
            bottom_color,
            right_color,
            true,
        );

        top_bottom_border_w += inline_end.padding;
    }

    section_start_x -= middle_length;

    {
        const rects = [2]sdl.SDL_Rect{
            // top
            sdl.SDL_Rect{
                .x = zssUnitToPixel(top_bottom_border_x),
                .y = zssUnitToPixel(border_top_y),
                .w = zssUnitToPixel(top_bottom_border_w),
                .h = zssUnitToPixel(block_start.border),
            },
            // bottom
            sdl.SDL_Rect{
                .x = zssUnitToPixel(top_bottom_border_x),
                .y = zssUnitToPixel(padding_bottom_y),
                .w = zssUnitToPixel(top_bottom_border_w),
                .h = zssUnitToPixel(block_end.border),
            },
        };

        assert(sdl.SDL_SetRenderDrawColor(renderer, top_color[0], top_color[1], top_color[2], top_color[3]) == 0);
        assert(sdl.SDL_RenderFillRect(renderer, &rects[0]) == 0);
        assert(sdl.SDL_SetRenderDrawColor(renderer, bottom_color[0], bottom_color[1], bottom_color[2], bottom_color[3]) == 0);
        assert(sdl.SDL_RenderFillRect(renderer, &rects[1]) == 0);
    }
}
