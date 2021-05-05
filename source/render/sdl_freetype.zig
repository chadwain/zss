const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const zss = @import("../../zss.zig");
const CSSUnit = zss.types.CSSUnit;
const Offset = zss.types.Offset;
const InlineRenderingData = zss.used_values.InlineRenderingData;

const hb = @import("harfbuzz");
const sdl = @import("SDL2");

const util = struct {
    usingnamespace @import("util/sdl.zig");
    usingnamespace @import("util/sdl_freetype.zig");
};

pub const drawBlockDataRoot = util.drawBlockDataRoot;
pub const drawBlockDataChildren = util.drawBlockDataChildren;
pub const textureAsBackgroundImage = util.textureAsBackgroundImage;

pub fn drawInlineData(
    context: *const InlineRenderingData,
    cumulative_offset: Offset,
    renderer: *sdl.SDL_Renderer,
    pixel_format: *sdl.SDL_PixelFormat,
) !void {
    const face = hb.hb_ft_font_get_face(context.font);

    for (context.line_boxes) |line_box| {
        var cursor: CSSUnit = 0;
        var i = line_box.elements[0];
        while (i < line_box.elements[1]) : (i += 1) {
            var glyph_index = context.glyph_indeces[i];
            const position = context.positions[i];
            defer cursor += position.advance;

            if (glyph_index == InlineRenderingData.special_index) blk: {
                i += 1;
                const special = InlineRenderingData.decodeSpecial(context.glyph_indeces[i]);
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
            try util.drawGlyph(bitmap, final_position, renderer, pixel_format);
        }
    }
}
