//! zml - zss markup language
//!
//! zml is a lightweight & minimal markup language for creating documents.
//! Its main purpose is to be able to assign CSS properties and features to
//! document elements with as little syntax as possible.
//! The syntax should feel natural to anyone that has used CSS.
//!
//! The grammar of zml documents is presented below.
//! It uses the value definition syntax described in CSS Values and Units Level 4.
//!
//! <root>               = <element>
//! <element>            = <normal-element> | <text-element>
//! <normal-element>     = <features> <inline-style-block>? <children>
//! <text-element>       = <string-token>
//!
//! <features>           = '*' | [ <type> | <id> | <class> | <attribute> ]+
//! <type>               = <ident-token>
//! <id>                 = <hash-token>
//! <class>              = '.' <ident-token>
//! <attribute>          = '[' <ident-token> [ '=' <attribute-value> ]? ']'
//! <attribute-value>    = <ident-token> | <string-token>
//!
//! <inline-style-block> = '(' <declaration-list> ')'
//!
//! <children>           = '{' <element>* '}'
//!
//! <ident-token>        = <defined in CSS Syntax Level 3>
//! <string-token>       = <defined in CSS Syntax Level 3>
//! <hash-token>         = <defined in CSS Syntax Level 3>
//! <declaration-list>   = <defined in CSS Style Attributes>
//!
//! Whitespace or comments are required between the components of <features>.
//! The <hash-token> component of <id> must be an "id" hash token.
//! No whitespace or comments are allowed between the components of <class>.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const MultiArrayList = std.MultiArrayList;

const zss = @import("../zss.zig");
const tokenize = zss.syntax.tokenize;
const Ast = zss.syntax.Ast;
const AstManaged = zss.syntax.parse.AstManaged;
const Component = zss.syntax.Component;
const Last3NonWhitespaceComponents = zss.syntax.parse.Last3NonWhitespaceComponents;
const Location = TokenSource.Location;
const Stack = zss.Stack;
const Token = zss.syntax.Token;
const TokenSource = zss.syntax.TokenSource;

test "parse a zml document" {
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
    const allocator = std.testing.allocator;

    var parser = Parser.init(token_source, allocator);
    defer parser.deinit();

    var ast = parser.parse(allocator) catch |err| switch (err) {
        error.ParseError => {
            std.log.err(
                "zml parse error: location = {}, char = '{c}' msg = {s}",
                .{ @intFromEnum(parser.failure.location), input[@intFromEnum(parser.failure.location)], parser.failure.cause.debugErrMsg() },
            );
            return;
        },
        else => |e| return e,
    };
    defer ast.deinit(allocator);
}

fn fuzzOne(input: []const u8) !void {
    const token_source = try TokenSource.init(input);
    const allocator = std.testing.allocator;

    var parser = Parser.init(token_source, allocator);
    defer parser.deinit();

    var ast = parser.parse(allocator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
    defer ast.deinit(allocator);
}

test "zml parser fuzz test" {
    // TODO: It could be useful to include a corpus.
    try std.testing.fuzz(fuzzOne, .{});
}

pub const Parser = struct {
    token_source: TokenSource,
    location: Location,
    allocator: Allocator,
    element_stack: ArrayListUnmanaged(struct {
        element_index: Ast.Size,
        block_index: Ast.Size,
    }),
    block_stack: Stack(struct {
        ending_tag: Component.Tag,
        component_index: Ast.Size,
    }),
    /// If parsing fails with `error.ParseError`, this will contain a more detailed error.
    /// Otherwise, this field is undefined.
    failure: Failure,

    pub const Failure = struct {
        cause: Cause,
        location: Location,

        pub const Cause = enum {
            block_depth_limit_reached,
            element_depth_limit_reached,
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
                    .block_depth_limit_reached => "block depth limit reached",
                    .element_depth_limit_reached => "element depth limit reached",
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

    pub fn init(token_source: TokenSource, allocator: Allocator) Parser {
        return .{
            .token_source = token_source,
            .location = @enumFromInt(0),
            .allocator = allocator,
            .element_stack = .{},
            .block_stack = .{},
            .failure = undefined,
        };
    }

    pub fn deinit(parser: *Parser) void {
        parser.element_stack.deinit(parser.allocator);
        parser.block_stack.deinit(parser.allocator);
    }

    pub const Error = error{ ParseError, Overflow } || TokenSource.Error || Allocator.Error;

    pub fn parse(parser: *Parser, allocator: Allocator) Error!Ast {
        var managed = AstManaged{ .allocator = allocator };
        errdefer managed.deinit();

        const document_index = try managed.addComplexComponent(.zml_document, parser.location);
        try parseElement(parser, &managed);
        while (parser.element_stack.items.len > 0) {
            try parseElement(parser, &managed);
        }
        try parser.consumeUntilEof();
        managed.finishComplexComponent(document_index);

        return .{ .components = managed.components.slice() };
    }

    fn fail(parser: *Parser, cause: Failure.Cause, location: Location) error{ParseError} {
        parser.failure = .{ .cause = cause, .location = location };
        return error.ParseError;
    }

    fn nextTokenAllowEof(parser: *Parser) !struct { Token, Location } {
        const location = parser.location;
        const token = try parser.token_source.next(&parser.location);
        return .{ token, location };
    }

    fn nextToken(parser: *Parser) !struct { Token, Location } {
        const next_token = try parser.nextTokenAllowEof();
        if (next_token[0] == .token_eof) return parser.fail(.unexpected_eof, next_token[1]);
        return next_token;
    }

    fn nextTokenSkipWhitespace(parser: *Parser) !struct { Token, Location } {
        while (true) {
            const next_token = try parser.nextToken();
            switch (next_token[0]) {
                .token_whitespace, .token_comments => {},
                else => return next_token,
            }
        }
    }

    fn consumeWhitespace(parser: *Parser) !bool {
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

    fn consumeWhitespaceAllowEof(parser: *Parser) !bool {
        const start_location = parser.location;
        while (true) {
            const token, const location = try parser.nextTokenAllowEof();
            switch (token) {
                .token_whitespace, .token_comments => {},
                else => {
                    parser.location = location;
                    return parser.location != start_location;
                },
            }
        }
    }

    fn consumeUntilEof(parser: *Parser) !void {
        while (true) {
            const token, const location = try parser.nextTokenAllowEof();
            switch (token) {
                .token_whitespace, .token_comments => {},
                .token_eof => return,
                else => return parser.fail(.invalid_token, location),
            }
        }
    }

    fn pushElement(parser: *Parser, element_index: Ast.Size, block_index: Ast.Size, block_location: Location) !void {
        const max_element_depth = 1000;
        if (parser.element_stack.items.len == max_element_depth) return parser.fail(.element_depth_limit_reached, block_location);
        try parser.element_stack.append(parser.allocator, .{ .element_index = element_index, .block_index = block_index });
    }
};

fn parseElement(parser: *Parser, ast: *AstManaged) !void {
    _ = try parser.consumeWhitespaceAllowEof();
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
            const item = parser.element_stack.pop();
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
    while (true) : (has_preceding_whitespace = try parser.consumeWhitespace()) {
        const token, const location = try parser.nextToken();

        if (token == .token_left_curly) {
            if (!parsed_any_features) return parser.fail(.element_with_no_features, main_location);
            if (parsed_inline_styles == null) ast.finishComplexComponent(features_index);

            const block_index = try ast.addComplexComponent(.zml_children, location);
            const after_left_curly, const after_left_curly_location = try parser.nextTokenSkipWhitespace();
            if (after_left_curly == .token_right_curly) {
                ast.finishElement(element_index, block_index);
            } else {
                parser.location = after_left_curly_location;
                try parser.pushElement(element_index, block_index, location);
            }
            return;
        }

        if (token == .token_left_paren) {
            ast.finishComplexComponent(features_index);
            try parseInlineStyleBlock(parser, ast, location);
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
            try parseFeature(parser, ast, token, location, &parsed_type);
            if (parsed_star) return parser.fail(.empty_with_other_features, location);
        }

        if (parsed_inline_styles) |loc| return parser.fail(.inline_style_block_before_features, loc);
        parsed_any_features = true;
    }
}

fn parseFeature(parser: *Parser, ast: *AstManaged, main_token: Token, main_location: Location, parsed_type: *bool) !void {
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
            const name, const name_location = try parser.nextTokenSkipWhitespace();
            if (name != .token_ident) break :blk;

            const after_name, _ = try parser.nextTokenSkipWhitespace();
            if (after_name == .token_right_square) return ast.addZmlAttribute(main_location, name_location);

            const value, const value_location = try parser.nextTokenSkipWhitespace();
            const right_bracket, _ = try parser.nextTokenSkipWhitespace();
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

fn parseInlineStyleBlock(parser: *Parser, ast: *AstManaged, main_location: Location) !void {
    const style_block_index = try ast.addComplexComponent(.zml_styles, main_location);

    var previous_declaration: ?Ast.Size = null;
    parser.block_stack.top = .{ .ending_tag = .token_right_paren, .component_index = undefined };
    while (parser.block_stack.top != null) {
        assert(parser.block_stack.len() == 1);

        {
            const token, const location = try parser.nextTokenSkipWhitespace();
            if (token == .token_right_paren) {
                if (previous_declaration == null) return parser.fail(.empty_inline_style_block, main_location);
                break;
            } else {
                parser.location = location;
            }
        }

        const name, const name_location = try parser.nextToken();
        if (name != .token_ident) return parser.fail(.expected_identifier, name_location);
        const colon, const colon_location = try parser.nextToken();
        if (colon != .token_colon) return parser.fail(.expected_colon, colon_location);
        const declaration_index = try ast.addDeclaration(name_location, previous_declaration);

        _ = try parser.consumeWhitespace();
        var last_3 = Last3NonWhitespaceComponents{};
        while (true) {
            const token, const location = try parser.nextToken();
            switch (token) {
                .token_semicolon => {
                    if (parser.block_stack.len() == 1) break;
                    const component_index = try ast.addBasicComponent(.token_semicolon, location);
                    last_3.append(component_index);
                },
                // TODO: handle comments
                .token_whitespace => _ = try ast.addBasicComponent(.token_whitespace, location),
                .token_left_curly, .token_left_paren, .token_left_square, .token_function => {
                    // zig fmt: off
                    const component_tag: Component.Tag, const ending_tag: Component.Tag = switch (token) {
                        .token_left_curly =>  .{ .simple_block_curly,  .token_right_curly  },
                        .token_left_square => .{ .simple_block_square, .token_right_square },
                        .token_left_paren =>  .{ .simple_block_paren,  .token_right_paren  },
                        .token_function =>    .{ .function,            .token_right_paren  },
                        else => unreachable,
                    };
                    // zig fmt: on

                    const component_index = try ast.addComplexComponent(component_tag, location);
                    const after_open, const after_open_location = try parser.nextTokenSkipWhitespace();
                    if (after_open.cast(Component.Tag) == ending_tag) {
                        ast.finishComplexComponent(component_index);
                    } else {
                        parser.location = after_open_location;
                        const max_block_depth = 32;
                        if (parser.block_stack.len() == max_block_depth) return parser.fail(.block_depth_limit_reached, location);
                        try parser.block_stack.push(parser.allocator, .{ .ending_tag = ending_tag, .component_index = component_index });
                    }
                    last_3.append(component_index);
                },
                .token_right_curly, .token_right_paren, .token_right_square => {
                    const tag = token.cast(Component.Tag);
                    if (tag == parser.block_stack.top.?.ending_tag) {
                        const item = parser.block_stack.pop();
                        if (parser.block_stack.top == null) break;
                        ast.finishComplexComponent(item.component_index);
                    } else {
                        const component_index = try ast.addBasicComponent(tag, location);
                        last_3.append(component_index);
                    }
                },
                else => {
                    const component_index = try ast.addToken(token, location);
                    last_3.append(component_index);
                },
            }
        }

        if (ast.finishDeclaration(parser.token_source, declaration_index, last_3)) return parser.fail(.empty_declaration_value, name_location);
        previous_declaration = declaration_index;
    }

    ast.finishInlineStyleBlock(style_block_index, previous_declaration.?);
}
