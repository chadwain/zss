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
const Element = ElementTree.Element;
const null_element = Element.null_element;
const CascadedValueStore = zss.CascadedValueStore;
const pixelToZssUnit = zss.render.sdl.pixelToZssUnit;
const DrawOrderList = zss.render.DrawOrderList;
const QuadTree = zss.render.QuadTree;

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
        //sdl.SDL_RENDERER_ACCELERATED,
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
        .bg_color = @as(u32, bg_color orelse @as(std.fmt.ParseIntError!u24, 0xefefef) catch |e| {
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
    var elements: [8]Element = undefined;
    try element_tree.allocateElements(allocator, &elements);

    const slice = element_tree.slice();
    const root = elements[0];

    const removed_block = elements[1];

    const title_block = elements[2];
    const title_inline_box = elements[3];
    const title_text = elements[4];

    const body_block = elements[5];
    const body_text = elements[6];

    const footer = elements[7];

    slice.setAll(root, .{
        .next_sibling = null_element,
        .first_child = removed_block,
        .last_child = footer,
    });

    slice.setAll(removed_block, .{
        .next_sibling = title_block,
        .first_child = null_element,
        .last_child = null_element,
    });

    slice.setAll(title_block, .{
        .next_sibling = body_block,
        .first_child = title_inline_box,
        .last_child = title_inline_box,
    });

    slice.setAll(title_inline_box, .{
        .next_sibling = null_element,
        .first_child = title_text,
        .last_child = title_text,
    });

    slice.setAll(title_text, .{
        .next_sibling = null_element,
        .first_child = null_element,
        .last_child = null_element,
    });

    slice.setAll(body_block, .{
        .next_sibling = footer,
        .first_child = body_text,
        .last_child = body_text,
    });

    slice.setAll(body_text, .{
        .next_sibling = null_element,
        .first_child = null_element,
        .last_child = null_element,
    });

    slice.setAll(footer, .{
        .next_sibling = null_element,
        .first_child = null_element,
        .last_child = null_element,
    });

    var cascaded = zss.CascadedValueStore{};
    defer cascaded.deinit(allocator);
    try cascaded.ensureTotalCapacity(allocator, elements.len);

    // Root element
    const root_border = zss.values.BorderWidth{ .px = 10 };
    const root_padding = zss.values.Padding{ .px = 30 };
    const root_border_color = zss.values.Color{ .rgba = 0xaf2233ff };
    cascaded.box_style.setAssumeCapacity(root, .{ .display = .block });
    cascaded.content_width.setAssumeCapacity(root, .{ .min_size = .{ .px = 200 } });
    cascaded.horizontal_edges.setAssumeCapacity(root, .{ .padding_start = root_padding, .padding_end = root_padding, .border_start = root_border, .border_end = root_border });
    cascaded.vertical_edges.setAssumeCapacity(root, .{ .padding_start = root_padding, .padding_end = root_padding, .border_start = root_border, .border_end = root_border });
    cascaded.border_colors.setAssumeCapacity(root, .{ .top = root_border_color, .right = root_border_color, .bottom = root_border_color, .left = root_border_color });
    cascaded.border_styles.setAssumeCapacity(root, .{ .top = .solid, .right = .solid, .bottom = .solid, .left = .solid });
    cascaded.background1.setAssumeCapacity(root, .{ .color = .{ .rgba = args.bg_color } });
    cascaded.background2.setAssumeCapacity(root, .{
        .image = .{ .object = zss.render.sdl.textureAsBackgroundImageObject(smile) },
        .position = .{ .position = .{
            .x = .{ .side = .right, .offset = .{ .percentage = 0 } },
            .y = .{ .side = .top, .offset = .{ .px = 10 } },
        } },
        .repeat = .{ .repeat = .{ .x = .no_repeat, .y = .no_repeat } },
    });
    cascaded.color.setAssumeCapacity(root, .{ .color = .{ .rgba = args.text_color } });
    cascaded.font.setAssumeCapacity(root, .{ .font = .{ .font = font } });

    // Large element with display: none
    cascaded.box_style.setAssumeCapacity(removed_block, .{ .display = .none });
    cascaded.content_width.setAssumeCapacity(removed_block, .{ .size = .{ .px = 10000 } });
    cascaded.content_height.setAssumeCapacity(removed_block, .{ .size = .{ .px = 10000 } });
    cascaded.background1.setAssumeCapacity(removed_block, .{ .color = .{ .rgba = 0xff00ffff } });

    // Title block box
    cascaded.box_style.setAssumeCapacity(title_block, .{ .display = .block, .position = .relative });
    cascaded.vertical_edges.setAssumeCapacity(title_block, .{ .border_end = .{ .px = 2 }, .margin_end = .{ .px = 24 } });
    cascaded.z_index.setAssumeCapacity(title_block, .{ .z_index = .{ .integer = -1 } });
    cascaded.border_colors.setAssumeCapacity(title_block, .{ .bottom = .{ .rgba = 0x202020ff } });
    cascaded.border_styles.setAssumeCapacity(title_block, .{ .bottom = .solid });

    // Title inline box
    cascaded.box_style.setAssumeCapacity(title_inline_box, .{ .display = .inline_ });
    cascaded.horizontal_edges.setAssumeCapacity(title_inline_box, .{ .padding_start = .{ .px = 10 }, .padding_end = .{ .px = 10 } });
    cascaded.vertical_edges.setAssumeCapacity(title_inline_box, .{ .padding_end = .{ .px = 5 } });
    cascaded.background1.setAssumeCapacity(title_inline_box, .{ .color = .{ .rgba = 0xfa58007f } });

    // Title text
    cascaded.box_style.setAssumeCapacity(title_text, .{ .display = .text });
    cascaded.text.setAssumeCapacity(title_text, .{ .text = args.filename });

    // Body block box
    cascaded.box_style.setAssumeCapacity(body_block, .{ .display = .block, .position = .relative });

    // Body text
    cascaded.box_style.setAssumeCapacity(body_text, .{ .display = .text });
    cascaded.text.setAssumeCapacity(body_text, .{ .text = bytes });

    // Footer block
    cascaded.box_style.setAssumeCapacity(footer, .{ .display = .block });
    // cascaded.content_width.setAssumeCapacity(footer, .{ .size = .{ .px = 50 } });
    cascaded.content_height.setAssumeCapacity(footer, .{ .size = .{ .px = 50 } });
    cascaded.horizontal_edges.setAssumeCapacity(footer, .{ .border_start = .inherit, .border_end = .inherit });
    cascaded.vertical_edges.setAssumeCapacity(footer, .{ .margin_start = .{ .px = 10 }, .border_start = .inherit, .border_end = .inherit });
    cascaded.border_colors.setAssumeCapacity(footer, .{ .top = .inherit, .right = .inherit, .bottom = .inherit, .left = .inherit });
    cascaded.border_styles.setAssumeCapacity(footer, .{ .top = .inherit, .right = .inherit, .bottom = .inherit, .left = .inherit });
    cascaded.background2.setAssumeCapacity(footer, .{
        .image = .{ .object = zss.render.sdl.textureAsBackgroundImageObject(zig_png) },
        .position = .{ .position = .{
            .x = .{ .side = .left, .offset = .{ .percentage = 0.5 } },
            .y = .{ .side = .top, .offset = .{ .percentage = 0.5 } },
        } },
        .repeat = .{ .repeat = .{ .x = .no_repeat, .y = .no_repeat } },
        .size = .contain,
    });

    try sdlMainLoop(window, renderer, face, allocator, &element_tree, root, &cascaded);
}

const ProgramState = struct {
    element_tree: *const ElementTree,
    root: Element,
    cascaded_values: *const CascadedValueStore,
    box_tree: zss.used_values.BoxTree,
    draw_order_list: DrawOrderList,
    atlas: zss.render.sdl.GlyphAtlas,
    width: c_int,
    height: c_int,
    scroll_y: c_int,
    max_scroll_y: c_int,
    timer: std.time.Timer,
    last_layout_time: u64,

    grid_size_log_2: u4,
    draw_grid: bool,

    const Self = @This();

    fn init(
        element_tree: *const ElementTree,
        root: Element,
        cascaded_values: *const CascadedValueStore,
        window: *sdl.SDL_Window,
        renderer: *sdl.SDL_Renderer,
        pixel_format: *sdl.SDL_PixelFormat,
        face: hb.FT_Face,
        allocator: Allocator,
    ) !Self {
        var result = @as(Self, undefined);

        result.element_tree = element_tree;
        result.root = root;
        result.cascaded_values = cascaded_values;
        sdl.SDL_GetWindowSize(window, &result.width, &result.height);
        result.timer = try std.time.Timer.start();
        result.grid_size_log_2 = 7;
        result.draw_grid = false;

        result.box_tree = try zss.layout.doLayout(
            element_tree,
            root,
            cascaded_values,
            allocator,
            .{ .width = @intCast(u32, result.width), .height = @intCast(u32, result.height) },
        );
        errdefer result.box_tree.deinit();

        result.last_layout_time = result.timer.read();

        result.draw_order_list = try DrawOrderList.create(result.box_tree, allocator);
        errdefer result.draw_order_list.deinit(allocator);

        result.atlas = try zss.render.sdl.GlyphAtlas.init(face, renderer, pixel_format, allocator);
        errdefer result.atlas.deinit();

        result.updateMaxScroll();
        return result;
    }

    fn deinit(self: *Self, allocator: Allocator) void {
        self.box_tree.deinit();
        self.draw_order_list.deinit(allocator);
        self.atlas.deinit(allocator);
    }

    fn updateBoxTree(self: *Self, allocator: Allocator) !void {
        self.timer.reset();
        var new_box_tree = try zss.layout.doLayout(
            self.element_tree,
            self.root,
            self.cascaded_values,
            allocator,
            .{ .width = @intCast(u32, self.width), .height = @intCast(u32, self.height) },
        );
        defer new_box_tree.deinit();
        self.last_layout_time = self.timer.read();

        var new_draw_order_list = try DrawOrderList.create(new_box_tree, allocator);
        defer new_draw_order_list.deinit(allocator);

        std.mem.swap(zss.used_values.BoxTree, &self.box_tree, &new_box_tree);
        std.mem.swap(DrawOrderList, &self.draw_order_list, &new_draw_order_list);
        self.updateMaxScroll();
    }

    fn updateMaxScroll(self: *Self) void {
        const root_box_offsets = self.box_tree.blocks.subtrees.items[0].box_offsets.items[1];
        self.max_scroll_y = std.math.max(0, zss.render.sdl.zssUnitToPixel(root_box_offsets.border_pos.y + root_box_offsets.border_size.h) - self.height);
        self.scroll_y = std.math.clamp(self.scroll_y, 0, self.max_scroll_y);
    }
};

fn sdlMainLoop(
    window: *sdl.SDL_Window,
    renderer: *sdl.SDL_Renderer,
    face: hb.FT_Face,
    allocator: Allocator,
    element_tree: *const ElementTree,
    root: Element,
    cascaded_values: *const CascadedValueStore,
) !void {
    const pixel_format = sdl.SDL_AllocFormat(sdl.SDL_PIXELFORMAT_RGBA32) orelse unreachable;
    defer sdl.SDL_FreeFormat(pixel_format);

    var ps = try ProgramState.init(element_tree, root, cascaded_values, window, renderer, pixel_format, face, allocator);
    defer ps.deinit(allocator);

    const stderr = std.io.getStdErr().writer();
    try ps.draw_order_list.print(stderr, allocator);
    try stderr.writeAll("\n");
    try ps.draw_order_list.quad_tree.print(stderr);
    try stderr.writeAll("\n");
    try stderr.print("You can scroll using the Up, Down, PageUp, PageDown, Home, and End keys.\n", .{});
    try stderr.print("You can toggle the grid by pressing G, and change its size with [ and ].\n", .{});
    try stderr.writeAll("Press S to get a list of all items on screen.\n");

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
                        sdl.SDLK_g => {
                            ps.draw_grid = !ps.draw_grid;
                            if (ps.draw_grid) {
                                try stderr.print("\nGrid size: {}px\n", .{@as(u16, 1) << ps.grid_size_log_2});
                            }
                        },
                        sdl.SDLK_RIGHTBRACKET => {
                            if (ps.draw_grid) {
                                if (ps.grid_size_log_2 > 2) ps.grid_size_log_2 -= 1;
                                try stderr.print("\nGrid size: {}px\n", .{@as(u16, 1) << ps.grid_size_log_2});
                            }
                        },
                        sdl.SDLK_LEFTBRACKET => {
                            if (ps.draw_grid) {
                                if (ps.grid_size_log_2 < 10) ps.grid_size_log_2 += 1;
                                try stderr.print("\nGrid size: {}px\n", .{@as(u16, 1) << ps.grid_size_log_2});
                            }
                        },
                        sdl.SDLK_s => {
                            try printObjectsOnScreen(ps, stderr, allocator);
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
            try ps.updateBoxTree(allocator);
            try ps.draw_order_list.print(stderr, allocator);
            try ps.draw_order_list.quad_tree.print(stderr);
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
        try zss.render.sdl.drawBoxTree(ps.box_tree, renderer, pixel_format, &ps.atlas, allocator, viewport_rect, translation);
        if (ps.draw_grid) drawGrid(@as(u16, 1) << ps.grid_size_log_2, renderer, viewport_rect, translation);
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

fn drawGrid(grid_size: u16, renderer: *sdl.SDL_Renderer, viewport_rect: sdl.SDL_Rect, translation: sdl.SDL_Point) void {
    assert(sdl.SDL_SetRenderDrawColor(renderer, 0, 0, 0, 255) == 0);
    {
        var num_lines = @divFloor(viewport_rect.w + grid_size, grid_size);
        while (num_lines > 0) : (num_lines -= 1) {
            const x_pos = @mod(translation.x, grid_size) + (num_lines - 1) * grid_size;
            assert(sdl.SDL_RenderDrawLine(renderer, x_pos, 0, x_pos, viewport_rect.h) == 0);
        }
    }
    {
        var num_lines = @divFloor(viewport_rect.h + grid_size, grid_size);
        while (num_lines > 0) : (num_lines -= 1) {
            const y_pos = @mod(translation.y, grid_size) + (num_lines - 1) * grid_size;
            assert(sdl.SDL_RenderDrawLine(renderer, 0, y_pos, viewport_rect.w, y_pos) == 0);
        }
    }
}

fn printObjectsOnScreen(ps: ProgramState, stderr: std.fs.File.Writer, allocator: Allocator) !void {
    const intersects = try ps.draw_order_list.quad_tree.findObjectsInRect(.{
        .x = pixelToZssUnit(0),
        .y = pixelToZssUnit(ps.scroll_y),
        .w = pixelToZssUnit(ps.width),
        .h = pixelToZssUnit(ps.height),
    }, allocator);
    defer allocator.free(intersects);
    try stderr.writeAll("\nObjects on screen:\n");
    for (intersects) |object| {
        try stderr.writeAll("\t");
        try ps.draw_order_list.printQuadTreeObject(object, stderr);
        try stderr.writeAll("\n");
    }
}
