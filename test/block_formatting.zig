const std = @import("std");
const assert = std.debug.assert;
const expect = std.testing.expect;

const zss = @import("zss");

const sdl = @import("SDL2");
const hb = @import("harfbuzz");

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
    assert(sdl.SDL_SetRenderDrawBlendMode(renderer, sdl.SDL_BlendMode.SDL_BLENDMODE_BLEND) == 0);

    _ = sdl.IMG_Init(sdl.IMG_INIT_PNG | sdl.IMG_INIT_JPG);
    defer sdl.IMG_Quit();
    const zig_png = sdl.IMG_LoadTexture(renderer, "test/resources/zig.png") orelse unreachable;
    defer sdl.SDL_DestroyTexture(zig_png);

    try drawBlockContext(renderer, texture_pixel_format, zig_png);
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

fn drawBlockContext(renderer: *sdl.SDL_Renderer, pixel_format: *sdl.SDL_PixelFormat, zig_png: *sdl.SDL_Texture) !void {
    const dpi = blk: {
        var horizontal: f32 = 0;
        var vertical: f32 = 0;
        if (sdl.SDL_GetDisplayDPI(0, null, &horizontal, &vertical) != 0) {
            horizontal = 96;
            vertical = 96;
        }
        break :blk .{ .horizontal = @floatToInt(hb.FT_UInt, horizontal), .vertical = @floatToInt(hb.FT_UInt, vertical) };
    };

    var library: hb.FT_Library = undefined;
    assert(hb.FT_Init_FreeType(&library) == hb.FT_Err_Ok);
    defer assert(hb.FT_Done_FreeType(library) == hb.FT_Err_Ok);

    var face: hb.FT_Face = undefined;
    assert(hb.FT_New_Face(library, "test/fonts/NotoSans-Regular.ttf", 0, &face) == hb.FT_Err_Ok);
    defer assert(hb.FT_Done_Face(face) == hb.FT_Err_Ok);

    const heightPt = 20;
    assert(hb.FT_Set_Char_Size(face, 0, heightPt * 64, dpi.horizontal, dpi.vertical) == hb.FT_Err_Ok);

    const hbfont = hb.hb_ft_font_create_referenced(face) orelse unreachable;
    defer hb.hb_font_destroy(hbfont);
    hb.hb_ft_font_set_funcs(hbfont);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer assert(!gpa.deinit());

    var ctx = try exampleBlockData(&gpa.allocator, zig_png, hbfont);
    defer ctx.deinit(&gpa.allocator);

    const offset = zss.used_values.Offset{
        .x = 0,
        .y = 0,
    };
    const clip_rect = zss.types.CSSRect{
        .x = 0,
        .y = 0,
        .w = viewport_rect.w,
        .h = viewport_rect.h,
    };

    zss.sdl_freetype.drawBlockDataRoot(&ctx, offset, clip_rect, renderer, pixel_format);
    try zss.sdl_freetype.drawBlockDataChildren(&ctx, &gpa.allocator, offset, clip_rect, renderer, pixel_format);

    var atlas = try zss.sdl_freetype.makeGlyphAtlas(face, renderer, pixel_format, &gpa.allocator);
    defer atlas.deinit(&gpa.allocator);
    for (ctx.inline_data) |inline_data| {
        var o = offset;
        var it = zss.util.PdfsFlatTreeIterator.init(ctx.pdfs_flat_tree, inline_data.id_of_containing_block);
        while (it.next()) |id| {
            o = o.add(ctx.box_offsets[id].content_top_left);
        }
        try zss.sdl_freetype.drawInlineData(inline_data.data, o, renderer, pixel_format, &atlas);
    }
}

fn exampleBlockData(allocator: *std.mem.Allocator, zig_png: *sdl.SDL_Texture, hbfont: *hb.hb_font_t) !zss.used_values.BlockRenderingData {
    const len = 3;
    var pdfs_flat_tree = [len]u16{ 3, 2, 1 };
    var inline_size = [len]zss.box_tree.LogicalSize{
        .{
            .size = .{ .px = 500 },
            .padding_start = .{ .px = 100 },
            .padding_end = .{ .px = 100 },
            .border_end_width = .{ .px = 100 },
        },
        .{
            .size = .{ .px = 200 },
        },
        .{},
    };
    var block_size = [len]zss.box_tree.LogicalSize{
        .{
            .size = .{ .px = 550 },
            .padding_start = .{ .px = 50 },
        },
        .{},
        .{},
    };
    var display = [len]zss.box_tree.Display{
        .{ .block_flow_root = {} },
        .{ .block_flow = {} },
        .{ .text = {} },
    };
    //var position_inset = [_]zss.box_tree.PositionInset{.{}} ** len;
    var latin1_text = [_]zss.box_tree.Latin1Text{.{ .text = "" }} ** len;
    var border = [len]zss.box_tree.Border{
        .{ .inline_end_color = .{ .rgba = 0xffffff40 } },
        .{},
        .{},
    };
    var background = [len]zss.box_tree.Background{
        .{
            .color = .{ .rgba = 0xff2233ff },
            .image = .{ .data = zss.sdl_freetype.textureAsBackgroundImage(zig_png) },
            .position = .{ .position = .{
                .horizontal = .{ .side = .right, .offset = .{ .percentage = 0 } },
                .vertical = .{ .side = .top, .offset = .{ .percentage = 0.5 } },
            } },
            .repeat = .{ .repeat = .{ .horizontal = .space, .vertical = .repeat } },
            .origin = .{ .padding_box = {} },
            .clip = .{ .padding_box = {} },
            .size = .{ .size = .{
                .width = .{ .percentage = 0.3 },
                .height = .{ .percentage = 1 },
            } },
        },
        .{ .color = .{ .rgba = 0x5c76d3ff } },
        .{},
    };
    latin1_text[2] = .{ .text = "wow! look at this cool document I made using zss!" };
    var font = zss.box_tree.Font{ .font = hbfont };
    const box_tree = zss.box_tree.BoxTree{
        .pdfs_flat_tree = &pdfs_flat_tree,
        .inline_size = &inline_size,
        .block_size = &block_size,
        .display = &display,
        //.position_inset = &position_inset,
        .latin1_text = &latin1_text,
        .font = font,
        .border = &border,
        .background = &background,
    };

    var context = try zss.layout.BlockLayoutContext.init(&box_tree, allocator, 0, viewport_rect.w, viewport_rect.h);
    defer context.deinit();
    var data = try zss.layout.createBlockRenderingData(&context, allocator);

    return data;
}
