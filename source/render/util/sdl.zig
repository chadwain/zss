const std = @import("std");
const assert = std.debug.assert;

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

const ThreeBoxes = struct {
    border: ZssRect,
    padding: ZssRect,
    content: ZssRect,
};

// The only supported writing mode is horizontal-tb, so this function
// lets us ignore the logical coords and move into physical coords.
fn getThreeBoxes(translation: ZssVector, box_offsets: zss.used_values.BoxOffsets, borders: zss.used_values.Borders) ThreeBoxes {
    const border_x = translation.x + box_offsets.border_start.inline_dir;
    const border_y = translation.y + box_offsets.border_start.block_dir;
    const border_w = box_offsets.border_end.inline_dir - box_offsets.border_start.inline_dir;
    const border_h = box_offsets.border_end.block_dir - box_offsets.border_start.block_dir;

    return ThreeBoxes{
        .border = ZssRect{
            .x = border_x,
            .y = border_y,
            .w = border_w,
            .h = border_h,
        },
        .padding = ZssRect{
            .x = border_x + borders.inline_start,
            .y = border_y + borders.block_start,
            .w = border_w - borders.inline_start - borders.inline_end,
            .h = border_h - borders.block_start - borders.block_end,
        },
        .content = ZssRect{
            .x = translation.x + box_offsets.content_start.inline_dir,
            .y = translation.y + box_offsets.content_start.block_dir,
            .w = box_offsets.content_end.inline_dir - box_offsets.content_start.inline_dir,
            .h = box_offsets.content_end.block_dir - box_offsets.content_start.block_dir,
        },
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

const bg_image_fns = struct {
    fn getNaturalSize(data: *zss.BoxTree.Background.Image.Object.Data) zss.BoxTree.Background.Image.Object.Dimensions {
        const texture = @ptrCast(*sdl.SDL_Texture, data);
        var width: c_int = undefined;
        var height: c_int = undefined;
        assert(sdl.SDL_QueryTexture(texture, null, null, &width, &height) == 0);
        return .{ .width = @intToFloat(f32, width), .height = @intToFloat(f32, height) };
    }
};

pub fn textureAsBackgroundImageObject(texture: *sdl.SDL_Texture) zss.BoxTree.Background.Image.Object {
    return .{
        .data = @ptrCast(*zss.BoxTree.Background.Image.Object.Data, texture),
        .getNaturalSizeFn = bg_image_fns.getNaturalSize,
    };
}

/// Draws the background color, background image, and borders of a
/// block box. This implements §Appendix E.2 Step 2.
pub fn drawBlockValuesRoot(
    values: *const BlockLevelUsedValues,
    translation: ZssVector,
    clip_rect: ZssRect,
    renderer: *sdl.SDL_Renderer,
    pixel_format: *sdl.SDL_PixelFormat,
) void {
    //const visual_effect = values.visual_effect[0];
    //if (visual_effect.visibility == .Hidden) return;
    const borders = values.borders[0];
    const background1 = values.background1[0];
    const background2 = values.background2[0];
    const border_colors = values.border_colors[0];
    const box_offsets = values.box_offsets[0];

    const boxes = getThreeBoxes(translation, box_offsets, borders);
    drawBlockContainer(&boxes, borders, background1, background2, border_colors, clip_rect, renderer, pixel_format);
}

/// Draws the background color, background image, and borders of all of the
/// descendant boxes in a block context (i.e. excluding the top element).
/// This implements §Appendix E.2 Step 4.
pub fn drawBlockValuesChildren(
    values: *const BlockLevelUsedValues,
    allocator: *std.mem.Allocator,
    translation: ZssVector,
    initial_clip_rect: ZssRect,
    renderer: *sdl.SDL_Renderer,
    pixel_format: *sdl.SDL_PixelFormat,
) !void {
    const Interval = struct {
        begin: UsedId,
        end: UsedId,
    };
    const StackItem = struct {
        interval: Interval,
        translation: ZssVector,
        //clip_rect: ZssRect,
    };

    var stack = std.ArrayList(StackItem).init(allocator);
    defer stack.deinit();

    if (values.structure[0] != 1) {
        const box_offsets = values.box_offsets[0];
        //const borders = values.borders[0];
        //const clip_rect = switch (values.visual_effect[0].overflow) {
        //    .Visible => initial_clip_rect,
        //    .Hidden => blk: {
        //        const padding_rect = ZssRect{
        //            .x = translation.x + box_offsets.border_top_left.x + borders.left,
        //            .y = translation.y + box_offsets.border_top_left.y + borders.top,
        //            .w = (box_offsets.border_bottom_right.x - borders.right) - (box_offsets.border_top_left.x + borders.left),
        //            .h = (box_offsets.border_bottom_right.y - borders.bottom) - (box_offsets.border_top_left.y + borders.top),
        //        };
        //
        //        break :blk initial_clip_rect.intersect(padding_rect);
        //    },
        //};
        //
        //// No need to draw children if the clip rect is empty.
        //if (!clip_rect.isEmpty()) {
        //    try stack.append(StackItem{
        //        .interval = Interval{ .begin = 1, .end = values.structure[0] },
        //        .translation = translation.add(box_offsets.content_top_left),
        //        .clip_rect = clip_rect,
        //    });
        //    assert(sdl.SDL_RenderSetClipRect(renderer, &zssRectToSdlRect(stack.items[0].clip_rect)) == 0);
        //}

        try stack.append(StackItem{
            .interval = Interval{ .begin = 1, .end = values.structure[0] },
            .translation = translation.add(zssFlowRelativeVectorToZssVector(box_offsets.content_start)),
        });
    }

    while (stack.items.len > 0) {
        const stack_item = &stack.items[stack.items.len - 1];
        const interval = &stack_item.interval;

        while (interval.begin != interval.end) {
            const used_id = interval.begin;
            const subtree_size = values.structure[used_id];
            defer interval.begin += subtree_size;

            const box_offsets = values.box_offsets[used_id];
            const borders = values.borders[used_id];
            const border_colors = values.border_colors[used_id];
            const background1 = values.background1[used_id];
            const background2 = values.background2[used_id];
            //const visual_effect = values.visual_effect[used_id];
            const boxes = getThreeBoxes(stack_item.translation, box_offsets, borders);

            //if (visual_effect.visibility == .Visible) {
            drawBlockContainer(&boxes, borders, background1, background2, border_colors, initial_clip_rect, renderer, pixel_format);
            //}

            if (subtree_size != 1) {
                //const new_clip_rect = switch (visual_effect.overflow) {
                //    .Visible => stack_item.clip_rect,
                //    .Hidden => stack_item.clip_rect.intersect(boxes.padding),
                //};
                //
                //// No need to draw children if the clip rect is empty.
                //if (!new_clip_rect.isEmpty()) {
                //    // TODO maybe the wrong place to call SDL_RenderSetClipRect
                //    assert(sdl.SDL_RenderSetClipRect(renderer, &zssRectToSdlRect(new_clip_rect)) == 0);
                //    try stack.append(StackItem{
                //        .interval = Interval{ .begin = used_id + 1, .end = used_id + subtree_size },
                //        .translation = stack_item.translation.add(box_offsets.content_top_left),
                //        .clip_rect = new_clip_rect,
                //    });
                //    continue :stackLoop;
                //}

                try stack.append(StackItem{
                    .interval = Interval{ .begin = used_id + 1, .end = used_id + subtree_size },
                    .translation = stack_item.translation.add(zssFlowRelativeVectorToZssVector(box_offsets.content_start)),
                });
            }
        }

        _ = stack.pop();
    }
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

pub fn drawBlockContainer(
    boxes: *const ThreeBoxes,
    borders: zss.used_values.Borders,
    background1: zss.used_values.Background1,
    background2: zss.used_values.Background2,
    border_colors: zss.used_values.BorderColor,
    // TODO clip_rect is unused
    clip_rect: ZssRect,
    renderer: *sdl.SDL_Renderer,
    pixel_format: *sdl.SDL_PixelFormat,
) void {
    const bg_clip_rect = zssRectToSdlRect(switch (background1.clip) {
        .Border => boxes.border,
        .Padding => boxes.padding,
        .Content => boxes.content,
    });

    // draw background color
    drawBackgroundColor(renderer, pixel_format, bg_clip_rect, background1.color_rgba);

    // draw background image
    if (background2.image) |texture_ptr| {
        const texture = @ptrCast(*sdl.SDL_Texture, texture_ptr);
        var tw: c_int = undefined;
        var th: c_int = undefined;
        assert(sdl.SDL_QueryTexture(texture, null, null, &tw, &th) == 0);
        const origin_rect = zssRectToSdlRect(switch (background2.origin) {
            .Border => boxes.border,
            .Padding => boxes.padding,
            .Content => boxes.content,
        });
        const size = ImageSize{
            .w = zssUnitToPixel(background2.size.width),
            .h = zssUnitToPixel(background2.size.height),
        };
        const position = sdl.SDL_Point{
            .x = origin_rect.x + zssUnitToPixel(background2.position.x),
            .y = origin_rect.y + zssUnitToPixel(background2.position.y),
        };
        drawBackgroundImage(
            renderer,
            texture,
            origin_rect,
            bg_clip_rect,
            position,
            size,
            background2.repeat,
        );
    }

    // draw borders
    drawBordersSolid(
        renderer,
        pixel_format,
        &zssRectToSdlRect(boxes.border),
        &BorderWidths{
            .top = zssUnitToPixel(borders.block_start),
            .right = zssUnitToPixel(borders.inline_end),
            .bottom = zssUnitToPixel(borders.block_end),
            .left = zssUnitToPixel(borders.inline_start),
        },
        &BorderColor{
            .top_rgba = border_colors.block_start_rgba,
            .right_rgba = border_colors.inline_end_rgba,
            .bottom_rgba = border_colors.block_end_rgba,
            .left_rgba = border_colors.inline_start_rgba,
        },
    );
}

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

const ImageSize = struct {
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
