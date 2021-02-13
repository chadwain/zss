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
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const AutoHashMapUnmanaged = std.AutoHashMapUnmanaged;

const zss = @import("../../zss.zig");
const CSSUnit = zss.types.CSSUnit;
const Offset = zss.types.Offset;
const CSSRect = zss.types.CSSRect;
usingnamespace zss.stacking_context;

const block = @import("sdl/block.zig");
pub const drawRootElementBlock = block.drawRootElementBlock;
pub const drawTopElementBlock = block.drawTopElementBlock;
pub const drawDescendantBlocks = block.drawDescendantBlocks;
const inl = @import("sdl/inline.zig");
pub const drawInlineContext = inl.drawInlineContext;

usingnamespace @import("SDL2");

pub fn renderStackingContexts(
    stacking_contexts: *const StackingContextTree,
    allocator: *Allocator,
    renderer: *SDL_Renderer,
    pixel_format: *SDL_PixelFormat,
) !void {
    const StackItemInner = struct { val: StackingContext, sc: ?*const StackingContextTree };
    const StackItem = union(enum) {
        topElemRender: StackItemInner,
        descendantsRender: StackItemInner,
    };

    const ops = struct {
        fn addLeftSubtree(list: *std.ArrayList(StackItem), context: *const StackingContextTree, midpoint: usize) !void {
            var i = midpoint;
            while (i > 0) : (i -= 1) {
                const value = context.value(i - 1);
                const child = context.child(i - 1);
                try list.append(.{ .topElemRender = .{ .val = value, .sc = child } });
            }
        }

        fn addRightSubtree(list: *std.ArrayList(StackItem), context: *const StackingContextTree, midpoint: usize) !void {
            var i = context.numChildren();
            while (i > midpoint) : (i -= 1) {
                const value = context.value(i - 1);
                const child = context.child(i - 1);
                try list.append(.{ .topElemRender = .{ .val = value, .sc = child } });
            }
        }
    };

    const sdl_clip_rect = if (SDL_RenderIsClipEnabled(renderer) == .SDL_TRUE) blk: {
        var r: SDL_Rect = undefined;
        SDL_RenderGetClipRect(renderer, &r);
        break :blk r;
    } else null;
    defer if (sdl_clip_rect) |*r| {
        assert(SDL_RenderSetClipRect(renderer, r) == 0);
    } else {
        assert(SDL_RenderSetClipRect(renderer, null) == 0);
    };

    const viewport = sdlRectToCssRect(
        sdl_clip_rect orelse blk: {
            var r: SDL_Rect = undefined;
            SDL_RenderGetViewport(renderer, &r);
            break :blk r;
        },
    );

    var stack = std.ArrayList(StackItem).init(allocator);
    defer stack.deinit();

    {
        const value = stacking_contexts.value(0);
        const child = stacking_contexts.child(0);
        const b = value.inner_context.block;

        drawRootElementBlock(b.context, b.offset_tree, value.offset, viewport.intersect(value.clip_rect), renderer, pixel_format);
        try stack.append(.{ .descendantsRender = .{ .val = value, .sc = child } });
        if (child) |sc| try ops.addLeftSubtree(&stack, sc, value.midpoint);
    }

    while (stack.items.len > 0) {
        switch (stack.pop()) {
            .topElemRender => |item| {
                switch (item.val.inner_context) {
                    .block => |b| drawTopElementBlock(b.context, b.offset_tree, item.val.offset, viewport.intersect(item.val.clip_rect), renderer, pixel_format),
                    else => {},
                }
                try stack.append(.{ .descendantsRender = item });
                if (item.sc) |sc| try ops.addLeftSubtree(&stack, sc, item.val.midpoint);
            },
            .descendantsRender => |item| {
                try renderStackingContext(item.val, viewport, allocator, renderer, pixel_format);
                if (item.sc) |sc| try ops.addRightSubtree(&stack, sc, item.val.midpoint);
            },
        }
    }
}

fn renderStackingContext(
    context: StackingContext,
    viewport: CSSRect,
    allocator: *Allocator,
    renderer: *SDL_Renderer,
    pixel_format: *SDL_PixelFormat,
) !void {
    switch (context.inner_context) {
        .block => |b| try drawDescendantBlocks(b.context, allocator, b.offset_tree, context.offset, viewport.intersect(context.clip_rect), renderer, pixel_format),
        .inl => |i| try drawInlineContext(i.context, allocator, context.offset, renderer, pixel_format),
    }
}

pub fn cssUnitToSdlPixel(css: CSSUnit) i32 {
    return css;
}

pub fn cssRectToSdlRect(css: CSSRect) SDL_Rect {
    return SDL_Rect{
        .x = cssUnitToSdlPixel(css.x),
        .y = cssUnitToSdlPixel(css.y),
        .w = cssUnitToSdlPixel(css.w),
        .h = cssUnitToSdlPixel(css.h),
    };
}

pub fn sdlRectToCssRect(rect: SDL_Rect) CSSRect {
    return CSSRect{
        .x = rect.x,
        .y = rect.y,
        .w = rect.w,
        .h = rect.h,
    };
}

pub fn rgbaMap(pixel_format: *SDL_PixelFormat, color: u32) u32 {
    const color_le = std.mem.nativeToLittle(u32, color);
    return SDL_MapRGBA(
        pixel_format,
        @truncate(u8, color_le >> 24),
        @truncate(u8, color_le >> 16),
        @truncate(u8, color_le >> 8),
        @truncate(u8, color_le),
    );
}

pub fn textureAsBackgroundImage(texture: *SDL_Texture) zss.properties.BackgroundImage.Data {
    return @ptrCast(zss.properties.BackgroundImage.Data, texture);
}
