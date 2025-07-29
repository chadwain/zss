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
const Location = TokenSource.Location;
const Stack = zss.Stack;
const Token = syntax.Token;
const TokenSource = syntax.TokenSource;

const AstManaged = struct {
    components: MultiArrayList(Component) = .{},
    allocator: Allocator,

    fn deinit(ast: *AstManaged) void {
        ast.components.deinit(ast.allocator);
    }

    fn len(ast: *const AstManaged) Ast.Size {
        return @intCast(ast.components.len);
    }

    fn shrink(ast: *AstManaged, index: Ast.Size) void {
        ast.components.shrinkRetainingCapacity(index);
    }

    const AddComponentError = error{Overflow} || Allocator.Error;

    fn createComponent(ast: *AstManaged, component: Component) AddComponentError!Ast.Size {
        const index = ast.len();
        if (index == std.math.maxInt(Ast.Size)) return error.Overflow;
        try ast.components.append(ast.allocator, component);
        return index;
    }

    fn addBasicComponent(ast: *AstManaged, tag: Component.Tag, location: Location) !Ast.Size {
        return ast.addBasicComponentExtra(tag, location, .undef);
    }

    fn addBasicComponentExtra(ast: *AstManaged, tag: Component.Tag, location: Location, extra: Extra) !Ast.Size {
        const next_sibling = try std.math.add(Ast.Size, 1, ast.len());
        return ast.createComponent(.{
            .next_sibling = next_sibling,
            .tag = tag,
            .location = location,
            .extra = extra,
        });
    }

    fn addComplexComponent(ast: *AstManaged, tag: Component.Tag, location: Location) !Ast.Size {
        return ast.createComponent(.{
            .next_sibling = undefined,
            .tag = tag,
            .location = location,
            .extra = undefined,
        });
    }

    fn finishComplexComponent(ast: *AstManaged, component_index: Ast.Size) void {
        ast.finishComplexComponentExtra(component_index, .undef);
    }

    fn finishComplexComponentExtra(ast: *AstManaged, component_index: Ast.Size, extra: Extra) void {
        const next_sibling: Ast.Size = ast.len();
        ast.components.items(.next_sibling)[component_index] = next_sibling;
        ast.components.items(.extra)[component_index] = extra;
    }

    fn addToken(ast: *AstManaged, token: Token, location: Location) !Ast.Size {
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

    fn addDimension(ast: *AstManaged, location: Location, dimension: Token.Dimension) !Ast.Size {
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

    fn addZmlAttribute(ast: *AstManaged, main_location: Location, name_location: Location) !void {
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

    fn addZmlAttributeWithValue(
        ast: *AstManaged,
        main_location: Location,
        name_location: Location,
        value_tag: Component.Tag,
        value_location: Location,
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

    fn finishInlineStyleBlock(ast: *AstManaged, style_block_index: Ast.Size, last_declaration: Ast.Size) void {
        const next_sibling: Ast.Size = ast.len();
        ast.components.items(.next_sibling)[style_block_index] = next_sibling;
        ast.components.items(.extra)[style_block_index] = .{ .index = last_declaration };
    }

    fn addDeclaration(ast: *AstManaged, main_location: Location, previous_declaration: ?Ast.Size) !Ast.Size {
        return ast.createComponent(.{
            .next_sibling = undefined,
            .tag = undefined,
            .location = main_location,
            .extra = .{ .index = previous_declaration orelse 0 },
        });
    }

    fn finishDeclaration(ast: *AstManaged, token_source: TokenSource, declaration_index: Ast.Size, last_3: Last3NonWhitespaceComponents) bool {
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

    fn finishElement(ast: *AstManaged, element_index: Ast.Size, block_index: Ast.Size) void {
        const components = ast.components.slice();
        const next_sibling = ast.len();
        components.items(.next_sibling)[element_index] = next_sibling;
        components.items(.next_sibling)[block_index] = next_sibling;
    }
};

/// Helps to keep track of the last 3 non-whitespace components in a declaration's value.
/// This is used to trim whitespace and to detect "!important" at the end of a value.
const Last3NonWhitespaceComponents = struct {
    /// A queue of the indeces of the last 3 non-whitespace components.
    /// Note that this queue grows starting from the end (the newest component index will be at index 2).
    components: [3]Ast.Size = undefined,
    len: u2 = 0,

    fn append(last_3: *Last3NonWhitespaceComponents, component_index: Ast.Size) void {
        last_3.components[0] = last_3.components[1];
        last_3.components[1] = last_3.components[2];
        last_3.components[2] = component_index;
        last_3.len +|= 1;
    }
};

const DocumentType = enum { css, zml };

pub const Parser = struct {
    rule_stack: Stack(QualifiedRule),
    element_stack: ArrayListUnmanaged(struct { element_index: Ast.Size, block_index: Ast.Size }),
    block_stack: Stack(struct { ending_tag: Component.Tag, index: Ast.Size }),
    token_source: TokenSource,
    allocator: Allocator,
    location: Location,
    depth: u8,
    /// If parsing fails with `error.ParseError`, this will contain a more detailed error.
    /// Otherwise, this field is undefined.
    failure: Failure,

    const QualifiedRule = struct {
        index: Ast.Size,
        index_of_block: ?Ast.Size = null,
        is_style_rule: bool,
        index_of_last_declaration: ?Ast.Size = null,
        discarded: bool = false,
    };

    pub const Failure = struct {
        cause: Cause,
        location: Location,

        pub const Cause = enum {
            depth_limit_reached,
            element_with_no_features,
            empty_with_other_features,
            empty_declaration_value,
            empty_inline_style_block,
            expected_colon,
            expected_identifier,
            inline_style_block_before_features,
            invalid_feature,
            invalid_id,
            invalid_token,
            missing_space_between_features,
            multiple_types,
            multiple_inline_style_blocks,
            unexpected_eof,

            pub fn debugErrMsg(cause: Cause) []const u8 {
                return switch (cause) {
                    .depth_limit_reached => std.fmt.comptimePrint("depth limit of {} reached", .{depth_limit}),
                    .element_with_no_features => "element must have at least one feature",
                    .empty_with_other_features => "'*' cannot appear with other features",
                    .empty_declaration_value => "empty declaration value",
                    .empty_inline_style_block => "empty inline style block",
                    .expected_colon => "expected ':'",
                    .expected_identifier => "expected identifier",
                    .inline_style_block_before_features => "inline style block must appear after all features",
                    .invalid_feature => "invalid feature",
                    .invalid_id => "invalid id (not a valid CSS identifier)",
                    .invalid_token => "invalid token",
                    .missing_space_between_features => "features must be separated with whitespace or comments",
                    .multiple_types => "only one type feature is allowed on an element",
                    .multiple_inline_style_blocks => "only one inline style block is allowed per element",
                    .unexpected_eof => "unexpected end-of-file",
                };
            }
        };
    };

    pub const depth_limit = 128;

    pub fn init(token_source: TokenSource, allocator: Allocator) Parser {
        return .{
            .rule_stack = .{},
            .element_stack = .empty,
            .block_stack = .{},
            .token_source = token_source,
            .allocator = allocator,
            .location = @enumFromInt(0),
            .depth = 0,
            .failure = undefined,
        };
    }

    pub fn deinit(parser: *Parser) void {
        parser.rule_stack.deinit(parser.allocator);
        parser.element_stack.deinit(parser.allocator);
        parser.block_stack.deinit(parser.allocator);
    }

    pub const Error = error{ParseError} || AstManaged.AddComponentError || TokenSource.Error || Allocator.Error;

    /// Creates an Ast with a root node with tag `rule_list`
    /// Implements CSS Syntax Level 3 Section 9 "Parse a CSS stylesheet"
    pub fn parseCssStylesheet(parser: *Parser, allocator: Allocator) Error!Ast {
        var managed = AstManaged{ .allocator = allocator };
        errdefer managed.deinit();

        const index = try consumeListOfRules(parser, &managed, true);
        _ = index; // TODO: Return the index
        return .{ .components = managed.components.slice() };
    }

    /// Creates an Ast with a root node with tag `component_list`
    /// Implements CSS Syntax Level 3 Section 5.3.10 "Parse a list of component values"
    pub fn parseListOfComponentValues(parser: *Parser, allocator: Allocator) Error!Ast {
        var managed = AstManaged{ .allocator = allocator };
        errdefer managed.deinit();

        const index = try consumeListOfComponentValues(parser, &managed);
        _ = index; // TODO: Return the index
        return .{ .components = managed.components.slice() };
    }

    /// Creates an Ast with a root node with tag `zml_document`
    pub fn parseZmlDocument(parser: *Parser, allocator: Allocator) Error!Ast {
        var managed = AstManaged{ .allocator = allocator };
        errdefer managed.deinit();

        const document_index = try managed.addComplexComponent(.zml_document, parser.location);
        try consumeElement(parser, &managed);
        while (parser.element_stack.items.len > 0) {
            try consumeElement(parser, &managed);
        }
        try parser.skipUntilEof();
        managed.finishComplexComponent(document_index);

        return .{ .components = managed.components.slice() };
    }

    fn setLocation(parser: *Parser, location: Location) void {
        parser.location = location;
    }

    fn fail(parser: *Parser, cause: Failure.Cause, location: Location) error{ParseError} {
        parser.failure = .{ .cause = cause, .location = location };
        return error.ParseError;
    }

    fn increaseDepth(parser: *Parser, location: Location) !void {
        if (parser.depth == depth_limit) return parser.fail(.depth_limit_reached, location);
        parser.depth += 1;
    }

    fn decreaseDepth(parser: *Parser, amount: u8) void {
        parser.depth -= amount;
    }

    fn nextTokenAllowEof(parser: *Parser) !struct { Token, Location } {
        const location = parser.location;
        const token = try parser.token_source.next(&parser.location);
        return .{ token, location };
    }

    fn nextToken(parser: *Parser) !struct { Token, Location } {
        const location = parser.location;
        const token = try parser.token_source.next(&parser.location);
        if (token == .token_eof) return parser.fail(.unexpected_eof, location);
        return .{ token, location };
    }

    fn nextTokenSkipSpacesAllowEof(parser: *Parser) !struct { Token, Location } {
        while (true) {
            const token, const location = try parser.nextTokenAllowEof();
            switch (token) {
                .token_whitespace, .token_comments => {},
                else => return .{ token, location },
            }
        }
    }

    fn nextTokenSkipSpaces(parser: *Parser) !struct { Token, Location } {
        while (true) {
            const token, const location = try parser.nextToken();
            switch (token) {
                .token_whitespace, .token_comments => {},
                else => return .{ token, location },
            }
        }
    }

    fn skipSpacesAllowEof(parser: *Parser) !void {
        while (true) {
            const token, const location = try parser.nextTokenAllowEof();
            switch (token) {
                .token_whitespace, .token_comments => {},
                else => {
                    parser.location = location;
                    return;
                },
            }
        }
    }

    fn skipSpaces(parser: *Parser) !bool {
        const start_location = parser.location;
        while (true) {
            const token, const location = try parser.nextToken();
            switch (token) {
                .token_whitespace, .token_comments => {},
                else => {
                    parser.location = location;
                    return parser.location != start_location;
                },
            }
        }
    }

    fn skipUntilEof(parser: *Parser) !void {
        while (true) {
            const token, const location = try parser.nextTokenAllowEof();
            switch (token) {
                .token_whitespace, .token_comments => {},
                .token_eof => return,
                else => return parser.fail(.invalid_token, location),
            }
        }
    }
};

fn consumeListOfRules(parser: *Parser, ast: *AstManaged, top_level: bool) !Ast.Size {
    const index = try ast.addComplexComponent(.rule_list, parser.location);

    while (true) {
        const token, const location = try parser.nextTokenAllowEof();
        sw: switch (token) {
            .token_whitespace, .token_comments => {},
            .token_eof => break,
            .token_cdo, .token_cdc => {
                if (!top_level) {
                    continue :sw .token_ident;
                } // TODO: Handle else case
            },
            .token_at_keyword => |at_rule| try consumeAtRule(parser, ast, location, at_rule),
            else => {
                parser.setLocation(location);
                const rule_index = try ast.addComplexComponent(.qualified_rule, location);
                try parser.increaseDepth(location);
                parser.rule_stack.top = .{ .index = rule_index, .is_style_rule = top_level };
                try consumeQualifiedRule(parser, ast);
            },
        }
    }

    ast.finishComplexComponent(index);
    return index;
}

fn consumeListOfComponentValues(parser: *Parser, ast: *AstManaged) !Ast.Size {
    const index = try ast.addComplexComponent(.component_list, parser.location);

    while (true) {
        const token, const location = try parser.nextTokenAllowEof();
        switch (token) {
            .token_eof => break,
            else => _ = try consumeComponentValue(parser, ast, token, location, .css),
        }
    }

    ast.finishComplexComponent(index);
    return index;
}

fn consumeAtRule(parser: *Parser, ast: *AstManaged, main_location: Location, at_rule: ?Token.AtRule) !void {
    const index = try ast.addComplexComponent(.at_rule, main_location);
    while (true) {
        const token, const location = try parser.nextTokenAllowEof();
        switch (token) {
            .token_semicolon => break,
            .token_eof => {
                // NOTE: Parse error
                // TODO: Mark the at-rule as containing parse errors
                break;
            },
            .token_left_curly => {
                _ = try consumeComponentValue(parser, ast, .token_left_curly, location, .css);
                break;
            },
            else => _ = try consumeComponentValue(parser, ast, token, location, .css),
        }
    }
    ast.finishComplexComponentExtra(index, .{ .at_rule = at_rule });
}

fn consumeQualifiedRule(parser: *Parser, ast: *AstManaged) !void {
    while (parser.rule_stack.top) |*qualified_rule| {
        if (qualified_rule.index_of_block == null) {
            try consumeQualifiedRulePrelude(parser, ast, qualified_rule);
            if (qualified_rule.discarded) {
                parser.decreaseDepth(1);
                _ = parser.rule_stack.pop();
                continue;
            }
        }

        if (qualified_rule.index_of_block != null and qualified_rule.is_style_rule) {
            if (try consumeStyleBlockContents(parser, ast, qualified_rule)) |nested_rule_index| {
                try parser.increaseDepth(parser.location);
                try parser.rule_stack.push(parser.allocator, .{ .index = nested_rule_index, .is_style_rule = false });
                continue;
            }
            ast.finishComplexComponentExtra(qualified_rule.index_of_block.?, .{ .index = qualified_rule.index_of_last_declaration orelse 0 });
        }

        ast.finishComplexComponentExtra(qualified_rule.index, .{ .index = qualified_rule.index_of_block.? });

        parser.decreaseDepth(1);
        _ = parser.rule_stack.pop();
    }
}

fn consumeQualifiedRulePrelude(parser: *Parser, ast: *AstManaged, qualified_rule: *Parser.QualifiedRule) !void {
    while (true) {
        const token, const location = try parser.nextTokenAllowEof();
        switch (token) {
            .token_eof => {
                // NOTE: Parse error
                // TODO: Mark the qualified rule as containing parse errors
                qualified_rule.discarded = true;
                ast.shrink(qualified_rule.index); // TODO: Do not shrink the Ast
                return;
            },
            .token_left_curly => {
                qualified_rule.index_of_block = switch (qualified_rule.is_style_rule) {
                    false => try consumeComponentValue(parser, ast, .token_left_curly, location, .css),
                    true => try ast.addComplexComponent(.style_block, location),
                };
                return;
            },
            else => _ = try consumeComponentValue(parser, ast, token, location, .css),
        }
    }
}

/// A `null` return value means the style block is finished parsing.
/// A non-`null` return value is the index of a nested qualified rule.
fn consumeStyleBlockContents(parser: *Parser, ast: *AstManaged, qualified_rule: *Parser.QualifiedRule) !?Ast.Size {
    while (true) {
        const token, const location = try parser.nextTokenAllowEof();
        switch (token) {
            .token_right_curly => return null,
            .token_eof => {
                // NOTE: Parse error
                // TODO: Mark the block as containing parse errors
                return null;
            },
            .token_whitespace, .token_comments, .token_semicolon => {},
            .token_at_keyword => |at_rule| try consumeAtRule(parser, ast, location, at_rule),
            .token_ident => {
                if (try consumeDeclaration(parser, ast, location, qualified_rule.index_of_last_declaration, .css)) |decl_index| {
                    qualified_rule.index_of_last_declaration = decl_index;
                } else {
                    try seekToEndOfDeclaration(parser, .css);
                }
            },
            else => {
                if (token == .token_delim and token.token_delim == '&') {
                    parser.setLocation(location);
                    return try ast.addComplexComponent(.qualified_rule, location);
                } else {
                    // NOTE: Parse error
                    parser.setLocation(location);
                    try seekToEndOfDeclaration(parser, .css);
                }
            },
        }
    }
}

fn seekToEndOfDeclaration(parser: *Parser, document_type: DocumentType) !void {
    while (true) {
        const token, const location = try parser.nextTokenAllowEof();
        switch (token) {
            .token_semicolon => break,
            .token_eof => {
                switch (document_type) {
                    .css => break, // TODO: Mark the surrounding block as containing parse errors
                    .zml => return parser.fail(.unexpected_eof, location),
                }
            },
            .token_right_curly, .token_right_paren => {
                const ending_tag: Component.Tag = switch (document_type) {
                    .css => .token_right_curly,
                    .zml => .token_right_paren,
                };
                if (token.cast(Component.Tag) == ending_tag) {
                    parser.setLocation(location);
                    break;
                } else {
                    try ignoreComponentValue(parser, token);
                }
            },
            else => try ignoreComponentValue(parser, token),
        }
    }
}

fn consumeDeclaration(
    parser: *Parser,
    ast: *AstManaged,
    name_location: Location,
    previous_declaration: ?Ast.Size,
    document_type: DocumentType,
) !?Ast.Size {
    const colon_token, const colon_location = try parser.nextTokenSkipSpacesAllowEof();
    if (colon_token != .token_colon) {
        // NOTE: Parse error
        parser.setLocation(colon_location);
        return null;
    }

    const index = try ast.addDeclaration(name_location, previous_declaration);

    var last_3 = Last3NonWhitespaceComponents{};
    try parser.skipSpacesAllowEof();
    while (true) {
        const token, const location = try parser.nextTokenAllowEof();
        switch (token) {
            .token_semicolon => break,
            .token_eof => {
                switch (document_type) {
                    .css => break, // TODO: Mark the surrounding block as containing parse errors
                    .zml => return parser.fail(.unexpected_eof, location),
                }
            },
            .token_right_curly, .token_right_paren => {
                const ending_tag: Component.Tag = switch (document_type) {
                    .css => .token_right_curly,
                    .zml => .token_right_paren,
                };
                if (token.cast(Component.Tag) == ending_tag) {
                    break parser.setLocation(location);
                } else {
                    const component_index = try consumeComponentValue(parser, ast, token, location, document_type);
                    last_3.append(component_index);
                }
            },
            .token_whitespace, .token_comments => _ = try ast.addBasicComponent(token.cast(Component.Tag), location),
            else => {
                const component_index = try consumeComponentValue(parser, ast, token, location, document_type);
                last_3.append(component_index);
            },
        }
    }

    _ = ast.finishDeclaration(parser.token_source, index, last_3);
    return index;
}

fn consumeComponentValue(
    parser: *Parser,
    ast: *AstManaged,
    main_token: Token,
    main_location: Location,
    document_type: DocumentType,
) !Ast.Size {
    switch (main_token) {
        else => return ast.addToken(main_token, main_location),
        .token_left_curly, .token_left_square, .token_left_paren, .token_function => {},
    }

    const main_component_tag, const main_ending_tag = blockTokenToComponents(main_token);
    const main_index = try ast.addComplexComponent(main_component_tag, main_location);
    try parser.increaseDepth(main_location);
    parser.block_stack.top = .{ .ending_tag = main_ending_tag, .index = main_index };

    while (parser.block_stack.top) |top| {
        const token, const location = try parser.nextTokenAllowEof();
        switch (token) {
            .token_left_curly, .token_left_square, .token_left_paren, .token_function => {
                const component_tag, const ending_tag = blockTokenToComponents(token);
                const index = try ast.addComplexComponent(component_tag, location);
                try parser.increaseDepth(location);
                try parser.block_stack.push(parser.allocator, .{ .ending_tag = ending_tag, .index = index });
            },
            .token_right_curly, .token_right_square, .token_right_paren => {
                const tag = token.cast(Component.Tag);
                if (tag == top.ending_tag) {
                    parser.decreaseDepth(1);
                    const index = parser.block_stack.pop().index;
                    ast.finishComplexComponent(index);
                    continue;
                } else {
                    _ = try ast.addBasicComponent(tag, location);
                }
            },
            .token_eof => {
                switch (document_type) {
                    .css => {
                        ast.finishComplexComponent(top.index);
                        const len = parser.block_stack.rest.items.len;
                        for (0..len) |i| {
                            const index = parser.block_stack.rest.items[len - 1 - i].index;
                            ast.finishComplexComponent(index);
                        }

                        parser.decreaseDepth(@intCast(len + 1));
                        parser.block_stack.clear();
                        break;
                    },
                    .zml => return parser.fail(.unexpected_eof, location),
                }
            },
            else => _ = try ast.addToken(token, location),
        }
    }

    return main_index;
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
    while (true) : (token, _ = try parser.nextTokenAllowEof()) {
        switch (token) {
            .token_left_curly, .token_left_square, .token_left_paren, .token_function => {
                _, const ending_tag = blockTokenToComponents(token);
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

fn blockTokenToComponents(token: Token) struct { Component.Tag, Component.Tag } {
    // zig fmt: off
    const component_tag: Component.Tag, const ending_tag: Component.Tag = switch (token) {
        .token_left_curly =>  .{ .simple_block_curly,  .token_right_curly  },
        .token_left_square => .{ .simple_block_square, .token_right_square },
        .token_left_paren =>  .{ .simple_block_paren,  .token_right_paren  },
        .token_function =>    .{ .function,            .token_right_paren  },
        else => unreachable,
    };
    // zig fmt: on
    return .{ component_tag, ending_tag };
}

fn consumeElement(parser: *Parser, ast: *AstManaged) !void {
    try parser.skipSpacesAllowEof();
    const main_token, const main_location = try parser.nextTokenAllowEof();

    switch (main_token) {
        .token_eof => {
            const no_open_elements = (parser.element_stack.items.len == 0);
            if (no_open_elements) return;
            return parser.fail(.unexpected_eof, main_location);
        },
        .token_right_curly => {
            const no_open_elements = (parser.element_stack.items.len == 0);
            if (no_open_elements) return parser.fail(.invalid_token, main_location);
            parser.decreaseDepth(1);
            const item = parser.element_stack.pop().?;
            ast.finishElement(item.element_index, item.block_index);
            return;
        },
        .token_string => {
            _ = try ast.addBasicComponent(.zml_text_element, main_location);
            return;
        },
        else => parser.location = main_location,
    }

    const element_index = try ast.addComplexComponent(.zml_element, main_location);
    const features_index = try ast.addComplexComponent(.zml_features, main_location);
    var has_preceding_whitespace = true;
    var parsed_any_features = false;
    var parsed_type = false;
    var parsed_inline_styles: ?Location = null;
    var parsed_star = false;
    while (true) : (has_preceding_whitespace = try parser.skipSpaces()) {
        const token, const location = try parser.nextToken();

        if (token == .token_left_curly) {
            if (!parsed_any_features) return parser.fail(.element_with_no_features, main_location);
            if (parsed_inline_styles == null) ast.finishComplexComponent(features_index);

            const block_index = try ast.addComplexComponent(.zml_children, location);
            const after_left_curly, const after_left_curly_location = try parser.nextTokenSkipSpaces();
            if (after_left_curly == .token_right_curly) {
                ast.finishElement(element_index, block_index);
            } else {
                parser.location = after_left_curly_location;
                try parser.increaseDepth(location);
                try parser.element_stack.append(parser.allocator, .{ .element_index = element_index, .block_index = block_index });
            }
            return;
        }

        if (token == .token_left_paren) {
            ast.finishComplexComponent(features_index);
            try consumeInlineStyleBlock(parser, ast, location);
            if (!parsed_any_features) return parser.fail(.inline_style_block_before_features, location);
            if (parsed_inline_styles) |loc| return parser.fail(.multiple_inline_style_blocks, loc);
            parsed_inline_styles = location;
            continue;
        }

        if (!has_preceding_whitespace) return parser.fail(.missing_space_between_features, location);

        if (token == .token_delim and token.token_delim == '*') {
            _ = try ast.addBasicComponent(.zml_empty, location);
            if (parsed_any_features) return parser.fail(.empty_with_other_features, location);
            parsed_star = true;
        } else {
            try consumeFeature(parser, ast, token, location, &parsed_type);
            if (parsed_star) return parser.fail(.empty_with_other_features, location);
        }

        if (parsed_inline_styles) |loc| return parser.fail(.inline_style_block_before_features, loc);
        parsed_any_features = true;
    }
}

fn consumeFeature(parser: *Parser, ast: *AstManaged, main_token: Token, main_location: Location, parsed_type: *bool) !void {
    switch (main_token) {
        .token_delim => |codepoint| blk: {
            if (codepoint == '.') {
                const identifier, _ = try parser.nextToken();
                if (identifier != .token_ident) break :blk;
                _ = try ast.addBasicComponent(.zml_class, main_location);
                return;
            }
        },
        .token_ident => {
            _ = try ast.addBasicComponent(.zml_type, main_location);
            if (parsed_type.*) return parser.fail(.multiple_types, main_location);
            parsed_type.* = true;
            return;
        },
        .token_hash_id => {
            _ = try ast.addBasicComponent(.zml_id, main_location);
            return;
        },
        .token_hash_unrestricted => {
            return parser.fail(.invalid_id, main_location);
        },
        .token_left_square => blk: {
            const name, const name_location = try parser.nextTokenSkipSpaces();
            if (name != .token_ident) break :blk;

            const after_name, _ = try parser.nextTokenSkipSpaces();
            if (after_name == .token_right_square) return ast.addZmlAttribute(main_location, name_location);

            const value, const value_location = try parser.nextTokenSkipSpaces();
            const right_bracket, _ = try parser.nextTokenSkipSpaces();
            if ((after_name == .token_delim and after_name.token_delim == '=') and
                (value == .token_ident or value == .token_string) and
                (right_bracket == .token_right_square))
            {
                return ast.addZmlAttributeWithValue(main_location, name_location, value.cast(Component.Tag), value_location);
            }
        },

        else => {},
    }

    return parser.fail(.invalid_feature, main_location);
}

fn consumeInlineStyleBlock(parser: *Parser, ast: *AstManaged, main_location: Location) !void {
    const style_block_index = try ast.addComplexComponent(.zml_styles, main_location);

    var previous_declaration: ?Ast.Size = null;
    while (true) {
        {
            const token, const location = try parser.nextTokenSkipSpaces();
            if (token == .token_right_paren) {
                if (previous_declaration == null) return parser.fail(.empty_inline_style_block, main_location);
                break;
            } else {
                parser.location = location;
            }
        }

        const name, const name_location = try parser.nextToken();
        if (name != .token_ident) return parser.fail(.expected_identifier, name_location);
        const declaration_index = try consumeDeclaration(parser, ast, name_location, previous_declaration, .zml);
        previous_declaration = declaration_index;
    }

    ast.finishInlineStyleBlock(style_block_index, previous_declaration.?);
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

    var parser = Parser.init(token_source, allocator);
    defer parser.deinit();

    var ast = try parser.parseCssStylesheet(allocator);
    defer ast.deinit(allocator);

    const TestComponent = struct {
        next_sibling: Ast.Size,
        tag: Component.Tag,
        location: Location,
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

test "parse a zml document" {
    const allocator = std.testing.allocator;
    const input =
        \\* {
        \\   p1 {}
        \\   * {}
        \\   "Hello"
        \\   p2 (decl: value !important; decl: asdf) {
        \\       /*comment*/p3/*comment*/[a=b] #id {}
        \\   }
        \\   p3 (decl: func({} [ {} {1}] };)) {}
        \\}
    ;
    const token_source = try TokenSource.init(input);

    var parser = Parser.init(token_source, allocator);
    defer parser.deinit();

    var ast = try parser.parseZmlDocument(allocator);
    defer ast.deinit(allocator);
}

test "parser fuzz test" {
    const ns = struct {
        fn fuzzFn(comptime document_type: DocumentType) fn (_: void, input: []const u8) anyerror!void {
            const parse_fn = switch (document_type) {
                .css => Parser.parseCssStylesheet,
                .zml => Parser.parseZmlDocument,
            };
            const ns2 = struct {
                fn fuzzOne(_: void, input: []const u8) !void {
                    const token_source = try TokenSource.init(input);
                    const allocator = std.testing.allocator;

                    var parser = Parser.init(token_source, allocator);
                    defer parser.deinit();

                    var ast = parse_fn(&parser, allocator) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => return,
                    };
                    defer ast.deinit(allocator);
                }
            };
            return ns2.fuzzOne;
        }
    };

    // TODO: It could be useful to include a corpus.
    try std.testing.fuzz({}, ns.fuzzFn(.css), .{});
    try std.testing.fuzz({}, ns.fuzzFn(.zml), .{});
}
