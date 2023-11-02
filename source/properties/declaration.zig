const zss = @import("../../zss.zig");
const CascadedValues = zss.ElementTree.CascadedValues;
const ComponentTree = zss.syntax.ComponentTree;
const ParserSource = zss.syntax.parse.Source;
const PropertyName = zss.properties.definitions.PropertyName;

const std = @import("std");
const assert = std.debug.assert;
const ArenaAllocator = std.heap.ArenaAllocator;

pub const ParsedDeclarations = struct {
    normal: CascadedValues,
    important: CascadedValues,
};

pub fn parseStyleBlockDeclarations(
    arena: *ArenaAllocator,
    components: ComponentTree.Slice,
    parser_source: ParserSource,
    style_block: ComponentTree.Size,
) !ParsedDeclarations {
    assert(components.tag(style_block) == .style_block);

    var normal = CascadedValues{};
    // errdefer normal.deinit(allocator);
    var important = CascadedValues{};
    // errdefer important.deinit(allocator);

    // We parse declarations in the reverse order in which they appear.
    // This is because later declarations will overwrite previous ones.
    var index = components.extra(style_block).index();
    while (index != 0) {
        defer index = components.extra(index).index();
        const destination = switch (components.tag(index)) {
            .declaration_important => &important,
            .declaration_normal => &normal,
            else => unreachable,
        };
        try parseDeclaration(destination, arena, components, parser_source, index);
    }

    return ParsedDeclarations{ .normal = normal, .important = important };
}

fn parseDeclaration(
    cascaded: *CascadedValues,
    arena: *ArenaAllocator,
    components: ComponentTree.Slice,
    parser_source: ParserSource,
    declaration_index: ComponentTree.Size,
) !void {
    if (cascaded.all != null) return;

    // TODO: If this property has already been declared, skip parsing a value entirely.
    const property_name = parsePropertyName(components, parser_source, declaration_index) orelse return;
    const declaration_end = components.nextSibling(declaration_index);
    const css_wide_keyword = zss.values.parse.cssWideKeyword(components, parser_source, declaration_index, declaration_end);
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
                        var source = zss.values.parse.Source{
                            .components = components,
                            .parser_source = parser_source,
                            .position = declaration_index + 1,
                            .end = declaration_end,
                        };
                        // TODO: If parsing fails, "reset" the arena
                        const value = parseFn(&source) orelse return;
                        if (source.position != source.end) return;
                        try cascaded.addValue(arena, simple.aggregate_tag, simple.field, value);
                    }
                },
            }
        },
    }
}

fn parsePropertyName(
    components: ComponentTree.Slice,
    parser_source: ParserSource,
    declaration_index: ComponentTree.Size,
) ?PropertyName {
    const map = comptime blk: {
        const names = std.meta.fields(PropertyName);
        var result: [names.len]ParserSource.KV(PropertyName) = undefined;
        for (names, &result) |property_name, *entry| {
            entry.* = .{ property_name.name, @enumFromInt(property_name.value) };
        }
        break :blk &result;
    };
    const location = components.location(declaration_index);
    return parser_source.mapIdentifier(location, PropertyName, map);
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
        \\}
    ;
    const source = ParserSource.init(try zss.syntax.tokenize.Source.init(input));
    var components = try zss.syntax.parse.parseCssStylesheet(source, allocator);
    defer components.deinit(allocator);
    const slice = components.slice();

    const qualified_rule: ComponentTree.Size = 1;
    assert(slice.tag(qualified_rule) == .qualified_rule);
    const style_block = slice.extra(qualified_rule).index();
    assert(slice.tag(style_block) == .style_block);
    var arena = ArenaAllocator.init(allocator);
    defer arena.deinit();
    const decls = try parseStyleBlockDeclarations(&arena, slice, source, style_block);

    const expectEqual = std.testing.expectEqual;
    const aggregates = zss.properties.aggregates;

    const all = decls.normal.all orelse return error.TestFailure;
    try expectEqual(zss.values.types.CssWideKeyword.unset, all);

    const box_style = decls.normal.get(.box_style) orelse return error.TestFailure;
    try expectEqual(aggregates.BoxStyle{
        .display = .inline_,
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
}
