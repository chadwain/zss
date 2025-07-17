const zss = @import("zss.zig");
const Ast = zss.syntax.Ast;
const CascadedValues = zss.CascadedValues;
const TokenSource = zss.syntax.TokenSource;
const ValueContext = zss.values.parse.Context;

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

// TODO: rename to group
pub const aggregates = @import("property/aggregates.zig");
pub const parse = @import("property/parse.zig");
pub const Declarations = @import("property/Declarations.zig");

comptime {
    if (@import("builtin").is_test) {
        _ = parse;
        _ = Declarations;
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
    @"background-color",
    @"background-image",
    @"background-repeat",
    @"background-attachment",
    @"background-position",
    @"background-clip",
    @"background-origin",
    @"background-size",
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
            .all                      => .all,

            .display                  => nonShorthand(.box_style       , .display       ),
            .position                 => nonShorthand(.box_style       , .position      ),
            .float                    => nonShorthand(.box_style       , .float         ),
            .@"z-index"               => nonShorthand(.z_index         , .z_index       ),
            .width                    => nonShorthand(.content_width   , .width         ),
            .@"min-width"             => nonShorthand(.content_width   , .min_width     ),
            .@"max-width"             => nonShorthand(.content_width   , .max_width     ),
            .height                   => nonShorthand(.content_height  , .height        ),
            .@"min-height"            => nonShorthand(.content_height  , .min_height    ),
            .@"max-height"            => nonShorthand(.content_height  , .max_height    ),
            .@"padding-left"          => nonShorthand(.horizontal_edges, .padding_left  ),
            .@"padding-right"         => nonShorthand(.horizontal_edges, .padding_right ),
            .@"padding-top"           => nonShorthand(.vertical_edges  , .padding_top   ),
            .@"padding-bottom"        => nonShorthand(.vertical_edges  , .padding_bottom),
            .@"border-left-width"     => nonShorthand(.horizontal_edges, .border_left   ),
            .@"border-right-width"    => nonShorthand(.horizontal_edges, .border_right  ),
            .@"border-top-width"      => nonShorthand(.vertical_edges  , .border_top    ),
            .@"border-bottom-width"   => nonShorthand(.vertical_edges  , .border_bottom ),
            .@"margin-left"           => nonShorthand(.horizontal_edges, .margin_left   ),
            .@"margin-right"          => nonShorthand(.horizontal_edges, .margin_right  ),
            .@"margin-top"            => nonShorthand(.vertical_edges  , .margin_top    ),
            .@"margin-bottom"         => nonShorthand(.vertical_edges  , .margin_bottom ),
            .left                     => nonShorthand(.insets          , .left          ),
            .right                    => nonShorthand(.insets          , .right         ),
            .top                      => nonShorthand(.insets          , .top           ),
            .bottom                   => nonShorthand(.insets          , .bottom        ),
            .@"background-color"      => nonShorthand(.background_color, .color         ),
            .@"background-image"      => nonShorthand(.background      , .image         ),
            .@"background-repeat"     => nonShorthand(.background      , .repeat        ),
            .@"background-attachment" => nonShorthand(.background      , .attachment    ),
            .@"background-position"   => nonShorthand(.background      , .position      ),
            .@"background-clip"       => nonShorthand(.background_clip , .clip          ),
            .@"background-origin"     => nonShorthand(.background      , .origin        ),
            .@"background-size"       => nonShorthand(.background      , .size          ),
            .color                    => nonShorthand(.color           , .color         ),
        };
        // zig fmt: on
    }

    fn nonShorthand(
        comptime aggregate_tag: aggregates.Tag,
        comptime field: @Type(.enum_literal),
    ) Description {
        return .{
            .non_shorthand = .{
                .aggregate_tag = aggregate_tag,
                .field = field,
            },
        };
    }

    pub fn DeclarationType(comptime property: Property) type {
        switch (property.description()) {
            .all => return zss.values.types.CssWideKeyword,
            .non_shorthand => |non_shorthand| {
                const tag = non_shorthand.aggregate_tag;
                const Field = tag.FieldType(non_shorthand.field);
                return StructWithOneField(
                    @tagName(tag),
                    StructWithOneField(
                        @tagName(non_shorthand.field),
                        switch (tag.size()) {
                            .single => aggregates.SingleValue(Field),
                            .multi => aggregates.MultiValue(Field),
                        },
                    ),
                );
            },
        }
    }

    fn StructWithOneField(comptime field_name: [:0]const u8, comptime T: type) type {
        return @Type(.{ .@"struct" = .{
            .layout = .auto,
            .fields = &.{
                .{
                    .name = field_name,
                    .type = T,
                    .default_value_ptr = null,
                    .is_comptime = false,
                    .alignment = @alignOf(T),
                },
            },
            .decls = &.{},
            .is_tuple = false,
        } });
    }

    fn declaredValueFromCwk(comptime property: Property, cwk: zss.values.types.CssWideKeyword) property.DeclarationType() {
        var result: property.DeclarationType() = undefined;
        inline for (@typeInfo(property.DeclarationType()).@"struct".fields) |aggregate_field| {
            inline for (@typeInfo(aggregate_field.type).@"struct".fields) |value_field| {
                @field(@field(result, aggregate_field.name), value_field.name) = switch (cwk) {
                    .initial => .initial,
                    .inherit => .inherit,
                    .unset => .unset,
                };
            }
        }
        return result;
    }
};

pub const Importance = enum {
    normal,
    important,
};

// TODO: Pick a "smarter" number
// TODO: Consider just creating a buffer outselves instead of requiring the user to provide one
pub const recommended_buffer_size = Declarations.max_list_len * 10;

pub fn parseDeclarationsFromAst(
    decls: *Declarations,
    /// The allocator for `decls`.
    allocator: Allocator,
    value_ctx: *ValueContext,
    /// A byte buffer that will be used for temporary dynamic allocations.
    /// See also: `recommended_buffer_size`.
    buffer: []u8,
    /// The last declaration in a list of declarations, or 0 if the list is empty.
    last_declaration_index: Ast.Size,
) !Declarations.Block {
    var fba = std.heap.FixedBufferAllocator.init(buffer);
    const block = try decls.openBlock(allocator);

    // We parse declarations in the reverse order in which they appear.
    // This is because later declarations will override previous ones.
    var index = last_declaration_index;
    while (index != 0) {
        const importance: Importance = switch (value_ctx.ast.tag(index)) {
            .declaration_important => .important,
            .declaration_normal => .normal,
            else => unreachable,
        };
        try parseDeclaration(decls, allocator, value_ctx, &fba, index, importance);
        index = value_ctx.ast.extra(index).index;
    }

    decls.closeBlock();
    return block;
}

fn parseDeclaration(
    decls: *Declarations,
    allocator: Allocator,
    value_ctx: *ValueContext,
    fba: *std.heap.FixedBufferAllocator,
    declaration_index: Ast.Size,
    importance: Importance,
) !void {
    // TODO: If this property has already been declared, skip parsing a value entirely.
    const location = value_ctx.ast.location(declaration_index);
    const property = value_ctx.token_source.matchIdentifierEnum(location, Property) orelse {
        // TODO: don't heap allocate
        const name_string = value_ctx.token_source.copyIdentifier(value_ctx.ast.location(declaration_index), allocator) catch return;
        defer allocator.free(name_string);
        zss.log.warn("Ignoring declaration with unrecognized name: {s}", .{name_string});
        return;
    };
    value_ctx.sequence = value_ctx.ast.children(declaration_index);

    switch (property) {
        inline else => |comptime_property| {
            switch (comptime comptime_property.description()) {
                .all => {
                    const cwk = zss.values.parse.cssWideKeyword(value_ctx) orelse return;
                    if (!value_ctx.sequence.empty()) {
                        return;
                    }
                    decls.addAll(importance, cwk);
                },
                .non_shorthand => |non_shorthand| {
                    const parseFn = @field(parse, @tagName(comptime_property));
                    const parsed_value_optional = switch (comptime non_shorthand.aggregate_tag.size()) {
                        .single => parseFn(value_ctx),
                        .multi => parseFn(value_ctx, fba) catch |err| switch (err) {
                            error.OutOfMemory => return error.OutOfBufferSpace,
                            else => |e| return e,
                        },
                    };

                    const parsed_value = if (parsed_value_optional) |parsed_value|
                        parsed_value
                    else if (zss.values.parse.cssWideKeyword(value_ctx)) |cwk|
                        comptime_property.declaredValueFromCwk(cwk)
                    else
                        return;

                    if (!value_ctx.sequence.empty()) {
                        return;
                    }

                    try decls.addValues(allocator, importance, parsed_value);
                },
            }
        },
    }
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

    const rule_list: Ast.Size = 0;
    std.debug.assert(ast.tag(rule_list) == .rule_list);
    var rules = ast.children(rule_list);
    const qualified_rule = rules.nextSkipSpaces(ast).?;
    std.debug.assert(ast.tag(qualified_rule) == .qualified_rule);
    const style_block = ast.extra(qualified_rule).index;
    std.debug.assert(ast.tag(style_block) == .style_block);
    const last_declaration = ast.extra(style_block).index;

    const ns = struct {
        fn expectEqual(
            comptime aggregate_tag: aggregates.Tag,
            decls: *const Declarations,
            block: Declarations.Block,
            expected: aggregate_tag.DeclaredValues(),
        ) !void {
            const meta = decls.getMeta(block);
            const Values = aggregate_tag.DeclaredValues();
            var values = Values{};
            decls.apply(aggregate_tag, block, .normal, meta, &values);

            inline for (std.meta.fields(Values)) |field| {
                const expected_field = @field(expected, field.name);
                const actual_field = @field(values, field.name);
                try actual_field.expectEqual(expected_field);
            }
        }
    };

    var decls = Declarations{};
    defer decls.deinit(allocator);

    var value_ctx = ValueContext.init(ast, source);
    var buffer: [recommended_buffer_size]u8 = undefined;
    const block = try parseDeclarationsFromAst(&decls, allocator, &value_ctx, &buffer, last_declaration);

    try ns.expectEqual(.box_style, &decls, block, .{
        .display = .{ .declared = .@"inline" },
        .position = .{ .declared = .relative },
        .float = .{ .declared = .none },
    });

    try ns.expectEqual(.content_width, &decls, block, .{
        .width = .{ .declared = .auto },
        .min_width = .{ .declared = .{ .percentage = 7 } },
        .max_width = .{ .declared = .none },
    });

    try ns.expectEqual(.content_height, &decls, block, .{
        .height = .{ .declared = .{ .percentage = 10 } },
        .min_height = .unset,
        .max_height = .{ .declared = .none },
    });

    try ns.expectEqual(.horizontal_edges, &decls, block, .{
        .padding_left = .unset,
        .padding_right = .{ .declared = .{ .px = 0 } },
        .border_left = .{ .declared = .{ .px = 100 } },
        .border_right = .{ .declared = .thin },
        .margin_left = .{ .declared = .auto },
        .margin_right = .unset,
    });

    try ns.expectEqual(.vertical_edges, &decls, block, .{
        .padding_top = .unset,
        .padding_bottom = .{ .declared = .{ .px = -7 } },
        .border_top = .{ .declared = .medium },
        .border_bottom = .{ .declared = .thick },
        .margin_top = .{ .declared = .{ .px = 0 } },
        .margin_bottom = .{ .declared = .{ .px = 0 } },
    });

    try ns.expectEqual(.insets, &decls, block, .{
        .left = .{ .declared = .auto },
        .right = .{ .declared = .auto },
        .top = .{ .declared = .{ .px = 100 } },
        .bottom = .unset,
    });

    try ns.expectEqual(.background, &decls, block, .{
        .image = .{ .declared = &.{.none} },
        .repeat = .unset,
        .attachment = .unset,
        .position = .unset,
        .origin = .unset,
        .size = .unset,
    });
}
