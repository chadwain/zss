//! zml - zss markup language
//!
//! zml is a lightweight & minimal markup language for creating documents.
//! It's main purpose is to be able to assign CSS properties and features to
//! document elements with as little syntax as possible. At the same time,
//! the syntax should feel natural and obvious to anyone that has used CSS.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const MultiArrayList = std.MultiArrayList;

const zss = @import("zss.zig");
const tokenize = zss.syntax.tokenize;
const Source = tokenize.Source;
const Location = Source.Location;
const Stack = zss.util.Stack;
const Token = zss.syntax.Token;

pub const Ast = struct {
    pub const Size = u32;
    pub const Tag = enum {
        token_eof,
        token_comments,
        token_ident,
        token_function,
        token_at_keyword,
        token_hash_unrestricted,
        token_hash_id,
        token_string,
        token_bad_string,
        token_url,
        token_bad_url,
        token_delim,
        token_integer,
        token_number,
        token_percentage,
        token_dimension,
        token_whitespace,
        token_cdo,
        token_cdc,
        token_colon,
        token_semicolon,
        token_comma,
        token_left_square,
        token_right_square,
        token_left_paren,
        token_right_paren,
        token_left_curly,
        token_right_curly,

        /// A function
        /// children: The function's arguments (an arbitrary sequence of components)
        /// location: The location of the <function-token> that created this component
        function,
        /// A '[]-block'
        /// location: The location of the <[-token> that opens this block
        /// children: An arbitrary sequence of components
        simple_block_square,
        /// A '{}-block'
        /// location: The location of the <{-token> that opens this block
        /// children: An arbitrary sequence of components
        simple_block_curly,
        /// A '()-block'
        /// location: The location of the <(-token> that opens this block
        /// children: An arbitrary sequence of components
        simple_block_paren,

        /// A CSS property declaration that does not end with "!important"
        /// location: The location of the <ident-token> that is the name for this declaration
        /// children: The declaration's value (an arbitrary sequence of nodes)
        ///           Trailing and leading <whitespace-token>s are not included
        ///           The ending <semicolon-token> (if it exists) is not included
        ///    extra: Use `extra.index()` to get a node index.
        ///           Then, if the value is 0, this declaration is the first declaration in the sequence containing it.
        ///           Otherwise, the value is the index of the declaration that appeared just before this one
        ///           (with tag = `declaration_normal` or `declaration_important`).
        declaration_normal,
        /// A CSS property declaration that ends with "!important"
        /// location: The location of the <ident-token> that is the name for this declaration
        /// children: The declaration's value (an arbitrary sequence of nodes)
        ///           Trailing and leading <whitespace-token>s are not included
        ///           The ending <semicolon-token> (if it exists) is not included
        ///           The <delim-token> and <ident-token> that make up "!important" are not included
        ///    extra: Use `extra.index()` to get a node index.
        ///           Then, if the value is 0, this declaration is the first declaration in the sequence containing it.
        ///           Otherwise, the value is the index of the declaration that appeared just before this one
        ///           (with tag = `declaration_normal` or `declaration_important`).
        declaration_important,

        /// description: The empty feature (a '*' codepoint)
        ///    location: The '*' codepoint
        empty,
        /// description: A zml element type (an identifier)
        ///    location: The identifier's first codepoint
        type,
        /// description: A zml element id (a '#' codepoint + an identifier)
        ///    location: The '#' codepoint
        id,
        /// description: A zml element class (a '.' codepoint + an identifier)
        ///    location: The '.' codepoint
        class,
        /// description: A zml element attribute (a '[]-block' containing an attribute name + optionally, a '=' codepoint and an attribute value)
        ///    location: The location of the <[-token> that opens the block
        ///    children: The attribute name (a `token_ident`) + optionally, the attribute value (a `token_ident` or `token_string`)
        attribute,
        /// description: A zml element's features
        ///    location: The location of the element's first feature
        ///    children: either a single `empty`, or a non-empty sequence of `type`, `id`, `class`, and `attribute` (at most one `type` is allowed)
        features,
        /// description: A zml element's inline style declarations (a '()-block' containing declarations)
        ///    location: The location of the <(-token> that opens the block
        ///    children: a non-empty sequence of `declaration_normal` and `declaration_important`
        ///       extra: Use `extra.index()` to get the node index of the *last* declaration in the inline style block
        ///              (with tag = `declaration_normal` or `declaration_important`).
        styles,
        /// description: A '{}-block' containing a zml element's children
        ///    location: The location of the <{-token> that opens the block
        ///    children: A sequence of `element`
        children,
        /// description: A zml element
        ///    location: The location of the `features`
        ///    children: The element's features (a `features`) +
        ///              optionally, the element's inline style declarations (a `styles`) +
        ///              the element's children (a `children`)
        element,
        /// description: A zml document
        ///    location: The beginning of the source document
        ///    children: Optionally, a single `element`
        document,
    };

    pub const Node = struct {
        next_sibling: Size,
        tag: Tag,
        location: Location,
    };

    nodes: MultiArrayList(Node) = .{},

    pub fn deinit(ast: *Ast, allocator: Allocator) void {
        ast.nodes.deinit(allocator);
    }

    pub const debug = struct {
        pub fn print(ast: Ast, allocator: Allocator, writer: anytype) !void {
            const nodes = ast.nodes.slice();
            try writer.print("Zdf Ast (index, tag, location)\narray len {}\n", .{nodes.len});
            if (nodes.len == 0) return;
            try writer.print("ast size {}\n", .{nodes.items(.next_sibling)[0]});

            const Item = struct {
                current: Size,
                end: Size,
            };
            var stack = Stack(Item){};
            defer stack.deinit(allocator);
            stack.top = .{ .current = 0, .end = nodes.items(.next_sibling)[0] };

            while (stack.top) |*top| {
                if (top.current == top.end) {
                    _ = stack.pop();
                    continue;
                }

                const index = top.current;
                const node = nodes.get(index);
                const indent = (stack.len() - 1) * 4;
                try writer.writeByteNTimes(' ', indent);
                try writer.print("{} {s} {}\n", .{ index, @tagName(node.tag), @intFromEnum(node.location) });

                top.current = node.next_sibling;
                if (index + 1 != node.next_sibling) {
                    try stack.push(allocator, .{ .current = index + 1, .end = node.next_sibling });
                }
            }
        }
    };
};

test "parse" {
    const input = "id/*comment*/[abc] (display: block   ! important; position: nowhere ({ blocks )})) {}";
    const source = try Source.init(zss.util.Utf8String{ .data = input });
    const allocator = std.testing.allocator;

    var ast = Ast{};
    defer ast.deinit(allocator);

    var parser = Parser.init(source, allocator);
    defer parser.deinit();
    parser.parse(&ast, allocator) catch |err| switch (err) {
        error.ParseError => std.log.err(
            "zml parse error: location = {}, msg = {s}",
            .{ @intFromEnum(parser.failure.location), parser.failure.cause.errMsg() },
        ),
        else => |e| return e,
    };
}

const Parser = struct {
    source: Source,
    location: Location,
    allocator: Allocator,
    element_stack: ArrayListUnmanaged(struct {
        element_index: Ast.Size,
        block_index: Ast.Size,
    }),
    block_stack: Stack(struct {
        ending_tag: Ast.Tag,
        node_index: Ast.Size,
    }),
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
            invalid_token,
            missing_space_between_features,
            multiple_inline_style_blocks,
            unexpected_eof,

            pub fn errMsg(cause: Cause) []const u8 {
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
                    .invalid_token => "invalid token",
                    .missing_space_between_features => "features must be separated with whitespace or comments",
                    .multiple_inline_style_blocks => "only one inline style block is allowed",
                    .unexpected_eof => "unexpected end-of-file",
                };
            }
        };
    };

    pub fn init(source: Source, allocator: Allocator) Parser {
        return .{
            .source = source,
            .location = .start,
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

    pub fn parse(parser: *Parser, ast: *Ast, allocator: Allocator) !void {
        const managed = AstManaged{ .unmanaged = ast, .allocator = allocator };

        const document_index = try managed.addComplexNode(.document, parser.location);
        try parseElement(parser, managed);
        while (parser.element_stack.items.len > 0) {
            try parseElement(parser, managed);
        }
        try consumeUntilEof(parser);
        managed.finishComplexNode(document_index);
    }

    fn fail(parser: *Parser, cause: Failure.Cause, location: Location) error{ParseError} {
        parser.failure = .{ .cause = cause, .location = location };
        return error.ParseError;
    }

    fn nextTokenAllowEof(parser: *Parser) !struct { Token, Location } {
        const next_token = try tokenize.nextToken(parser.source, parser.location);
        defer parser.location = next_token.next_location;
        return .{ next_token.token, parser.location };
    }

    fn nextToken(parser: *Parser) !struct { Token, Location } {
        const next_token = try parser.nextTokenAllowEof();
        if (next_token[0] == .token_eof) return parser.fail(.unexpected_eof, next_token[1]);
        return next_token;
    }

    fn pushElement(parser: *Parser, ast: AstManaged, element_index: Ast.Size, block_location: Location) !void {
        const max_element_depth = std.math.maxInt(u16);
        if (parser.element_stack.items.len == max_element_depth) return parser.fail(.element_depth_limit_reached, block_location);
        const block_index = try ast.createNode(.{
            .next_sibling = undefined,
            .tag = .children,
            .location = block_location,
        });
        try parser.element_stack.append(parser.allocator, .{ .element_index = element_index, .block_index = block_index });
    }

    fn popElement(parser: *Parser, ast: AstManaged) void {
        const item = parser.element_stack.pop();
        const nodes = ast.unmanaged.nodes.slice();
        const next_sibling = ast.len();
        nodes.items(.next_sibling)[item.element_index] = next_sibling;
        nodes.items(.next_sibling)[item.block_index] = next_sibling;
    }
};

const AstManaged = struct {
    unmanaged: *Ast,
    allocator: Allocator,

    fn len(ast: AstManaged) Ast.Size {
        return @intCast(ast.unmanaged.nodes.len);
    }

    fn createNode(ast: AstManaged, node: Ast.Node) !Ast.Size {
        const index = ast.len();
        if (index == std.math.maxInt(Ast.Size)) return error.Overflow;
        try ast.unmanaged.nodes.append(ast.allocator, node);
        return index;
    }

    fn addBasicNode(ast: AstManaged, tag: Ast.Tag, location: Location) !Ast.Size {
        const next_sibling = try std.math.add(Ast.Size, 1, ast.len());
        return ast.createNode(.{
            .next_sibling = next_sibling,
            .tag = tag,
            .location = location,
        });
    }

    fn addComplexNode(ast: AstManaged, tag: Ast.Tag, location: Location) !Ast.Size {
        return ast.createNode(.{
            .next_sibling = undefined,
            .tag = tag,
            .location = location,
        });
    }

    fn finishComplexNode(ast: AstManaged, node_index: Ast.Size) void {
        const next_sibling: Ast.Size = ast.len();
        ast.unmanaged.nodes.items(.next_sibling)[node_index] = next_sibling;
    }

    fn addAttributeWithoutValue(ast: AstManaged, main_location: Location, name_location: Location) !void {
        const next_sibling = try std.math.add(Ast.Size, 2, ast.len());
        _ = try ast.createNode(.{
            .next_sibling = next_sibling,
            .tag = .attribute,
            .location = main_location,
        });
        _ = try ast.createNode(.{
            .next_sibling = next_sibling,
            .tag = .token_ident,
            .location = name_location,
        });
    }

    fn addAttributeWithValue(
        ast: AstManaged,
        main_location: Location,
        name_location: Location,
        value_tag: Ast.Tag,
        value_location: Location,
    ) !void {
        const next_sibling = try std.math.add(Ast.Size, 3, ast.len());
        _ = try ast.createNode(.{
            .next_sibling = next_sibling,
            .tag = .attribute,
            .location = main_location,
        });
        _ = try ast.createNode(.{
            .next_sibling = next_sibling - 1,
            .tag = .token_ident,
            .location = name_location,
        });
        _ = try ast.createNode(.{
            .next_sibling = next_sibling,
            .tag = value_tag,
            .location = value_location,
        });
    }

    const finishInlineStyleBlock = finishComplexNode;

    fn addDeclaration(ast: AstManaged, main_location: Location) !Ast.Size {
        return ast.createNode(.{
            .next_sibling = undefined,
            .tag = undefined,
            .location = main_location,
        });
    }

    fn finishDeclaration(ast: AstManaged, parser: *Parser, declaration_index: Ast.Size, last_3: Last3NonWhitespaceNodes) !void {
        const nodes = ast.unmanaged.nodes.slice();
        const is_important = false; // TODO
        // const is_important = blk: {
        //     if (last_3.len < 2) break :blk false;
        //     const exclamation = last_3.nodes[1];
        //     const important_string = last_3.nodes[2];
        //     break :blk slice.items(.tag)[exclamation] == .token_delim and
        //         slice.items(.extra)[exclamation].codepoint() == '!' and
        //         slice.items(.tag)[important_string] == .token_ident and
        //         parser.source.mapIdentifier(slice.items(.location)[important_string], void, &.{.{ "important", {} }}) != null;
        // };

        const tag: Ast.Tag, const min_required_nodes: u2 = switch (is_important) {
            true => .{ .declaration_important, 3 },
            false => .{ .declaration_normal, 1 },
        };
        if (last_3.len < min_required_nodes) return parser.fail(.empty_declaration_value, nodes.items(.location)[declaration_index]);
        nodes.items(.tag)[declaration_index] = tag;
        const last_node = last_3.nodes[3 - min_required_nodes];
        const next_sibling = nodes.items(.next_sibling)[last_node];
        nodes.items(.next_sibling)[declaration_index] = next_sibling;
        ast.unmanaged.nodes.shrinkRetainingCapacity(next_sibling);
    }
};

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

fn nextTokenSkipWhitespace(parser: *Parser) !struct { Token, Location } {
    while (true) {
        const next_token = try parser.nextToken();
        switch (next_token[0]) {
            .token_whitespace, .token_comments => {},
            else => return next_token,
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

fn parseElement(parser: *Parser, ast: AstManaged) !void {
    _ = try consumeWhitespace(parser);
    const main_token, const main_location = try parser.nextTokenAllowEof();

    switch (main_token) {
        .token_eof => {
            const is_root_element = (parser.element_stack.items.len == 0);
            if (is_root_element) return;
            return parser.fail(.unexpected_eof, main_location);
        },
        .token_right_curly => return parser.popElement(ast),
        else => parser.location = main_location,
    }

    const element_index = try ast.addComplexNode(.element, main_location);
    const features_index = try ast.addComplexNode(.features, main_location);
    var has_preceding_whitespace = true;
    var parsed_any_features = false;
    var parsed_inline_styles = false;
    var parsed_star = false;
    while (true) : (has_preceding_whitespace = try consumeWhitespace(parser)) {
        const token, const location = try parser.nextToken();

        if (token == .token_left_curly) {
            if (!parsed_any_features) return parser.fail(.element_with_no_features, main_location);
            if (!parsed_inline_styles) ast.finishComplexNode(features_index);
            return parser.pushElement(ast, element_index, location);
        }

        if (!has_preceding_whitespace) return parser.fail(.missing_space_between_features, location);

        if (token == .token_left_paren) {
            ast.finishComplexNode(features_index);
            try parseInlineStyleBlock(parser, ast, location);
            if (!parsed_any_features) return parser.fail(.inline_style_block_before_features, location);
            if (parsed_inline_styles) return parser.fail(.multiple_inline_style_blocks, location);
            parsed_inline_styles = true;
            continue;
        }

        if (parsed_inline_styles) return parser.fail(.inline_style_block_before_features, location);

        if (token == .token_delim and token.token_delim == '*') {
            if (parsed_any_features) return parser.fail(.empty_with_other_features, location);
            _ = try ast.addBasicNode(.empty, location);
            parsed_any_features = true;
            parsed_star = true;
            continue;
        }

        try parseFeature(parser, ast, token, location);
        if (parsed_star) return parser.fail(.empty_with_other_features, location);
        parsed_any_features = true;
    }
}

fn parseFeature(parser: *Parser, ast: AstManaged, main_token: Token, main_location: Location) !void {
    switch (main_token) {
        .token_delim => |codepoint| blk: {
            switch (codepoint) {
                '.' => {
                    const identifier, _ = try parser.nextToken();
                    if (identifier != .token_ident) break :blk;
                    _ = try ast.addBasicNode(.class, main_location);
                    return;
                },
                else => {},
            }
        },
        .token_ident => {
            _ = try ast.addBasicNode(.type, main_location);
            return;
        },
        .token_hash_id => {
            _ = try ast.addBasicNode(.id, main_location);
            return;
        },
        .token_left_square => blk: {
            const name, const name_location = try nextTokenSkipWhitespace(parser);
            if (name != .token_ident) break :blk;

            const after_name, _ = try nextTokenSkipWhitespace(parser);
            if (after_name == .token_right_square) return ast.addAttributeWithoutValue(main_location, name_location);

            const value, const value_location = try nextTokenSkipWhitespace(parser);
            const right_bracket, _ = try nextTokenSkipWhitespace(parser);
            if ((after_name == .token_delim and after_name.token_delim == '=') and
                (value == .token_ident or value == .token_string) and
                (right_bracket == .token_right_square))
            {
                return ast.addAttributeWithValue(main_location, name_location, value.cast(Ast.Tag), value_location);
            }
        },

        else => {},
    }

    return parser.fail(.invalid_feature, main_location);
}

/// Used to help keep track of the last 3 non-whitespace nodes in a declaration's value.
const Last3NonWhitespaceNodes = struct {
    /// A queue of the indeces of the last 3 non-whitespace nodes.
    /// Note that this queue grows starting from the end. (i.e. the newest node index will be at index 2).
    nodes: [3]Ast.Size = undefined,
    len: u2 = 0,

    fn append(last_3: *Last3NonWhitespaceNodes, node_index: Ast.Size) void {
        comptime var i = 0;
        inline while (i < 2) : (i += 1) {
            last_3.nodes[i] = last_3.nodes[i + 1];
        }
        last_3.nodes[2] = node_index;
        last_3.len +|= 1;
    }
};

fn parseInlineStyleBlock(parser: *Parser, ast: AstManaged, main_location: Location) !void {
    const style_block_index = try ast.addComplexNode(.styles, main_location);

    {
        const token, const location = try nextTokenSkipWhitespace(parser);
        if (token == .token_right_paren)
            return parser.fail(.empty_inline_style_block, main_location)
        else
            parser.location = location;
    }

    while (true) {
        parser.block_stack.top = .{ .ending_tag = .token_right_paren, .node_index = undefined };

        const name, const name_location = try parser.nextToken();
        if (name != .token_ident) return parser.fail(.expected_identifier, name_location);
        const colon, const colon_location = try parser.nextToken();
        if (colon != .token_colon) return parser.fail(.expected_colon, colon_location);
        const declaration_index = try ast.addDeclaration(name_location);

        _ = try consumeWhitespace(parser);
        var last_3 = Last3NonWhitespaceNodes{};
        while (true) {
            const token, const location = try parser.nextToken();
            switch (token) {
                .token_semicolon => if (parser.block_stack.rest.len == 0) break,
                .token_whitespace => _ = try ast.addBasicNode(.token_whitespace, location),
                .token_left_curly, .token_left_paren, .token_left_square, .token_function => {
                    // TODO: detect if the block is empty
                    const max_block_depth = 32;
                    if (parser.block_stack.len() == max_block_depth) return parser.fail(.block_depth_limit_reached, location);
                    // zig fmt: off
                    const element_tag: Ast.Tag, const ending_tag: Ast.Tag = switch (token) {
                        .token_left_curly =>  .{ .simple_block_curly,  .token_right_curly  },
                        .token_left_square => .{ .simple_block_square, .token_right_square },
                        .token_left_paren =>  .{ .simple_block_paren,  .token_right_paren  },
                        .token_function =>    .{ .function,            .token_right_paren  },
                        else => unreachable,
                    };
                    // zig fmt: on
                    const node_index = try ast.addComplexNode(element_tag, location);
                    try parser.block_stack.push(parser.allocator, .{ .ending_tag = ending_tag, .node_index = node_index });
                    last_3.append(node_index);
                },
                .token_right_curly, .token_right_paren, .token_right_square => {
                    const tag = token.cast(Ast.Tag);
                    if (tag == parser.block_stack.top.?.ending_tag) {
                        const item = parser.block_stack.pop();
                        if (parser.block_stack.top == null) break;
                        ast.finishComplexNode(item.node_index);
                    } else {
                        const node_index = try ast.addBasicNode(tag, location);
                        last_3.append(node_index);
                    }
                },
                else => {
                    const node_index = switch (token) {
                        else => try ast.addBasicNode(token.cast(Ast.Tag), location),
                    };
                    last_3.append(node_index);
                },
            }
        }

        try ast.finishDeclaration(parser, declaration_index, last_3);

        if (parser.block_stack.top == null) {
            ast.finishInlineStyleBlock(style_block_index);
            return;
        }

        const after_decl, const after_decl_location = try nextTokenSkipWhitespace(parser);
        if (after_decl == .token_right_paren) {
            ast.finishInlineStyleBlock(style_block_index);
            return;
        } else {
            parser.location = after_decl_location;
        }
    }
}
