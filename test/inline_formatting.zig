const std = @import("std");
const assert = std.debug.assert;
const expect = std.testing.expect;

const zss = @import("zss");

const sdl = @import("SDL2");
const hb = @import("harfbuzz");

const viewport_rect = zss.used_values.ZssSize{ .w = 800, .h = 600 };

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

    try exampleInlineValues(renderer, texture_pixel_format, hbfont);
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

fn exampleInlineValues(renderer: *sdl.SDL_Renderer, pixelFormat: *sdl.SDL_PixelFormat, hbfont: *hb.hb_font_t) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer assert(!gpa.deinit());
    const al = &gpa.allocator;

    const box_tree = zss.box_tree;
    const len = 2;
    var pdfs_flat_tree = [len]box_tree.BoxId{ 2, 1 };
    var inline_size = [_]box_tree.LogicalSize{.{}} ** len;
    var block_size = [_]box_tree.LogicalSize{.{}} ** len;
    var display = [len]box_tree.Display{ .{ .block_flow = {} }, .{ .text = {} } };
    var latin1_text = [len]box_tree.Latin1Text{ .{}, .{ .text = "hello world." } };
    var font = box_tree.Font{ .font = hbfont };
    var border = [_]box_tree.Border{.{}} ** len;
    var background = [_]box_tree.Background{.{}} ** len;
    var context = zss.layout.InlineLevelLayoutContext.init(
        &zss.box_tree.BoxTree{
            .pdfs_flat_tree = &pdfs_flat_tree,
            .inline_size = &inline_size,
            .block_size = &block_size,
            .display = &display,
            .latin1_text = &latin1_text,
            .font = font,
            .border = &border,
            .background = &background,
        },
        al,
        .{ .parent = 0, .begin = 1, .end = pdfs_flat_tree[0] },
        500 * zss.used_values.unitsPerPixel,
    );
    defer context.deinit();
    var inl = try zss.layout.createInlineLevelUsedValues(&context, al);
    defer inl.deinit(al);

    var atlas = try zss.sdl_freetype.GlyphAtlas.init(hb.hb_ft_font_get_face(hbfont), renderer, pixelFormat, al);
    defer atlas.deinit(al);

    try zss.sdl_freetype.drawInlineValues(&inl, .{ .x = 0, .y = 0 }, al, renderer, pixelFormat, &atlas);
}
