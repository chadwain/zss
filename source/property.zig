const zss = @import("zss.zig");
const groups = zss.values.groups;
const Ast = zss.syntax.Ast;
const CascadedValues = zss.CascadedValues;
const Declarations = zss.Declarations;
const Environment = zss.Environment;
const Importance = Declarations.Importance;
const SourceCode = zss.syntax.SourceCode;
const Urls = zss.values.parse.Urls;
const ValueContext = zss.values.parse.Context;

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

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
    padding,
    @"border-left-width",
    @"border-right-width",
    @"border-top-width",
    @"border-bottom-width",
    @"border-width",
    @"margin-left",
    @"margin-right",
    @"margin-top",
    @"margin-bottom",
    left,
    right,
    top,
    bottom,
    @"border-left-color",
    @"border-right-color",
    @"border-top-color",
    @"border-bottom-color",
    @"border-color",
    @"border-left-style",
    @"border-right-style",
    @"border-top-style",
    @"border-bottom-style",
    @"border-style",
    color,
    @"background-color",
    @"background-image",
    @"background-repeat",
    @"background-attachment",
    @"background-position",
    @"background-clip",
    @"background-origin",
    @"background-size",

    pub fn affectedFields(comptime property: Property) []const struct { groups.Tag, []const @Type(.enum_literal) } {
        // zig fmt: off
        return comptime switch (property) {
            .all                      => unreachable,

            .display                  => &.{.{.box_style       , &.{.display}       }},
            .position                 => &.{.{.box_style       , &.{.position}      }},
            .float                    => &.{.{.box_style       , &.{.float}         }},
            .@"z-index"               => &.{.{.z_index         , &.{.z_index}       }},
            .width                    => &.{.{.content_width   , &.{.width}         }},
            .@"min-width"             => &.{.{.content_width   , &.{.min_width}     }},
            .@"max-width"             => &.{.{.content_width   , &.{.max_width}     }},
            .height                   => &.{.{.content_height  , &.{.height}        }},
            .@"min-height"            => &.{.{.content_height  , &.{.min_height}    }},
            .@"max-height"            => &.{.{.content_height  , &.{.max_height}    }},
            .@"padding-left"          => &.{.{.horizontal_edges, &.{.padding_left}  }},
            .@"padding-right"         => &.{.{.horizontal_edges, &.{.padding_right} }},
            .@"padding-top"           => &.{.{.vertical_edges  , &.{.padding_top}   }},
            .@"padding-bottom"        => &.{.{.vertical_edges  , &.{.padding_bottom}}},
            .padding                  => &.{
                .{.horizontal_edges, &.{.padding_left, .padding_right}},
                .{.vertical_edges,   &.{.padding_top, .padding_bottom}},
            },
            .@"border-left-width"     => &.{.{.horizontal_edges, &.{.border_left}   }},
            .@"border-right-width"    => &.{.{.horizontal_edges, &.{.border_right}  }},
            .@"border-top-width"      => &.{.{.vertical_edges  , &.{.border_top}    }},
            .@"border-bottom-width"   => &.{.{.vertical_edges  , &.{.border_bottom} }},
            .@"border-width"          => &.{
                .{.horizontal_edges, &.{.border_left, .border_right}},
                .{.vertical_edges,   &.{.border_top, .border_bottom}},
            },
            .@"margin-left"           => &.{.{.horizontal_edges, &.{.margin_left}   }},
            .@"margin-right"          => &.{.{.horizontal_edges, &.{.margin_right}  }},
            .@"margin-top"            => &.{.{.vertical_edges  , &.{.margin_top}    }},
            .@"margin-bottom"         => &.{.{.vertical_edges  , &.{.margin_bottom} }},
            .left                     => &.{.{.insets          , &.{.left}          }},
            .right                    => &.{.{.insets          , &.{.right}         }},
            .top                      => &.{.{.insets          , &.{.top}           }},
            .bottom                   => &.{.{.insets          , &.{.bottom}        }},
            .@"border-left-color"     => &.{.{.border_colors   , &.{.left}          }},
            .@"border-right-color"    => &.{.{.border_colors   , &.{.right}         }},
            .@"border-top-color"      => &.{.{.border_colors   , &.{.top}           }},
            .@"border-bottom-color"   => &.{.{.border_colors   , &.{.bottom}        }},
            .@"border-color"          => &.{
                .{.border_colors, &.{.top, .right, .bottom, .left}},
            },
            .@"border-left-style"     => &.{.{.border_styles   , &.{.left}          }},
            .@"border-right-style"    => &.{.{.border_styles   , &.{.right}         }},
            .@"border-top-style"      => &.{.{.border_styles   , &.{.top}           }},
            .@"border-bottom-style"   => &.{.{.border_styles   , &.{.bottom}        }},
            .@"border-style"          => &.{
                .{.border_styles, &.{.top, .right, .bottom, .left}},
            },
            .color                    => &.{.{.color           , &.{.color}         }},
            .@"background-color"      => &.{.{.background_color, &.{.color}         }},
            .@"background-image"      => &.{.{.background      , &.{.image}         }},
            .@"background-repeat"     => &.{.{.background      , &.{.repeat}        }},
            .@"background-attachment" => &.{.{.background      , &.{.attachment}    }},
            .@"background-position"   => &.{.{.background      , &.{.position}      }},
            .@"background-clip"       => &.{.{.background_clip , &.{.clip}          }},
            .@"background-origin"     => &.{.{.background      , &.{.origin}        }},
            .@"background-size"       => &.{.{.background      , &.{.size}          }},
        };
        // zig fmt: on
    }

    pub fn ParseFnReturnType(comptime property: Property) type {
        const ns = struct {
            fn GroupFieldsStruct(comptime group: groups.Tag, field_tags: []const @Type(.enum_literal)) type {
                var fields: [field_tags.len]std.builtin.Type.StructField = undefined;
                for (&fields, field_tags) |*field, tag| {
                    const FieldType = group.FieldType(tag);
                    const Type = switch (group.size()) {
                        .single => groups.SingleValue(FieldType),
                        .multi => groups.MultiValue(FieldType),
                    };
                    const default: Type = .undeclared;
                    field.* = .{
                        .name = @tagName(tag),
                        .type = Type,
                        .alignment = @alignOf(Type),
                        .is_comptime = false,
                        .default_value_ptr = &default,
                    };
                }
                return @Type(.{ .@"struct" = .{
                    .layout = .auto,
                    .fields = &fields,
                    .decls = &.{},
                    .is_tuple = false,
                } });
            }
        };

        const affected_fields = property.affectedFields();
        var fields: [affected_fields.len]std.builtin.Type.StructField = undefined;
        for (&fields, affected_fields) |*field, group| {
            const Type = ns.GroupFieldsStruct(group[0], group[1]);
            field.* = .{
                .name = @tagName(group[0]),
                .type = Type,
                .alignment = @alignOf(Type),
                .is_comptime = false,
                .default_value_ptr = &Type{},
            };
        }
        return @Type(.{ .@"struct" = .{
            .layout = .auto,
            .fields = &fields,
            .decls = &.{},
            .is_tuple = false,
        } });
    }

    fn declaredValueFromCwk(comptime property: Property, cwk: zss.values.types.CssWideKeyword) property.ParseFnReturnType() {
        var result: property.ParseFnReturnType() = undefined;
        inline for (@typeInfo(property.ParseFnReturnType()).@"struct".fields) |group_field| {
            inline for (@typeInfo(group_field.type).@"struct".fields) |value_field| {
                @field(@field(result, group_field.name), value_field.name) = switch (cwk) {
                    .initial => .initial,
                    .inherit => .inherit,
                    .unset => .unset,
                };
            }
        }
        return result;
    }
};

// TODO: Pick a "smarter" number
// TODO: Consider just creating a buffer ourselves instead of requiring the user to provide one
pub const recommended_buffer_size = Declarations.max_list_len * 32;

pub fn parseDeclarationsFromAst(
    env: *Environment,
    ast: Ast,
    source_code: SourceCode,
    /// A byte buffer that will be used for temporary dynamic allocations.
    /// See also: `recommended_buffer_size`.
    buffer: []u8,
    /// The last declaration in a list of declarations, or 0 if the list is empty.
    last_declaration_index: Ast.Index,
    urls: Urls.Managed,
) !Declarations.Block {
    var ctx = ValueContext.init(ast, source_code);
    var fba = std.heap.FixedBufferAllocator.init(buffer);
    const block = try env.decls.openBlock(env.allocator);

    // We parse declarations in the reverse order in which they appear.
    // This is because later declarations will override previous ones.
    var index = last_declaration_index;
    while (@intFromEnum(index) != 0) {
        const importance: Importance = switch (index.tag(ast)) {
            .declaration_important => .important,
            .declaration_normal => .normal,
            else => unreachable,
        };
        try parseDeclaration(env, &ctx, &fba, urls, index, importance);
        index = index.extra(ast).index;
    }

    env.decls.closeBlock();
    return block;
}

fn parseDeclaration(
    env: *Environment,
    ctx: *ValueContext,
    fba: *std.heap.FixedBufferAllocator,
    urls: Urls.Managed,
    declaration_index: Ast.Index,
    importance: Importance,
) !void {
    // TODO: If this property has already been declared, skip parsing a value entirely.
    const location = declaration_index.location(ctx.ast);
    const property = ctx.source_code.mapIdentifierEnum(location, Property) orelse {
        zss.log.warn("Ignoring unsupported declaration: {f}", .{ctx.source_code.formatIdentToken(location)});
        return;
    };
    // zss.log.debug("Parsing declaration '{s}'", .{@tagName(property)});

    switch (property) {
        .all => {
            const cwk = parse.all(ctx, declaration_index) orelse return;
            env.decls.addAll(importance, cwk);
        },
        inline else => |comptime_property| {
            const parse_fn = @field(parse, @tagName(comptime_property));
            const value_or_null = switch (comptime std.meta.ArgsTuple(@TypeOf(parse_fn))) {
                struct { *ValueContext, Ast.Index } => parse_fn(ctx, declaration_index),
                struct { *ValueContext, Ast.Index, *std.heap.FixedBufferAllocator } => blk: {
                    fba.reset();
                    break :blk try parse_fn(ctx, declaration_index, fba);
                },
                struct { *ValueContext, Ast.Index, *std.heap.FixedBufferAllocator, Urls.Managed } => blk: {
                    fba.reset();
                    break :blk try parse_fn(ctx, declaration_index, fba, urls);
                },
                else => |T| @compileError(@typeName(T) ++ " is not a supported argument list for a property parser"),
            };

            const value = if (value_or_null) |parsed_value|
                parsed_value
            else if (parse.all(ctx, declaration_index)) |cwk|
                comptime_property.declaredValueFromCwk(cwk)
            else
                return;

            try env.decls.addValues(env.allocator, importance, value);
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
        \\
        \\  border-left-color: #ff000000;
        \\  border-right-color: #00ff0000;
        \\  border-top-color: #0000ff00;
        \\  border-bottom-color: #000000ff;
        \\
        \\  border-left-style: dotted;
        \\  border-right-style: dashed;
        \\  border-top-style: groove;
        \\  border-bottom-style: outset;
        \\}
    ;
    const source = try SourceCode.init(input);
    var ast, const rule_list_index = blk: {
        var parser = zss.syntax.Parser.init(source, allocator);
        defer parser.deinit();
        break :blk try parser.parseCssStylesheet(allocator);
    };
    defer ast.deinit(allocator);

    var rules = rule_list_index.children(ast);
    const qualified_rule = rules.nextSkipSpaces(ast).?;
    std.debug.assert(qualified_rule.tag(ast) == .qualified_rule);
    const style_block = qualified_rule.extra(ast).index;
    std.debug.assert(style_block.tag(ast) == .style_block);
    const last_declaration = style_block.extra(ast).index;

    const ns = struct {
        fn expectEqual(
            comptime group: groups.Tag,
            decls: *const Declarations,
            block: Declarations.Block,
            expected: group.DeclaredValues(),
        ) !void {
            const Values = group.DeclaredValues();
            var values = Values{};
            decls.apply(group, block, .normal, &values);

            inline for (std.meta.fields(Values)) |field| {
                const expected_field = @field(expected, field.name);
                const actual_field = @field(values, field.name);
                try actual_field.expectEqual(expected_field);
            }
        }
    };

    var env = zss.Environment.init(allocator, &.empty_document, .all_insensitive, .no_quirks);
    defer env.deinit();

    var urls = Urls.init(&env);
    defer urls.deinit(allocator);

    var buffer: [recommended_buffer_size]u8 = undefined;
    const block = try parseDeclarationsFromAst(&env, ast, source, &buffer, last_declaration, urls.toManaged(allocator));
    urls.commit(&env);

    try ns.expectEqual(.box_style, &env.decls, block, .{
        .display = .{ .declared = .@"inline" },
        .position = .{ .declared = .relative },
        .float = .{ .declared = .none },
    });

    try ns.expectEqual(.content_width, &env.decls, block, .{
        .width = .{ .declared = .auto },
        .min_width = .{ .declared = .{ .percentage = 0.07 } },
        .max_width = .{ .declared = .none },
    });

    try ns.expectEqual(.content_height, &env.decls, block, .{
        .height = .{ .declared = .{ .percentage = 0.1 } },
        .min_height = .unset,
        .max_height = .{ .declared = .none },
    });

    try ns.expectEqual(.horizontal_edges, &env.decls, block, .{
        .padding_left = .unset,
        .padding_right = .{ .declared = .{ .px = 0 } },
        .border_left = .{ .declared = .{ .px = 100 } },
        .border_right = .{ .declared = .thin },
        .margin_left = .{ .declared = .auto },
        .margin_right = .unset,
    });

    try ns.expectEqual(.vertical_edges, &env.decls, block, .{
        .padding_top = .unset,
        .padding_bottom = .{ .declared = .{ .px = -7 } },
        .border_top = .{ .declared = .medium },
        .border_bottom = .{ .declared = .thick },
        .margin_top = .{ .declared = .{ .px = 0 } },
        .margin_bottom = .{ .declared = .{ .px = 0 } },
    });

    try ns.expectEqual(.insets, &env.decls, block, .{
        .left = .{ .declared = .auto },
        .right = .{ .declared = .auto },
        .top = .{ .declared = .{ .px = 100 } },
        .bottom = .unset,
    });

    try ns.expectEqual(.background, &env.decls, block, .{
        .image = .{ .declared = &.{.none} },
        .repeat = .unset,
        .attachment = .unset,
        .position = .unset,
        .origin = .unset,
        .size = .unset,
    });

    try ns.expectEqual(.border_colors, &env.decls, block, .{
        .left = .{ .declared = .{ .rgba = 0xff000000 } },
        .right = .{ .declared = .{ .rgba = 0x00ff0000 } },
        .top = .{ .declared = .{ .rgba = 0x0000ff00 } },
        .bottom = .{ .declared = .{ .rgba = 0x000000ff } },
    });

    try ns.expectEqual(.border_styles, &env.decls, block, .{
        .left = .{ .declared = .dotted },
        .right = .{ .declared = .dashed },
        .top = .{ .declared = .groove },
        .bottom = .{ .declared = .outset },
    });
}
