const std = @import("std");
const assert = std.debug.assert;

const sdl = @import("SDL2");
const zgl = @import("zgl");

fn sdlCall(code: c_int) !void {
    if (code != 0) return error.SdlError;
}

pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer assert(gpa.deinit() == .ok);
    var allocator = gpa.allocator();

    errdefer |err| if (err == error.SdlError) {
        std.debug.print("{s}\n", .{sdl.SDL_GetError()});
    };

    if (sdl.SDL_Init(sdl.SDL_INIT_VIDEO) != 0) return error.SdlError;
    defer sdl.SDL_Quit();

    try sdlCall(sdl.SDL_GL_SetAttribute(sdl.SDL_GL_CONTEXT_MAJOR_VERSION, 3));
    try sdlCall(sdl.SDL_GL_SetAttribute(sdl.SDL_GL_CONTEXT_MINOR_VERSION, 3));
    try sdlCall(sdl.SDL_GL_SetAttribute(sdl.SDL_GL_CONTEXT_PROFILE_MASK, sdl.SDL_GL_CONTEXT_PROFILE_CORE));
    try sdlCall(sdl.SDL_GL_SetAttribute(sdl.SDL_GL_DOUBLEBUFFER, 1));
    try sdlCall(sdl.SDL_GL_SetAttribute(sdl.SDL_GL_RED_SIZE, 8));
    try sdlCall(sdl.SDL_GL_SetAttribute(sdl.SDL_GL_GREEN_SIZE, 8));
    try sdlCall(sdl.SDL_GL_SetAttribute(sdl.SDL_GL_BLUE_SIZE, 8));
    try sdlCall(sdl.SDL_GL_SetAttribute(sdl.SDL_GL_ALPHA_SIZE, 8));

    const width = 800;
    const height = 600;
    const window = sdl.SDL_CreateWindow(
        "zss Demo.",
        sdl.SDL_WINDOWPOS_CENTERED_MASK,
        sdl.SDL_WINDOWPOS_CENTERED_MASK,
        width,
        height,
        sdl.SDL_WINDOW_SHOWN | sdl.SDL_WINDOW_RESIZABLE | sdl.SDL_WINDOW_OPENGL,
    ) orelse return error.SdlError;
    defer sdl.SDL_DestroyWindow(window);

    // This fails if the OpenGL version (set above) is not supported
    const context = sdl.SDL_GL_CreateContext(window) orelse return error.SdlError;
    defer sdl.SDL_GL_DeleteContext(context);

    try sdlCall(sdl.SDL_GL_SetSwapInterval(1));

    const getProcAddressWrapper = struct {
        fn f(_: void, symbol_name: [:0]const u8) ?*const anyopaque {
            return sdl.SDL_GL_GetProcAddress(symbol_name);
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

    mainLoop: while (true) {
        var event: sdl.SDL_Event = undefined;
        while (sdl.SDL_PollEvent(&event) != 0) {
            switch (event.type) {
                sdl.SDL_QUIT => {
                    break :mainLoop;
                },
                else => {},
            }
        }

        zgl.clearColor(0, 0, 0, 0);
        zgl.clear(.{ .color = true });
        zgl.drawArrays(.triangles, 0, 3);
        zgl.flush();

        sdl.SDL_GL_SwapWindow(window);
    }

    return 0;
}
