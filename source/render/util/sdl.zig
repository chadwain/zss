const std = @import("std");
const assert = std.debug.assert;

const zss = @import("../../../zss.zig");
const CSSUnit = zss.types.CSSUnit;
const CSSRect = zss.types.CSSRect;
const Offset = zss.types.Offset;
const BlockRenderingData = zss.used_values.BlockRenderingData;

const sdl = @import("SDL2");

pub fn cssUnitToSdlPixel(css: CSSUnit) i32 {
    return css;
}

pub fn cssRectToSdlRect(css: CSSRect) sdl.SDL_Rect {
    return sdl.SDL_Rect{
        .x = cssUnitToSdlPixel(css.x),
        .y = cssUnitToSdlPixel(css.y),
        .w = cssUnitToSdlPixel(css.w),
        .h = cssUnitToSdlPixel(css.h),
    };
}

pub fn sdlRectToCssRect(rect: sdl.SDL_Rect) CSSRect {
    return CSSRect{
        .x = rect.x,
        .y = rect.y,
        .w = rect.w,
        .h = rect.h,
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

pub fn textureAsBackgroundImage(texture: *sdl.SDL_Texture) *zss.values.BackgroundImage.Data {
    return @ptrCast(*zss.values.BackgroundImage.Data, texture);
}

/// Draws the background color, background image, and borders of a
/// block box. This implements §Appendix E.2 Step 2.
pub fn drawBlockDataRoot(
    context: *const BlockRenderingData,
    cumulative_offset: Offset,
    clip_rect: CSSRect,
    renderer: *sdl.SDL_Renderer,
    pixel_format: *sdl.SDL_PixelFormat,
) void {
    const visual_effect = context.visual_effect[0];
    if (visual_effect.visibility == .Hidden) return;
    const borders = context.borders[0];
    const background1 = context.background1[0];
    const background2 = context.background2[0];
    const border_colors = context.border_colors[0];
    const box_offsets = context.box_offsets[0];

    const boxes = zss.util.getThreeBoxes(cumulative_offset, box_offsets, borders);
    drawBackgroundAndBorders(&boxes, borders, background1, background2, border_colors, clip_rect, renderer, pixel_format);
}

/// Draws the background color, background image, and borders of all of the
/// descendant boxes in a block context (i.e. excluding the top element).
/// This implements §Appendix E.2 Step 4.
pub fn drawBlockDataChildren(
    context: *const BlockRenderingData,
    allocator: *std.mem.Allocator,
    cumulative_offset: Offset,
    initial_clip_rect: CSSRect,
    renderer: *sdl.SDL_Renderer,
    pixel_format: *sdl.SDL_PixelFormat,
) !void {
    const Interval = struct {
        begin: u16,
        end: u16,
    };
    const StackItem = struct {
        interval: Interval,
        cumulative_offset: Offset,
        clip_rect: CSSRect,
    };

    var stack = std.ArrayList(StackItem).init(allocator);
    defer stack.deinit();

    if (context.pdfs_flat_tree[0] != 1) {
        const box_offsets = context.box_offsets[0];
        const borders = context.borders[0];
        const clip_rect = switch (context.visual_effect[0].overflow) {
            .Visible => initial_clip_rect,
            .Hidden => blk: {
                const padding_rect = CSSRect{
                    .x = cumulative_offset.x + box_offsets.border_top_left.x + borders.left,
                    .y = cumulative_offset.y + box_offsets.border_top_left.y + borders.top,
                    .w = (box_offsets.border_bottom_right.x - borders.right) - (box_offsets.border_top_left.x + borders.left),
                    .h = (box_offsets.border_bottom_right.y - borders.bottom) - (box_offsets.border_top_left.y + borders.top),
                };

                break :blk initial_clip_rect.intersect(padding_rect);
            },
        };

        // No need to draw children is the clip rect is empty.
        if (!clip_rect.isEmpty()) {
            try stack.append(StackItem{
                .interval = Interval{ .begin = 1, .end = context.pdfs_flat_tree[0] },
                .cumulative_offset = cumulative_offset.add(box_offsets.content_top_left),
                .clip_rect = clip_rect,
            });
            assert(sdl.SDL_RenderSetClipRect(renderer, &cssRectToSdlRect(stack.items[0].clip_rect)) == 0);
        }
    }

    stackLoop: while (stack.items.len > 0) {
        const stack_item = &stack.items[stack.items.len - 1];
        const interval = &stack_item.interval;

        while (interval.begin != interval.end) {
            const used_id = interval.begin;
            const subtree_size = context.pdfs_flat_tree[used_id];
            defer interval.begin += subtree_size;

            const box_offsets = context.box_offsets[used_id];
            const borders = context.borders[used_id];
            const border_colors = context.border_colors[used_id];
            const background1 = context.background1[used_id];
            const background2 = context.background2[used_id];
            const visual_effect = context.visual_effect[used_id];
            const boxes = zss.util.getThreeBoxes(stack_item.cumulative_offset, box_offsets, borders);

            if (visual_effect.visibility == .Visible) {
                drawBackgroundAndBorders(&boxes, borders, background1, background2, border_colors, stack_item.clip_rect, renderer, pixel_format);
            }

            if (subtree_size != 1) {
                const new_clip_rect = switch (visual_effect.overflow) {
                    .Visible => stack_item.clip_rect,
                    .Hidden => stack_item.clip_rect.intersect(boxes.padding),
                };

                // No need to draw children is the clip rect is empty.
                if (!new_clip_rect.isEmpty()) {
                    assert(sdl.SDL_RenderSetClipRect(renderer, &cssRectToSdlRect(new_clip_rect)) == 0);
                    try stack.append(StackItem{
                        .interval = Interval{ .begin = used_id + 1, .end = used_id + subtree_size },
                        .cumulative_offset = stack_item.cumulative_offset.add(box_offsets.content_top_left),
                        .clip_rect = new_clip_rect,
                    });
                    continue :stackLoop;
                }
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

pub fn drawBackgroundAndBorders(
    boxes: *const zss.types.ThreeBoxes,
    borders: zss.used_values.Borders,
    background1: zss.used_values.Background1,
    background2: zss.used_values.Background2,
    border_colors: zss.used_values.BorderColor,
    clip_rect: CSSRect,
    renderer: *sdl.SDL_Renderer,
    pixel_format: *sdl.SDL_PixelFormat,
) void {
    const bg_clip_rect = cssRectToSdlRect(switch (background1.clip) {
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
        const origin_rect = cssRectToSdlRect(switch (background2.origin) {
            .Border => boxes.border,
            .Padding => boxes.padding,
            .Content => boxes.content,
        });
        const size = sdl.SDL_Point{
            .x = @floatToInt(c_int, background2.size.width * @intToFloat(f32, tw)),
            .y = @floatToInt(c_int, background2.size.height * @intToFloat(f32, th)),
        };
        drawBackgroundImage(
            renderer,
            texture,
            origin_rect,
            bg_clip_rect,
            sdl.SDL_Point{
                .x = origin_rect.x + @floatToInt(c_int, @intToFloat(f32, origin_rect.w - size.x) * background2.position.horizontal),
                .y = origin_rect.y + @floatToInt(c_int, @intToFloat(f32, origin_rect.h - size.y) * background2.position.vertical),
            },
            size,
            .{
                .x = switch (background2.repeat.x) {
                    .None => .NoRepeat,
                    .Repeat => .Repeat,
                    .Space => .Space,
                },
                .y = switch (background2.repeat.y) {
                    .None => .NoRepeat,
                    .Repeat => .Repeat,
                    .Space => .Space,
                },
            },
        );
    }

    // draw borders
    drawBordersSolid(
        renderer,
        pixel_format,
        &cssRectToSdlRect(boxes.border),
        &BorderWidths{
            .top = cssUnitToSdlPixel(borders.top),
            .right = cssUnitToSdlPixel(borders.right),
            .bottom = cssUnitToSdlPixel(borders.bottom),
            .left = cssUnitToSdlPixel(borders.left),
        },
        &BorderColor{
            .top_rgba = border_colors.top_rgba,
            .right_rgba = border_colors.right_rgba,
            .bottom_rgba = border_colors.bottom_rgba,
            .left_rgba = border_colors.left_rgba,
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

/// Represents one of the ways in which background images can be repeated.
/// Note that "background-repeat: round" is not explicitly supported, but can
/// be achieved by first resizing the image and using '.Repeat'.
pub const Repeat = enum { NoRepeat, Repeat, Space };

pub fn drawBackgroundImage(
    renderer: *sdl.SDL_Renderer,
    texture: *sdl.SDL_Texture,
    positioning_area: sdl.SDL_Rect,
    painting_area: sdl.SDL_Rect,
    position: sdl.SDL_Point,
    size: sdl.SDL_Point,
    repeat: struct { x: Repeat, y: Repeat },
) void {
    if (size.x == 0 or size.y == 0) return;
    const dimensions = blk: {
        var w: c_int = undefined;
        var h: c_int = undefined;
        assert(sdl.SDL_QueryTexture(texture, null, null, &w, &h) == 0);
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
            const image_rect = sdl.SDL_Rect{
                .x = positioning_area.x + info_x.offset + @divFloor(i * (size.x * @intCast(c_int, info_x.space.den) + @intCast(c_int, info_x.space.num)), @intCast(c_int, info_x.space.den)),
                .y = positioning_area.y + info_y.offset + @divFloor(j * (size.y * @intCast(c_int, info_y.space.den) + @intCast(c_int, info_y.space.num)), @intCast(c_int, info_y.space.den)),
                .w = size.x,
                .h = size.y,
            };
            var intersection = @as(sdl.SDL_Rect, undefined);
            // getBackgroundImageRepeatInfo should never return info that would make us draw
            // an image that is completely outside of the background painting area.
            assert(sdl.SDL_IntersectRect(&painting_area, &image_rect, &intersection) == .SDL_TRUE);
            assert(sdl.SDL_RenderCopy(
                renderer,
                texture,
                &sdl.SDL_Rect{
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

const GetBackgroundImageRepeatInfoType = struct {
    count: c_uint,
    space: zss.types.Ratio(c_uint),
    offset: c_int,
    start_index: c_int,
};

fn getBackgroundImageRepeatInfo(
    repeat: Repeat,
    painting_area_size: c_uint,
    positioning_area_offset: c_int,
    positioning_area_size: c_uint,
    image_offset: c_int,
    image_size: c_uint,
) GetBackgroundImageRepeatInfoType {
    return switch (repeat) {
        .NoRepeat => .{
            .count = 1,
            .space = zss.types.Ratio(c_uint){ .num = 0, .den = 1 },
            .offset = image_offset,
            .start_index = 0,
        },
        .Repeat => blk: {
            const before = zss.util.divCeil(c_int, image_offset + positioning_area_offset, @intCast(c_int, image_size));
            const after = zss.util.divCeil(c_int, @intCast(c_int, painting_area_size) - positioning_area_offset - image_offset - @intCast(c_int, image_size), @intCast(c_int, image_size));
            break :blk .{
                .count = @intCast(c_uint, before + after + 1),
                .space = zss.types.Ratio(c_uint){ .num = 0, .den = 1 },
                .offset = image_offset,
                .start_index = -before,
            };
        },
        .Space => blk: {
            const positioning_area_count = positioning_area_size / image_size;
            if (positioning_area_count <= 1) {
                break :blk GetBackgroundImageRepeatInfoType{
                    .count = 1,
                    .space = zss.types.Ratio(c_uint){ .num = 0, .den = 1 },
                    .offset = image_offset,
                    .start_index = 0,
                };
            } else {
                const space = positioning_area_size % image_size;
                const before = zss.util.divCeil(
                    c_int,
                    @intCast(c_int, positioning_area_count - 1) * positioning_area_offset - @intCast(c_int, space),
                    @intCast(c_int, positioning_area_size - image_size),
                );
                const after = zss.util.divCeil(
                    c_int,
                    @intCast(c_int, positioning_area_count - 1) * (@intCast(c_int, painting_area_size) - @intCast(c_int, positioning_area_size) - positioning_area_offset) - @intCast(c_int, space),
                    @intCast(c_int, positioning_area_size - image_size),
                );
                const count = @intCast(c_uint, before + after + @intCast(c_int, positioning_area_count));
                break :blk GetBackgroundImageRepeatInfoType{
                    .count = count,
                    .space = zss.types.Ratio(c_uint){ .num = space, .den = positioning_area_count - 1 },
                    .offset = 0,
                    .start_index = -before,
                };
            }
        },
    };
}
