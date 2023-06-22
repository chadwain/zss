const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const MultiArrayList = std.MultiArrayList;

pub const tokenize = @import("./tokenize.zig");

/// A source of `Component.Tag`.
pub const Source = struct {
    source: tokenize.CodepointSource,

    pub const Location = struct {
        value: Value,

        pub const Value = u32;

        pub fn format(loc: Location, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
            try writer.print("{}", .{loc.value});
        }
    };

    pub fn init(source: tokenize.CodepointSource) Source {
        return Source{ .source = source };
    }

    pub fn next(source: *Source) Component.Tag {
        while (true) {
            const tag = tokenize.nextToken(&source.source);
            if (tag != .token_comments) return tag;
        }
    }

    pub fn location(source: Source) Location {
        return source.source.location();
    }

    pub fn seek(source: *Source, loc: Location) void {
        source.source.seek(loc);
    }

    pub fn matchDelimeter(source: *Source, codepoint: u21) bool {
        return source.source.matchDelimeter(codepoint);
    }

    pub fn matchKeyword(source: *Source, keyword: []const u7) bool {
        return source.source.matchKeyword(keyword);
    }
};

pub const Component = struct {
    skip: ComponentTree.Size,
    tag: Tag,
    /// The location of this Component in whatever source created it.
    location: Source.Location,
    /// Additional info about the Component. The meaning of this value depends on `tag`.
    extra: ComponentTree.Size,

    pub const Tag = enum {
        /// The end of a sequence of tokens
        token_eof,
        /// A sequence of one or more comment blocks
        /// location: The '/' of the first comment block
        token_comments,

        /// An identifier.
        /// location: The first codepoint of the identifier
        token_ident,
        /// An identifier + a '(' codepoint
        /// location: The first codepoint of the function name
        token_function,
        /// A '@' codepoint + an identifier
        /// location: The '@' codepoint
        token_at_keyword,
        /// A '#' codepoint + an identifier
        /// location: The '#' codepoint
        token_hash_unrestricted,
        /// A '#' codepoint + an identifier, that also forms a valid ID selector
        /// location: The '#' codepoint
        token_hash_id,
        /// A quoted string
        /// location: The beginning '\'' or '"' codepoint
        token_string,
        /// A quoted string with an unescaped newline in it
        /// location: The beginning '\'' or '"' codepoint
        token_bad_string,
        /// The identifier "url" + a '(' codepoint + a sequence of codepoints + a ')' codepoint
        /// location: The 'u' of "url"
        token_url,
        /// Identical to `token_url`, but the sequence contains invalid codepoints
        token_bad_url,
        /// A single codepoint
        /// location: The codepoint
        token_delim,
        /// A numeric value (integral or floating point)
        /// location: The first codepoint of the number
        token_number,
        /// A numeric value + a '%' codepoint
        /// location: The first codepoint of the number
        token_percentage,
        /// A numeric value + an identifier
        /// location: The first codepoint of the number
        token_dimension,
        /// A series of one or more whitespace codepoints
        /// location: The first whitespace codepoint
        token_whitespace,
        /// The sequence "<!--"
        /// location: The '<' of the sequence
        token_cdo,
        /// The sequence "-->"
        /// location: The first '-' of the sequence
        token_cdc,
        /// A ':' codepoint
        /// location: The codepoint
        token_colon,
        /// A ';' codepoint
        /// location: The codepoint
        token_semicolon,
        /// A ',' codepoint
        /// location: The codepoint
        token_comma,
        /// A '[' codepoint
        /// location: The codepoint
        token_left_bracket,
        /// A ']' codepoint
        /// location: The codepoint
        token_right_bracket,
        /// A '(' codepoint
        /// location: The codepoint
        token_left_paren,
        /// A ')' codepoint
        /// location: The codepoint
        token_right_paren,
        /// A '{' codepoint
        /// location: The codepoint
        token_left_curly,
        /// A '}' codepoint
        /// location: The codepoint
        token_right_curly,

        /// A name beginning with '@'
        /// children: A prelude (a sequence of components) + optionally, a `simple_block_curly`
        /// location: The '@' of its name
        /// extra: If 0, it is meaningless.
        ///        Else, the skip from this component to its `simple_block_curly`
        at_rule,
        /// children: A prelude (a sequence of components) + a `simple_block_curly`
        /// extra: The skip from this component to its `simple_block_curly`
        qualified_rule,
        /// An identifier
        /// children: A sequence of components
        /// location: The first codepoint of its name
        function,
        /// A '[]-block'
        /// children: A sequence of components
        /// location: The '[' codepoint that opens the block
        simple_block_bracket,
        /// A '{}-block'
        /// children: A sequence of components
        /// location: The '{' codepoint that opens the block
        simple_block_curly,
        /// A '()-block'
        /// children: A sequence of components
        /// location: The '(' codepoint that opens the block
        simple_block_paren,
        /// children: A sequence of `at_rule` and `qualified_rule`
        rule_list,

        grammar_sequence,
        grammar_alternatives,
        grammar_optional,
    };
};

/// A tree of `Component`s. Implemented as a skip tree, with elements being indexed by `Size`.
pub const ComponentTree = struct {
    components: List = .{},

    pub const Size = u32;
    pub const List = MultiArrayList(Component);

    /// Free resources associated with the ComponentTree.
    pub fn deinit(tree: *ComponentTree, allocator: Allocator) void {
        tree.components.deinit(allocator);
    }

    pub const debug = struct {
        pub fn print(tree: ComponentTree, allocator: Allocator, writer: anytype) !void {
            const c = tree.components;
            try writer.print("ComponentTree:\narray len {}\n", .{c.len});
            if (c.len == 0) return;
            try writer.print("tree size {}\n", .{c.items(.skip)[0]});

            const Item = struct {
                current: ComponentTree.Size,
                end: ComponentTree.Size,
            };
            var stack = ArrayListUnmanaged(Item){};
            defer stack.deinit(allocator);
            try stack.append(allocator, .{ .current = 0, .end = c.items(.skip)[0] });

            while (stack.items.len > 0) {
                const last = &stack.items[stack.items.len - 1];
                if (last.current != last.end) {
                    const index = last.current;
                    const component = c.get(index);
                    const indent = (stack.items.len - 1) * 4;
                    try writer.writeByteNTimes(' ', indent);
                    try writer.print("{} {s} {} {}\n", .{ index, @tagName(component.tag), component.location, component.extra });

                    last.current += component.skip;
                    if (component.skip != 1) {
                        try stack.append(allocator, .{ .current = index + 1, .end = index + component.skip });
                    }
                } else {
                    _ = stack.pop();
                }
            }
        }
    };
};

fn addComponent(tree: *ComponentTree, allocator: Allocator, component: Component) !ComponentTree.Size {
    if (tree.components.len == std.math.maxInt(ComponentTree.Size)) return error.Overflow;
    const index = @intCast(ComponentTree.Size, tree.components.len);
    try tree.components.append(allocator, component);
    return index;
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
        // true if the simple block is part of a qualified rule or an at rule.
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

    fn addToken(stack: *Stack, tree: *ComponentTree, tag: Component.Tag, location: Source.Location, allocator: Allocator) !void {
        _ = try addComponent(tree, allocator, .{ .skip = 1, .tag = tag, .location = location, .extra = 0 });
        stack.last().skip += 1;
    }

    fn pushListOfRules(stack: *Stack, tree: *ComponentTree, location: Source.Location, top_level: bool, allocator: Allocator) !void {
        const index = try addComponent(tree, allocator, .{ .skip = undefined, .tag = .rule_list, .location = location, .extra = 0 });
        try stack.list.append(allocator, .{ .skip = 1, .index = index, .data = .{ .list_of_rules = .{ .top_level = top_level } } });
    }

    fn pushAtRule(stack: *Stack, tree: *ComponentTree, location: Source.Location, allocator: Allocator) !void {
        const index = try addComponent(tree, allocator, .{ .skip = undefined, .tag = .at_rule, .location = location, .extra = 0 });
        try stack.list.append(allocator, .{ .skip = 1, .index = index, .data = .at_rule });
    }

    fn pushQualifiedRule(stack: *Stack, tree: *ComponentTree, location: Source.Location, allocator: Allocator) !void {
        const index = try addComponent(tree, allocator, .{ .skip = undefined, .tag = .qualified_rule, .location = location, .extra = 0 });
        try stack.list.append(allocator, .{ .skip = 1, .index = index, .data = .qualified_rule });
    }

    fn pushFunction(stack: *Stack, tree: *ComponentTree, location: Source.Location, allocator: Allocator) !void {
        const index = try addComponent(tree, allocator, .{ .skip = undefined, .tag = .function, .location = location, .extra = 0 });
        try stack.list.append(allocator, .{ .skip = 1, .index = index, .data = .function });
    }

    fn addSimpleBlock(stack: *Stack, tree: *ComponentTree, tag: Component.Tag, location: Source.Location, allocator: Allocator) !void {
        const component_tag: Component.Tag = switch (tag) {
            .token_left_curly => .simple_block_curly,
            .token_left_bracket => .simple_block_bracket,
            .token_left_paren => .simple_block_paren,
            else => unreachable,
        };
        _ = try addComponent(tree, allocator, .{ .skip = undefined, .tag = component_tag, .location = location, .extra = 0 });
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
        const index = try addComponent(tree, allocator, .{ .skip = undefined, .tag = component_tag, .location = location, .extra = 0 });
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
        tree.components.items(.skip)[frame.index] = frame.skip;
    }

    fn popSimpleBlock(stack: *Stack, tree: *ComponentTree) void {
        const frame = stack.list.pop();
        const slice = tree.components.slice();
        slice.items(.skip)[frame.index] = frame.skip;

        if (frame.data.simple_block.in_a_rule) {
            const parent_frame = stack.list.pop();
            switch (parent_frame.data) {
                .at_rule, .qualified_rule => {},
                else => unreachable,
            }
            const combined_skip = parent_frame.skip + frame.skip;
            stack.last().skip += combined_skip;
            slice.items(.skip)[parent_frame.index] = combined_skip;
            slice.items(.extra)[parent_frame.index] = frame.index - parent_frame.index;
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

pub fn parseStylesheet(source: *Source, allocator: Allocator) !ComponentTree {
    var stack = try Stack.init(allocator);
    defer stack.deinit(allocator);

    var tree = ComponentTree{ .components = .{} };
    errdefer tree.deinit(allocator);

    try stack.pushListOfRules(&tree, source.location(), true, allocator);
    try loop(&stack, &tree, source, allocator);
    return tree;
}

fn loop(stack: *Stack, tree: *ComponentTree, source: *Source, allocator: Allocator) !void {
    while (stack.list.items.len > 1) {
        const frame = stack.last().*;
        switch (frame.data) {
            .root => unreachable,
            .list_of_rules => try consumeListOfRules(stack, tree, source, allocator),
            .qualified_rule => try consumeQualifiedRule(stack, tree, source, allocator),
            .at_rule => try consumeAtRule(stack, tree, source, allocator),
            .simple_block => try consumeSimpleBlock(stack, tree, source, allocator),
            .function => try consumeFunction(stack, tree, source, allocator),
        }
    }
}

fn consumeListOfRules(stack: *Stack, tree: *ComponentTree, source: *Source, allocator: Allocator) !void {
    while (true) {
        const location = source.location();
        const tag = source.next();
        switch (tag) {
            .token_whitespace => {},
            .token_eof => return stack.popFrame(tree),
            .token_cdo, .token_cdc => {
                const top_level = stack.last().data.list_of_rules.top_level;
                if (!top_level) {
                    source.seek(location);
                    try stack.pushQualifiedRule(tree, location, allocator);
                    return;
                }
            },
            .token_at_keyword => {
                try stack.pushAtRule(tree, location, allocator);
                return;
            },
            else => {
                source.seek(location);
                try stack.pushQualifiedRule(tree, location, allocator);
                return;
            },
        }
    }
}

fn consumeAtRule(stack: *Stack, tree: *ComponentTree, source: *Source, allocator: Allocator) !void {
    while (true) {
        const location = source.location();
        const tag = source.next();
        switch (tag) {
            .token_semicolon => return stack.popFrame(tree),
            .token_eof => {
                // NOTE: Parse error
                return stack.popFrame(tree);
            },
            .token_left_curly => {
                try stack.pushSimpleBlock(tree, tag, location, true, allocator);
                return;
            },
            .simple_block_curly => {
                try stack.addSimpleBlock(tree, tag, location, allocator);
                stack.popFrame(tree);
                return;
            },
            else => {
                const must_suspend = try consumeComponentValue(stack, tree, tag, location, allocator);
                if (must_suspend) return;
            },
        }
    }
}

fn consumeQualifiedRule(stack: *Stack, tree: *ComponentTree, source: *Source, allocator: Allocator) !void {
    while (true) {
        const location = source.location();
        const tag = source.next();
        switch (tag) {
            .token_eof => {
                // NOTE: Parse error
                return stack.ignoreQualifiedRule(tree);
            },
            .token_left_curly => {
                try stack.pushSimpleBlock(tree, tag, location, true, allocator);
                return;
            },
            .simple_block_curly => {
                try stack.addSimpleBlock(tree, tag, location, allocator);
                stack.popFrame(tree);
                return;
            },
            else => {
                const must_suspend = try consumeComponentValue(stack, tree, tag, location, allocator);
                if (must_suspend) return;
            },
        }
    }
}

fn consumeComponentValue(stack: *Stack, tree: *ComponentTree, tag: Component.Tag, location: Source.Location, allocator: Allocator) !bool {
    switch (tag) {
        .token_left_curly, .token_left_bracket, .token_left_paren => {
            try stack.pushSimpleBlock(tree, tag, location, false, allocator);
            return true;
        },
        .token_function => {
            try stack.pushFunction(tree, location, allocator);
            return true;
        },
        else => {
            try stack.addToken(tree, tag, location, allocator);
            return false;
        },
    }
}

fn consumeSimpleBlock(stack: *Stack, tree: *ComponentTree, source: *Source, allocator: Allocator) !void {
    const ending_tag = stack.last().data.simple_block.endingTokenTag();
    while (true) {
        const location = source.location();
        const tag = source.next();
        if (tag == ending_tag) {
            return stack.popSimpleBlock(tree);
        } else if (tag == .token_eof) {
            // NOTE: Parse error
            return stack.popSimpleBlock(tree);
        } else {
            const must_suspend = try consumeComponentValue(stack, tree, tag, location, allocator);
            if (must_suspend) return;
        }
    }
}

fn consumeFunction(stack: *Stack, tree: *ComponentTree, source: *Source, allocator: Allocator) !void {
    while (true) {
        const location = source.location();
        const tag = source.next();
        switch (tag) {
            .token_right_paren => return stack.popFrame(tree),
            .token_eof => {
                // NOTE: Parse error
                return stack.popFrame(tree);
            },
            else => {
                const must_suspend = try consumeComponentValue(stack, tree, tag, location, allocator);
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

    const asciiString = @import("../../zss.zig").util.asciiString;
    const ascii = asciiString(input);

    var token_source = Source.init(try tokenize.CodepointSource.init(ascii));

    var tree = try parseStylesheet(&token_source, allocator);
    defer tree.deinit(allocator);

    // zig fmt: off
    const expected = [25]Component{
        .{ .skip = 25, .tag = .rule_list,          .location = .{ .value = 0 },  .extra = 0 },
        .{ .skip = 3,  .tag = .at_rule,            .location = .{ .value = 0 },  .extra = 0 },
        .{ .skip = 1,  .tag = .token_whitespace,   .location = .{ .value = 8 },  .extra = 0 },
        .{ .skip = 1,  .tag = .token_string,       .location = .{ .value = 9 },  .extra = 0 },
        .{ .skip = 3,  .tag = .at_rule,            .location = .{ .value = 18 }, .extra = 2 },
        .{ .skip = 1,  .tag = .token_whitespace,   .location = .{ .value = 27 }, .extra = 0 },
        .{ .skip = 1,  .tag = .simple_block_curly, .location = .{ .value = 28 }, .extra = 0 },
        .{ .skip = 18, .tag = .qualified_rule,     .location = .{ .value = 32 }, .extra = 3 },
        .{ .skip = 1,  .tag = .token_ident,        .location = .{ .value = 32 }, .extra = 0 },
        .{ .skip = 1,  .tag = .token_whitespace,   .location = .{ .value = 36 }, .extra = 0 },
        .{ .skip = 15, .tag = .simple_block_curly, .location = .{ .value = 37 }, .extra = 0 },
        .{ .skip = 1,  .tag = .token_whitespace,   .location = .{ .value = 38 }, .extra = 0 },
        .{ .skip = 12, .tag = .function,           .location = .{ .value = 43 }, .extra = 0 },
        .{ .skip = 1,  .tag = .token_ident,        .location = .{ .value = 49 }, .extra = 0 },
        .{ .skip = 1,  .tag = .token_comma,        .location = .{ .value = 51 }, .extra = 0 },
        .{ .skip = 1,  .tag = .token_whitespace,   .location = .{ .value = 52 }, .extra = 0 },
        .{ .skip = 1,  .tag = .token_ident,        .location = .{ .value = 53 }, .extra = 0 },
        .{ .skip = 1,  .tag = .token_comma,        .location = .{ .value = 56 }, .extra = 0 },
        .{ .skip = 1,  .tag = .token_whitespace,   .location = .{ .value = 57 }, .extra = 0 },
        .{ .skip = 1,  .tag = .token_ident,        .location = .{ .value = 58 }, .extra = 0 },
        .{ .skip = 1,  .tag = .token_comma,        .location = .{ .value = 63 }, .extra = 0 },
        .{ .skip = 1,  .tag = .token_whitespace,   .location = .{ .value = 64 }, .extra = 0 },
        .{ .skip = 1,  .tag = .token_ident,        .location = .{ .value = 65 }, .extra = 0 },
        .{ .skip = 1,  .tag = .token_delim,        .location = .{ .value = 69 }, .extra = 0 },
        .{ .skip = 1,  .tag = .token_whitespace,   .location = .{ .value = 71 }, .extra = 0 },
    };
    // zig fmt: on

    const slice = tree.components.slice();
    if (expected.len != slice.len) return error.TestFailure;
    for (expected, 0..) |ex, i| {
        const actual = slice.get(i);
        try std.testing.expectEqual(ex, actual);
    }
}
