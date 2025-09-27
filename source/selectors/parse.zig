const zss = @import("../zss.zig");
const Stylesheet = zss.Stylesheet;

const selectors = zss.selectors;
const Data = selectors.Data;
const Specificity = selectors.Specificity;

const Environment = zss.Environment;
const NamespaceId = Environment.Namespaces.Id;
const ElementType = Environment.ElementType;
const ElementAttribute = Environment.ElementAttribute;

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
    namespaces: *const Stylesheet.Namespaces,
    default_namespace: NamespaceId,

    sequence: Ast.Sequence = undefined,
    specificities: std.ArrayList(Specificity),
    allocator: Allocator,
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
            .namespaces = namespaces,
            .default_namespace = namespaces.default orelse .any,

            .specificities = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(parser: *Parser) void {
        parser.specificities.deinit(parser.allocator);
    }

    /// Attempts to parse a <complex-selector-list> from `sequence`, and append the selector data to `data_list`.
    /// If any one of the complex selectors fails to parse, then the entire parse fails, and `data_list` is reverted to its original state.
    /// Each complex selector will have its specificity found in `parser.specificities.items`.
    pub fn parseComplexSelectorList(
        parser: *Parser,
        data_list: *std.ArrayList(Data),
        data_list_allocator: Allocator,
        sequence: Ast.Sequence,
    ) !void {
        parser.sequence = sequence;
        parser.specificities.clearRetainingCapacity();

        const managed = DataListManaged{ .list = data_list, .allocator = data_list_allocator };
        const old_len = managed.len();

        (try parseComplexSelector(parser, managed)) orelse {
            managed.reset(old_len);
            return parser.fail();
        };
        while (true) {
            _ = parser.skipSpaces();
            const comma_tag, _ = parser.next() orelse break;
            if (comma_tag != .token_comma) {
                managed.reset(old_len);
                return parser.fail();
            }
            (try parseComplexSelector(parser, managed)) orelse {
                managed.reset(old_len);
                return parser.fail();
            };
        }

        if (parser.specificities.items.len == 0) {
            managed.reset(old_len);
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

    fn next(parser: *Parser) ?struct { Component.Tag, Ast.Index } {
        const index = parser.sequence.nextKeepSpaces(parser.ast) orelse return null;
        const tag = index.tag(parser.ast);
        return .{ tag, index };
    }

    /// If the next component is `accepted_tag`, then return that component index.
    fn accept(parser: *Parser, accepted_tag: Component.Tag) ?Ast.Index {
        const tag, const index = parser.next() orelse return null;
        if (accepted_tag == tag) {
            return index;
        } else {
            parser.sequence.reset(index);
            return null;
        }
    }

    /// Fails parsing if an unexpected component or EOF is encountered.
    fn expect(parser: *Parser, expected_tag: Component.Tag) !Ast.Index {
        const tag, const index = parser.next() orelse return parser.fail();
        return if (expected_tag == tag) index else parser.fail();
    }

    fn expectEof(parser: *Parser) !void {
        if (!parser.sequence.emptyKeepSpaces()) return parser.fail();
    }

    /// Returns true if any spaces were encountered.
    fn skipSpaces(parser: *Parser) bool {
        return parser.sequence.skipSpaces(parser.ast);
    }
};

const DataListManaged = struct {
    list: *std.ArrayList(Data),
    allocator: Allocator,

    fn len(data_list: DataListManaged) Data.ListIndex {
        return @intCast(data_list.list.items.len);
    }

    fn append(data_list: DataListManaged, code: Data) !void {
        if (data_list.list.items.len == std.math.maxInt(Data.ListIndex)) return error.OutOfMemory;
        try data_list.list.append(data_list.allocator, code);
    }

    fn appendSlice(data_list: DataListManaged, codes: []const Data) !void {
        if (codes.len > std.math.maxInt(Data.ListIndex) - data_list.list.items.len) return error.OutOfMemory;
        try data_list.list.appendSlice(data_list.allocator, codes);
    }

    fn beginComplexSelector(data_list: DataListManaged) !Data.ListIndex {
        const index = data_list.len();
        try data_list.append(undefined);
        return index;
    }

    /// `start` is the value previously returned by `beginComplexSelector`
    fn endComplexSelector(data_list: DataListManaged, start: Data.ListIndex) void {
        data_list.list.items[start] = .{ .next_complex_selector = data_list.len() };
        data_list.list.items[data_list.len() - 1].trailing.combinator = undefined;
    }

    fn reset(data_list: DataListManaged, complex_selector_start: Data.ListIndex) void {
        data_list.list.shrinkRetainingCapacity(complex_selector_start);
    }
};

fn parseComplexSelector(parser: *Parser, data_list: DataListManaged) !?void {
    const complex_start = try data_list.beginComplexSelector();
    try parser.specificities.ensureUnusedCapacity(parser.allocator, 1);
    parser.specificity = .{};
    parser.valid = true;

    var compound_start = complex_start + 1;
    _ = parser.skipSpaces();
    (try parseCompoundSelector(parser, data_list)) orelse return parser.fail();

    while (true) {
        const combinator = parseCombinator(parser) orelse {
            try data_list.append(.{ .trailing = .{ .combinator = undefined, .compound_selector_start = compound_start } });
            break;
        };
        try data_list.append(.{ .trailing = .{ .combinator = combinator, .compound_selector_start = compound_start } });

        compound_start = data_list.len();
        _ = parser.skipSpaces();
        (try parseCompoundSelector(parser, data_list)) orelse {
            if (combinator == .descendant) {
                break;
            } else {
                return parser.fail();
            }
        };
    }

    if (!parser.valid) {
        data_list.reset(complex_start);
        return null;
    }
    data_list.endComplexSelector(complex_start);
    parser.specificities.appendAssumeCapacity(parser.specificity);
}

/// Syntax: <combinator> = '>' | '+' | '~' | [ '|' '|' ]
fn parseCombinator(parser: *Parser) ?selectors.Combinator {
    const has_space = parser.skipSpaces();
    if (parser.accept(.token_delim)) |index| {
        switch (index.extra(parser.ast).codepoint) {
            '>' => return .child,
            '+' => return .next_sibling,
            '~' => return .subsequent_sibling,
            '|' => {
                if (parser.accept(.token_delim)) |second_pipe| {
                    if (second_pipe.extra(parser.ast).codepoint == '|') return .column;
                }
            },
            else => {},
        }
        parser.sequence.reset(index);
    }
    return if (has_space) .descendant else null;
}

fn parseCompoundSelector(parser: *Parser, data_list: DataListManaged) !?void {
    var parsed_any_selectors = false;

    if (try parseTypeSelector(parser, data_list)) |_| {
        parsed_any_selectors = true;
    }

    while (try parseSubclassSelector(parser, data_list)) |_| {
        parsed_any_selectors = true;
    }

    while (try parsePseudoElementSelector(parser, data_list)) |_| {
        parsed_any_selectors = true;
    }

    if (!parsed_any_selectors) return null;
}

fn parseTypeSelector(parser: *Parser, data_list: DataListManaged) !?void {
    const qn = parseQualifiedName(parser) orelse return null;
    const type_selector: ElementType = .{
        .namespace = switch (qn.namespace) {
            .identifier => |identifier| resolveNamespace(parser, identifier),
            .none => .none,
            .any => .any,
            .default => parser.default_namespace,
        },
        .name = switch (qn.name) {
            .identifier => |identifier| try parser.env.addTypeName(identifier.location(parser.ast), parser.source),
            .any => .any,
        },
    };
    try data_list.appendSlice(&.{
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
        identifier: Ast.Index,
        none,
        any,
        default,
    };
    const Name = union(enum) {
        identifier: Ast.Index,
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
            .token_ident => break :name .{ .identifier = index },
            .token_delim => switch (index.extra(parser.ast).codepoint) {
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
        if (pipe_index.extra(parser.ast).codepoint == '|') {
            if (parseName(parser)) |name| {
                qn.namespace = switch (qn.name) {
                    .identifier => |name_index| .{ .identifier = name_index },
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
        .token_ident => return .{ .identifier = index },
        .token_delim => if (index.extra(parser.ast).codepoint == '*') return .any,
        else => {},
    }
    parser.sequence.reset(index);
    return null;
}

fn resolveNamespace(parser: *Parser, index: Ast.Index) NamespaceId {
    const namespace_index = parser.namespaces.indexer.getFromIdentTokenSensitive(index.location(parser.ast), parser.source) orelse {
        parser.valid = false;
        return undefined;
    };
    return parser.namespaces.ids.items[namespace_index];
}

fn parseSubclassSelector(parser: *Parser, data_list: DataListManaged) !?void {
    const first_component_tag, const first_component_index = parser.next() orelse return null;
    switch (first_component_tag) {
        .token_hash_id => {
            const location = first_component_index.location(parser.ast);
            const name = try parser.env.addIdName(location, parser.source);
            try data_list.appendSlice(&.{
                .{ .simple_selector_tag = .id },
                .{ .id_selector = name },
            });
            parser.addSpecificity(.id);
            return;
        },
        .token_delim => class_selector: {
            if (first_component_index.extra(parser.ast).codepoint != '.') break :class_selector;
            const class_name_index = parser.accept(.token_ident) orelse break :class_selector;
            const location = class_name_index.location(parser.ast);
            const name = try parser.env.addClassName(location, parser.source);
            try data_list.appendSlice(&.{
                .{ .simple_selector_tag = .class },
                .{ .class_selector = name },
            });
            parser.addSpecificity(.class);
            return;
        },
        .simple_block_square => {
            try parseAttributeSelector(parser, data_list, first_component_index);
            parser.addSpecificity(.attribute);
            return;
        },
        .token_colon => pseudo_class_selector: {
            const pseudo_class = parsePseudo(.class, parser) orelse break :pseudo_class_selector;
            try data_list.appendSlice(&.{
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

fn parseAttributeSelector(parser: *Parser, data_list: DataListManaged, block_index: Ast.Index) !void {
    const sequence = parser.sequence;
    defer parser.sequence = sequence;
    parser.sequence = block_index.children(parser.ast);

    // Parse the attribute namespace and name
    _ = parser.skipSpaces();
    const qn = parseQualifiedName(parser) orelse return parser.fail();
    const attribute_selector: ElementAttribute = .{
        .namespace = switch (qn.namespace) {
            .identifier => |identifier| resolveNamespace(parser, identifier),
            .none => .none,
            .any => .any,
            .default => .none,
        },
        .name = switch (qn.name) {
            .identifier => |identifier| try parser.env.addAttributeName(identifier.location(parser.ast), parser.source),
            .any => return parser.fail(),
        },
    };

    _ = parser.skipSpaces();
    const after_qn_tag, const after_qn_index = parser.next() orelse {
        try data_list.appendSlice(&.{
            .{ .simple_selector_tag = .{ .attribute = null } },
            .{ .attribute_selector = attribute_selector },
        });
        return;
    };

    // Parse the attribute matcher
    const operator = operator: {
        if (after_qn_tag != .token_delim) return parser.fail();
        const codepoint = after_qn_index.extra(parser.ast).codepoint;
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
            if (equal_sign.extra(parser.ast).codepoint != '=') return parser.fail();
        }
        break :operator operator;
    };

    // Parse the attribute value
    _ = parser.skipSpaces();
    const value_tag, const value_index = parser.next() orelse return parser.fail();
    const attribute_value = switch (value_tag) {
        .token_ident => try parser.env.addAttributeValueIdent(value_index.location(parser.ast), parser.source),
        .token_string,
        => try parser.env.addAttributeValueString(value_index.location(parser.ast), parser.source),
        else => return parser.fail(),
    };

    // Parse the case modifier
    _ = parser.skipSpaces();
    const case: selectors.AttributeCase = case: {
        if (parser.accept(.token_ident)) |case_index| {
            const location = case_index.location(parser.ast);
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
    try data_list.appendSlice(&.{
        .{ .simple_selector_tag = .{ .attribute = .{ .operator = operator, .case = case } } },
        .{ .attribute_selector = attribute_selector },
        .{ .attribute_selector_value = attribute_value },
    });
}

fn parsePseudoElementSelector(parser: *Parser, data_list: DataListManaged) !?void {
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
    try data_list.appendSlice(&.{
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
        try data_list.appendSlice(&.{
            .{ .simple_selector_tag = .pseudo_class },
            .{ .pseudo_class_selector = pseudo_class },
        });
        parser.addSpecificity(.pseudo_class);
    }
}

const Pseudo = enum { element, class, legacy_element };

fn parsePseudo(comptime pseudo: Pseudo, parser: *Parser) ?switch (pseudo) {
    .element, .legacy_element => selectors.PseudoElement,
    .class => selectors.PseudoClass,
} {
    const main_component_tag, const main_component_index = parser.next() orelse return null;
    switch (main_component_tag) {
        .token_ident => {
            if (pseudo == .class and parser.source.matchIdentifierEnum(main_component_index.location(parser.ast), selectors.PseudoClass) == .root) {
                return .root;
            }
            return unrecognizedPseudo(pseudo, parser, main_component_index);
        },
        .function => {
            var function_values = main_component_index.children(parser.ast);
            if (anyValue(parser.ast, &function_values)) {
                return unrecognizedPseudo(pseudo, parser, main_component_index);
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
        switch (index.tag(ast)) {
            .token_bad_string, .token_bad_url, .token_right_paren, .token_right_square, .token_right_curly => return false,
            else => {},
        }
    }
    return true;
}

fn unrecognizedPseudo(comptime pseudo: Pseudo, parser: *Parser, main_component_index: Ast.Index) ?switch (pseudo) {
    .element, .legacy_element => selectors.PseudoElement,
    .class => selectors.PseudoClass,
} {
    var iterator = parser.source.identTokenIterator(main_component_index.location(parser.ast));
    zss.log.warn("Ignoring unsupported pseudo {s}: {f}", .{
        switch (pseudo) {
            .element, .legacy_element => "element",
            .class => "class",
        },
        &iterator,
    });
    return .unrecognized;
}
