/// The set of namespace prefixes and their corresponding namespace ids.
namespaces: Namespaces,
/// URLs found while parsing declaration blocks.
decl_urls: Urls,

pub const Namespaces = struct {
    indexer: IdentifierSet = .{ .case = .sensitive, .max_size = std.math.maxInt(std.meta.Tag(NamespaceId)) },
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
const Declarations = zss.property.Declarations;
const Environment = zss.Environment;
const IdentifierSet = zss.syntax.IdentifierSet;
const Importance = zss.property.Importance;
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
}

/// Create a `Stylesheet` from an Ast `rule_list` node.
/// Free using `deinit`.
pub fn create(
    allocator: Allocator,
    ast: Ast,
    rule_list: Ast.Size,
    token_source: TokenSource,
    env: *Environment,
    cascade_source: *cascade.Source,
) !Stylesheet {
    var namespaces = Namespaces{};
    errdefer namespaces.deinit(allocator);

    var decl_urls = Urls.init(env);
    errdefer decl_urls.deinit(allocator);

    var selector_parser = selectors.Parser.init(env, allocator, token_source, ast, &namespaces);
    defer selector_parser.deinit();

    var unsorted_selectors = std.MultiArrayList(struct { index: selectors.Size, specificity: Specificity }){};
    defer unsorted_selectors.deinit(allocator);

    assert(ast.tag(rule_list) == .rule_list);
    var rule_sequence = ast.children(rule_list);
    while (rule_sequence.nextSkipSpaces(ast)) |index| {
        switch (ast.tag(index)) {
            .at_rule => {
                const at_rule = ast.extra(index).at_rule orelse {
                    const bytes = ast.atKeywordIdentifierBytes(token_source, index);
                    zss.log.warn("Ignoring unknown at-rule: @{s}", .{bytes});
                    continue;
                };
                atRule(&namespaces, allocator, ast, token_source, env, at_rule, index) catch |err| switch (err) {
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

                const end_of_prelude = ast.extra(index).index;
                const selector_sequence: Ast.Sequence = .{ .start = index + 1, .end = end_of_prelude };
                const selector_code_list = selectors.CodeList{ .list = &cascade_source.selector_data, .allocator = env.allocator };
                const first_complex_selector = selector_code_list.len();
                selector_parser.parseComplexSelectorList(selector_code_list, selector_sequence) catch |err| switch (err) {
                    error.ParseError => continue,
                    else => |e| return e,
                };

                const last_declaration = ast.extra(end_of_prelude).index;
                var buffer: [zss.property.recommended_buffer_size]u8 = undefined;
                const decl_block = try zss.property.parseDeclarationsFromAst(env, ast, token_source, &buffer, last_declaration, decl_urls.toManaged(allocator));

                var index_of_complex_selector = first_complex_selector;
                for (selector_parser.specificities.items) |specificity| {
                    const selector_number: selectors.Size = @intCast(unsorted_selectors.len);
                    try unsorted_selectors.append(allocator, .{ .index = index_of_complex_selector, .specificity = specificity });

                    for ([_]Importance{ .important, .normal }) |importance| {
                        const destination_list = switch (importance) {
                            .important => &cascade_source.selectors_important,
                            .normal => &cascade_source.selectors_normal,
                        };
                        if (!env.decls.hasValues(decl_block, importance)) continue;

                        try destination_list.append(env.allocator, .{
                            // Temporarily store the selector number; after sorting, this is replaced with the selector index.
                            .selector = selector_number,
                            .block = decl_block,
                        });
                    }

                    index_of_complex_selector = selector_code_list.list.items[index_of_complex_selector].next_complex_selector;
                }
                assert(index_of_complex_selector == selector_code_list.len());
            },
            else => unreachable,
        }
    }

    decl_urls.commit(env);

    const unsorted_selectors_slice = unsorted_selectors.slice();

    // Sort the selectors such that items with a higher cascade order appear earlier in each list.
    for ([_]Importance{ .important, .normal }) |importance| {
        const list = switch (importance) {
            .important => &cascade_source.selectors_important,
            .normal => &cascade_source.selectors_normal,
        };
        const SortContext = struct {
            selector_number: []const selectors.Size,
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

    return .{
        .namespaces = namespaces,
        .decl_urls = decl_urls,
    };
}

fn atRule(
    namespaces: *Namespaces,
    allocator: Allocator,
    ast: Ast,
    token_source: TokenSource,
    env: *Environment,
    at_rule: AtRule,
    at_rule_index: Ast.Size,
) !void {

    // TODO: There are rules involving how some at-rules must be ordered
    //       Example 1: @namespace rules must come after @charset and @import
    //       Example 2: @import and @namespace must come before any other non-ignored at-rules and style rules
    switch (at_rule) {
        .import => return error.UnrecognizedAtRule,
        .namespace => {
            var sequence = ast.children(at_rule_index);
            const prefix_opt: ?Ast.Size = prefix: {
                const index = sequence.nextSkipSpaces(ast) orelse break :prefix null;
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

            const id = try env.addNamespace(ast, token_source, namespace);
            if (prefix_opt) |prefix| {
                const it = token_source.identTokenIterator(ast.location(prefix));
                const index = try namespaces.indexer.getOrPutFromSource(allocator, token_source, it);
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
        \\@namespace test "foo.bar";
        \\test {display: block}
    ;
    const token_source = try zss.syntax.TokenSource.init(input);

    var ast = blk: {
        var parser = zss.syntax.Parser.init(token_source, allocator);
        defer parser.deinit();
        break :blk try parser.parseCssStylesheet(allocator);
    };
    defer ast.deinit(allocator);

    var env = Environment.init(allocator);
    defer env.deinit();

    const cascade_source = try env.cascade_tree.createSource(env.allocator);

    var stylesheet = try create(allocator, ast, 0, token_source, &env, cascade_source);
    defer stylesheet.deinit(allocator);
}
