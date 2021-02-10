// This file is a part of zss.
// Copyright (C) 2020-2021 Chadwain Holness
//
// This library is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this library.  If not, see <https://www.gnu.org/licenses/>.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const assert = std.debug.assert;

const zss = @import("../../../zss.zig");
const BlockFormattingContext = zss.BlockFormattingContext;
const Offset = zss.util.Offset;
const OffsetTree = zss.offset_tree.OffsetTree;
const OffsetInfo = zss.offset_tree.OffsetInfo;
const sdl = zss.sdl;
usingnamespace zss.properties;

usingnamespace @import("SDL2");

// TODO delete this
fn TreeMap(comptime V: type) type {
    return @import("prefix-tree-map").PrefixTreeMapUnmanaged(zss.context.ContextSpecificBoxIdPart, V, zss.context.cmpPart);
}

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
    context: *const BlockFormattingContext,
    offset_tree: *const OffsetTree,
    offset: Offset,
    renderer: *SDL_Renderer,
    pixel_format: *SDL_PixelFormat,
) void {
    const id = &[1]BlockFormattingContext.IdPart{context.tree.parts.items[0]};
    const visual_effect = context.visual_effect.get(id) orelse VisualEffect{};
    if (visual_effect.visibility == .Hidden) return;
    const offsets = offset_tree.get(id).?;
    const borders = context.borders.get(id) orelse Borders{};
    const background_color = context.background_color.get(id) orelse BackgroundColor{};
    const background_image = context.background_image.get(id) orelse BackgroundImage{};
    const border_colors = context.border_colors.get(id) orelse BorderColor{};

    const initial_clip_rect = if (SDL_RenderIsClipEnabled(renderer) == .SDL_TRUE) blk: {
        var r: SDL_Rect = undefined;
        SDL_RenderGetClipRect(renderer, &r);
        break :blk r;
    } else null;
    defer if (initial_clip_rect) |*r| {
        assert(SDL_RenderSetClipRect(renderer, r) == 0);
    } else {
        assert(SDL_RenderSetClipRect(renderer, null) == 0);
    };

    const real_initial_clip_rect = initial_clip_rect orelse blk: {
        var r: SDL_Rect = undefined;
        SDL_RenderGetViewport(renderer, &r);
        break :blk r;
    };

    drawBackgroundAndBorders(offset, offsets, borders, background_color, background_image, border_colors, real_initial_clip_rect, renderer, pixel_format);
}

/// Draws the background color, background image, and borders of all of the
/// descendant boxes in a block context (i.e. excluding the top element).
/// This implements §Appendix E.2 Step 4.
///
/// TODO support table boxes
pub fn drawDescendantBlocks(
    context: *const BlockFormattingContext,
    allocator: *Allocator,
    offset_tree: *const OffsetTree,
    offset: Offset,
    renderer: *SDL_Renderer,
    pixel_format: *SDL_PixelFormat,
) !void {
    const defaults = struct {
        const borders_node = TreeMap(Borders){};
        const border_colors_node = TreeMap(BorderColor){};
        const background_color_node = TreeMap(BackgroundColor){};
        const background_image_node = TreeMap(BackgroundImage){};
        const visual_effect_node = TreeMap(VisualEffect){};
    };

    const StackItem = struct {
        offset_tree: *const OffsetTree,
        offset: Offset,
        visible: bool,
        clip_rect: SDL_Rect,
        nodes: struct {
            tree: *const TreeMap(bool),
            borders: *const TreeMap(Borders),
            border_colors: *const TreeMap(BorderColor),
            background_color: *const TreeMap(BackgroundColor),
            background_image: *const TreeMap(BackgroundImage),
            visual_effect: *const TreeMap(VisualEffect),
        },
        indeces: struct {
            tree: usize = 0,
            borders: usize = 0,
            background_color: usize = 0,
            background_image: usize = 0,
            border_colors: usize = 0,
            visual_effect: usize = 0,
        } = .{},
    };

    if (context.tree.child(0) == null) return;

    var stack = ArrayList(StackItem).init(allocator);
    defer stack.deinit();

    const initial_clip_rect = if (SDL_RenderIsClipEnabled(renderer) == .SDL_TRUE) blk: {
        var r: SDL_Rect = undefined;
        SDL_RenderGetClipRect(renderer, &r);
        break :blk r;
    } else null;
    defer if (initial_clip_rect) |*r| {
        assert(SDL_RenderSetClipRect(renderer, r) == 0);
    } else {
        assert(SDL_RenderSetClipRect(renderer, null) == 0);
    };

    const real_initial_clip_rect = initial_clip_rect orelse blk: {
        var r: SDL_Rect = undefined;
        SDL_RenderGetViewport(renderer, &r);
        break :blk r;
    };

    {
        const id = &[1]BlockFormattingContext.IdPart{context.tree.parts.items[0]};
        const tree = context.tree.child(0).?;
        const offset_tree_child = offset_tree.child(0).?;
        const borders: struct { data: Borders, child: *const TreeMap(Borders) } = blk: {
            const find = context.borders.find(id);
            if (find.wasFound()) {
                break :blk .{ .data = find.parent.?.value(find.index), .child = find.parent.?.child(find.index) orelse &defaults.borders_node };
            } else {
                break :blk .{ .data = Borders{}, .child = &defaults.borders_node };
            }
        };
        const border_colors = blk: {
            const find = context.border_colors.find(id);
            if (find.wasFound()) {
                break :blk find.parent.?.child(find.index) orelse &defaults.border_colors_node;
            } else {
                break :blk &defaults.border_colors_node;
            }
        };
        const background_color = blk: {
            const find = context.background_color.find(id);
            if (find.wasFound()) {
                break :blk find.parent.?.child(find.index) orelse &defaults.background_color_node;
            } else {
                break :blk &defaults.background_color_node;
            }
        };
        const background_image = blk: {
            const find = context.background_image.find(id);
            if (find.wasFound()) {
                break :blk find.parent.?.child(find.index) orelse &defaults.background_image_node;
            } else {
                break :blk &defaults.background_image_node;
            }
        };
        const visual_effect: struct { data: VisualEffect, child: *const TreeMap(VisualEffect) } = blk: {
            const find = context.visual_effect.find(id);
            if (find.wasFound()) {
                break :blk .{ .data = find.parent.?.value(find.index), .child = find.parent.?.child(find.index) orelse &defaults.visual_effect_node };
            } else {
                break :blk .{ .data = VisualEffect{}, .child = &defaults.visual_effect_node };
            }
        };

        const offset_info = offset_tree.get(id).?;
        const clip_rect = switch (visual_effect.data.overflow) {
            .Visible => real_initial_clip_rect,
            .Hidden => blk: {
                const padding_rect = SDL_Rect{
                    .x = sdl.cssUnitToSdlPixel(offset.x + offset_info.border_top_left.x + borders.data.left),
                    .y = sdl.cssUnitToSdlPixel(offset.y + offset_info.border_top_left.y + borders.data.top),
                    .w = sdl.cssUnitToSdlPixel((offset_info.border_bottom_right.x - borders.data.right) - (offset_info.border_top_left.x + borders.data.left)),
                    .h = sdl.cssUnitToSdlPixel((offset_info.border_bottom_right.y - borders.data.bottom) - (offset_info.border_top_left.y + borders.data.top)),
                };

                var intersect: SDL_Rect = undefined;
                // NOTE if there is no intersection here, then
                // child elements don't need to be rendered
                _ = SDL_IntersectRect(&real_initial_clip_rect, &padding_rect, &intersect);
                break :blk intersect;
            },
        };
        assert(SDL_RenderSetClipRect(renderer, &clip_rect) == 0);

        try stack.append(StackItem{
            .offset_tree = offset_tree_child,
            .offset = offset.add(offset_info.content_top_left),
            .visible = visual_effect.data.visibility == .Visible,
            .clip_rect = clip_rect,
            .nodes = .{
                .tree = tree,
                .borders = borders.child,
                .border_colors = border_colors,
                .background_color = background_color,
                .background_image = background_image,
                .visual_effect = visual_effect.child,
            },
        });
    }

    stackLoop: while (stack.items.len > 0) {
        const stack_item = &stack.items[stack.items.len - 1];
        const nodes = &stack_item.nodes;
        const indeces = &stack_item.indeces;

        while (indeces.tree < nodes.tree.numChildren()) {
            defer indeces.tree += 1;
            const offsets = stack_item.offset_tree.value(indeces.tree);
            const part = nodes.tree.part(indeces.tree);

            const borders: struct { data: Borders, child: *const TreeMap(Borders) } =
                if (indeces.borders < nodes.borders.numChildren() and nodes.borders.parts.items[indeces.borders] == part)
            blk: {
                const data = nodes.borders.value(indeces.borders);
                const child = nodes.borders.child(indeces.borders);
                indeces.borders += 1;
                break :blk .{ .data = data, .child = child orelse &defaults.borders_node };
            } else .{ .data = Borders{}, .child = &defaults.borders_node };
            const border_colors: struct { data: BorderColor, child: *const TreeMap(BorderColor) } =
                if (indeces.border_colors < nodes.border_colors.numChildren() and nodes.border_colors.parts.items[indeces.border_colors] == part)
            blk: {
                const data = nodes.border_colors.value(indeces.border_colors);
                const child = nodes.border_colors.child(indeces.border_colors);
                indeces.border_colors += 1;
                break :blk .{ .data = data, .child = child orelse &defaults.border_colors_node };
            } else .{ .data = BorderColor{}, .child = &defaults.border_colors_node };
            const background_color: struct { data: BackgroundColor, child: *const TreeMap(BackgroundColor) } =
                if (indeces.background_color < nodes.background_color.numChildren() and nodes.background_color.parts.items[indeces.background_color] == part)
            blk: {
                const data = nodes.background_color.value(indeces.background_color);
                const child = nodes.background_color.child(indeces.background_color);
                indeces.background_color += 1;
                break :blk .{ .data = data, .child = child orelse &defaults.background_color_node };
            } else .{ .data = BackgroundColor{}, .child = &defaults.background_color_node };
            const background_image: struct { data: BackgroundImage, child: *const TreeMap(BackgroundImage) } =
                if (indeces.background_image < nodes.background_image.numChildren() and nodes.background_image.parts.items[indeces.background_image] == part)
            blk: {
                const data = nodes.background_image.value(indeces.background_image);
                const child = nodes.background_image.child(indeces.background_image);
                indeces.background_image += 1;
                break :blk .{ .data = data, .child = child orelse &defaults.background_image_node };
            } else .{ .data = BackgroundImage{}, .child = &defaults.background_image_node };
            const visual_effect: struct { data: VisualEffect, child: *const TreeMap(VisualEffect) } =
                if (indeces.visual_effect < nodes.visual_effect.numChildren() and nodes.visual_effect.parts.items[indeces.visual_effect] == part)
            blk: {
                const data = nodes.visual_effect.value(indeces.visual_effect);
                const child = nodes.visual_effect.child(indeces.visual_effect);
                indeces.visual_effect += 1;
                break :blk .{ .data = data, .child = child orelse &defaults.visual_effect_node };
            } else .{ .data = VisualEffect{ .visibility = if (stack_item.visible) .Visible else .Hidden }, .child = &defaults.visual_effect_node };

            if (visual_effect.data.visibility == .Visible) {
                drawBackgroundAndBorders(stack_item.offset, offsets, borders.data, background_color.data, background_image.data, border_colors.data, stack_item.clip_rect, renderer, pixel_format);
            }

            if (nodes.tree.child(indeces.tree)) |child_tree| {
                const new_clip_rect = switch (visual_effect.data.overflow) {
                    .Visible => stack_item.clip_rect,
                    .Hidden => blk: {
                        const padding_rect = SDL_Rect{
                            .x = sdl.cssUnitToSdlPixel(stack_item.offset.x + offsets.border_top_left.x + borders.data.left),
                            .y = sdl.cssUnitToSdlPixel(stack_item.offset.y + offsets.border_top_left.y + borders.data.top),
                            .w = sdl.cssUnitToSdlPixel((offsets.border_bottom_right.x - borders.data.right) - (offsets.border_top_left.x + borders.data.left)),
                            .h = sdl.cssUnitToSdlPixel((offsets.border_bottom_right.y - borders.data.bottom) - (offsets.border_top_left.y + borders.data.top)),
                        };
                        var intersect: SDL_Rect = undefined;
                        // NOTE if there is no intersection here, then
                        // child elements don't need to be rendered
                        _ = SDL_IntersectRect(&stack_item.clip_rect, &padding_rect, &intersect);
                        break :blk intersect;
                    },
                };
                assert(SDL_RenderSetClipRect(renderer, &new_clip_rect) == 0);

                try stack.append(StackItem{
                    .offset_tree = stack_item.offset_tree.child(indeces.tree).?,
                    .offset = stack_item.offset.add(offsets.content_top_left),
                    .visible = visual_effect.data.visibility == .Visible,
                    .clip_rect = new_clip_rect,
                    .nodes = .{
                        .tree = child_tree,
                        .borders = borders.child,
                        .border_colors = border_colors.child,
                        .background_color = background_color.child,
                        .background_image = background_image.child,
                        .visual_effect = visual_effect.child,
                    },
                });
                continue :stackLoop;
            }
        }

        _ = stack.pop();
    }
}

fn drawBackgroundAndBorders(
    offset: Offset,
    offset_info: OffsetInfo,
    borders: Borders,
    background_color: BackgroundColor,
    background_image: BackgroundImage,
    border_colors: BorderColor,
    clip_rect: SDL_Rect,
    renderer: *SDL_Renderer,
    pixel_format: *SDL_PixelFormat,
) void {
    const border_x = offset.x + offset_info.border_top_left.x;
    const border_y = offset.y + offset_info.border_top_left.y;
    const bg_width = offset_info.border_bottom_right.x - offset_info.border_top_left.x;
    const bg_height = offset_info.border_bottom_right.y - offset_info.border_top_left.y;
    const border_lr_height = bg_height - borders.top - borders.bottom;

    const border_rect = SDL_Rect{
        .x = sdl.cssUnitToSdlPixel(border_x),
        .y = sdl.cssUnitToSdlPixel(border_y),
        .w = sdl.cssUnitToSdlPixel(bg_width),
        .h = sdl.cssUnitToSdlPixel(bg_height),
    };
    const padding_rect = SDL_Rect{
        .x = sdl.cssUnitToSdlPixel(border_x + borders.left),
        .y = sdl.cssUnitToSdlPixel(border_y + borders.top),
        .w = sdl.cssUnitToSdlPixel(bg_width - borders.left - borders.right),
        .h = sdl.cssUnitToSdlPixel(bg_height - borders.top - borders.bottom),
    };
    const content_rect = SDL_Rect{
        .x = sdl.cssUnitToSdlPixel(offset.x + offset_info.content_top_left.x),
        .y = sdl.cssUnitToSdlPixel(offset.y + offset_info.content_top_left.y),
        .w = sdl.cssUnitToSdlPixel(offset_info.content_bottom_right.x - offset_info.content_top_left.x),
        .h = sdl.cssUnitToSdlPixel(offset_info.content_bottom_right.y - offset_info.content_top_left.y),
    };

    const bg_clip_rect = switch (background_image.clip) {
        .Border => border_rect,
        .Padding => padding_rect,
        .Content => content_rect,
    };

    {
        const bg_color = sdl.rgbaMap(pixel_format, background_color.rgba);
        var rgba: [4]u8 = undefined;
        SDL_GetRGBA(bg_color, pixel_format, &rgba[0], &rgba[1], &rgba[2], &rgba[3]);
        assert(SDL_SetRenderDrawColor(renderer, rgba[0], rgba[1], rgba[2], rgba[3]) == 0);
        assert(SDL_RenderFillRect(renderer, &bg_clip_rect) == 0);
    }

    if (background_image.data) |data| {
        const texture = @intToPtr(*SDL_Texture, data);
        const dest_rect = blk: {
            const origin_rect = switch (background_image.origin) {
                .Border => border_rect,
                .Padding => padding_rect,
                .Content => content_rect,
            };

            var result: SDL_Rect = undefined;
            assert(SDL_QueryTexture(texture, null, null, &result.w, &result.h) == 0);
            result.x = origin_rect.x + @floatToInt(c_int, @intToFloat(f32, origin_rect.w - result.w) * background_image.position.horizontal);
            result.y = origin_rect.y + @floatToInt(c_int, @intToFloat(f32, origin_rect.h - result.h) * background_image.position.vertical);
            break :blk result;
        };

        const draw_region = blk: {
            var result: SDL_Rect = undefined;
            // NOTE if there is no intersection here, then
            // the image doesn't need to be rendered
            _ = SDL_IntersectRect(&clip_rect, &bg_clip_rect, &result);
            break :blk result;
        };
        assert(SDL_RenderSetClipRect(renderer, &draw_region) == 0);
        defer assert(SDL_RenderSetClipRect(renderer, &clip_rect) == 0);

        assert(SDL_RenderCopy(renderer, texture, null, &dest_rect) == 0);
    }

    const rects = [_]SDL_Rect{
        // top border
        SDL_Rect{
            .x = sdl.cssUnitToSdlPixel(border_x),
            .y = sdl.cssUnitToSdlPixel(border_y),
            .w = sdl.cssUnitToSdlPixel(bg_width),
            .h = sdl.cssUnitToSdlPixel(borders.top),
        },
        // right border
        SDL_Rect{
            .x = sdl.cssUnitToSdlPixel(border_x + bg_width - borders.right),
            .y = sdl.cssUnitToSdlPixel(border_y + borders.top),
            .w = sdl.cssUnitToSdlPixel(borders.right),
            .h = sdl.cssUnitToSdlPixel(border_lr_height),
        },
        // bottom border
        SDL_Rect{
            .x = sdl.cssUnitToSdlPixel(border_x),
            .y = sdl.cssUnitToSdlPixel(border_y + bg_height - borders.bottom),
            .w = sdl.cssUnitToSdlPixel(bg_width),
            .h = sdl.cssUnitToSdlPixel(borders.bottom),
        },
        //left border
        SDL_Rect{
            .x = sdl.cssUnitToSdlPixel(border_x),
            .y = sdl.cssUnitToSdlPixel(border_y + borders.top),
            .w = sdl.cssUnitToSdlPixel(borders.left),
            .h = sdl.cssUnitToSdlPixel(border_lr_height),
        },
    };

    const colors = [_]u32{
        sdl.rgbaMap(pixel_format, border_colors.top_rgba),
        sdl.rgbaMap(pixel_format, border_colors.right_rgba),
        sdl.rgbaMap(pixel_format, border_colors.bottom_rgba),
        sdl.rgbaMap(pixel_format, border_colors.left_rgba),
    };

    for (rects) |_, i| {
        var rgba: [4]u8 = undefined;
        SDL_GetRGBA(colors[i], pixel_format, &rgba[0], &rgba[1], &rgba[2], &rgba[3]);
        assert(SDL_SetRenderDrawColor(renderer, rgba[0], rgba[1], rgba[2], rgba[3]) == 0);
        assert(SDL_RenderFillRect(renderer, &rects[i]) == 0);
    }
}
