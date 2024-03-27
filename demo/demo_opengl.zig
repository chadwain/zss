const std = @import("std");
const assert = std.debug.assert;

const zgl = @import("zgl");
const glfw = @import("glfw");

fn glfwCall(code: c_int) !void {
    if (code != glfw.GLFW_TRUE) return error.GlfwError;
}

pub fn main() !u8 {
    std.debug.print("\n{s}\n", .{glfw.glfwGetVersionString()});

    errdefer |err| if (err == error.GlfwError) {
        var description: ?[*:0]const u8 = undefined;
        const code = glfw.glfwGetError(&description);
        std.debug.print("GLFWError(0x{X}): {?s}\n", .{ code, description });
    };

    try glfwCall(glfw.glfwInit());
    defer glfw.glfwTerminate();

    glfw.glfwWindowHint(glfw.GLFW_CONTEXT_VERSION_MAJOR, 3);
    glfw.glfwWindowHint(glfw.GLFW_CONTEXT_VERSION_MINOR, 3);
    glfw.glfwWindowHint(glfw.GLFW_OPENGL_PROFILE, glfw.GLFW_OPENGL_CORE_PROFILE);

    const width = 800;
    const height = 600;
    const window = glfw.glfwCreateWindow(width, height, "zss demo", null, null) orelse return error.GlfwError;
    defer glfw.glfwDestroyWindow(window);

    glfw.glfwMakeContextCurrent(window);
    glfw.glfwSwapInterval(1);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    const getProcAddressWrapper = struct {
        fn f(_: void, symbol_name: [:0]const u8) ?*const anyopaque {
            return glfw.glfwGetProcAddress(symbol_name);
        }
    }.f;
    // TODO: Use zgl bindings that match the OpenGL version that we use
    try zgl.loadExtensions({}, getProcAddressWrapper);

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

    while (glfw.glfwWindowShouldClose(window) == glfw.GLFW_FALSE) {
        zgl.clearColor(0, 0, 0, 0);
        zgl.clear(.{ .color = true });
        zgl.drawArrays(.triangles, 0, 3);
        zgl.flush();

        glfw.glfwSwapBuffers(window);
        glfw.glfwWaitEvents();
    }

    return 0;
}
