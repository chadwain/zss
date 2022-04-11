const zss = @import("zss");
const Boxes = zss.used_values.Boxes;
const r = zss.render.sdl;

const std = @import("std");
const allocator = std.testing.allocator;
const assert = std.debug.assert;

const hb = @import("harfbuzz");
const sdl = @import("SDL2");

const cases = @import("./test_cases.zig");

pub fn drawToSurface(
    boxes: Boxes,
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

    const buffer = sdl.SDL_CreateRGBSurface(0, tw, th, 32, 0, 0, 0, 0);
    defer sdl.SDL_FreeSurface(buffer);

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
            try r.renderBoxes(boxes, renderer, pixel_format, glyph_atlas, allocator, vp, tr);
            sdl.SDL_RenderPresent(renderer);
            assert(sdl.SDL_RenderReadPixels(renderer, &vp, buffer.*.format.*.format, buffer.*.pixels, buffer.*.pitch) == 0);
            assert(sdl.SDL_BlitSurface(buffer, null, surface, &.{ .x = i * tw, .y = j * th, .w = tw, .h = th }) == 0);
        }
    }

    return surface;
}

test "sdl" {
    var window: ?*sdl.SDL_Window = undefined;
    var renderer: ?*sdl.SDL_Renderer = undefined;
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
    assert(sdl.SDL_SetRenderDrawBlendMode(renderer, sdl.SDL_BLENDMODE_BLEND) == 0);

    var library: hb.FT_Library = undefined;
    assert(hb.FT_Init_FreeType(&library) == 0);
    defer _ = hb.FT_Done_FreeType(library);

    const all_test_data = try cases.getTestData();
    defer {
        for (all_test_data.items) |*data| data.deinit();
        all_test_data.deinit();
    }

    const results_path = "test/sdl_results";
    try std.fs.cwd().makePath(results_path);

    std.debug.print("\n", .{});
    for (all_test_data.items) |data, i| {
        std.debug.print("sdl render {}... ", .{i});
        defer std.debug.print("\n", .{});

        const case = data.toTestCase(library);
        defer case.deinit();
        var atlas = try r.GlyphAtlas.init(case.face, renderer.?, pixel_format, allocator);
        defer atlas.deinit(allocator);
        var boxes = try zss.layout.doLayout(case.element_tree, case.cascaded_values, allocator, .{ .w = case.width, .h = case.height });
        defer boxes.deinit();

        const root_sizes: struct { width: i32, height: i32 } = if (boxes.blocks.skips.items.len > 1) blk: {
            // TODO: Find the used_id of root a better way
            const root_box_offsets = boxes.blocks.box_offsets.items[1];
            break :blk .{
                .width = r.zssUnitToPixel(root_box_offsets.border_end.x - root_box_offsets.border_start.x),
                .height = r.zssUnitToPixel(root_box_offsets.border_end.y - root_box_offsets.border_start.y),
            };
        } else .{ .width = 0, .height = 0 };
        const surface = try drawToSurface(boxes, root_sizes.width, root_sizes.height, sdl.SDL_Point{ .x = 0, .y = 0 }, renderer.?, pixel_format, &atlas);
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
