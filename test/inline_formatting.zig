// This file is a part of zss.
// Copyright (C) 2020-2021 Chadwain Holness
//
// This library is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this library.  If not, see <https://www.gnu.org/licenses/>.

const std = @import("std");
const assert = std.debug.assert;
const expect = std.testing.expect;

const zss = @import("zss");

usingnamespace @import("sdl/render_sdl.zig");
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

    //try exampleInlineContext(renderer, texture_pixel_format, hbfont);
    try exampleInlineContext2(renderer, texture_pixel_format, hbfont);
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

fn exampleInlineContext(renderer: *sdl.SDL_Renderer, pixelFormat: *sdl.SDL_PixelFormat, font: *hb.hb_font_t) !void {
    const BoxMeasures = zss.InlineRenderingContext.BoxMeasures;
    const InlineBoxFragment = zss.InlineRenderingContext.InlineBoxFragment;
    const Heights = zss.InlineRenderingContext.Heights;
    const CSSUnit = zss.types.CSSUnit;
    const BackgroundColor = zss.used_properties.BackgroundColor;
    var measures_top = [_]BoxMeasures{.{}} ** 4 ++ [_]BoxMeasures{.{ .border = 10, .border_color_rgba = 0xff839175 }};
    var measures_bottom = [_]BoxMeasures{.{}} ** 4 ++ [_]BoxMeasures{.{ .border = 10, .border_color_rgba = 0xff839175 }};
    var measures_left = [_]BoxMeasures{.{}} ** 5;
    var measures_right = [_]BoxMeasures{.{}} ** 5;
    var background_color = [_]BackgroundColor{ .{ .rgba = 0xff223300 }, .{ .rgba = 0x00df1213 }, .{ .rgba = 0x5c76d3ff }, .{ .rgba = 0x306892ff }, .{ .rgba = 0xff223300 } };
    var fragments: [5]InlineBoxFragment = undefined;

    fragments[0] = .{ .baseline_pos = .{ .x = 0, .y = 30 }, .width = 400, .inline_box_id = 0, .include_top = false, .include_right = false, .include_bottom = false, .include_left = false, .text = null };
    fragments[1] = .{ .baseline_pos = .{ .x = 400, .y = 20 }, .width = 400, .inline_box_id = 2, .include_top = false, .include_right = false, .include_bottom = false, .include_left = false, .text = null };
    fragments[2] = .{ .baseline_pos = .{ .x = 200, .y = 110 }, .width = 40, .inline_box_id = 2, .include_top = false, .include_right = false, .include_bottom = false, .include_left = false, .text = null };
    fragments[3] = .{ .baseline_pos = .{ .x = 240, .y = 90 }, .width = 40, .inline_box_id = 3, .include_top = false, .include_right = false, .include_bottom = false, .include_left = false, .text = null };

    const string = "abcdefg";
    const buf = hb.hb_buffer_create() orelse unreachable;
    defer hb.hb_buffer_destroy(buf);
    hb.hb_buffer_add_utf8(buf, string, @intCast(c_int, string.len), 0, @intCast(c_int, string.len));
    hb.hb_buffer_set_direction(buf, hb.hb_direction_t.HB_DIRECTION_LTR);
    hb.hb_buffer_set_script(buf, hb.hb_script_t.HB_SCRIPT_LATIN);
    hb.hb_buffer_set_language(buf, hb.hb_language_from_string("en", -1));
    hb.hb_shape(font, buf, 0, 0);

    const glyph_infos = blk: {
        var n: c_uint = 0;
        const p = hb.hb_buffer_get_glyph_infos(buf, &n);
        break :blk p[0..n];
    };
    const glyph_positions = blk: {
        var n: c_uint = 0;
        const p = hb.hb_buffer_get_glyph_positions(buf, &n);
        break :blk p[0..n];
    };

    const measurements = blk: {
        var asc: c_long = 0;
        var desc: c_long = 0;
        var bbox: hb.FT_BBox = undefined;
        const face = hb.hb_ft_font_get_face(font) orelse unreachable;
        for (string) |c, i| {
            var cursor = hb.FT_Vector{ .x = 0, .y = 0 };
            var glyph: hb.FT_Glyph = undefined;
            defer hb.FT_Done_Glyph(glyph);
            assert(hb.FT_Load_Char(face, c, hb.FT_LOAD_DEFAULT | hb.FT_LOAD_NO_HINTING) == hb.FT_Err_Ok);
            assert(hb.FT_Get_Glyph(face.*.glyph, &glyph) == hb.FT_Err_Ok);
            assert(hb.FT_Glyph_To_Bitmap(&glyph, hb.FT_Render_Mode.FT_RENDER_MODE_NORMAL, &cursor, 0) == hb.FT_Err_Ok);

            hb.FT_Glyph_Get_CBox(glyph, hb.FT_GLYPH_BBOX_UNSCALED, &bbox);
            asc = std.math.max(asc, bbox.yMax);
            desc = std.math.min(desc, bbox.yMin);
        }

        break :blk .{ .ascender = @intCast(i32, @divFloor(asc, 64)), .descender = -@intCast(i32, @divFloor(desc, 64)) };
    };

    fragments[4] = .{
        .baseline_pos = .{ .x = 0, .y = 100 + measurements.ascender },
        .width = 400,
        .inline_box_id = 4,
        .include_top = true,
        .include_right = false,
        .include_bottom = true,
        .include_left = false,
        .text = InlineBoxFragment.Text{ .font = font, .infos = glyph_infos, .positions = glyph_positions },
    };

    var heights = [_]Heights{
        .{ .above_baseline = 30, .below_baseline = 0 },
        .{ .above_baseline = 20, .below_baseline = 0 },
        .{ .above_baseline = 40, .below_baseline = 0 },
        .{ .above_baseline = 40, .below_baseline = 0 },
        .{ .above_baseline = measurements.ascender, .below_baseline = 0 },
    };
    const inl = zss.InlineRenderingContext{
        .fragments = &fragments,
        .measures_top = &measures_top,
        .measures_right = &measures_right,
        .measures_bottom = &measures_bottom,
        .measures_left = &measures_left,
        .heights = &heights,
        .background_color = &background_color,
    };

    @import("./sdl/inline_rendering.zig").drawInlineContext(&inl, .{ .x = 0, .y = 0 }, renderer, pixelFormat);
}

fn exampleInlineContext2(renderer: *sdl.SDL_Renderer, pixelFormat: *sdl.SDL_PixelFormat, hbfont: *hb.hb_font_t) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.testing.expect(!gpa.deinit());
    const al = &gpa.allocator;

    const properties = zss.properties;
    const len = 4;
    var preorder_array = [len]u16{ 4, 1, 1, 1 };
    var inline_size = [len]properties.LogicalSize{
        .{},
        .{ .border_start_width = .{ .px = 10 }, .border_end_width = .{ .px = 40 } },
        .{},
        .{ .border_start_width = .{ .px = 30 }, .border_end_width = .{ .px = 40 } },
    };
    var block_size = [_]properties.LogicalSize{.{}} ** len;
    var display = [len]properties.Display{ .{ .block_flow_root = {} }, .{ .inline_flow = {} }, .{ .text = {} }, .{ .inline_flow = {} } };
    var position_inset = [_]properties.PositionInset{.{}} ** len;
    var latin1_text = [_]properties.Latin1Text{.{ .text = "" }} ** len;
    latin1_text[2].text = "hello world.";
    var font = [_]properties.Font{ .{ .font = hbfont }, .{ .font = null }, .{ .font = null }, .{ .font = null } };
    var inl = try zss.solve.generateUsedDataInline(
        &zss.box_tree.BoxTree{
            .preorder_array = &preorder_array,
            .inline_size = &inline_size,
            .block_size = &block_size,
            .display = &display,
            .position_inset = &position_inset,
            .latin1_text = &latin1_text,
            .font = &font,
        },
        al,
        zss.types.CSSSize{ .w = 500, .h = 400 },
    );
    defer inl.deinit(al);

    inl.measures_left[1].border_color_rgba = 0xff0000ff;
    inl.measures_right[1].border_color_rgba = 0x4713c7ff;
    inl.measures_right[2].border_color_rgba = 0x791bda9f;

    {
        const p = std.debug.print;
        p("\n", .{});
        p("glyphs\n", .{});
        var i: usize = 0;
        while (i < inl.glyph_indeces.len) : (i += 1) {
            const gi = inl.glyph_indeces[i];
            if (gi == zss.InlineRenderingContext.special_index) {
                i += 1;
                p("{}\n", .{zss.InlineRenderingContext.decodeSpecial(inl.glyph_indeces[i])});
            } else {
                p("{x}\n", .{gi});
            }
        }
        p("\n", .{});
        p("positions\n", .{});
        i = 0;
        while (i < inl.positions.len) : (i += 1) {
            const pos = inl.positions[i];
            p("{}\n", .{pos});
            if (inl.glyph_indeces[i] == zss.InlineRenderingContext.special_index) {
                i += 1;
            }
        }
        p("\n", .{});
        p("line boxes\n", .{});
        for (inl.line_boxes) |l| {
            p("{}\n", .{l});
        }
    }

    @import("./sdl/inline_rendering.zig").drawInlineContext(&inl, .{ .x = 0, .y = 0 }, renderer, pixelFormat);
}
