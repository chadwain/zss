const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const AutoArrayHashMapUnmanaged = std.AutoArrayHashMapUnmanaged;

const zss = @import("../../zss.zig");
const ZssUnit = zss.used_values.ZssUnit;
const ZssRect = zss.used_values.ZssRect;
const ZssVector = zss.used_values.ZssVector;
const ZssFlowRelativeVector = zss.used_values.ZssFlowRelativeVector;
const UsedId = zss.used_values.UsedId;
const BlockLevelUsedValues = zss.used_values.BlockLevelUsedValues;
const InlineLevelUsedValues = zss.used_values.InlineLevelUsedValues;
const Document = zss.used_values.Document;

const hb = @import("harfbuzz");
const sdl = @import("SDL2");

pub const util = @import("util/sdl.zig");

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
        var it = zss.util.StructureArrayIterator.init(block_values.structure, inline_values.id_of_containing_block);
        while (it.next()) |id| {
            cumulative_translation = cumulative_translation.add(util.zssFlowRelativeVectorToZssVector(block_values.box_offsets[id].content_start));
        }
        try drawInlineValues(inline_values.values, cumulative_translation, allocator, renderer, pixel_format, glyph_atlas);
    }
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

pub const GlyphAtlas = struct {
    pub const Entry = struct {
        slot: u8,
        ascender_px: i16,
        width: u16,
        height: u16,
    };

    map: AutoArrayHashMapUnmanaged(c_uint, Entry),
    texture: *sdl.SDL_Texture,
    surface: *sdl.SDL_Surface,
    face: hb.FT_Face,
    max_glyph_width: u16,
    max_glyph_height: u16,
    next_slot: u9,

    const Self = @This();

    pub fn init(face: hb.FT_Face, renderer: *sdl.SDL_Renderer, pixel_format: *sdl.SDL_PixelFormat, allocator: *Allocator) !Self {
        const max_glyph_width = @intCast(u16, zss.util.roundUp(zss.util.divCeil((face.*.bbox.xMax - face.*.bbox.xMin) * face.*.size.*.metrics.x_ppem, face.*.units_per_EM), 4));
        const max_glyph_height = @intCast(u16, zss.util.roundUp(zss.util.divCeil((face.*.bbox.yMax - face.*.bbox.yMin) * face.*.size.*.metrics.y_ppem, face.*.units_per_EM), 4));

        const surface = sdl.SDL_CreateRGBSurfaceWithFormat(
            0,
            max_glyph_width,
            max_glyph_height,
            32,
            pixel_format.*.format,
        ) orelse return error.SDL_Error;
        errdefer sdl.SDL_FreeSurface(surface);
        assert(sdl.SDL_FillRect(surface, null, sdl.SDL_MapRGBA(pixel_format, 0, 0, 0, 0)) == 0);

        const texture = sdl.SDL_CreateTexture(
            renderer,
            pixel_format.*.format,
            sdl.SDL_TEXTUREACCESS_STATIC,
            max_glyph_width * 16,
            max_glyph_height * 16,
        ) orelse return error.SDL_Error;
        errdefer sdl.SDL_DestroyTexture(texture);
        assert(sdl.SDL_SetTextureBlendMode(texture, sdl.SDL_BlendMode.SDL_BLENDMODE_BLEND) == 0);

        var map = AutoArrayHashMapUnmanaged(c_uint, Entry){};
        errdefer map.deinit(allocator);
        try map.ensureCapacity(allocator, 256);

        return Self{
            .map = map,
            .texture = texture,
            .surface = surface,
            .face = face,
            .max_glyph_width = max_glyph_width,
            .max_glyph_height = max_glyph_height,
            .next_slot = 0,
        };
    }

    pub fn deinit(self: *Self, allocator: *Allocator) void {
        self.map.deinit(allocator);
        sdl.SDL_DestroyTexture(self.texture);
        sdl.SDL_FreeSurface(self.surface);
    }

    pub fn getOrLoadGlyph(self: *Self, glyph_index: c_uint) !Entry {
        if (self.map.getEntry(glyph_index)) |entry| {
            return entry.value_ptr.*;
        } else {
            if (self.next_slot >= 256) return error.OutOfGlyphSlots;

            assert(hb.FT_Load_Glyph(self.face, glyph_index, hb.FT_LOAD_DEFAULT) == hb.FT_Err_Ok);
            assert(hb.FT_Render_Glyph(self.face.*.glyph, hb.FT_Render_Mode.FT_RENDER_MODE_NORMAL) == hb.FT_Err_Ok);
            const bitmap = self.face.*.glyph.*.bitmap;
            assert(bitmap.width <= self.max_glyph_width and bitmap.rows <= self.max_glyph_height);

            copyBitmapToSurface(self.surface, bitmap);
            defer assert(sdl.SDL_FillRect(self.surface, null, sdl.SDL_MapRGBA(self.surface.format, 0, 0, 0, 0)) == 0);
            assert(sdl.SDL_UpdateTexture(
                self.texture,
                &sdl.SDL_Rect{
                    .x = (self.next_slot % 16) * self.max_glyph_width,
                    .y = (self.next_slot / 16) * self.max_glyph_height,
                    .w = self.max_glyph_width,
                    .h = self.max_glyph_height,
                },
                self.surface.*.pixels.?,
                self.surface.*.pitch,
            ) == 0);

            const entry = Entry{
                .slot = @intCast(u8, self.next_slot),
                .ascender_px = @intCast(i16, self.face.*.glyph.*.bitmap_top),
                .width = @intCast(u16, bitmap.width),
                .height = @intCast(u16, bitmap.rows),
            };
            self.map.putAssumeCapacity(glyph_index, entry);
            self.next_slot += 1;

            return entry;
        }
    }
};

fn copyBitmapToSurface(surface: *sdl.SDL_Surface, bitmap: hb.FT_Bitmap) void {
    var src_index: usize = 0;
    var dest_index: usize = 0;
    while (src_index < bitmap.pitch * @intCast(c_int, bitmap.rows)) : ({
        src_index += @intCast(usize, bitmap.pitch);
        dest_index += @intCast(usize, surface.pitch);
    }) {
        const src_row = bitmap.buffer[src_index .. src_index + bitmap.width];
        const dest_row = @ptrCast([*]u32, @alignCast(4, @ptrCast([*]u8, surface.pixels.?) + dest_index))[0..bitmap.width];
        for (src_row) |_, i| {
            dest_row[i] = sdl.SDL_MapRGBA(surface.format, 0xff, 0xff, 0xff, src_row[i]);
        }
    }
}

pub const ThreeBoxes = struct {
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
            .translation = translation.add(util.zssFlowRelativeVectorToZssVector(box_offsets.content_start)),
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
                    .translation = stack_item.translation.add(util.zssFlowRelativeVectorToZssVector(box_offsets.content_start)),
                });
            }
        }

        _ = stack.pop();
    }
}

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
    const bg_clip_rect = util.zssRectToSdlRect(switch (background1.clip) {
        .Border => boxes.border,
        .Padding => boxes.padding,
        .Content => boxes.content,
    });

    // draw background color
    util.drawBackgroundColor(renderer, pixel_format, bg_clip_rect, background1.color_rgba);

    // draw background image
    if (background2.image) |texture_ptr| {
        const texture = @ptrCast(*sdl.SDL_Texture, texture_ptr);
        var tw: c_int = undefined;
        var th: c_int = undefined;
        assert(sdl.SDL_QueryTexture(texture, null, null, &tw, &th) == 0);
        const origin_rect = util.zssRectToSdlRect(switch (background2.origin) {
            .Border => boxes.border,
            .Padding => boxes.padding,
            .Content => boxes.content,
        });
        const size = util.ImageSize{
            .w = util.zssUnitToPixel(background2.size.width),
            .h = util.zssUnitToPixel(background2.size.height),
        };
        const position = sdl.SDL_Point{
            .x = origin_rect.x + util.zssUnitToPixel(background2.position.x),
            .y = origin_rect.y + util.zssUnitToPixel(background2.position.y),
        };
        util.drawBackgroundImage(
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
    util.drawBordersSolid(
        renderer,
        pixel_format,
        &util.zssRectToSdlRect(boxes.border),
        &util.BorderWidths{
            .top = util.zssUnitToPixel(borders.block_start),
            .right = util.zssUnitToPixel(borders.inline_end),
            .bottom = util.zssUnitToPixel(borders.block_end),
            .left = util.zssUnitToPixel(borders.inline_start),
        },
        &util.BorderColor{
            .top_rgba = border_colors.block_start_rgba,
            .right_rgba = border_colors.inline_end_rgba,
            .bottom_rgba = border_colors.block_end_rgba,
            .left_rgba = border_colors.inline_start_rgba,
        },
    );
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

            if (glyph_index == 0) blk: {
                i += 1;
                const special = InlineLevelUsedValues.Special.decode(values.glyph_indeces[i]);
                switch (special.kind) {
                    .ZeroGlyphIndex => break :blk,
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

        if (glyph_index == 0) {
            i += 1;
            const special = InlineLevelUsedValues.Special.decode(glyph_indeces[i]);
            if (special.kind == .BoxEnd and special.data == used_id) {
                found = true;
                break;
            }
        }

        advance += metric.advance;
    }

    return .{ .advance = advance, .found = found };
}
