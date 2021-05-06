const std = @import("std");
const assert = std.debug.assert;

const zss = @import("../../zss.zig");
const CSSUnit = zss.used_values.CSSUnit;
const Offset = zss.used_values.Offset;
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
pub const GlyphAtlas = util.GlyphAtlas;
pub const makeGlyphAtlas = util.makeGlyphAtlas;

pub fn drawInlineData(
    context: *const InlineRenderingData,
    cumulative_offset: Offset,
    renderer: *sdl.SDL_Renderer,
    pixel_format: *sdl.SDL_PixelFormat,
    atlas: *const GlyphAtlas,
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

            const glyph_info = atlas.map.get(glyph_index) orelse unreachable;
            assert(sdl.SDL_RenderCopy(
                renderer,
                atlas.texture,
                &sdl.SDL_Rect{
                    .x = (glyph_info.slot % 16) * atlas.glyph_width,
                    .y = (glyph_info.slot / 16) * atlas.glyph_height,
                    .w = glyph_info.width,
                    .h = glyph_info.height,
                },
                &sdl.SDL_Rect{
                    .x = util.cssUnitToSdlPixel(cumulative_offset.x + cursor + position.offset),
                    .y = util.cssUnitToSdlPixel(cumulative_offset.y + line_box.baseline) - glyph_info.ascender_px,
                    .w = glyph_info.width,
                    .h = glyph_info.height,
                },
            ) == 0);
        }
    }
}
