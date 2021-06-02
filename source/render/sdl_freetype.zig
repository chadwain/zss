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

pub const pixelToCSSUnit = util.pixelToCSSUnit;

pub const drawBlockDataRoot = util.drawBlockDataRoot;
pub const drawBlockDataChildren = util.drawBlockDataChildren;
pub const drawBackgroundColor = util.drawBackgroundColor;
pub const textureAsBackgroundImage = util.textureAsBackgroundImage;
pub const GlyphAtlas = util.GlyphAtlas;
pub const makeGlyphAtlas = util.makeGlyphAtlas;

pub fn drawInlineData(
    context: *const InlineRenderingData,
    cumulative_offset: Offset,
    renderer: *sdl.SDL_Renderer,
    pixel_format: *sdl.SDL_PixelFormat,
    atlas: *GlyphAtlas,
) !void {
    const face = hb.hb_ft_font_get_face(context.font);
    const color = util.rgbaMap(pixel_format, context.font_color_rgba);
    assert(sdl.SDL_SetTextureColorMod(atlas.texture, color[0], color[1], color[2]) == 0);
    assert(sdl.SDL_SetTextureAlphaMod(atlas.texture, color[3]) == 0);

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
                    .LineBreak => unreachable,
                }
                continue;
            }

            const glyph_info = atlas.getOrLoadGlyph(glyph_index) catch |err| switch (err) {
                error.OutOfGlyphSlots => {
                    std.log.err("Could not load glyph with index {}: {s}\n", .{ glyph_index, @errorName(err) });
                    continue;
                },
            };
            assert(sdl.SDL_RenderCopy(
                renderer,
                atlas.texture,
                &sdl.SDL_Rect{
                    .x = (glyph_info.slot % 16) * atlas.max_glyph_width,
                    .y = (glyph_info.slot / 16) * atlas.max_glyph_height,
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
