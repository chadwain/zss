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
const CascadedValues = ElementTree.CascadedValues;
const pixelToZssUnit = zss.render.sdl.pixelToZssUnit;
const DrawOrderList = zss.render.DrawOrderList;
const QuadTree = zss.render.QuadTree;

const sdl = @import("SDL2");
const hb = @import("harfbuzz");
const sdlMainLoop = @import("./show_document_sdl.zig").sdlMainLoop;

const usage = "Usage: demo [--font <file>] [--font-size <integer>] [--color <hex color>] [--bg-color <hex color>] <file>";

pub fn main() !u8 {
    const stderr = std.io.getStdErr().writer();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer assert(gpa.deinit() == .ok);
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

    assert(hb.FT_Set_Char_Size(face, 0, @as(c_long, @intCast(args.font_size)) * 64, 96, 96) == hb.FT_Err_Ok);

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

    var element_tree = zss.ElementTree.init(allocator);
    defer element_tree.deinit();
    var elements: [8]Element = undefined;
    try element_tree.allocateElements(&elements);

    const root = elements[0];
    const removed_block = elements[1];
    const title_block = elements[2];
    const title_inline_box = elements[3];
    const title_text = elements[4];
    const body_block = elements[5];
    const body_text = elements[6];
    const footer = elements[7];

    const slice = element_tree.slice();

    slice.initElement(root, .normal, .orphan, {});
    slice.initElement(removed_block, .normal, .first_child_of, root);
    slice.initElement(title_block, .normal, .last_child_of, root);
    slice.initElement(title_inline_box, .normal, .first_child_of, title_block);
    slice.initElement(title_text, .text, .first_child_of, title_inline_box);
    slice.initElement(body_block, .normal, .last_child_of, root);
    slice.initElement(body_text, .text, .first_child_of, body_block);
    slice.initElement(footer, .normal, .last_child_of, root);

    {
        const arena = slice.arena;
        var cv: *CascadedValues = undefined;

        // Root element
        cv = slice.ptr(.cascaded_values, root);
        const root_border = zss.values.BorderWidth{ .px = 10 };
        const root_padding = zss.values.Padding{ .px = 30 };
        const root_border_color = zss.values.Color{ .rgba = 0xaf2233ff };
        try cv.add(arena, .box_style, .{ .display = .block });
        try cv.add(arena, .content_width, .{ .min_width = .{ .px = 200 } });
        try cv.add(arena, .horizontal_edges, .{
            .padding_left = root_padding,
            .padding_right = root_padding,
            .border_left = root_border,
            .border_right = root_border,
        });
        try cv.add(arena, .vertical_edges, .{
            .padding_top = root_padding,
            .padding_bottom = root_padding,
            .border_top = root_border,
            .border_bottom = root_border,
        });
        try cv.add(arena, .border_colors, .{
            .top = root_border_color,
            .right = root_border_color,
            .bottom = root_border_color,
            .left = root_border_color,
        });
        try cv.add(arena, .border_styles, .{ .top = .solid, .right = .solid, .bottom = .solid, .left = .solid });
        try cv.add(arena, .background1, .{ .color = .{ .rgba = args.bg_color } });
        try cv.add(arena, .background2, .{
            .image = .{ .object = zss.render.sdl.textureAsBackgroundImageObject(smile) },
            .position = .{ .position = .{
                .x = .{ .side = .right, .offset = .{ .percentage = 0 } },
                .y = .{ .side = .top, .offset = .{ .px = 10 } },
            } },
            .repeat = .{ .repeat = .{ .x = .no_repeat, .y = .no_repeat } },
        });
        try cv.add(arena, .color, .{ .color = .{ .rgba = args.text_color } });
        try cv.add(arena, .font, .{ .font = .{ .font = font } });

        // Large element with display: none
        cv = slice.ptr(.cascaded_values, removed_block);
        try cv.add(arena, .box_style, .{ .display = .none });
        try cv.add(arena, .content_width, .{ .width = .{ .px = 10000 } });
        try cv.add(arena, .content_height, .{ .height = .{ .px = 10000 } });
        try cv.add(arena, .background1, .{ .color = .{ .rgba = 0xff00ffff } });

        // Title block box
        cv = slice.ptr(.cascaded_values, title_block);
        try cv.add(arena, .box_style, .{ .display = .block, .position = .relative });
        try cv.add(arena, .vertical_edges, .{ .border_bottom = .{ .px = 2 }, .margin_bottom = .{ .px = 24 } });
        try cv.add(arena, .z_index, .{ .z_index = .{ .integer = -1 } });
        try cv.add(arena, .border_colors, .{ .bottom = .{ .rgba = 0x202020ff } });
        try cv.add(arena, .border_styles, .{ .bottom = .solid });

        // Title inline box
        cv = slice.ptr(.cascaded_values, title_inline_box);
        try cv.add(arena, .box_style, .{ .display = .inline_ });
        try cv.add(arena, .horizontal_edges, .{ .padding_left = .{ .px = 10 }, .padding_right = .{ .px = 10 } });
        try cv.add(arena, .vertical_edges, .{ .padding_bottom = .{ .px = 5 } });
        try cv.add(arena, .background1, .{ .color = .{ .rgba = 0xfa58007f } });

        // Title text
        cv = slice.ptr(.cascaded_values, title_text);
        try cv.add(arena, .box_style, .{ .display = .text });
        slice.set(.text, title_text, args.filename);

        // Body block box
        cv = slice.ptr(.cascaded_values, body_block);
        try cv.add(arena, .box_style, .{ .display = .block, .position = .relative });

        // Body text
        cv = slice.ptr(.cascaded_values, body_text);
        try cv.add(arena, .box_style, .{ .display = .text });
        slice.set(.text, body_text, bytes);

        // Footer block
        cv = slice.ptr(.cascaded_values, footer);
        try cv.add(arena, .box_style, .{ .display = .block });
        // try cv.add(arena, .content_width, .{ .width = .{ .px = 50 } });
        try cv.add(arena, .content_height, .{ .height = .{ .px = 50 } });
        try cv.add(arena, .horizontal_edges, .{ .border_left = .inherit, .border_right = .inherit });
        try cv.add(arena, .vertical_edges, .{ .margin_top = .{ .px = 10 }, .border_top = .inherit, .border_bottom = .inherit });
        try cv.add(arena, .border_colors, .{ .top = .inherit, .right = .inherit, .bottom = .inherit, .left = .inherit });
        try cv.add(arena, .border_styles, .{ .top = .inherit, .right = .inherit, .bottom = .inherit, .left = .inherit });
        try cv.add(arena, .background2, .{
            .image = .{ .object = zss.render.sdl.textureAsBackgroundImageObject(zig_png) },
            .position = .{ .position = .{
                .x = .{ .side = .left, .offset = .{ .percentage = 0.5 } },
                .y = .{ .side = .top, .offset = .{ .percentage = 0.5 } },
            } },
            .repeat = .{ .repeat = .{ .x = .no_repeat, .y = .no_repeat } },
            .size = .contain,
        });
    }

    try sdlMainLoop(window, renderer, face, allocator, element_tree.slice(), root);
}
