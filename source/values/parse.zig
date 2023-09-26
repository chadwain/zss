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

    pub const PrimitiveType = enum {
        keyword,
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

/// Spec: CSS 2.2
// 	inline | block | list-item | inline-block | table | inline-table | table-row-group | table-header-group
//  | table-footer-group | table-row | table-column-group | table-column | table-cell | table-caption | none
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

/// Spec: CSS 2.2
// static | relative | absolute | fixed
pub fn position(source: *Source) ?values.Position {
    return parseSingleKeyword(source, values.Position, &.{
        .{ "static", .static },
        .{ "relative", .relative },
        .{ "absolute", .absolute },
        .{ "fixed", .fixed },
    });
}

/// Spec: CSS 2.2
// left | right | none
pub fn float(source: *Source) ?values.Float {
    return parseSingleKeyword(source, values.Float, &.{
        .{ "left", .left },
        .{ "right", .right },
        .{ "none", .none },
    });
}
