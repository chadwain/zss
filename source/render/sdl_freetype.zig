const std = @import("std");
const assert = std.debug.assert;

const zss = @import("../../zss.zig");
const ZssUnit = zss.used_values.ZssUnit;
const ZssRect = zss.used_values.ZssRect;
const ZssVector = zss.used_values.ZssVector;
const UsedId = zss.used_values.UsedId;
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
        var it = zss.util.PdfsArrayIterator.init(block_values.structure, inline_values.id_of_containing_block);
        while (it.next()) |id| {
            cumulative_translation = cumulative_translation.add(block_values.box_offsets[id].content_top_left);
        }
        try drawInlineValues(inline_values.values, cumulative_translation, allocator, renderer, pixel_format, glyph_atlas);
    }
}

pub fn drawInlineValues(
    values: *const InlineLevelUsedValues,
    translation: ZssVector,
    allocator: *std.mem.Allocator,
    renderer: *sdl.SDL_Renderer,
    pixel_format: *sdl.SDL_PixelFormat,
    atlas: *GlyphAtlas,
) !void {
    const face = hb.hb_ft_font_get_face(values.font);
    const color = util.rgbaMap(pixel_format, values.font_color_rgba);
    assert(sdl.SDL_SetTextureColorMod(atlas.texture, color[0], color[1], color[2]) == 0);
    assert(sdl.SDL_SetTextureAlphaMod(atlas.texture, color[3]) == 0);
    var inline_box_stack = std.ArrayList(UsedId).init(allocator);
    defer inline_box_stack.deinit();

    for (values.line_boxes) |line_box| {
        for (inline_box_stack.items) |used_id| {
            const match_info = findMatchingBoxEnd(values.glyph_indeces[line_box.elements[0]..line_box.elements[1]], values.metrics[line_box.elements[0]..line_box.elements[1]], used_id);
            util.drawInlineBox(
                renderer,
                pixel_format,
                values,
                used_id,
                ZssVector{ .x = translation.x, .y = translation.y + line_box.baseline },
                match_info.advance,
                false,
                match_info.found,
            );
        }

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
                    .BoxStart => {
                        const match_info = findMatchingBoxEnd(values.glyph_indeces[i + 1 .. line_box.elements[1]], values.metrics[i + 1 .. line_box.elements[1]], special.data);
                        util.drawInlineBox(
                            renderer,
                            pixel_format,
                            values,
                            special.data,
                            ZssVector{ .x = translation.x + cursor + metrics.offset, .y = translation.y + line_box.baseline },
                            match_info.advance,
                            true,
                            match_info.found,
                        );
                        try inline_box_stack.append(special.data);
                    },
                    .BoxEnd => assert(special.data == inline_box_stack.pop()),
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

fn findMatchingBoxEnd(glyph_indeces: []const hb.hb_codepoint_t, metrics: []const InlineLevelUsedValues.Metrics, used_id: UsedId) struct { advance: ZssUnit, found: bool } {
    var found = false;
    var advance: ZssUnit = 0;
    var i: usize = 0;
    while (i < glyph_indeces.len) : (i += 1) {
        const glyph_index = glyph_indeces[i];
        const metric = metrics[i];

        if (glyph_index == InlineLevelUsedValues.Special.glyph_index) {
            i += 1;
            const special = InlineLevelUsedValues.Special.decode(glyph_indeces[i]);
            if (special.meaning == .BoxEnd and special.data == used_id) {
                found = true;
                break;
            }
        }

        advance += metric.advance;
    }

    return .{ .advance = advance, .found = found };
}
