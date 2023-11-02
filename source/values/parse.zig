const std = @import("std");

const zss = @import("../../zss.zig");
const types = zss.values.types;
const ComponentTree = zss.syntax.ComponentTree;
const ParserSource = zss.syntax.parse.Source;

/// A source of primitive CSS values.
pub const Source = struct {
    components: ComponentTree.Slice,
    parser_source: ParserSource,
    end: ComponentTree.Size,
    position: ComponentTree.Size,

    pub const Value = union(enum) {
        unknown,
        keyword: noreturn,
        integer: i32,
        percentage: f32,
        dimension: Dimension,

        pub const Dimension = struct { number: f32, unit_position: ComponentTree.Size };
    };

    pub const Type = std.meta.Tag(Value);

    pub const Item = struct {
        position: ComponentTree.Size,
        type: Type,
    };

    fn getType(source: *const Source, pos: ComponentTree.Size) Type {
        return switch (source.components.tag(pos)) {
            .token_ident => .keyword,
            .token_integer => .integer,
            .token_percentage => .percentage,
            .token_dimension => .dimension,
            else => .unknown,
        };
    }

    pub fn next(source: *Source) ?Item {
        if (source.position == source.end) return null;
        defer source.position = source.components.nextSibling(source.position);
        return Item{ .position = source.position, .type = source.getType(source.position) };
    }

    pub fn value(source: *const Source, comptime @"type": Type, pos: ComponentTree.Size) std.meta.fieldInfo(Value, @"type").type {
        std.debug.assert(source.getType(pos) == @"type");
        switch (comptime @"type") {
            .keyword => @compileError("use source.mapKeyword() instead"),
            .integer => return source.components.extra(pos).integer(),
            .percentage => return source.components.extra(pos).number(),
            .dimension => {
                const number = source.components.extra(pos).number();
                const unit_position = pos + 1;
                return Value.Dimension{ .number = number, .unit_position = unit_position };
            },
            .unknown => return {},
        }
    }

    /// Given that `position` belongs to a keyword value, map that keyword to the value given in `kvs`,
    /// using case-insensitive matching. If there was no match, null is returned.
    pub fn mapKeyword(source: Source, pos: ComponentTree.Size, comptime ResultType: type, kvs: []const ParserSource.KV(ResultType)) ?ResultType {
        std.debug.assert(source.getType(pos) == .keyword);
        const location = source.components.location(pos);
        return source.parser_source.mapIdentifier(location, ResultType, kvs);
    }
};

/// Maps a value type to the function that will be used to parse it.
pub fn typeToParseFn(comptime Type: type) fn (*Source) ?Type {
    return switch (Type) {
        types.Display => display,
        types.Position => position,
        types.Float => float,
        types.ZIndex => zIndex,
        types.LengthPercentage => lengthPercentage,
        types.LengthPercentageAuto => lengthPercentageAuto,
        types.BorderWidth => borderWidth,
        types.MaxSize => maxSize,
        else => @compileError("Unknown CSS value type: " ++ @typeName(Type)),
    };
}

fn testParsing(parseFn: anytype, input: []const u8, expected: @typeInfo(@TypeOf(parseFn)).Fn.return_type.?) !void {
    const allocator = std.testing.allocator;

    const parser_source = ParserSource.init(try zss.syntax.tokenize.Source.init(input));
    var tree = try zss.syntax.parse.parseListOfComponentValues(parser_source, allocator);
    defer tree.deinit(allocator);
    const slice = tree.slice();

    var source = Source{ .components = slice, .parser_source = parser_source, .end = slice.nextSibling(0), .position = 1 };
    const actual = parseFn(&source);
    try std.testing.expectEqual(source.end, source.position);
    try std.testing.expectEqual(actual, expected);
}

test "css value parsing" {
    try testParsing(display, "block", .block);
    try testParsing(display, "inline", .inline_);

    try testParsing(position, "static", .static);

    try testParsing(float, "left", .left);
    try testParsing(float, "right", .right);
    try testParsing(float, "none", .none);

    try testParsing(zIndex, "42", .{ .integer = 42 });
    try testParsing(zIndex, "-42", .{ .integer = -42 });
    try testParsing(zIndex, "auto", .auto);
    try testParsing(zIndex, "9999999999999999", .{ .integer = 0 });
    try testParsing(zIndex, "-9999999999999999", .{ .integer = 0 });

    try testParsing(lengthPercentage, "5px", .{ .px = 5 });
    try testParsing(lengthPercentage, "5%", .{ .percentage = 5 });
    try testParsing(lengthPercentage, "5", null);
    try testParsing(lengthPercentage, "auto", null);

    try testParsing(lengthPercentageAuto, "5px", .{ .px = 5 });
    try testParsing(lengthPercentageAuto, "5%", .{ .percentage = 5 });
    try testParsing(lengthPercentageAuto, "5", null);
    try testParsing(lengthPercentageAuto, "auto", .auto);

    try testParsing(maxSize, "5px", .{ .px = 5 });
    try testParsing(maxSize, "5%", .{ .percentage = 5 });
    try testParsing(maxSize, "5", null);
    try testParsing(maxSize, "auto", null);
    try testParsing(maxSize, "none", .none);

    try testParsing(borderWidth, "5px", .{ .px = 5 });
    try testParsing(borderWidth, "thin", .thin);
    try testParsing(borderWidth, "medium", .medium);
    try testParsing(borderWidth, "thick", .thick);
}

pub fn parseSingleKeyword(source: *Source, comptime Type: type, kvs: []const ParserSource.KV(Type)) ?Type {
    const keyword = source.next() orelse return null;
    if (keyword.type != .keyword) return null;
    return source.mapKeyword(keyword.position, Type, kvs);
}

pub fn length(source: *Source, dimension: Source.Value.Dimension, comptime Type: type) ?Type {
    const number = dimension.number;
    // TODO: consider using @unionInit()
    // TODO: Source.Value.Dimension should store its unit as an enum rather than a source location
    return source.mapKeyword(dimension.unit_position, Type, &.{
        .{ "px", .{ .px = number } },
    });
}

pub fn cssWideKeyword(
    components: zss.syntax.ComponentTree.Slice,
    parser_source: zss.syntax.parse.Source,
    declaration_index: ComponentTree.Size,
    declaration_end: ComponentTree.Size,
) ?types.CssWideKeyword {
    if (declaration_end - declaration_index == 2) {
        if (components.tag(declaration_index + 1) == .token_ident) {
            const location = components.location(declaration_index + 1);
            return parser_source.mapIdentifier(location, types.CssWideKeyword, &.{
                .{ "initial", .initial },
                .{ "inherit", .inherit },
                .{ "unset", .unset },
            });
        }
    }
    return null;
}

// Spec: CSS 2.2
// inline | block | list-item | inline-block | table | inline-table | table-row-group | table-header-group
// | table-footer-group | table-row | table-column-group | table-column | table-cell | table-caption | none
pub fn display(source: *Source) ?types.Display {
    return parseSingleKeyword(source, types.Display, &.{
        .{ "inline", .inline_ },
        .{ "block", .block },
        // .{ "list-item", .list_item },
        .{ "inline-block", .inline_block },
        // .{ "table", .table },
        // .{ "inline-table", .inline_table },
        // .{ "table-row-group", .table_row_group },
        // .{ "table-header-group", .table_header_group },
        // .{ "table-footer-group", .table_footer_group },
        // .{ "table-row", .table_row },
        // .{ "table-column-group", .table_column_group },
        // .{ "table-column", .table_column },
        // .{ "table-cell", .table_cell },
        // .{ "table-caption", .table_caption },
        .{ "none", .none },
    });
}

// Spec: CSS 2.2
// static | relative | absolute | fixed
pub fn position(source: *Source) ?types.Position {
    return parseSingleKeyword(source, types.Position, &.{
        .{ "static", .static },
        .{ "relative", .relative },
        .{ "absolute", .absolute },
        .{ "fixed", .fixed },
    });
}

// Spec: CSS 2.2
// left | right | none
pub fn float(source: *Source) ?types.Float {
    return parseSingleKeyword(source, types.Float, &.{
        .{ "left", .left },
        .{ "right", .right },
        .{ "none", .none },
    });
}

// Spec: CSS 2.2
// auto | <integer>
pub fn zIndex(source: *Source) ?types.ZIndex {
    const auto_or_int = source.next() orelse return null;
    switch (auto_or_int.type) {
        .integer => return types.ZIndex{ .integer = source.value(.integer, auto_or_int.position) },
        .keyword => return source.mapKeyword(auto_or_int.position, types.ZIndex, &.{
            .{ "auto", .auto },
        }),
        else => return null,
    }
}

// Spec: CSS 2.2
// <length> | <percentage>
pub fn lengthPercentage(source: *Source) ?types.LengthPercentage {
    const item = source.next() orelse return null;
    switch (item.type) {
        .dimension => return length(source, source.value(.dimension, item.position), types.LengthPercentage),
        .percentage => return .{ .percentage = source.value(.percentage, item.position) },
        else => return null,
    }
}

// Spec: CSS 2.2
// <length> | <percentage> | auto
pub fn lengthPercentageAuto(source: *Source) ?types.LengthPercentageAuto {
    const item = source.next() orelse return null;
    switch (item.type) {
        .dimension => return length(source, source.value(.dimension, item.position), types.LengthPercentageAuto),
        .percentage => return .{ .percentage = source.value(.percentage, item.position) },
        .keyword => return source.mapKeyword(item.position, types.LengthPercentageAuto, &.{
            .{ "auto", .auto },
        }),
        else => return null,
    }
}

// Spec: CSS 2.2
// <length> | <percentage> | none
pub fn maxSize(source: *Source) ?types.MaxSize {
    const item = source.next() orelse return null;
    switch (item.type) {
        .dimension => return length(source, source.value(.dimension, item.position), types.MaxSize),
        .percentage => return .{ .percentage = source.value(.percentage, item.position) },
        .keyword => return source.mapKeyword(item.position, types.MaxSize, &.{
            .{ "none", .none },
        }),
        else => return null,
    }
}

// Spec: CSS 2.2
// Syntax: <length> | thin | medium | thick
pub fn borderWidth(source: *Source) ?types.BorderWidth {
    const item = source.next() orelse return null;
    switch (item.type) {
        .dimension => return length(source, source.value(.dimension, item.position), types.BorderWidth),
        .keyword => return source.mapKeyword(item.position, types.BorderWidth, &.{
            .{ "thin", .thin },
            .{ "medium", .medium },
            .{ "thick", .thick },
        }),
        else => return null,
    }
}
