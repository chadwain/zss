const std = @import("std");
const assert = std.debug.assert;

const zss = @import("../../zss.zig");
const ZssUnit = zss.used_values.ZssUnit;
const ZssRect = zss.used_values.ZssRect;
const ZssVector = zss.used_values.ZssVector;
const InlineRenderingData = zss.used_values.InlineRenderingData;
const Document = zss.used_values.Document;

const hb = @import("harfbuzz");
const sdl = @import("SDL2");

const util = struct {
    usingnamespace @import("util/sdl.zig");
    usingnamespace @import("util/sdl_freetype.zig");
};

pub const pixelToZssUnit = util.pixelToZssUnit;

pub const drawBlockDataRoot = util.drawBlockDataRoot;
pub const drawBlockDataChildren = util.drawBlockDataChildren;
pub const drawBackgroundColor = util.drawBackgroundColor;
pub const textureAsBackgroundImage = util.textureAsBackgroundImage;
pub const GlyphAtlas = util.GlyphAtlas;
pub const makeGlyphAtlas = util.makeGlyphAtlas;

pub fn renderDocument(
    document: *const Document,
    renderer: *sdl.SDL_Renderer,
    pixel_format: *sdl.SDL_PixelFormat,
    glyph_atlas: *GlyphAtlas,
    allocator: *std.mem.Allocator,
    clip_rect: ZssRect,
    translation: ZssVector,
) !void {
    const block_data = &document.block_data;
    drawBlockDataRoot(block_data, translation, clip_rect, renderer, pixel_format);
    try drawBlockDataChildren(block_data, allocator, translation, clip_rect, renderer, pixel_format);

    for (block_data.inline_data) |inline_data| {
        var cumulative_translation = translation;
        var it = zss.util.PdfsFlatTreeIterator.init(block_data.pdfs_flat_tree, inline_data.id_of_containing_block);
        while (it.next()) |id| {
            cumulative_translation = cumulative_translation.add(block_data.box_offsets[id].content_top_left);
        }
        try drawInlineData(inline_data.data, cumulative_translation, renderer, pixel_format, glyph_atlas);
    }
}

pub fn drawInlineData(
    context: *const InlineRenderingData,
    translation: ZssVector,
    renderer: *sdl.SDL_Renderer,
    pixel_format: *sdl.SDL_PixelFormat,
    atlas: *GlyphAtlas,
) !void {
    const face = hb.hb_ft_font_get_face(context.font);
    const color = util.rgbaMap(pixel_format, context.font_color_rgba);
    assert(sdl.SDL_SetTextureColorMod(atlas.texture, color[0], color[1], color[2]) == 0);
    assert(sdl.SDL_SetTextureAlphaMod(atlas.texture, color[3]) == 0);

    for (context.line_boxes) |line_box| {
        var cursor: ZssUnit = 0;
        var i = line_box.elements[0];
        while (i < line_box.elements[1]) : (i += 1) {
            var glyph_index = context.glyph_indeces[i];
            const position = context.positions[i];
            defer cursor += position.advance;

            if (glyph_index == InlineRenderingData.Special.glyph_index) blk: {
                i += 1;
                const special = InlineRenderingData.Special.decode(context.glyph_indeces[i]);
                switch (special.meaning) {
                    // TODO not actually drawing the inline boxes
                    .BoxStart, .BoxEnd => {},
                    .LiteralFFFF => {
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
                    .x = util.zssUnitToPixel(translation.x + cursor + position.offset),
                    .y = util.zssUnitToPixel(translation.y + line_box.baseline) - glyph_info.ascender_px,
                    .w = glyph_info.width,
                    .h = glyph_info.height,
                },
            ) == 0);
        }
    }
}
