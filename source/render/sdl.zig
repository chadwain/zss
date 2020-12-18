// This file is a part of zss.
// Copyright (C) 2020 Chadwain Holness
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

pub const sdl = @cImport({
    @cInclude("SDL2/SDL.h");
});

const zss = @import("../../zss.zig");
const CSSUnit = zss.properties.CSSUnit;
const RenderTree = zss.RenderTree;

const block = @import("sdl/block.zig");
pub const BlockRenderState = block.BlockRenderState;
pub const renderBlockFormattingContext = block.renderBlockFormattingContext;
const @"inline" = @import("sdl/inline.zig");
pub const renderInlineFormattingContext = @"inline".renderInlineFormattingContext;

pub const Offset = struct {
    x: CSSUnit,
    y: CSSUnit,

    pub fn add(self: @This(), other: @This()) @This() {
        return .{ .x = self.x + other.x, .y = self.y + other.y };
    }
};

pub const StateUnion = union(enum) {
    block_state: BlockRenderState,
    //inline_state: InlineRenderState,
};

pub const StateStackItem = struct {
    ctxId: RenderTree.ContextId,
    state: *StateUnion,
    offset: Offset,
};

pub const RenderState = struct {
    tree: *const RenderTree,
    allocator: *Allocator,
    stack: ArrayListUnmanaged(StateStackItem) = .{},
    state_map: AutoHashMapUnmanaged(RenderTree.ContextId, StateUnion) = .{},

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
                    .block => |b| StateUnion{ .block_state = try BlockRenderState.init(b, result.allocator) },
                    .@"inline" => @panic("unimplemented"),
                };
                try result.state_map.putNoClobber(result.allocator, entry.key, state);
            }
        }

        const root = tree.root_context_id;
        try result.stack.append(
            result.allocator,
            StateStackItem{
                .ctxId = root,
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
                    .block_state => |b| b.deinit(),
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
            .block_state => |*b| try renderBlockFormattingContext(b, state, renderer, pixel_format, item.offset, item.ctxId),
            //.inline_state => |i| try renderInlineFormattingContext(i, renderer, pixel_format),
        };
        if (should_pop) _ = stack.pop();
    }
}

pub fn pushDescendant(state: *RenderState, ctxId: RenderTree.ContextId, offset: Offset) !void {
    const descendant = &(state.state_map.getEntry(ctxId) orelse unreachable).value;
    try state.stack.append(state.allocator, StateStackItem{ .ctxId = ctxId, .state = descendant, .offset = offset });
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
