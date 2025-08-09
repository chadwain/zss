//! A CSS stylesheet, in text form, contains a sequence of style rules.
//! Each style rule consists of:
//!     a sequence of "complex selectors", and
//!     a declaration block containing both important and normal declarations
//!
//! When a declaration block is parsed, we split it into two blocks of important and normal declarations,
//! and handle each of them separately. They end up in `decl_blocks`.
//!
//! Every complex selector in the stylesheet is added to either `selectors_important` or `selectors_normal` (or both),
//! and given a reference to its associated declaration block. These lists are sorted such that selectors with a
//! higher cascade order appear earlier.
//!
//! To iterate over all declaration blocks in cascade order: iterate over all selectors in `selectors_important`,
//! followed by all selectors in `selectors_normal`, taking care not to include a declaration block more than once.

/// Selectors that apply to blocks of important declarations.
/// This list is sorted such that selectors with a higher cascade order appear earlier.
selectors_important: std.MultiArrayList(Selector),
/// Selectors that apply to blocks of normal declarations.
/// This list is sorted such that selectors with a higher cascade order appear earlier.
selectors_normal: std.MultiArrayList(Selector),
selector_data: []const selectors.Data,
namespaces: Namespaces,
/// Private fields.
private: Private,

pub const Selector = struct {
    /// The complex selector itself.
    complex: selectors.Size,
    /// The specificity of the selector.
    specificity: Specificity,
    /// The index of the declaration block this selector is associated with.
    decl_block: Declarations.Block,
};

pub const Namespaces = struct {
    // TODO: consider making an `IdentifierMap` structure for this use case

    /// Maps UTF-8 strings to namespaces.
    /// Note that namespace prefixes are case-sensitive.
    prefixes: std.StringArrayHashMapUnmanaged(NamespaceId) = .empty,
    /// The default namespace, or `null` if there is no default namespace.
    default: ?NamespaceId = null,
};

const Private = struct {
    arena: ArenaAllocator.State,
};

const Stylesheet = @This();

const zss = @import("zss.zig");
const Ast = zss.syntax.Ast;
const AtRule = zss.syntax.Token.AtRule;
const Declarations = zss.property.Declarations;
const Environment = zss.Environment;
const Importance = zss.property.Importance;
const NamespaceId = Environment.Namespaces.Id;
const TokenSource = zss.syntax.TokenSource;

const selectors = zss.selectors;
const Specificity = selectors.Specificity;

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

/// Releases all resources associated with the stylesheet.
pub fn deinit(stylesheet: *Stylesheet, allocator: Allocator) void {
    var arena = stylesheet.private.arena.promote(allocator);
    defer stylesheet.private.arena = arena.state;
    arena.deinit();
}

/// Create a `Stylesheet` from an Ast `rule_list` node.
/// Free using `deinit`.
pub fn create(
    ast: Ast,
    rule_list: Ast.Size,
    token_source: TokenSource,
    env: *Environment,
    child_allocator: Allocator,
) !Stylesheet {
    // TODO: Pick a different allocator
    var arena = ArenaAllocator.init(child_allocator);
    errdefer arena.deinit();
    const allocator = arena.allocator();

    var stylesheet = Stylesheet{
        .selectors_important = .empty,
        .selectors_normal = .empty,
        .selector_data = undefined,
        .namespaces = .{},
        .private = .{ .arena = undefined },
    };

    var selector_data = selectors.DataList.init(allocator);
    defer selector_data.deinit();

    var selector_parser = selectors.Parser.init(env, allocator, token_source, ast, &stylesheet.namespaces);
    defer selector_parser.deinit();

    std.debug.assert(ast.tag(rule_list) == .rule_list);
    var rule_sequence = ast.children(rule_list);
    while (rule_sequence.nextSkipSpaces(ast)) |index| {
        switch (ast.tag(index)) {
            .at_rule => {
                const at_rule = ast.extra(index).at_rule orelse {
                    const copy = try token_source.copyAtKeyword(ast.location(index), allocator);
                    defer allocator.free(copy);
                    zss.log.warn("Ignoring unknown at-rule: @{s}", .{copy});
                    continue;
                };
                atRule(&stylesheet, &arena, ast, token_source, env, at_rule, index) catch |err| switch (err) {
                    error.InvalidAtRule => {
                        zss.log.warn("Ignoring invalid @{s} at-rule", .{@tagName(at_rule)});
                    },
                    else => |e| return e,
                };
            },
            .qualified_rule => {
                // TODO: No handling of invalid style rules

                const end_of_prelude = ast.extra(index).index;
                const selector_sequence: Ast.Sequence = .{ .start = index + 1, .end = end_of_prelude };
                const first_complex_selector = selector_data.len();
                selector_parser.parseComplexSelectorList(&selector_data, selector_sequence) catch |err| switch (err) {
                    error.ParseError => continue,
                    else => |e| return e,
                };

                const last_declaration = ast.extra(end_of_prelude).index;
                var buffer: [zss.property.recommended_buffer_size]u8 = undefined;
                const decl_block = try zss.property.parseDeclarationsFromAst(env, ast, token_source, &buffer, last_declaration);

                for ([_]Importance{ .important, .normal }) |importance| {
                    const destination_list = switch (importance) {
                        .important => &stylesheet.selectors_important,
                        .normal => &stylesheet.selectors_normal,
                    };
                    if (!env.decls.hasValues(decl_block, importance)) continue;

                    var index_of_complex_selector = first_complex_selector;
                    for (selector_parser.specificities.items) |specificity| {
                        try destination_list.append(allocator, .{
                            .specificity = specificity,
                            .complex = index_of_complex_selector,
                            .decl_block = decl_block,
                        });
                        index_of_complex_selector = selector_data.list.items[index_of_complex_selector].next_complex_start;
                    }
                }
            },
            else => unreachable,
        }
    }

    stylesheet.selector_data = try selector_data.toOwnedSlice();

    // Sort the selectors such that items with a higher cascade order appear earlier in each list.
    for ([_]Importance{ .important, .normal }) |importance| {
        const selectors_list = switch (importance) {
            .important => &stylesheet.selectors_important,
            .normal => &stylesheet.selectors_normal,
        };
        const SortContext = struct {
            specificities: []const Specificity,
            decl_blocks: []const Declarations.Block,

            pub fn lessThan(ctx: @This(), a_index: usize, b_index: usize) bool {
                const a_spec = ctx.specificities[a_index];
                const b_spec = ctx.specificities[b_index];
                switch (a_spec.order(b_spec)) {
                    .lt => return false,
                    .gt => return true,
                    .eq => {},
                }

                const a_decl_block = ctx.decl_blocks[a_index];
                const b_decl_block = ctx.decl_blocks[b_index];
                return !a_decl_block.earlierThan(b_decl_block);
            }
        };
        selectors_list.sortUnstable(SortContext{
            .specificities = selectors_list.items(.specificity),
            .decl_blocks = selectors_list.items(.decl_block),
        });
    }

    stylesheet.private.arena = arena.state;
    return stylesheet;
}

fn atRule(
    stylesheet: *Stylesheet,
    arena: *ArenaAllocator,
    ast: Ast,
    token_source: TokenSource,
    env: *Environment,
    at_rule: AtRule,
    at_rule_index: Ast.Size,
) !void {
    const allocator = arena.allocator();

    // TODO: There are rules involving how some at-rules must be ordered
    //       Example 1: @namespace rules must come after @charset and @import
    //       Example 2: @import and @namespace must come before any other non-ignored at-rules and style rules
    switch (at_rule) {
        .import => std.debug.panic("TODO: @import rules", .{}),
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
                try stylesheet.namespaces.prefixes.ensureUnusedCapacity(allocator, 1);
                const prefix_str = try token_source.copyIdentifier(ast.location(prefix), allocator);
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
