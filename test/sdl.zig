const zss = @import("zss");
const BoxTree = zss.used_values.BoxTree;
const r = zss.render.sdl;

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const hb = @import("harfbuzz");
const sdl = @import("SDL2");

pub fn run(tests: []const zss.testing.Test) !void {
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

    const results_path = "test/output/sdl";
    try std.fs.cwd().makePath(results_path);

    const stdout = std.io.getStdOut().writer();
    const stderr = std.io.getStdErr().writer();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer assert(!gpa.deinit());
    const allocator = gpa.allocator();

    for (tests) |t, i| {
        try stdout.print("sdl: ({}/{}) \"{s}\" ... ", .{ i + 1, tests.len, t.name });
        defer stdout.writeAll("\n") catch {};

        var box_tree = try zss.layout.doLayout(t.element_tree, t.cascaded_values, allocator, .{ .width = t.width, .height = t.height });
        defer box_tree.deinit();

        var root_sizes: struct { width: i32, height: i32 } = undefined;
        if (t.element_tree.size() > 0) switch (box_tree.element_index_to_generated_box[0]) {
            .block_box => |block_box| {
                const subtree = &box_tree.blocks.subtrees.items[block_box.subtree];
                const box_offsets = subtree.box_offsets.items[block_box.index];
                root_sizes = .{
                    .width = r.zssUnitToPixel(box_offsets.border_size.w),
                    .height = r.zssUnitToPixel(box_offsets.border_size.h),
                };
            },
            .none => root_sizes = .{ .width = 0, .height = 0 },
            .text, .inline_box => unreachable,
        } else {
            root_sizes = .{ .width = 0, .height = 0 };
        }

        var maybe_atlas = maybe_atlas: {
            const font = if (t.hb_font != null and t.hb_font.? != hb.hb_font_get_empty()) t.hb_font.? else break :maybe_atlas null;
            const face = hb.hb_ft_font_get_face(font);
            break :maybe_atlas try r.GlyphAtlas.init(face, renderer.?, pixel_format, allocator);
        };
        defer if (maybe_atlas) |*atlas| atlas.deinit(allocator);
        const atlas_ptr = if (maybe_atlas) |*atlas| atlas else null;

        const surface = try drawToSurface(
            allocator,
            box_tree,
            root_sizes.width,
            root_sizes.height,
            sdl.SDL_Point{ .x = 0, .y = 0 },
            renderer.?,
            pixel_format,
            atlas_ptr,
        );
        defer sdl.SDL_FreeSurface(surface);
        const filename = try std.fmt.allocPrintZ(allocator, results_path ++ "/{s}.bmp", .{t.name});
        defer allocator.free(filename);
        if (sdl.SDL_SaveBMP(surface, filename) != 0) {
            stderr.print("sdl: couldn't save test \"{s}\", skipping", .{t.name}) catch {};
            continue;
        }

        try stdout.writeAll("success");
    }
}

fn drawToSurface(
    allocator: Allocator,
    box_tree: BoxTree,
    width: c_int,
    height: c_int,
    translation: sdl.SDL_Point,
    renderer: *sdl.SDL_Renderer,
    pixel_format: *sdl.SDL_PixelFormat,
    glyph_atlas: ?*r.GlyphAtlas,
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
            try r.drawBoxTree(box_tree, renderer, pixel_format, glyph_atlas, allocator, vp, tr);
            sdl.SDL_RenderPresent(renderer);
            assert(sdl.SDL_RenderReadPixels(renderer, &vp, buffer.*.format.*.format, buffer.*.pixels, buffer.*.pitch) == 0);
            assert(sdl.SDL_BlitSurface(buffer, null, surface, &.{ .x = i * tw, .y = j * th, .w = tw, .h = th }) == 0);
        }
    }

    return surface;
}
