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
const util = @import("./util.zig");

pub fn drawInlineContext(
    context: *const InlineRenderingContext,
    cumulative_offset: Offset,
    renderer: *sdl.SDL_Renderer,
    pixel_format: *sdl.SDL_PixelFormat,
) void {
    const face = hb.hb_ft_font_get_face(context.font);

    // TODO does this rendering order agree with CSS2.2 Appendix E?
    for (context.line_boxes) |line_box| {
        var cursor: CSSUnit = 0;
        var i = line_box.elements[0];
        while (i < line_box.elements[1]) : (i += 1) {
            var glyph_index = context.glyph_indeces[i];
            const position = context.positions[i];
            defer cursor += position.advance;

            if (glyph_index == InlineRenderingContext.special_index) blk: {
                i += 1;
                const special = InlineRenderingContext.decodeSpecial(context.glyph_indeces[i]);
                switch (special.meaning) {
                    // TODO not actually drawing the inline boxes
                    .BoxStart, .BoxEnd => {},
                    .Literal_FFFF => {
                        assert(hb.hb_font_get_glyph(context.font, 0xFFFF, 0, &glyph_index) != 0);
                        break :blk;
                    },
                }
                continue;
            }

            assert(hb.FT_Load_Glyph(face, glyph_index, hb.FT_LOAD_DEFAULT | hb.FT_LOAD_NO_HINTING) == hb.FT_Err_Ok);
            assert(hb.FT_Render_Glyph(face.*.glyph, hb.FT_Render_Mode.FT_RENDER_MODE_NORMAL) == 0);

            const bitmap = face.*.glyph.*.bitmap;
            if (bitmap.width == 0 or bitmap.rows == 0) continue;
            const final_position = sdl.SDL_Point{
                .x = util.cssUnitToSdlPixel(cumulative_offset.x + cursor + position.offset),
                .y = util.cssUnitToSdlPixel(cumulative_offset.y + line_box.baseline) - face.*.glyph.*.bitmap_top,
            };
            drawGlyph(bitmap, final_position, renderer, pixel_format);
        }
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
