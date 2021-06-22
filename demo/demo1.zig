const std = @import("std");
const fs = std.fs;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const zss = @import("zss");
const box_tree = zss.box_tree;
const pixelToZssUnit = zss.sdl_freetype.pixelToZssUnit;

const sdl = @import("SDL2");
const ft = @import("freetype");
const hb = @import("harfbuzz");

pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer assert(!gpa.deinit());
    var allocator = &gpa.allocator;

    const program_args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, program_args);
    const args = parseArgs(program_args[1..]);

    const file_bytes = blk: {
        const file = try fs.cwd().openFile(args.filename, .{});
        defer file.close();
        break :blk try file.readToEndAlloc(allocator, std.math.maxInt(c_int));
    };
    defer allocator.free(file_bytes);
    const text = blk: {
        // Exclude a trailing newline.
        if (file_bytes.len == 0) break :blk file_bytes;
        switch (file_bytes[file_bytes.len - 1]) {
            '\n' => if (file_bytes.len > 1 and file_bytes[file_bytes.len - 2] == '\r')
                break :blk file_bytes[0 .. file_bytes.len - 2]
            else
                break :blk file_bytes[0 .. file_bytes.len - 1],
            '\r' => break :blk file_bytes[0 .. file_bytes.len - 1],
            else => break :blk file_bytes,
        }
    };

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
    assert(hb.FT_New_Face(library, args.font_filename, 0, &face) == hb.FT_Err_Ok);
    defer assert(hb.FT_Done_Face(face) == hb.FT_Err_Ok);

    assert(hb.FT_Set_Char_Size(face, 0, args.font_size * 64, dpi.horizontal, dpi.vertical) == hb.FT_Err_Ok);

    try createBoxTree(&args, window, face, allocator, text);
    return 0;
}

const ProgramArguments = struct {
    filename: [:0]const u8,
    font_filename: [:0]const u8,
    font_size: u32,
    text_color: u24,
    bg_color: u24,
};

fn parseArgs(args: []const [:0]const u8) ProgramArguments {
    var filename: ?[:0]const u8 = null;
    var font_filename: ?[:0]const u8 = null;
    var font_size: ?std.fmt.ParseIntError!u32 = null;
    var text_color: ?std.fmt.ParseIntError!u24 = null;
    var bg_color: ?std.fmt.ParseIntError!u24 = null;

    var i: usize = 0;
    while (i < args.len) {
        const arg = args[i];
        if (!std.mem.startsWith(u8, arg, "--")) {
            if (i == args.len - 1) {
                filename = arg;
                break;
            } else {
                std.log.err("Argument syntax error", .{});
                std.os.exit(1);
            }
        } else if (i + 1 < args.len) {
            defer i += 2;
            if (std.mem.eql(u8, arg, "--font")) {
                font_filename = args[i + 1];
            } else if (std.mem.eql(u8, arg, "--font-size")) {
                font_size = std.fmt.parseUnsigned(u32, args[i + 1], 10);
            } else if (std.mem.eql(u8, arg, "--color")) {
                const text_color_str = if (std.mem.startsWith(u8, args[i + 1], "0x")) args[i + 1][2..] else args[i + 1];
                text_color = std.fmt.parseUnsigned(u24, text_color_str, 16);
            } else if (std.mem.eql(u8, arg, "--bg-color")) {
                const bg_color_str = if (std.mem.startsWith(u8, args[i + 1], "0x")) args[i + 1][2..] else args[i + 1];
                bg_color = std.fmt.parseUnsigned(u24, bg_color_str, 16);
            } else {
                std.log.err("Unrecognized option: {s}", .{arg});
                std.os.exit(1);
            }
        }
    }

    return ProgramArguments{
        .filename = filename orelse {
            std.log.err("Input file not specified", .{});
            std.os.exit(1);
        },
        .font_filename = font_filename orelse {
            std.log.err("Font file not specified", .{});
            std.os.exit(1);
        },
        .font_size = font_size orelse @as(std.fmt.ParseIntError!u32, 12) catch |e| {
            std.log.err("Unable to parse font size: {s}", .{@errorName(e)});
            std.os.exit(1);
        },
        .text_color = text_color orelse @as(std.fmt.ParseIntError!u24, 0x101010) catch |e| {
            std.log.err("Unable to parse text color: {s}", .{@errorName(e)});
            std.os.exit(1);
        },
        .bg_color = bg_color orelse @as(std.fmt.ParseIntError!u24, 0xeeeeee) catch |e| {
            std.log.err("Unable to parse background color: {s}", .{@errorName(e)});
            std.os.exit(1);
        },
    };
}

fn createBoxTree(args: *const ProgramArguments, window: *sdl.SDL_Window, face: ft.FT_Face, allocator: *Allocator, bytes: []const u8) !void {
    const font = hb.hb_ft_font_create_referenced(face) orelse unreachable;
    defer hb.hb_font_destroy(font);
    hb.hb_ft_font_set_funcs(font);

    const len = 7;
    var pdfs_flat_tree = [len]zss.box_tree.BoxId{ 7, 3, 2, 1, 3, 2, 1 };
    const root_border_width = zss.box_tree.LogicalSize.BorderWidth{ .px = 10 };
    const root_padding = zss.box_tree.LogicalSize.Padding{ .px = 30 };
    var inline_size = [len]box_tree.LogicalSize{
        .{ .min_size = .{ .px = 200 }, .padding_start = root_padding, .padding_end = root_padding, .border_start_width = root_border_width, .border_end_width = root_border_width },
        .{},
        .{ .border_start_width = .{ .px = 10 }, .border_end_width = .{ .px = 10 }, .padding_start = .{ .px = 10 }, .padding_end = .{ .px = 10 } },
        .{},
        .{},
        .{},
        .{},
    };
    var block_size = [len]box_tree.LogicalSize{
        .{ .padding_start = root_padding, .padding_end = root_padding, .border_start_width = root_border_width, .border_end_width = root_border_width },
        .{ .border_end_width = .{ .px = 2 }, .margin_end = .{ .px = 24 } },
        .{ .border_start_width = .{ .px = 10 }, .border_end_width = .{ .px = 3 }, .padding_end = .{ .px = 5 } },
        .{},
        .{},
        .{ .border_end_width = .{ .px = 2 } },
        .{},
    };
    var display = [len]box_tree.Display{ .{ .block_flow = {} }, .{ .block_flow = {} }, .{ .inline_flow = {} }, .{ .text = {} }, .{ .block_flow = {} }, .{ .inline_flow = {} }, .{ .text = {} } };
    var latin1_text = [len]box_tree.Latin1Text{ .{}, .{}, .{}, .{ .text = args.filename }, .{}, .{}, .{ .text = bytes } };
    const root_border_color = zss.box_tree.Border.Color{ .rgba = 0xaf2233ff };
    var border = [len]box_tree.Border{
        .{ .inline_start_color = root_border_color, .inline_end_color = root_border_color, .block_start_color = root_border_color, .block_end_color = root_border_color },
        .{ .block_end_color = .{ .rgba = 0x202020ff } },
        .{ .inline_start_color = .{ .rgba = 0x40a830ff }, .inline_end_color = .{ .rgba = 0x3040a0ff }, .block_start_color = root_border_color, .block_end_color = root_border_color },
        .{},
        .{},
        .{ .block_end_color = .{ .rgba = 0xca40caff } },
        .{},
    };
    var background = [len]box_tree.Background{
        .{},
        .{},
        .{ .color = .{ .rgba = 0x3030707f }, .clip = .{ .padding_box = {} } },
        .{},
        .{},
        .{},
        .{},
    };
    var tree = box_tree.BoxTree{
        .pdfs_flat_tree = &pdfs_flat_tree,
        .inline_size = &inline_size,
        .block_size = &block_size,
        .display = &display,
        .latin1_text = &latin1_text,
        .border = &border,
        .background = &background,
        .font = .{ .font = font, .color = .{ .rgba = (@as(u32, args.text_color) << 8) | 0xff } },
    };

    try sdlMainLoop(args, window, face, allocator, &tree);
}

const ProgramState = struct {
    tree: *const box_tree.BoxTree,
    document: zss.used_values.Document,
    atlas: zss.sdl_freetype.GlyphAtlas,
    width: c_int,
    height: c_int,
    scroll_y: c_int,
    max_scroll_y: c_int,

    const Self = @This();

    fn init(tree: *const box_tree.BoxTree, window: *sdl.SDL_Window, renderer: *sdl.SDL_Renderer, pixel_format: *sdl.SDL_PixelFormat, face: hb.FT_Face, allocator: *Allocator) !Self {
        var result = @as(Self, undefined);

        result.tree = tree;
        sdl.SDL_GetWindowSize(window, &result.width, &result.height);

        result.document = try zss.layout.doLayout(tree, allocator, allocator, pixelToZssUnit(result.width), pixelToZssUnit(result.height));
        errdefer result.document.deinit(allocator);

        result.atlas = try zss.sdl_freetype.GlyphAtlas.init(face, renderer, pixel_format, allocator);
        errdefer result.atlas.deinit(allocator);

        result.updateMaxScroll();
        return result;
    }

    fn deinit(self: *Self, allocator: *Allocator) void {
        self.document.deinit(allocator);
        self.atlas.deinit(allocator);
    }

    fn updateDocument(self: *Self, allocator: *Allocator) !void {
        var new_document = try zss.layout.doLayout(self.tree, allocator, allocator, pixelToZssUnit(self.width), pixelToZssUnit(self.height));
        self.document.deinit(allocator);
        self.document = new_document;
        self.updateMaxScroll();
    }

    fn updateMaxScroll(self: *Self) void {
        self.max_scroll_y = std.math.max(0, zss.sdl_freetype.zssUnitToPixel(self.document.block_values.box_offsets[0].border_bottom_right.y) - self.height);
        self.scroll_y = std.math.clamp(self.scroll_y, 0, self.max_scroll_y);
    }
};

fn sdlMainLoop(args: *const ProgramArguments, window: *sdl.SDL_Window, face: ft.FT_Face, allocator: *Allocator, tree: *box_tree.BoxTree) !void {
    const pixel_format = sdl.SDL_AllocFormat(sdl.SDL_PIXELFORMAT_RGBA32) orelse unreachable;
    defer sdl.SDL_FreeFormat(pixel_format);

    const renderer = sdl.SDL_CreateRenderer(
        window,
        -1,
        sdl.SDL_RENDERER_ACCELERATED | sdl.SDL_RENDERER_PRESENTVSYNC,
    ) orelse unreachable;
    defer sdl.SDL_DestroyRenderer(renderer);
    assert(sdl.SDL_SetRenderDrawBlendMode(renderer, sdl.SDL_BlendMode.SDL_BLENDMODE_BLEND) == 0);

    var ps = try ProgramState.init(tree, window, renderer, pixel_format, face, allocator);
    defer ps.deinit(allocator);

    const scroll_speed = 15;

    var frame_times = [1]u64{0} ** 64;
    var frame_time_index: usize = 0;
    var sum_of_frame_times: u64 = 0;
    var timer = try std.time.Timer.start();

    var needs_relayout = false;
    var event: sdl.SDL_Event = undefined;
    mainLoop: while (true) {
        while (sdl.SDL_PollEvent(&event) != 0) {
            switch (@intToEnum(sdl.SDL_EventType, @intCast(c_int, event.@"type"))) {
                .SDL_WINDOWEVENT => {
                    switch (@intToEnum(sdl.SDL_WindowEventID, event.window.event)) {
                        .SDL_WINDOWEVENT_SIZE_CHANGED => {
                            ps.width = event.window.data1;
                            ps.height = event.window.data2;
                            needs_relayout = true;
                        },
                        else => {},
                    }
                },
                .SDL_KEYDOWN => {
                    switch (event.key.keysym.sym) {
                        sdl.SDLK_UP => {
                            ps.scroll_y -= scroll_speed;
                            if (ps.scroll_y < 0) ps.scroll_y = 0;
                        },
                        sdl.SDLK_DOWN => {
                            ps.scroll_y += scroll_speed;
                            if (ps.scroll_y > ps.max_scroll_y) ps.scroll_y = ps.max_scroll_y;
                        },
                        sdl.SDLK_HOME => {
                            ps.scroll_y = 0;
                        },
                        sdl.SDLK_END => {
                            ps.scroll_y = ps.max_scroll_y;
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
            try ps.updateDocument(allocator);
        }

        const viewport_rect = sdl.SDL_Rect{
            .x = 0,
            .y = 0,
            .w = ps.width,
            .h = ps.height,
        };
        const translation = sdl.SDL_Point{
            .x = 0,
            .y = -ps.scroll_y,
        };
        zss.sdl_freetype.drawBackgroundColor(renderer, pixel_format, viewport_rect, (@as(u32, args.bg_color) << 8) | 0xff);
        try zss.sdl_freetype.renderDocument(&ps.document, renderer, pixel_format, &ps.atlas, allocator, viewport_rect, translation);
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
