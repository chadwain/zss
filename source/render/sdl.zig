const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const AutoArrayHashMapUnmanaged = std.AutoArrayHashMapUnmanaged;

const zss = @import("../../zss.zig");
const ZssUnit = zss.used_values.ZssUnit;
const ZssRect = zss.used_values.ZssRect;
const ZssVector = zss.used_values.ZssVector;
const BlockBoxIndex = zss.used_values.BlockBoxIndex;
const BlockSubtree = zss.used_values.BlockSubtree;
const BlockSubtreeIndex = zss.used_values.BlockSubtreeIndex;
const BlockBox = zss.used_values.BlockBox;
const BlockBoxTree = zss.used_values.BlockBoxTree;
const InlineBoxIndex = zss.used_values.InlineBoxIndex;
const InlineFormattingContext = zss.used_values.InlineFormattingContext;
const InlineFormattingContextIndex = zss.used_values.InlineFormattingContextIndex;
const StackingContext = zss.used_values.StackingContext;
const StackingContextTree = zss.used_values.StackingContextTree;
const ZIndex = zss.used_values.ZIndex;
const BoxTree = zss.used_values.BoxTree;

const hb = @import("harfbuzz");
const sdl = @import("SDL2");

pub const util = @import("util/sdl.zig");

pub fn drawBoxTree(
    box_tree: BoxTree,
    renderer: *sdl.SDL_Renderer,
    pixel_format: *sdl.SDL_PixelFormat,
    maybe_atlas: ?*GlyphAtlas,
    allocator: Allocator,
    clip_rect: sdl.SDL_Rect,
    translation: sdl.SDL_Point,
) !void {
    if (box_tree.stacking_contexts.size() == 0) return;
    const slice = box_tree.stacking_contexts.list.slice();
    const clip_rect_zss = sdlRectToZssRect(clip_rect);

    const Action = enum { DrawGeneratingBlock, DrawLeft, DrawEverythingElse, DrawRight };

    var stack = ArrayListUnmanaged(struct {
        action: Action,
        iterator: StackingContextTree.Iterator,
        stacking_context: StackingContext,
        translation: ZssVector,
    }){};
    defer stack.deinit(allocator);
    try stack.append(allocator, .{
        .action = .DrawGeneratingBlock,
        .iterator = box_tree.stacking_contexts.iterator().firstChild(slice.items(.__skip)),
        .stacking_context = .{
            .block_box = slice.items(.block_box)[0],
            .z_index = slice.items(.z_index)[0],
            .ifcs = slice.items(.ifcs)[0],
        },
        .translation = sdlPointToZssVector(translation),
    });

    while (stack.items.len > 0) {
        const item = &stack.items[stack.items.len - 1];
        switch (item.action) {
            .DrawGeneratingBlock => {
                item.action = .DrawLeft;

                if (stack.items.len > 1) {
                    const parent = stack.items[stack.items.len - 2];
                    const new_translation = calcOffset(&box_tree.blocks, parent.stacking_context.block_box, item.stacking_context.block_box);
                    item.translation = parent.translation.add(new_translation);
                }

                drawGeneratingBlock(box_tree.blocks, item.stacking_context.block_box, item.translation, clip_rect_zss, renderer, pixel_format);
            },
            .DrawLeft => {
                if (item.iterator.empty() or slice.items(.z_index)[item.iterator.index] >= 0) {
                    item.action = .DrawEverythingElse;
                    continue;
                }
                const index = item.iterator.index;
                item.iterator = item.iterator.nextSibling(slice.items(.__skip));
                try stack.append(allocator, .{
                    .action = .DrawGeneratingBlock,
                    .iterator = StackingContextTree.Iterator{ .index = index + 1, .end = index + slice.items(.__skip)[index] },
                    .stacking_context = .{ .block_box = slice.items(.block_box)[index], .z_index = slice.items(.z_index)[index], .ifcs = slice.items(.ifcs)[index] },
                    .translation = undefined,
                });
            },
            .DrawEverythingElse => {
                item.action = .DrawRight;
                try drawChildBlocks(box_tree.blocks, item.stacking_context.block_box, allocator, item.translation, clip_rect_zss, renderer, pixel_format);

                for (item.stacking_context.ifcs.items) |ifc_index| {
                    const ifc = box_tree.ifcs.items[ifc_index];
                    const subtree = &box_tree.blocks.subtrees.items[ifc.parent_block.subtree];
                    const box_offsets = subtree.box_offsets.items[ifc.parent_block.index];
                    const new_translation = item.translation
                        .add(calcOffset(&box_tree.blocks, item.stacking_context.block_box, ifc.parent_block))
                        .add(box_offsets.border_pos)
                        .add(box_offsets.content_pos)
                        .add(ifc.origin);
                    try drawInlineFormattingContext(ifc, new_translation, allocator, renderer, pixel_format, maybe_atlas);
                }
            },
            .DrawRight => {
                if (item.iterator.empty()) {
                    _ = stack.pop();
                    continue;
                }
                const index = item.iterator.index;
                item.iterator = item.iterator.nextSibling(slice.items(.__skip));
                try stack.append(allocator, .{
                    .action = .DrawGeneratingBlock,
                    .iterator = StackingContextTree.Iterator{ .index = index + 1, .end = index + slice.items(.__skip)[index] },
                    .stacking_context = .{ .block_box = slice.items(.block_box)[index], .z_index = slice.items(.z_index)[index], .ifcs = slice.items(.ifcs)[index] },
                    .translation = undefined,
                });
            },
        }
    }
}

fn calcOffset(blocks: *const BlockBoxTree, parent: BlockBox, child: BlockBox) ZssVector {
    var target = child;
    var reached_parent_subtree = parent.subtree == target.subtree;
    var result = ZssVector{ .x = 0, .y = 0 };
    while (true) {
        const subtree = &blocks.subtrees.items[target.subtree];
        var block_iterator: zss.SkipTreePathIterator(BlockBoxIndex) = undefined;
        if (reached_parent_subtree) {
            block_iterator = zss.SkipTreePathIterator(BlockBoxIndex).initFrom(target.index, parent.index, subtree.skip.items);
        } else {
            block_iterator = zss.SkipTreePathIterator(BlockBoxIndex).init(target.index, subtree.skip.items);
        }
        while (true) {
            const index = block_iterator.next(subtree.skip.items) orelse break;
            switch (subtree.type.items[index]) {
                .block => {
                    const box_offsets = subtree.box_offsets.items[index];
                    result = result.add(box_offsets.border_pos).add(box_offsets.content_pos);
                },
                .subtree_proxy => unreachable,
            }
        }
        if (reached_parent_subtree) {
            break;
        } else {
            target = subtree.parent orelse unreachable;
            reached_parent_subtree = parent.subtree == target.subtree;

            const new_subtree = &blocks.subtrees.items[target.subtree];
            assert(new_subtree.type.items[target.index] == .subtree_proxy);
        }
    }
    return result;
}

pub fn zssUnitToPixel(unit: ZssUnit) c_int {
    return @divFloor(unit, zss.used_values.units_per_pixel);
}

pub fn zssUnitToPixelRatio(unit: ZssUnit) zss.util.Ratio(c_int) {
    return zss.util.Ratio(c_int).initReduce(unit, zss.used_values.units_per_pixel);
}

pub fn pixelToZssUnit(pixels: c_int) ZssUnit {
    return pixels * zss.used_values.units_per_pixel;
}

pub fn sdlPointToZssVector(point: sdl.SDL_Point) ZssVector {
    return ZssVector{
        .x = pixelToZssUnit(point.x),
        .y = pixelToZssUnit(point.y),
    };
}

pub fn zssVectorToSdlPoint(vector: ZssVector) sdl.SDL_Point {
    return sdl.SDL_Point{
        .x = zssUnitToPixel(vector.x),
        .y = zssUnitToPixel(vector.y),
    };
}

pub fn sdlRectToZssRect(rect: sdl.SDL_Rect) ZssRect {
    return ZssRect{
        .x = pixelToZssUnit(rect.x),
        .y = pixelToZssUnit(rect.y),
        .w = pixelToZssUnit(rect.w),
        .h = pixelToZssUnit(rect.h),
    };
}

pub fn zssRectToSdlRect(rect: ZssRect) sdl.SDL_Rect {
    return sdl.SDL_Rect{
        .x = zssUnitToPixel(rect.x),
        .y = zssUnitToPixel(rect.y),
        .w = zssUnitToPixel(rect.w),
        .h = zssUnitToPixel(rect.h),
    };
}

const bg_image_fns = struct {
    fn getNaturalSize(data: *zss.values.BackgroundImage.Object.Data) zss.values.BackgroundImage.Object.Dimensions {
        const texture = @ptrCast(*sdl.SDL_Texture, data);
        var width: c_int = undefined;
        var height: c_int = undefined;
        assert(sdl.SDL_QueryTexture(texture, null, null, &width, &height) == 0);
        return .{ .width = @intToFloat(f32, width), .height = @intToFloat(f32, height) };
    }
};

pub fn textureAsBackgroundImageObject(texture: *sdl.SDL_Texture) zss.values.BackgroundImage.Object {
    return .{
        .data = @ptrCast(*zss.values.BackgroundImage.Object.Data, texture),
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

    pub fn init(face: hb.FT_Face, renderer: *sdl.SDL_Renderer, pixel_format: *sdl.SDL_PixelFormat, allocator: Allocator) !Self {
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
        assert(sdl.SDL_SetTextureBlendMode(texture, sdl.SDL_BLENDMODE_BLEND) == 0);

        var map = AutoArrayHashMapUnmanaged(c_uint, Entry){};
        errdefer map.deinit(allocator);
        try map.ensureTotalCapacity(allocator, 256);

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

    pub fn deinit(self: *Self, allocator: Allocator) void {
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
            assert(hb.FT_Render_Glyph(self.face.*.glyph, hb.FT_RENDER_MODE_NORMAL) == hb.FT_Err_Ok);
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

fn getThreeBoxes(translation: ZssVector, box_offsets: zss.used_values.BoxOffsets, borders: zss.used_values.Borders) ThreeBoxes {
    const border_x = translation.x + box_offsets.border_pos.x;
    const border_y = translation.y + box_offsets.border_pos.y;

    return ThreeBoxes{
        .border = ZssRect{
            .x = border_x,
            .y = border_y,
            .w = box_offsets.border_size.w,
            .h = box_offsets.border_size.h,
        },
        .padding = ZssRect{
            .x = border_x + borders.left,
            .y = border_y + borders.top,
            .w = box_offsets.border_size.w - borders.left - borders.right,
            .h = box_offsets.border_size.h - borders.top - borders.bottom,
        },
        .content = ZssRect{
            .x = border_x + box_offsets.content_pos.x,
            .y = border_y + box_offsets.content_pos.y,
            .w = box_offsets.content_size.w,
            .h = box_offsets.content_size.h,
        },
    };
}

/// Draws the background color, background image, and borders of a
/// block box. This implements CSS2.2§Appendix E.2 Step 2.
pub fn drawGeneratingBlock(
    blocks: BlockBoxTree,
    generating_block: BlockBox,
    translation: ZssVector,
    clip_rect: ZssRect,
    renderer: *sdl.SDL_Renderer,
    pixel_format: *sdl.SDL_PixelFormat,
) void {
    const subtree = &blocks.subtrees.items[generating_block.subtree];
    //const visual_effect = blocks.visual_effect[0];
    //if (visual_effect.visibility == .Hidden) return;
    const borders = subtree.borders.items[generating_block.index];
    const background1 = subtree.background1.items[generating_block.index];
    const background2 = subtree.background2.items[generating_block.index];
    const border_colors = subtree.border_colors.items[generating_block.index];
    const box_offsets = subtree.box_offsets.items[generating_block.index];

    const boxes = getThreeBoxes(translation, box_offsets, borders);
    drawBlockContainer(&boxes, borders, background1, background2, border_colors, clip_rect, renderer, pixel_format);
}

/// Draws the background color, background image, and borders of all of the
/// descendant boxes in a block context (i.e. excluding the top element).
/// This implements CSS2.2§Appendix E.2 Step 4.
pub fn drawChildBlocks(
    blocks: BlockBoxTree,
    generating_block: BlockBox,
    allocator: Allocator,
    translation: ZssVector,
    initial_clip_rect: ZssRect,
    renderer: *sdl.SDL_Renderer,
    pixel_format: *sdl.SDL_PixelFormat,
) !void {
    const Interval = struct {
        begin: BlockBoxIndex,
        end: BlockBoxIndex,
    };

    const BlockStackItem = struct {
        interval: Interval,
        translation: ZssVector,
        //clip_rect: ZssRect,
    };

    var block_stack = ArrayListUnmanaged(BlockStackItem){};
    defer block_stack.deinit(allocator);

    const SubtreeStackItem = struct {
        subtree: *const BlockSubtree,
        index_of_root: usize,
    };

    var subtree_stack = ArrayListUnmanaged(SubtreeStackItem){};
    defer subtree_stack.deinit(allocator);
    try subtree_stack.append(allocator, .{
        .subtree = &blocks.subtrees.items[generating_block.subtree],
        .index_of_root = 0,
    });

    const generating_block_subtree = &blocks.subtrees.items[generating_block.subtree];
    switch (generating_block_subtree.type.items[generating_block.index]) {
        .block => {},
        .subtree_proxy => unreachable,
    }
    if (generating_block_subtree.skip.items[generating_block.index] != 1) {
        const box_offsets = generating_block_subtree.box_offsets.items[generating_block.index];
        //const borders = blocks.borders[0];
        //const clip_rect = switch (blocks.visual_effect[0].overflow) {
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
        //        .interval = Interval{ .begin = 1, .end = blocks.skips[0] },
        //        .translation = translation.add(box_offsets.content_top_left),
        //        .clip_rect = clip_rect,
        //    });
        //    assert(sdl.SDL_RenderSetClipRect(renderer, &zssRectToSdlRect(stack.items[0].clip_rect)) == 0);
        //}

        try block_stack.append(allocator, .{
            .interval = .{ .begin = generating_block.index + 1, .end = generating_block.index + generating_block_subtree.skip.items[generating_block.index] },
            .translation = translation.add(box_offsets.border_pos).add(box_offsets.content_pos),
        });
        try subtree_stack.append(allocator, .{
            .subtree = generating_block_subtree,
            .index_of_root = 0,
        });
    }

    stackLoop: while (block_stack.items.len > 0) {
        const block_item = &block_stack.items[block_stack.items.len - 1];
        const interval = &block_item.interval;

        const subtree_item = &subtree_stack.items[subtree_stack.items.len - 1];
        const subtree = subtree_item.subtree;

        while (interval.begin != interval.end) {
            const block_index = interval.begin;
            const skip = subtree.skip.items[block_index];
            interval.begin += skip;

            switch (subtree.type.items[block_index]) {
                .block => |block_info| {
                    if (block_info.stacking_context) |_| continue;
                },
                .subtree_proxy => |proxied_block| {
                    const proxied_block_subtree = &blocks.subtrees.items[proxied_block];
                    try block_stack.append(allocator, .{
                        .interval = .{ .begin = 0, .end = @intCast(BlockBoxIndex, proxied_block_subtree.skip.items.len) },
                        .translation = block_item.translation,
                    });
                    try subtree_stack.append(allocator, .{
                        .subtree = proxied_block_subtree,
                        .index_of_root = block_stack.items.len - 1,
                    });
                    continue :stackLoop;
                },
            }

            const box_offsets = subtree.box_offsets.items[block_index];
            const borders = subtree.borders.items[block_index];
            const border_colors = subtree.border_colors.items[block_index];
            const background1 = subtree.background1.items[block_index];
            const background2 = subtree.background2.items[block_index];
            //const visual_effect = subtree.visual_effect.items[block_index];
            const boxes = getThreeBoxes(block_item.translation, box_offsets, borders);

            //if (visual_effect.visibility == .Visible) {
            drawBlockContainer(&boxes, borders, background1, background2, border_colors, initial_clip_rect, renderer, pixel_format);
            //}

            if (skip != 1) {
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
                //        .interval = Interval{ .begin = block_box + 1, .end = block_box + skip },
                //        .translation = stack_item.translation.add(box_offsets.content_top_left),
                //        .clip_rect = new_clip_rect,
                //    });
                //    continue :stackLoop;
                //}

                try block_stack.append(allocator, .{
                    .interval = Interval{ .begin = block_index + 1, .end = block_index + skip },
                    .translation = block_item.translation.add(box_offsets.border_pos).add(box_offsets.content_pos),
                });
                continue :stackLoop;
            }
        }

        _ = block_stack.pop();
        if (subtree_item.index_of_root == block_stack.items.len) {
            _ = subtree_stack.pop();
        }
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
    _ = clip_rect;
    const bg_clip_rect = zssRectToSdlRect(switch (background1.clip) {
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
        const origin_rect = zssRectToSdlRect(switch (background2.origin) {
            .Border => boxes.border,
            .Padding => boxes.padding,
            .Content => boxes.content,
        });
        const size = util.ImageSize{
            .w = zssUnitToPixelRatio(background2.size.width),
            .h = zssUnitToPixelRatio(background2.size.height),
        };
        const position = util.ImagePosition{
            .x = zssUnitToPixelRatio(background2.position.x).addInt(origin_rect.x),
            .y = zssUnitToPixelRatio(background2.position.y).addInt(origin_rect.y),
        };

        const convertRepeat = (struct {
            fn f(style: zss.used_values.Background2.Repeat.Style) util.BackgroundRepeatStyle {
                return switch (style) {
                    .None => .None,
                    .Repeat => .Repeat,
                    .Space => .Space,
                    .Round => .Round,
                };
            }
        }).f;
        const repeat = util.BackgroundRepeat{
            .x = convertRepeat(background2.repeat.x),
            .y = convertRepeat(background2.repeat.y),
        };
        util.drawBackgroundImage(
            renderer,
            texture,
            origin_rect,
            bg_clip_rect,
            position,
            size,
            repeat,
        );
    }

    // draw borders
    util.drawBordersSolid(
        renderer,
        pixel_format,
        zssRectToSdlRect(boxes.border),
        util.Widths{
            .top = zssUnitToPixel(borders.top),
            .right = zssUnitToPixel(borders.right),
            .bottom = zssUnitToPixel(borders.bottom),
            .left = zssUnitToPixel(borders.left),
        },
        util.Colors{
            .top_rgba = border_colors.top_rgba,
            .right_rgba = border_colors.right_rgba,
            .bottom_rgba = border_colors.bottom_rgba,
            .left_rgba = border_colors.left_rgba,
        },
    );
}

pub fn drawInlineFormattingContext(
    ifc: *const InlineFormattingContext,
    translation: ZssVector,
    allocator: Allocator,
    renderer: *sdl.SDL_Renderer,
    pixel_format: *sdl.SDL_PixelFormat,
    maybe_atlas: ?*GlyphAtlas,
) !void {
    const color = util.rgbaMap(pixel_format, ifc.font_color_rgba);
    if (maybe_atlas) |atlas| {
        assert(sdl.SDL_SetTextureColorMod(atlas.texture, color[0], color[1], color[2]) == 0);
        assert(sdl.SDL_SetTextureAlphaMod(atlas.texture, color[3]) == 0);
    }

    var inline_box_stack = std.ArrayList(InlineBoxIndex).init(allocator);
    defer inline_box_stack.deinit();

    for (ifc.line_boxes.items) |line_box| {
        for (inline_box_stack.items) |inline_box| {
            const match_info = findMatchingBoxEnd(
                ifc.glyph_indeces.items[line_box.elements[0]..line_box.elements[1]],
                ifc.metrics.items[line_box.elements[0]..line_box.elements[1]],
                inline_box,
            );
            drawInlineBox(
                renderer,
                pixel_format,
                ifc,
                inline_box,
                ZssVector{ .x = translation.x, .y = translation.y + line_box.baseline },
                match_info.advance,
                false,
                match_info.found,
            );
        }

        var cursor: ZssUnit = 0;
        var i = line_box.elements[0];
        while (i < line_box.elements[1]) : (i += 1) {
            const glyph_index = ifc.glyph_indeces.items[i];
            const metrics = ifc.metrics.items[i];
            defer cursor += metrics.advance;

            if (glyph_index == 0) blk: {
                i += 1;
                const special = InlineFormattingContext.Special.decode(ifc.glyph_indeces.items[i]);
                switch (special.kind) {
                    .ZeroGlyphIndex => break :blk,
                    .BoxStart => {
                        const match_info = findMatchingBoxEnd(
                            ifc.glyph_indeces.items[i + 1 .. line_box.elements[1]],
                            ifc.metrics.items[i + 1 .. line_box.elements[1]],
                            special.data,
                        );
                        drawInlineBox(
                            renderer,
                            pixel_format,
                            ifc,
                            special.data,
                            ZssVector{ .x = translation.x + cursor + metrics.offset, .y = translation.y + line_box.baseline },
                            match_info.advance,
                            true,
                            match_info.found,
                        );
                        try inline_box_stack.append(special.data);
                    },
                    .BoxEnd => assert(special.data == inline_box_stack.pop()),
                    .InlineBlock => {},
                    _ => unreachable,
                }
                continue;
            }

            const atlas = maybe_atlas.?;
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
                    .x = zssUnitToPixel(translation.x + cursor + metrics.offset),
                    .y = zssUnitToPixel(translation.y + line_box.baseline) - glyph_info.ascender_px,
                    .w = glyph_info.width,
                    .h = glyph_info.height,
                },
            ) == 0);
        }
    }
}

fn findMatchingBoxEnd(
    glyph_indeces: []const hb.hb_codepoint_t,
    metrics: []const InlineFormattingContext.Metrics,
    inline_box: InlineBoxIndex,
) struct {
    advance: ZssUnit,
    found: bool,
} {
    var found = false;
    var advance: ZssUnit = 0;
    var i: usize = 0;
    while (i < glyph_indeces.len) : (i += 1) {
        const glyph_index = glyph_indeces[i];
        const metric = metrics[i];

        if (glyph_index == 0) {
            i += 1;
            const special = InlineFormattingContext.Special.decode(glyph_indeces[i]);
            if (special.kind == .BoxEnd and @as(InlineBoxIndex, special.data) == inline_box) {
                found = true;
                break;
            }
        }

        advance += metric.advance;
    }

    return .{ .advance = advance, .found = found };
}

fn drawInlineBox(
    renderer: *sdl.SDL_Renderer,
    pixel_format: *sdl.SDL_PixelFormat,
    ifc: *const InlineFormattingContext,
    inline_box: InlineBoxIndex,
    baseline_position: ZssVector,
    middle_length: ZssUnit,
    draw_start: bool,
    draw_end: bool,
) void {
    const inline_start = ifc.inline_start.items[inline_box];
    const inline_end = ifc.inline_end.items[inline_box];
    const block_start = ifc.block_start.items[inline_box];
    const block_end = ifc.block_end.items[inline_box];
    const background1 = ifc.background1.items[inline_box];

    const border = util.Widths{
        .top = zssUnitToPixel(block_start.border),
        .right = zssUnitToPixel(inline_end.border),
        .bottom = zssUnitToPixel(block_end.border),
        .left = zssUnitToPixel(inline_start.border),
    };

    const padding = util.Widths{
        .top = zssUnitToPixel(block_start.padding),
        .right = zssUnitToPixel(inline_end.padding),
        .bottom = zssUnitToPixel(block_end.padding),
        .left = zssUnitToPixel(inline_start.padding),
    };

    const border_colors = util.Colors{
        .top_rgba = block_start.border_color_rgba,
        .right_rgba = inline_end.border_color_rgba,
        .bottom_rgba = block_end.border_color_rgba,
        .left_rgba = inline_start.border_color_rgba,
    };

    const background_clip: util.BackgroundClip = switch (background1.clip) {
        .Border => .Border,
        .Padding => .Padding,
        .Content => .Content,
    };

    util.drawInlineBox(
        renderer,
        pixel_format,
        zssVectorToSdlPoint(baseline_position),
        zssUnitToPixel(ifc.ascender),
        zssUnitToPixel(ifc.descender),
        border,
        padding,
        border_colors,
        background1.color_rgba,
        background_clip,
        zssUnitToPixel(middle_length),
        draw_start,
        draw_end,
    );
}
