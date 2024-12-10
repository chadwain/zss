const std = @import("std");
const assert = std.debug.assert;
const panic = std.debug.panic;
const Allocator = std.mem.Allocator;

const zss = @import("../zss.zig");
const Images = zss.Images;
const DrawList = @import("./DrawList.zig");
const QuadTree = @import("./QuadTree.zig");

const BoxTree = zss.BoxTree;
const Color = BoxTree.Color;
const Ifc = BoxTree.InlineFormattingContext;
const GlyphIndex = Ifc.GlyphIndex;
const StackingContext = BoxTree.StackingContext;
const StackingContextTree = BoxTree.StackingContextTree;
const Subtree = BoxTree.Subtree;
const ZIndex = BoxTree.ZIndex;

const math = zss.math;
const units_per_pixel = zss.math.units_per_pixel;
const Unit = math.Unit;
const Range = math.Range;
const Rect = math.Rect;
const Size = math.Size;
const Vector = math.Vector;
const Ratio = math.Ratio;

const zgl = @import("zgl");
const hb = @import("mach-harfbuzz");

// TODO: Check for OpenGL errors
// TODO: Potentially lossy casts from integers to floats

pub const Renderer = struct {
    mode: Mode = .init,

    vao: zgl.VertexArray,
    ib: zgl.Buffer,
    vb: zgl.Buffer,
    program: zgl.Program,
    vertex_shader: zgl.Shader,
    fragment_shader: zgl.Shader,
    one_pixel_texture: zgl.Texture,

    glyphs: struct {
        texture: zgl.Texture,
        max_width_px: u32,
        max_height_px: u32,
        exists: [max_glyphs]bool,
        metrics: [max_glyphs]GlyphMetrics,
    },

    textures: std.AutoHashMapUnmanaged(Images.Handle, zgl.Texture) = .{},

    vertices: std.ArrayListUnmanaged(Vertex) = .{},
    indeces: std.ArrayListUnmanaged(u32) = .{},

    allocator: Allocator,

    const Mode = enum { init, flat_color, textured };

    const Vertex = extern struct {
        pos: [2]zgl.Int,
        color: [4]zgl.UByte,
        tex_coords: [2]zgl.Float,
    };

    const glyphs_per_row = 16;
    const glyphs_per_column = 16;
    const max_glyphs = glyphs_per_row * glyphs_per_column;

    const GlyphMetrics = struct {
        width_px: u32,
        height_px: u32,
        ascender_px: i32,
    };

    pub fn init(allocator: Allocator) Renderer {
        const vao = zgl.genVertexArray();
        zgl.bindVertexArray(vao);

        var buffer_names: [2]zgl.Buffer = undefined;
        zgl.genBuffers(&buffer_names);
        const ib, const vb = .{ buffer_names[0], buffer_names[1] };

        zgl.bindBuffer(vb, .array_buffer);
        zgl.enableVertexAttribArray(0);
        zgl.vertexAttribIPointer(0, 2, .int, @sizeOf(Vertex), @offsetOf(Vertex, "pos"));
        zgl.enableVertexAttribArray(1);
        zgl.vertexAttribPointer(1, 4, .unsigned_byte, true, @sizeOf(Vertex), @offsetOf(Vertex, "color"));
        zgl.enableVertexAttribArray(2);
        zgl.vertexAttribPointer(2, 2, .float, false, @sizeOf(Vertex), @offsetOf(Vertex, "tex_coords"));

        const program = zgl.createProgram();
        const vertex_shader = attachShader(program, .vertex,
            \\#version 330 core
            \\
            \\layout(location = 0) in ivec2 position;
            \\layout(location = 1) in vec4 color;
            \\layout(location = 2) in vec2 tex_coords;
            \\
            \\uniform ivec2 viewport;
            \\uniform ivec2 translation;
            \\
            \\const mat4 projection = mat4(
            \\  vec4(2.0,  0.0,  0.0, -1.0),
            \\  vec4(0.0, -2.0,  0.0,  1.0),
            \\  vec4(0.0,  0.0,  0.0,  0.0),
            \\  vec4(0.0,  0.0,  0.0,  1.0)
            \\);
            \\
            \\flat out vec4 Color;
            \\out vec2 TexCoords;
            \\
            \\void main()
            \\{
            \\    gl_Position = vec4(vec2(position + translation) / vec2(viewport), 0.0, 1.0) * projection;
            \\    Color = color;
            \\    TexCoords = tex_coords;
            \\}
        );
        const fragment_shader = attachShader(program, .fragment,
            \\#version 330 core
            \\
            \\uniform sampler2D Texture;
            \\
            \\flat in vec4 Color;
            \\in vec2 TexCoords;
            \\
            \\layout(location = 0) out vec4 color;
            \\
            \\void main()
            \\{
            \\    color = texture(Texture, TexCoords) * Color;
            \\}
        );
        zgl.linkProgram(program);

        const one_pixel_texture = createOnePixelTexture();

        return Renderer{
            .vao = vao,
            .ib = ib,
            .vb = vb,
            .program = program,
            .vertex_shader = vertex_shader,
            .fragment_shader = fragment_shader,
            .allocator = allocator,
            .one_pixel_texture = one_pixel_texture,
            .glyphs = undefined,
        };
    }

    fn attachShader(program: zgl.Program, shader_type: zgl.ShaderType, source: []const u8) zgl.Shader {
        const shader = zgl.createShader(shader_type);
        zgl.shaderSource(shader, 1, &[1][]const u8{source});
        zgl.compileShader(shader);
        var error_log: [512]u8 = undefined;
        var fbo = std.heap.FixedBufferAllocator.init(&error_log);
        const log = zgl.getShaderInfoLog(shader, fbo.allocator()) catch panic("OOM on trying to get shader error log", .{});
        if (log.len > 0) {
            panic("Error compiling {s} shader: {s}\n", .{ @tagName(shader_type), log });
        }
        zgl.attachShader(program, shader);
        return shader;
    }

    fn createOnePixelTexture() zgl.Texture {
        const texture = zgl.genTexture();
        zgl.bindTexture(texture, .@"2d");
        zgl.texParameter(.@"2d", .min_filter, .nearest);
        zgl.texParameter(.@"2d", .mag_filter, .nearest);
        zgl.texParameter(.@"2d", .wrap_s, .repeat);
        zgl.texParameter(.@"2d", .wrap_t, .repeat);
        zgl.textureImage2D(.@"2d", 0, .rgba, 1, 1, .rgba, .unsigned_byte, &Color.white.toRgbaArray());
        return texture;
    }

    pub fn deinit(renderer: *Renderer) void {
        zgl.deleteBuffers(&.{ renderer.ib, renderer.vb });
        zgl.deleteVertexArray(renderer.vao);
        zgl.deleteShader(renderer.vertex_shader);
        zgl.deleteShader(renderer.fragment_shader);
        zgl.deleteProgram(renderer.program);
        zgl.deleteTexture(renderer.one_pixel_texture);

        var it = renderer.textures.valueIterator();
        while (it.next()) |texture| {
            zgl.deleteTexture(texture.*);
        }
        renderer.textures.deinit(renderer.allocator);

        renderer.vertices.deinit(renderer.allocator);
        renderer.indeces.deinit(renderer.allocator);
    }

    pub fn initGlyphs(renderer: *Renderer, c_font: *hb.c.hb_font_t) !void {
        const font = hb.Font{ .handle = c_font };
        const face = font.getFreetypeFace();
        try face.selectCharmap(.unicode);

        const max_width, const max_height = blk: {
            const max_bbox = face.bbox();
            const metrics = face.size().metrics();
            break :blk .{
                @as(u32, @intCast(max_bbox.xMax - max_bbox.xMin)) * metrics.x_ppem / face.unitsPerEM(),
                @as(u32, @intCast(max_bbox.yMax - max_bbox.yMin)) * metrics.y_ppem / face.unitsPerEM(),
            };
        };

        const buffer_width = max_width * glyphs_per_row;
        const buffer_stride = buffer_width;
        const buffer_rows = max_height * glyphs_per_column;
        const buffer = try renderer.allocator.alloc(u8, buffer_stride * buffer_rows);
        defer renderer.allocator.free(buffer);

        const texture = zgl.genTexture();
        errdefer zgl.deleteTexture(texture);
        zgl.bindTexture(texture, .@"2d");
        zgl.texParameter(.@"2d", .min_filter, .nearest);
        zgl.texParameter(.@"2d", .mag_filter, .nearest);
        zgl.texParameter(.@"2d", .wrap_s, .repeat);
        zgl.texParameter(.@"2d", .wrap_t, .repeat);
        zgl.texParameter(.@"2d", .swizzle_r, .one);
        zgl.texParameter(.@"2d", .swizzle_g, .one);
        zgl.texParameter(.@"2d", .swizzle_b, .one);
        zgl.texParameter(.@"2d", .swizzle_a, .red);
        zgl.textureImage2D(.@"2d", 0, .red, buffer_width, buffer_rows, .red, .unsigned_byte, null);

        var exists = [1]bool{false} ** max_glyphs;
        var metrics = [1]GlyphMetrics{undefined} ** max_glyphs;
        for (0..max_glyphs) |glyph_index| {
            try face.loadGlyph(@intCast(glyph_index), .{});
            const glyph = face.glyph();
            try glyph.render(.normal);

            const bitmap = glyph.bitmap();
            if (bitmap.buffer()) |src| {
                const glyph_x = glyph_index % glyphs_per_row;
                const glyph_y = glyph_index / glyphs_per_row;

                const dest_index = (glyph_x * max_width) + (glyph_y * max_height * buffer_stride);

                const src_width = bitmap.width();
                const src_height = bitmap.rows();
                const src_stride: u32 = @abs(bitmap.pitch());
                for (0..src_height) |y| {
                    @memcpy(
                        buffer[dest_index + y * buffer_stride ..][0..src_width],
                        src[y * src_stride ..][0..src_width],
                    );
                }

                exists[glyph_index] = true;
                metrics[glyph_index] = .{
                    .width_px = src_width,
                    .height_px = src_height,
                    .ascender_px = glyph.bitmapTop(),
                };
            }
        }

        zgl.texSubImage2D(.@"2d", 0, 0, 0, buffer_width, buffer_rows, .red, .unsigned_byte, buffer.ptr);

        renderer.glyphs = .{
            .texture = texture,
            .max_width_px = max_width,
            .max_height_px = max_height,
            .exists = exists,
            .metrics = metrics,
        };
    }

    pub fn deinitGlyphs(renderer: *Renderer) void {
        zgl.deleteTexture(renderer.glyphs.texture);
    }

    pub fn showGlyphs(renderer: *Renderer, viewport: Rect) !void {
        try renderer.beginDraw(viewport, 1);
        defer renderer.endDraw();
        renderer.setMode(.textured, renderer.glyphs.texture);

        var rect = Rect{ .x = 0, .y = 0, .w = undefined, .h = undefined };
        const texture_width: i32 = @intCast(renderer.glyphs.max_width_px * glyphs_per_row);
        const texture_height: i32 = @intCast(renderer.glyphs.max_height_px * glyphs_per_column);
        if (texture_width >= texture_height) {
            rect.w = viewport.w;
            rect.h = @divFloor(texture_height * viewport.w, texture_width);
        } else {
            rect.w = @divFloor(texture_width * viewport.h, texture_height);
            rect.h = viewport.h;
        }
        try renderer.addTexturedRect(rect, Color.white, .{ 0.0, 1.0 }, .{ 0.0, 1.0 });
    }

    const GlyphInfo = struct {
        metrics: GlyphMetrics,
        tex_coords_x: [2]f32,
        tex_coords_y: [2]f32,
    };

    fn getGlyphInfo(renderer: *const Renderer, glyph_index: u32) ?GlyphInfo {
        if (glyph_index >= max_glyphs) return null;
        if (!renderer.glyphs.exists[glyph_index]) return null;

        const metrics = renderer.glyphs.metrics[glyph_index];

        const glyph_x = glyph_index % glyphs_per_row;
        const glyph_y = glyph_index / glyphs_per_row;

        const x_min: f32 = @floatFromInt(glyph_x * renderer.glyphs.max_width_px);
        const x_max: f32 = @floatFromInt(glyph_x * renderer.glyphs.max_width_px + metrics.width_px);
        const y_min: f32 = @floatFromInt(glyph_y * renderer.glyphs.max_height_px);
        const y_max: f32 = @floatFromInt(glyph_y * renderer.glyphs.max_height_px + metrics.height_px);

        const texture_width: f32 = @floatFromInt(renderer.glyphs.max_width_px * glyphs_per_row);
        const texture_height: f32 = @floatFromInt(renderer.glyphs.max_height_px * glyphs_per_column);

        return .{
            .metrics = metrics,
            .tex_coords_x = .{ x_min / texture_width, x_max / texture_width },
            .tex_coords_y = .{ y_min / texture_height, y_max / texture_height },
        };
    }

    fn uploadImage(renderer: *Renderer, images: Images.Slice, handle: Images.Handle) !zgl.Texture {
        const image = images.get(@intFromEnum(handle));
        const texture: zgl.Texture = switch (image.format) {
            .none => .invalid,
            .rgba => blk: {
                zgl.activeTexture(.texture_1);
                defer zgl.activeTexture(.texture_0);

                const data = image.data.rgba orelse break :blk .invalid;
                const texture = zgl.genTexture();
                zgl.bindTexture(texture, .@"2d");
                zgl.texParameter(.@"2d", .min_filter, .linear);
                zgl.texParameter(.@"2d", .mag_filter, .linear);
                zgl.texParameter(.@"2d", .wrap_s, .clamp_to_edge);
                zgl.texParameter(.@"2d", .wrap_t, .clamp_to_edge);

                zgl.textureImage2D(.@"2d", 0, .rgba, image.dimensions.width_px, image.dimensions.height_px, .rgba, .unsigned_byte, data.ptr);
                break :blk texture;
            },
        };
        try renderer.textures.putNoClobber(renderer.allocator, handle, texture);
        return texture;
    }

    fn beginDraw(renderer: *Renderer, viewport: Rect, num_objects: usize) !void {
        zgl.bindVertexArray(renderer.vao);
        zgl.bindBuffer(renderer.vb, .array_buffer);
        zgl.bindBuffer(renderer.ib, .element_array_buffer);
        zgl.useProgram(renderer.program);
        zgl.enable(.blend);
        zgl.binding.blendEquation(zgl.binding.FUNC_ADD);
        zgl.blendFuncSeparate(.src_alpha, .one_minus_src_alpha, .one, .one_minus_src_alpha);

        const viewport_location = zgl.getUniformLocation(renderer.program, "viewport");
        zgl.uniform2i(viewport_location, viewport.w, viewport.h);
        const translation_location = zgl.getUniformLocation(renderer.program, "translation");
        zgl.uniform2i(translation_location, -viewport.x, -viewport.y);
        renderer.setMode(.flat_color, {});

        // TODO: Bad approximation of initial capacity
        try renderer.vertices.ensureTotalCapacity(renderer.allocator, num_objects * 12);
        errdefer renderer.vertices.deinit(renderer.allocator);
        try renderer.indeces.ensureTotalCapacity(renderer.allocator, num_objects * 30);
    }

    fn endDraw(renderer: *Renderer) void {
        renderer.endMode();
    }

    fn setMode(
        renderer: *Renderer,
        comptime mode: Mode,
        extra: switch (mode) {
            .init, .flat_color => void,
            .textured => zgl.Texture,
        },
    ) void {
        renderer.endMode();
        switch (mode) {
            .init => @compileError("Invalid renderer mode 'init'"),
            .flat_color => {
                zgl.activeTexture(.texture_0);
                zgl.bindTexture(renderer.one_pixel_texture, .@"2d");
                const texture_location = zgl.getUniformLocation(renderer.program, "Texture");
                zgl.uniform1i(texture_location, 0);
            },
            .textured => {
                zgl.activeTexture(.texture_0);
                zgl.bindTexture(extra, .@"2d");
                const texture_location = zgl.getUniformLocation(renderer.program, "Texture");
                zgl.uniform1i(texture_location, 0);
            },
        }
        renderer.mode = mode;
    }

    fn endMode(renderer: *Renderer) void {
        switch (renderer.mode) {
            .init => {},
            .flat_color, .textured => {
                zgl.bufferData(.array_buffer, Vertex, renderer.vertices.items, .dynamic_draw);
                zgl.bufferData(.element_array_buffer, u32, renderer.indeces.items, .dynamic_draw);
                zgl.drawElements(.triangles, renderer.indeces.items.len, .unsigned_int, 0);
                renderer.vertices.clearRetainingCapacity();
                renderer.indeces.clearRetainingCapacity();
            },
        }
    }

    fn addTriangle(renderer: *Renderer, vertices: [3][2]Unit, color: Color) !void {
        const start_index: u32 = @intCast(renderer.vertices.items.len);
        try renderer.vertices.appendSlice(renderer.allocator, &.{
            .{ .pos = vertices[0], .color = undefined, .tex_coords = .{ 0.0, 0.0 } },
            .{ .pos = vertices[1], .color = undefined, .tex_coords = .{ 0.0, 0.0 } },
            .{ .pos = vertices[2], .color = color.toRgbaArray(), .tex_coords = .{ 0.0, 0.0 } },
        });
        const indeces_template = [3]u32{
            0, 1, 2,
        };
        var indeces: [indeces_template.len]u32 = undefined;
        for (indeces_template, &indeces) |in, *out| {
            out.* = start_index + in;
        }
        try renderer.indeces.appendSlice(renderer.allocator, &indeces);
    }

    /// Vertices are expected to be in this order:
    ///
    /// 0              1
    ///  ______________
    ///  |            |
    ///  |            |
    ///  |            |
    ///  ______________
    /// 3              2
    fn addQuadFull(renderer: *Renderer, pos: [4][2]Unit, color: Color, tex_coords: [4][2]f32) !void {
        const start_index: u32 = @intCast(renderer.vertices.items.len);
        try renderer.vertices.appendSlice(renderer.allocator, &.{
            .{ .pos = pos[0], .color = undefined, .tex_coords = tex_coords[0] },
            .{ .pos = pos[1], .color = undefined, .tex_coords = tex_coords[1] },
            .{ .pos = pos[2], .color = undefined, .tex_coords = tex_coords[2] },
            .{ .pos = pos[3], .color = color.toRgbaArray(), .tex_coords = tex_coords[3] },
        });
        const indeces_template = [6]u32{
            0, 1, 3,
            1, 2, 3,
        };
        var indeces: [indeces_template.len]u32 = undefined;
        for (indeces_template, &indeces) |in, *out| {
            out.* = start_index + in;
        }
        try renderer.indeces.appendSlice(renderer.allocator, &indeces);
    }

    fn addQuad(renderer: *Renderer, vertices: [4][2]Unit, color: Color) !void {
        return renderer.addQuadFull(vertices, color, .{[2]f32{ 0.0, 0.0 }} ** 4);
    }

    fn zssRectToVertices(rect: Rect) [4][2]Unit {
        return .{
            .{ rect.x, rect.y },
            .{ rect.x + rect.w, rect.y },
            .{ rect.x + rect.w, rect.y + rect.h },
            .{ rect.x, rect.y + rect.h },
        };
    }

    fn addRect(renderer: *Renderer, rect: Rect, color: Color) !void {
        return renderer.addQuad(zssRectToVertices(rect), color);
    }

    fn addTexturedRect(renderer: *Renderer, rect: Rect, tint: Color, tex_coords_x: [2]f32, tex_coords_y: [2]f32) !void {
        const tex_coords = [4][2]f32{
            .{ tex_coords_x[0], tex_coords_y[0] },
            .{ tex_coords_x[1], tex_coords_y[0] },
            .{ tex_coords_x[1], tex_coords_y[1] },
            .{ tex_coords_x[0], tex_coords_y[1] },
        };
        return renderer.addQuadFull(zssRectToVertices(rect), tint, tex_coords);
    }
};

pub fn drawBoxTree(
    renderer: *Renderer,
    images: Images.Slice,
    box_tree: BoxTree,
    draw_list: DrawList,
    allocator: Allocator,
    viewport: Rect,
) !void {
    const objects = try getObjectsOnScreenInDrawOrder(draw_list, allocator, viewport);
    defer allocator.free(objects);

    try renderer.beginDraw(viewport, objects.len);
    defer renderer.endDraw();

    for (objects) |object| {
        const entry = draw_list.getEntry(object);
        switch (entry) {
            .block_box => |block_box| {
                const border_top_left = block_box.border_top_left;

                const subtree = box_tree.getSubtree(block_box.ref.subtree).view();
                const index = block_box.ref.index;

                const box_offsets = subtree.items(.box_offsets)[index];
                const borders = subtree.items(.borders)[index];
                const background = subtree.items(.background)[index];
                const border_colors = subtree.items(.border_colors)[index];
                const boxes = getThreeBoxes(border_top_left, box_offsets, borders);

                try drawBlockContainer(renderer, box_tree, images, boxes, background, border_colors);
            },
            .line_box => |line_box_info| {
                const origin = line_box_info.origin;
                const ifc = box_tree.getIfc(line_box_info.ifc_id);
                const line_box = ifc.line_boxes.items[line_box_info.line_box_index];

                try drawLineBox(renderer, ifc, line_box, origin, allocator);
            },
        }
    }
}

fn getObjectsOnScreenInDrawOrder(draw_list: DrawList, allocator: Allocator, viewport: Rect) ![]QuadTree.Object {
    const objects = try draw_list.quad_tree.findObjectsInRect(viewport, allocator);
    errdefer allocator.free(objects);

    const draw_indeces = try allocator.alloc(DrawList.DrawIndex, objects.len);
    defer allocator.free(draw_indeces);

    for (objects, draw_indeces) |object, *draw_index| draw_index.* = draw_list.getDrawIndex(object);

    const SortContext = struct {
        objects: []QuadTree.Object,
        draw_indeces: []DrawList.DrawIndex,

        pub fn lessThan(ctx: @This(), a_index: usize, b_index: usize) bool {
            return ctx.draw_indeces[a_index] < ctx.draw_indeces[b_index];
        }

        pub fn swap(ctx: @This(), a_index: usize, b_index: usize) void {
            std.mem.swap(QuadTree.Object, &ctx.objects[a_index], &ctx.objects[b_index]);
            std.mem.swap(DrawList.DrawIndex, &ctx.draw_indeces[a_index], &ctx.draw_indeces[b_index]);
        }
    };

    std.mem.sortUnstableContext(0, objects.len, SortContext{ .objects = objects, .draw_indeces = draw_indeces });
    return objects;
}

const ThreeBoxes = struct {
    border: Rect,
    padding: Rect,
    content: Rect,
};

fn getThreeBoxes(
    border_top_left: Vector,
    box_offsets: zss.BoxTree.BoxOffsets,
    borders: zss.BoxTree.Borders,
) ThreeBoxes {
    return ThreeBoxes{
        .border = Rect{
            .x = border_top_left.x,
            .y = border_top_left.y,
            .w = box_offsets.border_size.w,
            .h = box_offsets.border_size.h,
        },
        .padding = Rect{
            .x = border_top_left.x + borders.left,
            .y = border_top_left.y + borders.top,
            .w = box_offsets.border_size.w - borders.left - borders.right,
            .h = box_offsets.border_size.h - borders.top - borders.bottom,
        },
        .content = Rect{
            .x = border_top_left.x + box_offsets.content_pos.x,
            .y = border_top_left.y + box_offsets.content_pos.y,
            .w = box_offsets.content_size.w,
            .h = box_offsets.content_size.h,
        },
    };
}

fn drawBlockContainer(
    renderer: *Renderer,
    box_tree: BoxTree,
    images: Images.Slice,
    boxes: ThreeBoxes,
    background: zss.BoxTree.BlockBoxBackground,
    border_colors: zss.BoxTree.BorderColor,
) !void {
    // draw background color
    switch (background.color.a) {
        0 => {},
        else => {
            const bg_clip_rect = switch (background.color_clip) {
                .border => boxes.border,
                .padding => boxes.padding,
                .content => boxes.content,
            };
            try renderer.addRect(bg_clip_rect, background.color);
        },
    }

    // draw background images
    if (box_tree.background_images.get(background.images)) |background_images| {
        var i = background_images.len;
        while (i > 0) : (i -= 1) {
            const bg_image = background_images[i - 1];
            const handle = bg_image.handle orelse continue;
            if (bg_image.size.w == 0 or bg_image.size.h == 0) continue;

            const texture: zgl.Texture = renderer.textures.get(handle) orelse (try renderer.uploadImage(images, handle));
            if (texture == .invalid) continue;

            renderer.setMode(.textured, texture);
            defer renderer.setMode(.flat_color, {});

            const positioning_area = switch (bg_image.origin) {
                .border => boxes.border,
                .padding => boxes.padding,
                .content => boxes.content,
            };

            const painting_area = switch (bg_image.clip) {
                .border => boxes.border,
                .padding => boxes.padding,
                .content => boxes.content,
            };

            try drawBackgroundImage(renderer, positioning_area, painting_area, bg_image.position, bg_image.size, bg_image.repeat);
        }
    }

    // draw borders
    const border = boxes.border;
    const border_vertices = [4][2]Unit{
        .{ border.x, border.y },
        .{ border.x + border.w, border.y },
        .{ border.x + border.w, border.y + border.h },
        .{ border.x, border.y + border.h },
    };
    const padding = boxes.padding;
    const padding_vertices = [4][2]Unit{
        .{ padding.x, padding.y },
        .{ padding.x + padding.w, padding.y },
        .{ padding.x + padding.w, padding.y + padding.h },
        .{ padding.x, padding.y + padding.h },
    };

    try renderer.addQuad(.{ border_vertices[0], border_vertices[1], padding_vertices[1], padding_vertices[0] }, border_colors.top);
    try renderer.addQuad(.{ border_vertices[1], border_vertices[2], padding_vertices[2], padding_vertices[1] }, border_colors.right);
    try renderer.addQuad(.{ border_vertices[2], border_vertices[3], padding_vertices[3], padding_vertices[2] }, border_colors.bottom);
    try renderer.addQuad(.{ border_vertices[3], border_vertices[0], padding_vertices[0], padding_vertices[3] }, border_colors.left);
}

fn drawBackgroundImage(
    renderer: *Renderer,
    positioning_area: Rect,
    painting_area: Rect,
    position: Vector,
    size: Size,
    repeat: zss.BoxTree.BackgroundImage.Repeat,
) !void {
    const info_x = getBackgroundImageTilingInfo(
        repeat.x,
        painting_area.w,
        positioning_area.x - painting_area.x,
        positioning_area.w,
        position.x,
        size.w,
    );
    const info_y = getBackgroundImageTilingInfo(
        repeat.y,
        painting_area.h,
        positioning_area.y - painting_area.y,
        positioning_area.h,
        position.y,
        size.h,
    );

    var i = info_x.start_index;
    while (i < info_x.start_index + info_x.count) : (i += 1) {
        const tile_x = getBackgroundImageTileCoords(i, painting_area.xRange(), positioning_area.xRange(), size.w, info_x.space, info_x.offset);

        var j = info_y.start_index;
        while (j < info_y.start_index + info_y.count) : (j += 1) {
            const tile_y = getBackgroundImageTileCoords(j, painting_area.yRange(), positioning_area.yRange(), size.h, info_y.space, info_y.offset);

            const image_rect = Rect{
                .x = tile_x.coords.min,
                .y = tile_y.coords.min,
                .w = tile_x.coords.max - tile_x.coords.min,
                .h = tile_y.coords.max - tile_y.coords.min,
            };
            try renderer.addTexturedRect(
                image_rect,
                Color.white,
                .{ tile_x.tex_coords.min, tile_x.tex_coords.max },
                .{ tile_y.tex_coords.min, tile_y.tex_coords.max },
            );
        }
    }
}

// Tiling Background Images
//
//                             Painting area
// |------------------------------------------------------------------|
// | |---------|  |--------  Positioning area  -------|  ----------|  |
// | ||----------------------------------------------------------| |  |
// | ||(-2, -1)|  | (-1, -1)|  | (0, -1) |  | (1, -1) |  | (2, -1| |  |
// | ||--------|  |----------  ----------|  |---------|  --------|-|  |
// |  |                                                          |    |
// |  |                          Center                          |    |
// | ||--------|  |---------|  |---------|  |---------|  |-------|-|  |
// | ||Image   |  | Image   |  | Image   |  | Image   |  | Image | |  |
// | ||(-2, 0) |  | (-1, 0) |  | (0, 0)  |  | (1, 0)  |  | (2, 0)| |  |
// | ||--------|  |---------|  |---------|  |---------|  |-------|-|  |
// |  |                                                          |    |
// |  |                                                          |    |
// | ||--------|  |---------|  |---------|  |---------|  |-------|-|  |
// | ||Image   |  | Image   |  | Image   |  | Image   |  | Image | |  |
// | ||(-2, 1) |  | (-1, 1) |  | (0, 1)  |  | (1, 1)  |  | (2, 1)| |  |
// | ||--------|  |---------|  |---------|  |---------|  |-------|-|  |
// |  |                                                          |    |
// |  |                                                          |    |
// | ||--------|  |---------|  |---------|  |---------|  |---------|  |
// | ||(-2, 2) |  | (-1, 2) |  | (0, 2)  |  | (1, 2)  |  | (2, 2)| |  |
// | ||----------------------------------------------------------| |  |
// | |---------|  |---------|  |---------|  |---------|  |---------|  |
// |------------------------------------------------------------------|
//
// Background images are positioned within the background positioning area, and painted within the background painting area.
// In this diagram the positioning area is smaller than the painting area, but it could be the other way around.
// The images have (x, y) coordinates that increase going to the right and down.
// One image with a known position is designated to be the "center image", and given the coordinates (0, 0).
// All the other images are positioned relative to the center image.
// The spacing, position, and size of the images can be determined for the x and y axes independently.

const BackgroundImageTilingInfo = struct {
    /// The index of the left-most/top-most image to be drawn.
    start_index: i32,
    /// The number of images to draw. Always positive.
    count: i32,
    /// The amount of space to leave between each image. Always positive.
    space: Ratio,
    /// The offset of the top/left of the image with index 0 from the top/left of the positioning area.
    offset: Unit,
};

fn getBackgroundImageTilingInfo(
    repeat: zss.BoxTree.BackgroundImage.Repeat.Style,
    /// Must be greater than or equal to 0.
    painting_area_size: Unit,
    /// The offset of the top/left of the positioning area from the top/left of the painting area.
    positioning_area_offset: Unit,
    /// Must be greater than or equal to 0.
    positioning_area_size: Unit,
    /// The offset of the top/left of the image with index 0 from the top/left of the positioning area.
    image_offset: Unit,
    /// Must be strictly greater than 0.
    image_size: Unit,
) BackgroundImageTilingInfo {
    assert(painting_area_size >= 0);
    assert(positioning_area_size >= 0);
    assert(image_size > 0);

    // Unless otherwise specified, the center image is the one with offset `image_offset` from the start of the positioning area.
    const divCeil = std.math.divCeil;
    switch (repeat) {
        .none => {
            return .{
                .start_index = 0,
                .count = 1,
                .space = .{ .num = 0, .den = 1 },
                .offset = image_offset,
            };
        },
        .repeat => {
            const space_before_center = positioning_area_offset + image_offset;
            const num_before_center = divCeil(Unit, space_before_center, image_size) catch unreachable;

            const space_after_center = painting_area_size - positioning_area_offset - image_offset - image_size;
            const num_after_center = divCeil(Unit, space_after_center, image_size) catch unreachable;

            return .{
                .start_index = -num_before_center,
                .count = num_before_center + num_after_center + 1,
                .space = .{ .num = 0, .den = 1 },
                .offset = image_offset,
            };
        },
        .space => {
            const num_within_positioning_area = @divFloor(positioning_area_size, image_size);
            if (num_within_positioning_area <= 1) {
                return .{
                    .start_index = 0,
                    .count = 1,
                    .space = .{ .num = 0, .den = 1 },
                    .offset = image_offset,
                };
            }

            // Here, the center image is chosen to be the one with offset 0 from the start of the positioning area.

            const positioning_area_unused_space = @mod(positioning_area_size, image_size);
            const n = num_within_positioning_area - 1;

            // To determine how many images to draw in the space before/after the positioning area:
            //
            // space_between_images = positioning_area_unused_space / n
            // space = The amount of space between the start/end edge of the positioning area and the start/end edge of the painting area
            // result
            //     = divCeil(space - space_between_images, image_size + space_between_images)
            //     = divCeil(n * space - positioning_area_unused_space, n * image_size + positioning_area_unused_space)
            //     = divCeil(n * space - positioning_area_unused_space, (n + 1) * image_size + positioning_area_unused_space - image_size)
            //     = divCeil(n * space - positioning_area_unused_space, positioning_area_size - image_size)

            const denominator = positioning_area_size - image_size;

            const space_before_positioning_area = positioning_area_offset;
            const num_before_positioning_area =
                divCeil(Unit, n * space_before_positioning_area - positioning_area_unused_space, denominator) catch unreachable;

            const space_after_positioning_area = painting_area_size - positioning_area_offset - positioning_area_size;
            const num_after_positioning_area =
                divCeil(Unit, n * space_after_positioning_area - positioning_area_unused_space, denominator) catch unreachable;

            return .{
                .start_index = -num_before_positioning_area,
                .count = num_before_positioning_area + num_after_positioning_area + num_within_positioning_area,
                .space = .{ .num = positioning_area_unused_space, .den = n },
                .offset = 0,
            };
        },
        .round => panic("TODO: render: Background image round repeat style", .{}),
    }
}

const BackgroundImageTileCoords = struct {
    coords: struct {
        min: Unit,
        max: Unit,
    },
    tex_coords: struct {
        min: f32,
        max: f32,
    },
};

fn getBackgroundImageTileCoords(
    tile_coord: i32,
    painting_range: Range,
    positioning_range: Range,
    size: Unit,
    space: Ratio,
    offset: Unit,
) BackgroundImageTileCoords {
    var result: BackgroundImageTileCoords = undefined;

    // s = positioning_range.start + offset + tile_coord * (size + space)
    //   = divFloor(space.den * (positioning_range.start + offset + tile_coord * size) + tile_coord * space.num, space.den)
    const s = @divFloor(space.den * (positioning_range.start + offset + tile_coord * size) + tile_coord * space.num, space.den);
    result.coords.min, result.tex_coords.min = if (s >= painting_range.start)
        .{ s, 0.0 }
    else
        .{ painting_range.start, @as(f32, @floatFromInt(painting_range.start - s)) / @as(f32, @floatFromInt(size)) };

    result.coords.max, result.tex_coords.max = blk: {
        const s_end = s + size;
        const painting_range_end = painting_range.start + painting_range.length;
        break :blk if (s_end <= painting_range_end)
            .{ s_end, 1.0 }
        else
            .{ painting_range_end, 1.0 + @as(f32, @floatFromInt(painting_range_end - s_end)) / @as(f32, @floatFromInt(size)) };
    };

    assert(result.coords.max > result.coords.min);
    return result;
}

fn drawLineBox(
    renderer: *Renderer,
    ifc: *const Ifc,
    line_box: Ifc.LineBox,
    translation: Vector,
    allocator: Allocator,
) !void {
    const slice = ifc.slice();

    var inline_box_stack = std.ArrayListUnmanaged(Ifc.Size){};
    defer inline_box_stack.deinit(allocator);

    var offset = translation;

    const all_glyphs = ifc.glyphs.items(.index)[line_box.elements[0]..line_box.elements[1]];
    const all_metrics = ifc.glyphs.items(.metrics)[line_box.elements[0]..line_box.elements[1]];

    if (line_box.inline_box) |initial_inline_box| {
        renderer.setMode(.flat_color, {});

        var i: Ifc.Size = 0;
        const skips = slice.items(.skip);

        while (true) {
            const insets = slice.items(.insets)[i];
            offset = offset.add(insets);
            try inline_box_stack.append(allocator, i);
            const match_info = findMatchingBoxEnd(all_glyphs, all_metrics, i);
            try drawInlineBox(
                renderer,
                ifc,
                slice,
                i,
                Vector{ .x = offset.x, .y = offset.y + line_box.baseline },
                match_info.advance,
                false,
                match_info.found,
            );

            if (i == initial_inline_box) break;
            const end = i + skips[i];
            i += 1;
            while (i < end) {
                const skip = skips[i];
                if (initial_inline_box >= i and initial_inline_box < i + skip) break;
                i += skip;
            } else unreachable;
        }
    }

    renderer.setMode(.textured, renderer.glyphs.texture);
    defer renderer.setMode(.flat_color, {});

    var cursor: Unit = 0;
    var i: usize = 0;
    while (i < all_glyphs.len) : (i += 1) {
        const glyph_index = all_glyphs[i];
        const metrics = all_metrics[i];
        defer cursor += metrics.advance;

        if (glyph_index == 0) blk: {
            i += 1;
            const special = Ifc.Special.decode(all_glyphs[i]);
            switch (special.kind) {
                .ZeroGlyphIndex => break :blk,
                .BoxStart => {
                    renderer.setMode(.flat_color, {});
                    defer renderer.setMode(.textured, renderer.glyphs.texture);

                    const match_info = findMatchingBoxEnd(all_glyphs[i + 1 ..], all_metrics[i + 1 ..], special.data);
                    const insets = slice.items(.insets)[special.data];
                    offset = offset.add(insets);
                    try drawInlineBox(
                        renderer,
                        ifc,
                        slice,
                        special.data,
                        Vector{ .x = offset.x + cursor + metrics.offset, .y = offset.y + line_box.baseline },
                        match_info.advance,
                        true,
                        match_info.found,
                    );
                    try inline_box_stack.append(allocator, special.data);
                },
                .BoxEnd => {
                    assert(special.data == inline_box_stack.pop());
                    const insets = slice.items(.insets)[special.data];
                    offset = offset.sub(insets);
                },
                .InlineBlock => {},
                _ => unreachable,
            }
            continue;
        }

        if (renderer.getGlyphInfo(glyph_index)) |info| {
            const rect = Rect{
                .x = offset.x + cursor + metrics.offset,
                .y = offset.y + line_box.baseline - (info.metrics.ascender_px * units_per_pixel),
                .w = @intCast(info.metrics.width_px * units_per_pixel),
                .h = @intCast(info.metrics.height_px * units_per_pixel),
            };
            try renderer.addTexturedRect(rect, ifc.font_color, info.tex_coords_x, info.tex_coords_y);
        }
    }
}

fn findMatchingBoxEnd(
    glyph_indeces: []const GlyphIndex,
    metrics: []const Ifc.Metrics,
    inline_box: Ifc.Size,
) struct {
    advance: Unit,
    found: bool,
} {
    var found = false;
    var advance: Unit = 0;
    var i: usize = 0;
    while (i < glyph_indeces.len) : (i += 1) {
        const glyph_index = glyph_indeces[i];
        const metric = metrics[i];

        if (glyph_index == 0) {
            i += 1;
            const special = Ifc.Special.decode(glyph_indeces[i]);
            if (special.kind == .BoxEnd and @as(Ifc.Size, special.data) == inline_box) {
                found = true;
                break;
            }
        }

        advance += metric.advance;
    }

    return .{ .advance = advance, .found = found };
}

fn drawInlineBox(
    renderer: *Renderer,
    ifc: *const Ifc,
    slice: Ifc.Slice,
    inline_box: Ifc.Size,
    baseline_position: Vector,
    middle_length: Unit,
    draw_start: bool,
    draw_end: bool,
) !void {
    const inline_start = slice.items(.inline_start)[inline_box];
    const inline_end = slice.items(.inline_end)[inline_box];
    const block_start = slice.items(.block_start)[inline_box];
    const block_end = slice.items(.block_end)[inline_box];
    const background = slice.items(.background)[inline_box];

    // TODO: Assuming ltr writing mode
    const border = .{
        .top = block_start.border,
        .right = inline_end.border,
        .bottom = block_end.border,
        .left = inline_start.border,
    };

    const padding = .{
        .top = block_start.padding,
        .right = inline_end.padding,
        .bottom = block_end.padding,
        .left = inline_start.padding,
    };

    const border_colors = .{
        .top = block_start.border_color,
        .right = inline_end.border_color,
        .bottom = block_end.border_color,
        .left = inline_start.border_color,
    };

    // NOTE: The height of the content box is based on the ascender and descender.
    const content_top_y = baseline_position.y - ifc.ascender;
    const padding_top_y = content_top_y - padding.top;
    const border_top_y = padding_top_y - border.top;
    const content_bottom_y = baseline_position.y + ifc.descender;
    const padding_bottom_y = content_bottom_y + padding.bottom;
    const border_bottom_y = padding_bottom_y + border.bottom;

    { // background color
        var background_clip_rect = Rect{
            .x = baseline_position.x,
            .y = undefined,
            .w = middle_length,
            .h = undefined,
        };
        switch (background.clip) {
            .border => {
                background_clip_rect.y = border_top_y;
                background_clip_rect.h = border_bottom_y - border_top_y;
                if (draw_start) background_clip_rect.w += padding.left + border.left;
                if (draw_end) background_clip_rect.w += padding.right + border.right;
            },
            .padding => {
                background_clip_rect.y = padding_top_y;
                background_clip_rect.h = padding_bottom_y - padding_top_y;
                if (draw_start) {
                    background_clip_rect.x += border.left;
                    background_clip_rect.w += padding.left;
                }
                if (draw_end) background_clip_rect.w += padding.right;
            },
            .content => {
                background_clip_rect.y = content_top_y;
                background_clip_rect.h = content_bottom_y - content_top_y;
                if (draw_start) background_clip_rect.x += padding.left + border.left;
            },
        }
        try renderer.addRect(background_clip_rect, background.color);
    }

    var middle_border_x = baseline_position.x;
    var middle_border_w = middle_length;

    if (draw_start) {
        middle_border_x += border.left;
        middle_border_w += padding.left;

        const section_start_x = baseline_position.x;
        const section_end_x = section_start_x + border.left;

        const vertices = [6][2]Unit{
            .{ section_start_x, border_top_y },
            .{ section_end_x, border_top_y },
            .{ section_end_x, padding_top_y },
            .{ section_end_x, padding_bottom_y },
            .{ section_end_x, border_bottom_y },
            .{ section_start_x, border_bottom_y },
        };

        try renderer.addQuad(.{ vertices[0], vertices[2], vertices[3], vertices[5] }, border_colors.left);
        try renderer.addTriangle(.{ vertices[0], vertices[1], vertices[2] }, border_colors.top);
        try renderer.addTriangle(.{ vertices[3], vertices[4], vertices[5] }, border_colors.bottom);
    }

    if (draw_end) {
        middle_border_w += padding.right;

        const section_start_x = middle_border_x + middle_border_w;
        const section_end_x = section_start_x + border.right;

        const vertices = [6][2]Unit{
            .{ section_start_x, border_top_y },
            .{ section_end_x, border_top_y },
            .{ section_end_x, border_bottom_y },
            .{ section_start_x, border_bottom_y },
            .{ section_start_x, padding_bottom_y },
            .{ section_start_x, padding_top_y },
        };

        try renderer.addQuad(.{ vertices[1], vertices[2], vertices[4], vertices[5] }, border_colors.right);
        try renderer.addTriangle(.{ vertices[0], vertices[1], vertices[5] }, border_colors.top);
        try renderer.addTriangle(.{ vertices[2], vertices[3], vertices[4] }, border_colors.bottom);
    }

    {
        const top_rect = Rect{
            .x = middle_border_x,
            .y = border_top_y,
            .w = middle_border_w,
            .h = border.top,
        };
        const bottom_rect = Rect{
            .x = middle_border_x,
            .y = padding_bottom_y,
            .w = middle_border_w,
            .h = border.bottom,
        };

        try renderer.addRect(top_rect, border_colors.top);
        try renderer.addRect(bottom_rect, border_colors.bottom);
    }
}
