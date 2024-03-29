const std = @import("std");
const assert = std.debug.assert;

const zgl = @import("zgl");
const glfw = @import("mach-glfw");

fn glfwCall(code: c_int) !void {
    if (code != glfw.GLFW_TRUE) return error.GlfwError;
}

pub fn main() !u8 {
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

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    const vao = zgl.genVertexArray();
    zgl.bindVertexArray(vao);

    const verteces = [6]f32{ 0.0, 0.5, -0.5, -0.5, 0.5, -0.5 };
    const vbo = zgl.genBuffer();
    zgl.bindBuffer(vbo, .array_buffer);
    zgl.bufferData(.array_buffer, f32, &verteces, .static_draw);

    zgl.enableVertexArrayAttrib(vao, 0);
    zgl.vertexAttribPointer(0, 2, .float, false, 2 * @sizeOf(f32), 0);

    const vertex_shader_source =
        \\#version 330 core
        \\
        \\layout(location = 0) in vec4 position;
        \\
        \\void main()
        \\{
        \\    gl_Position = position;
        \\}
    ;
    const vertex_shader = zgl.createShader(.vertex);
    zgl.shaderSource(vertex_shader, 1, &[1][]const u8{vertex_shader_source});
    zgl.compileShader(vertex_shader);
    const vertex_shader_log = try zgl.getShaderInfoLog(vertex_shader, allocator);
    defer allocator.free(vertex_shader_log);
    std.debug.print("{s}\n", .{vertex_shader_log});

    const fragment_shader_source =
        \\#version 330 core
        \\
        \\layout(location = 0) out vec4 color;
        \\
        \\void main()
        \\{
        \\    color = vec4(0.0, 1.0, 0.0, 1.0);
        \\}
    ;
    const fragment_shader = zgl.createShader(.fragment);
    zgl.shaderSource(fragment_shader, 1, &[1][]const u8{fragment_shader_source});
    zgl.compileShader(fragment_shader);
    const fragment_shader_log = try zgl.getShaderInfoLog(fragment_shader, allocator);
    defer allocator.free(fragment_shader_log);
    std.debug.print("{s}\n", .{fragment_shader_log});

    const program = zgl.createProgram();
    zgl.attachShader(program, vertex_shader);
    zgl.attachShader(program, fragment_shader);
    zgl.linkProgram(program);
    zgl.useProgram(program);

    while (!window.shouldClose()) {
        zgl.clearColor(0, 0, 0, 0);
        zgl.clear(.{ .color = true });
        zgl.drawArrays(.triangles, 0, 3);
        zgl.flush();

        window.swapBuffers();
        glfw.waitEvents();
    }

    return 0;
}
