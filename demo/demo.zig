//! This demo program shows how one might use zss.
//! This program takes as input the name of some text file on your computer,
//! and displays the contents of that file in a graphical window.
//! The window can be resized, and you can use the Up, Down, PageUp, PageDown
//! Home, and End keys to navigate. The font, font size, text color, and
//! background color can be changed using commandline options.
//!
//! To see a roughly equivalent HTML document, see demo.html.
const std = @import("std");
const fs = std.fs;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const zss = @import("zss");
const BoxTree = zss.BoxTree;
const pixelToZssUnit = zss.render.sdl.pixelToZssUnit;

const sdl = @import("SDL2");
const hb = @import("harfbuzz");

const usage = "Usage: demo [--font <file>] [--font-size <integer>] [--color <hex color>] [--bg-color <hex color>] <file>";

pub fn main() !u8 {
    const stderr = std.io.getStdErr().writer();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer assert(!gpa.deinit());
    var allocator = &gpa.allocator;

    const program_args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, program_args);
    const args = parseArgs(program_args[1..], stderr);

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

    _ = sdl.IMG_Init(sdl.IMG_INIT_PNG | sdl.IMG_INIT_JPG);
    defer sdl.IMG_Quit();

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

    const renderer = sdl.SDL_CreateRenderer(
        window,
        -1,
        sdl.SDL_RENDERER_ACCELERATED | sdl.SDL_RENDERER_PRESENTVSYNC,
    ) orelse unreachable;
    defer sdl.SDL_DestroyRenderer(renderer);
    assert(sdl.SDL_SetRenderDrawBlendMode(renderer, sdl.SDL_BlendMode.SDL_BLENDMODE_BLEND) == 0);

    var library: hb.FT_Library = undefined;
    assert(hb.FT_Init_FreeType(&library) == hb.FT_Err_Ok);
    defer assert(hb.FT_Done_FreeType(library) == hb.FT_Err_Ok);

    var face: hb.FT_Face = undefined;
    if (hb.FT_New_Face(library, args.font_filename, 0, &face) != hb.FT_Err_Ok) {
        stderr.print("Error loading font file: {s}\n", .{args.font_filename}) catch {};
        return 1;
    }
    defer assert(hb.FT_Done_Face(face) == hb.FT_Err_Ok);

    assert(hb.FT_Set_Char_Size(face, 0, @intCast(c_long, args.font_size) * 64, 96, 96) == hb.FT_Err_Ok);

    try createBoxTree(&args, window, renderer, face, allocator, text);
    return 0;
}

const ProgramArguments = struct {
    filename: [:0]const u8,
    font_filename: [:0]const u8,
    font_size: u32,
    text_color: u32,
    bg_color: u32,
};

fn parseArgs(args: []const [:0]const u8, stderr: std.fs.File.Writer) ProgramArguments {
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
                stderr.print("Argument syntax error\n{s}\n", .{usage}) catch {};
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
                stderr.print("Unrecognized option: {s}\n{s}\n", .{ arg, usage }) catch {};
                std.os.exit(1);
            }
        }
    }

    return ProgramArguments{
        .filename = filename orelse {
            stderr.print("Input file not specified\n{s}\n", .{usage}) catch {};
            std.os.exit(1);
        },
        .font_filename = font_filename orelse "demo/NotoSans-Regular.ttf",
        .font_size = font_size orelse @as(std.fmt.ParseIntError!u32, 14) catch |e| {
            stderr.print("Unable to parse font size: {s}", .{@errorName(e)}) catch {};
            std.os.exit(1);
        },
        .text_color = @as(u32, text_color orelse @as(std.fmt.ParseIntError!u24, 0x101010) catch |e| {
            stderr.print("Unable to parse text color: {s}", .{@errorName(e)}) catch {};
            std.os.exit(1);
        }) << 8 | 0xff,
        .bg_color = @as(u32, bg_color orelse @as(std.fmt.ParseIntError!u24, 0xeeeeee) catch |e| {
            stderr.print("Unable to parse background color: {s}", .{@errorName(e)}) catch {};
            std.os.exit(1);
        }) << 8 | 0xff,
    };
}

fn createBoxTree(args: *const ProgramArguments, window: *sdl.SDL_Window, renderer: *sdl.SDL_Renderer, face: hb.FT_Face, allocator: *Allocator, bytes: []const u8) !void {
    const font = hb.hb_ft_font_create_referenced(face) orelse unreachable;
    defer hb.hb_font_destroy(font);
    hb.hb_ft_font_set_funcs(font);

    const smile = sdl.IMG_LoadTexture(renderer, "demo/smile.png") orelse return error.ResourceLoadFail;
    defer sdl.SDL_DestroyTexture(smile);

    const zig_png = sdl.IMG_LoadTexture(renderer, "demo/zig.png") orelse return error.ResourceLoadFail;
    defer sdl.SDL_DestroyTexture(zig_png);

    const root_border = BoxTree.LogicalSize.BorderWidth{ .px = 10 };
    const root_padding = BoxTree.LogicalSize.Padding{ .px = 30 };
    const root_border_color = BoxTree.Border.Color{ .rgba = 0xaf2233ff };

    const len = 9;
    var structure = [len]BoxTree.BoxId{ 9, 1, 3, 2, 1, 3, 2, 1, 1 };
    var inline_size = [len]BoxTree.LogicalSize{
        .{ .min_size = .{ .px = 200 }, .padding_start = root_padding, .padding_end = root_padding, .border_start = root_border, .border_end = root_border },
        .{ .size = .{ .px = 10000 } },
        .{},
        .{ .padding_start = .{ .px = 10 }, .padding_end = .{ .px = 10 } },
        .{},
        .{},
        .{},
        .{},
        .{},
    };
    var block_size = [len]BoxTree.LogicalSize{
        .{ .padding_start = root_padding, .padding_end = .{ .px = 12 }, .border_start = root_border, .border_end = root_border },
        .{ .size = .{ .px = 10000 } },
        .{ .border_end = .{ .px = 2 }, .margin_end = .{ .px = 24 } },
        .{ .padding_end = .{ .px = 5 } },
        .{},
        .{},
        .{},
        .{},
        .{ .size = .{ .px = 50 }, .margin_start = .{ .px = 10 } },
    };
    var display = [len]BoxTree.Display{
        .{ .block = {} },
        .{ .none = {} },
        .{ .block = {} },
        .{ .inline_ = {} },
        .{ .text = {} },
        .{ .block = {} },
        .{ .inline_ = {} },
        .{ .text = {} },
        .{ .block = {} },
    };
    var position = [len]BoxTree.Positioning{
        .{},
        .{},
        .{ .style = .{ .relative = {} }, .z_index = .{ .value = -1 } },
        .{},
        .{},
        .{ .style = .{ .relative = {} } },
        .{},
        .{},
        .{},
    };
    var insets = [len]BoxTree.Insets{
        .{},
        .{},
        .{},
        .{},
        .{},
        .{},
        .{},
        .{},
        .{},
    };
    var latin1_text = [len]BoxTree.Latin1Text{
        .{},
        .{},
        .{},
        .{},
        .{ .text = args.filename },
        .{},
        .{},
        .{ .text = bytes },
        .{},
    };
    var border = [len]BoxTree.Border{
        .{ .inline_start_color = root_border_color, .inline_end_color = root_border_color, .block_start_color = root_border_color, .block_end_color = root_border_color },
        .{},
        .{ .block_end_color = .{ .rgba = 0x202020ff } },
        .{},
        .{},
        .{},
        .{},
        .{},
        .{},
    };
    var background = [len]BoxTree.Background{
        .{
            .image = .{ .object = zss.render.sdl.textureAsBackgroundImageObject(smile) },
            .position = .{ .position = .{
                .x = .{ .side = .right },
                .y = .{ .offset = .{ .px = 10 } },
            } },
            .repeat = .{ .repeat = .{ .x = .no_repeat, .y = .no_repeat } },
            .color = .{ .rgba = args.bg_color },
        },
        .{},
        .{},
        .{ .color = .{ .rgba = 0xfa58007f } },
        .{},
        .{},
        .{},
        .{},
        .{
            .image = .{ .object = zss.render.sdl.textureAsBackgroundImageObject(zig_png) },
            .position = .{ .position = .{
                .x = .{ .offset = .{ .percentage = 0.5 } },
                .y = .{ .offset = .{ .percentage = 0.5 } },
            } },
            .repeat = .{ .repeat = .{ .x = .no_repeat, .y = .no_repeat } },
            .size = .{ .contain = {} },
        },
    };
    const tree = BoxTree{
        .structure = &structure,
        .inline_size = &inline_size,
        .block_size = &block_size,
        .display = &display,
        .position = &position,
        .insets = &insets,
        .latin1_text = &latin1_text,
        .border = &border,
        .background = &background,
        .font = .{ .font = font, .color = .{ .rgba = args.text_color } },
    };

    try sdlMainLoop(args, window, renderer, face, allocator, &tree);
}

const ProgramState = struct {
    tree: *const BoxTree,
    document: zss.used_values.Document,
    atlas: zss.render.sdl.GlyphAtlas,
    width: c_int,
    height: c_int,
    scroll_y: c_int,
    max_scroll_y: c_int,
    timer: std.time.Timer,
    last_layout_time: u64,

    const Self = @This();

    fn init(tree: *const BoxTree, window: *sdl.SDL_Window, renderer: *sdl.SDL_Renderer, pixel_format: *sdl.SDL_PixelFormat, face: hb.FT_Face, allocator: *Allocator) !Self {
        var result = @as(Self, undefined);

        result.tree = tree;
        sdl.SDL_GetWindowSize(window, &result.width, &result.height);
        result.timer = try std.time.Timer.start();

        result.document = try zss.layout.doLayout(tree, allocator, pixelToZssUnit(result.width), pixelToZssUnit(result.height));
        errdefer result.document.deinit();

        result.last_layout_time = result.timer.read();

        result.atlas = try zss.render.sdl.GlyphAtlas.init(face, renderer, pixel_format, allocator);
        errdefer result.atlas.deinit();

        result.updateMaxScroll();
        return result;
    }

    fn deinit(self: *Self, allocator: *Allocator) void {
        self.document.deinit();
        self.atlas.deinit(allocator);
    }

    fn updateDocument(self: *Self, allocator: *Allocator) !void {
        self.timer.reset();
        var new_document = try zss.layout.doLayout(self.tree, allocator, pixelToZssUnit(self.width), pixelToZssUnit(self.height));
        self.last_layout_time = self.timer.read();
        self.document.deinit();
        self.document = new_document;
        self.updateMaxScroll();
    }

    fn updateMaxScroll(self: *Self) void {
        self.max_scroll_y = std.math.max(0, zss.render.sdl.zssUnitToPixel(self.document.blocks.box_offsets.items[0].border_end.y) - self.height);
        self.scroll_y = std.math.clamp(self.scroll_y, 0, self.max_scroll_y);
    }
};

fn sdlMainLoop(args: *const ProgramArguments, window: *sdl.SDL_Window, renderer: *sdl.SDL_Renderer, face: hb.FT_Face, allocator: *Allocator, tree: *const BoxTree) !void {
    const pixel_format = sdl.SDL_AllocFormat(sdl.SDL_PIXELFORMAT_RGBA32) orelse unreachable;
    defer sdl.SDL_FreeFormat(pixel_format);

    var ps = try ProgramState.init(tree, window, renderer, pixel_format, face, allocator);
    defer ps.deinit(allocator);

    const stderr = std.io.getStdErr().writer();
    try stderr.print("You can scroll using the Up, Down, PageUp, PageDown, Home, and End keys.\n", .{});

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
                        sdl.SDLK_PAGEUP => {
                            ps.scroll_y -= ps.height;
                            if (ps.scroll_y < 0) ps.scroll_y = 0;
                        },
                        sdl.SDLK_PAGEDOWN => {
                            ps.scroll_y += ps.height;
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
        assert(sdl.SDL_SetRenderDrawColor(renderer, 0, 0, 0, 255) == 0);
        assert(sdl.SDL_RenderClear(renderer) == 0);
        try zss.render.sdl.renderDocument(&ps.document, renderer, pixel_format, &ps.atlas, allocator, viewport_rect, translation);
        sdl.SDL_RenderPresent(renderer);

        const frame_time = timer.lap();
        const frame_time_slot = &frame_times[frame_time_index % frame_times.len];
        sum_of_frame_times -= frame_time_slot.*;
        frame_time_slot.* = frame_time;
        sum_of_frame_times += frame_time;
        frame_time_index +%= 1;
        const average_frame_time = sum_of_frame_times / (frame_times.len * 1000);
        const last_layout_time_ms = ps.last_layout_time / 1000;
        try stderr.print("\rLast layout time: {}.{}ms     Average frame time: {}.{}ms", .{ last_layout_time_ms / 1000, last_layout_time_ms % 1000, average_frame_time / 1000, average_frame_time % 1000 });
    }
}
