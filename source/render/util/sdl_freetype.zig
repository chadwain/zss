const std = @import("std");
const assert = std.debug.assert;
const sdl = @import("SDL2");
const ft = @import("freetype");

pub fn drawGlyph(bitmap: ft.FT_Bitmap, position: sdl.SDL_Point, renderer: *sdl.SDL_Renderer, pixel_format: *sdl.SDL_PixelFormat) error{SDLError}!void {
    const glyph_surface = try makeGlyphSurface(bitmap, pixel_format);
    defer sdl.SDL_FreeSurface(glyph_surface);

    const glyph_texture = sdl.SDL_CreateTextureFromSurface(renderer, glyph_surface) orelse return error.SDLError;
    // NOTE Is it a bug to destroy this texture before calling SDL_RenderPresent?
    defer sdl.SDL_DestroyTexture(glyph_texture);

    assert(sdl.SDL_RenderCopy(renderer, glyph_texture, null, &sdl.SDL_Rect{
        .x = position.x,
        .y = position.y,
        .w = glyph_surface.*.w,
        .h = glyph_surface.*.h,
    }) == 0);
}

// TODO Find a better way to render glyphs than to allocate a new surface
pub fn makeGlyphSurface(bitmap: ft.FT_Bitmap, pixel_format: *sdl.SDL_PixelFormat) error{SDLError}!*sdl.SDL_Surface {
    assert(bitmap.pixel_mode == ft.FT_PIXEL_MODE_GRAY);
    const result = sdl.SDL_CreateRGBSurfaceWithFormat(
        0,
        @intCast(c_int, bitmap.width),
        @intCast(c_int, bitmap.rows),
        32,
        pixel_format.*.format,
    ) orelse return error.SDLError;

    var src_index: usize = 0;
    var dest_index: usize = 0;
    while (dest_index < result.*.pitch * result.*.h) : ({
        dest_index += @intCast(usize, result.*.pitch);
        src_index += @intCast(usize, bitmap.pitch);
    }) {
        const src_row = bitmap.buffer[src_index .. src_index + bitmap.width];
        const dest_row = @ptrCast([*]u32, @alignCast(4, @ptrCast([*]u8, result.*.pixels.?) + dest_index))[0..bitmap.width];
        for (src_row) |_, i| {
            dest_row[i] = sdl.SDL_MapRGBA(pixel_format, 0xff, 0xff, 0xff, src_row[i]);
        }
    }
    return result;
}
