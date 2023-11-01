const zss = @import("../../zss.zig");
const values = zss.values;

const aggregates = zss.properties.aggregates;
const BoxStyle = aggregates.BoxStyle;
const ContentWidth = aggregates.ContentWidth;
const ContentHeight = aggregates.ContentHeight;
const HorizontalEdges = aggregates.HorizontalEdges;
const VerticalEdges = aggregates.VerticalEdges;
const ZIndex = aggregates.ZIndex;
const Insets = aggregates.Insets;

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

pub fn height(input: ParserFnInput) ?ContentHeight {
    return genericParser(input, ContentHeight, "height", values.parse.lengthPercentageAuto);
}

pub fn minHeight(input: ParserFnInput) ?ContentHeight {
    return genericParser(input, ContentHeight, "min_height", values.parse.lengthPercentage);
}

pub fn maxHeight(input: ParserFnInput) ?ContentHeight {
    return genericParser(input, ContentHeight, "max_height", values.parse.maxSize);
}

pub fn paddingLeft(input: ParserFnInput) ?HorizontalEdges {
    return genericParser(input, HorizontalEdges, "padding_left", values.parse.lengthPercentage);
}

pub fn paddingRight(input: ParserFnInput) ?HorizontalEdges {
    return genericParser(input, HorizontalEdges, "padding_right", values.parse.lengthPercentage);
}

pub fn paddingTop(input: ParserFnInput) ?VerticalEdges {
    return genericParser(input, VerticalEdges, "padding_top", values.parse.lengthPercentage);
}

pub fn paddingBottom(input: ParserFnInput) ?VerticalEdges {
    return genericParser(input, VerticalEdges, "padding_bottom", values.parse.lengthPercentage);
}

pub fn borderLeftWidth(input: ParserFnInput) ?HorizontalEdges {
    return genericParser(input, HorizontalEdges, "border_left", values.parse.borderWidth);
}

pub fn borderRightWidth(input: ParserFnInput) ?HorizontalEdges {
    return genericParser(input, HorizontalEdges, "border_right", values.parse.borderWidth);
}

pub fn borderTopWidth(input: ParserFnInput) ?VerticalEdges {
    return genericParser(input, VerticalEdges, "border_top", values.parse.borderWidth);
}

pub fn borderBottomWidth(input: ParserFnInput) ?VerticalEdges {
    return genericParser(input, VerticalEdges, "border_bottom", values.parse.borderWidth);
}

pub fn marginLeft(input: ParserFnInput) ?HorizontalEdges {
    return genericParser(input, HorizontalEdges, "margin_left", values.parse.lengthPercentageAuto);
}

pub fn marginRight(input: ParserFnInput) ?HorizontalEdges {
    return genericParser(input, HorizontalEdges, "margin_right", values.parse.lengthPercentageAuto);
}

pub fn marginTop(input: ParserFnInput) ?VerticalEdges {
    return genericParser(input, VerticalEdges, "margin_top", values.parse.lengthPercentageAuto);
}

pub fn marginBottom(input: ParserFnInput) ?VerticalEdges {
    return genericParser(input, VerticalEdges, "margin_bottom", values.parse.lengthPercentageAuto);
}

pub fn left(input: ParserFnInput) ?Insets {
    return genericParser(input, Insets, "left", values.parse.lengthPercentageAuto);
}

pub fn right(input: ParserFnInput) ?Insets {
    return genericParser(input, Insets, "right", values.parse.lengthPercentageAuto);
}

pub fn top(input: ParserFnInput) ?Insets {
    return genericParser(input, Insets, "top", values.parse.lengthPercentageAuto);
}

pub fn bottom(input: ParserFnInput) ?Insets {
    return genericParser(input, Insets, "bottom", values.parse.lengthPercentageAuto);
}
