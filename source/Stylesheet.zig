const Stylesheet = @This();

const zss = @import("zss.zig");
const ComplexSelectorList = zss.selectors.ComplexSelectorList;
const Ast = zss.syntax.Ast;
const AtRule = zss.syntax.Token.AtRule;
const Environment = zss.Environment;
const NamespaceId = Environment.Namespaces.Id;
const ParsedDeclarations = zss.properties.parse.ParsedDeclarations;
const Source = zss.syntax.TokenSource;

const std = @import("std");
const assert = std.debug.assert;
const panic = std.debug.panic;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const MultiArrayList = std.MultiArrayList;

pub const StyleRule = struct {
    selector: ComplexSelectorList,
    declarations: ParsedDeclarations,
};

pub const Namespaces = struct {
    // TODO: consider making an `IdentifierMap` structure for this use case
    prefixes: std.StringArrayHashMapUnmanaged(NamespaceId) = .empty,
    default: ?NamespaceId = null,
};

rules: MultiArrayList(StyleRule) = .empty,
arena: ArenaAllocator.State,
namespaces: Namespaces = .{},

pub fn deinit(stylesheet: *Stylesheet, allocator: Allocator) void {
    var arena = stylesheet.arena.promote(allocator);
    defer stylesheet.arena = arena.state;
    arena.deinit();
}

pub fn create(ast: Ast, source: Source, child_allocator: Allocator, env: *Environment) !Stylesheet {
    var arena = ArenaAllocator.init(child_allocator);
    errdefer arena.deinit();
    const allocator = arena.allocator();

    var stylesheet = Stylesheet{ .arena = undefined };

    assert(ast.tag(0) == .rule_list);
    var rule_sequence = ast.children(0);
    while (rule_sequence.nextSkipSpaces(ast)) |index| {
        switch (ast.tag(index)) {
            .at_rule => {
                const at_rule = ast.extra(index).at_rule orelse {
                    const iterator = source.atKeywordTokenIterator(ast.location(index));
                    // TODO: Access of `iterator.location` is an implementation detail leak
                    const copy = try source.copyIdentifier(iterator.location, allocator);
                    defer allocator.free(copy);
                    zss.log.warn("Ignoring unknown at-rule: @{s}", .{copy});
                    continue;
                };
                atRule(&stylesheet, allocator, env, ast, source, at_rule, index) catch |err| switch (err) {
                    error.InvalidAtRule => {
                        zss.log.warn("Ignoring invalid @{s} at-rule", .{@tagName(at_rule)});
                    },
                    else => |e| return e,
                };
            },
            .qualified_rule => {
                try stylesheet.rules.ensureUnusedCapacity(allocator, 1);

                const end_of_prelude = ast.extra(index).index;
                const selector_sequence: Ast.Sequence = .{ .start = index + 1, .end = end_of_prelude };
                const selector_list = try zss.selectors.parseSelectorList(env, allocator, source, ast, selector_sequence, &stylesheet.namespaces);
                const last_declaration = ast.extra(end_of_prelude).index;
                var value_source = zss.values.parse.Source.init(ast, source, arena.allocator());
                const decls = try zss.properties.parse.parseDeclarationsFromAst(&value_source, &arena, last_declaration);
                stylesheet.rules.appendAssumeCapacity(.{ .selector = selector_list, .declarations = decls });
            },
            else => unreachable,
        }
    }

    stylesheet.arena = arena.state;
    return stylesheet;
}

fn atRule(
    stylesheet: *Stylesheet,
    allocator: Allocator,
    env: *Environment,
    ast: Ast,
    source: Source,
    at_rule: AtRule,
    at_rule_index: Ast.Size,
) !void {
    switch (at_rule) {
        .import => panic("TODO: @import rules", .{}),
        .namespace => {
            var sequence = ast.children(at_rule_index);
            const prefix_opt: ?Ast.Size = prefix: {
                const index = sequence.nextSkipSpaces(ast) orelse return error.InvalidAtRule;
                if (ast.tag(index) != .token_ident) {
                    sequence.reset(index);
                    break :prefix null;
                }
                break :prefix index;
            };
            // TODO: The namespace must match the grammar of <url>.
            const namespace: Ast.Size = namespace: {
                const index = sequence.nextSkipSpaces(ast) orelse return error.InvalidAtRule;
                switch (ast.tag(index)) {
                    .token_string, .token_url, .token_bad_url => break :namespace index,
                    else => return error.InvalidAtRule,
                }
            };
            if (sequence.nextSkipSpaces(ast)) |_| return error.InvalidAtRule;

            const id = try env.addNamespace(ast, source, namespace);
            if (prefix_opt) |prefix| {
                try stylesheet.namespaces.prefixes.ensureUnusedCapacity(allocator, 1);
                const prefix_str = try source.copyIdentifier(ast.location(prefix), allocator);
                const gop_result = stylesheet.namespaces.prefixes.getOrPutAssumeCapacity(prefix_str);
                if (gop_result.found_existing) {
                    allocator.free(prefix_str);
                }
                gop_result.value_ptr.* = id;
            } else {
                stylesheet.namespaces.default = id;
            }
        },
    }
}
