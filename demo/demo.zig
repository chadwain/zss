//! This demo program uses zss to display the contents of a file in a window.
//! To run it, run `zig build demo -- my-file.txt`, or `zig-out/bin/demo my-file.txt`.
//! You can use the up/down arrow keys and the page up/page down keys to scroll.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const zss = @import("zss");
const hb = @import("harfbuzz").c;
const zgl = @import("zgl");
const zigimg = @import("zigimg");
const glfw = @import("mach-glfw");

const ZssUnit = zss.math.Unit;
const zss_units_per_pixel = zss.math.units_per_pixel;

const ProgramState = struct {
    main_window: glfw.Window,
    main_window_width: u32,
    main_window_height: u32,

    resize_timer: *std.time.Timer,
    next_resize: ?struct { width: u32, height: u32 } = null,

    current_scroll: ZssUnit = 0,
    max_scroll: ZssUnit,

    allocator: Allocator,
    env: *zss.Environment,
    images: *const zss.Images,
    fonts: *const zss.Fonts,

    box_tree: *zss.BoxTree,
    draw_list: *zss.render.DrawList,

    fn resize(self: *ProgramState) !void {
        if (self.resize_timer.read() < std.time.ns_per_ms * 250) return;
        self.resize_timer.reset();
        if (self.next_resize) |size| {
            zgl.viewport(0, 0, size.width, size.height);
            try self.changeMainWindowSize(size.width, size.height);
            self.next_resize = null;
        }
    }

    fn changeMainWindowSize(self: *ProgramState, width: u32, height: u32) !void {
        self.main_window_width = width;
        self.main_window_height = height;
        try self.relayout();

        const box = box: {
            if (self.env.root_node) |root_node| {
                if (self.box_tree.node_to_generated_box.get(root_node)) |generated_box| {
                    switch (generated_box) {
                        .block_ref => |ref| break :box ref,
                        .inline_box, .text => unreachable,
                    }
                }
            }
            break :box self.box_tree.initial_containing_block;
        };
        const max_height = blk: {
            const subtree = self.box_tree.getSubtree(box.subtree);
            const box_offsets = subtree.view().items(.box_offsets)[box.index];
            break :blk box_offsets.border_size.h;
        };
        self.max_scroll = @max(0, max_height - @as(ZssUnit, @intCast(self.main_window_height * zss_units_per_pixel)));
        self.scroll(.nowhere);
    }

    fn scroll(self: *ProgramState, comptime direction: enum { nowhere, up, down, page_up, page_down }) void {
        const scroll_amount = 20 * zss_units_per_pixel;
        switch (direction) {
            .nowhere => {},
            .up => self.current_scroll -= scroll_amount,
            .down => self.current_scroll += scroll_amount,
            .page_up => self.current_scroll -= @intCast(self.main_window_height * zss_units_per_pixel),
            .page_down => self.current_scroll += @intCast(self.main_window_height * zss_units_per_pixel),
        }
        self.current_scroll = std.math.clamp(self.current_scroll, 0, self.max_scroll);
    }

    fn relayout(self: *ProgramState) !void {
        var layout = zss.Layout.init(
            self.env,
            self.allocator,
            self.main_window_width,
            self.main_window_height,
            self.images,
            self.fonts,
        );
        defer layout.deinit();

        var box_tree = try layout.run(self.allocator);
        defer box_tree.deinit();

        var draw_list = try zss.render.DrawList.create(&box_tree, self.allocator);
        defer draw_list.deinit(self.allocator);

        std.mem.swap(zss.BoxTree, self.box_tree, &box_tree);
        std.mem.swap(zss.render.DrawList, self.draw_list, &draw_list);
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    const args = try Args.init(allocator);
    defer args.deinit(allocator);

    const file_path = args.filePath();
    const file_contents = try readFile(allocator, file_path);
    defer switch (file_contents) {
        .text => |text| allocator.free(text),
        .open_error => {},
    };

    // Setup GLFW

    if (!glfw.init(.{})) return glfwError();
    defer glfw.terminate();

    const initial_width = 800;
    const initial_height = 600;
    const window = glfw.Window.create(initial_width, initial_height, "zss demo", null, null, .{
        .context_version_major = 3,
        .context_version_minor = 3,
        .opengl_profile = .opengl_core_profile,
    }) orelse return glfwError();
    defer window.destroy();

    glfw.makeContextCurrent(window);
    defer glfw.makeContextCurrent(null);

    glfw.swapInterval(1);

    const ns = struct {
        fn getProcAddressWrapper(_: void, symbol_name: [:0]const u8) ?*const anyopaque {
            return glfw.getProcAddress(symbol_name);
        }
    };
    try zgl.loadExtensions({}, ns.getProcAddressWrapper);

    // Setup FreeType

    var library: hb.FT_Library = undefined;
    try checkFtError(hb.FT_Init_FreeType(&library));
    defer _ = hb.FT_Done_FreeType(library);

    const font_file = @embedFile("NotoSans-Regular.ttf");
    var face: hb.FT_Face = undefined;
    try checkFtError(hb.FT_New_Memory_Face(library, font_file.ptr, font_file.len, 0, &face));
    defer _ = hb.FT_Done_Face(face);

    const font_size = 12;
    const dpi: struct { x: c_uint, y: c_uint } = blk: {
        const content_scale = window.getContentScale();
        break :blk .{ .x = @intFromFloat(content_scale.x_scale * 96), .y = @intFromFloat(content_scale.y_scale * 96) };
    };
    try checkFtError(hb.FT_Set_Char_Size(face, 0, font_size * 64, dpi.x, dpi.y));

    const font = hb.hb_ft_font_create_referenced(face) orelse {
        std.debug.print("Error: Can't create FT_Face from hb_font_t\n", .{});
        return error.HarfbuzzError;
    };
    defer hb.hb_font_destroy(font);
    hb.hb_ft_font_set_funcs(font);

    // Setup zss

    var env = zss.Environment.init(allocator);
    defer env.deinit();

    var images = zss.Images.init();
    defer images.deinit(allocator);

    var fonts = zss.Fonts.init();
    defer fonts.deinit();
    _ = fonts.setFont(font);

    // Load the document.
    const zml_document_token_source = try zss.syntax.TokenSource.init(@embedFile("demo.zml"));
    var zml_document = try zss.zml.createDocumentFromTokenSource(allocator, zml_document_token_source, &env);
    defer zml_document.deinit(allocator);
    zml_document.setEnvTreeInterface(&env);

    // Replace the text of the title and body nodes with the file name and file contents.
    if (zml_document.named_nodes.get("title")) |title_text| {
        const title_text_zss_node = title_text.toZssNode(&zml_document);
        try env.setNodeProperty(.category, title_text_zss_node, .text);
        try env.setNodeProperty(.text, title_text_zss_node, try env.addTextFromString(file_path));
    }
    if (zml_document.named_nodes.get("body")) |body_text| {
        const body_text_zss_node = body_text.toZssNode(&zml_document);
        const text_id = switch (file_contents) {
            .text => |text| try env.addTextFromString(text),
            .open_error => |err| blk: {
                const string = try std.fmt.allocPrint(allocator, "(Unable to open file: {s})\n", .{@errorName(err)});
                defer allocator.free(string);
                break :blk try env.addTextFromString(string);
            },
        };
        try env.setNodeProperty(.category, body_text_zss_node, .text);
        try env.setNodeProperty(.text, body_text_zss_node, text_id);
    }

    // Load the stylesheet.
    const stylesheet_token_source = try zss.syntax.TokenSource.init(@embedFile("demo.css"));
    var stylesheet = try zss.Stylesheet.createFromTokenSource(allocator, stylesheet_token_source, &env);
    defer stylesheet.deinit(allocator);

    // Load the Zig logo image.
    var zig_logo_data, const zig_logo_image = try loadImage(@embedFile("zig.png"), allocator);
    defer zig_logo_data.deinit();
    const zig_logo_handle = try images.addImage(allocator, zig_logo_image);
    const resources = Resources{ .zig_logo = zig_logo_handle };

    // Resolve URLs in both the document and the stylesheet.
    for (0..zml_document.urls.len) |index| {
        const url = zml_document.urls.get(index);
        try linkResource(resources, allocator, &env, url.id, url.type, url.src_loc, zml_document_token_source);
    }
    var stylesheet_urls_it = stylesheet.decl_urls.iterator();
    while (stylesheet_urls_it.next()) |url| {
        try linkResource(resources, allocator, &env, url.id, url.desc.type, url.desc.src_loc, stylesheet_token_source);
    }

    // Run the CSS cascade.
    // This gives style information to every node in the document tree.
    const zml_document_cascade_node = zss.cascade.Node{ .leaf = &zml_document.cascade_source };
    const stylesheet_cascade_node = zss.cascade.Node{ .leaf = &stylesheet.cascade_source };
    try env.cascade_list.author.appendSlice(env.allocator, &.{ &zml_document_cascade_node, &stylesheet_cascade_node });
    try zss.cascade.run(&env);

    // Perform an "empty" layout, just to initialize the box tree.
    var box_tree = blk: {
        const root_node = env.root_node;
        env.root_node = null;
        defer env.root_node = root_node;

        var layout = zss.Layout.init(&env, allocator, 0, 0, &images, &fonts);
        defer layout.deinit();
        break :blk try layout.run(allocator);
    };
    defer box_tree.deinit();

    var draw_list = try zss.render.DrawList.create(&box_tree, allocator);
    defer draw_list.deinit(allocator);

    var resize_timer = try std.time.Timer.start();

    var program_state = ProgramState{
        .main_window = window,
        .main_window_width = undefined,
        .main_window_height = undefined,

        .resize_timer = &resize_timer,

        .max_scroll = undefined,

        .allocator = allocator,
        .env = &env,
        .images = &images,
        .fonts = &fonts,

        .box_tree = &box_tree,
        .draw_list = &draw_list,
    };

    window.setUserPointer(&program_state);
    window.setKeyCallback(keyCallback);
    window.setFramebufferSizeCallback(framebufferSizeCallback);
    // TODO: window.setContentScaleCallback

    // This causes layout to be performed again, this time with the correct window width and height.
    try program_state.changeMainWindowSize(initial_width, initial_height);

    var renderer = zss.render.opengl.Renderer.init(allocator);
    defer renderer.deinit();

    try renderer.initGlyphs(font);
    defer renderer.deinitGlyphs();

    while (!window.shouldClose()) {
        try program_state.resize();

        zgl.clearColor(0, 0, 0, 0);
        zgl.clear(.{ .color = true });

        const viewport_rect = zss.math.Rect{
            .x = 0,
            .y = program_state.current_scroll,
            .w = @intCast(program_state.main_window_width * zss_units_per_pixel),
            .h = @intCast(program_state.main_window_height * zss_units_per_pixel),
        };
        try zss.render.opengl.drawBoxTree(
            &renderer,
            program_state.images,
            program_state.box_tree,
            program_state.draw_list,
            allocator,
            viewport_rect,
        );

        // zgl.clearColor(0, 0, 0, 0);
        // zgl.clear(.{ .color = true });
        // try renderer.showGlyphs(viewport_rect);

        zgl.flush();

        window.swapBuffers();
        glfw.waitEventsTimeout(0.25);
    }
}

const Args = struct {
    strings: [][:0]u8,

    fn init(allocator: Allocator) !Args {
        const strings = try std.process.argsAlloc(allocator);
        errdefer std.process.argsFree(allocator, strings);
        if (strings.len != 2) {
            std.debug.print(
                \\Error: invalid program arguments
                \\Usage: demo <file-path>
                \\
            , .{});
            return error.InvalidProgramArguments;
        }
        return .{ .strings = strings };
    }

    fn deinit(args: Args, allocator: Allocator) void {
        std.process.argsFree(allocator, args.strings);
    }

    fn filePath(args: Args) [:0]const u8 {
        return args.strings[1];
    }
};

fn checkFtError(err: hb.FT_Error) error{FreeTypeError}!void {
    if (err != hb.FT_Err_Ok) return error.FreeTypeError;
}

fn glfwError() error{GlfwError} {
    if (glfw.getError()) |glfw_error| {
        std.debug.print("GLFWError({s}): {?s}\n", .{ @errorName(glfw_error.error_code), glfw_error.description });
    }
    return error.GlfwError;
}

fn readFile(allocator: Allocator, file_path: []const u8) !union(enum) {
    text: []const u8,
    open_error: std.fs.File.OpenError,
} {
    var list = std.ArrayList(u8).init(allocator);
    errdefer list.deinit();

    const file = std.fs.cwd().openFile(file_path, .{}) catch |err| return .{ .open_error = err };
    defer file.close();
    try file.reader().readAllArrayList(&list, 1024 * 1024);

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

    return .{ .text = try list.toOwnedSlice() };
}

fn loadImage(bytes: []const u8, allocator: Allocator) !struct { zigimg.Image, zss.Images.Description } {
    var zigimg_image = try zigimg.Image.fromMemory(allocator, bytes);
    errdefer zigimg_image.deinit();

    const zss_image: zss.Images.Description = .{
        .dimensions = .{
            .width_px = @intCast(zigimg_image.width),
            .height_px = @intCast(zigimg_image.height),
        },
        .format = switch (zigimg_image.pixelFormat()) {
            .rgba32 => .rgba,
            else => return error.UnsupportedPixelFormat,
        },
        .data = zigimg_image.rawBytes(),
    };

    return .{ zigimg_image, zss_image };
}

const Resources = struct {
    zig_logo: zss.Images.Handle,
};

fn linkResource(
    resources: Resources,
    allocator: Allocator,
    env: *zss.Environment,
    id: zss.Environment.UrlId,
    @"type": zss.values.parse.Urls.Type,
    src_loc: zss.values.parse.Urls.SourceLocation,
    token_source: zss.syntax.TokenSource,
) !void {
    const url_string = switch (src_loc) {
        .url_token => |location| try token_source.copyUrl(location, allocator),
        .string_token => |location| try token_source.copyString(location, allocator),
    };
    defer allocator.free(url_string);
    switch (@"type") {
        .background_image => {
            if (std.mem.eql(u8, url_string, "zig.png")) {
                try env.linkUrlToImage(id, resources.zig_logo);
            }
        },
    }
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

fn framebufferSizeCallback(window: glfw.Window, width: u32, height: u32) void {
    const program_state = window.getUserPointer(ProgramState) orelse return;
    if (program_state.main_window.handle != window.handle) return;

    program_state.next_resize = .{ .width = width, .height = height };
}
