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

    var location: TokenSource.Location = @enumFromInt(0);
    const index = try managed.addComplexComponent(.rule_list, location);
    parser.stack.top = .{
        .index = index,
        .data = .{ .list_of_rules = .{ .top_level = true } },
    };
    try loop(&parser, &location, &managed);

    return .{ .components = managed.components.slice() };
}

/// Creates an Ast with a root node with tag `component_list`
/// Implements CSS Syntax Level 3 Section 5.3.10 "Parse a list of component values"
pub fn parseListOfComponentValues(token_source: TokenSource, allocator: Allocator) !Ast {
    var managed = AstManaged{ .allocator = allocator };
    errdefer managed.deinit();

    var parser: Parser = .{ .token_source = token_source, .allocator = allocator };
    defer parser.deinit();

    var location: TokenSource.Location = @enumFromInt(0);
    const index = try managed.addComplexComponent(.component_list, location);
    parser.stack.top = .{ .index = index, .data = .list_of_component_values };
    try loop(&parser, &location, &managed);

    return .{ .components = managed.components.slice() };
}

const Parser = struct {
    stack: Stack(Frame) = .{},
    token_source: TokenSource,
    allocator: Allocator,

    const Frame = struct {
        index: Ast.Size,
        data: Data,

        const Data = union(enum) {
            list_of_rules: ListOfRules,
            list_of_component_values,
            style_block: StyleBlock,
            declaration_value: DeclarationValue,
            qualified_rule: QualifiedRule,
            at_rule: AtRule,
            simple_block: SimpleBlock,
        };

        const ListOfRules = struct {
            top_level: bool,
        };

        const QualifiedRule = struct {
            index_of_block: ?Ast.Size = null,
            is_style_rule: bool,
        };

        const AtRule = struct {
            at_rule: ?Token.AtRule,
            parsed_block: bool = false,
        };

        const DeclarationValue = struct {
            last_3: Last3NonWhitespaceComponents = .{},
        };

        const StyleBlock = struct {
            index_of_last_declaration: Ast.Size = 0,
        };

        const SimpleBlock = struct {
            ending_tag: Component.Tag,
        };
    };

    fn deinit(parser: *Parser) void {
        parser.stack.deinit(parser.allocator);
    }

    fn pushFrame(parser: *Parser, frame: Frame) !void {
        try parser.stack.push(parser.allocator, frame);
        // This error forces the current stack frame being evaluated to stop executing.
        // This error will then be caught in the `loop` function.
        return error.ControlFlowSuspend;
    }

    /// `location` must be the location of a <function-token>.
    fn pushFunction(parser: *Parser, ast: *AstManaged, location: TokenSource.Location) !void {
        const index = try ast.addComplexComponent(.function, location);
        try parser.pushFrame(.{
            .index = index,
            .data = .{ .simple_block = .{ .ending_tag = .token_right_paren } },
        });
    }

    /// `location` must be the location of a <{-token>, <[-token>, or <(-token>.
    fn pushSimpleBlock(parser: *Parser, ast: *AstManaged, tag: Component.Tag, location: TokenSource.Location) !void {
        const component_tag: Component.Tag = switch (tag) {
            .token_left_curly => .simple_block_curly,
            .token_left_square => .simple_block_square,
            .token_left_paren => .simple_block_paren,
            else => unreachable,
        };
        const index = try ast.addComplexComponent(component_tag, location);
        try parser.pushFrame(.{
            .index = index,
            .data = .{ .simple_block = .{ .ending_tag = mirrorTag(tag) } },
        });
    }

    fn popComponent(parser: *Parser, ast: *AstManaged) void {
        const frame = parser.stack.pop();
        switch (frame.data) {
            .qualified_rule => unreachable, // use popQualifiedRule instead
            .at_rule => unreachable, // use popAtRule instead
            .style_block => unreachable, // use popStyleBlock instead
            .declaration_value => unreachable, // use popDeclarationValue instead
            else => {},
        }
        ast.finishComplexComponent(frame.index);
    }

    /// `location` must be the location of the first token of the at-rule (i.e. the <at-keyword-token>).
    /// To finish this component, use `popAtRule`.
    fn pushAtRule(parser: *Parser, ast: *AstManaged, at_rule: ?Token.AtRule, location: TokenSource.Location) !void {
        const index = try ast.addComplexComponent(.at_rule, location);
        try parser.pushFrame(.{ .index = index, .data = .{ .at_rule = .{ .at_rule = at_rule } } });
    }

    fn popAtRule(parser: *Parser, ast: *AstManaged) void {
        const frame = parser.stack.pop();
        ast.finishComplexComponentExtra(frame.index, .{ .at_rule = frame.data.at_rule.at_rule });
    }

    /// `location` must be the location of the first token of the qualified rule.
    /// To finish this component, use either `popQualifiedRule` or `discardQualifiedRule`.
    fn pushQualifiedRule(parser: *Parser, ast: *AstManaged, location: TokenSource.Location, is_style_rule: bool) !void {
        const index = try ast.addComplexComponent(.qualified_rule, location);
        try parser.pushFrame(.{ .index = index, .data = .{ .qualified_rule = .{ .is_style_rule = is_style_rule } } });
    }

    fn popQualifiedRule(parser: *Parser, ast: *AstManaged) void {
        const frame = parser.stack.pop();
        ast.finishComplexComponentExtra(frame.index, .{ .index = frame.data.qualified_rule.index_of_block.? });
    }

    fn discardQualifiedRule(parser: *Parser, ast: *AstManaged) void {
        const frame = parser.stack.pop();
        assert(frame.data == .qualified_rule);
        ast.shrink(frame.index);
    }

    /// `location` must be the location of a <{-token>.
    /// To finish this component, use `popStyleBlock`.
    fn pushStyleBlock(parser: *Parser, ast: *AstManaged, location: TokenSource.Location) !void {
        const index = try ast.addComplexComponent(.style_block, location);
        try parser.pushFrame(.{ .index = index, .data = .{ .style_block = .{} } });
    }

    fn popStyleBlock(parser: *Parser, ast: *AstManaged) void {
        const frame = parser.stack.pop();
        ast.finishComplexComponentExtra(frame.index, .{ .index = frame.data.style_block.index_of_last_declaration });
    }

    /// To finish this component, use `popDeclarationValue`.
    fn pushDeclarationValue(
        parser: *Parser,
        ast: *AstManaged,
        location: TokenSource.Location,
        style_block: *Frame.StyleBlock,
        previous_declaration: ?Ast.Size,
    ) !void {
        const index = try ast.addDeclaration(location, previous_declaration);
        style_block.index_of_last_declaration = index;
        try parser.pushFrame(.{ .index = index, .data = .{ .declaration_value = .{} } });
    }

    fn popDeclarationValue(parser: *Parser, ast: *AstManaged) void {
        const frame = parser.stack.pop();
        _ = ast.finishDeclaration(parser.token_source, frame.index, frame.data.declaration_value.last_3);
    }
};

fn nextSimpleBlockToken(parser: *Parser, location: *TokenSource.Location, ending_tag: Component.Tag) !?Token {
    const token = try parser.token_source.next(location);
    if (token.cast(Component.Tag) == ending_tag) {
        return null;
    } else if (token == .token_eof) {
        // NOTE: Parse error
        return null;
    } else {
        return token;
    }
}

fn loop(parser: *Parser, location: *TokenSource.Location, ast: *AstManaged) !void {
    while (parser.stack.top) |*frame| {
        // zig fmt: off
        const result = switch (frame.data) {
            // NOTE: `parser` and `&frame.data` alias
            .list_of_rules            =>     |*list_of_rules| consumeListOfRules(parser, location, ast, list_of_rules),
            .list_of_component_values =>                      consumeListOfComponentValues(parser, location, ast),
            .qualified_rule           =>    |*qualified_rule| consumeQualifiedRule(parser, location, ast, qualified_rule),
            .at_rule                  =>           |*at_rule| consumeAtRule(parser, location, ast, at_rule),
            .style_block              =>       |*style_block| consumeStyleBlockContents(parser, location, ast, style_block),
            .declaration_value        => |*declaration_value| consumeDeclarationValue(parser, location, ast, declaration_value),
            .simple_block             =>      |*simple_block| consumeSimpleBlock(parser, location, ast, simple_block),
        };
        // zig fmt: on

        // TODO: Using errors for control flow like this leads to stupidly long error return traces...
        result catch |err| switch (err) {
            error.ControlFlowSuspend => {},
            else => |e| return e,
        };
    }
}

fn consumeListOfRules(parser: *Parser, location: *TokenSource.Location, ast: *AstManaged, data: *const Parser.Frame.ListOfRules) !void {
    while (true) {
        const saved_location = location.*;
        const token = try parser.token_source.next(location);
        switch (token) {
            .token_whitespace, .token_comments => {},
            .token_eof => return parser.popComponent(ast),
            .token_cdo, .token_cdc => {
                if (!data.top_level) {
                    location.* = saved_location;
                    try parser.pushQualifiedRule(ast, saved_location, false);
                    return;
                }
            },
            .token_at_keyword => |at_rule| {
                return parser.pushAtRule(ast, at_rule, saved_location);
            },
            else => {
                location.* = saved_location;
                return parser.pushQualifiedRule(ast, saved_location, data.top_level);
            },
        }
    }
}

fn consumeListOfComponentValues(parser: *Parser, location: *TokenSource.Location, ast: *AstManaged) !void {
    while (true) {
        const saved_location = location.*;
        const token = try parser.token_source.next(location);
        switch (token) {
            .token_eof => return parser.popComponent(ast),
            else => _ = try consumeComponentValue(parser, location, ast, token, saved_location),
        }
    }
}

fn consumeAtRule(parser: *Parser, location: *TokenSource.Location, ast: *AstManaged, data: *Parser.Frame.AtRule) !void {
    if (data.parsed_block) {
        parser.popAtRule(ast);
        return;
    }

    while (true) {
        const saved_location = location.*;
        const token = try parser.token_source.next(location);
        switch (token) {
            .token_semicolon => return parser.popAtRule(ast),
            .token_eof => {
                // NOTE: Parse error
                return parser.popAtRule(ast);
            },
            .token_left_curly => {
                data.parsed_block = true;
                return parser.pushSimpleBlock(ast, .token_left_curly, saved_location);
            },
            else => _ = try consumeComponentValue(parser, location, ast, token, saved_location),
        }
    }
}

fn consumeQualifiedRule(parser: *Parser, location: *TokenSource.Location, ast: *AstManaged, data: *Parser.Frame.QualifiedRule) !void {
    if (data.index_of_block != null) {
        parser.popQualifiedRule(ast);
        return;
    }

    while (true) {
        const saved_location = location.*;
        const token = try parser.token_source.next(location);
        switch (token) {
            .token_eof => {
                // NOTE: Parse error
                return parser.discardQualifiedRule(ast);
            },
            .token_left_curly => {
                data.index_of_block = ast.len();
                switch (data.is_style_rule) {
                    false => try parser.pushSimpleBlock(ast, .token_left_curly, saved_location),
                    true => try parser.pushStyleBlock(ast, saved_location),
                }
            },
            else => _ = try consumeComponentValue(parser, location, ast, token, saved_location),
        }
    }
}

fn consumeStyleBlockContents(parser: *Parser, location: *TokenSource.Location, ast: *AstManaged, data: *Parser.Frame.StyleBlock) !void {
    while (true) {
        const saved_location = location.*;
        const token = (try nextSimpleBlockToken(parser, location, .token_right_curly)) orelse {
            parser.popStyleBlock(ast);
            return;
        };
        switch (token) {
            .token_whitespace, .token_comments, .token_semicolon => {},
            .token_at_keyword => |at_rule| {
                try parser.pushAtRule(ast, at_rule, saved_location);
            },
            .token_ident => try consumeDeclarationStart(parser, location, ast, data, saved_location, data.index_of_last_declaration),
            else => {
                if (token == .token_delim and token.token_delim == '&') {
                    location.* = saved_location;
                    try parser.pushQualifiedRule(ast, saved_location, false);
                } else {
                    // NOTE: Parse error
                    location.* = saved_location;
                    try seekToEndOfDeclaration(parser, location);
                }
            },
        }
    }
}

fn seekToEndOfDeclaration(parser: *Parser, location: *TokenSource.Location) !void {
    while (true) {
        const saved_location = location.*;
        const token = try parser.token_source.next(location);
        switch (token) {
            .token_semicolon, .token_eof => break,
            .token_right_curly => {
                location.* = saved_location;
                break;
            },
            else => try ignoreComponentValue(parser, token, location),
        }
    }
}

/// If a declaration's start can be successfully parsed, this pushes a new frame onto the parser's stack.
fn consumeDeclarationStart(
    parser: *Parser,
    location: *TokenSource.Location,
    ast: *AstManaged,
    style_block: *Parser.Frame.StyleBlock,
    name_location: TokenSource.Location,
    previous_declaration: Ast.Size,
) !void {
    while (true) {
        const saved_location = location.*;
        const token = try parser.token_source.next(location);
        switch (token) {
            .token_whitespace, .token_comments => {},
            .token_colon => break,
            else => {
                // NOTE: Parse error
                location.* = saved_location;
                return;
            },
        }
    }

    while (true) {
        const saved_location = location.*;
        const token = try parser.token_source.next(location);
        switch (token) {
            .token_whitespace, .token_comments => {},
            else => {
                location.* = saved_location;
                try parser.pushDeclarationValue(ast, name_location, style_block, previous_declaration);
            },
        }
    }
}

fn consumeDeclarationValue(parser: *Parser, location: *TokenSource.Location, ast: *AstManaged, data: *Parser.Frame.DeclarationValue) !void {
    while (true) {
        const saved_location = location.*;
        const token = try parser.token_source.next(location);
        switch (token) {
            .token_semicolon, .token_eof => {
                parser.popDeclarationValue(ast);
                return;
            },
            .token_right_curly => {
                location.* = saved_location;
                parser.popDeclarationValue(ast);
                return;
            },
            .token_whitespace, .token_comments => {
                _ = try ast.addBasicComponent(token.cast(Component.Tag), saved_location);
            },
            else => {
                const component_index = try consumeComponentValue(parser, location, ast, token, saved_location);
                data.last_3.append(component_index);
            },
        }
    }
}

fn consumeComponentValue(parser: *Parser, location: *TokenSource.Location, ast: *AstManaged, main_token: Token, main_location: TokenSource.Location) !Ast.Size {
    switch (main_token) {
        else => return ast.addToken(main_token, main_location),
        .token_left_curly, .token_left_square, .token_left_paren, .token_function => {
            const main_index = ast.len();

            const allocator = parser.allocator;
            var block_stack = ArrayListUnmanaged(struct { Component.Tag, Ast.Size }){};
            defer block_stack.deinit(allocator);

            var token = main_token;
            var saved_location = main_location;
            while (true) : ({
                saved_location = location.*;
                token = try parser.token_source.next(location);
            }) {
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

                        const index = try ast.addComplexComponent(component_tag, saved_location);
                        try block_stack.append(allocator, .{ ending_tag, index });
                    },
                    .token_right_curly, .token_right_square, .token_right_paren => {
                        if (block_stack.items[block_stack.items.len - 1][0] == token.cast(Component.Tag)) {
                            _, const index = block_stack.pop().?;
                            ast.finishComplexComponent(index);
                            if (block_stack.items.len == 0) break;
                        }
                    },
                    .token_eof => {
                        for (0..block_stack.items.len) |i| {
                            _, const index = block_stack.items[block_stack.items.len - 1 - i];
                            ast.finishComplexComponent(index);
                        }
                        break;
                    },
                    else => _ = try ast.addToken(token, saved_location),
                }
            }

            return main_index;
        },
    }
}

fn ignoreComponentValue(parser: *Parser, first_token: Token, location: *TokenSource.Location) !void {
    switch (first_token) {
        .token_left_curly, .token_left_square, .token_left_paren, .token_function => {},
        else => return,
    }

    const allocator = parser.allocator;
    var block_stack = ArrayListUnmanaged(Component.Tag){};
    defer block_stack.deinit(allocator);

    var token = first_token;
    while (true) : (token = try parser.token_source.next(location)) {
        switch (token) {
            .token_left_curly, .token_left_square, .token_left_paren, .token_function => {
                try block_stack.append(allocator, mirrorTag(token.cast(Component.Tag)));
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

fn consumeSimpleBlock(parser: *Parser, location: *TokenSource.Location, ast: *AstManaged, data: *const Parser.Frame.SimpleBlock) !void {
    while (true) {
        const saved_location = location.*;
        const token = (try nextSimpleBlockToken(parser, location, data.ending_tag)) orelse {
            return parser.popComponent(ast);
        };
        _ = try consumeComponentValue(parser, location, ast, token, saved_location);
    }
}

/// Given a component that opens a block, return the component that would close the block.
fn mirrorTag(tag: Component.Tag) Component.Tag {
    return switch (tag) {
        .token_left_square => .token_right_square,
        .token_left_curly => .token_right_curly,
        .token_left_paren, .token_function => .token_right_paren,
        else => unreachable,
    };
}

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
