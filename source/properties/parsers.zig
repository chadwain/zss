const zss = @import("../../zss.zig");
const values = zss.values;

const aggregates = zss.properties.aggregates;
const BoxStyle = aggregates.BoxStyle;

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