//pub const sdl = @cImport({
//    @cInclude("SDL2/SDL.h");
//});
//usingnamespace sdl;
const std = @import("std");
const assert = std.debug.assert;
const expect = std.testing.expect;
const zss = @import("zss");
usingnamespace zss.sdl.sdl;

test "render block formating context using SDL" {
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

    const window_texture = SDL_GetRenderTarget(renderer);

    const texture_pixel_format = SDL_AllocFormat(SDL_PIXELFORMAT_RGBA32) orelse unreachable;
    defer SDL_FreeFormat(texture_pixel_format);
    const texture = SDL_CreateTexture(
        renderer,
        texture_pixel_format.*.format,
        SDL_TEXTUREACCESS_TARGET,
        width,
        height,
    ) orelse unreachable;
    defer SDL_DestroyTexture(texture);
    assert(SDL_SetRenderTarget(renderer, texture) == 0);

    try exampleBlockContext(renderer, texture_pixel_format);
    SDL_RenderPresent(renderer);

    assert(SDL_SetRenderTarget(renderer, window_texture) == 0);
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

        assert(SDL_RenderClear(renderer) == 0);
        assert(SDL_RenderCopy(renderer, texture, null, &SDL_Rect{
            .x = 0,
            .y = 0,
            .w = width,
            .h = height,
        }) == 0);
        SDL_RenderPresent(renderer);
    }
}

fn exampleBlockContext(renderer: *SDL_Renderer, pixel_format: *SDL_PixelFormat) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer expect(!gpa.deinit());

    var blk_ctx = try zss.BlockFormattingContext.init(&gpa.allocator);
    defer blk_ctx.deinit();

    const TreeValue = zss.BlockFormattingContext.TreeValue;

    const root = [_]TreeValue{.{ .tree_val = 0, .map_key = 0 }};
    {
        const val = root[root.len - 1];
        const key = val.map_key;
        try blk_ctx.tree.insertChild(&[_]TreeValue{}, val, blk_ctx.allocator);
        try blk_ctx.set(key, .width, .{ .width = 800 });
        try blk_ctx.set(key, .height, .{ .height = 600 });
        try blk_ctx.set(key, .background_color, .{ .rgba = 0xff223300 });
        try blk_ctx.set(key, .border_padding_left_right, .{ .padding_left = 100 });
        try blk_ctx.set(key, .border_padding_top_bottom, .{ .padding_top = 200 });
    }

    const root_0 = root ++ [_]TreeValue{.{ .tree_val = 0, .map_key = 1 }};
    {
        const val = root_0[root_0.len - 1];
        const key = val.map_key;
        try blk_ctx.tree.insertChild(&root, val, blk_ctx.allocator);
        try blk_ctx.set(key, .width, .{ .width = 100 });
        try blk_ctx.set(key, .height, .{ .height = 100 });
        try blk_ctx.set(key, .background_color, .{ .rgba = 0x00df1213 });
        try blk_ctx.set(key, .margin_left_right, .{ .margin_left = 250 });
        try blk_ctx.set(key, .margin_top_bottom, .{ .margin_top = 50 });
    }

    const root_0_0 = root_0 ++ [_]TreeValue{.{ .tree_val = 0, .map_key = 2 }};
    {
        const val = root_0_0[root_0_0.len - 1];
        const key = val.map_key;
        try blk_ctx.tree.insertChild(&root_0, val, blk_ctx.allocator);
        try blk_ctx.set(key, .width, .{ .width = 40 });
        try blk_ctx.set(key, .height, .{ .height = 40 });
        try blk_ctx.set(key, .background_color, .{ .rgba = 0x5c76d3ff });
    }

    const root_1 = root ++ [_]TreeValue{.{ .tree_val = 1, .map_key = 3 }};
    {
        const val = root_1[root_1.len - 1];
        const key = val.map_key;
        try blk_ctx.tree.insertChild(&root, val, blk_ctx.allocator);
        try blk_ctx.set(key, .width, .{ .width = 100 });
        try blk_ctx.set(key, .height, .{ .height = 100 });
        try blk_ctx.set(key, .background_color, .{ .rgba = 0x306892ff });
    }

    try zss.sdl.renderBlockFormattingContext(
        blk_ctx,
        &gpa.allocator,
        renderer,
        pixel_format,
    );
}
