const std = @import("std");
const assert = std.debug.assert;

const zss = @import("../../zss.zig");
const ZssUnit = zss.used_values.ZssUnit;
const ZssRect = zss.used_values.ZssRect;
const ZssVector = zss.used_values.ZssVector;
const InlineLevelUsedValues = zss.used_values.InlineLevelUsedValues;
const Document = zss.used_values.Document;

const hb = @import("harfbuzz");
const sdl = @import("SDL2");

const util = struct {
    usingnamespace @import("util/sdl.zig");
    usingnamespace @import("util/sdl_freetype.zig");
};

pub const pixelToZssUnit = util.pixelToZssUnit;
pub const zssUnitToPixel = util.zssUnitToPixel;

pub const drawBlockValuesRoot = util.drawBlockValuesRoot;
pub const drawBlockValuesChildren = util.drawBlockValuesChildren;
pub const drawBackgroundColor = util.drawBackgroundColor;
pub const textureAsBackgroundImageObject = util.textureAsBackgroundImageObject;
pub const GlyphAtlas = util.GlyphAtlas;
pub const makeGlyphAtlas = util.makeGlyphAtlas;

pub fn renderDocument(
    document: *const Document,
    renderer: *sdl.SDL_Renderer,
    pixel_format: *sdl.SDL_PixelFormat,
    glyph_atlas: *GlyphAtlas,
    allocator: *std.mem.Allocator,
    clip_rect: sdl.SDL_Rect,
    translation: sdl.SDL_Point,
) !void {
    const block_values = &document.block_values;
    const translation_zss = util.sdlPointToZssVector(translation);
    const clip_rect_zss = util.sdlRectToZssRect(clip_rect);

    drawBlockValuesRoot(block_values, translation_zss, clip_rect_zss, renderer, pixel_format);
    try drawBlockValuesChildren(block_values, allocator, translation_zss, clip_rect_zss, renderer, pixel_format);

    for (block_values.inline_values) |inline_values| {
        var cumulative_translation = translation_zss;
        var it = zss.util.PdfsFlatTreeIterator.init(block_values.pdfs_flat_tree, inline_values.id_of_containing_block);
        while (it.next()) |id| {
            cumulative_translation = cumulative_translation.add(block_values.box_offsets[id].content_top_left);
        }
        try drawInlineValues(inline_values.values, cumulative_translation, renderer, pixel_format, glyph_atlas);
    }
}

pub fn drawInlineValues(
    values: *const InlineLevelUsedValues,
    translation: ZssVector,
    renderer: *sdl.SDL_Renderer,
    pixel_format: *sdl.SDL_PixelFormat,
    atlas: *GlyphAtlas,
) !void {
    const face = hb.hb_ft_font_get_face(values.font);
    const color = util.rgbaMap(pixel_format, values.font_color_rgba);
    assert(sdl.SDL_SetTextureColorMod(atlas.texture, color[0], color[1], color[2]) == 0);
    assert(sdl.SDL_SetTextureAlphaMod(atlas.texture, color[3]) == 0);

    for (values.line_boxes) |line_box| {
        var cursor: ZssUnit = 0;
        var i = line_box.elements[0];
        while (i < line_box.elements[1]) : (i += 1) {
            const glyph_index = values.glyph_indeces[i];
            const metrics = values.metrics[i];
            defer cursor += metrics.advance;

            if (glyph_index == InlineLevelUsedValues.Special.glyph_index) blk: {
                i += 1;
                const special = InlineLevelUsedValues.Special.decode(values.glyph_indeces[i]);
                switch (special.meaning) {
                    .LiteralGlyphIndex => break :blk,
                    // TODO not actually drawing the inline boxes
                    .BoxStart, .BoxEnd => {},
                    _ => unreachable,
                }
                continue;
            }

            const glyph_info = atlas.getOrLoadGlyph(glyph_index) catch |err| switch (err) {
                error.OutOfGlyphSlots => {
                    std.log.err("Could not load glyph with index {}: {s}", .{ glyph_index, @errorName(err) });
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
                    .x = util.zssUnitToPixel(translation.x + cursor + metrics.offset),
                    .y = util.zssUnitToPixel(translation.y + line_box.baseline) - glyph_info.ascender_px,
                    .w = glyph_info.width,
                    .h = glyph_info.height,
                },
            ) == 0);
        }
    }
}
