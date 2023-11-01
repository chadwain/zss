const zss = @import("../../zss.zig");
const aggregates = zss.properties.aggregates;
const CascadedValues = zss.ElementTree.CascadedValues;
const ComponentTree = zss.syntax.ComponentTree;
const CssWideKeyword = zss.values.CssWideKeyword;
const ElementTree = Environment.ElementTree;
const Environment = zss.Environment;
const ParserSource = zss.syntax.parse.Source;
const Specificity = zss.selectors.Specificity;

const std = @import("std");
const assert = std.debug.assert;
const panic = std.debug.panic;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const AutoArrayHashMapUnmanaged = std.AutoArrayHashMapUnmanaged;
const MultiArrayList = std.MultiArrayList;

pub const parsers = @import("./parsers.zig");

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
    const declaration_name = parseDeclarationName(components, parser_source, declaration_index) orelse return;
    if (declaration_name == .all) {
        return parseAllDeclaration(cascaded, components, parser_source, declaration_index);
    }

    const declaration_end = components.nextSibling(declaration_index);
    const css_wide_keyword = zss.values.parse.cssWideKeyword(components, parser_source, declaration_index, declaration_end);

    var source: zss.values.parse.Source = undefined;
    var input: parsers.ParserFnInput = undefined;
    if (css_wide_keyword) |cwk| {
        input = .{ .css_wide_keyword = cwk };
    } else {
        source = .{ .components = components, .parser_source = parser_source, .position = declaration_index + 1, .end = declaration_end };
        input = .{ .source = &source };
    }

    switch (declaration_name) {
        .all => unreachable,
        inline else => |comptime_decl_name| {
            const aggregate_tag = comptime comptime_decl_name.aggregateTag();
            const parseFn = comptime_decl_name.parseFn();
            // TODO: If parsing fails, "reset" the arena
            const aggregate = parseFn(input) orelse return;
            if (input == .source and (input.source.position != input.source.end)) return;
            try cascaded.add(arena, aggregate_tag, aggregate);
        },
    }
}

fn parseAllDeclaration(
    cascaded: *CascadedValues,
    components: ComponentTree.Slice,
    parser_source: ParserSource,
    declaration_index: ComponentTree.Size,
) void {
    const declaration_end = components.nextSibling(declaration_index);
    const css_wide_keyword = zss.values.parse.cssWideKeyword(components, parser_source, declaration_index, declaration_end) orelse return;
    cascaded.all = css_wide_keyword;
}

const DeclarationName = enum {
    all,
    display,
    position,
    float,
    z_index,
    width,
    min_width,
    max_width,
    height,
    min_height,
    max_height,
    padding_left,
    padding_right,
    padding_top,
    padding_bottom,
    border_left_width,
    border_right_width,
    border_top_width,
    border_bottom_width,
    margin_left,
    margin_right,
    margin_top,
    margin_bottom,
    left,
    right,
    top,
    bottom,

    fn aggregateTag(comptime name: DeclarationName) aggregates.Tag {
        return switch (name) {
            .all => @compileError("'aggregateTag' not valid with argument 'all'"),
            .display, .position, .float => .box_style,
            .z_index => .z_index,
            .width, .min_width, .max_width => .content_width,
            .height, .min_height, .max_height => .content_height,
            .padding_left, .padding_right, .border_left_width, .border_right_width, .margin_left, .margin_right => .horizontal_edges,
            .padding_top, .padding_bottom, .border_top_width, .border_bottom_width, .margin_top, .margin_bottom => .vertical_edges,
            .left, .right, .top, .bottom => .insets,
        };
    }

    fn parseFn(comptime name: DeclarationName) fn (parsers.ParserFnInput) ?aggregateTag(name).Value() {
        return switch (name) {
            .all => @compileError("'parseFn' not valid with argument 'all'"),
            .display => parsers.display,
            .position => parsers.position,
            .float => parsers.float,
            .z_index => parsers.zIndex,
            .width => parsers.width,
            .min_width => parsers.minWidth,
            .max_width => parsers.maxWidth,
            .height => parsers.height,
            .min_height => parsers.minHeight,
            .max_height => parsers.maxHeight,
            .padding_left => parsers.paddingLeft,
            .padding_right => parsers.paddingRight,
            .padding_top => parsers.paddingTop,
            .padding_bottom => parsers.paddingBottom,
            .border_left_width => parsers.borderLeftWidth,
            .border_right_width => parsers.borderRightWidth,
            .border_top_width => parsers.borderTopWidth,
            .border_bottom_width => parsers.borderBottomWidth,
            .margin_left => parsers.marginLeft,
            .margin_right => parsers.marginRight,
            .margin_top => parsers.marginTop,
            .margin_bottom => parsers.marginBottom,
            .left => parsers.left,
            .right => parsers.right,
            .top => parsers.top,
            .bottom => parsers.bottom,
        };
    }
};

fn parseDeclarationName(
    components: zss.syntax.ComponentTree.Slice,
    parser_source: zss.syntax.parse.Source,
    declaration_index: ComponentTree.Size,
) ?DeclarationName {
    // NOTE: This is the "official" place where property names get mapped to an internal representation.
    const location = components.location(declaration_index);
    return parser_source.mapIdentifier(location, DeclarationName, &.{
        .{ "all", .all },
        .{ "display", .display },
        .{ "position", .position },
        .{ "float", .float },
        .{ "z-index", .z_index },
        .{ "width", .width },
        .{ "min-width", .min_width },
        .{ "max-width", .max_width },
        .{ "height", .height },
        .{ "min-height", .min_height },
        .{ "max-height", .max_height },
        .{ "padding-left", .padding_left },
        .{ "padding-right", .padding_right },
        .{ "padding-top", .padding_top },
        .{ "padding-bottom", .padding_bottom },
        .{ "border-left-width", .border_left_width },
        .{ "border-right-width", .border_right_width },
        .{ "border-top-width", .border_top_width },
        .{ "border-bottom-width", .border_bottom_width },
        .{ "margin-left", .margin_left },
        .{ "margin-right", .margin_right },
        .{ "margin-top", .margin_top },
        .{ "margin-bottom", .margin_bottom },
        .{ "left", .left },
        .{ "right", .right },
        .{ "top", .top },
        .{ "bottom", .bottom },
    });
}

test {
    const allocator = std.testing.allocator;
    const input =
        \\test {
        \\  all: unset;
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
    const values = zss.values;

    const all = decls.normal.all orelse return error.TestFailure;
    try expectEqual(values.CssWideKeyword.unset, all);

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
