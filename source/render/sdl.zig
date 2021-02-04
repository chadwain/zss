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
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const AutoHashMapUnmanaged = std.AutoHashMapUnmanaged;

const zss = @import("../../zss.zig");
const CSSUnit = zss.properties.CSSUnit;
const Offset = zss.util.Offset;
usingnamespace zss.stacking_context;

const block = @import("sdl/block.zig");
pub const drawRootElementBlock = block.drawRootElementBlock;
pub const drawTopElementBlock = block.drawTopElementBlock;
pub const drawDescendantBlocks = block.drawDescendantBlocks;
const inl = @import("sdl/inline.zig");
pub const drawInlineContext = inl.drawInlineContext;

const sdl = @import("SDL2");

pub fn renderStackingContexts(
    stacking_contexts: *const StackingContextTree,
    allocator: *Allocator,
    renderer: *sdl.SDL_Renderer,
    pixel_format: *sdl.SDL_PixelFormat,
) !void {
    const StackItemInner = struct { val: StackingContext, sc: ?*const StackingContextTree };
    const StackItem = union(enum) {
        topElemRender: StackItemInner,
        descendantsRender: StackItemInner,
    };
    var stack = std.ArrayList(StackItem).init(allocator);
    defer stack.deinit();

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

    {
        const value = stacking_contexts.value(0);
        const child = stacking_contexts.child(0);
        const b = value.inner_context.block;
        drawRootElementBlock(b.context, b.offset_tree, value.offset, renderer, pixel_format);
        try stack.append(.{ .descendantsRender = .{ .val = value, .sc = child } });
        if (child) |sc| try ops.addLeftSubtree(&stack, sc, value.midpoint);
    }
    while (stack.items.len > 0) {
        switch (stack.pop()) {
            .topElemRender => |item| {
                switch (item.val.inner_context) {
                    .block => |b| drawTopElementBlock(b.context, b.offset_tree, item.val.offset, renderer, pixel_format),
                    else => {},
                }
                try stack.append(.{ .descendantsRender = item });
                if (item.sc) |sc| try ops.addLeftSubtree(&stack, sc, item.val.midpoint);
            },
            .descendantsRender => |item| {
                try renderStackingContext(item.val, allocator, renderer, pixel_format);
                if (item.sc) |sc| try ops.addRightSubtree(&stack, sc, item.val.midpoint);
            },
        }
    }
}

fn renderStackingContext(
    context: StackingContext,
    allocator: *Allocator,
    renderer: *sdl.SDL_Renderer,
    pixel_format: *sdl.SDL_PixelFormat,
) !void {
    switch (context.inner_context) {
        .block => |b| try drawDescendantBlocks(b.context, allocator, b.offset_tree, context.offset, renderer, pixel_format),
        .inl => |i| try drawInlineContext(i.context, allocator, context.offset, renderer, pixel_format),
    }
}

pub fn cssUnitToSdlPixel(css: CSSUnit) i32 {
    return css;
}

pub fn rgbaMap(pixel_format: *sdl.SDL_PixelFormat, color: u32) u32 {
    const color_le = std.mem.nativeToLittle(u32, color);
    return sdl.SDL_MapRGBA(
        pixel_format,
        @truncate(u8, color_le >> 24),
        @truncate(u8, color_le >> 16),
        @truncate(u8, color_le >> 8),
        @truncate(u8, color_le),
    );
}
