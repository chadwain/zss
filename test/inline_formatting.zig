//pub const sdl = @cImport({
//    @cInclude("SDL2/SDL.h");
//});
//usingnamespace sdl;
const std = @import("std");
const assert = std.debug.assert;
const expect = std.testing.expect;
const zss = @import("zss");
usingnamespace zss.sdl.sdl;

test "" {
    assert(SDL_Init(SDL_INIT_VIDEO) == 0);
    defer SDL_Quit();

    const width = 800;
    const height = 600;
    const window = SDL_CreateWindow(
        "An SDL Window.",
        SDL_WINDOWPOS_CENTERED_MASK,
        SDL_WINDOWPOS_CENTERED_MASK,
        width,
        height,
        SDL_WINDOW_SHOWN | SDL_WINDOW_RESIZABLE,
    ) orelse unreachable;
    defer SDL_DestroyWindow(window);

    const renderer = SDL_CreateRenderer(
        window,
        -1,
        SDL_RENDERER_ACCELERATED | SDL_RENDERER_PRESENTVSYNC,
    ) orelse unreachable;
    defer SDL_DestroyRenderer(renderer);

    const pixelFormat = SDL_GetWindowPixelFormat(window);
    const surface = SDL_CreateRGBSurfaceWithFormat(0, width, height, 32, pixelFormat) orelse unreachable;
    defer SDL_FreeSurface(surface);
    assert(SDL_SetSurfaceBlendMode(surface, SDL_BlendMode.SDL_BLENDMODE_BLEND) == 0);

    try exampleInlineContext(surface);

    const texture = SDL_CreateTextureFromSurface(renderer, surface);
    defer SDL_DestroyTexture(texture);
    const textureRect = SDL_Rect{
        .x = 0,
        .y = 0,
        .w = width,
        .h = height,
    };

    var running: bool = true;
    var event: SDL_Event = undefined;
    while (running) {
        while (SDL_PollEvent(&event) != 0) {
            if (event.@"type" == SDL_WINDOWEVENT) {
                if (event.window.event == SDL_WINDOWEVENT_CLOSE)
                    running = false;
            } else if (event.@"type" == SDL_QUIT) {
                running = false;
            }
        }

        std.debug.assert(SDL_RenderClear(renderer) >= 0);
        std.debug.assert(SDL_RenderCopy(renderer, texture, null, &textureRect) >= 0);
        SDL_RenderPresent(renderer);
    }
}

fn exampleInlineContext(surface: *SDL_Surface) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer expect(!gpa.deinit());

    var inl_ctx = try zss.InlineFormattingContext.init(&gpa.allocator);
    defer inl_ctx.deinit();

    {
        try inl_ctx.line_boxes.appendSlice(inl_ctx.allocator, &[_]zss.InlineFormattingContext.LineBox{
            .{ .y_pos = 0, .baseline = 30 }, // height = 30
            .{ .y_pos = 30, .baseline = 50 }, // height = 70
            .{ .y_pos = 100, .baseline = 30 }, // height = doesn't matter
        });
    }

    {
        const key = @as(zss.InlineFormattingContext.MapKey, 0);
        try inl_ctx.tree.insert(&[1]zss.InlineFormattingContext.TreeValue{.{ .tree_val = 0, .map_key = key }});
        try inl_ctx.width.putNoClobber(inl_ctx.allocator, key, .{ .width = 400 });
        try inl_ctx.height.putNoClobber(inl_ctx.allocator, key, .{ .height = 30 });
        try inl_ctx.background_color.putNoClobber(inl_ctx.allocator, key, .{ .rgba = 0xff223300 });
        try inl_ctx.position.putNoClobber(inl_ctx.allocator, key, .{ .line_box_index = 0, .advance = 0, .ascender = 30 });
    }

    {
        const key = @as(zss.InlineFormattingContext.MapKey, 1);
        try inl_ctx.tree.insert(&[_]zss.InlineFormattingContext.TreeValue{.{ .tree_val = 1, .map_key = key }});
        try inl_ctx.width.putNoClobber(inl_ctx.allocator, key, .{ .width = 400 });
        try inl_ctx.height.putNoClobber(inl_ctx.allocator, key, .{ .height = 20 });
        try inl_ctx.background_color.putNoClobber(inl_ctx.allocator, key, .{ .rgba = 0x00df1213 });
        try inl_ctx.position.putNoClobber(inl_ctx.allocator, key, .{ .line_box_index = 0, .advance = 400, .ascender = 20 });
    }

    {
        const key = @as(zss.InlineFormattingContext.MapKey, 2);
        try inl_ctx.tree.insert(&[_]zss.InlineFormattingContext.TreeValue{.{ .tree_val = 2, .map_key = key }});
        try inl_ctx.width.putNoClobber(inl_ctx.allocator, key, .{ .width = 40 });
        try inl_ctx.height.putNoClobber(inl_ctx.allocator, key, .{ .height = 40 });
        try inl_ctx.background_color.putNoClobber(inl_ctx.allocator, key, .{ .rgba = 0x5c76d3ff });
        try inl_ctx.position.putNoClobber(inl_ctx.allocator, key, .{ .line_box_index = 1, .advance = 200, .ascender = 40 });
    }

    {
        const key = @as(zss.InlineFormattingContext.MapKey, 3);
        try inl_ctx.tree.insert(&[_]zss.InlineFormattingContext.TreeValue{.{ .tree_val = 3, .map_key = key }});
        try inl_ctx.width.putNoClobber(inl_ctx.allocator, key, .{ .width = 40 });
        try inl_ctx.height.putNoClobber(inl_ctx.allocator, key, .{ .height = 40 });
        try inl_ctx.background_color.putNoClobber(inl_ctx.allocator, key, .{ .rgba = 0x306892ff });
        try inl_ctx.position.putNoClobber(inl_ctx.allocator, key, .{ .line_box_index = 1, .advance = 240, .ascender = 20 });
    }

    try zss.sdl.renderInlineFormattingContext(
        inl_ctx,
        &gpa.allocator,
        surface,
        .{ .offset_x = 0, .offset_y = 0 },
    );
}
