const zss = @import("../../zss.zig");
const aggregates = zss.properties.aggregates;
const CssWideKeyword = zss.values.CssWideKeyword;
const ComponentTree = zss.syntax.ComponentTree;
const Environment = zss.Environment;
const ElementTree = Environment.ElementTree;
const ParserSource = zss.syntax.parse.Source;
const Specificity = zss.selectors.Specificity;

const std = @import("std");
const assert = std.debug.assert;
const panic = std.debug.panic;
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const AutoArrayHashMapUnmanaged = std.AutoArrayHashMapUnmanaged;
const MultiArrayList = std.MultiArrayList;

pub const parsers = @import("./parsers.zig");
pub const CascadedDeclarations = @import("./CascadedDeclarations.zig");

pub const ParsedDeclarations = struct {
    normal: CascadedDeclarations,
    important: CascadedDeclarations,

    pub fn deinit(decls: *ParsedDeclarations, allocator: Allocator) void {
        decls.normal.deinit(allocator);
        decls.important.deinit(allocator);
    }
};

pub fn parseStyleBlockDeclarations(
    allocator: Allocator,
    components: ComponentTree.Slice,
    parser_source: ParserSource,
    style_block: ComponentTree.Size,
) !ParsedDeclarations {
    assert(components.tag(style_block) == .style_block);

    var normal = CascadedDeclarations{};
    errdefer normal.deinit(allocator);
    var important = CascadedDeclarations{};
    errdefer important.deinit(allocator);

    var index = components.extra(style_block).index();
    while (index != 0) {
        defer index = components.extra(index).index();
        const destination = switch (components.tag(index)) {
            .declaration_important => &important,
            .declaration_normal => &normal,
            else => unreachable,
        };
        try parseDeclaration(destination, allocator, components, parser_source, index);
    }

    // TODO: Sort the results according to cascade order?
    return ParsedDeclarations{ .normal = normal, .important = important };
}

fn parseDeclaration(
    cascaded: *CascadedDeclarations,
    allocator: Allocator,
    components: ComponentTree.Slice,
    parser_source: ParserSource,
    declaration_index: ComponentTree.Size,
) !void {
    const declaration_name = parseDeclarationName(components, parser_source, declaration_index) orelse return;
    if (declaration_name == .all) {
        return parseAllDeclaration(cascaded, components, parser_source, declaration_index);
    } else if (cascaded.all != .undeclared) {
        return;
    }

    const declaration_end = components.nextSibling(declaration_index);
    const css_wide_keyword = parseCssWideKeyword(components, parser_source, declaration_index, declaration_end);

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
        inline .display, .position, .float => |comptime_tag| {
            const parserFn = comptime_tag.parserFn();
            const box_style = parserFn(input) orelse return;
            if (input == .source and (input.source.position != input.source.end)) return;
            try cascaded.setAggregate(allocator, .box_style, box_style);
        },
    }
}

fn parseAllDeclaration(
    cascaded: *CascadedDeclarations,
    components: ComponentTree.Slice,
    parser_source: ParserSource,
    declaration_index: ComponentTree.Size,
) void {
    const declaration_end = components.nextSibling(declaration_index);
    const css_wide_keyword = parseCssWideKeyword(components, parser_source, declaration_index, declaration_end) orelse return;
    css_wide_keyword.apply(.{&cascaded.all});
}

const DeclarationName = enum {
    all,
    display,
    position,
    float,

    fn ParserFnReturnType(comptime name: DeclarationName) type {
        return switch (name) {
            .all => @compileError("'parserFnReturnType' not valid with argument 'all'"),
            .display, .position, .float => aggregates.BoxStyle,
        };
    }

    fn parserFn(comptime name: DeclarationName) fn (parsers.ParserFnInput) ?ParserFnReturnType(name) {
        return switch (name) {
            .all => @compileError("'parserFn' not valid with argument 'all'"),
            .display => parsers.display,
            .position => parsers.position,
            .float => parsers.float,
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
    });
}

fn parseCssWideKeyword(
    components: zss.syntax.ComponentTree.Slice,
    parser_source: zss.syntax.parse.Source,
    declaration_index: ComponentTree.Size,
    declaration_end: ComponentTree.Size,
) ?CssWideKeyword {
    if (declaration_end - declaration_index == 2) {
        if (components.tag(declaration_index + 1) == .token_ident) {
            const location = components.location(declaration_index + 1);
            return parser_source.mapIdentifier(location, CssWideKeyword, &.{
                .{ "initial", .initial },
                .{ "inherit", .inherit },
                .{ "unset", .unset },
            });
        }
    }
    return null;
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
    var decls = try parseStyleBlockDeclarations(allocator, slice, source, style_block);
    defer decls.deinit(allocator);

    const expectEqual = std.testing.expectEqual;
    const values = zss.values;
    try expectEqual(values.All.unset, decls.normal.all);
    const box_style_declared_values = decls.normal.get(.box_style).?;
    try expectEqual(values.Display.inline_, box_style_declared_values.display);
    try expectEqual(values.Position.relative, box_style_declared_values.position);
    try expectEqual(values.Float.none, box_style_declared_values.float);
}

pub const ValueReference = struct {
    stylesheet_index: usize,
    style_rule_index: usize,
};

pub const DeclaredValues = []ValueReference;

/// Gets all declared values for an element.
pub fn getDeclaredValues(
    env: *const Environment,
    tree: ElementTree.Slice,
    element: ElementTree.Element,
    allocator: Allocator,
) !DeclaredValues {
    if (env.stylesheets.items.len == 0) return .{};
    if (env.stylesheets.items.len > 1) panic("TODO: getDeclaredValues: Can only handle one stylesheet", .{});

    var refs = ArrayListUnmanaged(ValueReference){};
    errdefer refs.deinit(allocator);

    // Determines the order for values that have the same precedence in the cascade (i.e. they have the same origin, specificity, etc.).
    const ValuePrecedence = struct {
        specificity: Specificity,
        important: bool,
    };

    var precedences = MultiArrayList(ValuePrecedence){};
    defer precedences.deinit(allocator);

    const stylesheet_index: usize = 0;
    const rules = env.stylesheets.items[stylesheet_index].rules.slice();
    for (rules.items(.selector), rules.items(.declarations), 0..) |selector, declarations, i| {
        const specificity = selector.matchElement(tree, element) orelse continue;

        const ref = ValueReference{
            .stylesheet_index = stylesheet_index,
            .style_rule_index = i,
        };

        var precendence = ValuePrecedence{
            .specificity = specificity,
            .important = undefined,
        };

        if (declarations.important.size() > 0) {
            precendence.important = true;
            try refs.append(allocator, ref);
            try precedences.append(allocator, precendence);
        }

        if (declarations.normal.size() > 0) {
            precendence.important = false;
            try refs.append(allocator, ref);
            try precedences.append(allocator, precendence);
        }
    }

    const result = try refs.toOwnedSlice(allocator);
    errdefer allocator.free(result);

    // Sort the declared values such that values that are of higher precedence in the cascade are earlier in the list.
    const SortContext = struct {
        refs: DeclaredValues,
        precedences: MultiArrayList(ValuePrecedence).Slice,

        pub fn swap(sc: @This(), a_index: usize, b_index: usize) void {
            std.mem.swap(ValueReference, &sc.refs.items[a_index], &sc.refs.items[b_index]);
            inline for (std.meta.fields(ValuePrecedence), 0..) |field_info, i| {
                const Field = std.meta.FieldEnum(ValuePrecedence);
                const field = @as(Field, @enumFromInt(i));
                const slice = sc.precedences.items(field);
                std.mem.swap(field_info.type, &slice[a_index], &slice[b_index]);
            }
        }

        pub fn lessThan(sc: @This(), a_index: usize, b_index: usize) bool {
            const left_important = sc.precedences.items(.important)[a_index];
            const right_important = sc.precedences.items(.important)[b_index];
            if (left_important != right_important) {
                return left_important;
            }

            const left_specificity = sc.precedences.items(.specificity)[a_index];
            const right_specificity = sc.precedences.items(.specificity)[b_index];
            switch (left_specificity.order(right_specificity)) {
                .lt => return false,
                .gt => return true,
                .eq => {},
            }

            return false;
        }
    };

    // Must be a stable sort.
    std.sort.insertionContext(0, refs.len, SortContext{ .refs = result, .precedences = precedences.slice() });

    return result;
}
