const std = @import("std");
const assert = std.debug.assert;
const expect = std.testing.expect;

const zss = @import("zss");

const sdl = @import("SDL2");
usingnamespace @import("sdl/render_sdl.zig");

const viewport_rect = zss.types.CSSSize{ .w = 800, .h = 600 };

pub fn main() !void {
    assert(sdl.SDL_Init(sdl.SDL_INIT_VIDEO) == 0);
    defer sdl.SDL_Quit();

    const width = viewport_rect.w;
    const height = viewport_rect.h;
    const window = sdl.SDL_CreateWindow(
        "An SDL Window.",
        sdl.SDL_WINDOWPOS_CENTERED_MASK,
        sdl.SDL_WINDOWPOS_CENTERED_MASK,
        width,
        height,
        sdl.SDL_WINDOW_SHOWN | sdl.SDL_WINDOW_RESIZABLE,
    ) orelse unreachable;
    defer sdl.SDL_DestroyWindow(window);

    const renderer = sdl.SDL_CreateRenderer(
        window,
        -1,
        sdl.SDL_RENDERER_ACCELERATED | sdl.SDL_RENDERER_PRESENTVSYNC,
    ) orelse unreachable;
    defer sdl.SDL_DestroyRenderer(renderer);

    const window_texture = sdl.SDL_GetRenderTarget(renderer);

    const texture_pixel_format = sdl.SDL_AllocFormat(sdl.SDL_PIXELFORMAT_RGBA32) orelse unreachable;
    defer sdl.SDL_FreeFormat(texture_pixel_format);
    const texture = sdl.SDL_CreateTexture(
        renderer,
        texture_pixel_format.*.format,
        sdl.SDL_TEXTUREACCESS_TARGET,
        width,
        height,
    ) orelse unreachable;
    defer sdl.SDL_DestroyTexture(texture);
    assert(sdl.SDL_SetRenderTarget(renderer, texture) == 0);

    _ = sdl.IMG_Init(sdl.IMG_INIT_PNG | sdl.IMG_INIT_JPG);
    defer sdl.IMG_Quit();
    const zig_png = sdl.IMG_LoadTexture(renderer, "test/resources/zig.png") orelse unreachable;
    defer sdl.SDL_DestroyTexture(zig_png);
    const sunglasses_jpg = sdl.IMG_LoadTexture(renderer, "test/resources/sunglasses.jpg") orelse unreachable;
    defer sdl.SDL_DestroyTexture(sunglasses_jpg);

    try drawBlockContext(renderer, texture_pixel_format, zig_png, sunglasses_jpg);
    sdl.SDL_RenderPresent(renderer);

    assert(sdl.SDL_SetRenderTarget(renderer, window_texture) == 0);
    var running: bool = true;
    var event: sdl.SDL_Event = undefined;
    while (running) {
        while (sdl.SDL_PollEvent(&event) != 0) {
            if (event.@"type" == sdl.SDL_WINDOWEVENT) {
                if (event.window.event == sdl.SDL_WINDOWEVENT_CLOSE)
                    running = false;
            } else if (event.@"type" == sdl.SDL_QUIT) {
                running = false;
            }
        }

        assert(sdl.SDL_RenderClear(renderer) == 0);
        assert(sdl.SDL_RenderCopy(renderer, texture, null, &sdl.SDL_Rect{
            .x = 0,
            .y = 0,
            .w = width,
            .h = height,
        }) == 0);
        sdl.SDL_RenderPresent(renderer);
    }
}

fn drawBlockContext(renderer: *sdl.SDL_Renderer, pixel_format: *sdl.SDL_PixelFormat, zig_png: *sdl.SDL_Texture, sunglasses_jpg: *sdl.SDL_Texture) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer expect(!gpa.deinit());

    var ctx1 = try exampleBlockContext1(&gpa.allocator, zig_png);
    defer ctx1.deinit(&gpa.allocator);

    var ctx2 = try exampleBlockContext2(&gpa.allocator);
    defer ctx2.deinit(&gpa.allocator);

    var ctx3 = try exampleBlockContext3(&gpa.allocator, sunglasses_jpg);
    defer ctx3.deinit(&gpa.allocator);

    var ctx4 = try exampleBlockContext4(&gpa.allocator);
    defer ctx4.deinit(&gpa.allocator);

    var ctx5 = try exampleBlockContext5(&gpa.allocator);
    defer ctx5.deinit(&gpa.allocator);

    var stacking_context_root = zss.stacking_context.StackingContextTree{};
    defer stacking_context_root.deinitRecursive(&gpa.allocator);

    _ = try stacking_context_root.insert(
        &gpa.allocator,
        &[_]u16{0},
        zss.stacking_context.StackingContext{
            .midpoint = 2,
            .offset = .{ .x = 0, .y = 0 },
            .clip_rect = .{ .x = 0, .y = 0, .w = 1000000, .h = 1000000 },
            .inner_context = .{ .block = &ctx1 },
        },
        undefined,
    );

    _ = try stacking_context_root.insert(
        &gpa.allocator,
        &[_]u16{ 0, 0 },
        zss.stacking_context.StackingContext{
            .midpoint = 0,
            .offset = .{ .x = 100, .y = 110 },
            .clip_rect = .{ .x = 0, .y = 0, .w = 1000000, .h = 1000000 },
            .inner_context = .{ .block = &ctx2 },
        },
        undefined,
    );

    _ = try stacking_context_root.insert(
        &gpa.allocator,
        &[_]u16{ 0, 1 },
        zss.stacking_context.StackingContext{
            .midpoint = 0,
            .offset = .{ .x = 450, .y = 110 },
            .clip_rect = .{ .x = 0, .y = 0, .w = 1000000, .h = 1000000 },
            .inner_context = .{ .block = &ctx3 },
        },
        undefined,
    );

    _ = try stacking_context_root.insert(
        &gpa.allocator,
        &[_]u16{ 0, 2 },
        zss.stacking_context.StackingContext{
            .midpoint = 1,
            .offset = .{ .x = 400, .y = 400 },
            .clip_rect = .{ .x = 0, .y = 0, .w = 1000000, .h = 1000000 },
            .inner_context = .{ .block = &ctx4 },
        },
        undefined,
    );

    _ = try stacking_context_root.insert(
        &gpa.allocator,
        &[_]u16{ 0, 2, 0 },
        zss.stacking_context.StackingContext{
            .midpoint = 0,
            .offset = .{ .x = 200, .y = 350 },
            .clip_rect = .{ .x = 0, .y = 0, .w = 1000000, .h = 1000000 },
            .inner_context = .{ .block = &ctx5 },
        },
        undefined,
    );

    try renderStackingContexts(&stacking_context_root, &gpa.allocator, renderer, pixel_format);
}

fn exampleBlockContext1(allocator: *std.mem.Allocator, zig_png: *sdl.SDL_Texture) !zss.BlockRenderingContext {
    const len = 3;
    var preorder_array = [len]u16{ 3, 2, 1 };
    var inline_size = [len]zss.properties.LogicalSize{
        .{
            .size = .{ .px = 700 },
            .padding_start = .{ .px = 100 },
        },
        .{
            .size = .{ .px = 100 },
            .margin_start = .{ .px = 250 },
        },
        .{
            .size = .{ .px = 40 },
        },
    };
    var block_size = [len]zss.properties.LogicalSize{
        .{
            .size = .{ .px = 550 },
            .padding_start = .{ .px = 50 },
        },
        .{
            .size = .{ .px = 100 },
            .margin_start = .{ .px = 50 },
        },
        .{
            .size = .{ .px = 40 },
        },
    };
    var display = [len]zss.properties.Display{
        .{ .block_flow_root = {} },
        .{ .block_flow = {} },
        .{ .block_flow = {} },
    };
    var position_inset = [_]zss.properties.PositionInset{.{}} ** len;
    var latin1_text = [_]zss.properties.Latin1Text{.{ .text = "" }} ** len;
    var font = [_]zss.properties.Font{.{ .font = null }} ** len;
    const box_tree = zss.box_tree.BoxTree{
        .preorder_array = &preorder_array,
        .inline_size = &inline_size,
        .block_size = &block_size,
        .display = &display,
        .position_inset = &position_inset,
        .latin1_text = &latin1_text,
        .font = &font,
    };

    var context = try zss.solve.BlockContext.init(&box_tree, allocator, 0, viewport_rect.w, viewport_rect.h);
    defer context.deinit();
    var data = try zss.solve.createBlockUsedData(&context, allocator);

    data.background_color[0] = .{ .rgba = 0xff223300 };
    data.background_image[0] = .{
        .image = textureAsBackgroundImage(zig_png),
        .position = .{ .vertical = 0.5, .horizontal = 0.5 },
        .size = .{ .width = 0.75, .height = 0.5 },
        .repeat = .{ .x = .Space, .y = .Repeat },
    };

    data.background_color[1] = .{ .rgba = 0x00df1213 };
    data.visual_effect[1] = .{ .visibility = .Hidden };

    data.background_color[2] = .{ .rgba = 0x5c76d3ff };
    data.visual_effect[2] = .{ .visibility = .Hidden };

    return data;
}

fn exampleBlockContext2(allocator: *std.mem.Allocator) !zss.BlockRenderingContext {
    const len = 4;
    var preorder_array = [len]u16{ 4, 1, 1, 1 };
    var inline_size = [len]zss.properties.LogicalSize{
        .{
            .size = .{ .px = 100 },
            .border_start_width = .{ .px = 20 },
            .border_end_width = .{ .px = 10 },
        },
        .{ .size = .{ .px = 50 } },
        .{ .size = .{ .px = 100 } },
        .{ .size = .{ .px = 150 } },
    };
    var block_size = [len]zss.properties.LogicalSize{
        .{
            //.size = .{ .px = 100 },
            .border_start_width = .{ .px = 5 },
            .border_end_width = .{ .px = 15 },
        },
        .{ .size = .{ .px = 50 } },
        .{ .size = .{ .px = 50 } },
        .{ .size = .{ .px = 50 } },
    };
    var display = [len]zss.properties.Display{
        .{ .block_flow_root = {} },
        .{ .block_flow = {} },
        .{ .block_flow = {} },
        .{ .block_flow = {} },
    };
    var position_inset = [len]zss.properties.PositionInset{
        .{ .position = .{ .relative = {} }, .inline_start = .{ .px = 150 } },
        .{ .position = .{ .relative = {} }, .block_start = .{ .px = -20 }, .block_end = .{ .px = -2000 }, .inline_end = .{ .px = 10 } },
        .{ .position = .{ .relative = {} }, .block_end = .{ .px = -25 }, .inline_start = .{ .px = 80 } },
        .{ .position = .{ .relative = {} } },
    };
    var latin1_text = [_]zss.properties.Latin1Text{.{ .text = "" }} ** len;
    var font = [_]zss.properties.Font{.{ .font = null }} ** len;
    const box_tree = zss.box_tree.BoxTree{
        .preorder_array = &preorder_array,
        .inline_size = &inline_size,
        .block_size = &block_size,
        .display = &display,
        .position_inset = &position_inset,
        .latin1_text = &latin1_text,
        .font = &font,
    };

    var context = try zss.solve.BlockContext.init(&box_tree, allocator, 0, viewport_rect.w, viewport_rect.h);
    defer context.deinit();
    var data = try zss.solve.createBlockUsedData(&context, allocator);

    data.background_color[0] = .{ .rgba = 0x306892ff };
    data.background_color[1] = .{ .rgba = 0x505050ff };
    data.background_color[2] = .{ .rgba = 0x808080ff };
    data.background_color[3] = .{ .rgba = 0xb0b0b0ff };

    return data;
}

fn exampleBlockContext3(allocator: *std.mem.Allocator, sunglasses_jpg: *sdl.SDL_Texture) !zss.BlockRenderingContext {
    const len = 2;
    var preorder_array = [len]u16{ 2, 1 };
    var inline_size = [len]zss.properties.LogicalSize{
        .{
            .size = .{ .px = 300 },
            .border_start_width = .{ .px = 10 },
            .border_end_width = .{ .px = 10 },
        },
        .{
            .size = .{ .px = 100 },
            .border_start_width = .{ .px = 10 },
            .border_end_width = .{ .px = 10 },
            .margin_start = .{ .px = -25 },
        },
    };
    var block_size = [len]zss.properties.LogicalSize{
        .{
            .size = .{ .px = 150 },
            .border_start_width = .{ .px = 10 },
            .border_end_width = .{ .px = 10 },
        },
        .{
            .size = .{ .px = 100 },
            .border_start_width = .{ .px = 10 },
            .border_end_width = .{ .px = 10 },
            .margin_start = .{ .px = -30 },
        },
    };
    var display = [len]zss.properties.Display{
        .{ .block_flow_root = {} },
        .{ .block_flow = {} },
    };
    var position_inset = [_]zss.properties.PositionInset{.{}} ** len;
    var latin1_text = [_]zss.properties.Latin1Text{.{ .text = "" }} ** len;
    var font = [_]zss.properties.Font{.{ .font = null }} ** len;
    const box_tree = zss.box_tree.BoxTree{
        .preorder_array = &preorder_array,
        .inline_size = &inline_size,
        .block_size = &block_size,
        .display = &display,
        .position_inset = &position_inset,
        .latin1_text = &latin1_text,
        .font = &font,
    };

    var context = try zss.solve.BlockContext.init(&box_tree, allocator, 0, viewport_rect.w, viewport_rect.h);
    defer context.deinit();
    var data = try zss.solve.createBlockUsedData(&context, allocator);

    data.background_color[0] = .{ .rgba = 0x592b1cff };
    data.visual_effect[0] = .{ .overflow = .Hidden };
    data.background_image[0] = .{ .image = textureAsBackgroundImage(sunglasses_jpg), .position = .{ .horizontal = 0.4, .vertical = 0.9 }, .clip = .Content };

    data.border_colors[1] = .{ .top_rgba = 0x789b58ff, .right_rgba = 0x789b58ff, .bottom_rgba = 0x789b58ff, .left_rgba = 0x789b58ff };
    data.background_color[1] = .{ .rgba = 0x9500abff };

    return data;
}

fn exampleBlockContext4(allocator: *std.mem.Allocator) !zss.BlockRenderingContext {
    const len = 1;
    var preorder_array = [len]u16{1};
    var inline_size = [len]zss.properties.LogicalSize{
        .{
            .size = .{ .px = 150 },
            .border_start_width = .{ .px = 30 },
            .border_end_width = .{ .px = 30 },
        },
    };
    var block_size = [len]zss.properties.LogicalSize{
        .{
            .size = .{ .px = 100 },
            .border_start_width = .{ .px = 30 },
            .border_end_width = .{ .px = 30 },
        },
    };
    var display = [len]zss.properties.Display{
        .{ .block_flow_root = {} },
    };
    var position_inset = [_]zss.properties.PositionInset{.{}} ** len;
    var latin1_text = [_]zss.properties.Latin1Text{.{ .text = "" }} ** len;
    var font = [_]zss.properties.Font{.{ .font = null }} ** len;
    const box_tree = zss.box_tree.BoxTree{
        .preorder_array = &preorder_array,
        .inline_size = &inline_size,
        .block_size = &block_size,
        .display = &display,
        .position_inset = &position_inset,
        .latin1_text = &latin1_text,
        .font = &font,
    };

    var context = try zss.solve.BlockContext.init(&box_tree, allocator, 0, viewport_rect.w, viewport_rect.h);
    defer context.deinit();
    var data = try zss.solve.createBlockUsedData(&context, allocator);

    data.border_colors[0] = .{ .top_rgba = 0x20f4f4ff, .right_rgba = 0x3faf34ff, .bottom_rgba = 0xa32a7cff, .left_rgba = 0x102458ff };
    data.background_color[0] = .{ .rgba = 0x9104baff };

    return data;
}

fn exampleBlockContext5(allocator: *std.mem.Allocator) !zss.BlockRenderingContext {
    const len = 1;
    var preorder_array = [len]u16{1};
    var inline_size = [len]zss.properties.LogicalSize{
        .{
            .size = .{ .px = 75 },
        },
    };
    var block_size = [len]zss.properties.LogicalSize{
        .{
            .size = .{ .px = 200 },
            .min_size = .{ .px = 300 },
        },
    };
    var display = [len]zss.properties.Display{
        .{ .block_flow_root = {} },
    };
    var position_inset = [_]zss.properties.PositionInset{.{}} ** len;
    var latin1_text = [_]zss.properties.Latin1Text{.{ .text = "" }} ** len;
    var font = [_]zss.properties.Font{.{ .font = null }} ** len;
    const box_tree = zss.box_tree.BoxTree{
        .preorder_array = &preorder_array,
        .inline_size = &inline_size,
        .block_size = &block_size,
        .display = &display,
        .position_inset = &position_inset,
        .latin1_text = &latin1_text,
        .font = &font,
    };

    var context = try zss.solve.BlockContext.init(&box_tree, allocator, 0, viewport_rect.w, viewport_rect.h);
    defer context.deinit();
    var data = try zss.solve.createBlockUsedData(&context, allocator);

    data.background_color[0] = .{ .rgba = 0xb186afff };
    data.border_colors[0] = .{ .top_rgba = 0xdd56faff, .right_rgba = 0x93542cff, .bottom_rgba = 0x2bda86ff, .left_rgba = 0xbca973ff };

    return data;
}
