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

    pub fn init() Renderer {
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

    pub fn deinit(renderer: Renderer) void {
        zgl.deleteBuffers(&.{ renderer.ib, renderer.vb });
        zgl.deleteVertexArray(renderer.vao);
        zgl.deleteShader(renderer.vertex_shader);
        zgl.deleteShader(renderer.fragment_shader);
        zgl.deleteProgram(renderer.program);
    }

    fn prepareToDraw(renderer: Renderer, viewport: ZssRect, translation: ZssVector) void {
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
    }
};

pub fn drawBoxTree(
    renderer: Renderer,
    box_tree: BoxTree,
    draw_order_list: DrawOrderList,
    allocator: Allocator,
    viewport: ZssRect,
) !void {
    const translation = ZssVector{ .x = -viewport.x, .y = -viewport.y };
    renderer.prepareToDraw(viewport, translation);

    const objects = try getObjectsOnScreenInDrawOrder(draw_order_list, allocator, viewport);
    defer allocator.free(objects);

    // TODO: Bad approximation of initial capacity
    var vbo_data = try std.ArrayListUnmanaged(Renderer.Vertex).initCapacity(allocator, objects.len * 12);
    defer vbo_data.deinit(allocator);

    // TODO: Bad approximation of initial capacity
    var ib_data = try std.ArrayListUnmanaged(u32).initCapacity(allocator, objects.len * 30);
    defer ib_data.deinit(allocator);

    var block_count: u32 = 0;
    for (objects) |object| {
        const entry = draw_order_list.getEntry(object);
        switch (entry) {
            .block_box => |block_box| {
                const border_top_left = block_box.border_top_left.add(translation);

                const subtree = box_tree.blocks.subtrees.items[block_box.block_box.subtree];
                const index = block_box.block_box.index;

                const box_offsets = subtree.box_offsets.items[index];
                const borders = subtree.borders.items[index];
                const background1 = subtree.background1.items[index];
                // const background2 = subtree.background2.items[index];
                const border_colors = subtree.border_colors.items[index];
                const boxes = getThreeBoxes(border_top_left, box_offsets, borders);

                var vertices: Renderer.BlockVertices = undefined;
                drawBlockContainer(&vertices, boxes, background1, border_colors);
                try vbo_data.appendSlice(allocator, &vertices);

                var indeces: [Renderer.index_buffer_data.len]u32 = undefined;
                for (Renderer.index_buffer_data, &indeces) |in, *out| {
                    out.* = in + 12 * block_count;
                }
                try ib_data.appendSlice(allocator, &indeces);

                block_count += 1;
            },
            .line_box => {}, // TODO
        }
    }

    zgl.bufferData(.array_buffer, Renderer.Vertex, vbo_data.items, .dynamic_draw);
    zgl.bufferData(.element_array_buffer, u32, ib_data.items, .dynamic_draw);
    zgl.drawElements(.triangles, ib_data.items.len, .u32, 0);
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

fn v(x: ZssUnit, y: ZssUnit, color: Color) Renderer.Vertex {
    return .{ .pos = .{ x, y }, .color = @bitCast(std.mem.nativeToBig(u32, color)) };
}

fn drawBlockContainer(
    vertices: *Renderer.BlockVertices,
    boxes: ThreeBoxes,
    background1: zss.used_values.Background1,
    border_colors: zss.used_values.BorderColor,
) void {
    const bg_clip_rect = switch (background1.clip) {
        .Border => boxes.border,
        .Padding => boxes.padding,
        .Content => boxes.content,
    };

    // draw background color
    vertices.*[8] = v(bg_clip_rect.x, bg_clip_rect.y, undefined);
    vertices.*[9] = v(bg_clip_rect.x + bg_clip_rect.w, bg_clip_rect.y, undefined);
    vertices.*[10] = v(bg_clip_rect.x + bg_clip_rect.w, bg_clip_rect.y + bg_clip_rect.h, undefined);
    vertices.*[11] = v(bg_clip_rect.x, bg_clip_rect.y + bg_clip_rect.h, background1.color_rgba);

    // TODO: draw the background image

    // draw borders
    const border = boxes.border;
    vertices.*[0] = v(border.x, border.y, undefined);
    vertices.*[1] = v(border.x + border.w, border.y, undefined);
    vertices.*[2] = v(border.x + border.w, border.y + border.h, undefined);
    vertices.*[3] = v(border.x, border.y + border.h, undefined);
    const padding = boxes.padding;
    vertices.*[4] = v(padding.x, padding.y, border_colors.top_rgba);
    vertices.*[5] = v(padding.x + padding.w, padding.y, border_colors.right_rgba);
    vertices.*[6] = v(padding.x + padding.w, padding.y + padding.h, border_colors.bottom_rgba);
    vertices.*[7] = v(padding.x, padding.y + padding.h, border_colors.left_rgba);
}
