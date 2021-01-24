const std = @import("std");
const assert = std.debug.assert;
const expect = std.testing.expect;

const zss = @import("zss");

usingnamespace @import("SDL2");

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

    const Part = zss.BlockFormattingContext.IdPart;

    const root = &[_]Part{0};
    {
        try blk_ctx.new(root);
        try blk_ctx.set(root, .width, .{ .width = 800 });
        try blk_ctx.set(root, .height, .{ .height = 600 });
        try blk_ctx.set(root, .background_color, .{ .rgba = 0xff223300 });
        try blk_ctx.set(root, .border_padding_left_right, .{ .padding_left = 100 });
        try blk_ctx.set(root, .border_padding_top_bottom, .{ .padding_top = 200 });
    }

    const root_0 = root ++ [_]Part{0};
    {
        try blk_ctx.new(root_0);
        try blk_ctx.set(root_0, .width, .{ .width = 100 });
        try blk_ctx.set(root_0, .height, .{ .height = 100 });
        try blk_ctx.set(root_0, .background_color, .{ .rgba = 0x00df1213 });
        try blk_ctx.set(root_0, .margin_left_right, .{ .margin_left = 250 });
        try blk_ctx.set(root_0, .margin_top_bottom, .{ .margin_top = 50 });
    }

    const root_0_0 = root_0 ++ [_]Part{0};
    {
        try blk_ctx.new(root_0_0);
        try blk_ctx.set(root_0_0, .width, .{ .width = 40 });
        try blk_ctx.set(root_0_0, .height, .{ .height = 40 });
        try blk_ctx.set(root_0_0, .background_color, .{ .rgba = 0x5c76d3ff });
    }

    const root_1 = root ++ [_]Part{1};
    {
        try blk_ctx.new(root_1);
        try blk_ctx.set(root_1, .width, .{ .width = 100 });
        try blk_ctx.set(root_1, .height, .{ .height = 100 });
        try blk_ctx.set(root_1, .background_color, .{ .rgba = 0x306892ff });
    }

    var render_tree = zss.RenderTree.init(&gpa.allocator);
    defer render_tree.deinit();
    const ctxId = try render_tree.newContext(.{ .block = &blk_ctx });
    render_tree.root_context_id = ctxId;

    var sdl_render = try zss.sdl.RenderState.init(&gpa.allocator, &render_tree);
    defer sdl_render.deinit();

    try zss.sdl.render(&sdl_render, renderer, pixel_format);
}
