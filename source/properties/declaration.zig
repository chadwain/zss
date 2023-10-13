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

    fn aggregateTag(comptime name: DeclarationName) aggregates.Tag {
        return switch (name) {
            .all => @compileError("'aggregateTag' not valid with argument 'all'"),
            .display, .position, .float => .box_style,
            .z_index => .z_index,
        };
    }

    fn parseFn(comptime name: DeclarationName) fn (parsers.ParserFnInput) ?aggregateTag(name).Value() {
        return switch (name) {
            .all => @compileError("'parseFn' not valid with argument 'all'"),
            .display => parsers.display,
            .position => parsers.position,
            .float => parsers.float,
            .z_index => parsers.zIndex,
        };
    }
};

fn parseDeclarationName(
    components: zss.syntax.ComponentTree.Slice,
    parser_source: zss.syntax.parse.Source,
    declaration_index: ComponentTree.Size,
) ?DeclarationName {
    const location = components.location(declaration_index);
    return parser_source.mapIdentifier(location, DeclarationName, &.{
        .{ "all", .all },
        .{ "display", .display },
        .{ "position", .position },
        .{ "float", .float },
        .{ "z-index", .z_index },
    });
}

test {
    const allocator = std.testing.allocator;
    const input =
        \\test {
        \\  display: block;
        \\  all: unset;
        \\  display: inherit;
        \\  display: inline;
        \\  display: invalid;
        \\  unknown: inherit;
        \\  unknown: invalid;
        \\  position: relative;
        \\  position: neutral;
        \\  float: none;
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
    const box_style_declared_values = decls.normal.get(.box_style) orelse return error.TestFailure;
    try expectEqual(values.Display.inline_, box_style_declared_values.display);
    try expectEqual(values.Position.relative, box_style_declared_values.position);
    try expectEqual(values.Float.none, box_style_declared_values.float);
}
