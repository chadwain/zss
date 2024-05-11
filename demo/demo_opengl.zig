const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const zss = @import("zss");
const hb = @import("mach-harfbuzz").c;
const zgl = @import("zgl");
const glfw = @import("mach-glfw");

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

    var env = zss.Environment.init(allocator);
    defer env.deinit();
    const checkerboard_image_handle = try env.addImage(checkerboard_image);

    var tree, const root = try createElements(allocator, file_name, file_contents.items, font, checkerboard_image_handle);
    defer tree.deinit();

    var box_tree = try zss.layout.doLayout(tree.slice(), root, &env, allocator, .{ .width = width, .height = height });
    defer box_tree.deinit();

    var draw_list = try zss.render.DrawOrderList.create(box_tree, allocator);
    defer draw_list.deinit(allocator);

    var renderer = zss.render.opengl.Renderer.init(allocator);
    defer renderer.deinit();

    while (!window.shouldClose()) {
        zgl.clearColor(0, 0, 0, 0);
        zgl.clear(.{ .color = true });

        const units_per_pixel = zss.used_values.units_per_pixel;
        const viewport_rect = zss.used_values.ZssRect{ .x = 0, .y = 0, .w = width * units_per_pixel, .h = height * units_per_pixel };
        try zss.render.opengl.drawBoxTree(&renderer, env, box_tree, draw_list, allocator, viewport_rect);

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

const checkerboard_image = zss.Environment.Images.Image{
    .dimensions = .{ .width_px = 128, .height_px = 128 },
    .format = .rgba,
    .data = .{ .rgba = &(([1]u32{std.mem.nativeToBig(u32, 0x101010ff)} ** 32) ++ ([1]u32{std.mem.nativeToBig(u32, 0xddddddff)} ** 32)) ** (2 * 128) },
};

fn createElements(
    allocator: Allocator,
    file_name: []const u8,
    file_contents: []const u8,
    font: *hb.hb_font_t,
    checkerboard_image_handle: zss.Environment.Images.Handle,
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
        var cv: *zss.ElementTree.CascadedValues = undefined;

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
        try cv.add(arena, .box_style, .{ .display = .inline_ });
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
        try cv.add(arena, .box_style, .{ .display = .inline_ });
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
        try cv.add(arena, .background2, .{
            .image = .{ .object = checkerboard_image_handle },
            .position = .{ .position = .{
                .x = .{ .side = .start, .offset = .{ .percentage = 0.5 } },
                .y = .{ .side = .start, .offset = .{ .percentage = 0.5 } },
            } },
            .repeat = .{ .repeat = .{ .x = .no_repeat, .y = .no_repeat } },
            .size = .contain,
        });
    }

    return .{ tree, root };
}
