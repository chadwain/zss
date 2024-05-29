const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const zss = @import("zss");
const hb = @import("mach-harfbuzz").c;
const zgl = @import("zgl");
const zigimg = @import("zigimg");
const glfw = @import("mach-glfw");

const ZssUnit = zss.used_values.ZssUnit;
const zss_units_per_pixel = zss.used_values.units_per_pixel;

const ProgramState = struct {
    main_window: glfw.Window,
    main_window_height: ZssUnit,
    current_scroll: ZssUnit = 0,
    max_scroll: ZssUnit,

    fn changeMainWindowSize(self: *ProgramState, height: i32, box_tree: zss.used_values.BoxTree) void {
        self.main_window_height = height * zss_units_per_pixel;
        const root_block_height = box_tree.rootBlockHeight();
        self.max_scroll = @max(0, root_block_height - self.main_window_height);
        self.scroll(.nowhere);
    }

    fn scroll(self: *ProgramState, comptime direction: enum { nowhere, up, down, page_up, page_down }) void {
        const scroll_amount = 20 * zss_units_per_pixel;
        switch (direction) {
            .nowhere => {},
            .up => self.current_scroll -= scroll_amount,
            .down => self.current_scroll += scroll_amount,
            .page_up => self.current_scroll -= self.main_window_height,
            .page_down => self.current_scroll += self.main_window_height,
        }
        self.current_scroll = std.math.clamp(self.current_scroll, 0, self.max_scroll);
    }
};

pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    const program_args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, program_args);

    const file_name = program_args[1];
    var file_contents = try readFile(allocator, file_name);
    defer file_contents.deinit(allocator);

    var library: hb.FT_Library = undefined;
    _ = hb.FT_Init_FreeType(&library);
    defer _ = hb.FT_Done_FreeType(library);

    const font_filename = "demo/NotoSans-Regular.ttf";
    var face: hb.FT_Face = undefined;
    _ = hb.FT_New_Face(library, font_filename, 0, &face);
    defer _ = hb.FT_Done_Face(face);

    const font_size = 14;
    // TODO: Get display DPI
    _ = hb.FT_Set_Char_Size(face, 0, font_size * 64, 96, 96);

    const font = hb.hb_ft_font_create_referenced(face) orelse @panic("Couldn't create font!");
    defer hb.hb_font_destroy(font);
    hb.hb_ft_font_set_funcs(font);

    std.debug.print("\n{s}\n", .{glfw.getVersionString()});

    errdefer |err| if (err == error.GlfwError) {
        const glfw_error = glfw.getError().?;
        std.debug.print("GLFWError({s}): {?s}\n", .{ @errorName(glfw_error.error_code), glfw_error.description });
    };

    if (!glfw.init(.{})) return error.GlfwError;
    defer glfw.terminate();

    const width = 800;
    const height = 600;
    const window = glfw.Window.create(width, height, "zss demo", null, null, .{
        .context_version_major = 3,
        .context_version_minor = 3,
        .opengl_profile = .opengl_core_profile,
    }) orelse return error.GlfwError;
    defer window.destroy();

    var program_state = ProgramState{
        .main_window = window,
        .main_window_height = undefined,
        .max_scroll = undefined,
    };
    window.setUserPointer(&program_state);
    window.setKeyCallback(keyCallback);

    glfw.makeContextCurrent(window);
    defer glfw.makeContextCurrent(null);

    glfw.swapInterval(1);

    const getProcAddressWrapper = struct {
        fn f(_: void, symbol_name: [:0]const u8) ?*const anyopaque {
            return glfw.getProcAddress(symbol_name);
        }
    }.f;
    // TODO: Use zgl bindings that match the OpenGL version that we use
    try zgl.loadExtensions({}, getProcAddressWrapper);

    var images = zss.Images{};
    defer images.deinit(allocator);

    var zig_logo = blk: {
        const path = "demo/zig.png";
        var file = try std.fs.cwd().openFile(path, .{});
        defer file.close();
        const image = try zigimg.Image.fromFile(allocator, &file);
        break :blk image;
    };
    defer zig_logo.deinit();
    const zig_logo_image: zss.Images.Image = .{
        .dimensions = .{
            .width_px = @intCast(zig_logo.width),
            .height_px = @intCast(zig_logo.height),
        },
        .format = switch (zig_logo.pixelFormat()) {
            .rgba32 => .rgba,
            else => return error.Unsupported,
        },
        .data = switch (zig_logo.pixelFormat()) {
            .rgba32 => .{ .rgba = zig_logo.rawBytes() },
            else => return error.Unsupported,
        },
    };
    const zig_logo_handle = try images.addImage(allocator, zig_logo_image);
    const images_slice = images.slice();

    var storage = zss.values.Storage{ .allocator = allocator };
    defer storage.deinit();
    _ = try storage.alloc(zss.values.types.BackgroundClip, 1);

    var tree, const root = try createElements(allocator, file_name, file_contents.items, font, zig_logo_handle);
    defer tree.deinit();

    var box_tree = try zss.layout.doLayout(
        tree.slice(),
        root,
        allocator,
        .{
            .viewport = .{ .w = width * zss_units_per_pixel, .h = height * zss_units_per_pixel },
            .images = images_slice,
            .storage = &storage,
        },
    );
    defer box_tree.deinit();

    program_state.changeMainWindowSize(height, box_tree);

    var draw_list = try zss.render.DrawList.create(box_tree, allocator);
    defer draw_list.deinit(allocator);

    var renderer = zss.render.opengl.Renderer.init(allocator);
    defer renderer.deinit();

    try renderer.initGlyphs(font);
    defer renderer.deinitGlyphs();

    while (!window.shouldClose()) {
        zgl.clearColor(0, 0, 0, 0);
        zgl.clear(.{ .color = true });

        const viewport_rect = zss.used_values.ZssRect{
            .x = 0,
            .y = program_state.current_scroll,
            .w = width * zss_units_per_pixel,
            .h = height * zss_units_per_pixel,
        };
        try zss.render.opengl.drawBoxTree(&renderer, images_slice, box_tree, draw_list, allocator, viewport_rect);

        // zgl.clearColor(0, 0, 0, 0);
        // zgl.clear(.{ .color = true });
        // try renderer.showGlyphs(viewport_rect);

        zgl.flush();

        window.swapBuffers();
        glfw.waitEvents();
    }

    return 0;
}

fn readFile(allocator: Allocator, file_name: []const u8) !std.ArrayListUnmanaged(u8) {
    var list = std.ArrayList(u8).init(allocator);
    errdefer list.deinit();

    const file = try std.fs.cwd().openFile(file_name, .{});
    defer file.close();
    try file.reader().readAllArrayList(&list, 1_000_000);

    // Exclude a trailing newline.
    if (list.items.len > 0) {
        switch (list.items[list.items.len - 1]) {
            '\n' => if (list.items.len > 1 and list.items[list.items.len - 2] == '\r') {
                list.items.len -= 2;
            } else {
                list.items.len -= 1;
            },
            '\r' => list.items.len -= 1,
            else => {},
        }
    }

    return list.moveToUnmanaged();
}

fn createElements(
    allocator: Allocator,
    file_name: []const u8,
    file_contents: []const u8,
    font: *hb.hb_font_t,
    footer_image_handle: zss.Images.Handle,
) !struct { zss.ElementTree, zss.ElementTree.Element } {
    var tree = zss.ElementTree.init(allocator);
    errdefer tree.deinit();

    var elements: [9]zss.ElementTree.Element = undefined;
    try tree.allocateElements(&elements);

    const root = elements[0];
    const removed_block = elements[1];
    const title_block = elements[2];
    const title_inline_box = elements[3];
    const title_text = elements[4];
    const body_block = elements[5];
    const body_text = elements[6];
    const footer = elements[7];
    const body_inline_box = elements[8];

    const slice = tree.slice();

    slice.initElement(root, .normal, .orphan, {});
    slice.initElement(removed_block, .normal, .first_child_of, root);
    slice.initElement(title_block, .normal, .last_child_of, root);
    slice.initElement(title_inline_box, .normal, .first_child_of, title_block);
    slice.initElement(title_text, .text, .first_child_of, title_inline_box);
    slice.initElement(body_block, .normal, .last_child_of, root);
    slice.initElement(body_inline_box, .normal, .last_child_of, body_block);
    slice.initElement(body_text, .text, .first_child_of, body_inline_box);
    slice.initElement(footer, .normal, .last_child_of, root);

    {
        const arena = slice.arena;
        var cv: *zss.CascadedValues = undefined;

        const bg_color = 0xefefefff;
        const text_color = 0x101010ff;

        // Root element
        cv = slice.ptr(.cascaded_values, root);
        const root_border = zss.values.types.BorderWidth{ .px = 10 };
        const root_padding = zss.values.types.Padding{ .px = 30 };
        const root_border_color = zss.values.types.Color{ .rgba = 0xaf2233ff };
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
        try cv.add(arena, .background1, .{ .color = .{ .rgba = bg_color } });
        try cv.add(arena, .background2, .{
            .position = .{ .position = .{
                .x = .{ .side = .end, .offset = .{ .percentage = 0 } },
                .y = .{ .side = .start, .offset = .{ .px = 10 } },
            } },
            .repeat = .{ .repeat = .{ .x = .no_repeat, .y = .no_repeat } },
        });
        try cv.add(arena, .color, .{ .color = .{ .rgba = text_color } });
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
        try cv.add(arena, .box_style, .{ .display = .@"inline" });
        try cv.add(arena, .horizontal_edges, .{
            .padding_left = .{ .px = 10 },
            .padding_right = .{ .px = 10 },
            .border_left = .{ .px = 10 },
            .border_right = .{ .px = 10 },
        });
        try cv.add(arena, .vertical_edges, .{
            .padding_bottom = .{ .px = 5 },
            .border_top = .{ .px = 10 },
            .border_bottom = .{ .px = 10 },
        });
        try cv.add(arena, .background1, .{ .color = .{ .rgba = 0xfa58007f } });
        try cv.add(arena, .border_styles, .{ .top = .solid, .right = .solid, .bottom = .solid, .left = .solid });
        try cv.add(arena, .border_colors, .{
            .top = .{ .rgba = 0xaa1010ff },
            .right = .{ .rgba = 0x10aa10ff },
            .bottom = .{ .rgba = 0x504090ff },
            .left = .{ .rgba = 0x1010aaff },
        });

        // Title text
        cv = slice.ptr(.cascaded_values, title_text);
        try cv.add(arena, .box_style, .{ .display = .text });
        slice.set(.text, title_text, file_name);

        // Body block box
        cv = slice.ptr(.cascaded_values, body_block);
        try cv.add(arena, .box_style, .{ .display = .block, .position = .relative });

        // Body inline box
        cv = slice.ptr(.cascaded_values, body_inline_box);
        try cv.add(arena, .box_style, .{ .display = .@"inline" });
        try cv.add(arena, .background1, .{ .color = .{ .rgba = 0x1010507f } });

        // Body text
        cv = slice.ptr(.cascaded_values, body_text);
        try cv.add(arena, .box_style, .{ .display = .text });
        slice.set(.text, body_text, file_contents);

        // Footer block
        cv = slice.ptr(.cascaded_values, footer);
        try cv.add(arena, .box_style, .{ .display = .block });
        // try cv.add(arena, .content_width, .{ .width = .{ .px = 50 } });
        try cv.add(arena, .content_height, .{ .height = .{ .px = 200 } });
        try cv.add(arena, .horizontal_edges, .{ .border_left = .inherit, .border_right = .inherit });
        try cv.add(arena, .vertical_edges, .{ .margin_top = .{ .px = 10 }, .border_top = .inherit, .border_bottom = .inherit });
        try cv.add(arena, .border_colors, .{ .top = .inherit, .right = .inherit, .bottom = .inherit, .left = .inherit });
        try cv.add(arena, .border_styles, .{ .top = .inherit, .right = .inherit, .bottom = .inherit, .left = .inherit });
        try cv.add(arena, .background1, .{ .clip = .padding_box });
        try cv.add(arena, .background2, .{
            .image = .{ .image = footer_image_handle },
            .position = .{ .position = .{
                .x = .{ .side = .start, .offset = .{ .percentage = 0.5 } },
                .y = .{ .side = .start, .offset = .{ .percentage = 0.5 } },
            } },
            .repeat = .{ .repeat = .{ .x = .space, .y = .no_repeat } },
            .size = .contain,
        });
    }

    return .{ tree, root };
}

fn keyCallback(window: glfw.Window, key: glfw.Key, scancode: i32, action: glfw.Action, mods: glfw.Mods) void {
    _ = scancode;
    _ = mods;

    const program_state = window.getUserPointer(ProgramState) orelse return;
    if (program_state.main_window.handle != window.handle) return;

    switch (action) {
        .press, .repeat => {},
        .release => return,
    }

    switch (key) {
        .down => program_state.scroll(.down),
        .up => program_state.scroll(.up),
        .page_down => program_state.scroll(.page_down),
        .page_up => program_state.scroll(.page_up),
        else => {},
    }
}
