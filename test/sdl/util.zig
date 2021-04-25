const zss = @import("zss");
const CSSUnit = zss.types.CSSUnit;
const CSSRect = zss.types.CSSRect;

const sdl = @import("SDL2");

pub fn cssUnitToSdlPixel(css: CSSUnit) i32 {
    return css;
}

pub fn cssRectToSdlRect(css: CSSRect) sdl.SDL_Rect {
    return sdl.SDL_Rect{
        .x = cssUnitToSdlPixel(css.x),
        .y = cssUnitToSdlPixel(css.y),
        .w = cssUnitToSdlPixel(css.w),
        .h = cssUnitToSdlPixel(css.h),
    };
}

pub fn sdlRectToCssRect(rect: sdl.SDL_Rect) CSSRect {
    return CSSRect{
        .x = rect.x,
        .y = rect.y,
        .w = rect.w,
        .h = rect.h,
    };
}

pub fn textureAsBackgroundImage(texture: *sdl.SDL_Texture) zss.used_properties.BackgroundImage.Data {
    return @ptrCast(zss.used_properties.BackgroundImage.Data, texture);
}
