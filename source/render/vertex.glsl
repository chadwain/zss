#version 330 core

layout(location = 0) in ivec2 position;
layout(location = 1) in vec4 color;
layout(location = 2) in vec2 tex_coords;

uniform ivec2 viewport;
uniform ivec2 translation;

const mat4 projection = mat4(
  vec4(2.0,  0.0,  0.0, -1.0),
  vec4(0.0, -2.0,  0.0,  1.0),
  vec4(0.0,  0.0,  0.0,  0.0),
  vec4(0.0,  0.0,  0.0,  1.0)
);

flat out vec4 Color;
out vec2 TexCoords;

void main()
{
    gl_Position = vec4(vec2(position + translation) / vec2(viewport), 0.0, 1.0) * projection;
    Color = color;
    TexCoords = tex_coords;
}
