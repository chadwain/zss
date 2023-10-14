const std = @import("std");

const zss = @import("../../zss.zig");
const values = zss.values;
const ComponentTree = zss.syntax.ComponentTree;
const ParserSource = zss.syntax.parse.Source;

/// A source of primitive CSS values.
pub const Source = struct {
    components: ComponentTree.Slice,
    parser_source: ParserSource,
    end: ComponentTree.Size,
    position: ComponentTree.Size,

    pub const PrimitiveType = union(enum) {
        keyword,
        integer: i32,
        invalid,
    };

    pub const Item = struct {
        position: ComponentTree.Size,
        type: PrimitiveType,
    };

    pub fn next(source: *Source) ?Item {
        if (source.position == source.end) return null;
        defer source.position = source.components.nextSibling(source.position);

        const @"type": PrimitiveType = switch (source.components.tag(source.position)) {
            .token_ident => .keyword,
            .token_integer => .{ .integer = source.components.extra(source.position).integer() },
            else => .invalid,
        };
        return Item{ .position = source.position, .type = @"type" };
    }

    /// Given that `position` belongs to a keyword value, map that keyword to the value given in `kvs`,
    /// using case-insensitive matching. If there was no match, null is returned.
    pub fn mapKeyword(source: Source, pos: ComponentTree.Size, comptime Type: type, kvs: []const ParserSource.KV(Type)) ?Type {
        const location = source.components.location(pos);
        return source.parser_source.mapIdentifier(location, Type, kvs);
    }
};

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
}

pub fn parseSingleKeyword(source: *Source, comptime Type: type, kvs: []const ParserSource.KV(Type)) ?Type {
    const keyword = source.next() orelse return null;
    if (keyword.type != .keyword) return null;
    return source.mapKeyword(keyword.position, Type, kvs);
}

pub fn cssWideKeyword(
    components: zss.syntax.ComponentTree.Slice,
    parser_source: zss.syntax.parse.Source,
    declaration_index: ComponentTree.Size,
    declaration_end: ComponentTree.Size,
) ?values.CssWideKeyword {
    if (declaration_end - declaration_index == 2) {
        if (components.tag(declaration_index + 1) == .token_ident) {
            const location = components.location(declaration_index + 1);
            return parser_source.mapIdentifier(location, values.CssWideKeyword, &.{
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
pub fn display(source: *Source) ?values.Display {
    return parseSingleKeyword(source, values.Display, &.{
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
pub fn position(source: *Source) ?values.Position {
    return parseSingleKeyword(source, values.Position, &.{
        .{ "static", .static },
        .{ "relative", .relative },
        .{ "absolute", .absolute },
        .{ "fixed", .fixed },
    });
}

// Spec: CSS 2.2
// left | right | none
pub fn float(source: *Source) ?values.Float {
    return parseSingleKeyword(source, values.Float, &.{
        .{ "left", .left },
        .{ "right", .right },
        .{ "none", .none },
    });
}

// Spec: CSS 2.2
// auto | <integer>
pub fn zIndex(source: *Source) ?values.ZIndex {
    const auto_or_int = source.next() orelse return null;
    switch (auto_or_int.type) {
        .integer => |integer| return values.ZIndex{ .integer = integer },
        .keyword => return source.mapKeyword(auto_or_int.position, values.ZIndex, &.{
            .{ "auto", .auto },
        }),
        else => return null,
    }
}
