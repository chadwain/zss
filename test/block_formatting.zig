//pub const sdl = @cImport({
//    @cInclude("SDL2/SDL.h");
//});
//usingnamespace sdl;
const std = @import("std");
const assert = std.debug.assert;
const expect = std.testing.expect;
const zss = @import("zss");
usingnamespace zss.render_sdl.sdl;

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

    try exampleBlockContext(surface);

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

fn exampleBlockContext(surface: *SDL_Surface) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer expect(!gpa.deinit());

    var blk_ctx = try zss.BlockFormattingContext.init(&gpa.allocator);
    defer blk_ctx.deinit();

    {
        const key = zss.BlockFormattingContext.root_map_key;
        try blk_ctx.width.putNoClobber(blk_ctx.allocator, key, .{ .width = 800 });
        try blk_ctx.height.putNoClobber(blk_ctx.allocator, key, .{ .height = 600 });
        try blk_ctx.background_color.putNoClobber(blk_ctx.allocator, key, .{ .rgba = 0xff223300 });
    }

    {
        const key = @as(zss.BlockFormattingContext.MapKey, 1);
        try blk_ctx.tree.insert(&[1]zss.BlockFormattingContext.TreeValue{.{ .tree_val = 0, .map_key = key }});
        try blk_ctx.width.putNoClobber(blk_ctx.allocator, key, .{ .width = 100 });
        try blk_ctx.height.putNoClobber(blk_ctx.allocator, key, .{ .height = 100 });
        try blk_ctx.background_color.putNoClobber(blk_ctx.allocator, key, .{ .rgba = 0x00df1213 });
    }

    try zss.render_sdl.renderBlockFormattingContext(
        blk_ctx,
        &gpa.allocator,
        .{ .surface = surface },
    );
}
