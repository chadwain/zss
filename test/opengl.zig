const zss = @import("zss");
const BoxTree = zss.used_values.BoxTree;
const DrawList = zss.render.DrawList;
const units_per_pixel = zss.used_values.units_per_pixel;

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const Test = @import("./testing.zig").Test;

const glfw = @import("mach-glfw");
const hb = @import("mach-harfbuzz").c;
const zgl = @import("zgl");
const zigimg = @import("zigimg");

pub fn run(tests: []const Test) !void {
    if (!glfw.init(.{})) return error.GlfwError;
    defer glfw.terminate();

    const window = glfw.Window.create(1, 1, "zss opengl render tests", null, null, .{
        .context_version_major = 3,
        .context_version_minor = 3,
        .opengl_profile = .opengl_core_profile,
        .visible = false,
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
    try zgl.loadExtensions({}, getProcAddressWrapper);

    const results_path = "test/output/opengl";
    try std.fs.cwd().makePath(results_path);

    const stdout = std.io.getStdOut().writer();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    var images = zss.Images{};
    defer images.deinit(allocator);
    const images_slice = images.slice();

    var storage = zss.values.Storage{ .allocator = allocator };
    defer storage.deinit();

    var renderer = zss.render.opengl.Renderer.init(allocator);
    defer renderer.deinit();

    for (tests, 0..) |t, ti| {
        try stdout.print("opengl: ({}/{}) \"{s}\" ... ", .{ ti + 1, tests.len, t.name });
        defer stdout.writeAll("\n") catch {};

        var box_tree = try zss.layout.doLayout(t.slice, t.root, allocator, t.width, t.height, images_slice, &storage);
        defer box_tree.deinit();

        const init_glyphs = t.hb_font != null and t.hb_font.? != hb.hb_font_get_empty();
        if (init_glyphs) try renderer.initGlyphs(t.hb_font.?);
        defer if (init_glyphs) renderer.deinitGlyphs();

        var draw_list = try DrawList.create(box_tree, allocator);
        defer draw_list.deinit(allocator);

        setIcbBackgroundColor(&box_tree, zss.used_values.Color.fromRgbaInt(0x202020ff));
        const root_block_size = rootBlockSize(&box_tree, t.root);

        const pages = zss.util.divCeil(root_block_size.height, t.height);
        var image = try zigimg.Image.create(allocator, root_block_size.width, pages * t.height, .rgba32);
        defer image.deinit();
        const image_pixels = image.pixels.asBytes();

        const temp_buffer = try allocator.alloc(u8, image_pixels.len);
        defer allocator.free(temp_buffer);

        const file_name = try std.fmt.allocPrint(allocator, results_path ++ "/{s}.png", .{t.name});
        defer allocator.free(file_name);

        window.setSize(.{ .width = t.width, .height = t.height });
        zgl.viewport(0, 0, t.width, t.height);
        for (0..pages) |i| {
            zgl.clearColor(0, 0, 0, 0);
            zgl.clear(.{ .color = true });

            const viewport = zss.used_values.ZssRect{
                .x = @intCast(root_block_size.x * units_per_pixel),
                .y = @intCast((i * t.height + root_block_size.y) * units_per_pixel),
                .w = @intCast(t.width * units_per_pixel),
                .h = @intCast(t.height * units_per_pixel),
            };
            try zss.render.opengl.drawBoxTree(&renderer, images_slice, box_tree, draw_list, allocator, viewport);
            zgl.flush();

            const y: u32 = @intCast(i * t.height);
            const w = root_block_size.width;
            const h: u32 = t.height;
            zgl.readPixels(0, 0, w, h, .rgba, .unsigned_byte, temp_buffer[((pages - 1) * t.height - y) * w * 4 ..][0 .. w * h * 4].ptr);
        }

        // Flip everything vertically
        for (0..(pages * t.height)) |y| {
            const inverted_y = pages * t.height - 1 - y;
            @memcpy(
                image_pixels[inverted_y * root_block_size.width * 4 ..][0 .. root_block_size.width * 4],
                temp_buffer[y * root_block_size.width * 4 ..][0 .. root_block_size.width * 4],
            );
        }

        if (image_pixels.len == 0) {
            try stdout.writeAll("success, no file written");
        } else {
            try image.writeToFilePath(file_name, .{ .png = .{} });
            try stdout.writeAll("success");
        }
    }
}

fn rootBlockSize(box_tree: *BoxTree, root_element: zss.ElementTree.Element) struct { x: u32, y: u32, width: u32, height: u32 } {
    if (root_element.eqlNull()) return .{ .x = 0, .y = 0, .width = 0, .height = 0 };
    const generated_box = box_tree.element_to_generated_box.get(root_element) orelse return .{ .x = 0, .y = 0, .width = 0, .height = 0 };
    switch (generated_box) {
        .block_box => |block_box| {
            const subtree_slice = box_tree.blocks.subtree(block_box.subtree).slice();
            const box_offsets = subtree_slice.items(.box_offsets)[block_box.index];
            return .{
                .x = @intCast(@divFloor(box_offsets.border_pos.x, units_per_pixel)),
                .y = @intCast(@divFloor(box_offsets.border_pos.y, units_per_pixel)),
                .width = @intCast(@divFloor(box_offsets.border_size.w, units_per_pixel)),
                .height = @intCast(@divFloor(box_offsets.border_size.h, units_per_pixel)),
            };
        },
        .text, .inline_box => unreachable,
    }
}

fn setIcbBackgroundColor(box_tree: *BoxTree, color: zss.used_values.Color) void {
    const icb = box_tree.blocks.initial_containing_block;
    const subtree_slice = box_tree.blocks.subtree(icb.subtree).slice();
    const background = &subtree_slice.items(.background)[icb.index];
    background.color = color;
}
