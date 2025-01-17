const zss = @import("../zss.zig");
const selectors = zss.selectors;

const Environment = zss.Environment;
const NamespaceId = Environment.NamespaceId;

const syntax = zss.syntax;
const Ast = syntax.Ast;
const Component = syntax.Component;
const TokenSource = syntax.TokenSource;

const std = @import("std");
const panic = std.debug.panic;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

pub const Parser = struct {
    env: *Environment,
    arena: Allocator,
    source: TokenSource,
    slice: Ast.Slice,
    sequence: Ast.Sequence,
    unspecified_namespace: NamespaceId,

    specificity: selectors.Specificity = undefined,

    pub const Error = error{ParseError} || syntax.IdentifierSet.Error;

    pub fn init(
        env: *Environment,
        arena: *ArenaAllocator,
        source: TokenSource,
        slice: Ast.Slice,
        sequence: Ast.Sequence,
    ) Parser {
        return Parser{
            .env = env,
            .arena = arena.allocator(),
            .source = source,
            .slice = slice,
            .sequence = sequence,
            .unspecified_namespace = env.default_namespace orelse NamespaceId.any,
        };
    }

    fn fail(_: *Parser) Error {
        return error.ParseError;
    }

    fn nextComponent(parser: *Parser) ?struct { Component.Tag, Ast.Size } {
        const index = parser.sequence.nextKeepSpaces(parser.slice) orelse return null;
        const tag = parser.slice.tag(index);
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
        return parser.sequence.skipSpaces(parser.slice);
    }
};

pub fn parseComplexSelectorList(parser: *Parser) Parser.Error!selectors.ComplexSelectorList {
    var list = ArrayListUnmanaged(selectors.ComplexSelectorFull){};
    defer {
        for (list.items) |*full| full.deinit(parser.arena);
        list.deinit(parser.arena);
    }

    var expecting_comma = false;
    while (true) {
        if (expecting_comma) {
            _ = parser.skipSpaces();
            (try parser.expectComponentAllowEof(.token_comma)) orelse break;
            expecting_comma = false;
        } else {
            try list.ensureUnusedCapacity(parser.arena, 1);
            const complex_selector = try parseComplexSelector(parser);
            list.appendAssumeCapacity(.{ .selector = complex_selector, .specificity = parser.specificity });
            parser.specificity = undefined;
            expecting_comma = true;
        }
    }

    if (list.items.len == 0) {
        return parser.fail();
    }

    const owned = try list.toOwnedSlice(parser.arena);
    return .{ .list = owned };
}

fn parseComplexSelector(parser: *Parser) !selectors.ComplexSelector {
    parser.specificity = .{};

    var compounds = ArrayListUnmanaged(selectors.CompoundSelector){};
    defer {
        for (compounds.items) |*compound| compound.deinit(parser.arena);
        compounds.deinit(parser.arena);
    }
    var combinators = ArrayListUnmanaged(selectors.Combinator){};
    defer combinators.deinit(parser.arena);

    {
        try compounds.ensureUnusedCapacity(parser.arena, 1);
        const compound = (try parseCompoundSelector(parser)) orelse return parser.fail();
        compounds.appendAssumeCapacity(compound);
    }

    while (true) {
        const combinator = (try parseCombinator(parser)) orelse break;

        try compounds.ensureUnusedCapacity(parser.arena, 1);
        _ = parser.skipSpaces();
        const after_combinator = parser.sequence.start;
        const compound = (try parseCompoundSelector(parser)) orelse {
            if (combinator == .descendant) {
                parser.sequence.reset(after_combinator);
                break;
            } else {
                return parser.fail();
            }
        };

        compounds.appendAssumeCapacity(compound);
        try combinators.append(parser.arena, combinator);
    }

    const combinators_owned = try combinators.toOwnedSlice(parser.arena);
    errdefer parser.arena.free(combinators_owned);
    const compounds_owned = try compounds.toOwnedSlice(parser.arena);
    return .{ .compounds = compounds_owned, .combinators = combinators_owned };
}

/// Syntax: <combinator> = '>' | '+' | '~' | [ '|' '|' ]
fn parseCombinator(parser: *Parser) !?selectors.Combinator {
    const has_space = parser.skipSpaces();
    if (parser.acceptComponent(.token_delim)) |index| {
        switch (parser.slice.extra(index).codepoint()) {
            '>' => return .child,
            '+' => return .next_sibling,
            '~' => return .subsequent_sibling,
            '|' => {
                const second_pipe = try parser.expectComponent(.token_delim);
                if (parser.slice.extra(second_pipe).codepoint() != '|') return parser.fail();
                return .column;
            },
            else => {},
        }
        parser.sequence.reset(index);
    }
    return if (has_space) .descendant else null;
}

fn parseCompoundSelector(parser: *Parser) !?selectors.CompoundSelector {
    var type_selector: ?selectors.TypeSelector = undefined;
    if (try parseTypeSelector(parser)) |result| {
        type_selector = result;
        if (result.name != .any) {
            parser.specificity.add(.type_ident);
        }
    } else {
        type_selector = null;
    }

    var subclasses = ArrayListUnmanaged(selectors.SubclassSelector){};
    defer subclasses.deinit(parser.arena);
    while (true) {
        const subclass_selector = (try parseSubclassSelector(parser)) orelse break;
        try subclasses.append(parser.arena, subclass_selector);
    }

    var pseudo_elements = ArrayListUnmanaged(selectors.PseudoElement){};
    defer {
        for (pseudo_elements.items) |element| parser.arena.free(element.classes);
        pseudo_elements.deinit(parser.arena);
    }
    while (true) {
        _ = parser.acceptComponent(.token_colon) orelse break;
        _ = try parser.expectComponent(.token_colon);

        const element = try parsePseudoSelector(parser);
        try pseudo_elements.ensureUnusedCapacity(parser.arena, 1);
        parser.specificity.add(.pseudo_element);

        var pseudo_classes = ArrayListUnmanaged(selectors.PseudoName){};
        defer pseudo_classes.deinit(parser.arena);
        while (true) {
            _ = parser.acceptComponent(.token_colon) orelse break;
            const class = try parsePseudoSelector(parser);
            try pseudo_classes.append(parser.arena, class);
            parser.specificity.add(.pseudo_class);
        }

        const pseudo_classes_owned = try pseudo_classes.toOwnedSlice(parser.arena);
        pseudo_elements.appendAssumeCapacity(.{ .name = element, .classes = pseudo_classes_owned });
    }

    if (type_selector == null and subclasses.items.len == 0 and pseudo_elements.items.len == 0) return null;

    const subclasses_owned = try subclasses.toOwnedSlice(parser.arena);
    errdefer parser.arena.free(subclasses_owned);
    const pseudo_elements_owned = try pseudo_elements.toOwnedSlice(parser.arena);
    return .{
        .type_selector = type_selector,
        .subclasses = subclasses_owned,
        .pseudo_elements = pseudo_elements_owned,
    };
}

fn parseTypeSelector(parser: *Parser) !?selectors.TypeSelector {
    const element_type = (try parseElementType(parser)) orelse return null;
    return .{
        .namespace = switch (element_type.namespace) {
            .identifier => panic("TODO: Namespaces in type selectors", .{}),
            .none => .none,
            .any => .any,
            .default => parser.unspecified_namespace,
        },
        .name = switch (element_type.name) {
            .identifier => |identifier| try parser.env.addTypeOrAttributeName(identifier, parser.source),
            .any => .any,
        },
    };
}

const ElementType = struct {
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
fn parseElementType(parser: *Parser) !?ElementType {
    // I consider the following grammar easier to comprehend.
    // Just like the real grammar, no spaces are allowed anywhere.
    //
    // Syntax: <type-selector> = <ns-prefix>? [ <ident-token> | '*' ]
    //         <ns-prefix>     = [ <ident-token> | '*' ]? '|'

    var result: ElementType = undefined;

    const tag, const index = parser.nextComponent() orelse return null;
    result.name = switch (tag) {
        .token_ident => .{ .identifier = parser.slice.location(index) },
        .token_delim => switch (parser.slice.extra(index).codepoint()) {
            '*' => .any,
            '|' => {
                const name = parseElementName(parser) orelse return parser.fail();
                return .{
                    .namespace = .none,
                    .name = name,
                };
            },
            else => return null,
        },
        else => return null,
    };

    if (parser.acceptComponent(.token_delim)) |pipe_index| {
        if (parser.slice.extra(pipe_index).codepoint() == '|') {
            const name = parseElementName(parser) orelse return parser.fail();
            result.namespace = switch (result.name) {
                .identifier => |location| .{ .identifier = location },
                .any => .any,
            };
            result.name = name;
            return result;
        }
        parser.sequence.reset(pipe_index);
    }

    result.namespace = .default;
    return result;
}

fn parseElementName(parser: *Parser) ?ElementType.Name {
    const tag, const index = parser.nextComponent() orelse return null;
    return switch (tag) {
        .token_ident => .{ .identifier = parser.slice.location(index) },
        .token_delim => if (parser.slice.extra(index).codepoint() == '*') .any else null,
        else => null,
    };
}

fn parseSubclassSelector(parser: *Parser) !?selectors.SubclassSelector {
    const first_component_tag, const first_component_index = parser.nextComponent() orelse return null;
    switch (first_component_tag) {
        .token_hash_id => {
            const location = parser.slice.location(first_component_index);
            const name = try parser.env.addIdName(location, parser.source);
            parser.specificity.add(.id);
            return .{ .id = name };
        },
        .token_delim => {
            if (parser.slice.extra(first_component_index).codepoint() == '.') {
                const class_name = try parser.expectComponent(.token_ident);
                const location = parser.slice.location(class_name);
                const name = try parser.env.addClassName(location, parser.source);
                parser.specificity.add(.class);
                return .{ .class = name };
            }
        },
        .simple_block_square => {
            const saved_sequence = parser.sequence;
            defer parser.sequence = saved_sequence;
            parser.sequence = parser.slice.children(first_component_index);
            const attribute_selector = try parseAttributeSelector(parser);
            _ = parser.skipSpaces();
            if (!parser.sequence.empty()) return parser.fail();
            parser.specificity.add(.attribute);
            return .{ .attribute = attribute_selector };
        },
        .token_colon => {
            const pseudo_class = try parsePseudoSelector(parser);
            parser.specificity.add(.pseudo_class);
            return .{ .pseudo = pseudo_class };
        },
        else => {},
    }

    parser.sequence.reset(first_component_index);
    return null;
}

fn parseAttributeSelector(parser: *Parser) !selectors.AttributeSelector {
    var result: selectors.AttributeSelector = undefined;

    // Parse the attribute namespace and name
    _ = parser.skipSpaces();
    const element_type = (try parseElementType(parser)) orelse return parser.fail();
    result.namespace = switch (element_type.namespace) {
        .identifier => panic("TODO: Namespaces in attribute selectors", .{}),
        .none => .none,
        .any => .any,
        .default => .none,
    };
    result.name = switch (element_type.name) {
        .identifier => |identifier| try parser.env.addTypeOrAttributeName(identifier, parser.source),
        .any => return parser.fail(),
    };

    // Parse the attribute matcher
    _ = parser.skipSpaces();
    const attr_matcher_index = parser.acceptComponent(.token_delim) orelse {
        result.complex = null;
        return result;
    };
    const attr_matcher_codepoint = parser.slice.extra(attr_matcher_index).codepoint();
    const operator: selectors.AttributeSelector.Operator = switch (attr_matcher_codepoint) {
        '=' => .equals,
        '~' => .list_contains,
        '|' => .equals_or_prefix_dash,
        '^' => .starts_with,
        '$' => .ends_with,
        '*' => .contains,
        else => return parser.fail(),
    };
    if (operator != .equals) {
        if (parser.skipSpaces()) return parser.fail();
        const equal_sign_index = try parser.expectComponent(.token_delim);
        const codepoint = parser.slice.extra(equal_sign_index).codepoint();
        if (codepoint != '=') return parser.fail();
    }

    // Parse the attribute value
    _ = parser.skipSpaces();
    const value_tag, const value_index = parser.nextComponent() orelse return parser.fail();
    switch (value_tag) {
        .token_ident, .token_string => {},
        else => return parser.fail(),
    }
    result.complex = .{ .operator = operator, .value = value_index, .case = undefined };

    // Parse the case modifier
    _ = parser.skipSpaces();
    const modifier_index = parser.acceptComponent(.token_ident) orelse {
        result.complex.?.case = .default;
        return result;
    };
    const modifier_location = parser.slice.location(modifier_index);
    result.complex.?.case = parser.source.mapIdentifier(modifier_location, selectors.AttributeSelector.Case, &.{
        .{ "i", .ignore_case },
        .{ "s", .same_case },
    }) orelse return parser.fail();

    return result;
}

// Assumes that the previous Ast node was a `token_colon`.
fn parsePseudoSelector(parser: *Parser) !selectors.PseudoName {
    const main_component_tag, const main_component_index = parser.nextComponent() orelse return parser.fail();
    switch (main_component_tag) {
        .token_ident => {
            // TODO: Get the actual pseudo class name.
            return .unrecognized;
        },
        .function => {
            var function_values = parser.slice.children(main_component_index);
            if (anyValue(parser.slice, &function_values)) {
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
