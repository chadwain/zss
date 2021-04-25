const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const zss = @import("zss");
const CSSUnit = zss.types.CSSUnit;
const Offset = zss.types.Offset;
const CSSRect = zss.types.CSSRect;
const OffsetTree = zss.offset_tree.OffsetTree;
usingnamespace zss.stacking_context;
usingnamespace zss.used_properties;

usingnamespace @import("SDL2");
const inl = @import("inline_rendering.zig");
const block = @import("block_rendering.zig");
const drawRootElementBlock = block.drawRootElementBlock;
const drawTopElementBlock = block.drawTopElementBlock;
const drawDescendantBlocks = block.drawDescendantBlocks;
const drawInlineContext = inl.drawInlineContext;

pub fn renderStackingContexts(
    stacking_contexts: *const StackingContextTree,
    allocator: *Allocator,
    renderer: *SDL_Renderer,
    pixel_format: *SDL_PixelFormat,
) !void {
    const ItemInner = struct { val: StackingContext, sc: ?*const StackingContextTree };
    const Item = union(enum) {
        topElemRender: ItemInner,
        descendantsRender: ItemInner,
    };

    const ops = struct {
        fn addLeftSubtree(list: *std.ArrayList(Item), context: *const StackingContextTree, midpoint: usize) !void {
            var i = midpoint;
            while (i > 0) : (i -= 1) {
                const value = context.value(i - 1);
                const child = context.child(i - 1);
                try list.append(.{ .topElemRender = .{ .val = value, .sc = child } });
            }
        }

        fn addRightSubtree(list: *std.ArrayList(Item), context: *const StackingContextTree, midpoint: usize) !void {
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

    var stack = std.ArrayList(Item).init(allocator);
    defer stack.deinit();

    {
        const value = stacking_contexts.value(0);
        const child = stacking_contexts.child(0);
        const b = value.inner_context.block;

        drawRootElementBlock(b, value.offset, viewport.intersect(value.clip_rect), renderer, pixel_format);
        try stack.append(.{ .descendantsRender = .{ .val = value, .sc = child } });
        if (child) |sc| try ops.addLeftSubtree(&stack, sc, value.midpoint);
    }

    while (stack.items.len > 0) {
        switch (stack.pop()) {
            .topElemRender => |item| {
                switch (item.val.inner_context) {
                    .block => |b| drawTopElementBlock(b, item.val.offset, viewport.intersect(item.val.clip_rect), renderer, pixel_format),
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
        .block => |b| {
            try drawDescendantBlocks(b, allocator, context.offset, viewport.intersect(context.clip_rect), renderer, pixel_format);

            for (b.inline_data) |inline_data| {
                var offset = context.offset;
                var it = zss.util.PreorderArrayIterator.init(b.preorder_array, inline_data.used_id);
                while (it.next()) |used_id| {
                    offset = offset.add(b.box_offsets[used_id].content_top_left);
                }
                drawInlineContext(inline_data.data, offset, renderer, pixel_format);
            }
        },
        //.inl => |i| try drawInlineContext(i.context, allocator, context.offset, renderer, pixel_format),
        .inl => unreachable,
    }
}
