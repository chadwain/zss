const Fonts = @This();

const hb = @import("harfbuzz").c;

pub const Handle = enum { invalid, the_only_handle };

/// Externally managed.
the_only_font: ?*hb.hb_font_t,

pub fn init() Fonts {
    return .{ .the_only_font = null };
}

pub fn deinit(fonts: *Fonts) void {
    _ = fonts;
}

pub fn setFont(fonts: *Fonts, font: *hb.hb_font_t) Handle {
    fonts.the_only_font = font;
    return .the_only_handle;
}

pub fn query(fonts: Fonts) Handle {
    return if (fonts.the_only_font) |_| .the_only_handle else .invalid;
}

pub fn get(fonts: Fonts, handle: Handle) ?*hb.hb_font_t {
    return switch (handle) {
        .invalid => null,
        .the_only_handle => fonts.the_only_font.?,
    };
}
