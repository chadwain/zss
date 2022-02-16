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
const ElementTree = zss.ElementTree;
const ValueTree = zss.ValueTree;
const pixelToZssUnit = zss.render.sdl.pixelToZssUnit;

const sdl = @import("SDL2");
const hb = @import("harfbuzz");

const usage = "Usage: demo [--font <file>] [--font-size <integer>] [--color <hex color>] [--bg-color <hex color>] <file>";

pub fn main() !u8 {
    const stderr = std.io.getStdErr().writer();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer assert(!gpa.deinit());
    var allocator = gpa.allocator();

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
    assert(sdl.SDL_SetRenderDrawBlendMode(renderer, sdl.SDL_BLENDMODE_BLEND) == 0);

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

fn createBoxTree(args: *const ProgramArguments, window: *sdl.SDL_Window, renderer: *sdl.SDL_Renderer, face: hb.FT_Face, allocator: Allocator, bytes: []const u8) !void {
    const font = hb.hb_ft_font_create_referenced(face) orelse unreachable;
    defer hb.hb_font_destroy(font);
    hb.hb_ft_font_set_funcs(font);

    const smile = sdl.IMG_LoadTexture(renderer, "demo/smile.png") orelse return error.ResourceLoadFail;
    defer sdl.SDL_DestroyTexture(smile);

    const zig_png = sdl.IMG_LoadTexture(renderer, "demo/zig.png") orelse return error.ResourceLoadFail;
    defer sdl.SDL_DestroyTexture(zig_png);

    var element_tree = zss.ElementTree{};
    defer element_tree.deinit(allocator);

    const num_elements = 9;
    try element_tree.ensureTotalCapacity(allocator, num_elements);
    const root = element_tree.createRootAssumeCapacity(.{});
    const root_0 = element_tree.appendChildAssumeCapacity(root, .{});
    const root_1 = element_tree.appendChildAssumeCapacity(root, .{});
    const root_1_0 = element_tree.appendChildAssumeCapacity(root_1, .{});
    const root_1_0_0 = element_tree.appendChildAssumeCapacity(root_1_0, .{});
    const root_2 = element_tree.appendChildAssumeCapacity(root, .{});
    const root_2_0 = element_tree.appendChildAssumeCapacity(root_2, .{});
    const root_2_0_0 = element_tree.appendChildAssumeCapacity(root_2_0, .{});
    const root_3 = element_tree.appendChildAssumeCapacity(root, .{});
    const skips = element_tree.skips();

    var cascaded = zss.ValueTree{
        .font = .{ .font = font, .color = .{ .rgba = args.text_color } },
    };
    defer cascaded.deinit(allocator);
    const v = &cascaded.values;

    try v.text.ensureTotalCapacity(allocator, num_elements);
    try v.box_style.ensureTotalCapacity(allocator, num_elements);
    try v.z_index.ensureTotalCapacity(allocator, num_elements);
    try v.widths.ensureTotalCapacity(allocator, num_elements);
    try v.horizontal_sizes.ensureTotalCapacity(allocator, num_elements);
    try v.heights.ensureTotalCapacity(allocator, num_elements);
    try v.vertical_sizes.ensureTotalCapacity(allocator, num_elements);
    try v.color.ensureTotalCapacity(allocator, num_elements);
    try v.border_colors.ensureTotalCapacity(allocator, num_elements);
    try v.background1.ensureTotalCapacity(allocator, num_elements);
    try v.background2.ensureTotalCapacity(allocator, num_elements);

    // Root element
    const root_border = zss.value.BorderWidth{ .px = 10 };
    const root_padding = zss.value.Padding{ .px = 30 };
    const root_border_color = zss.value.Color{ .rgba = 0xaf2233ff };
    v.box_style.insertAssumeCapacity(skips, root, .{ .display = .block });
    v.widths.insertAssumeCapacity(skips, root, .{ .min_size = .{ .px = 200 } });
    v.horizontal_sizes.insertAssumeCapacity(skips, root, .{ .padding_start = root_padding, .padding_end = root_padding, .border_start = root_border, .border_end = root_border });
    v.vertical_sizes.insertAssumeCapacity(skips, root, .{ .padding_start = root_padding, .padding_end = root_padding, .border_start = root_border, .border_end = root_border });
    v.border_colors.insertAssumeCapacity(skips, root, .{ .top = root_border_color, .right = root_border_color, .bottom = root_border_color, .left = root_border_color });
    v.background1.insertAssumeCapacity(skips, root, .{ .color = .{ .rgba = args.bg_color } });
    v.background2.insertAssumeCapacity(skips, root, .{
        .image = .{ .object = zss.render.sdl.textureAsBackgroundImageObject(smile) },
        .position = .{ .position = .{
            .x = .{ .side = .right, .offset = .{ .percentage = 0 } },
            .y = .{ .side = .top, .offset = .{ .px = 10 } },
        } },
        .repeat = .{ .repeat = .{ .x = .no_repeat, .y = .no_repeat } },
    });

    // Large element with display: none
    v.box_style.insertAssumeCapacity(skips, root_0, .{ .display = .none });
    v.widths.insertAssumeCapacity(skips, root_0, .{ .size = .{ .px = 10000 } });
    v.heights.insertAssumeCapacity(skips, root_0, .{ .size = .{ .px = 10000 } });

    // Title block box
    v.box_style.insertAssumeCapacity(skips, root_1, .{ .display = .block, .position = .relative });
    v.vertical_sizes.insertAssumeCapacity(skips, root_1, .{ .border_end = .{ .px = 2 }, .margin_end = .{ .px = 24 } });
    v.z_index.insertAssumeCapacity(skips, root_1, .{ .z_index = .{ .integer = -1 } });
    v.border_colors.insertAssumeCapacity(skips, root_1, .{ .bottom = .{ .rgba = 0x202020ff } });

    // Title inline box
    v.box_style.insertAssumeCapacity(skips, root_1_0, .{ .display = .inline_ });
    v.horizontal_sizes.insertAssumeCapacity(skips, root_1_0, .{ .padding_start = .{ .px = 10 }, .padding_end = .{ .px = 10 } });
    v.vertical_sizes.insertAssumeCapacity(skips, root_1_0, .{ .padding_end = .{ .px = 5 } });
    v.background1.insertAssumeCapacity(skips, root_1_0, .{ .color = .{ .rgba = 0xfa58007f } });

    // Title text
    v.box_style.insertAssumeCapacity(skips, root_1_0_0, .{ .display = .text });
    v.text.insertAssumeCapacity(skips, root_1_0_0, .{ .text = args.filename });

    // Body block box
    v.box_style.insertAssumeCapacity(skips, root_2, .{ .display = .block, .position = .relative });

    // Body inline box
    v.box_style.insertAssumeCapacity(skips, root_2_0, .{ .display = .inline_ });

    // Body text
    v.box_style.insertAssumeCapacity(skips, root_2_0_0, .{ .display = .text });
    v.text.insertAssumeCapacity(skips, root_2_0_0, .{ .text = bytes });

    // Footer block
    v.box_style.insertAssumeCapacity(skips, root_3, .{ .display = .block });
    v.heights.insertAssumeCapacity(skips, root_3, .{ .size = .{ .px = 50 } });
    v.horizontal_sizes.insertAssumeCapacity(skips, root_3, .{ .border_start = .inherit, .border_end = .inherit });
    v.vertical_sizes.insertAssumeCapacity(skips, root_3, .{ .margin_start = .{ .px = 10 }, .border_start = .inherit, .border_end = .inherit });
    v.border_colors.insertAssumeCapacity(skips, root_3, .{ .top = root_border_color, .right = root_border_color, .bottom = root_border_color, .left = root_border_color });
    v.background2.insertAssumeCapacity(skips, root_3, .{
        .image = .{ .object = zss.render.sdl.textureAsBackgroundImageObject(zig_png) },
        .position = .{ .position = .{
            .x = .{ .side = .left, .offset = .{ .percentage = 0.5 } },
            .y = .{ .side = .top, .offset = .{ .percentage = 0.5 } },
        } },
        .repeat = .{ .repeat = .{ .x = .no_repeat, .y = .no_repeat } },
        .size = .{ .contain = {} },
    });

    try sdlMainLoop(window, renderer, face, allocator, &element_tree, &cascaded);
}

const ProgramState = struct {
    element_tree: *const ElementTree,
    cascaded_value_tree: *const ValueTree,
    document: zss.used_values.Document,
    atlas: zss.render.sdl.GlyphAtlas,
    width: c_int,
    height: c_int,
    scroll_y: c_int,
    max_scroll_y: c_int,
    timer: std.time.Timer,
    last_layout_time: u64,

    const Self = @This();

    fn init(
        element_tree: *const ElementTree,
        cascaded_value_tree: *const ValueTree,
        window: *sdl.SDL_Window,
        renderer: *sdl.SDL_Renderer,
        pixel_format: *sdl.SDL_PixelFormat,
        face: hb.FT_Face,
        allocator: Allocator,
    ) !Self {
        var result = @as(Self, undefined);

        result.element_tree = element_tree;
        result.cascaded_value_tree = cascaded_value_tree;
        sdl.SDL_GetWindowSize(window, &result.width, &result.height);
        result.timer = try std.time.Timer.start();

        result.document = try zss.layout.doLayout(element_tree, cascaded_value_tree, allocator, .{ .w = pixelToZssUnit(result.width), .h = pixelToZssUnit(result.height) });
        errdefer result.document.deinit();

        result.last_layout_time = result.timer.read();

        result.atlas = try zss.render.sdl.GlyphAtlas.init(face, renderer, pixel_format, allocator);
        errdefer result.atlas.deinit();

        result.updateMaxScroll();
        return result;
    }

    fn deinit(self: *Self, allocator: Allocator) void {
        self.document.deinit();
        self.atlas.deinit(allocator);
    }

    fn updateDocument(self: *Self, allocator: Allocator) !void {
        self.timer.reset();
        var new_document = try zss.layout.doLayout(self.element_tree, self.cascaded_value_tree, allocator, .{ .w = pixelToZssUnit(self.width), .h = pixelToZssUnit(self.height) });
        self.last_layout_time = self.timer.read();
        self.document.deinit();
        self.document = new_document;
        self.updateMaxScroll();
    }

    fn updateMaxScroll(self: *Self) void {
        self.max_scroll_y = std.math.max(0, zss.render.sdl.zssUnitToPixel(self.document.blocks.box_offsets.items[1].border_end.y) - self.height);
        self.scroll_y = std.math.clamp(self.scroll_y, 0, self.max_scroll_y);
    }
};

fn sdlMainLoop(
    window: *sdl.SDL_Window,
    renderer: *sdl.SDL_Renderer,
    face: hb.FT_Face,
    allocator: Allocator,
    element_tree: *const ElementTree,
    cascaded_value_tree: *const ValueTree,
) !void {
    const pixel_format = sdl.SDL_AllocFormat(sdl.SDL_PIXELFORMAT_RGBA32) orelse unreachable;
    defer sdl.SDL_FreeFormat(pixel_format);

    var ps = try ProgramState.init(element_tree, cascaded_value_tree, window, renderer, pixel_format, face, allocator);
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
            switch (event.@"type") {
                sdl.SDL_WINDOWEVENT => {
                    switch (event.window.event) {
                        sdl.SDL_WINDOWEVENT_SIZE_CHANGED => {
                            ps.width = event.window.data1;
                            ps.height = event.window.data2;
                            needs_relayout = true;
                        },
                        else => {},
                    }
                },
                sdl.SDL_KEYDOWN => {
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
                sdl.SDL_QUIT => {
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
