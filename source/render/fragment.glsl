#version 330 core

uniform sampler2D Texture;

flat in vec4 Color;
in vec2 TexCoords;

layout(location = 0) out vec4 color;

void main()
{
    color = texture(Texture, TexCoords) * Color;
}
