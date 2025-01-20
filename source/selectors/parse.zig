const zss = @import("../zss.zig");
const selectors = zss.selectors;
const ComplexSelector = selectors.ComplexSelector;
const ComplexSelectorList = selectors.ComplexSelectorList;
const Specificity = selectors.Specificity;

const Environment = zss.Environment;
const NamespaceId = Environment.NamespaceId;

const syntax = zss.syntax;
const Ast = syntax.Ast;
const Component = syntax.Component;
const TokenSource = syntax.TokenSource;

const std = @import("std");
const panic = std.debug.panic;
const Allocator = std.mem.Allocator;
const MultiArrayList = std.MultiArrayList;

pub const Parser = struct {
    env: *Environment,
    allocator: Allocator,
    source: TokenSource,
    ast: Ast.Slice,
    sequence: Ast.Sequence,
    default_namespace: NamespaceId,

    data: zss.ArrayListSized(ComplexSelector.Data) = undefined,
    specificity: Specificity = undefined,

    pub fn init(
        env: *Environment,
        allocator: Allocator,
        source: TokenSource,
        ast: Ast.Slice,
        sequence: Ast.Sequence,
    ) Parser {
        return Parser{
            .env = env,
            .allocator = allocator,
            .source = source,
            .ast = ast,
            .sequence = sequence,
            .default_namespace = env.default_namespace orelse NamespaceId.any,
        };
    }

    pub fn parseComplexSelectorList(parser: *Parser) !ComplexSelectorList {
        parser.data = .{ .max_size = std.math.maxInt(ComplexSelector.Index) };
        defer parser.data.deinit(parser.allocator);

        var list = MultiArrayList(ComplexSelectorList.Item){};
        errdefer {
            for (list.items(.complex)) |item| parser.allocator.free(item.data);
            list.deinit(parser.allocator);
        }

        var expecting_comma = false;
        while (true) {
            if (expecting_comma) {
                _ = parser.skipSpaces();
                (try parser.expectComponentAllowEof(.token_comma)) orelse break;
                expecting_comma = false;
            } else {
                try list.ensureUnusedCapacity(parser.allocator, 1);
                parser.specificity = .{};
                try parseComplexSelector(parser);
                const data = try parser.data.toOwnedSlice(parser.allocator);
                list.appendAssumeCapacity(.{ .complex = .{ .data = data }, .specificity = parser.specificity });
                expecting_comma = true;
            }
        }

        if (list.len == 0) {
            return parser.fail();
        }
        return .{ .list = list.slice() };
    }

    fn fail(_: *Parser) error{ParseError} {
        return error.ParseError;
    }

    fn nextComponent(parser: *Parser) ?struct { Component.Tag, Ast.Size } {
        const index = parser.sequence.nextKeepSpaces(parser.ast) orelse return null;
        const tag = parser.ast.tag(index);
        return .{ tag, index };
    }

    /// If the next component is `accepted_tag`, then return that component index.
    fn acceptComponent(parser: *Parser, accepted_tag: Component.Tag) ?Ast.Size {
        const tag, const index = parser.nextComponent() orelse return null;
        if (accepted_tag == tag) {
            return index;
        } else {
            parser.sequence.reset(index);
            return null;
        }
    }

    /// Returns null if EOF is encountered; otherwise, fails parsing if an unexpected component is encountered.
    fn expectComponentAllowEof(parser: *Parser, expected_tag: Component.Tag) !?void {
        const tag, _ = parser.nextComponent() orelse return null;
        return if (expected_tag == tag) {} else parser.fail();
    }

    /// Fails parsing if an unexpected component or EOF is encountered.
    fn expectComponent(parser: *Parser, expected_tag: Component.Tag) !Ast.Size {
        const tag, const index = parser.nextComponent() orelse return parser.fail();
        return if (expected_tag == tag) index else parser.fail();
    }

    /// Returns true if any spaces were encountered.
    fn skipSpaces(parser: *Parser) bool {
        return parser.sequence.skipSpaces(parser.ast);
    }
};

fn parseComplexSelector(parser: *Parser) !void {
    var start: ComplexSelector.Index = @intCast(parser.data.len());
    _ = parser.skipSpaces();
    (try parseCompoundSelector(parser)) orelse return parser.fail();

    while (true) {
        const combinator = (try parseCombinator(parser)) orelse {
            try parser.data.append(parser.allocator, .{ .trailing = .{ .combinator = undefined, .compound_selector_start = start } });
            break;
        };
        try parser.data.append(parser.allocator, .{ .trailing = .{ .combinator = combinator, .compound_selector_start = start } });

        start = @intCast(parser.data.len());
        _ = parser.skipSpaces();
        (try parseCompoundSelector(parser)) orelse {
            if (combinator == .descendant) {
                parser.data.items()[start - 1].trailing.combinator = undefined;
                break;
            } else {
                return parser.fail();
            }
        };
    }
}

/// Syntax: <combinator> = '>' | '+' | '~' | [ '|' '|' ]
fn parseCombinator(parser: *Parser) !?selectors.Combinator {
    const has_space = parser.skipSpaces();
    if (parser.acceptComponent(.token_delim)) |index| {
        switch (parser.ast.extra(index).codepoint) {
            '>' => return .child,
            '+' => return .next_sibling,
            '~' => return .subsequent_sibling,
            '|' => {
                const second_pipe = try parser.expectComponent(.token_delim);
                if (parser.ast.extra(second_pipe).codepoint != '|') return parser.fail();
                return .column;
            },
            else => {},
        }
        parser.sequence.reset(index);
    }
    return if (has_space) .descendant else null;
}

fn parseCompoundSelector(parser: *Parser) !?void {
    var num_selectors: ComplexSelector.Index = 0;

    if (try parseTypeSelector(parser)) |_| {
        num_selectors += 1;
    }

    while (try parseSubclassSelector(parser)) |_| {
        num_selectors += 1;
    }

    while (try parsePseudoElementSelector(parser)) |_| {
        num_selectors += 1;
    }

    if (num_selectors == 0) return null;
}

fn parseTypeSelector(parser: *Parser) !?void {
    const ty = (try parseType(parser)) orelse return null;
    const type_selector: selectors.Type = .{
        .namespace = switch (ty.namespace) {
            .identifier => panic("TODO: Namespaces in type selectors", .{}),
            .none => .none,
            .any => .any,
            .default => parser.default_namespace,
        },
        .name = switch (ty.name) {
            .identifier => |identifier| try parser.env.addTypeOrAttributeName(identifier, parser.source),
            .any => .any,
        },
    };
    try parser.data.appendSlice(parser.allocator, &.{
        .{ .simple_selector_tag = .type },
        .{ .type_selector = type_selector },
    });
    if (type_selector.name != .any) {
        parser.specificity.add(.type_ident);
    }
}

const Type = struct {
    namespace: Namespace,
    name: Name,

    const Namespace = union(enum) {
        identifier: TokenSource.Location,
        none,
        any,
        default,
    };
    const Name = union(enum) {
        identifier: TokenSource.Location,
        any,
    };
};

/// Syntax: <type-selector> = <wq-name> | <ns-prefix>? '*'
///         <ns-prefix>     = [ <ident-token> | '*' ]? '|'
///         <wq-name>       = <ns-prefix>? <ident-token>
///
///         Spaces are forbidden between any of these components.
fn parseType(parser: *Parser) !?Type {
    // I consider the following grammar easier to comprehend.
    // Just like the real grammar, no spaces are allowed anywhere.
    //
    // Syntax: <type-selector> = <ns-prefix>? <type-name>
    //         <ns-prefix>     = <type-name>? '|'
    //         <type-name>     = <ident-token> | '*'

    var ty: Type = undefined;

    const tag, const index = parser.nextComponent() orelse return null;
    ty.name = name: {
        switch (tag) {
            .token_ident => break :name .{ .identifier = parser.ast.location(index) },
            .token_delim => switch (parser.ast.extra(index).codepoint) {
                '*' => break :name .any,
                '|' => {
                    const name = try parseTypeName(parser);
                    return .{
                        .namespace = .none,
                        .name = name,
                    };
                },
                else => {},
            },
            else => {},
        }
        parser.sequence.reset(index);
        return null;
    };

    if (parser.acceptComponent(.token_delim)) |pipe_index| {
        if (parser.ast.extra(pipe_index).codepoint == '|') {
            const name = try parseTypeName(parser);
            ty.namespace = switch (ty.name) {
                .identifier => |location| .{ .identifier = location },
                .any => .any,
            };
            ty.name = name;
            return ty;
        }
        parser.sequence.reset(pipe_index);
    }

    ty.namespace = .default;
    return ty;
}

/// Syntax: <ident-token> | '*'
fn parseTypeName(parser: *Parser) !Type.Name {
    const tag, const index = parser.nextComponent() orelse return parser.fail();
    return switch (tag) {
        .token_ident => .{ .identifier = parser.ast.location(index) },
        .token_delim => if (parser.ast.extra(index).codepoint == '*') .any else parser.fail(),
        else => parser.fail(),
    };
}

fn parseSubclassSelector(parser: *Parser) !?void {
    const first_component_tag, const first_component_index = parser.nextComponent() orelse return null;
    switch (first_component_tag) {
        .token_hash_id => {
            const location = parser.ast.location(first_component_index);
            const name = try parser.env.addIdName(location, parser.source);
            try parser.data.appendSlice(parser.allocator, &.{
                .{ .simple_selector_tag = .id },
                .{ .id_selector = name },
            });
            parser.specificity.add(.id);
            return;
        },
        .token_delim => {
            if (parser.ast.extra(first_component_index).codepoint == '.') {
                const class_name = try parser.expectComponent(.token_ident);
                const location = parser.ast.location(class_name);
                const name = try parser.env.addClassName(location, parser.source);
                try parser.data.appendSlice(parser.allocator, &.{
                    .{ .simple_selector_tag = .class },
                    .{ .class_selector = name },
                });
                parser.specificity.add(.class);
                return;
            }
        },
        .simple_block_square => {
            const saved_sequence = parser.sequence;
            defer parser.sequence = saved_sequence;
            parser.sequence = parser.ast.children(first_component_index);
            try parseAttributeSelector(parser);
            _ = parser.skipSpaces();
            if (!parser.sequence.empty()) return parser.fail();
            parser.specificity.add(.attribute);
            return;
        },
        .token_colon => {
            const pseudo_class = try parsePseudo(parser, .class);
            try parser.data.appendSlice(parser.allocator, &.{
                .{ .simple_selector_tag = .pseudo_class },
                .{ .pseudo_class_selector = pseudo_class },
            });
            parser.specificity.add(.pseudo_class);
            return;
        },
        else => {},
    }

    parser.sequence.reset(first_component_index);
    return null;
}

fn parseAttributeSelector(parser: *Parser) !void {
    // Parse the attribute namespace and name
    _ = parser.skipSpaces();
    const element_type = (try parseType(parser)) orelse return parser.fail();
    const attribute_selector: selectors.Type = .{
        .namespace = switch (element_type.namespace) {
            .identifier => panic("TODO: Namespaces in attribute selectors", .{}),
            .none => .none,
            .any => .any,
            .default => .none,
        },
        .name = switch (element_type.name) {
            .identifier => |identifier| try parser.env.addTypeOrAttributeName(identifier, parser.source),
            .any => return parser.fail(),
        },
    };

    // Parse the attribute matcher
    _ = parser.skipSpaces();
    const attr_matcher_index = parser.acceptComponent(.token_delim) orelse {
        try parser.data.appendSlice(parser.allocator, &.{
            .{ .simple_selector_tag = .{ .attribute = null } },
            .{ .attribute_selector = attribute_selector },
        });
        return;
    };
    const attr_matcher_codepoint = parser.ast.extra(attr_matcher_index).codepoint;
    const operator: selectors.AttributeOperator = switch (attr_matcher_codepoint) {
        '=' => .equals,
        '~' => .list_contains,
        '|' => .equals_or_prefix_dash,
        '^' => .starts_with,
        '$' => .ends_with,
        '*' => .contains,
        else => return parser.fail(),
    };
    if (operator != .equals) {
        const equal_sign_index = try parser.expectComponent(.token_delim);
        const codepoint = parser.ast.extra(equal_sign_index).codepoint;
        if (codepoint != '=') return parser.fail();
    }

    // Parse the attribute value
    _ = parser.skipSpaces();
    const value_tag, const value_index = parser.nextComponent() orelse return parser.fail();
    switch (value_tag) {
        .token_ident, .token_string => {},
        else => return parser.fail(),
    }

    // Parse the case modifier
    _ = parser.skipSpaces();
    const case: selectors.AttributeCase = if (parser.acceptComponent(.token_ident)) |case_index| case: {
        const case_location = parser.ast.location(case_index);
        break :case parser.source.mapIdentifier(case_location, selectors.AttributeCase, &.{
            .{ "i", .ignore_case },
            .{ "s", .same_case },
        }) orelse return parser.fail();
    } else .default;

    try parser.data.appendSlice(parser.allocator, &.{
        .{ .simple_selector_tag = .{ .attribute = .{ .operator = operator, .case = case } } },
        .{ .attribute_selector = attribute_selector },
        .{ .attribute_selector_value = value_index },
    });
}

fn parsePseudoElementSelector(parser: *Parser) !?void {
    _ = parser.acceptComponent(.token_colon) orelse return null;
    _ = try parser.expectComponent(.token_colon);

    const pseudo_element = try parsePseudo(parser, .element);
    try parser.data.appendSlice(parser.allocator, &.{
        .{ .simple_selector_tag = .pseudo_element },
        .{ .pseudo_element_selector = pseudo_element },
    });
    parser.specificity.add(.pseudo_element);

    while (true) {
        _ = parser.acceptComponent(.token_colon) orelse break;
        const pseudo_class = try parsePseudo(parser, .class);
        try parser.data.appendSlice(parser.allocator, &.{
            .{ .simple_selector_tag = .pseudo_class },
            .{ .pseudo_class_selector = pseudo_class },
        });
        parser.specificity.add(.pseudo_class);
    }
}

// Assumes that the previous Ast node was a `token_colon`.
fn parsePseudo(parser: *Parser, comptime what: enum { element, class }) !switch (what) {
    .element => selectors.PseudoElement,
    .class => selectors.PseudoClass,
} {
    const main_component_tag, const main_component_index = parser.nextComponent() orelse return parser.fail();
    switch (main_component_tag) {
        .token_ident => {
            // TODO: Get the actual pseudo class name.
            return .unrecognized;
        },
        .function => {
            var function_values = parser.ast.children(main_component_index);
            if (anyValue(parser.ast, &function_values)) {
                // TODO: Get the actual pseudo class name.
                return .unrecognized;
            }
        },
        else => {},
    }
    return parser.fail();
}

/// Returns true if the sequence matches the grammar of <any-value>.
fn anyValue(ast: Ast.Slice, sequence: *Ast.Sequence) bool {
    while (sequence.nextKeepSpaces(ast)) |index| {
        switch (ast.tag(index)) {
            .token_bad_string, .token_bad_url, .token_right_paren, .token_right_square, .token_right_curly => return false,
            else => {},
        }
    }
    return true;
}
