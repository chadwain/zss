const zss = @import("zss");
const Document = zss.used_values.Document;
const r = zss.render.sdl;

const std = @import("std");
const allocator = std.testing.allocator;
const assert = std.debug.assert;

const hb = @import("harfbuzz");
const sdl = @import("SDL2");

const cases = @import("./test_cases.zig");

pub fn drawToSurface(
    doc: *Document,
    width: c_int,
    height: c_int,
    translation: sdl.SDL_Point,
    renderer: *sdl.SDL_Renderer,
    pixel_format: *sdl.SDL_PixelFormat,
    glyph_atlas: *r.GlyphAtlas,
) !*sdl.SDL_Surface {
    const surface = sdl.SDL_CreateRGBSurface(0, width, height, 32, 0, 0, 0, 0);
    errdefer sdl.SDL_FreeSurface(surface);

    var tw: c_int = undefined;
    var th: c_int = undefined;
    assert(sdl.SDL_QueryTexture(sdl.SDL_GetRenderTarget(renderer), null, null, &tw, &th) == 0);

    const count_x = zss.util.divCeil(width, tw);
    const count_y = zss.util.divCeil(height, th);

    var i: c_int = 0;
    while (i < count_x) : (i += 1) {
        var j: c_int = 0;
        while (j < count_y) : (j += 1) {
            const tr = sdl.SDL_Point{ .x = translation.x - i * tw, .y = translation.y - j * th };
            const vp = sdl.SDL_Rect{ .x = 0, .y = 0, .w = std.math.min(width - tr.x, tw), .h = std.math.min(height - tr.y, th) };
            assert(sdl.SDL_SetRenderDrawColor(renderer, 0, 0, 0, 0) == 0);
            assert(sdl.SDL_RenderClear(renderer) == 0);
            try r.renderDocument(doc, renderer, pixel_format, glyph_atlas, allocator, vp, tr);
            const pixels = @ptrCast([*]u8, surface.*.pixels.?);
            assert(sdl.SDL_RenderReadPixels(renderer, &vp, 0, &pixels[@intCast(usize, 4 * ((i * tw) + (j * th) * width))], width * 4) == 0);
        }
    }

    return surface;
}

test "sdl" {
    var window: ?*sdl.SDL_Window = undefined;
    var renderer: ?*sdl.SDL_Renderer = undefined;
    // TODO crash from SDL_RenderReadPixels if window is too small
    const wwidth = 100;
    const wheight = 100;
    assert(sdl.SDL_Init(sdl.SDL_INIT_VIDEO) == 0);
    defer sdl.SDL_Quit();
    assert(sdl.SDL_CreateWindowAndRenderer(wwidth, wheight, sdl.SDL_WINDOW_SHOWN | sdl.SDL_WINDOW_MINIMIZED, &window, &renderer) == 0);
    defer sdl.SDL_DestroyWindow(window);
    defer sdl.SDL_DestroyRenderer(renderer);
    const pixel_format = sdl.SDL_AllocFormat(sdl.SDL_PIXELFORMAT_RGBA32) orelse unreachable;
    defer sdl.SDL_FreeFormat(pixel_format);
    const texture = sdl.SDL_CreateTexture(renderer, pixel_format.*.format, sdl.SDL_TEXTUREACCESS_TARGET, wwidth, wheight);
    defer sdl.SDL_DestroyTexture(texture);
    assert(sdl.SDL_SetRenderTarget(renderer, texture) == 0);
    assert(sdl.SDL_SetRenderDrawBlendMode(renderer, sdl.SDL_BlendMode.SDL_BLENDMODE_BLEND) == 0);

    var library: hb.FT_Library = undefined;
    assert(hb.FT_Init_FreeType(&library) == 0);
    defer _ = hb.FT_Done_FreeType(library);

    const results_path = "test/sdl_results";
    try std.fs.cwd().makePath(results_path);

    std.debug.print("\n", .{});
    for (cases.tree_data) |_, i| {
        std.debug.print("sdl test {}... ", .{i});
        defer std.debug.print("\n", .{});

        var case = cases.get(i, library);
        defer case.deinit();
        var atlas = try r.GlyphAtlas.init(case.face, renderer.?, pixel_format, allocator);
        defer atlas.deinit(allocator);
        var doc = try zss.layout.doLayout(&case.tree, allocator, case.width, case.height);
        defer doc.deinit();
        const root_sizes = doc.blocks.box_offsets.items[0];
        const root_width = r.zssUnitToPixel(root_sizes.border_end.inline_dir - root_sizes.border_start.inline_dir);
        const root_height = r.zssUnitToPixel(root_sizes.border_end.block_dir - root_sizes.border_start.block_dir);
        const surface = try drawToSurface(&doc, root_width, root_height, sdl.SDL_Point{ .x = 0, .y = 0 }, renderer.?, pixel_format, &atlas);
        defer sdl.SDL_FreeSurface(surface);
        const filename = try std.fmt.allocPrintZ(allocator, results_path ++ "/{:0>2}.bmp", .{i});
        defer allocator.free(filename);
        if (sdl.SDL_SaveBMP(surface, filename) != 0) {
            std.log.err("sdl: couldn't save test {}, skipping", .{i});
            continue;
        }

        std.debug.print("success", .{});
    }
}
