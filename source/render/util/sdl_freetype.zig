const std = @import("std");
const Allocator = std.mem.Allocator;
const AutoArrayHashMapUnmanaged = std.AutoArrayHashMapUnmanaged;
const assert = std.debug.assert;

const zss = @import("../../../zss.zig");
const sdl = @import("SDL2");
const ft = @import("freetype");

pub const GlyphAtlas = struct {
    pub const Entry = struct {
        slot: u8,
        ascender_px: i16,
        width: u16,
        height: u16,
    };

    map: AutoArrayHashMapUnmanaged(c_uint, Entry),
    texture: *sdl.SDL_Texture,
    glyph_width: u16,
    glyph_height: u16,

    const Self = @This();

    pub fn deinit(self: *Self, allocator: *Allocator) void {
        self.map.deinit(allocator);
        sdl.SDL_DestroyTexture(self.texture);
    }
};

pub fn makeGlyphAtlas(face: ft.FT_Face, renderer: *sdl.SDL_Renderer, pixel_format: *sdl.SDL_PixelFormat, allocator: *Allocator) !GlyphAtlas {
    const max_bitmap_width = @intCast(u16, zss.util.roundUp(c_long, zss.util.divCeil(c_long, (face.*.bbox.xMax - face.*.bbox.xMin) * face.*.size.*.metrics.x_ppem, face.*.units_per_EM), 4));
    const max_bitmap_height = @intCast(u16, zss.util.roundUp(c_long, zss.util.divCeil(c_long, (face.*.bbox.yMax - face.*.bbox.yMin) * face.*.size.*.metrics.y_ppem, face.*.units_per_EM), 4));

    const surface = sdl.SDL_CreateRGBSurfaceWithFormat(
        0,
        16 * max_bitmap_width,
        16 * max_bitmap_height,
        32,
        pixel_format.*.format,
    ) orelse return error.SDL_Error;
    defer sdl.SDL_FreeSurface(surface);

    const texture = sdl.SDL_CreateTexture(
        renderer,
        pixel_format.*.format,
        sdl.SDL_TEXTUREACCESS_STATIC,
        surface.*.w,
        surface.*.h,
    ) orelse return error.SDL_Error;
    errdefer sdl.SDL_DestroyTexture(texture);

    var map = AutoArrayHashMapUnmanaged(c_uint, GlyphAtlas.Entry){};
    errdefer map.deinit(allocator);
    try map.ensureCapacity(allocator, 256);

    var slot: u8 = 0;
    var i: usize = 0;
    while (i < 256) : (i += 1) {
        const glyph_index = ft.FT_Get_Char_Index(face, i);
        const get_or_put_result = map.getOrPutAssumeCapacity(glyph_index);
        if (get_or_put_result.found_existing) continue;

        assert(ft.FT_Load_Glyph(face, glyph_index, ft.FT_LOAD_DEFAULT | ft.FT_LOAD_NO_HINTING) == ft.FT_Err_Ok);
        assert(ft.FT_Render_Glyph(face.*.glyph, ft.FT_Render_Mode.FT_RENDER_MODE_NORMAL) == ft.FT_Err_Ok);
        const bitmap = face.*.glyph.*.bitmap;
        assert(bitmap.width <= max_bitmap_width and bitmap.rows <= max_bitmap_height);

        copyBitmapToSurface(
            surface,
            pixel_format,
            bitmap,
            sdl.SDL_Point{ .x = (slot % 16) * max_bitmap_width, .y = (slot / 16) * max_bitmap_height },
        );

        get_or_put_result.entry.value = .{ .slot = slot, .ascender_px = @intCast(i16, face.*.glyph.*.bitmap_top), .width = @intCast(u16, bitmap.width), .height = @intCast(u16, bitmap.rows) };
        slot +%= 1;
    }

    assert(sdl.SDL_SetTextureBlendMode(texture, sdl.SDL_BlendMode.SDL_BLENDMODE_BLEND) == 0);
    assert(sdl.SDL_UpdateTexture(texture, null, surface.*.pixels.?, surface.*.pitch) == 0);
    return GlyphAtlas{ .map = map, .texture = texture, .glyph_width = max_bitmap_width, .glyph_height = max_bitmap_height };
}

fn copyBitmapToSurface(surface: *sdl.SDL_Surface, pixel_format: *sdl.SDL_PixelFormat, bitmap: ft.FT_Bitmap, offset: sdl.SDL_Point) void {
    var src_index: usize = 0;
    var dest_index: usize = @intCast(usize, offset.y * surface.pitch + offset.x * 4);
    while (src_index < bitmap.pitch * @intCast(c_int, bitmap.rows)) : ({
        src_index += @intCast(usize, bitmap.pitch);
        dest_index += @intCast(usize, surface.pitch);
    }) {
        const src_row = bitmap.buffer[src_index .. src_index + bitmap.width];
        const dest_row = @ptrCast([*]u32, @alignCast(4, @ptrCast([*]u8, surface.pixels.?) + dest_index))[0..bitmap.width];
        for (src_row) |_, i| {
            dest_row[i] = sdl.SDL_MapRGBA(pixel_format, 0xff, 0xff, 0xff, src_row[i]);
        }
    }
}
