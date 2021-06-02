const std = @import("std");
const fs = std.fs;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const zss = @import("zss");
const box_tree = zss.box_tree;
const pixelToCSSUnit = zss.sdl_freetype.pixelToCSSUnit;

const sdl = @import("SDL2");
const ft = @import("freetype");
const hb = @import("harfbuzz");

const page_background_color = 0xeeeeeeff;

pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer assert(!gpa.deinit());
    var allocator = &gpa.allocator;

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len != 2) {
        std.debug.print("error: Expected 2 arguments", .{});
        return 1;
    }
    const filename = args[1];
    const bytes = blk: {
        const file = try fs.cwd().openFile(filename, .{});
        defer file.close();
        break :blk try file.readToEndAlloc(allocator, std.math.maxInt(c_int));
    };
    defer allocator.free(bytes);

    assert(sdl.SDL_Init(sdl.SDL_INIT_VIDEO) == 0);
    defer sdl.SDL_Quit();

    const width = 800;
    const height = 600;
    const window = sdl.SDL_CreateWindow(
        "zss Demo.",
        sdl.SDL_WINDOWPOS_CENTERED_MASK,
        sdl.SDL_WINDOWPOS_CENTERED_MASK,
        width,
        height,
        sdl.SDL_WINDOW_SHOWN | sdl.SDL_WINDOW_RESIZABLE,
    ) orelse unreachable;
    defer sdl.SDL_DestroyWindow(window);

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

    const font_height_pt = 12;
    assert(hb.FT_Set_Char_Size(face, 0, font_height_pt * 64, dpi.horizontal, dpi.vertical) == hb.FT_Err_Ok);

    try createBoxTree(window, face, allocator, filename, bytes);
    return 0;
}

fn createBoxTree(window: *sdl.SDL_Window, face: ft.FT_Face, allocator: *Allocator, filename: []const u8, bytes: []const u8) !void {
    const font = hb.hb_ft_font_create_referenced(face) orelse unreachable;
    defer hb.hb_font_destroy(font);
    hb.hb_ft_font_set_funcs(font);

    const len = 5;
    var pdfs_flat_tree = [len]u16{ 5, 2, 1, 2, 1 };
    const root_border_width = zss.box_tree.LogicalSize.BorderValue{ .px = 10 };
    const root_padding = zss.box_tree.LogicalSize.PaddingValue{ .px = 30 };
    var inline_size = [len]box_tree.LogicalSize{
        .{ .min_size = .{ .px = 200 }, .padding_start = root_padding, .padding_end = root_padding, .border_start_width = root_border_width, .border_end_width = root_border_width },
        .{},
        .{},
        .{},
        .{},
    };
    var block_size = [len]box_tree.LogicalSize{
        .{ .padding_start = root_padding, .padding_end = root_padding, .border_start_width = root_border_width, .border_end_width = root_border_width },
        .{ .border_end_width = .{ .px = 2 }, .margin_end = .{ .px = 24 } },
        .{},
        .{},
        .{},
    };
    var display = [len]box_tree.Display{ .{ .block_flow_root = {} }, .{ .block_flow = {} }, .{ .text = {} }, .{ .block_flow = {} }, .{ .text = {} } };
    var latin1_text = [len]box_tree.Latin1Text{ .{}, .{}, .{ .text = filename }, .{}, .{ .text = bytes } };
    const root_border_color = zss.box_tree.Border.BorderColor{ .rgba = 0xaf2233ff };
    var border = [len]box_tree.Border{
        .{ .inline_start_color = root_border_color, .inline_end_color = root_border_color, .block_start_color = root_border_color, .block_end_color = root_border_color },
        .{ .block_end_color = .{ .rgba = 0x202020ff } },
        .{},
        .{},
        .{},
    };
    var background = [len]box_tree.Background{ .{ .color = .{ .rgba = page_background_color } }, .{}, .{}, .{}, .{} };
    var tree = box_tree.BoxTree{
        .pdfs_flat_tree = &pdfs_flat_tree,
        .inline_size = &inline_size,
        .block_size = &block_size,
        .display = &display,
        .latin1_text = &latin1_text,
        .border = &border,
        .background = &background,
        .font = .{ .font = font, .color = .{ .rgba = 0x101010ff } },
    };

    try sdlMainLoop(window, face, allocator, &tree);
}

fn sdlMainLoop(window: *sdl.SDL_Window, face: ft.FT_Face, allocator: *Allocator, tree: *box_tree.BoxTree) !void {
    var width: c_int = undefined;
    var height: c_int = undefined;
    sdl.SDL_GetWindowSize(window, &width, &height);

    const pixel_format = sdl.SDL_AllocFormat(sdl.SDL_PIXELFORMAT_RGBA32) orelse unreachable;
    defer sdl.SDL_FreeFormat(pixel_format);

    const renderer = sdl.SDL_CreateRenderer(
        window,
        -1,
        sdl.SDL_RENDERER_ACCELERATED | sdl.SDL_RENDERER_PRESENTVSYNC,
    ) orelse unreachable;
    defer sdl.SDL_DestroyRenderer(renderer);
    assert(sdl.SDL_SetRenderDrawBlendMode(renderer, sdl.SDL_BlendMode.SDL_BLENDMODE_BLEND) == 0);

    var data: zss.used_values.BlockRenderingData = blk: {
        var context = try zss.layout.BlockLayoutContext.init(tree, allocator, 0, pixelToCSSUnit(width), pixelToCSSUnit(height));
        defer context.deinit();
        break :blk try zss.layout.createBlockRenderingData(&context, allocator);
    };
    defer data.deinit(allocator);
    var atlas = try zss.sdl_freetype.GlyphAtlas.init(face, renderer, pixel_format, allocator);
    defer atlas.deinit(allocator);
    var needs_relayout = false;

    var max_scroll_y = std.math.min(0, -data.box_offsets[0].border_top_left.y);
    var min_scroll_y = max_scroll_y - std.math.max(0, data.box_offsets[0].border_bottom_right.y - data.box_offsets[0].border_top_left.y - height);
    var scroll_y = max_scroll_y;
    const scroll_speed = 15;

    var frame_times = [1]u64{0} ** 64;
    var frame_time_index: usize = 0;
    var sum_of_frame_times: u64 = 0;
    var timer = try std.time.Timer.start();

    var event: sdl.SDL_Event = undefined;
    mainLoop: while (true) {
        while (sdl.SDL_PollEvent(&event) != 0) {
            switch (@intToEnum(sdl.SDL_EventType, @intCast(c_int, event.@"type"))) {
                .SDL_WINDOWEVENT => {
                    switch (@intToEnum(sdl.SDL_WindowEventID, event.window.event)) {
                        .SDL_WINDOWEVENT_SIZE_CHANGED => {
                            width = event.window.data1;
                            height = event.window.data2;
                            needs_relayout = true;
                        },
                        else => {},
                    }
                },
                .SDL_KEYDOWN => {
                    switch (event.key.keysym.sym) {
                        sdl.SDLK_UP => {
                            scroll_y += scroll_speed;
                            if (scroll_y > max_scroll_y) scroll_y = max_scroll_y;
                        },
                        sdl.SDLK_DOWN => {
                            scroll_y -= scroll_speed;
                            if (scroll_y < min_scroll_y) scroll_y = min_scroll_y;
                        },
                        sdl.SDLK_HOME => {
                            scroll_y = max_scroll_y;
                        },
                        sdl.SDLK_END => {
                            scroll_y = min_scroll_y;
                        },
                        else => {},
                    }
                },
                .SDL_QUIT => {
                    break :mainLoop;
                },
                else => {},
            }
        }

        if (needs_relayout) {
            needs_relayout = false;

            var context = try zss.layout.BlockLayoutContext.init(tree, allocator, 0, pixelToCSSUnit(width), pixelToCSSUnit(height));
            defer context.deinit();
            var new_data = try zss.layout.createBlockRenderingData(&context, allocator);
            data.deinit(allocator);
            data = new_data;

            max_scroll_y = std.math.min(0, -data.box_offsets[0].border_top_left.y);
            min_scroll_y = max_scroll_y - std.math.max(0, data.box_offsets[0].border_bottom_right.y - data.box_offsets[0].border_top_left.y - height);
            scroll_y = std.math.clamp(scroll_y, min_scroll_y, max_scroll_y);
        }

        {
            zss.sdl_freetype.drawBackgroundColor(renderer, pixel_format, sdl.SDL_Rect{ .x = 0, .y = 0, .w = width, .h = height }, page_background_color);

            const css_viewport_rect = zss.used_values.CSSRect{
                .x = 0,
                .y = 0,
                .w = pixelToCSSUnit(width),
                .h = pixelToCSSUnit(height),
            };
            const offset = zss.used_values.Offset{
                .x = 0,
                .y = scroll_y,
            };
            zss.sdl_freetype.drawBlockDataRoot(&data, offset, css_viewport_rect, renderer, pixel_format);
            try zss.sdl_freetype.drawBlockDataChildren(&data, allocator, offset, css_viewport_rect, renderer, pixel_format);

            for (data.inline_data) |inline_data| {
                var o = offset;
                var it = zss.util.PdfsFlatTreeIterator.init(data.pdfs_flat_tree, inline_data.id_of_containing_block);
                while (it.next()) |id| {
                    o = o.add(data.box_offsets[id].content_top_left);
                }
                try zss.sdl_freetype.drawInlineData(inline_data.data, o, renderer, pixel_format, &atlas);
            }
        }

        sdl.SDL_RenderPresent(renderer);

        const frame_time = timer.lap();
        const frame_time_slot = &frame_times[frame_time_index % frame_times.len];
        sum_of_frame_times -= frame_time_slot.*;
        frame_time_slot.* = frame_time;
        sum_of_frame_times += frame_time;
        frame_time_index +%= 1;
        std.debug.print("\rAverage frame time: {}us", .{sum_of_frame_times / (frame_times.len * 1000)});
    }
}
