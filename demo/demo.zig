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
    element_tree: zss.ElementTree.Slice,
    root_element: zss.ElementTree.Element,
    images: zss.Images.Slice,
    fonts: *const zss.Fonts,
    decls: *const zss.property.Declarations,

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

        const box = if (self.box_tree.element_to_generated_box.get(self.root_element)) |generated_box|
            switch (generated_box) {
                .block_ref => |ref| ref,
                .inline_box, .text => unreachable,
            }
        else
            self.box_tree.initial_containing_block;
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
            self.element_tree,
            self.root_element,
            self.allocator,
            self.main_window_width,
            self.main_window_height,
            self.images,
            self.fonts,
            self.decls,
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

pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    const args = try Args.init(allocator);
    defer args.deinit(allocator);

    const file_path = args.filePath();
    var file_contents = try readFile(allocator, file_path);
    defer file_contents.deinit(allocator);

    var library: hb.FT_Library = undefined;
    _ = hb.FT_Init_FreeType(&library);
    defer _ = hb.FT_Done_FreeType(library);

    // TODO: Find a better way to find these files.
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

    const initial_width = 800;
    const initial_height = 600;
    const window = glfw.Window.create(initial_width, initial_height, "zss demo", null, null, .{
        .context_version_major = 3,
        .context_version_minor = 3,
        .opengl_profile = .opengl_core_profile,
    }) orelse return error.GlfwError;
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

    var decls = zss.property.Declarations{};
    defer decls.deinit(allocator);

    var images = zss.Images{};
    defer images.deinit(allocator);

    var fonts = zss.Fonts.init();
    defer fonts.deinit();
    _ = fonts.setFont(font);

    // TODO: Find a better way to find these files.
    var zig_logo_data, const zig_logo_image = try loadImage("demo/zig.png", allocator);
    defer zig_logo_data.deinit();
    const zig_logo_handle = try images.addImage(allocator, zig_logo_image);

    var tree = zss.ElementTree.init(allocator);
    defer tree.deinit();

    const root_element = try createElements(allocator, &tree, &decls, file_path, file_contents.items, zig_logo_handle);

    var box_tree = blk: {
        var layout = zss.Layout.init(tree.slice(), .null_element, allocator, 0, 0, images.slice(), &fonts, &decls);
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
        .element_tree = tree.slice(),
        .root_element = root_element,
        .images = images.slice(),
        .fonts = &fonts,
        .decls = &decls,

        .box_tree = &box_tree,
        .draw_list = &draw_list,
    };

    window.setUserPointer(&program_state);
    window.setKeyCallback(keyCallback);
    window.setFramebufferSizeCallback(framebufferSizeCallback);
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

    return 0;
}

const Args = struct {
    strings: [][:0]u8,

    fn init(allocator: Allocator) !Args {
        const strings = try std.process.argsAlloc(allocator);
        if (strings.len != 2) {
            try std.io.getStdErr().writeAll(
                \\Error: invalid program arguments
                \\Usage: demo <file-path>
                \\
            );
            std.process.exit(1);
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

fn readFile(allocator: Allocator, file_path: []const u8) !std.ArrayListUnmanaged(u8) {
    var list = std.ArrayList(u8).init(allocator);
    errdefer list.deinit();

    const file = try std.fs.cwd().openFile(file_path, .{});
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

fn loadImage(path: []const u8, allocator: Allocator) !struct { zigimg.Image, zss.Images.Image } {
    var zigimg_image = blk: {
        var file = try std.fs.cwd().openFile(path, .{});
        defer file.close();
        const image = try zigimg.Image.fromFile(allocator, &file);
        break :blk image;
    };
    errdefer zigimg_image.deinit();

    var zss_image: zss.Images.Image = .{
        .dimensions = .{
            .width_px = @intCast(zigimg_image.width),
            .height_px = @intCast(zigimg_image.height),
        },
        .format = undefined,
        .data = undefined,
    };
    zss_image.format, zss_image.data = switch (zigimg_image.pixelFormat()) {
        .rgba32 => .{ .rgba, .{ .rgba = zigimg_image.rawBytes() } },
        else => return error.UnsupportedPixelFormat,
    };

    return .{ zigimg_image, zss_image };
}

const Elements = enum {
    root,
    removed_block,
    title_block,
    title_inline_box,
    title_text,
    body_block,
    body_inline_box,
    body_text,
    footer,
};

/// Returns the root element.
fn createElements(
    allocator: Allocator,
    tree: *zss.ElementTree,
    decls: *zss.property.Declarations,
    file_name: []const u8,
    file_contents: []const u8,
    footer_image_handle: zss.Images.Handle,
) !zss.ElementTree.Element {
    const element_enum_values = comptime std.enums.values(Elements);
    const tree_elements = blk: {
        var tree_elements: [element_enum_values.len]zss.ElementTree.Element = undefined;
        try tree.allocateElements(&tree_elements);
        var array: std.EnumArray(Elements, zss.ElementTree.Element) = .initUndefined();
        for (element_enum_values, 0..) |value, index| array.set(value, tree_elements[index]);
        break :blk array;
    };

    const slice = tree.slice();

    // zig fmt: off
    slice.initElement(tree_elements.get(.root),             .normal, .orphan);
    slice.initElement(tree_elements.get(.removed_block),    .normal, .{ .first_child_of = tree_elements.get(.root) });
    slice.initElement(tree_elements.get(.title_block),      .normal, .{ .last_child_of  = tree_elements.get(.root) });
    slice.initElement(tree_elements.get(.title_inline_box), .normal, .{ .first_child_of = tree_elements.get(.title_block) });
    slice.initElement(tree_elements.get(.title_text),       .text,   .{ .first_child_of = tree_elements.get(.title_inline_box) });
    slice.initElement(tree_elements.get(.body_block),       .normal, .{ .last_child_of  = tree_elements.get(.root) });
    slice.initElement(tree_elements.get(.body_inline_box),  .normal, .{ .last_child_of  = tree_elements.get(.body_block) });
    slice.initElement(tree_elements.get(.body_text),        .text,   .{ .first_child_of = tree_elements.get(.body_inline_box) });
    slice.initElement(tree_elements.get(.footer),           .normal, .{ .last_child_of  = tree_elements.get(.root) });
    // zig fmt: on

    slice.set(.text, tree_elements.get(.title_text), file_name);
    slice.set(.text, tree_elements.get(.body_text), file_contents);

    const element_style_decls = try getElementStyleDecls(decls, allocator, footer_image_handle);
    for (element_enum_values) |value| {
        const block = element_style_decls.get(value) orelse continue;
        try slice.updateCascadedValues(
            tree_elements.get(value),
            decls,
            &.{.{ .block = block, .importance = .normal }},
        );
    }

    return tree_elements.get(.root);
}

const ElementStyleDecls = std.EnumArray(Elements, ?zss.property.Declarations.Block);

fn getElementStyleDecls(
    decls: *zss.property.Declarations,
    allocator: Allocator,
    footer_image_handle: zss.Images.Handle,
) !ElementStyleDecls {
    var result: ElementStyleDecls = .initUndefined();
    result.set(.title_text, null);
    result.set(.body_text, null);

    const bg_color = 0xefefefff;
    const text_color = 0x101010ff;
    const Values = zss.property.Declarations.AllAggregateValues;

    { // Root element
        const root_border = zss.values.types.BorderWidth{ .px = 10 };
        const root_padding = zss.values.types.Padding{ .px = 30 };
        const root_border_color = zss.values.types.Color{ .rgba = 0xaf2233ff };

        result.set(.root, try decls.openBlock(allocator));
        try decls.addValues(allocator, .normal, .{
            .box_style = Values(.box_style){ .display = .{ .declared = .block } },
            .content_width = Values(.content_width){ .min_width = .{ .declared = .{ .px = 200 } } },
            .horizontal_edges = Values(.horizontal_edges){
                .padding_left = .{ .declared = root_padding },
                .padding_right = .{ .declared = root_padding },
                .border_left = .{ .declared = root_border },
                .border_right = .{ .declared = root_border },
            },
            .vertical_edges = Values(.vertical_edges){
                .padding_top = .{ .declared = root_padding },
                .padding_bottom = .{ .declared = root_padding },
                .border_top = .{ .declared = root_border },
                .border_bottom = .{ .declared = root_border },
            },
            .border_colors = Values(.border_colors){
                .top = .{ .declared = root_border_color },
                .right = .{ .declared = root_border_color },
                .bottom = .{ .declared = root_border_color },
                .left = .{ .declared = root_border_color },
            },
            .border_styles = Values(.border_styles){
                .top = .{ .declared = .solid },
                .right = .{ .declared = .solid },
                .bottom = .{ .declared = .solid },
                .left = .{ .declared = .solid },
            },
            .background_color = Values(.background_color){
                .color = .{ .declared = .{ .rgba = bg_color } },
            },
            .background = Values(.background){
                .position = .{ .declared = &.{.{
                    .x = .{ .side = .end, .offset = .{ .percentage = 0 } },
                    .y = .{ .side = .start, .offset = .{ .px = 10 } },
                }} },
                .repeat = .{ .declared = &.{.{
                    .x = .no_repeat,
                    .y = .no_repeat,
                }} },
            },
            .color = Values(.color){
                .color = .{ .declared = .{ .rgba = text_color } },
            },
        });
        decls.closeBlock();
    }

    { // Large element with display: none
        result.set(.removed_block, try decls.openBlock(allocator));
        try decls.addValues(allocator, .normal, .{
            .box_style = Values(.box_style){ .display = .{ .declared = .none } },
            .content_width = Values(.content_width){ .width = .{ .declared = .{ .px = 500 } } },
            .content_height = Values(.content_height){ .height = .{ .declared = .{ .px = 500 } } },
            .background_color = Values(.background_color){ .color = .{ .declared = .{ .rgba = 0xff00ffff } } },
        });
        decls.closeBlock();
    }

    { // Title block box
        result.set(.title_block, try decls.openBlock(allocator));
        try decls.addValues(allocator, .normal, .{
            .box_style = Values(.box_style){
                .display = .{ .declared = .block },
                .position = .{ .declared = .relative },
            },
            .vertical_edges = Values(.vertical_edges){
                .border_bottom = .{ .declared = .{ .px = 2 } },
                .margin_bottom = .{ .declared = .{ .px = 24 } },
            },
            .z_index = Values(.z_index){
                .z_index = .{ .declared = .{ .integer = -1 } },
            },
            .border_colors = Values(.border_colors){
                .bottom = .{ .declared = .{ .rgba = 0x202020ff } },
            },
            .border_styles = Values(.border_styles){
                .bottom = .{ .declared = .solid },
            },
        });
        decls.closeBlock();
    }

    { // Title inline box
        result.set(.title_inline_box, try decls.openBlock(allocator));
        try decls.addValues(allocator, .normal, .{
            .box_style = Values(.box_style){ .display = .{ .declared = .@"inline" } },
            .horizontal_edges = Values(.horizontal_edges){
                .padding_left = .{ .declared = .{ .px = 10 } },
                .padding_right = .{ .declared = .{ .px = 10 } },
                .border_left = .{ .declared = .{ .px = 10 } },
                .border_right = .{ .declared = .{ .px = 10 } },
            },
            .vertical_edges = Values(.vertical_edges){
                .padding_bottom = .{ .declared = .{ .px = 5 } },
                .border_top = .{ .declared = .{ .px = 10 } },
                .border_bottom = .{ .declared = .{ .px = 10 } },
            },
            .background_color = Values(.background_color){
                .color = .{ .declared = .{ .rgba = 0xfa58007f } },
            },
            .border_styles = Values(.border_styles){
                .top = .{ .declared = .solid },
                .right = .{ .declared = .solid },
                .bottom = .{ .declared = .solid },
                .left = .{ .declared = .solid },
            },
            .border_colors = Values(.border_colors){
                .top = .{ .declared = .{ .rgba = 0xaa1010ff } },
                .right = .{ .declared = .{ .rgba = 0x10aa10ff } },
                .bottom = .{ .declared = .{ .rgba = 0x504090ff } },
                .left = .{ .declared = .{ .rgba = 0x1010aaff } },
            },
        });
        decls.closeBlock();
    }

    { // Body block box
        result.set(.body_block, try decls.openBlock(allocator));
        try decls.addValues(allocator, .normal, .{
            .box_style = Values(.box_style){
                .display = .{ .declared = .block },
                .position = .{ .declared = .relative },
            },
        });
        decls.closeBlock();
    }

    { // Body inline box
        result.set(.body_inline_box, try decls.openBlock(allocator));
        try decls.addValues(allocator, .normal, .{
            .box_style = Values(.box_style){ .display = .{ .declared = .@"inline" } },
            .color = Values(.color){ .color = .{ .declared = .{ .rgba = 0x1010507f } } },
        });
        decls.closeBlock();
    }

    { // Footer block
        result.set(.footer, try decls.openBlock(allocator));
        try decls.addValues(allocator, .normal, .{
            .box_style = Values(.box_style){
                .display = .{ .declared = .block },
            },
            .content_height = Values(.content_height){
                .height = .{ .declared = .{ .px = 200 } },
            },
            .horizontal_edges = Values(.horizontal_edges){
                .border_left = .inherit,
                .border_right = .inherit,
            },
            .vertical_edges = Values(.vertical_edges){
                .margin_top = .{ .declared = .{ .px = 10 } },
                .border_top = .inherit,
                .border_bottom = .inherit,
            },
            .border_colors = Values(.border_colors){
                .top = .inherit,
                .right = .inherit,
                .bottom = .inherit,
                .left = .inherit,
            },
            .border_styles = Values(.border_styles){
                .top = .inherit,
                .right = .inherit,
                .bottom = .inherit,
                .left = .inherit,
            },
            .background_clip = Values(.background_clip){
                .clip = .{ .declared = &.{.padding_box} },
            },
            .background = Values(.background){
                .image = .{ .declared = &.{.{ .image = footer_image_handle }} },
                .position = .{ .declared = &.{.{
                    .x = .{ .side = .start, .offset = .{ .percentage = 0.5 } },
                    .y = .{ .side = .start, .offset = .{ .percentage = 0.5 } },
                }} },
                .repeat = .{ .declared = &.{.{ .x = .space, .y = .no_repeat }} },
                .size = .{ .declared = &.{.contain} },
            },
        });
        decls.closeBlock();
    }

    return result;
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
