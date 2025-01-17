const Stylesheet = @This();

const zss = @import("zss.zig");
const ComplexSelectorList = zss.selectors.ComplexSelectorList;
const Ast = zss.syntax.Ast;
const Environment = zss.Environment;
const ParsedDeclarations = zss.properties.declaration.ParsedDeclarations;
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

rules: MultiArrayList(StyleRule) = .{},
arena: ArenaAllocator.State = .{},

pub fn deinit(stylesheet: *Stylesheet, allocator: Allocator) void {
    var arena = stylesheet.arena.promote(allocator);
    defer stylesheet.arena = arena.state;
    arena.deinit();
}

pub fn create(ast: Ast.Slice, source: Source, child_allocator: Allocator, env: *Environment) !Stylesheet {
    var arena = ArenaAllocator.init(child_allocator);
    errdefer arena.deinit();
    const allocator = arena.allocator();

    var rules = MultiArrayList(StyleRule){};

    assert(ast.tag(0) == .rule_list);
    var next_index: Ast.Size = 1;
    const end_of_stylesheet = ast.nextSibling(0);
    while (next_index < end_of_stylesheet) {
        const index = next_index;
        next_index = ast.nextSibling(next_index);
        switch (ast.tag(index)) {
            .at_rule => panic("TODO: At-rules in a stylesheet\n", .{}),
            .qualified_rule => {
                const end_of_prelude = ast.extra(index).index();

                try rules.ensureUnusedCapacity(allocator, 1);
                const selector_sequence: Ast.Sequence = .{ .start = index + 1, .end = end_of_prelude };
                const selector_list = (try zss.selectors.parseSelectorList(env, &arena, source, ast, selector_sequence)) orelse continue;
                const last_declaration = ast.extra(end_of_prelude).index();
                var value_source = zss.values.parse.Source.init(ast, source, arena.allocator());
                const decls = try zss.properties.declaration.parseDeclarationsFromAst(&value_source, &arena, last_declaration);
                rules.appendAssumeCapacity(.{ .selector = selector_list, .declarations = decls });
            },
            else => unreachable,
        }
    }

    return Stylesheet{ .rules = rules, .arena = arena.state };
}
