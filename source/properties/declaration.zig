const zss = @import("../zss.zig");
const Ast = zss.syntax.Ast;
const CascadedValues = zss.CascadedValues;
const TokenSource = zss.syntax.TokenSource;
const PropertyName = zss.properties.definitions.PropertyName;
const ValueSource = zss.values.parse.Source;

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

pub const ParsedDeclarations = struct {
    normal: CascadedValues,
    important: CascadedValues,
};

pub fn parseDeclarationsFromAst(
    value_source: *ValueSource,
    arena: *ArenaAllocator,
    /// The last declaration in a list of declarations, or 0 if the list is empty.
    last_declaration_index: Ast.Size,
) Allocator.Error!ParsedDeclarations {
    var normal = CascadedValues{};
    var important = CascadedValues{};

    // We parse declarations in the reverse order in which they appear.
    // This is because later declarations will overwrite previous ones.
    var index = last_declaration_index;
    while (index != 0) {
        const destination = switch (value_source.ast.tag(index)) {
            .declaration_important => &important,
            .declaration_normal => &normal,
            else => unreachable,
        };
        try parseDeclaration(destination, arena, value_source, index);
        index = value_source.ast.extra(index).index;
    }

    return ParsedDeclarations{ .normal = normal, .important = important };
}

fn parseDeclaration(
    cascaded: *CascadedValues,
    arena: *ArenaAllocator,
    value_source: *ValueSource,
    declaration_index: Ast.Size,
) !void {
    if (cascaded.all != null) return;

    // TODO: If this property has already been declared, skip parsing a value entirely.
    const property_name = parsePropertyName(value_source.ast, value_source.token_source, declaration_index) orelse {
        const name_string = value_source.token_source.copyIdentifier(value_source.ast.location(declaration_index), arena.allocator()) catch return;
        zss.log.warn("Ignoring declaration with unrecognized name: {s}", .{name_string});
        return;
    };
    const decl_value_sequence = value_source.ast.children(declaration_index);

    value_source.sequence = decl_value_sequence;
    const css_wide_keyword = blk: {
        const value = zss.values.parse.cssWideKeyword(value_source) orelse break :blk null;
        if (!value_source.sequence.empty()) break :blk null;
        break :blk value;
    };
    switch (property_name) {
        inline else => |comptime_property_name| {
            const def = comptime comptime_property_name.definition();
            switch (def) {
                .all => {
                    if (css_wide_keyword) |cwk| {
                        // `cascaded.all` was already checked to be null earlier
                        cascaded.all = cwk;
                    }
                },
                .simple => |simple| {
                    const Aggregate = simple.aggregate_tag.Value();
                    const field_info = comptime std.meta.fieldInfo(Aggregate, simple.field);

                    if (css_wide_keyword) |cwk| {
                        var value: field_info.type = undefined;
                        cwk.apply(.{&value});
                        try cascaded.addValue(arena, simple.aggregate_tag, simple.field, value);
                    } else {
                        const parseFn = zss.values.parse.typeToParseFn(field_info.type);
                        value_source.sequence = decl_value_sequence;
                        // TODO: If parsing fails, "reset" the arena
                        const value = parseFn(value_source) orelse return;
                        if (!value_source.sequence.empty()) return;
                        try cascaded.addValue(arena, simple.aggregate_tag, simple.field, value);
                    }
                },
            }
        },
    }
}

fn parsePropertyName(
    ast: Ast,
    token_source: TokenSource,
    declaration_index: Ast.Size,
) ?PropertyName {
    const map = comptime blk: {
        const names = std.meta.fields(PropertyName);
        var result: [names.len]TokenSource.KV(PropertyName) = undefined;
        for (names, &result) |property_name, *entry| {
            entry.* = .{ property_name.name, @enumFromInt(property_name.value) };
        }
        const const_result = result;
        break :blk &const_result;
    };
    const location = ast.location(declaration_index);
    return token_source.mapIdentifier(location, PropertyName, map);
}

test {
    const allocator = std.testing.allocator;
    const input =
        \\test {
        \\  all: unset;
        \\  all: initial inherit unset;
        \\
        \\  unknown: inherit;
        \\  unknown: invalid;
        \\
        \\  display: block;
        \\  display: inherit;
        \\  display: inline;
        \\  display: invalid;
        \\  position: relative;
        \\  position: neutral;
        \\  float: none;
        \\
        \\  width: 100px;
        \\  width: auto;
        \\  min-width: 7%;
        \\  max-width: none;
        \\  max-width: never;
        \\
        \\  height: 10%;
        \\  min-height: auto;
        \\  max-height: none;
        \\
        \\  padding-left: 0;
        \\  padding-right: 0px;
        \\  padding-top: -7;
        \\  padding-bottom: -7px;
        \\
        \\  border-left-width: 100px;
        \\  border-right-width: thin;
        \\  border-top-width: medium;
        \\  border-bottom-width: thick;
        \\
        \\  margin-left: auto;
        \\  margin-right: 100yards;
        \\  margin-top: 0px;
        \\  margin-bottom: 0px;
        \\
        \\  left: auto;
        \\  right: auto;
        \\  top: 100px;
        \\  bottom: unset;
        \\
        \\  background-image: url();
        \\  background-image: none;
        \\}
    ;
    const source = try TokenSource.init(input);
    var ast = try zss.syntax.parse.parseCssStylesheet(source, allocator);
    defer ast.deinit(allocator);

    const qualified_rule: Ast.Size = 1;
    assert(ast.tag(qualified_rule) == .qualified_rule);
    const style_block = ast.extra(qualified_rule).index;
    assert(ast.tag(style_block) == .style_block);
    const last_declaration = ast.extra(style_block).index;

    var arena = ArenaAllocator.init(allocator);
    defer arena.deinit();

    var value_source = ValueSource.init(ast, source, arena.allocator());
    const decls = try parseDeclarationsFromAst(&value_source, &arena, last_declaration);

    const expectEqual = std.testing.expectEqual;
    const aggregates = zss.properties.aggregates;

    const all = decls.normal.all orelse return error.TestFailure;
    try expectEqual(zss.values.types.CssWideKeyword.unset, all);

    const box_style = decls.normal.get(.box_style) orelse return error.TestFailure;
    try expectEqual(aggregates.BoxStyle{
        .display = .@"inline",
        .position = .relative,
        .float = .none,
    }, box_style);

    const content_width = decls.normal.get(.content_width) orelse return error.TestFailure;
    try expectEqual(aggregates.ContentWidth{
        .width = .auto,
        .min_width = .{ .percentage = 7 },
        .max_width = .none,
    }, content_width);

    const content_height = decls.normal.get(.content_height) orelse return error.TestFailure;
    try expectEqual(aggregates.ContentHeight{
        .height = .{ .percentage = 10 },
        .min_height = .undeclared,
        .max_height = .none,
    }, content_height);

    const horizontal_edges = decls.normal.get(.horizontal_edges) orelse return error.TestFailure;
    try expectEqual(aggregates.HorizontalEdges{
        .padding_left = .undeclared,
        .padding_right = .{ .px = 0 },
        .border_left = .{ .px = 100 },
        .border_right = .thin,
        .margin_left = .auto,
        .margin_right = .undeclared,
    }, horizontal_edges);

    const vertical_edges = decls.normal.get(.vertical_edges) orelse return error.TestFailure;
    try expectEqual(aggregates.VerticalEdges{
        .padding_top = .undeclared,
        .padding_bottom = .{ .px = -7 },
        .border_top = .medium,
        .border_bottom = .thick,
        .margin_top = .{ .px = 0 },
        .margin_bottom = .{ .px = 0 },
    }, vertical_edges);

    const insets = decls.normal.get(.insets) orelse return error.TestFailure;
    try expectEqual(aggregates.Insets{
        .left = .auto,
        .right = .auto,
        .top = .{ .px = 100 },
        .bottom = .unset,
    }, insets);

    const background2 = decls.normal.get(.background2) orelse return error.TestFailure;
    try expectEqual(aggregates.Background2{
        .image = .none,
    }, background2);
}
