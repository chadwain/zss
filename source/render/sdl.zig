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
const RenderTree = zss.RenderTree;

const block = @import("sdl/block.zig");
pub const DrawBlockState = block.DrawBlockState;
pub const drawBlockContext = block.drawBlockContext;
const @"inline" = @import("sdl/inline.zig");
pub const DrawInlineState = @"inline".DrawInlineState;
pub const drawInlineContext = @"inline".drawInlineContext;

const sdl = @import("SDL2");

pub const ContextDrawState = union(enum) {
    block_state: DrawBlockState,
    inline_state: DrawInlineState,
};

pub const StackItem = struct {
    context_id: RenderTree.ContextId,
    state: *ContextDrawState,
    offset: Offset,
};

pub const RenderState = struct {
    tree: *const RenderTree,
    allocator: *Allocator,
    stack: ArrayListUnmanaged(StackItem) = .{},
    state_map: AutoHashMapUnmanaged(RenderTree.ContextId, ContextDrawState) = .{},

    const Self = @This();

    pub fn init(allocator: *Allocator, tree: *const RenderTree) !Self {
        var result = Self{
            .allocator = allocator,
            .tree = tree,
        };
        errdefer result.deinit();

        {
            var it = tree.contexts.iterator();
            while (it.next()) |entry| {
                const state = switch (entry.value) {
                    .block => |b| ContextDrawState{ .block_state = try DrawBlockState.init(b, result.allocator) },
                    .@"inline" => |i| ContextDrawState{ .inline_state = try DrawInlineState.init(i, allocator) },
                };
                try result.state_map.putNoClobber(result.allocator, entry.key, state);
            }
        }

        const root = tree.root_context_id;
        try result.stack.append(
            result.allocator,
            StackItem{
                .context_id = root,
                .state = &result.state_map.getEntry(root).?.value,
                .offset = .{ .x = 0, .y = 0 },
            },
        );

        return result;
    }

    pub fn deinit(self: *Self) void {
        {
            var it = self.state_map.iterator();
            while (it.next()) |entry| {
                switch (entry.value) {
                    .block_state => |*b| b.deinit(),
                    .inline_state => |*i| i.deinit(),
                }
            }
        }
        self.stack.deinit(self.allocator);
        self.state_map.deinit(self.allocator);
    }
};

pub fn render(state: *RenderState, renderer: *sdl.SDL_Renderer, pixel_format: *sdl.SDL_PixelFormat) !void {
    const stack = &state.stack;
    while (stack.items.len > 0) {
        const item = stack.items[stack.items.len - 1];
        const should_pop = switch (item.state.*) {
            .block_state => |*b| try drawBlockContext(b, state, renderer, pixel_format, item.offset, item.context_id),
            .inline_state => |*i| try drawInlineContext(i, renderer, pixel_format, item.offset),
        };
        if (should_pop) _ = stack.pop();
    }
}

pub fn pushDescendant(state: *RenderState, context_id: RenderTree.ContextId, offset: Offset) !void {
    const descendant = &(state.state_map.getEntry(context_id) orelse unreachable).value;
    try state.stack.append(state.allocator, StackItem{ .context_id = context_id, .state = descendant, .offset = offset });
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
