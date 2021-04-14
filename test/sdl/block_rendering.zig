const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const zss = @import("zss");
const CSSUnit = zss.types.CSSUnit;
const Offset = zss.types.Offset;
const CSSRect = zss.types.CSSRect;
const BlockRenderingContext = zss.BlockRenderingContext;
usingnamespace zss.stacking_context;
usingnamespace zss.used_properties;

const render_sdl = @import("render_sdl.zig");
const sdl = @import("SDL2");

const Interval = struct {
    begin: u16,
    end: u16,
};

const StackItem = struct {
    interval: Interval,
    cumulative_offset: Offset,
    clip_rect: CSSRect,
};

/// Draws the background color, background image, and borders of the root
/// element box. This function should only be called with the block context
/// that contains the root element. This implements §Appendix E.2 Step 1.
///
/// TODO draw background images differently for the root element
pub const drawRootElementBlock = drawTopElementBlock;

/// Draws the background color, background image, and borders of a
/// block box. This implements §Appendix E.2 Step 2.
///
/// TODO support table boxes
pub fn drawTopElementBlock(
    context: *const BlockRenderingContext,
    cumulative_offset: Offset,
    clip_rect: CSSRect,
    renderer: *sdl.SDL_Renderer,
    pixel_format: *sdl.SDL_PixelFormat,
) void {
    const visual_effect = context.visual_effect[0];
    if (visual_effect.visibility == .Hidden) return;
    const borders = context.borders[0];
    const background_color = context.background_color[0];
    const background_image = context.background_image[0];
    const border_colors = context.border_colors[0];
    const box_offsets = context.box_offsets[0];

    const boxes = zss.util.getThreeBoxes(cumulative_offset, box_offsets, borders);
    drawBackgroundAndBorders(&boxes, borders, background_color, background_image, border_colors, clip_rect, renderer, pixel_format);
}

/// Draws the background color, background image, and borders of all of the
/// descendant boxes in a block context (i.e. excluding the top element).
/// This implements §Appendix E.2 Step 4.
///
/// TODO support table boxes
pub fn drawDescendantBlocks(
    context: *const BlockRenderingContext,
    allocator: *Allocator,
    cumulative_offset: Offset,
    initial_clip_rect: CSSRect,
    renderer: *sdl.SDL_Renderer,
    pixel_format: *sdl.SDL_PixelFormat,
) !void {
    var stack = ArrayList(StackItem).init(allocator);
    defer stack.deinit();

    if (context.preorder_array[0] != 1) {
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

                // NOTE if there is no intersection here, then
                // child elements don't need to be rendered
                break :blk initial_clip_rect.intersect(padding_rect);
            },
        };
        try stack.append(StackItem{
            .interval = Interval{ .begin = 1, .end = context.preorder_array[0] },
            .cumulative_offset = cumulative_offset.add(box_offsets.content_top_left),
            .clip_rect = clip_rect,
        });
        assert(sdl.SDL_RenderSetClipRect(renderer, &render_sdl.cssRectToSdlRect(stack.items[0].clip_rect)) == 0);
    }

    stackLoop: while (stack.items.len > 0) {
        const stack_item = &stack.items[stack.items.len - 1];
        const interval = &stack_item.interval;

        while (interval.begin != interval.end) {
            const index = interval.begin;
            const num_descendants = context.preorder_array[index];
            defer interval.begin += num_descendants;

            const box_offsets = context.box_offsets[index];
            const borders = context.borders[index];
            const border_colors = context.border_colors[index];
            const background_color = context.background_color[index];
            const background_image = context.background_image[index];
            const visual_effect = context.visual_effect[index];
            const boxes = zss.util.getThreeBoxes(stack_item.cumulative_offset, box_offsets, borders);

            if (visual_effect.visibility == .Visible) {
                drawBackgroundAndBorders(&boxes, borders, background_color, background_image, border_colors, stack_item.clip_rect, renderer, pixel_format);
            }

            if (num_descendants != 1) {
                const new_clip_rect = switch (visual_effect.overflow) {
                    .Visible => stack_item.clip_rect,
                    .Hidden =>
                    // NOTE if there is no intersection here, then
                    // child elements don't need to be rendered
                    stack_item.clip_rect.intersect(boxes.padding),
                };
                assert(sdl.SDL_RenderSetClipRect(renderer, &render_sdl.cssRectToSdlRect(new_clip_rect)) == 0);

                try stack.append(StackItem{
                    .interval = Interval{ .begin = index + 1, .end = index + num_descendants },
                    .cumulative_offset = stack_item.cumulative_offset.add(box_offsets.content_top_left),
                    .clip_rect = new_clip_rect,
                });
                continue :stackLoop;
            }
        }

        _ = stack.pop();
    }
}

fn drawBackgroundAndBorders(
    boxes: *const zss.types.ThreeBoxes,
    borders: Borders,
    background_color: BackgroundColor,
    background_image: BackgroundImage,
    border_colors: BorderColor,
    clip_rect: CSSRect,
    renderer: *sdl.SDL_Renderer,
    pixel_format: *sdl.SDL_PixelFormat,
) void {
    const bg_clip_rect = render_sdl.cssRectToSdlRect(switch (background_image.clip) {
        .Border => boxes.border,
        .Padding => boxes.padding,
        .Content => boxes.content,
    });

    // draw background color
    zss.sdl.drawBackgroundColor(renderer, pixel_format, bg_clip_rect, background_color.rgba);

    // draw background image
    if (background_image.image) |texture_ptr| {
        const texture = @ptrCast(*sdl.SDL_Texture, texture_ptr);
        var tw: c_int = undefined;
        var th: c_int = undefined;
        assert(sdl.SDL_QueryTexture(texture, null, null, &tw, &th) == 0);
        const origin_rect = render_sdl.cssRectToSdlRect(switch (background_image.origin) {
            .Border => boxes.border,
            .Padding => boxes.padding,
            .Content => boxes.content,
        });
        const size = sdl.SDL_Point{
            .x = @floatToInt(c_int, background_image.size.width * @intToFloat(f32, tw)),
            .y = @floatToInt(c_int, background_image.size.height * @intToFloat(f32, th)),
        };
        zss.sdl.drawBackgroundImage(
            renderer,
            texture,
            origin_rect,
            bg_clip_rect,
            sdl.SDL_Point{
                .x = origin_rect.x + @floatToInt(c_int, @intToFloat(f32, origin_rect.w - size.x) * background_image.position.horizontal),
                .y = origin_rect.y + @floatToInt(c_int, @intToFloat(f32, origin_rect.h - size.y) * background_image.position.vertical),
            },
            size,
            .{
                .x = switch (background_image.repeat.x) {
                    .None => .NoRepeat,
                    .Repeat => .Repeat,
                    .Space => .Space,
                },
                .y = switch (background_image.repeat.y) {
                    .None => .NoRepeat,
                    .Repeat => .Repeat,
                    .Space => .Space,
                },
            },
        );
    }

    // draw borders
    zss.sdl.drawBordersSolid(
        renderer,
        pixel_format,
        &render_sdl.cssRectToSdlRect(boxes.border),
        &zss.sdl.BorderWidths{
            .top = render_sdl.cssUnitToSdlPixel(borders.top),
            .right = render_sdl.cssUnitToSdlPixel(borders.right),
            .bottom = render_sdl.cssUnitToSdlPixel(borders.bottom),
            .left = render_sdl.cssUnitToSdlPixel(borders.left),
        },
        &zss.sdl.BorderColor{
            .top_rgba = border_colors.top_rgba,
            .right_rgba = border_colors.right_rgba,
            .bottom_rgba = border_colors.bottom_rgba,
            .left_rgba = border_colors.left_rgba,
        },
    );
}
