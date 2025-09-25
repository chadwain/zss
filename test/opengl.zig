const zss = @import("zss");
const BoxTree = zss.BoxTree;
const DrawList = zss.render.DrawList;
const units_per_pixel = zss.math.units_per_pixel;

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const Test = @import("Test.zig");

const glfw = @import("mach-glfw");
const hb = @import("harfbuzz").c;
const zgl = @import("zgl");
const zigimg = @import("zigimg");

pub fn run(tests: []const *Test, output_parent_dir: []const u8) !void {
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

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    var output_dir = blk: {
        const path = try std.fs.path.join(allocator, &.{ output_parent_dir, "opengl" });
        defer allocator.free(path);
        break :blk try std.fs.cwd().makeOpenPath(path, .{});
    };
    defer output_dir.close();

    var stdout_buffer: [200]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writerStreaming(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    var renderer = zss.render.opengl.Renderer.init(allocator);
    defer renderer.deinit();

    for (tests, 0..) |t, ti| {
        try stdout.print("opengl: ({}/{}) \"{s}\" ... ", .{ ti + 1, tests.len, t.name });
        try stdout.flush();

        var layout = zss.Layout.init(&t.env, allocator, t.width, t.height, t.images, t.fonts);
        defer layout.deinit();

        var box_tree = try layout.run(allocator);
        defer box_tree.deinit();

        const font_opt = t.fonts.get(t.font_handle);
        if (font_opt) |font| try renderer.initGlyphs(font);
        defer if (font_opt) |_| renderer.deinitGlyphs();

        var draw_list = try DrawList.create(&box_tree, allocator);
        defer draw_list.deinit(allocator);

        setIcbBackgroundColor(&box_tree, zss.math.Color.fromRgbaInt(0x202020ff));
        const root_block_size = rootBlockSize(&box_tree, t.env.root_node);

        const pages = try std.math.divCeil(u32, root_block_size.height, t.height);
        var image = try zigimg.Image.create(allocator, root_block_size.width, pages * t.height, .rgba32);
        defer image.deinit(allocator);
        const image_pixels = image.pixels.asBytes();

        const temp_buffer = try allocator.alloc(u8, image_pixels.len);
        defer allocator.free(temp_buffer);

        window.setSize(.{ .width = t.width, .height = t.height });
        zgl.viewport(0, 0, t.width, t.height);
        for (0..pages) |i| {
            zgl.clearColor(0, 0, 0, 0);
            zgl.clear(.{ .color = true });

            const viewport = zss.math.Rect{
                .x = @intCast(root_block_size.x * units_per_pixel),
                .y = @intCast((i * t.height + root_block_size.y) * units_per_pixel),
                .w = @intCast(t.width * units_per_pixel),
                .h = @intCast(t.height * units_per_pixel),
            };
            try zss.render.opengl.drawBoxTree(&renderer, t.images, &box_tree, &draw_list, allocator, viewport);
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
            // TODO: Delete the output file if it already exists
            try stdout.writeAll("success, no file written\n");
        } else {
            const image_path = try std.mem.concat(allocator, u8, &.{ t.name, ".png" });
            defer allocator.free(image_path);
            if (std.fs.path.dirname(image_path)) |parent_dir| {
                try output_dir.makePath(parent_dir);
            }
            const image_file = try output_dir.createFile(image_path, .{});
            defer image_file.close();
            var write_buffer: [4096]u8 = undefined;
            try image.writeToFile(allocator, image_file, &write_buffer, .{ .png = .{} });

            try stdout.writeAll("success\n");
        }

        try stdout.flush();
    }

    try stdout.print("opengl: all {} tests passed\n", .{tests.len});
    try stdout.flush();
}

fn rootBlockSize(box_tree: *BoxTree, root_element_or_null: ?zss.Environment.NodeId) struct { x: u32, y: u32, width: u32, height: u32 } {
    const root_element = root_element_or_null orelse return .{ .x = 0, .y = 0, .width = 0, .height = 0 };
    const generated_box = box_tree.node_to_generated_box.get(root_element) orelse return .{ .x = 0, .y = 0, .width = 0, .height = 0 };
    const ref = switch (generated_box) {
        .block_ref => |ref| ref,
        .text => |ifc_id| box_tree.getIfc(ifc_id).parent_block,
        .inline_box => unreachable,
    };
    const subtree = box_tree.getSubtree(ref.subtree).view();
    const box_offsets = subtree.items(.box_offsets)[ref.index];
    return .{
        .x = @intCast(@divFloor(box_offsets.border_pos.x, units_per_pixel)),
        .y = @intCast(@divFloor(box_offsets.border_pos.y, units_per_pixel)),
        .width = @intCast(@divFloor(box_offsets.border_size.w, units_per_pixel)),
        .height = @intCast(@divFloor(box_offsets.border_size.h, units_per_pixel)),
    };
}

fn setIcbBackgroundColor(box_tree: *BoxTree, color: zss.math.Color) void {
    // TODO: This wouldn't be necessary if [background propagation](https://www.w3.org/TR/css-backgrounds-3/#special-backgrounds) was implemented.
    const icb = box_tree.initial_containing_block;
    const subtree = box_tree.getSubtree(icb.subtree).view();
    const background = &subtree.items(.background)[icb.index];
    background.color = color;
}
