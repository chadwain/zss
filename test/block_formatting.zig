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

    try drawBlockContext(renderer, texture_pixel_format);
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

fn drawBlockContext(renderer: *SDL_Renderer, pixel_format: *SDL_PixelFormat) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer expect(!gpa.deinit());

    var ctx1 = try exampleBlockContext1(&gpa.allocator);
    defer ctx1.deinit();

    var ctx2 = try exampleBlockContext2(&gpa.allocator);
    defer ctx2.deinit();

    var ctx3 = try exampleBlockContext3(&gpa.allocator);
    defer ctx3.deinit();

    var ctx4 = try exampleBlockContext4(&gpa.allocator);
    defer ctx4.deinit();

    var ctx5 = try exampleBlockContext5(&gpa.allocator);
    defer ctx5.deinit();

    var offset_tree_1 = try zss.offset_tree.fromBlockContext(&ctx1, &gpa.allocator);
    defer offset_tree_1.deinitRecursive(&gpa.allocator);

    var offset_tree_2 = try zss.offset_tree.fromBlockContext(&ctx2, &gpa.allocator);
    defer offset_tree_2.deinitRecursive(&gpa.allocator);

    var offset_tree_3 = try zss.offset_tree.fromBlockContext(&ctx3, &gpa.allocator);
    defer offset_tree_3.deinitRecursive(&gpa.allocator);

    var offset_tree_4 = try zss.offset_tree.fromBlockContext(&ctx4, &gpa.allocator);
    defer offset_tree_4.deinitRecursive(&gpa.allocator);

    var offset_tree_5 = try zss.offset_tree.fromBlockContext(&ctx5, &gpa.allocator);
    defer offset_tree_5.deinitRecursive(&gpa.allocator);

    var stacking_context_root = zss.stacking_context.StackingContextTree{};
    defer stacking_context_root.deinitRecursive(&gpa.allocator);

    _ = try stacking_context_root.insert(
        &gpa.allocator,
        &[_]u16{0},
        zss.stacking_context.StackingContext{
            .midpoint = 2,
            .offset = zss.util.Offset{ .x = 0, .y = 0 },
            .inner_context = .{
                .block = .{
                    .context = &ctx1,
                    .offset_tree = &offset_tree_1,
                },
            },
        },
        undefined,
    );

    _ = try stacking_context_root.insert(
        &gpa.allocator,
        &[_]u16{ 0, 0 },
        zss.stacking_context.StackingContext{
            .midpoint = 0,
            .offset = zss.util.Offset{ .x = 100, .y = 110 },
            .inner_context = .{
                .block = .{
                    .context = &ctx2,
                    .offset_tree = &offset_tree_2,
                },
            },
        },
        undefined,
    );

    _ = try stacking_context_root.insert(
        &gpa.allocator,
        &[_]u16{ 0, 1 },
        zss.stacking_context.StackingContext{
            .midpoint = 0,
            .offset = zss.util.Offset{ .x = 600, .y = 110 },
            .inner_context = .{
                .block = .{
                    .context = &ctx3,
                    .offset_tree = &offset_tree_3,
                },
            },
        },
        undefined,
    );

    _ = try stacking_context_root.insert(
        &gpa.allocator,
        &[_]u16{ 0, 2 },
        zss.stacking_context.StackingContext{
            .midpoint = 1,
            .offset = zss.util.Offset{ .x = 400, .y = 450 },
            .inner_context = .{
                .block = .{
                    .context = &ctx4,
                    .offset_tree = &offset_tree_4,
                },
            },
        },
        undefined,
    );

    _ = try stacking_context_root.insert(
        &gpa.allocator,
        &[_]u16{ 0, 2, 0 },
        zss.stacking_context.StackingContext{
            .midpoint = 0,
            .offset = zss.util.Offset{ .x = 200, .y = 350 },
            .inner_context = .{
                .block = .{
                    .context = &ctx5,
                    .offset_tree = &offset_tree_5,
                },
            },
        },
        undefined,
    );

    try zss.sdl.renderStackingContexts(&stacking_context_root, &gpa.allocator, renderer, pixel_format);
}

fn exampleBlockContext1(allocator: *std.mem.Allocator) !zss.BlockFormattingContext {
    var blk_ctx = zss.BlockFormattingContext.init(allocator);
    errdefer blk_ctx.deinit();

    const Part = zss.BlockFormattingContext.IdPart;

    const root = &[_]Part{0};
    {
        try blk_ctx.new(root);
        try blk_ctx.set(root, .width, .{ .width = 700 });
        try blk_ctx.set(root, .height, .{ .height = 550 });
        try blk_ctx.set(root, .background_color, .{ .rgba = 0xff223300 });
        try blk_ctx.set(root, .padding, .{ .padding_left = 100, .padding_top = 50 });
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

    return blk_ctx;
}

fn exampleBlockContext2(allocator: *std.mem.Allocator) !zss.BlockFormattingContext {
    var blk_ctx = zss.BlockFormattingContext.init(allocator);
    errdefer blk_ctx.deinit();

    const Part = zss.BlockFormattingContext.IdPart;

    const root = &[_]Part{0};
    {
        try blk_ctx.new(root);
        try blk_ctx.set(root, .width, .{ .width = 100 });
        try blk_ctx.set(root, .height, .{ .height = 100 });
        try blk_ctx.set(root, .borders, .{ .border_top = 5, .border_right = 10, .border_bottom = 15, .border_left = 20 });
        try blk_ctx.set(root, .background_color, .{ .rgba = 0x306892ff });
    }

    return blk_ctx;
}

fn exampleBlockContext3(allocator: *std.mem.Allocator) !zss.BlockFormattingContext {
    var blk_ctx = zss.BlockFormattingContext.init(allocator);
    errdefer blk_ctx.deinit();

    const Part = zss.BlockFormattingContext.IdPart;

    const root = &[_]Part{0};
    {
        try blk_ctx.new(root);
        try blk_ctx.set(root, .width, .{ .width = 400 });
        try blk_ctx.set(root, .height, .{ .height = 25 });
        try blk_ctx.set(root, .background_color, .{ .rgba = 0x592b1cff });
    }

    const root_0 = root ++ [_]Part{0};
    {
        try blk_ctx.new(root_0);
        try blk_ctx.set(root_0, .width, .{ .width = 100 });
        try blk_ctx.set(root_0, .height, .{ .height = 100 });
        try blk_ctx.set(root_0, .background_color, .{ .rgba = 0x9500abff });
        try blk_ctx.set(root_0, .margin_left_right, .{ .margin_left = -25 });
        try blk_ctx.set(root_0, .margin_top_bottom, .{ .margin_top = 20 });
    }

    return blk_ctx;
}

fn exampleBlockContext4(allocator: *std.mem.Allocator) !zss.BlockFormattingContext {
    var blk_ctx = zss.BlockFormattingContext.init(allocator);
    errdefer blk_ctx.deinit();

    const Part = zss.BlockFormattingContext.IdPart;

    const root = &[_]Part{0};
    {
        try blk_ctx.new(root);
        try blk_ctx.set(root, .width, .{ .width = 150 });
        try blk_ctx.set(root, .height, .{ .height = 100 });
        try blk_ctx.set(root, .borders, .{ .border_top = 30, .border_right = 30, .border_bottom = 30, .border_left = 30 });
        try blk_ctx.set(root, .background_color, .{ .rgba = 0x9104baff });
    }

    return blk_ctx;
}

fn exampleBlockContext5(allocator: *std.mem.Allocator) !zss.BlockFormattingContext {
    var blk_ctx = zss.BlockFormattingContext.init(allocator);
    errdefer blk_ctx.deinit();

    const Part = zss.BlockFormattingContext.IdPart;

    const root = &[_]Part{0};
    {
        try blk_ctx.new(root);
        try blk_ctx.set(root, .width, .{ .width = 75 });
        try blk_ctx.set(root, .height, .{ .height = 200 });
        try blk_ctx.set(root, .background_color, .{ .rgba = 0xb186afff });
    }

    return blk_ctx;
}
