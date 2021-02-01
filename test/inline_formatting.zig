const std = @import("std");
const assert = std.debug.assert;
const expect = std.testing.expect;

const zss = @import("zss");

usingnamespace @import("SDL2");
const hb = @import("harfbuzz");

test "render inline formatting context using SDL" {
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

    const dpi = blk: {
        var horizontal: f32 = 0;
        var vertical: f32 = 0;
        if (SDL_GetDisplayDPI(0, null, &horizontal, &vertical) != 0) {
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

    try exampleInlineContext(renderer, texture_pixel_format, hbfont);
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

fn exampleInlineContext(renderer: *SDL_Renderer, pixelFormat: *SDL_PixelFormat, font: *hb.hb_font_t) !void {
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

    const Part = zss.InlineFormattingContext.IdPart;

    {
        const key = &[_]Part{0};
        try inl_ctx.new(key);
        try inl_ctx.set(key, .width, .{ .width = 400 });
        try inl_ctx.set(key, .height, .{ .height = 30 });
        try inl_ctx.set(key, .background_color, .{ .rgba = 0xff223300 });
        try inl_ctx.set(key, .position, .{ .line_box_index = 0, .advance = 0, .ascender = 30 });
        try inl_ctx.set(key, .data, .{ .empty_space = {} });
    }

    {
        const key = &[_]Part{1};
        try inl_ctx.new(key);
        try inl_ctx.set(key, .width, .{ .width = 400 });
        try inl_ctx.set(key, .height, .{ .height = 20 });
        try inl_ctx.set(key, .background_color, .{ .rgba = 0x00df1213 });
        try inl_ctx.set(key, .position, .{ .line_box_index = 0, .advance = 400, .ascender = 20 });
        try inl_ctx.set(key, .data, .{ .empty_space = {} });
    }

    {
        const key = &[_]Part{2};
        try inl_ctx.new(key);
        try inl_ctx.set(key, .width, .{ .width = 40 });
        try inl_ctx.set(key, .height, .{ .height = 40 });
        try inl_ctx.set(key, .background_color, .{ .rgba = 0x5c76d3ff });
        try inl_ctx.set(key, .position, .{ .line_box_index = 1, .advance = 200, .ascender = 40 });
        try inl_ctx.set(key, .data, .{ .empty_space = {} });
    }

    {
        const key = &[_]Part{3};
        try inl_ctx.new(key);
        try inl_ctx.set(key, .width, .{ .width = 40 });
        try inl_ctx.set(key, .height, .{ .height = 40 });
        try inl_ctx.set(key, .background_color, .{ .rgba = 0x306892ff });
        try inl_ctx.set(key, .position, .{ .line_box_index = 1, .advance = 240, .ascender = 20 });
        try inl_ctx.set(key, .data, .{ .empty_space = {} });
    }

    const bitmap_glyphs = blk: {
        const string = "abcdefg";
        const buf = hb.hb_buffer_create() orelse unreachable;
        defer hb.hb_buffer_destroy(buf);
        hb.hb_buffer_add_utf8(buf, string, @intCast(c_int, string.len), 0, @intCast(c_int, string.len));
        hb.hb_buffer_set_direction(buf, hb.hb_direction_t.HB_DIRECTION_LTR);
        hb.hb_buffer_set_script(buf, hb.hb_script_t.HB_SCRIPT_LATIN);
        hb.hb_buffer_set_language(buf, hb.hb_language_from_string("en", -1));
        hb.hb_shape(font, buf, 0, 0);

        const face = hb.hb_ft_font_get_face(font) orelse unreachable;
        const glyphs = try gpa.allocator.alloc(hb.FT_BitmapGlyph, string.len);
        const glyph_positions = blk2: {
            var n: c_uint = 0;
            const p = hb.hb_buffer_get_glyph_positions(buf, &n);
            break :blk2 p[0..n];
        };
        var cursor = hb.FT_Vector{ .x = 0, .y = 0 };
        for (string) |c, i| {
            const glyph = &glyphs[i];
            assert(hb.FT_Load_Char(face, c, hb.FT_LOAD_DEFAULT | hb.FT_LOAD_NO_HINTING) == hb.FT_Err_Ok);
            assert(hb.FT_Get_Glyph(face.*.glyph, @ptrCast(*hb.FT_Glyph, glyph)) == hb.FT_Err_Ok);
            assert(hb.FT_Glyph_To_Bitmap(@ptrCast(*hb.FT_Glyph, glyph), hb.FT_Render_Mode.FT_RENDER_MODE_NORMAL, &cursor, 0) == hb.FT_Err_Ok);
            cursor.x += glyph_positions[i].x_advance;
        }
        break :blk glyphs;
    };
    defer {
        for (bitmap_glyphs) |glyph| {
            hb.FT_Done_Glyph(@ptrCast(hb.FT_Glyph, glyph));
        }
        gpa.allocator.free(bitmap_glyphs);
    }

    const measurements = blk: {
        var asc: c_long = 0;
        var hgt: c_long = 0;
        var bbox: hb.FT_BBox = undefined;
        for (bitmap_glyphs) |g| {
            hb.FT_Glyph_Get_CBox(&g.*.root, hb.FT_GLYPH_BBOX_UNSCALED, &bbox);
            asc = std.math.max(asc, bbox.yMax);
            hgt = std.math.max(hgt, bbox.yMax - bbox.yMin);
        }
        break :blk .{ .ascender = @intCast(i32, @divTrunc(asc, 64)), .height = @intCast(i32, @divTrunc(hgt, 64)) };
    };
    inl_ctx.line_boxes.items[2].baseline = measurements.ascender;

    {
        const key = &[_]Part{4};
        try inl_ctx.new(key);
        try inl_ctx.set(key, .width, .{ .width = 400 });
        try inl_ctx.set(key, .height, .{ .height = measurements.height });
        try inl_ctx.set(key, .background_color, .{ .rgba = 0xff223300 });
        try inl_ctx.set(key, .margin_border_padding_top_bottom, .{ .border_top = 10, .border_bottom = 10 });
        try inl_ctx.set(key, .border_colors, .{ .top_rgba = 0xff839175, .bottom_rgba = 0xff839175 });
        try inl_ctx.set(key, .position, .{ .line_box_index = 2, .advance = 0, .ascender = measurements.ascender });
        try inl_ctx.set(key, .data, .{ .text = bitmap_glyphs });
    }

    const stacking_context_root = try zss.stacking_context.StackingContextTree.init(&gpa.allocator);
    defer stacking_context_root.deinitRecursive(&gpa.allocator);

    var blk_ctx = try zss.BlockFormattingContext.init(&gpa.allocator);
    defer blk_ctx.deinit();
    {
        const key = &[_]Part{0};
        try blk_ctx.new(key);
    }
    var blk_offset_tree = try zss.offset_tree.fromBlockContext(&blk_ctx, &gpa.allocator);
    defer blk_offset_tree.deinitRecursive(&gpa.allocator);

    _ = try stacking_context_root.insert(
        &gpa.allocator,
        &[_]u16{0},
        zss.stacking_context.StackingContext{
            .midpoint = 0,
            .offset = zss.util.Offset{ .x = 0, .y = 0 },
            .offset_tree = blk_offset_tree,
            .root = .{ .block = &blk_ctx },
        },
        undefined,
    );

    _ = try stacking_context_root.insert(
        &gpa.allocator,
        &[_]u16{ 0, 0 },
        zss.stacking_context.StackingContext{
            .midpoint = 0,
            .offset = zss.util.Offset{ .x = 0, .y = 0 },
            .offset_tree = undefined,
            .root = .{ .@"inline" = &inl_ctx },
        },
        undefined,
    );

    try zss.sdl.renderStackingContexts(stacking_context_root, &gpa.allocator, renderer, pixelFormat);
}
