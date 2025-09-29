/// The set of namespace prefixes and their corresponding namespace ids.
namespaces: Namespaces,
/// URLs found while parsing declaration blocks.
decl_urls: Urls,
cascade_source: cascade.Source,

pub const Namespaces = struct {
    indexer: zss.StringInterner = .init(.{ .max_size = NamespaceId.max_unique_values, .case = .sensitive }),
    /// Maps namespace prefixes to namespace ids.
    ids: std.ArrayListUnmanaged(NamespaceId) = .empty,
    /// The default namespace, or `null` if there is no default namespace.
    default: ?NamespaceId = null,

    pub fn deinit(namespaces: *Namespaces, allocator: Allocator) void {
        namespaces.indexer.deinit(allocator);
        namespaces.ids.deinit(allocator);
    }
};

const Stylesheet = @This();

const zss = @import("zss.zig");
const cascade = zss.cascade;
const Ast = zss.syntax.Ast;
const AtRule = zss.syntax.Token.AtRule;
const Declarations = zss.Declarations;
const Environment = zss.Environment;
const Importance = Declarations.Importance;
const NamespaceId = Environment.Namespaces.Id;
const TokenSource = zss.syntax.TokenSource;
const Urls = zss.values.parse.Urls;

const selectors = zss.selectors;
const Specificity = selectors.Specificity;

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

/// Releases all resources associated with the stylesheet.
pub fn deinit(stylesheet: *Stylesheet, allocator: Allocator) void {
    stylesheet.namespaces.deinit(allocator);
    stylesheet.decl_urls.deinit(allocator);
    stylesheet.cascade_source.deinit(allocator);
}

pub fn createFromTokenSource(allocator: Allocator, token_source: TokenSource, env: *Environment) !Stylesheet {
    var parser = zss.syntax.Parser.init(token_source, allocator);
    defer parser.deinit();
    var ast, const rule_list_index = try parser.parseCssStylesheet(allocator);
    defer ast.deinit(allocator);
    return create(allocator, ast, rule_list_index, token_source, env);
}

/// Create a `Stylesheet` from an Ast `rule_list` node.
/// Free using `deinit`.
pub fn create(
    allocator: Allocator,
    ast: Ast,
    rule_list_index: Ast.Index,
    token_source: TokenSource,
    env: *Environment,
) !Stylesheet {
    var stylesheet = Stylesheet{
        .namespaces = .{},
        .decl_urls = .init(env),
        .cascade_source = .{},
    };
    errdefer stylesheet.deinit(allocator);

    var selector_parser = selectors.Parser.init(env, allocator, token_source, ast, &stylesheet.namespaces);
    defer selector_parser.deinit();

    var unsorted_selectors = std.MultiArrayList(struct { index: selectors.Data.ListIndex, specificity: Specificity }){};
    defer unsorted_selectors.deinit(allocator);

    assert(rule_list_index.tag(ast) == .rule_list);
    var rule_sequence = rule_list_index.children(ast);
    while (rule_sequence.nextSkipSpaces(ast)) |index| {
        switch (index.tag(ast)) {
            .at_rule => {
                const at_rule = index.extra(ast).at_rule orelse {
                    zss.log.warn("Ignoring unknown at-rule: @{f}", .{token_source.formatAtKeywordToken(index.location(ast))});
                    continue;
                };
                atRule(&stylesheet.namespaces, allocator, ast, token_source, env, at_rule, index) catch |err| switch (err) {
                    error.InvalidAtRule => {
                        // NOTE: This is no longer a valid style sheet.
                        zss.log.warn("Ignoring invalid @{s} at-rule", .{@tagName(at_rule)});
                        continue;
                    },
                    error.UnrecognizedAtRule => {
                        zss.log.warn("Ignoring unknown at-rule: @{s}", .{@tagName(at_rule)});
                        continue;
                    },
                    else => |e| return e,
                };
            },
            .qualified_rule => {
                // TODO: Handle invalid style rules

                // Parse selectors
                const selector_sequence = ast.qualifiedRulePrelude(index);
                const first_complex_selector: selectors.Data.ListIndex = @intCast(stylesheet.cascade_source.selector_data.items.len);
                selector_parser.parseComplexSelectorList(&stylesheet.cascade_source.selector_data, allocator, selector_sequence) catch |err| switch (err) {
                    error.ParseError => continue,
                    else => |e| return e,
                };

                // Parse the style block
                const last_declaration = selector_sequence.end.extra(ast).index;
                var buffer: [zss.property.recommended_buffer_size]u8 = undefined;
                const decl_block = try zss.property.parseDeclarationsFromAst(env, ast, token_source, &buffer, last_declaration, stylesheet.decl_urls.toManaged(allocator));

                var index_of_complex_selector = first_complex_selector;
                for (selector_parser.specificities.items) |specificity| {
                    const selector_number: selectors.Data.ListIndex = @intCast(unsorted_selectors.len);
                    try unsorted_selectors.append(allocator, .{ .index = index_of_complex_selector, .specificity = specificity });

                    for ([_]Importance{ .important, .normal }) |importance| {
                        const destination_list = switch (importance) {
                            .important => &stylesheet.cascade_source.selectors_important,
                            .normal => &stylesheet.cascade_source.selectors_normal,
                        };
                        if (!env.decls.hasValues(decl_block, importance)) continue;

                        try destination_list.append(allocator, .{
                            // Temporarily store the selector number; after sorting, this is replaced with the selector index.
                            .selector = selector_number,
                            .block = decl_block,
                        });
                    }

                    index_of_complex_selector = stylesheet.cascade_source.selector_data.items[index_of_complex_selector].next_complex_selector;
                }
                assert(index_of_complex_selector == stylesheet.cascade_source.selector_data.items.len);
            },
            else => unreachable,
        }
    }

    stylesheet.decl_urls.commit(env);

    const unsorted_selectors_slice = unsorted_selectors.slice();

    // Sort the selectors such that items with a higher cascade order appear earlier in each list.
    for ([_]Importance{ .important, .normal }) |importance| {
        const list = switch (importance) {
            .important => &stylesheet.cascade_source.selectors_important,
            .normal => &stylesheet.cascade_source.selectors_normal,
        };
        const SortContext = struct {
            selector_number: []const selectors.Data.ListIndex,
            blocks: []const Declarations.Block,
            specificities: []const Specificity,

            pub fn lessThan(ctx: @This(), a_index: usize, b_index: usize) bool {
                const a_spec = ctx.specificities[ctx.selector_number[a_index]];
                const b_spec = ctx.specificities[ctx.selector_number[b_index]];
                switch (a_spec.order(b_spec)) {
                    .lt => return false,
                    .gt => return true,
                    .eq => {},
                }

                const a_block = ctx.blocks[a_index];
                const b_block = ctx.blocks[b_index];
                return !a_block.earlierThan(b_block);
            }
        };
        list.sortUnstable(SortContext{
            .selector_number = list.items(.selector),
            .blocks = list.items(.block),
            .specificities = unsorted_selectors_slice.items(.specificity),
        });

        for (list.items(.selector)) |*selector_index| {
            selector_index.* = unsorted_selectors_slice.items(.index)[selector_index.*];
        }
    }

    return stylesheet;
}

fn atRule(
    namespaces: *Namespaces,
    allocator: Allocator,
    ast: Ast,
    token_source: TokenSource,
    env: *Environment,
    at_rule: AtRule,
    at_rule_index: Ast.Index,
) !void {
    // TODO: There are rules involving how some at-rules must be ordered
    //       Example 1: @namespace rules must come after @charset and @import
    //       Example 2: @import and @namespace must come before any other non-ignored at-rules and style rules

    const parse = zss.values.parse;
    var parse_ctx: parse.Context = .init(ast, token_source);
    switch (at_rule) {
        .import => return error.UnrecognizedAtRule,
        .namespace => {
            // Spec: CSS Namespaces Level 3 Editor's Draft
            // Syntax: <namespace-prefix>? [ <string> | <url> ]
            //         <namespace-prefix> = <ident>

            parse_ctx.initSequence(at_rule_index.children(ast));
            const prefix_or_null = parse.identifier(&parse_ctx);
            const namespace: Environment.NamespaceLocation =
                if (parse.string(&parse_ctx)) |location|
                    .{ .string_token = location }
                else if (parse.url(&parse_ctx)) |url|
                    switch (url) {
                        .string_token => |location| .{ .string_token = location },
                        .url_token => |location| .{ .url_token = location },
                    }
                else
                    return error.InvalidAtRule;
            if (!parse_ctx.empty()) return error.InvalidAtRule;

            const id = try env.addNamespace(namespace, token_source);
            if (prefix_or_null) |prefix| {
                const index = try namespaces.indexer.addFromIdentTokenSensitive(allocator, prefix, token_source);
                if (index == namespaces.ids.items.len) {
                    try namespaces.ids.append(allocator, id);
                } else {
                    // NOTE: Later @namespace rules override previous ones.
                    namespaces.ids.items[index] = id;
                }
            } else {
                // NOTE: Later @namespace rules override previous ones.
                namespaces.default = id;
            }
        },
    }
}

test "create a stylesheet" {
    const allocator = std.testing.allocator;

    const input =
        \\@charset "utf-8";
        \\@import "import.css";
        \\@namespace test "example.com";
        \\@namespace test src("foo.bar");
        \\@namespace src("xyz");
        \\@namespace url(xyz);
        \\@namespace url("xyz");
        \\test {display: block}
    ;
    const token_source = try zss.syntax.TokenSource.init(input);

    var ast, const rule_list_index = blk: {
        var parser = zss.syntax.Parser.init(token_source, allocator);
        defer parser.deinit();
        break :blk try parser.parseCssStylesheet(allocator);
    };
    defer ast.deinit(allocator);

    var env = Environment.init(allocator);
    defer env.deinit();

    var stylesheet = try create(allocator, ast, rule_list_index, token_source, &env);
    defer stylesheet.deinit(allocator);
}
