const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const MultiArrayList = std.MultiArrayList;

const zss = @import("../zss.zig");
const syntax = zss.syntax;
const tokenize = syntax.tokenize;
const Ast = syntax.Ast;
const Component = syntax.Component;
const Extra = Component.Extra;
const Stack = zss.Stack;
const Token = syntax.Token;
const TokenSource = syntax.TokenSource;

pub const AstManaged = struct {
    components: MultiArrayList(Component) = .{},
    allocator: Allocator,

    pub fn deinit(ast: *AstManaged) void {
        ast.components.deinit(ast.allocator);
    }

    pub fn len(ast: *const AstManaged) Ast.Size {
        return @intCast(ast.components.len);
    }

    pub fn shrink(ast: *AstManaged, index: Ast.Size) void {
        ast.components.shrinkRetainingCapacity(index);
    }

    pub fn createComponent(ast: *AstManaged, component: Component) !Ast.Size {
        const index = ast.len();
        if (index == std.math.maxInt(Ast.Size)) return error.Overflow;
        try ast.components.append(ast.allocator, component);
        return index;
    }

    pub fn addBasicComponent(ast: *AstManaged, tag: Component.Tag, location: TokenSource.Location) !Ast.Size {
        return ast.addBasicComponentExtra(tag, location, .undef);
    }

    pub fn addBasicComponentExtra(ast: *AstManaged, tag: Component.Tag, location: TokenSource.Location, extra: Extra) !Ast.Size {
        const next_sibling = try std.math.add(Ast.Size, 1, ast.len());
        return ast.createComponent(.{
            .next_sibling = next_sibling,
            .tag = tag,
            .location = location,
            .extra = extra,
        });
    }

    pub fn addComplexComponent(ast: *AstManaged, tag: Component.Tag, location: TokenSource.Location) !Ast.Size {
        return ast.createComponent(.{
            .next_sibling = undefined,
            .tag = tag,
            .location = location,
            .extra = undefined,
        });
    }

    pub fn finishComplexComponent(ast: *AstManaged, component_index: Ast.Size) void {
        ast.finishComplexComponentExtra(component_index, .undef);
    }

    pub fn finishComplexComponentExtra(ast: *AstManaged, component_index: Ast.Size, extra: Extra) void {
        const next_sibling: Ast.Size = ast.len();
        ast.components.items(.next_sibling)[component_index] = next_sibling;
        ast.components.items(.extra)[component_index] = extra;
    }

    pub fn addToken(ast: *AstManaged, token: Token, location: TokenSource.Location) !Ast.Size {
        // zig fmt: off
        switch (token) {
            .token_delim      => |codepoint| return ast.addBasicComponentExtra(.token_delim,      location, .{ .codepoint = codepoint }),
            .token_integer    =>   |integer| return ast.addBasicComponentExtra(.token_integer,    location, .{ .integer = integer }),
            .token_number     =>    |number| return ast.addBasicComponentExtra(.token_number,     location, .{ .number = number }),
            .token_percentage =>    |number| return ast.addBasicComponentExtra(.token_percentage, location, .{ .number = number }),
            .token_dimension  => |dimension| return ast.addDimension(location, dimension),
            else              =>             return ast.addBasicComponent(token.cast(Component.Tag), location),
        }
        // zig fmt: on
    }

    pub fn addDimension(ast: *AstManaged, location: TokenSource.Location, dimension: Token.Dimension) !Ast.Size {
        const next_sibling = try std.math.add(Ast.Size, 2, ast.len());
        const dimension_index = try ast.createComponent(.{
            .next_sibling = next_sibling,
            .tag = .token_dimension,
            .location = location,
            .extra = .{ .number = dimension.number },
        });
        _ = try ast.createComponent(.{
            .next_sibling = next_sibling,
            .tag = .unit,
            .location = dimension.unit_location,
            .extra = .{ .unit = dimension.unit },
        });
        return dimension_index;
    }

    pub fn addZmlAttribute(ast: *AstManaged, main_location: TokenSource.Location, name_location: TokenSource.Location) !void {
        const next_sibling = try std.math.add(Ast.Size, 2, ast.len());
        _ = try ast.createComponent(.{
            .next_sibling = next_sibling,
            .tag = .zml_attribute,
            .location = main_location,
            .extra = .undef,
        });
        _ = try ast.createComponent(.{
            .next_sibling = next_sibling,
            .tag = .token_ident,
            .location = name_location,
            .extra = .undef,
        });
    }

    pub fn addZmlAttributeWithValue(
        ast: *AstManaged,
        main_location: TokenSource.Location,
        name_location: TokenSource.Location,
        value_tag: Component.Tag,
        value_location: TokenSource.Location,
    ) !void {
        const next_sibling = try std.math.add(Ast.Size, 3, ast.len());
        _ = try ast.createComponent(.{
            .next_sibling = next_sibling,
            .tag = .zml_attribute,
            .location = main_location,
            .extra = .undef,
        });
        _ = try ast.createComponent(.{
            .next_sibling = next_sibling - 1,
            .tag = .token_ident,
            .location = name_location,
            .extra = .undef,
        });
        _ = try ast.createComponent(.{
            .next_sibling = next_sibling,
            .tag = value_tag,
            .location = value_location,
            .extra = .undef,
        });
    }

    pub fn finishInlineStyleBlock(ast: *AstManaged, style_block_index: Ast.Size, last_declaration: Ast.Size) void {
        const next_sibling: Ast.Size = ast.len();
        ast.components.items(.next_sibling)[style_block_index] = next_sibling;
        ast.components.items(.extra)[style_block_index] = .{ .index = last_declaration };
    }

    pub fn addDeclaration(ast: *AstManaged, main_location: TokenSource.Location, previous_declaration: ?Ast.Size) !Ast.Size {
        return ast.createComponent(.{
            .next_sibling = undefined,
            .tag = undefined,
            .location = main_location,
            .extra = .{ .index = previous_declaration orelse 0 },
        });
    }

    pub fn finishDeclaration(ast: *AstManaged, token_source: TokenSource, declaration_index: Ast.Size, last_3: Last3NonWhitespaceComponents) bool {
        const components = ast.components.slice();
        const is_important = blk: {
            if (last_3.len < 2) break :blk false;
            const exclamation = last_3.components[1];
            const important_string = last_3.components[2];
            break :blk components.items(.tag)[exclamation] == .token_delim and
                components.items(.extra)[exclamation].codepoint == '!' and
                components.items(.tag)[important_string] == .token_ident and
                token_source.identifierEqlIgnoreCase(components.items(.location)[important_string], "important");
        };

        const tag: Component.Tag, const min_required_components: u2 = switch (is_important) {
            true => .{ .declaration_important, 3 },
            false => .{ .declaration_normal, 1 },
        };
        const is_empty_declaration = last_3.len < min_required_components;
        // TODO: If is_empty_declaration == true, then (declaration_index + 1) may not be the next sibling due to whitespace/comments
        const next_sibling = if (is_empty_declaration) declaration_index + 1 else blk: {
            const last_component = last_3.components[3 - min_required_components];
            break :blk components.items(.next_sibling)[last_component];
        };
        components.items(.tag)[declaration_index] = tag;
        components.items(.next_sibling)[declaration_index] = next_sibling;
        ast.shrink(next_sibling);
        return is_empty_declaration;
    }

    pub fn finishElement(ast: *AstManaged, element_index: Ast.Size, block_index: Ast.Size) void {
        const components = ast.components.slice();
        const next_sibling = ast.len();
        components.items(.next_sibling)[element_index] = next_sibling;
        components.items(.next_sibling)[block_index] = next_sibling;
    }
};

/// Helps to keep track of the last 3 non-whitespace components in a declaration's value.
/// This is used to trim whitespace and to detect "!important" at the end of a value.
pub const Last3NonWhitespaceComponents = struct {
    /// A queue of the indeces of the last 3 non-whitespace components.
    /// Note that this queue grows starting from the end (the newest component index will be at index 2).
    components: [3]Ast.Size = undefined,
    len: u2 = 0,

    pub fn append(last_3: *Last3NonWhitespaceComponents, component_index: Ast.Size) void {
        last_3.components[0] = last_3.components[1];
        last_3.components[1] = last_3.components[2];
        last_3.components[2] = component_index;
        last_3.len +|= 1;
    }
};

/// Creates an Ast with a root node with tag `rule_list`
/// Implements CSS Syntax Level 3 Section 9 "Parse a CSS stylesheet"
pub fn parseCssStylesheet(token_source: TokenSource, allocator: Allocator) !Ast {
    var managed = AstManaged{ .allocator = allocator };
    errdefer managed.deinit();

    var parser: Parser = .{ .token_source = token_source, .allocator = allocator };
    defer parser.deinit();

    const index = try consumeListOfRules(&parser, &managed, true);
    _ = index; // TODO: Return the index
    return .{ .components = managed.components.slice() };
}

/// Creates an Ast with a root node with tag `component_list`
/// Implements CSS Syntax Level 3 Section 5.3.10 "Parse a list of component values"
pub fn parseListOfComponentValues(token_source: TokenSource, allocator: Allocator) !Ast {
    var managed = AstManaged{ .allocator = allocator };
    errdefer managed.deinit();

    var parser: Parser = .{ .token_source = token_source, .allocator = allocator };
    defer parser.deinit();

    const index = try consumeListOfComponentValues(&parser, &managed);
    _ = index; // TODO: Return the index
    return .{ .components = managed.components.slice() };
}

const Parser = struct {
    rule_stack: Stack(Frame) = .{},
    token_source: TokenSource,
    allocator: Allocator,
    location: TokenSource.Location = @enumFromInt(0),

    const Frame = struct {
        index: Ast.Size,
        index_of_block: ?Ast.Size = null,
        is_style_rule: bool,
        index_of_last_declaration: Ast.Size = 0,
        discarded: bool = false,
    };

    fn deinit(parser: *Parser) void {
        parser.rule_stack.deinit(parser.allocator);
    }

    fn nextToken(parser: *Parser) !struct { Token, TokenSource.Location } {
        const location = parser.location;
        const token = try parser.token_source.next(&parser.location);
        return .{ token, location };
    }

    fn nextTokenSkipSpaces(parser: *Parser) !struct { Token, TokenSource.Location } {
        while (true) {
            const location = parser.location;
            const token = try parser.token_source.next(&parser.location);
            switch (token) {
                .token_whitespace, .token_comments => {},
                else => return .{ token, location },
            }
        }
    }

    fn skipSpaces(parser: *Parser) !void {
        // const start_location = parser.location;
        while (true) {
            const location = parser.location;
            const token = try parser.token_source.next(&parser.location);
            switch (token) {
                .token_whitespace, .token_comments => {},
                else => {
                    parser.location = location;
                    return;
                    // return parser.location != start_location;
                },
            }
        }
    }

    fn nextSimpleBlockToken(parser: *Parser, ending_tag: Component.Tag) !?struct { Token, TokenSource.Location } {
        const token, const location = try parser.nextToken();
        if (token.cast(Component.Tag) == ending_tag) {
            return null;
        } else if (token == .token_eof) {
            // NOTE: Parse error
            return null;
        } else {
            return .{ token, location };
        }
    }

    fn setLocation(parser: *Parser, location: TokenSource.Location) void {
        parser.location = location;
    }
};

fn loop(parser: *Parser, ast: *AstManaged) !void {
    while (parser.rule_stack.top) |*frame| {
        loopInner(parser, ast, frame) catch |err| switch (err) {
            error.ControlFlowSuspend => {},
            else => |e| return e,
        };
    }
}

fn loopInner(parser: *Parser, ast: *AstManaged, frame: *Parser.Frame) !void {
    try consumeQualifiedRule(parser, ast, frame);
    _ = parser.rule_stack.pop();
}

fn pushQualifiedRule(parser: *Parser, frame: Parser.Frame) !void {
    try parser.rule_stack.push(parser.allocator, frame);
    // This error forces the current stack frame being evaluated to stop executing.
    // This error will then be caught in the `loop` function.
    return error.ControlFlowSuspend;
}

fn consumeListOfRules(parser: *Parser, ast: *AstManaged, top_level: bool) !Ast.Size {
    const index = try ast.addComplexComponent(.rule_list, parser.location);

    while (true) {
        const token, const location = try parser.nextToken();
        switch (token) {
            .token_whitespace, .token_comments => {},
            .token_eof => break,
            .token_cdo, .token_cdc => {
                if (!top_level) {
                    parser.setLocation(location);
                    const rule_index = try ast.addComplexComponent(.qualified_rule, location);
                    parser.rule_stack.top = .{ .index = rule_index, .is_style_rule = top_level };
                    try loop(parser, ast);
                } // TODO: Handle else case
            },
            .token_at_keyword => |at_rule| try consumeAtRule(parser, ast, location, at_rule),
            else => {
                parser.setLocation(location);
                const rule_index = try ast.addComplexComponent(.qualified_rule, location);
                parser.rule_stack.top = .{ .index = rule_index, .is_style_rule = top_level };
                try loop(parser, ast);
            },
        }
    }

    ast.finishComplexComponent(index);
    return index;
}

fn consumeListOfComponentValues(parser: *Parser, ast: *AstManaged) !Ast.Size {
    const index = try ast.addComplexComponent(.component_list, parser.location);

    while (true) {
        const token, const location = try parser.nextToken();
        switch (token) {
            .token_eof => break,
            else => _ = try consumeComponentValue(parser, ast, token, location),
        }
    }

    ast.finishComplexComponent(index);
    return index;
}

fn consumeAtRule(parser: *Parser, ast: *AstManaged, main_location: TokenSource.Location, at_rule: ?Token.AtRule) !void {
    const index = try ast.addComplexComponent(.at_rule, main_location);
    while (true) {
        const token, const location = try parser.nextToken();
        switch (token) {
            .token_semicolon => break,
            .token_eof => break, // NOTE: Parse error
            .token_left_curly => {
                _ = try consumeComponentValue(parser, ast, .token_left_curly, location);
                break;
            },
            else => _ = try consumeComponentValue(parser, ast, token, location),
        }
    }
    ast.finishComplexComponentExtra(index, .{ .at_rule = at_rule });
}

fn consumeQualifiedRule(parser: *Parser, ast: *AstManaged, frame: *Parser.Frame) !void {
    if (frame.index_of_block == null) {
        try consumeQualifiedRulePrelude(parser, ast, frame);
        if (frame.discarded) return;
    }

    if (frame.index_of_block != null and frame.is_style_rule) {
        try consumeStyleBlockContents(parser, ast, frame);
        ast.finishComplexComponentExtra(frame.index_of_block.?, .{ .index = frame.index_of_last_declaration });
    }

    ast.finishComplexComponentExtra(frame.index, .{ .index = frame.index_of_block.? });
}

fn consumeQualifiedRulePrelude(parser: *Parser, ast: *AstManaged, frame: *Parser.Frame) !void {
    while (true) {
        const token, const location = try parser.nextToken();
        switch (token) {
            .token_eof => {
                // NOTE: Parse error
                frame.discarded = true;
                ast.shrink(frame.index); // TODO: Do not shrink the Ast
                return;
            },
            .token_left_curly => {
                frame.index_of_block = switch (frame.is_style_rule) {
                    false => try consumeComponentValue(parser, ast, .token_left_curly, location),
                    true => try ast.addComplexComponent(.style_block, location),
                };
                return;
            },
            else => _ = try consumeComponentValue(parser, ast, token, location),
        }
    }
}

fn consumeStyleBlockContents(parser: *Parser, ast: *AstManaged, frame: *Parser.Frame) !void {
    while (true) {
        const token, const location = (try parser.nextSimpleBlockToken(.token_right_curly)) orelse break;
        switch (token) {
            .token_whitespace, .token_comments, .token_semicolon => {},
            .token_at_keyword => |at_rule| try consumeAtRule(parser, ast, location, at_rule),
            .token_ident => {
                if (try consumeDeclaration(parser, ast, location, frame.index_of_last_declaration)) |decl_index| {
                    frame.index_of_last_declaration = decl_index;
                } else {
                    try seekToEndOfDeclaration(parser);
                }
            },
            else => {
                if (token == .token_delim and token.token_delim == '&') {
                    parser.setLocation(location);
                    const rule_index = try ast.addComplexComponent(.qualified_rule, location);
                    try pushQualifiedRule(parser, .{ .index = rule_index, .is_style_rule = false });
                } else {
                    // NOTE: Parse error
                    parser.setLocation(location);
                    try seekToEndOfDeclaration(parser);
                }
            },
        }
    }
}

fn seekToEndOfDeclaration(parser: *Parser) !void {
    while (true) {
        const token, const location = try parser.nextToken();
        switch (token) {
            .token_semicolon, .token_eof => break,
            .token_right_curly => {
                parser.setLocation(location);
                break;
            },
            else => try ignoreComponentValue(parser, token),
        }
    }
}

fn consumeDeclaration(
    parser: *Parser,
    ast: *AstManaged,
    name_location: TokenSource.Location,
    previous_declaration: Ast.Size,
) !?Ast.Size {
    const colon_token, const colon_location = try parser.nextTokenSkipSpaces();
    if (colon_token != .token_colon) {
        // NOTE: Parse error
        parser.setLocation(colon_location);
        return null;
    }

    const index = try ast.addDeclaration(name_location, previous_declaration);

    var last_3 = Last3NonWhitespaceComponents{};
    try parser.skipSpaces();
    while (true) {
        const token, const location = try parser.nextToken();
        switch (token) {
            .token_semicolon, .token_eof => break,
            .token_right_curly => break parser.setLocation(location),
            .token_whitespace, .token_comments => _ = try ast.addBasicComponent(token.cast(Component.Tag), location),
            else => {
                const component_index = try consumeComponentValue(parser, ast, token, location);
                last_3.append(component_index);
            },
        }
    }

    _ = ast.finishDeclaration(parser.token_source, index, last_3);
    return index;
}

fn consumeComponentValue(parser: *Parser, ast: *AstManaged, main_token: Token, main_location: TokenSource.Location) !Ast.Size {
    switch (main_token) {
        else => return ast.addToken(main_token, main_location),
        .token_left_curly, .token_left_square, .token_left_paren, .token_function => {
            const main_index = ast.len(); // TODO: Stop using ast.len()

            const allocator = parser.allocator;
            var block_stack = ArrayListUnmanaged(struct { ending_tag: Component.Tag, index: Ast.Size }){};
            defer block_stack.deinit(allocator);

            var token = main_token;
            var location = main_location;
            while (true) : (token, location = try parser.nextToken()) {
                switch (token) {
                    .token_left_curly, .token_left_square, .token_left_paren, .token_function => {
                        // zig fmt: off
                        const component_tag: Component.Tag, const ending_tag: Component.Tag = switch (token) {
                            .token_left_curly =>  .{ .simple_block_curly,  .token_right_curly  },
                            .token_left_square => .{ .simple_block_square, .token_right_square },
                            .token_left_paren =>  .{ .simple_block_paren,  .token_right_paren  },
                            .token_function =>    .{ .function,            .token_right_paren  },
                            else => unreachable,
                        };
                        // zig fmt: on

                        const index = try ast.addComplexComponent(component_tag, location);
                        try block_stack.append(allocator, .{ .ending_tag = ending_tag, .index = index });
                    },
                    .token_right_curly, .token_right_square, .token_right_paren => {
                        if (block_stack.items[block_stack.items.len - 1].ending_tag == token.cast(Component.Tag)) {
                            const index = block_stack.pop().?.index;
                            ast.finishComplexComponent(index);
                            if (block_stack.items.len == 0) break;
                        } // TODO: Handle else case
                    },
                    .token_eof => {
                        for (0..block_stack.items.len) |i| {
                            const index = block_stack.items[block_stack.items.len - 1 - i].index;
                            ast.finishComplexComponent(index);
                        }
                        break;
                    },
                    else => _ = try ast.addToken(token, location),
                }
            }

            return main_index;
        },
    }
}

// TODO: Component values should not be ignored
fn ignoreComponentValue(parser: *Parser, first_token: Token) !void {
    switch (first_token) {
        .token_left_curly, .token_left_square, .token_left_paren, .token_function => {},
        else => return,
    }

    const allocator = parser.allocator;
    var block_stack = ArrayListUnmanaged(Component.Tag){};
    defer block_stack.deinit(allocator);

    var token = first_token;
    while (true) : (token, _ = try parser.nextToken()) {
        switch (token) {
            .token_left_curly, .token_left_square, .token_left_paren, .token_function => {
                const ending_tag: Component.Tag = switch (token) {
                    .token_left_square => .token_right_square,
                    .token_left_curly => .token_right_curly,
                    .token_left_paren, .token_function => .token_right_paren,
                    else => unreachable,
                };
                try block_stack.append(allocator, ending_tag);
            },
            .token_right_curly, .token_right_square, .token_right_paren => {
                if (block_stack.items[block_stack.items.len - 1] == token.cast(Component.Tag)) {
                    _ = block_stack.pop();
                    if (block_stack.items.len == 0) return;
                }
            },
            .token_eof => return,
            else => {},
        }
    }
}

// TODO: write a fuzz test

test "parse a stylesheet" {
    const allocator = std.testing.allocator;
    const input =
        \\@charset "utf-8";
        \\@new-rule {}
        \\
        \\root {
        \\    prop: value;
        \\    prop2: func(abc) !important
        \\}
        \\
        \\other {}
        \\
        \\broken_rule
    ;
    const token_source = try TokenSource.init(input);

    var ast = try parseCssStylesheet(token_source, allocator);
    defer ast.deinit(allocator);

    const TestComponent = struct {
        next_sibling: Ast.Size,
        tag: Component.Tag,
        location: TokenSource.Location,
        extra: union(enum) {
            index: Ast.Size,
            codepoint: u21,
            integer: ?i32,
            number: ?f32,
            unit: ?Token.Unit,
            at_rule: ?Token.AtRule,

            const undef: @This() = .{ .index = 0 };
        },
    };

    // zig fmt: off
    const expecteds = [20]TestComponent{
        .{ .next_sibling = 20, .tag = .rule_list,             .location = @enumFromInt(0),  .extra = .undef               },
        .{ .next_sibling = 4,  .tag = .at_rule,               .location = @enumFromInt(0),  .extra = .{ .at_rule = null } },
        .{ .next_sibling = 3,  .tag = .token_whitespace,      .location = @enumFromInt(8),  .extra = .undef               },
        .{ .next_sibling = 4,  .tag = .token_string,          .location = @enumFromInt(9),  .extra = .undef               },
        .{ .next_sibling = 7,  .tag = .at_rule,               .location = @enumFromInt(18), .extra = .{ .at_rule = null } },
        .{ .next_sibling = 6,  .tag = .token_whitespace,      .location = @enumFromInt(27), .extra = .undef               },
        .{ .next_sibling = 7,  .tag = .simple_block_curly,    .location = @enumFromInt(28), .extra = .undef               },
        .{ .next_sibling = 16, .tag = .qualified_rule,        .location = @enumFromInt(32), .extra = .{ .index = 10 }     },
        .{ .next_sibling = 9,  .tag = .token_ident,           .location = @enumFromInt(32), .extra = .undef               },
        .{ .next_sibling = 10, .tag = .token_whitespace,      .location = @enumFromInt(36), .extra = .undef               },
        .{ .next_sibling = 16, .tag = .style_block,           .location = @enumFromInt(37), .extra = .{ .index = 13 }     },
        .{ .next_sibling = 13, .tag = .declaration_normal,    .location = @enumFromInt(43), .extra = .{ .index = 0 }      },
        .{ .next_sibling = 13, .tag = .token_ident,           .location = @enumFromInt(49), .extra = .undef               },
        .{ .next_sibling = 16, .tag = .declaration_important, .location = @enumFromInt(60), .extra = .{ .index = 11 }     },
        .{ .next_sibling = 16, .tag = .function,              .location = @enumFromInt(67), .extra = .undef               },
        .{ .next_sibling = 16, .tag = .token_ident,           .location = @enumFromInt(72), .extra = .undef               },
        .{ .next_sibling = 20, .tag = .qualified_rule,        .location = @enumFromInt(91), .extra = .{ .index = 19 }     },
        .{ .next_sibling = 18, .tag = .token_ident,           .location = @enumFromInt(91), .extra = .undef               },
        .{ .next_sibling = 19, .tag = .token_whitespace,      .location = @enumFromInt(96), .extra = .undef               },
        .{ .next_sibling = 20, .tag = .style_block,           .location = @enumFromInt(97), .extra = .{ .index = 0 }      },
    };
    // zig fmt: on

    if (expecteds.len != ast.components.len) return error.TestFailure;
    for (expecteds, 0..) |expected, i| {
        const actual = ast.components.get(@intCast(i));
        try std.testing.expectEqual(expected.next_sibling, actual.next_sibling);
        try std.testing.expectEqual(expected.tag, actual.tag);
        try std.testing.expectEqual(expected.location, actual.location);
        switch (expected.extra) {
            inline else => |value, tag| try std.testing.expectEqual(value, @field(actual.extra, @tagName(tag))),
        }
    }
}
