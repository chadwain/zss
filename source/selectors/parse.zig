const zss = @import("../zss.zig");
const Stylesheet = zss.Stylesheet;

const selectors = zss.selectors;
const ComplexSelector = selectors.ComplexSelector;
const ComplexSelectorList = selectors.ComplexSelectorList;
const CodeList = selectors.CodeList;
const Specificity = selectors.Specificity;

const Environment = zss.Environment;
const NamespaceId = Environment.Namespaces.Id;

const syntax = zss.syntax;
const Ast = syntax.Ast;
const Component = syntax.Component;
const TokenSource = syntax.TokenSource;

const std = @import("std");
const Allocator = std.mem.Allocator;
const MultiArrayList = std.MultiArrayList;

pub const Parser = struct {
    env: *Environment,
    source: TokenSource,
    ast: Ast,
    namespace_prefixes: *const std.StringArrayHashMapUnmanaged(NamespaceId),
    default_namespace: NamespaceId,

    sequence: Ast.Sequence = undefined,
    specificities: std.ArrayList(Specificity),
    valid: bool = undefined,
    specificity: Specificity = undefined,

    pub fn init(
        env: *Environment,
        allocator: Allocator,
        source: TokenSource,
        ast: Ast,
        namespaces: *const Stylesheet.Namespaces,
    ) Parser {
        return Parser{
            .env = env,
            .source = source,
            .ast = ast,
            .namespace_prefixes = &namespaces.prefixes,
            .default_namespace = namespaces.default orelse .any,

            .specificities = .init(allocator),
        };
    }

    pub fn deinit(parser: *Parser) void {
        parser.specificities.deinit();
    }

    pub fn parseComplexSelectorList(parser: *Parser, code_list: *CodeList, sequence: Ast.Sequence) !void {
        parser.sequence = sequence;
        parser.specificities.clearRetainingCapacity();
        const old_len = code_list.len();

        (try parseComplexSelector(parser, code_list)) orelse {
            code_list.reset(old_len);
            return parser.fail();
        };
        while (true) {
            _ = parser.skipSpaces();
            const comma_tag, _ = parser.next() orelse break;
            if (comma_tag != .token_comma) {
                code_list.reset(old_len);
                return parser.fail();
            }
            (try parseComplexSelector(parser, code_list)) orelse {
                code_list.reset(old_len);
                return parser.fail();
            };
        }

        if (parser.specificities.items.len == 0) {
            code_list.reset(old_len);
            return parser.fail();
        }
    }

    const SelectorKind = enum { id, class, attribute, pseudo_class, type, pseudo_element };

    fn addSpecificity(parser: *Parser, comptime kind: SelectorKind) void {
        const field_name = switch (kind) {
            .id => "a",
            .class, .attribute, .pseudo_class => "b",
            .type, .pseudo_element => "c",
        };
        const field = &@field(parser.specificity, field_name);
        field.* +|= 1;
    }

    fn fail(_: *Parser) error{ParseError} {
        return error.ParseError;
    }

    fn next(parser: *Parser) ?struct { Component.Tag, Ast.Size } {
        const index = parser.sequence.nextKeepSpaces(parser.ast) orelse return null;
        const tag = parser.ast.tag(index);
        return .{ tag, index };
    }

    /// If the next component is `accepted_tag`, then return that component index.
    fn accept(parser: *Parser, accepted_tag: Component.Tag) ?Ast.Size {
        const tag, const index = parser.next() orelse return null;
        if (accepted_tag == tag) {
            return index;
        } else {
            parser.sequence.reset(index);
            return null;
        }
    }

    /// Fails parsing if an unexpected component or EOF is encountered.
    fn expect(parser: *Parser, expected_tag: Component.Tag) !Ast.Size {
        const tag, const index = parser.next() orelse return parser.fail();
        return if (expected_tag == tag) index else parser.fail();
    }

    fn expectEof(parser: *Parser) !void {
        if (!parser.sequence.empty()) return parser.fail();
    }

    /// Returns true if any spaces were encountered.
    fn skipSpaces(parser: *Parser) bool {
        return parser.sequence.skipSpaces(parser.ast);
    }
};

fn parseComplexSelector(parser: *Parser, code_list: *CodeList) !?void {
    const complex_start = try code_list.beginComplexSelector();
    try parser.specificities.ensureUnusedCapacity(1);
    parser.specificity = .{};
    parser.valid = true;

    var compound_start = complex_start + 1;
    _ = parser.skipSpaces();
    (try parseCompoundSelector(parser, code_list)) orelse return parser.fail();

    while (true) {
        const combinator = parseCombinator(parser) orelse {
            try code_list.append(.{ .trailing = .{ .combinator = undefined, .compound_selector_start = compound_start } });
            break;
        };
        try code_list.append(.{ .trailing = .{ .combinator = combinator, .compound_selector_start = compound_start } });

        compound_start = code_list.len();
        _ = parser.skipSpaces();
        (try parseCompoundSelector(parser, code_list)) orelse {
            if (combinator == .descendant) {
                break;
            } else {
                return parser.fail();
            }
        };
    }

    if (!parser.valid) {
        code_list.reset(complex_start);
        return null;
    }
    code_list.endComplexSelector(complex_start);
    parser.specificities.appendAssumeCapacity(parser.specificity);
}

/// Syntax: <combinator> = '>' | '+' | '~' | [ '|' '|' ]
fn parseCombinator(parser: *Parser) ?selectors.Combinator {
    const has_space = parser.skipSpaces();
    if (parser.accept(.token_delim)) |index| {
        switch (parser.ast.extra(index).codepoint) {
            '>' => return .child,
            '+' => return .next_sibling,
            '~' => return .subsequent_sibling,
            '|' => {
                if (parser.accept(.token_delim)) |second_pipe| {
                    if (parser.ast.extra(second_pipe).codepoint == '|') return .column;
                }
            },
            else => {},
        }
        parser.sequence.reset(index);
    }
    return if (has_space) .descendant else null;
}

fn parseCompoundSelector(parser: *Parser, code_list: *CodeList) !?void {
    var parsed_any_selectors = false;

    if (try parseTypeSelector(parser, code_list)) |_| {
        parsed_any_selectors = true;
    }

    while (try parseSubclassSelector(parser, code_list)) |_| {
        parsed_any_selectors = true;
    }

    while (try parsePseudoElementSelector(parser, code_list)) |_| {
        parsed_any_selectors = true;
    }

    if (!parsed_any_selectors) return null;
}

fn parseTypeSelector(parser: *Parser, code_list: *CodeList) !?void {
    const qn = parseQualifiedName(parser) orelse return null;
    const type_selector: selectors.QualifiedName = .{
        .namespace = switch (qn.namespace) {
            .identifier => |identifier| try resolveNamespace(parser, identifier),
            .none => .none,
            .any => .any,
            .default => parser.default_namespace,
        },
        .name = switch (qn.name) {
            .identifier => |identifier| try parser.env.addTypeOrAttributeName(identifier, parser.source),
            .any => .any,
        },
    };
    try code_list.appendSlice(&.{
        .{ .simple_selector_tag = .type },
        .{ .type_selector = type_selector },
    });
    if (type_selector.name != .any) {
        parser.addSpecificity(.type);
    }
}

const QualifiedName = struct {
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
fn parseQualifiedName(parser: *Parser) ?QualifiedName {
    // I consider the following grammar easier to comprehend.
    // Just like the real grammar, no spaces are allowed anywhere.
    //
    // Syntax: <type-selector> = <ns-prefix>? <type-name>
    //         <ns-prefix>     = <type-name>? '|'
    //         <type-name>     = <ident-token> | '*'

    var qn: QualifiedName = undefined;

    const tag, const index = parser.next() orelse return null;
    qn.name = name: {
        switch (tag) {
            .token_ident => break :name .{ .identifier = parser.ast.location(index) },
            .token_delim => switch (parser.ast.extra(index).codepoint) {
                '*' => break :name .any,
                '|' => {
                    if (parseName(parser)) |name| {
                        return .{
                            .namespace = .none,
                            .name = name,
                        };
                    }
                },
                else => {},
            },
            else => {},
        }
        parser.sequence.reset(index);
        return null;
    };

    if (parser.accept(.token_delim)) |pipe_index| {
        if (parser.ast.extra(pipe_index).codepoint == '|') {
            if (parseName(parser)) |name| {
                qn.namespace = switch (qn.name) {
                    .identifier => |location| .{ .identifier = location },
                    .any => .any,
                };
                qn.name = name;
                return qn;
            }
        }
        parser.sequence.reset(pipe_index);
    }

    qn.namespace = .default;
    return qn;
}

/// Syntax: <ident-token> | '*'
fn parseName(parser: *Parser) ?QualifiedName.Name {
    const tag, const index = parser.next() orelse return null;
    switch (tag) {
        .token_ident => return .{ .identifier = parser.ast.location(index) },
        .token_delim => if (parser.ast.extra(index).codepoint == '*') return .any,
        else => {},
    }
    parser.sequence.reset(index);
    return null;
}

fn resolveNamespace(parser: *Parser, location: TokenSource.Location) !NamespaceId {
    // TODO: Don't allocate memory
    const copy = try parser.source.copyIdentifier(location, parser.specificities.allocator);
    defer parser.specificities.allocator.free(copy);
    const id = parser.namespace_prefixes.get(copy) orelse {
        parser.valid = false;
        return undefined;
    };
    return id;
}

fn parseSubclassSelector(parser: *Parser, code_list: *CodeList) !?void {
    const first_component_tag, const first_component_index = parser.next() orelse return null;
    switch (first_component_tag) {
        .token_hash_id => {
            const location = parser.ast.location(first_component_index);
            const name = try parser.env.addIdName(location, parser.source);
            try code_list.appendSlice(&.{
                .{ .simple_selector_tag = .id },
                .{ .id_selector = name },
            });
            parser.addSpecificity(.id);
            return;
        },
        .token_delim => class_selector: {
            if (parser.ast.extra(first_component_index).codepoint != '.') break :class_selector;
            const class_name_index = parser.accept(.token_ident) orelse break :class_selector;
            const location = parser.ast.location(class_name_index);
            const name = try parser.env.addClassName(location, parser.source);
            try code_list.appendSlice(&.{
                .{ .simple_selector_tag = .class },
                .{ .class_selector = name },
            });
            parser.addSpecificity(.class);
            return;
        },
        .simple_block_square => {
            try parseAttributeSelector(parser, code_list, first_component_index);
            parser.addSpecificity(.attribute);
            return;
        },
        .token_colon => pseudo_class_selector: {
            const pseudo_class = parsePseudo(.class, parser) orelse break :pseudo_class_selector;
            try code_list.appendSlice(&.{
                .{ .simple_selector_tag = .pseudo_class },
                .{ .pseudo_class_selector = pseudo_class },
            });
            parser.addSpecificity(.pseudo_class);
            return;
        },
        else => {},
    }

    parser.sequence.reset(first_component_index);
    return null;
}

fn parseAttributeSelector(parser: *Parser, code_list: *CodeList, block_index: Ast.Size) !void {
    const sequence = parser.sequence;
    defer parser.sequence = sequence;
    parser.sequence = parser.ast.children(block_index);

    // Parse the attribute namespace and name
    _ = parser.skipSpaces();
    const qn = parseQualifiedName(parser) orelse return parser.fail();
    const attribute_selector: selectors.QualifiedName = .{
        .namespace = switch (qn.namespace) {
            .identifier => |identifier| try resolveNamespace(parser, identifier),
            .none => .none,
            .any => .any,
            .default => .none,
        },
        .name = switch (qn.name) {
            .identifier => |identifier| try parser.env.addTypeOrAttributeName(identifier, parser.source),
            .any => return parser.fail(),
        },
    };

    _ = parser.skipSpaces();
    const after_qn_tag, const after_qn_index = parser.next() orelse {
        try code_list.appendSlice(&.{
            .{ .simple_selector_tag = .{ .attribute = null } },
            .{ .attribute_selector = attribute_selector },
        });
        return;
    };

    // Parse the attribute matcher
    const operator = operator: {
        if (after_qn_tag != .token_delim) return parser.fail();
        const codepoint = parser.ast.extra(after_qn_index).codepoint;
        const operator: selectors.AttributeOperator = switch (codepoint) {
            '=' => .equals,
            '~' => .list_contains,
            '|' => .equals_or_prefix_dash,
            '^' => .starts_with,
            '$' => .ends_with,
            '*' => .contains,
            else => return parser.fail(),
        };
        if (operator != .equals) {
            const equal_sign = try parser.expect(.token_delim);
            if (parser.ast.extra(equal_sign).codepoint != '=') return parser.fail();
        }
        break :operator operator;
    };

    // Parse the attribute value
    _ = parser.skipSpaces();
    const value_tag, const value_index = parser.next() orelse return parser.fail();
    switch (value_tag) {
        .token_ident, .token_string => {},
        else => return parser.fail(),
    }

    // Parse the case modifier
    _ = parser.skipSpaces();
    const case: selectors.AttributeCase = case: {
        if (parser.accept(.token_ident)) |case_index| {
            const location = parser.ast.location(case_index);
            const case = parser.source.mapIdentifier(location, selectors.AttributeCase, &.{
                .{ "i", .ignore_case },
                .{ "s", .same_case },
            }) orelse return parser.fail();
            break :case case;
        } else {
            break :case .default;
        }
    };

    _ = parser.skipSpaces();
    try parser.expectEof();
    try code_list.appendSlice(&.{
        .{ .simple_selector_tag = .{ .attribute = .{ .operator = operator, .case = case } } },
        .{ .attribute_selector = attribute_selector },
        .{ .attribute_selector_value = value_index },
    });
}

fn parsePseudoElementSelector(parser: *Parser, code_list: *CodeList) !?void {
    const element_index = parser.accept(.token_colon) orelse return null;
    const pseudo_element: selectors.PseudoElement = blk: {
        if (parser.accept(.token_colon)) |_| {
            break :blk parsePseudo(.element, parser);
        } else {
            break :blk parsePseudo(.legacy_element, parser);
        }
    } orelse {
        parser.sequence.reset(element_index);
        return null;
    };
    try code_list.appendSlice(&.{
        .{ .simple_selector_tag = .pseudo_element },
        .{ .pseudo_element_selector = pseudo_element },
    });
    parser.addSpecificity(.pseudo_element);

    while (true) {
        const class_index = parser.accept(.token_colon) orelse break;
        const pseudo_class = parsePseudo(.class, parser) orelse {
            parser.sequence.reset(class_index);
            break;
        };
        try code_list.appendSlice(&.{
            .{ .simple_selector_tag = .pseudo_class },
            .{ .pseudo_class_selector = pseudo_class },
        });
        parser.addSpecificity(.pseudo_class);
    }
}

fn parsePseudo(comptime what: enum { element, class, legacy_element }, parser: *Parser) ?switch (what) {
    .element, .legacy_element => selectors.PseudoElement,
    .class => selectors.PseudoClass,
} {
    const main_component_tag, const main_component_index = parser.next() orelse return null;
    switch (main_component_tag) {
        .token_ident => {
            // TODO: Get the actual pseudo element/class name.
            return .unrecognized;
        },
        .function => {
            var function_values = parser.ast.children(main_component_index);
            if (anyValue(parser.ast, &function_values)) {
                // TODO: Get the actual pseudo element/class name.
                return .unrecognized;
            }
        },
        else => {},
    }
    parser.sequence.reset(main_component_index);
    return null;
}

/// Returns true if the sequence matches the grammar of <any-value>.
fn anyValue(ast: Ast, sequence: *Ast.Sequence) bool {
    while (sequence.nextKeepSpaces(ast)) |index| {
        switch (ast.tag(index)) {
            .token_bad_string, .token_bad_url, .token_right_paren, .token_right_square, .token_right_curly => return false,
            else => {},
        }
    }
    return true;
}
