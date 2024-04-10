const std = @import("std");
const assert = std.debug.assert;
const panic = std.debug.panic;
const Allocator = std.mem.Allocator;

const zss = @import("../zss.zig");
const DrawOrderList = @import("./DrawOrderList.zig");
const QuadTree = @import("./QuadTree.zig");
const ZssUnit = zss.used_values.ZssUnit;
const ZssRect = zss.used_values.ZssRect;
const ZssVector = zss.used_values.ZssVector;
const BlockBoxIndex = zss.used_values.BlockBoxIndex;
const BlockSubtree = zss.used_values.BlockSubtree;
const BlockSubtreeIndex = zss.used_values.BlockSubtreeIndex;
const BlockBox = zss.used_values.BlockBox;
const BlockBoxTree = zss.used_values.BlockBoxTree;
const Color = zss.used_values.Color;
const InlineBoxIndex = zss.used_values.InlineBoxIndex;
const InlineFormattingContext = zss.used_values.InlineFormattingContext;
const InlineFormattingContextIndex = zss.used_values.InlineFormattingContextIndex;
const GlyphIndex = InlineFormattingContext.GlyphIndex;
const StackingContext = zss.used_values.StackingContext;
const StackingContextTree = zss.used_values.StackingContextTree;
const ZIndex = zss.used_values.ZIndex;
const BoxTree = zss.used_values.BoxTree;

const zgl = @import("zgl");

// TODO: Check for OpenGL errors
// TODO: Potentially lossy casts from integers to floats

pub const Renderer = struct {
    vao: zgl.VertexArray,
    ib: zgl.Buffer,
    vb: zgl.Buffer,
    program: zgl.Program,
    vertex_shader: zgl.Shader,
    fragment_shader: zgl.Shader,

    vertices: std.ArrayListUnmanaged(Vertex) = .{},
    indeces: std.ArrayListUnmanaged(u32) = .{},
    allocator: Allocator,

    const Vertex = extern struct {
        pos: [2]zgl.Int,
        color: [4]zgl.UByte,
    };

    // Vertices needed to draw a block box's borders
    // 0                      1
    //  ______________________
    //  |  4              5  |
    //  |   ______________   |
    //  |   |            |   |
    //  |   |            |   |
    //  |   |            |   |
    //  |   ______________   |
    //  |  7              6  |
    //  ______________________
    // 3                      2

    // Vertices needed to draw a block box's background color
    // 8              9
    //  ______________
    //  |            |
    //  |            |
    //  |            |
    //  ______________
    // 11             10

    const BlockVertices = [12]Vertex;

    const index_buffer_data = [30]zgl.UInt{
        8, 9,  11,
        9, 10, 11,
        0, 1,  4,
        1, 5,  4,
        1, 2,  5,
        2, 6,  5,
        2, 3,  6,
        3, 7,  6,
        3, 0,  7,
        0, 4,  7,
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

        const program = zgl.createProgram();
        const vertex_shader = attachShader(program, .vertex,
            \\#version 330 core
            \\
            \\layout(location = 0) in ivec2 position;
            \\layout(location = 1) in vec4 color;
            \\
            \\uniform ivec2 viewport;
            \\uniform ivec2 translation;
            \\
            \\flat out vec4 Color;
            \\
            \\void main()
            \\{
            \\    gl_Position = vec4(vec2(position + translation) * vec2(1.0, -1.0) / vec2(viewport) * 2 + vec2(-1.0, 1.0), 0.0, 1.0);
            \\    Color = color;
            \\}
        );
        const fragment_shader = attachShader(program, .fragment,
            \\#version 330 core
            \\
            \\flat in vec4 Color;
            \\
            \\layout(location = 0) out vec4 color;
            \\
            \\void main()
            \\{
            \\    color = Color;
            \\}
        );
        zgl.linkProgram(program);

        return Renderer{
            .vao = vao,
            .ib = ib,
            .vb = vb,
            .program = program,
            .vertex_shader = vertex_shader,
            .fragment_shader = fragment_shader,
            .allocator = allocator,
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

    pub fn deinit(renderer: *Renderer) void {
        zgl.deleteBuffers(&.{ renderer.ib, renderer.vb });
        zgl.deleteVertexArray(renderer.vao);
        zgl.deleteShader(renderer.vertex_shader);
        zgl.deleteShader(renderer.fragment_shader);
        zgl.deleteProgram(renderer.program);

        renderer.vertices.deinit(renderer.allocator);
        renderer.indeces.deinit(renderer.allocator);
    }

    fn beginDraw(renderer: *Renderer, viewport: ZssRect, translation: ZssVector, num_objects: usize) !void {
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
        zgl.uniform2i(translation_location, translation.x, translation.y);

        // TODO: Bad approximation of initial capacity
        try renderer.vertices.ensureTotalCapacity(renderer.allocator, num_objects * 12);
        try renderer.indeces.ensureTotalCapacity(renderer.allocator, num_objects * 30);
    }

    fn endDraw(renderer: *Renderer) void {
        renderer.vertices.clearRetainingCapacity();
        renderer.indeces.clearRetainingCapacity();
    }
};

fn addTriangle(renderer: *Renderer, vertices: [3][2]ZssUnit, color: Color) !void {
    const start_index: u32 = @intCast(renderer.vertices.items.len);
    try renderer.vertices.appendSlice(renderer.allocator, &.{
        .{ .pos = vertices[0], .color = undefined },
        .{ .pos = vertices[1], .color = undefined },
        .{ .pos = vertices[2], .color = color.toRgbaArray() },
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

fn addQuad(renderer: *Renderer, vertices: [4][2]ZssUnit, color: Color) !void {
    const start_index: u32 = @intCast(renderer.vertices.items.len);
    try renderer.vertices.appendSlice(renderer.allocator, &.{
        .{ .pos = vertices[0], .color = undefined },
        .{ .pos = vertices[1], .color = undefined },
        .{ .pos = vertices[2], .color = undefined },
        .{ .pos = vertices[3], .color = color.toRgbaArray() },
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

fn addZssRect(renderer: *Renderer, rect: ZssRect, color: Color) !void {
    const vertices = [4][2]ZssUnit{
        .{ rect.x, rect.y },
        .{ rect.x + rect.w, rect.y },
        .{ rect.x + rect.w, rect.y + rect.h },
        .{ rect.x, rect.y + rect.h },
    };
    return addQuad(renderer, vertices, color);
}

pub fn drawBoxTree(
    renderer: *Renderer,
    box_tree: BoxTree,
    draw_order_list: DrawOrderList,
    allocator: Allocator,
    viewport: ZssRect,
) !void {
    const objects = try getObjectsOnScreenInDrawOrder(draw_order_list, allocator, viewport);
    defer allocator.free(objects);

    const translation = ZssVector{ .x = -viewport.x, .y = -viewport.y };

    try renderer.beginDraw(viewport, translation, objects.len);
    defer renderer.endDraw();

    for (objects) |object| {
        const entry = draw_order_list.getEntry(object);
        switch (entry) {
            .block_box => |block_box| {
                const border_top_left = block_box.border_top_left.add(translation);

                const subtree_slice = box_tree.blocks.subtrees.items[block_box.block_box.subtree].slice();
                const index = block_box.block_box.index;

                const box_offsets = subtree_slice.items(.box_offsets)[index];
                const borders = subtree_slice.items(.borders)[index];
                const background1 = subtree_slice.items(.background1)[index];
                // const background2 = subtree_slice.items(.background2)[index];
                const border_colors = subtree_slice.items(.border_colors)[index];
                const boxes = getThreeBoxes(border_top_left, box_offsets, borders);

                try drawBlockContainer(renderer, boxes, background1, border_colors);
            },
            .line_box => |line_box_info| {
                const origin = line_box_info.origin.add(translation);
                const ifc = box_tree.ifcs.items[line_box_info.ifc_index];
                const line_box = ifc.line_boxes.items[line_box_info.line_box_index];

                try drawLineBox(renderer, ifc, line_box, origin, allocator);
            },
        }
    }

    zgl.bufferData(.array_buffer, Renderer.Vertex, renderer.vertices.items, .dynamic_draw);
    zgl.bufferData(.element_array_buffer, u32, renderer.indeces.items, .dynamic_draw);
    zgl.drawElements(.triangles, renderer.indeces.items.len, .u32, 0);
}

fn getObjectsOnScreenInDrawOrder(draw_order_list: DrawOrderList, allocator: Allocator, viewport: ZssRect) ![]QuadTree.Object {
    const objects = try draw_order_list.quad_tree.findObjectsInRect(viewport, allocator);
    errdefer allocator.free(objects);

    const draw_indeces = try allocator.alloc(DrawOrderList.DrawIndex, objects.len);
    defer allocator.free(draw_indeces);

    for (objects, draw_indeces) |object, *draw_index| draw_index.* = draw_order_list.getDrawIndex(object);

    const SortContext = struct {
        objects: []QuadTree.Object,
        draw_indeces: []DrawOrderList.DrawIndex,

        pub fn lessThan(ctx: @This(), a_index: usize, b_index: usize) bool {
            return ctx.draw_indeces[a_index] < ctx.draw_indeces[b_index];
        }

        pub fn swap(ctx: @This(), a_index: usize, b_index: usize) void {
            std.mem.swap(QuadTree.Object, &ctx.objects[a_index], &ctx.objects[b_index]);
            std.mem.swap(DrawOrderList.DrawIndex, &ctx.draw_indeces[a_index], &ctx.draw_indeces[b_index]);
        }
    };

    std.mem.sortUnstableContext(0, objects.len, SortContext{ .objects = objects, .draw_indeces = draw_indeces });
    return objects;
}

const ThreeBoxes = struct {
    border: ZssRect,
    padding: ZssRect,
    content: ZssRect,
};

fn getThreeBoxes(
    border_top_left: ZssVector,
    box_offsets: zss.used_values.BoxOffsets,
    borders: zss.used_values.Borders,
) ThreeBoxes {
    return ThreeBoxes{
        .border = ZssRect{
            .x = border_top_left.x,
            .y = border_top_left.y,
            .w = box_offsets.border_size.w,
            .h = box_offsets.border_size.h,
        },
        .padding = ZssRect{
            .x = border_top_left.x + borders.left,
            .y = border_top_left.y + borders.top,
            .w = box_offsets.border_size.w - borders.left - borders.right,
            .h = box_offsets.border_size.h - borders.top - borders.bottom,
        },
        .content = ZssRect{
            .x = border_top_left.x + box_offsets.content_pos.x,
            .y = border_top_left.y + box_offsets.content_pos.y,
            .w = box_offsets.content_size.w,
            .h = box_offsets.content_size.h,
        },
    };
}

fn drawBlockContainer(
    renderer: *Renderer,
    boxes: ThreeBoxes,
    background1: zss.used_values.Background1,
    border_colors: zss.used_values.BorderColor,
) !void {
    // draw background color
    switch (background1.color.a) {
        0 => {},
        else => {
            const bg_clip_rect = switch (background1.clip) {
                .Border => boxes.border,
                .Padding => boxes.padding,
                .Content => boxes.content,
            };

            try addQuad(renderer, .{
                .{ bg_clip_rect.x, bg_clip_rect.y },
                .{ bg_clip_rect.x + bg_clip_rect.w, bg_clip_rect.y },
                .{ bg_clip_rect.x + bg_clip_rect.w, bg_clip_rect.y + bg_clip_rect.h },
                .{ bg_clip_rect.x, bg_clip_rect.y + bg_clip_rect.h },
            }, background1.color);
        },
    }

    // TODO: draw the background image

    // draw borders
    const border = boxes.border;
    const border_vertices = [4][2]ZssUnit{
        .{ border.x, border.y },
        .{ border.x + border.w, border.y },
        .{ border.x + border.w, border.y + border.h },
        .{ border.x, border.y + border.h },
    };
    const padding = boxes.padding;
    const padding_vertices = [4][2]ZssUnit{
        .{ padding.x, padding.y },
        .{ padding.x + padding.w, padding.y },
        .{ padding.x + padding.w, padding.y + padding.h },
        .{ padding.x, padding.y + padding.h },
    };

    try addQuad(renderer, .{ border_vertices[0], border_vertices[1], padding_vertices[1], padding_vertices[0] }, border_colors.top);
    try addQuad(renderer, .{ border_vertices[1], border_vertices[2], padding_vertices[2], padding_vertices[1] }, border_colors.right);
    try addQuad(renderer, .{ border_vertices[2], border_vertices[3], padding_vertices[3], padding_vertices[2] }, border_colors.bottom);
    try addQuad(renderer, .{ border_vertices[3], border_vertices[0], padding_vertices[0], padding_vertices[3] }, border_colors.left);
}

fn drawLineBox(
    renderer: *Renderer,
    ifc: *const InlineFormattingContext,
    line_box: InlineFormattingContext.LineBox,
    translation: ZssVector,
    allocator: Allocator,
) !void {
    const slice = ifc.slice();

    var inline_box_stack = std.ArrayListUnmanaged(InlineBoxIndex){};
    defer inline_box_stack.deinit(allocator);

    var offset = translation;

    const all_glyphs = ifc.glyph_indeces.items[line_box.elements[0]..line_box.elements[1]];
    const all_metrics = ifc.metrics.items[line_box.elements[0]..line_box.elements[1]];

    if (line_box.inline_box) |inline_box| {
        var i: InlineBoxIndex = 0;
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
                inline_box,
                ZssVector{ .x = offset.x, .y = offset.y + line_box.baseline },
                match_info.advance,
                false,
                match_info.found,
            );

            if (i == inline_box) break;
            const end = i + skips[i];
            i += 1;
            while (i < end) {
                const skip = skips[i];
                if (inline_box >= i and inline_box < i + skip) break;
                i += skip;
            } else unreachable;
        }
    }

    var cursor: ZssUnit = 0;
    var i: usize = 0;
    while (i < all_glyphs.len) : (i += 1) {
        const glyph_index = all_glyphs[i];
        const metrics = all_metrics[i];
        defer cursor += metrics.advance;

        if (glyph_index == 0) blk: {
            i += 1;
            const special = InlineFormattingContext.Special.decode(all_glyphs[i]);
            switch (special.kind) {
                .ZeroGlyphIndex => break :blk,
                .BoxStart => {
                    const match_info = findMatchingBoxEnd(all_glyphs[i + 1 ..], all_metrics[i + 1 ..], special.data);
                    const insets = slice.items(.insets)[special.data];
                    offset = offset.add(insets);
                    try drawInlineBox(
                        renderer,
                        ifc,
                        slice,
                        special.data,
                        ZssVector{ .x = offset.x + cursor + metrics.offset, .y = offset.y + line_box.baseline },
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
    }
}

fn findMatchingBoxEnd(
    glyph_indeces: []const GlyphIndex,
    metrics: []const InlineFormattingContext.Metrics,
    inline_box: InlineBoxIndex,
) struct {
    advance: ZssUnit,
    found: bool,
} {
    var found = false;
    var advance: ZssUnit = 0;
    var i: usize = 0;
    while (i < glyph_indeces.len) : (i += 1) {
        const glyph_index = glyph_indeces[i];
        const metric = metrics[i];

        if (glyph_index == 0) {
            i += 1;
            const special = InlineFormattingContext.Special.decode(glyph_indeces[i]);
            if (special.kind == .BoxEnd and @as(InlineBoxIndex, special.data) == inline_box) {
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
    ifc: *const InlineFormattingContext,
    slice: InlineFormattingContext.Slice,
    inline_box: InlineBoxIndex,
    baseline_position: ZssVector,
    middle_length: ZssUnit,
    draw_start: bool,
    draw_end: bool,
) !void {
    const inline_start = slice.items(.inline_start)[inline_box];
    const inline_end = slice.items(.inline_end)[inline_box];
    const block_start = slice.items(.block_start)[inline_box];
    const block_end = slice.items(.block_end)[inline_box];
    const background1 = slice.items(.background1)[inline_box];

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
    const content_bottom_y = baseline_position.y - ifc.descender;
    const padding_bottom_y = content_bottom_y + padding.bottom;
    const border_bottom_y = padding_bottom_y + border.bottom;

    { // background color
        var background_clip_rect = ZssRect{
            .x = baseline_position.x,
            .y = undefined,
            .w = middle_length,
            .h = undefined,
        };
        switch (background1.clip) {
            .Border => {
                background_clip_rect.y = border_top_y;
                background_clip_rect.h = border_bottom_y - border_top_y;
                if (draw_start) background_clip_rect.w += padding.left + border.left;
                if (draw_end) background_clip_rect.w += padding.right + border.right;
            },
            .Padding => {
                background_clip_rect.y = padding_top_y;
                background_clip_rect.h = padding_bottom_y - padding_top_y;
                if (draw_start) {
                    background_clip_rect.x += border.left;
                    background_clip_rect.w += padding.left;
                }
                if (draw_end) background_clip_rect.w += padding.right;
            },
            .Content => {
                background_clip_rect.y = content_top_y;
                background_clip_rect.h = content_bottom_y - content_top_y;
                if (draw_start) background_clip_rect.x += padding.left + border.left;
            },
        }
        try addZssRect(renderer, background_clip_rect, background1.color);
    }

    var top_bottom_border_x = baseline_position.x;
    var top_bottom_border_w = middle_length;

    if (draw_start) {
        const section_start_x = baseline_position.x;
        const section_end_x = section_start_x + border.left;

        const vertices = [6][2]ZssUnit{
            .{ section_start_x, border_top_y },
            .{ section_end_x, border_top_y },
            .{ section_end_x, padding_top_y },
            .{ section_end_x, padding_bottom_y },
            .{ section_end_x, border_bottom_y },
            .{ section_start_x, border_bottom_y },
        };

        try addQuad(renderer, .{ vertices[0], vertices[2], vertices[3], vertices[5] }, border_colors.left);
        try addTriangle(renderer, .{ vertices[0], vertices[1], vertices[2] }, border_colors.top);
        try addTriangle(renderer, .{ vertices[3], vertices[4], vertices[5] }, border_colors.bottom);

        top_bottom_border_x += border.left;
        top_bottom_border_w += padding.left;
    }

    if (draw_end) {
        const section_start_x = baseline_position.x + border.left + padding.left + middle_length + padding.right;
        const section_end_x = section_start_x + border.right;

        const vertices = [6][2]ZssUnit{
            .{ section_start_x, border_top_y },
            .{ section_end_x, border_top_y },
            .{ section_end_x, border_bottom_y },
            .{ section_start_x, border_bottom_y },
            .{ section_start_x, padding_bottom_y },
            .{ section_start_x, padding_top_y },
        };

        try addQuad(renderer, .{ vertices[1], vertices[2], vertices[4], vertices[5] }, border_colors.right);
        try addTriangle(renderer, .{ vertices[0], vertices[1], vertices[5] }, border_colors.top);
        try addTriangle(renderer, .{ vertices[2], vertices[3], vertices[4] }, border_colors.bottom);

        top_bottom_border_w += padding.right;
    }

    {
        const top_rect = ZssRect{
            .x = top_bottom_border_x,
            .y = border_top_y,
            .w = top_bottom_border_w,
            .h = border.top,
        };
        const bottom_rect = ZssRect{
            .x = top_bottom_border_x,
            .y = padding_bottom_y,
            .w = top_bottom_border_w,
            .h = border.bottom,
        };

        try addZssRect(renderer, top_rect, border_colors.top);
        try addZssRect(renderer, bottom_rect, border_colors.bottom);
    }
}
