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
    const offsets = offset_tree.get(id).?;
    const borders = context.borders.get(id) orelse Borders{};
    const background_color = context.background_color.get(id) orelse BackgroundColor{};
    const border_colors = context.border_colors.get(id) orelse BorderColor{};

    drawBackgroundAndBorders(offset, offsets, borders, background_color, border_colors, renderer, pixel_format);
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
    };

    const StackItem = struct {
        offset_tree: *const OffsetTree,
        offset: Offset,
        nodes: struct {
            tree: *const TreeMap(bool),
            borders: *const TreeMap(Borders),
            border_colors: *const TreeMap(BorderColor),
            background_color: *const TreeMap(BackgroundColor),
        },
        indeces: struct {
            tree: usize = 0,
            borders: usize = 0,
            background_color: usize = 0,
            border_colors: usize = 0,
        } = .{},
    };

    if (context.tree.child(0) == null) return;

    var stack = ArrayList(StackItem).init(allocator);
    defer stack.deinit();

    {
        const id = &[1]BlockFormattingContext.IdPart{context.tree.parts.items[0]};
        const tree = context.tree.child(0).?;
        const offset_tree_child = offset_tree.child(0).?;
        const borders = blk: {
            const find = context.borders.find(id);
            if (find.wasFound()) {
                break :blk find.parent.?.child(find.index) orelse &defaults.borders_node;
            } else {
                break :blk &defaults.borders_node;
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
        try stack.append(StackItem{
            .offset_tree = offset_tree_child,
            .offset = offset.add(offset_tree.get(id).?.content_top_left),
            .nodes = .{
                .tree = tree,
                .borders = borders,
                .border_colors = border_colors,
                .background_color = background_color,
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
            const part = nodes.tree.parts.items[indeces.tree];

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

            drawBackgroundAndBorders(stack_item.offset, offsets, borders.data, background_color.data, border_colors.data, renderer, pixel_format);

            if (nodes.tree.child(indeces.tree)) |child_tree| {
                try stack.append(StackItem{
                    .offset_tree = stack_item.offset_tree.child(indeces.tree).?,
                    .offset = stack_item.offset.add(offsets.content_top_left),
                    .nodes = .{
                        .tree = child_tree,
                        .borders = borders.child,
                        .border_colors = border_colors.child,
                        .background_color = background_color.child,
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
    border_colors: BorderColor,
    renderer: *SDL_Renderer,
    pixel_format: *SDL_PixelFormat,
) void {
    const border_x = offset.x + offset_info.border_top_left.x;
    const border_y = offset.y + offset_info.border_top_left.y;
    const bg_width = offset_info.border_bottom_right.x - offset_info.border_top_left.x;
    const bg_height = offset_info.border_bottom_right.y - offset_info.border_top_left.y;
    const border_lr_height = bg_height - borders.border_top - borders.border_bottom;
    const rects = [_]SDL_Rect{
        // background
        SDL_Rect{
            .x = sdl.cssUnitToSdlPixel(border_x),
            .y = sdl.cssUnitToSdlPixel(border_y),
            .w = sdl.cssUnitToSdlPixel(bg_width),
            .h = sdl.cssUnitToSdlPixel(bg_height),
        },
        // top border
        SDL_Rect{
            .x = sdl.cssUnitToSdlPixel(border_x),
            .y = sdl.cssUnitToSdlPixel(border_y),
            .w = sdl.cssUnitToSdlPixel(bg_width),
            .h = sdl.cssUnitToSdlPixel(borders.border_top),
        },
        // right border
        SDL_Rect{
            .x = sdl.cssUnitToSdlPixel(border_x + bg_width - borders.border_right),
            .y = sdl.cssUnitToSdlPixel(border_y + borders.border_top),
            .w = sdl.cssUnitToSdlPixel(borders.border_right),
            .h = sdl.cssUnitToSdlPixel(border_lr_height),
        },
        // bottom border
        SDL_Rect{
            .x = sdl.cssUnitToSdlPixel(border_x),
            .y = sdl.cssUnitToSdlPixel(border_y + bg_height - borders.border_bottom),
            .w = sdl.cssUnitToSdlPixel(bg_width),
            .h = sdl.cssUnitToSdlPixel(borders.border_bottom),
        },
        //left border
        SDL_Rect{
            .x = sdl.cssUnitToSdlPixel(border_x),
            .y = sdl.cssUnitToSdlPixel(border_y + borders.border_top),
            .w = sdl.cssUnitToSdlPixel(borders.border_left),
            .h = sdl.cssUnitToSdlPixel(border_lr_height),
        },
    };

    const colors = [_]u32{
        sdl.rgbaMap(pixel_format, background_color.rgba),
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
