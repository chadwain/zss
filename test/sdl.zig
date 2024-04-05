const zss = @import("zss");
const BoxTree = zss.used_values.BoxTree;
const DrawOrderList = zss.render.DrawOrderList;
const r = zss.render.sdl;

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const Test = @import("./testing.zig").Test;

const hb = @import("mach-harfbuzz").c;
const sdl = @import("SDL2");

pub fn run(tests: []const Test) !void {
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
    defer assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    for (tests, 0..) |t, i| {
        try stdout.print("sdl: ({}/{}) \"{s}\" ... ", .{ i + 1, tests.len, t.name });
        defer stdout.writeAll("\n") catch {};

        var box_tree = try zss.layout.doLayout(t.slice, t.root, allocator, .{ .width = t.width, .height = t.height });
        defer box_tree.deinit();

        var root_sizes: struct { width: i32, height: i32 } = undefined;
        if (!t.root.eqlNull()) {
            if (box_tree.element_to_generated_box.get(t.root)) |generated| {
                switch (generated) {
                    .block_box => |block_box| {
                        const subtree_slice = box_tree.blocks.subtrees.items[block_box.subtree].slice();
                        const box_offsets = subtree_slice.items(.box_offsets)[block_box.index];
                        root_sizes = .{
                            .width = r.zssUnitToPixel(box_offsets.border_size.w),
                            .height = r.zssUnitToPixel(box_offsets.border_size.h),
                        };
                    },
                    .text, .inline_box => unreachable,
                }
            } else {
                root_sizes = .{ .width = 0, .height = 0 };
            }
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

        var draw_order_list = try DrawOrderList.create(box_tree, allocator);
        defer draw_order_list.deinit(allocator);

        const surface = try drawToSurface(
            allocator,
            box_tree,
            root_sizes.width,
            root_sizes.height,
            sdl.SDL_Point{ .x = 0, .y = 0 },
            renderer.?,
            pixel_format,
            atlas_ptr,
            draw_order_list,
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
    draw_order_list: DrawOrderList,
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
            const vp = sdl.SDL_Rect{ .x = tr.x, .y = tr.y, .w = @min(width - tr.x, tw), .h = @min(height - tr.y, th) };
            assert(sdl.SDL_SetRenderDrawColor(renderer, 0, 0, 0, 0) == 0);
            assert(sdl.SDL_RenderClear(renderer) == 0);
            try r.drawBoxTree(box_tree, draw_order_list, allocator, renderer, pixel_format, glyph_atlas, vp);
            sdl.SDL_RenderPresent(renderer);
            assert(sdl.SDL_RenderReadPixels(renderer, &vp, buffer.*.format.*.format, buffer.*.pixels, buffer.*.pitch) == 0);
            var rect = sdl.SDL_Rect{ .x = i * tw, .y = j * th, .w = tw, .h = th };
            assert(sdl.SDL_BlitSurface(buffer, null, surface, &rect) == 0);
        }
    }

    return surface;
}
