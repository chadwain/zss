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
        "An sdl.SDL Window.",
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

    const dpi = blk: {
        var horizontal: f32 = 0;
        var vertical: f32 = 0;
        if (sdl.SDL_GetDisplayDPI(0, null, &horizontal, &vertical) != 0) {
            horizontal = 96;
            vertical = 96;
        }
        break :blk .{ .horizontal = @floatToInt(hb.FT_UInt, horizontal), .vertical = @floatToInt(hb.FT_UInt, vertical) };
    };

    // Initialize FreeType
    var library: hb.FT_Library = undefined;
    assert(hb.FT_Init_FreeType(&library) == hb.FT_Err_Ok);
    defer assert(hb.FT_Done_FreeType(library) == hb.FT_Err_Ok);

    var face: hb.FT_Face = undefined;
    assert(hb.FT_New_Face(library, "test/fonts/NotoSans-Regular.ttf", 0, &face) == hb.FT_Err_Ok);
    defer assert(hb.FT_Done_Face(face) == hb.FT_Err_Ok);

    const heightPt = 40;
    assert(hb.FT_Set_Char_Size(face, 0, heightPt * 64, dpi.horizontal, dpi.vertical) == hb.FT_Err_Ok);

    const hbfont = hb.hb_ft_font_create_referenced(face) orelse unreachable;
    defer hb.hb_font_destroy(hbfont);
    hb.hb_ft_font_set_funcs(hbfont);

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

    try exampleInlineData(renderer, texture_pixel_format, hbfont);
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

fn exampleInlineData(renderer: *sdl.SDL_Renderer, pixelFormat: *sdl.SDL_PixelFormat, hbfont: *hb.hb_font_t) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.testing.expect(!gpa.deinit());
    const al = &gpa.allocator;

    const box_tree = zss.box_tree;
    const len = 4;
    var pdfs_flat_tree = [len]u16{ 4, 1, 1, 1 };
    var inline_size = [len]box_tree.LogicalSize{
        .{},
        .{ .border_start_width = .{ .px = 10 }, .border_end_width = .{ .px = 40 } },
        .{},
        .{ .border_start_width = .{ .px = 30 }, .border_end_width = .{ .px = 40 } },
    };
    var block_size = [_]box_tree.LogicalSize{.{}} ** len;
    var display = [len]box_tree.Display{ .{ .block_flow_root = {} }, .{ .inline_flow = {} }, .{ .text = {} }, .{ .inline_flow = {} } };
    //var position_inset = [_]box_tree.PositionInset{.{}} ** len;
    var latin1_text = [_]box_tree.Latin1Text{.{ .text = "" }} ** len;
    latin1_text[2].text = "hello world.";
    var font = box_tree.Font{ .font = hbfont };
    var border = [_]box_tree.Border{.{}} ** len;
    var background = [_]box_tree.Background{.{}} ** len;
    var context = zss.layout.InlineLayoutContext.init(
        &zss.box_tree.BoxTree{
            .pdfs_flat_tree = &pdfs_flat_tree,
            .inline_size = &inline_size,
            .block_size = &block_size,
            .display = &display,
            //.position_inset = &position_inset,
            .latin1_text = &latin1_text,
            .font = font,
            .border = &border,
            .background = &background,
        },
        al,
        .{ .begin = 1, .end = pdfs_flat_tree[0] },
        500,
    );
    defer context.deinit();
    var inl = try zss.layout.createInlineRenderingData(&context, al);
    defer inl.deinit(al);

    var atlas = try zss.sdl_freetype.makeGlyphAtlas(hb.hb_ft_font_get_face(hbfont), renderer, pixelFormat, al);
    defer atlas.deinit(al);

    try zss.sdl_freetype.drawInlineData(&inl, .{ .x = 0, .y = 0 }, renderer, pixelFormat, &atlas);
}
