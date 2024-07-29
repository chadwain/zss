const Fonts = @This();

const hb = @import("mach-harfbuzz");

pub const Handle = enum { invalid, the_only_handle };

/// Externally managed.
the_only_font: ?hb.Font,

pub fn init() Fonts {
    return .{ .the_only_font = null };
}

pub fn deinit(fonts: *Fonts) void {
    _ = fonts;
}

pub fn setFont(fonts: *Fonts, font: hb.Font) void {
    fonts.the_only_font = font;
}

pub fn query(fonts: Fonts) Handle {
    return if (fonts.the_only_font) |_| .the_only_handle else .invalid;
}

pub fn get(fonts: Fonts, handle: Handle) ?hb.Font {
    return switch (handle) {
        .invalid => null,
        .the_only_handle => fonts.the_only_font.?,
    };
}
