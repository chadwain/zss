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
            .{ .width = @intCast(result.width), .height = @intCast(result.height) },
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
            .{ .width = @intCast(self.width), .height = @intCast(self.height) },
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
        self.max_scroll_y = @max(0, zss.render.sdl.zssUnitToPixel(root_box_offsets.border_pos.y + root_box_offsets.border_size.h) - self.height);
        self.scroll_y = std.math.clamp(self.scroll_y, 0, self.max_scroll_y);
    }
};

pub fn sdlMainLoop(
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
            switch (event.type) {
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
            .y = ps.scroll_y,
            .w = ps.width,
            .h = ps.height,
        };
        assert(sdl.SDL_SetRenderDrawColor(renderer, 0, 0, 0, 255) == 0);
        assert(sdl.SDL_RenderClear(renderer) == 0);
        try zss.render.sdl.drawBoxTree(ps.box_tree, ps.draw_order_list, allocator, renderer, pixel_format, &ps.atlas, viewport_rect);
        if (ps.draw_grid) drawGrid(@as(u16, 1) << ps.grid_size_log_2, renderer, viewport_rect);
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

fn drawGrid(grid_size: u16, renderer: *sdl.SDL_Renderer, viewport_rect: sdl.SDL_Rect) void {
    assert(sdl.SDL_SetRenderDrawColor(renderer, 0, 0, 0, 255) == 0);
    {
        var num_lines = @divFloor(viewport_rect.w + grid_size, grid_size);
        while (num_lines > 0) : (num_lines -= 1) {
            const x_pos = @mod(-viewport_rect.x, grid_size) + (num_lines - 1) * grid_size;
            assert(sdl.SDL_RenderDrawLine(renderer, x_pos, 0, x_pos, viewport_rect.h) == 0);
        }
    }
    {
        var num_lines = @divFloor(viewport_rect.h + grid_size, grid_size);
        while (num_lines > 0) : (num_lines -= 1) {
            const y_pos = @mod(-viewport_rect.y, grid_size) + (num_lines - 1) * grid_size;
            assert(sdl.SDL_RenderDrawLine(renderer, 0, y_pos, viewport_rect.w, y_pos) == 0);
        }
    }
}

fn printObjectsOnScreen(ps: ProgramState, stderr: std.fs.File.Writer, allocator: Allocator) !void {
    const objects = try ps.draw_order_list.quad_tree.findObjectsInRect(.{
        .x = pixelToZssUnit(0),
        .y = pixelToZssUnit(ps.scroll_y),
        .w = pixelToZssUnit(ps.width),
        .h = pixelToZssUnit(ps.height),
    }, allocator);
    defer allocator.free(objects);

    var objects_in_order = std.MultiArrayList(struct { draw_index: DrawOrderList.DrawIndex, object: QuadTree.Object }){};
    defer objects_in_order.deinit(allocator);
    for (objects) |object| try objects_in_order.append(allocator, .{
        .draw_index = ps.draw_order_list.getDrawIndex(object),
        .object = object,
    });
    const slice = objects_in_order.slice();

    const SortContext = struct {
        draw_index: []DrawOrderList.DrawIndex,

        pub fn lessThan(ctx: @This(), a_index: usize, b_index: usize) bool {
            return ctx.draw_index[a_index] < ctx.draw_index[b_index];
        }
    };
    objects_in_order.sort(SortContext{ .draw_index = slice.items(.draw_index) });

    try stderr.writeAll("\nObjects on screen:\n");
    var i: usize = 0;
    while (i < slice.len) : (i += 1) {
        const draw_index = slice.items(.draw_index)[i];
        const object = slice.items(.object)[i];
        const drawable = ps.draw_order_list.getEntry(object);
        try stderr.print("\t{} {}\n", .{ draw_index, drawable });
    }
    try stderr.writeAll("\n");
}
