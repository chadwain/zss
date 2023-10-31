const zss = @import("../../zss.zig");
const values = zss.values;

const aggregates = zss.properties.aggregates;
const BoxStyle = aggregates.BoxStyle;
const ContentWidth = aggregates.ContentWidth;
const ZIndex = aggregates.ZIndex;

pub const ParserFnInput = union(enum) {
    source: *values.parse.Source,
    css_wide_keyword: values.CssWideKeyword,
};

pub fn display(input: ParserFnInput) ?BoxStyle {
    var box_style = BoxStyle{};
    switch (input) {
        .css_wide_keyword => |cwk| {
            cwk.apply(.{&box_style.display});
        },
        .source => |source| {
            box_style.display = values.parse.display(source) orelse return null;
        },
    }
    return box_style;
}

pub fn position(input: ParserFnInput) ?BoxStyle {
    var box_style = BoxStyle{};
    switch (input) {
        .css_wide_keyword => |cwk| {
            cwk.apply(.{&box_style.position});
        },
        .source => |source| {
            box_style.position = values.parse.position(source) orelse return null;
        },
    }
    return box_style;
}

pub fn float(input: ParserFnInput) ?BoxStyle {
    var box_style = BoxStyle{};
    switch (input) {
        .css_wide_keyword => |cwk| {
            cwk.apply(.{&box_style.float});
        },
        .source => |source| {
            box_style.float = values.parse.float(source) orelse return null;
        },
    }
    return box_style;
}

pub fn zIndex(input: ParserFnInput) ?ZIndex {
    var z_index = ZIndex{};
    switch (input) {
        .css_wide_keyword => |cwk| {
            cwk.apply(.{&z_index.z_index});
        },
        .source => |source| {
            z_index.z_index = values.parse.zIndex(source) orelse return null;
        },
    }
    return z_index;
}

pub fn width(input: ParserFnInput) ?ContentWidth {
    var content_width = ContentWidth{};
    switch (input) {
        .css_wide_keyword => |cwk| {
            cwk.apply(.{&content_width.width});
        },
        .source => |source| {
            content_width.width = values.parse.lengthPercentageAuto(source) orelse return null;
        },
    }
    return content_width;
}
