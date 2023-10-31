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

/// Can be used to parse most CSS properties:
///     It cannot parse the 'all' property.
///     It cannot parse shorthand properties.
fn genericParser(input: ParserFnInput, comptime Aggregate: type, comptime field_name: []const u8, comptime parseFn: anytype) ?Aggregate {
    var aggregate = Aggregate{};
    switch (input) {
        .css_wide_keyword => |cwk| {
            cwk.apply(.{&@field(aggregate, field_name)});
        },
        .source => |source| {
            @field(aggregate, field_name) = parseFn(source) orelse return null;
        },
    }
    return aggregate;
}

pub fn display(input: ParserFnInput) ?BoxStyle {
    return genericParser(input, BoxStyle, "display", values.parse.display);
}

pub fn position(input: ParserFnInput) ?BoxStyle {
    return genericParser(input, BoxStyle, "position", values.parse.position);
}

pub fn float(input: ParserFnInput) ?BoxStyle {
    return genericParser(input, BoxStyle, "float", values.parse.float);
}

pub fn zIndex(input: ParserFnInput) ?ZIndex {
    return genericParser(input, ZIndex, "z_index", values.parse.zIndex);
}

pub fn width(input: ParserFnInput) ?ContentWidth {
    return genericParser(input, ContentWidth, "width", values.parse.lengthPercentageAuto);
}

pub fn minWidth(input: ParserFnInput) ?ContentWidth {
    return genericParser(input, ContentWidth, "min_width", values.parse.lengthPercentage);
}

pub fn maxWidth(input: ParserFnInput) ?ContentWidth {
    return genericParser(input, ContentWidth, "max_width", values.parse.maxSize);
}
