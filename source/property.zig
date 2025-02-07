const zss = @import("zss.zig");
const Ast = zss.syntax.Ast;
const CascadedValues = zss.CascadedValues;
const TokenSource = zss.syntax.TokenSource;
const ValueContext = zss.values.parse.Context;

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

pub const aggregates = @import("property/aggregates.zig");
pub const parse = @import("property/parse.zig");

comptime {
    if (@import("builtin").is_test) {
        _ = parse;
    }
}

pub const Property = enum {
    all,

    display,
    position,
    float,
    @"z-index",
    width,
    @"min-width",
    @"max-width",
    height,
    @"min-height",
    @"max-height",
    @"padding-left",
    @"padding-right",
    @"padding-top",
    @"padding-bottom",
    @"border-left-width",
    @"border-right-width",
    @"border-top-width",
    @"border-bottom-width",
    @"margin-left",
    @"margin-right",
    @"margin-top",
    @"margin-bottom",
    left,
    right,
    top,
    bottom,
    @"background-image",
    color,

    pub const Description = union(enum) {
        all,
        non_shorthand: NonShorthand,

        pub const NonShorthand = struct {
            aggregate_tag: aggregates.Tag,
            field: @Type(.enum_literal),
        };
    };

    pub fn description(comptime property: Property) Description {
        // zig fmt: off
        return comptime switch (property) {
            .all                    => .all,

            .display                => nonShorthand(.box_style       , .display       ),
            .position               => nonShorthand(.box_style       , .position      ),
            .float                  => nonShorthand(.box_style       , .float         ),
            .@"z-index"             => nonShorthand(.z_index         , .z_index       ),
            .width                  => nonShorthand(.content_width   , .width         ),
            .@"min-width"           => nonShorthand(.content_width   , .min_width     ),
            .@"max-width"           => nonShorthand(.content_width   , .max_width     ),
            .height                 => nonShorthand(.content_height  , .height        ),
            .@"min-height"          => nonShorthand(.content_height  , .min_height    ),
            .@"max-height"          => nonShorthand(.content_height  , .max_height    ),
            .@"padding-left"        => nonShorthand(.horizontal_edges, .padding_left  ),
            .@"padding-right"       => nonShorthand(.horizontal_edges, .padding_right ),
            .@"padding-top"         => nonShorthand(.vertical_edges  , .padding_top   ),
            .@"padding-bottom"      => nonShorthand(.vertical_edges  , .padding_bottom),
            .@"border-left-width"   => nonShorthand(.horizontal_edges, .border_left   ),
            .@"border-right-width"  => nonShorthand(.horizontal_edges, .border_right  ),
            .@"border-top-width"    => nonShorthand(.vertical_edges  , .border_top    ),
            .@"border-bottom-width" => nonShorthand(.vertical_edges  , .border_bottom ),
            .@"margin-left"         => nonShorthand(.horizontal_edges, .margin_left   ),
            .@"margin-right"        => nonShorthand(.horizontal_edges, .margin_right  ),
            .@"margin-top"          => nonShorthand(.vertical_edges  , .margin_top    ),
            .@"margin-bottom"       => nonShorthand(.vertical_edges  , .margin_bottom ),
            .left                   => nonShorthand(.insets          , .left          ),
            .right                  => nonShorthand(.insets          , .right         ),
            .top                    => nonShorthand(.insets          , .top           ),
            .bottom                 => nonShorthand(.insets          , .bottom        ),
            .@"background-image"    => nonShorthand(.background2     , .image         ),
            .color                  => nonShorthand(.color           , .color         ),
        };
        // zig fmt: on
    }

    fn nonShorthand(comptime aggregate_tag: aggregates.Tag, comptime field: @Type(.enum_literal)) Description {
        return .{
            .non_shorthand = .{
                .aggregate_tag = aggregate_tag,
                .field = field,
            },
        };
    }
};

pub const ParsedDeclarations = struct {
    normal: CascadedValues,
    important: CascadedValues,
};

pub fn parseDeclarationsFromAst(
    value_ctx: *ValueContext,
    arena: *ArenaAllocator,
    /// The last declaration in a list of declarations, or 0 if the list is empty.
    last_declaration_index: Ast.Size,
) Allocator.Error!ParsedDeclarations {
    var normal = CascadedValues{};
    var important = CascadedValues{};

    // We parse declarations in the reverse order in which they appear.
    // This is because later declarations will override previous ones.
    var index = last_declaration_index;
    while (index != 0) {
        const destination = switch (value_ctx.ast.tag(index)) {
            .declaration_important => &important,
            .declaration_normal => &normal,
            else => unreachable,
        };
        try parseDeclaration(destination, arena, value_ctx, index);
        index = value_ctx.ast.extra(index).index;
    }

    return ParsedDeclarations{ .normal = normal, .important = important };
}

fn parseDeclaration(
    cascaded: *CascadedValues,
    arena: *ArenaAllocator,
    value_ctx: *ValueContext,
    declaration_index: Ast.Size,
) !void {
    if (cascaded.all != null) return;

    // TODO: If this property has already been declared, skip parsing a value entirely.
    const property = parsePropertyName(value_ctx.ast, value_ctx.token_source, declaration_index) orelse {
        const name_string = value_ctx.token_source.copyIdentifier(value_ctx.ast.location(declaration_index), arena.allocator()) catch return;
        zss.log.warn("Ignoring declaration with unrecognized name: {s}", .{name_string});
        return;
    };
    value_ctx.sequence = value_ctx.ast.children(declaration_index);

    switch (property) {
        inline else => |comptime_property| {
            switch (comptime comptime_property.description()) {
                .all => {
                    const cwk = zss.values.parse.cssWideKeyword(value_ctx) orelse return;
                    // `cascaded.all` was already checked to be null earlier, so it's okay to write this value.
                    cascaded.all = cwk;
                },
                .non_shorthand => |non_shorthand| {
                    // TODO: If parsing fails, "reset" the arena
                    const parsed_value = blk: {
                        const parseFn = @field(parse, @tagName(comptime_property));
                        if (parseFn(value_ctx)) |parsed_value| {
                            break :blk parsed_value;
                        } else {
                            const cwk = zss.values.parse.cssWideKeyword(value_ctx) orelse return;
                            const Aggregate = non_shorthand.aggregate_tag.Value();
                            var parsed_value: @FieldType(Aggregate, @tagName(non_shorthand.field)) = undefined;
                            cwk.apply(.{&parsed_value});
                            break :blk parsed_value;
                        }
                    };

                    if (!value_ctx.sequence.empty()) {
                        // TODO: `parsed_value` needs to be freed?
                        return;
                    }
                    try cascaded.addValue(arena, non_shorthand.aggregate_tag, non_shorthand.field, parsed_value);
                },
            }
        },
    }
}

fn parsePropertyName(
    ast: Ast,
    token_source: TokenSource,
    declaration_index: Ast.Size,
) ?Property {
    // TODO: Use syntax.tokenize.ComptimePrefixTree
    const map = comptime blk: {
        const fields = std.meta.fields(Property);
        var result: [fields.len]TokenSource.KV(Property) = undefined;
        for (fields, &result) |property, *entry| {
            entry.* = .{ property.name, @enumFromInt(property.value) };
        }
        const const_result = result;
        break :blk &const_result;
    };
    const location = ast.location(declaration_index);
    return token_source.mapIdentifier(location, Property, map);
}

test "parsing properties from a stylesheet" {
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
    std.debug.assert(ast.tag(qualified_rule) == .qualified_rule);
    const style_block = ast.extra(qualified_rule).index;
    std.debug.assert(ast.tag(style_block) == .style_block);
    const last_declaration = ast.extra(style_block).index;

    var arena = ArenaAllocator.init(allocator);
    defer arena.deinit();

    var value_ctx = ValueContext.init(ast, source, arena.allocator());
    const decls = try parseDeclarationsFromAst(&value_ctx, &arena, last_declaration);

    const expectEqual = std.testing.expectEqual;

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
