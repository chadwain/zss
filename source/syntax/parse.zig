const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

const zss = @import("../../zss.zig");
const toLowercase = zss.util.unicode.toLowercase;
const syntax = @import("./syntax.zig");
const Component = syntax.Component;
const Extra = Component.Extra;
const ComponentTree = syntax.ComponentTree;
const tokenize = @import("./tokenize.zig");

/// A source of `Component.Tag`.
pub const Source = struct {
    inner: tokenize.Source,

    pub const Location = tokenize.Source.Location;

    pub fn init(inner: tokenize.Source) Source {
        return Source{ .inner = inner };
    }

    /// Returns the next component tag, ignoring comments.
    pub fn next(source: Source, location: *Location) Component.Tag {
        var next_location = location.*;
        while (true) {
            const result = tokenize.nextToken(source.inner, next_location);
            if (result.tag != .token_comments) {
                location.* = result.next_location;
                return result.tag;
            }
            next_location = result.next_location;
        }
    }

    fn getDelimeter(source: Source, location: Location) u21 {
        return source.inner.delimTokenCodepoint(location);
    }

    pub fn identTokenIterator(source: Source, start: Location) IdentTokenIterator {
        return .{ .inner = source.inner.identSequenceIterator(start) };
    }

    pub fn matchKeyword(source: Source, location: Location, keyword: []const u21) bool {
        var it = source.inner.identSequenceIterator(location);
        for (keyword) |kw_codepoint| {
            const it_codepoint = it.next(source.inner) orelse return false;
            if (toLowercase(kw_codepoint) != toLowercase(it_codepoint)) return false;
        }
        return it.next(source.inner) == null;
    }

    pub fn identTokensEqlIgnoreCase(source: Source, ident1: Location, ident2: Location) bool {
        if (ident1.value == ident2.value) return true;
        var it1 = source.inner.identSequenceIterator(ident1);
        var it2 = source.inner.identSequenceIterator(ident2);
        while (it1.next(source.inner)) |codepoint1| {
            const codepoint2 = it2.next(source.inner) orelse return false;
            if (toLowercase(codepoint1) != toLowercase(codepoint2)) return false;
        } else {
            return (it2.next(source.inner) == null);
        }
    }
};

pub const IdentTokenIterator = struct {
    inner: tokenize.IdentSequenceIterator,

    pub fn next(it: *IdentTokenIterator, source: Source) ?u21 {
        return it.inner.next(source.inner);
    }
};

pub fn parseStylesheet(source: Source, allocator: Allocator) !ComponentTree {
    var stack = try Stack.init(allocator);
    defer stack.deinit(allocator);

    var tree = ComponentTree{ .components = .{} };
    errdefer tree.deinit(allocator);

    var location = Source.Location{};

    try stack.pushListOfRules(&tree, location, true, allocator);
    try loop(&stack, &tree, source, &location, allocator);
    return tree;
}

pub fn parseListOfComponentValues(source: Source, allocator: Allocator) !ComponentTree {
    var stack = try Stack.init(allocator);
    defer stack.deinit(allocator);

    var tree = ComponentTree{ .components = .{} };
    errdefer tree.deinit(allocator);

    var location = Source.Location{};

    try stack.pushListOfComponentValues(&tree, location, allocator);
    try loop(&stack, &tree, source, &location, allocator);
    return tree;
}

const Stack = struct {
    list: ArrayListUnmanaged(Frame),

    const Frame = struct {
        skip: ComponentTree.Size,
        index: ComponentTree.Size,
        data: Data,

        const Data = union(enum) {
            root,
            list_of_rules: ListOfRules,
            list_of_component_values,
            qualified_rule,
            at_rule,
            simple_block: SimpleBlock,
            function,
        };
    };

    const ListOfRules = struct {
        top_level: bool,
    };

    const SimpleBlock = struct {
        tag: Component.Tag,
        // true if the simple block is the associated {}-block of a qualified rule or an at rule.
        in_a_rule: bool,

        fn endingTokenTag(simple_block: SimpleBlock) Component.Tag {
            return switch (simple_block.tag) {
                .simple_block_curly => .token_right_curly,
                .simple_block_bracket => .token_right_bracket,
                .simple_block_paren => .token_right_paren,
                else => unreachable,
            };
        }
    };

    fn init(allocator: Allocator) !Stack {
        var stack = Stack{ .list = .{} };
        try stack.list.append(allocator, .{ .skip = 0, .index = undefined, .data = .root });
        return stack;
    }

    fn deinit(stack: *Stack, allocator: Allocator) void {
        stack.list.deinit(allocator);
    }

    fn last(stack: *Stack) *Frame {
        return &stack.list.items[stack.list.items.len - 1];
    }

    fn newComponent(tree: *ComponentTree, allocator: Allocator, component: Component) !ComponentTree.Size {
        if (tree.components.len == std.math.maxInt(ComponentTree.Size)) return error.Overflow;
        const index = @intCast(ComponentTree.Size, tree.components.len);
        try tree.components.append(allocator, component);
        return index;
    }

    /// Creates a Component that has no children.
    fn addComponent(
        stack: *Stack,
        tree: *ComponentTree,
        tag: Component.Tag,
        location: Source.Location,
        extra: Component.Extra,
        allocator: Allocator,
    ) !void {
        const index = @intCast(ComponentTree.Size, tree.components.len);
        _ = try newComponent(tree, allocator, .{
            .next_sibling = index + 1,
            .tag = tag,
            .location = location,
            .extra = extra,
        });
        stack.last().skip += 1;
    }

    fn pushListOfRules(stack: *Stack, tree: *ComponentTree, location: Source.Location, top_level: bool, allocator: Allocator) !void {
        const index = try newComponent(tree, allocator, .{
            .next_sibling = undefined,
            .tag = .rule_list,
            .location = location,
            .extra = Extra.make(0),
        });
        try stack.list.append(allocator, .{ .skip = 1, .index = index, .data = .{ .list_of_rules = .{ .top_level = top_level } } });
    }

    fn pushListOfComponentValues(stack: *Stack, tree: *ComponentTree, location: Source.Location, allocator: Allocator) !void {
        const index = try newComponent(tree, allocator, .{
            .next_sibling = undefined,
            .tag = .component_list,
            .location = location,
            .extra = Extra.make(0),
        });
        try stack.list.append(allocator, .{ .skip = 1, .index = index, .data = .list_of_component_values });
    }

    fn pushAtRule(stack: *Stack, tree: *ComponentTree, location: Source.Location, allocator: Allocator) !void {
        const index = try newComponent(tree, allocator, .{
            .next_sibling = undefined,
            .tag = .at_rule,
            .location = location,
            .extra = Extra.make(0),
        });
        try stack.list.append(allocator, .{ .skip = 1, .index = index, .data = .at_rule });
    }

    fn pushQualifiedRule(stack: *Stack, tree: *ComponentTree, location: Source.Location, allocator: Allocator) !void {
        const index = try newComponent(tree, allocator, .{
            .next_sibling = undefined,
            .tag = .qualified_rule,
            .location = location,
            .extra = Extra.make(0),
        });
        try stack.list.append(allocator, .{ .skip = 1, .index = index, .data = .qualified_rule });
    }

    fn pushFunction(stack: *Stack, tree: *ComponentTree, location: Source.Location, allocator: Allocator) !void {
        const index = try newComponent(tree, allocator, .{
            .next_sibling = undefined,
            .tag = .function,
            .location = location,
            .extra = Extra.make(0),
        });
        try stack.list.append(allocator, .{ .skip = 1, .index = index, .data = .function });
    }

    fn addSimpleBlock(stack: *Stack, tree: *ComponentTree, tag: Component.Tag, location: Source.Location, allocator: Allocator) !void {
        const component_tag: Component.Tag = switch (tag) {
            .token_left_curly => .simple_block_curly,
            .token_left_bracket => .simple_block_bracket,
            .token_left_paren => .simple_block_paren,
            else => unreachable,
        };
        _ = try newComponent(tree, allocator, .{
            .next_sibling = undefined,
            .tag = component_tag,
            .location = location,
            .extra = Extra.make(0),
        });
        stack.last().skip += 1;
    }

    fn pushSimpleBlock(stack: *Stack, tree: *ComponentTree, tag: Component.Tag, location: Source.Location, in_a_rule: bool, allocator: Allocator) !void {
        if (in_a_rule) {
            switch (stack.last().data) {
                .at_rule, .qualified_rule => {},
                else => unreachable,
            }
        }

        const component_tag: Component.Tag = switch (tag) {
            .token_left_curly => .simple_block_curly,
            .token_left_bracket => .simple_block_bracket,
            .token_left_paren => .simple_block_paren,
            else => unreachable,
        };
        const index = try newComponent(tree, allocator, .{
            .next_sibling = undefined,
            .tag = component_tag,
            .location = location,
            .extra = Extra.make(0),
        });
        try stack.list.append(allocator, .{
            .skip = 1,
            .index = index,
            .data = .{ .simple_block = .{ .tag = component_tag, .in_a_rule = in_a_rule } },
        });
    }

    fn popFrame(stack: *Stack, tree: *ComponentTree) void {
        const frame = stack.list.pop();
        assert(frame.data != .simple_block); // Use popSimpleBlock instead
        stack.last().skip += frame.skip;
        tree.components.items(.next_sibling)[frame.index] = frame.index + frame.skip;
    }

    fn popSimpleBlock(stack: *Stack, tree: *ComponentTree) void {
        const frame = stack.list.pop();
        const slice = tree.components.slice();
        slice.items(.next_sibling)[frame.index] = frame.index + frame.skip;

        if (frame.data.simple_block.in_a_rule) {
            const parent_frame = stack.list.pop();
            switch (parent_frame.data) {
                .at_rule, .qualified_rule => {},
                else => unreachable,
            }
            const combined_skip = parent_frame.skip + frame.skip;
            stack.last().skip += combined_skip;
            slice.items(.next_sibling)[parent_frame.index] = parent_frame.index + combined_skip;
            slice.items(.extra)[parent_frame.index] = Extra.make(frame.index);
        } else {
            stack.last().skip += frame.skip;
        }
    }

    fn ignoreQualifiedRule(stack: *Stack, tree: *ComponentTree) void {
        const frame = stack.list.pop();
        assert(frame.data == .qualified_rule);
        tree.components.shrinkRetainingCapacity(frame.index);
    }
};

fn loop(stack: *Stack, tree: *ComponentTree, source: Source, location: *Source.Location, allocator: Allocator) !void {
    while (stack.list.items.len > 1) {
        const frame = stack.last().*;
        switch (frame.data) {
            .root => unreachable,
            .list_of_rules => try consumeListOfRules(stack, tree, source, location, allocator),
            .list_of_component_values => try consumeListOfComponentValues(stack, tree, source, location, allocator),
            .qualified_rule => try consumeQualifiedRule(stack, tree, source, location, allocator),
            .at_rule => try consumeAtRule(stack, tree, source, location, allocator),
            .simple_block => try consumeSimpleBlock(stack, tree, source, location, allocator),
            .function => try consumeFunction(stack, tree, source, location, allocator),
        }
    }
}

fn consumeListOfRules(stack: *Stack, tree: *ComponentTree, source: Source, location: *Source.Location, allocator: Allocator) !void {
    while (true) {
        const saved_location = location.*;
        const tag = source.next(location);
        switch (tag) {
            .token_whitespace => {},
            .token_eof => return stack.popFrame(tree),
            .token_cdo, .token_cdc => {
                const top_level = stack.last().data.list_of_rules.top_level;
                if (!top_level) {
                    location.* = saved_location;
                    try stack.pushQualifiedRule(tree, saved_location, allocator);
                    return;
                }
            },
            .token_at_keyword => {
                try stack.pushAtRule(tree, saved_location, allocator);
                return;
            },
            else => {
                location.* = saved_location;
                try stack.pushQualifiedRule(tree, saved_location, allocator);
                return;
            },
        }
    }
}

fn consumeListOfComponentValues(stack: *Stack, tree: *ComponentTree, source: Source, location: *Source.Location, allocator: Allocator) !void {
    while (true) {
        const saved_location = location.*;
        const tag = source.next(location);
        switch (tag) {
            .token_eof => return stack.popFrame(tree),
            else => {
                const must_suspend = try consumeComponentValue(stack, tree, source, tag, saved_location, allocator);
                if (must_suspend) return;
            },
        }
    }
}

fn consumeAtRule(stack: *Stack, tree: *ComponentTree, source: Source, location: *Source.Location, allocator: Allocator) !void {
    while (true) {
        const saved_location = location.*;
        const tag = source.next(location);
        switch (tag) {
            .token_semicolon => return stack.popFrame(tree),
            .token_eof => {
                // NOTE: Parse error
                return stack.popFrame(tree);
            },
            .token_left_curly => {
                try stack.pushSimpleBlock(tree, tag, saved_location, true, allocator);
                return;
            },
            .simple_block_curly => {
                try stack.addSimpleBlock(tree, tag, saved_location, allocator);
                stack.popFrame(tree);
                return;
            },
            else => {
                const must_suspend = try consumeComponentValue(stack, tree, source, tag, saved_location, allocator);
                if (must_suspend) return;
            },
        }
    }
}

fn consumeQualifiedRule(stack: *Stack, tree: *ComponentTree, source: Source, location: *Source.Location, allocator: Allocator) !void {
    while (true) {
        const saved_location = location.*;
        const tag = source.next(location);
        switch (tag) {
            .token_eof => {
                // NOTE: Parse error
                return stack.ignoreQualifiedRule(tree);
            },
            .token_left_curly => {
                try stack.pushSimpleBlock(tree, tag, saved_location, true, allocator);
                return;
            },
            .simple_block_curly => {
                try stack.addSimpleBlock(tree, tag, saved_location, allocator);
                stack.popFrame(tree);
                return;
            },
            else => {
                const must_suspend = try consumeComponentValue(stack, tree, source, tag, saved_location, allocator);
                if (must_suspend) return;
            },
        }
    }
}

fn consumeComponentValue(
    stack: *Stack,
    tree: *ComponentTree,
    source: Source,
    tag: Component.Tag,
    location: Source.Location,
    allocator: Allocator,
) !bool {
    switch (tag) {
        .token_left_curly, .token_left_bracket, .token_left_paren => {
            try stack.pushSimpleBlock(tree, tag, location, false, allocator);
            return true;
        },
        .token_function => {
            try stack.pushFunction(tree, location, allocator);
            return true;
        },
        .token_delim => {
            const codepoint = source.getDelimeter(location);
            try stack.addComponent(tree, .token_delim, location, Extra.make(codepoint), allocator);
            return false;
        },
        else => {
            try stack.addComponent(tree, tag, location, Extra.make(0), allocator);
            return false;
        },
    }
}

fn consumeSimpleBlock(stack: *Stack, tree: *ComponentTree, source: Source, location: *Source.Location, allocator: Allocator) !void {
    const ending_tag = stack.last().data.simple_block.endingTokenTag();
    while (true) {
        const saved_location = location.*;
        const tag = source.next(location);
        if (tag == ending_tag) {
            return stack.popSimpleBlock(tree);
        } else if (tag == .token_eof) {
            // NOTE: Parse error
            return stack.popSimpleBlock(tree);
        } else {
            const must_suspend = try consumeComponentValue(stack, tree, source, tag, saved_location, allocator);
            if (must_suspend) return;
        }
    }
}

fn consumeFunction(stack: *Stack, tree: *ComponentTree, source: Source, location: *Source.Location, allocator: Allocator) !void {
    while (true) {
        const saved_location = location.*;
        const tag = source.next(location);
        switch (tag) {
            .token_right_paren => return stack.popFrame(tree),
            .token_eof => {
                // NOTE: Parse error
                return stack.popFrame(tree);
            },
            else => {
                const must_suspend = try consumeComponentValue(stack, tree, source, tag, saved_location, allocator);
                if (must_suspend) return;
            },
        }
    }
}

test "parse a stylesheet" {
    const allocator = std.testing.allocator;
    const input =
        \\@charset "utf-8";
        \\@new-rule {}
        \\
        \\root {
        \\    print(we, can, parse, this!)
        \\}
        \\broken
    ;

    const ascii8ToAscii7 = @import("../../zss.zig").util.ascii8ToAscii7;
    const ascii = ascii8ToAscii7(input);

    const token_source = Source.init(try tokenize.Source.init(ascii));

    var tree = try parseStylesheet(token_source, allocator);
    defer tree.deinit(allocator);

    // zig fmt: off
    const expected = [25]Component{
        .{ .next_sibling = 25, .tag = .rule_list,          .location = .{ .value = 0 },  .extra = Extra.make(0)   },
        .{ .next_sibling = 4,  .tag = .at_rule,            .location = .{ .value = 0 },  .extra = Extra.make(0)   },
        .{ .next_sibling = 3,  .tag = .token_whitespace,   .location = .{ .value = 8 },  .extra = Extra.make(0)   },
        .{ .next_sibling = 4,  .tag = .token_string,       .location = .{ .value = 9 },  .extra = Extra.make(0)   },
        .{ .next_sibling = 7,  .tag = .at_rule,            .location = .{ .value = 18 }, .extra = Extra.make(6)   },
        .{ .next_sibling = 6,  .tag = .token_whitespace,   .location = .{ .value = 27 }, .extra = Extra.make(0)   },
        .{ .next_sibling = 7,  .tag = .simple_block_curly, .location = .{ .value = 28 }, .extra = Extra.make(0)   },
        .{ .next_sibling = 25, .tag = .qualified_rule,     .location = .{ .value = 32 }, .extra = Extra.make(10)  },
        .{ .next_sibling = 9,  .tag = .token_ident,        .location = .{ .value = 32 }, .extra = Extra.make(0)   },
        .{ .next_sibling = 10, .tag = .token_whitespace,   .location = .{ .value = 36 }, .extra = Extra.make(0)   },
        .{ .next_sibling = 25, .tag = .simple_block_curly, .location = .{ .value = 37 }, .extra = Extra.make(0)   },
        .{ .next_sibling = 12, .tag = .token_whitespace,   .location = .{ .value = 38 }, .extra = Extra.make(0)   },
        .{ .next_sibling = 24, .tag = .function,           .location = .{ .value = 43 }, .extra = Extra.make(0)   },
        .{ .next_sibling = 14, .tag = .token_ident,        .location = .{ .value = 49 }, .extra = Extra.make(0)   },
        .{ .next_sibling = 15, .tag = .token_comma,        .location = .{ .value = 51 }, .extra = Extra.make(0)   },
        .{ .next_sibling = 16, .tag = .token_whitespace,   .location = .{ .value = 52 }, .extra = Extra.make(0)   },
        .{ .next_sibling = 17, .tag = .token_ident,        .location = .{ .value = 53 }, .extra = Extra.make(0)   },
        .{ .next_sibling = 18, .tag = .token_comma,        .location = .{ .value = 56 }, .extra = Extra.make(0)   },
        .{ .next_sibling = 19, .tag = .token_whitespace,   .location = .{ .value = 57 }, .extra = Extra.make(0)   },
        .{ .next_sibling = 20, .tag = .token_ident,        .location = .{ .value = 58 }, .extra = Extra.make(0)   },
        .{ .next_sibling = 21, .tag = .token_comma,        .location = .{ .value = 63 }, .extra = Extra.make(0)   },
        .{ .next_sibling = 22, .tag = .token_whitespace,   .location = .{ .value = 64 }, .extra = Extra.make(0)   },
        .{ .next_sibling = 23, .tag = .token_ident,        .location = .{ .value = 65 }, .extra = Extra.make(0)   },
        .{ .next_sibling = 24, .tag = .token_delim,        .location = .{ .value = 69 }, .extra = Extra.make('!') },
        .{ .next_sibling = 25, .tag = .token_whitespace,   .location = .{ .value = 71 }, .extra = Extra.make(0)   },
    };
    // zig fmt: on

    const slice = tree.components.slice();
    if (expected.len != slice.len) return error.TestFailure;
    for (expected, 0..) |ex, i| {
        const actual = slice.get(i);
        try std.testing.expectEqual(ex, actual);
    }
}
