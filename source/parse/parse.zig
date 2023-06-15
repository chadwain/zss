const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const MultiArrayList = std.MultiArrayList;

const zss = @import("../../zss.zig");
const Source = zss.tokenize.Source;
const Token = zss.tokenize.Token;

pub const TokenSource = struct {
    source: Source,

    pub const Location = Source.Location;

    pub fn init(source: Source) TokenSource {
        return TokenSource{ .source = source };
    }

    fn next(source: *TokenSource) Token {
        const nextToken = zss.tokenize.nextToken;
        return nextToken(&source.source);
    }

    fn location(source: TokenSource) Location {
        return source.source.location();
    }

    fn seek(source: *TokenSource, location_: Location) void {
        source.source.seek(location_);
    }
};

pub const Component = struct {
    skip: SyntaxTree.Size,
    tag: Tag,
    location: TokenSource.Location,
    extra: SyntaxTree.Size,

    pub const Tag = enum {
        eof,
        ident,
        function_token,
        at_keyword,
        hash_unrestricted,
        hash_id,
        string,
        bad_string,
        url,
        bad_url,
        delim,
        number,
        percentage,
        dimension,
        whitespace,
        cdo,
        cdc,
        colon,
        semicolon,
        comma,
        left_bracket,
        right_bracket,
        left_paren,
        right_paren,
        left_curly,
        right_curly,
        comments,

        at_rule,
        qualified_rule,
        function_block,
        simple_block_bracket,
        simple_block_curly,
        simple_block_paren,
        rule_list,
    };
};

pub const SyntaxTree = struct {
    components: MultiArrayList(Component),

    pub const Size = u32;

    pub fn deinit(syntax_tree: *SyntaxTree, allocator: Allocator) void {
        syntax_tree.components.deinit(allocator);
    }
};

fn addComponent(syntax_tree: *SyntaxTree, allocator: Allocator, component: Component) !SyntaxTree.Size {
    if (syntax_tree.components.len == std.math.maxInt(SyntaxTree.Size)) return error.Overflow;
    const index = @intCast(SyntaxTree.Size, syntax_tree.components.len);
    try syntax_tree.components.append(allocator, component);
    return index;
}

const Stack = struct {
    list: ArrayListUnmanaged(Frame),

    const Frame = struct {
        skip: SyntaxTree.Size,
        index: SyntaxTree.Size,
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
                .simple_block_curly => .right_curly,
                .simple_block_bracket => .right_bracket,
                .simple_block_paren => .right_paren,
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

    fn addToken(stack: *Stack, syntax_tree: *SyntaxTree, token: Token, allocator: Allocator) !void {
        _ = try addComponent(syntax_tree, allocator, .{ .skip = 1, .tag = token.tag, .location = token.start, .extra = 0 });
        stack.last().skip += 1;
    }

    fn pushListOfRules(stack: *Stack, syntax_tree: *SyntaxTree, location: TokenSource.Location, top_level: bool, allocator: Allocator) !void {
        const index = try addComponent(syntax_tree, allocator, .{ .skip = undefined, .tag = .rule_list, .location = location, .extra = 0 });
        try stack.list.append(allocator, .{ .skip = 1, .index = index, .data = .{ .list_of_rules = .{ .top_level = top_level } } });
    }

    fn pushAtRule(stack: *Stack, syntax_tree: *SyntaxTree, location: TokenSource.Location, allocator: Allocator) !void {
        const index = try addComponent(syntax_tree, allocator, .{ .skip = undefined, .tag = .at_rule, .location = location, .extra = 0 });
        try stack.list.append(allocator, .{ .skip = 1, .index = index, .data = .at_rule });
    }

    fn pushQualifiedRule(stack: *Stack, syntax_tree: *SyntaxTree, location: TokenSource.Location, allocator: Allocator) !void {
        const index = try addComponent(syntax_tree, allocator, .{ .skip = undefined, .tag = .qualified_rule, .location = location, .extra = 0 });
        try stack.list.append(allocator, .{ .skip = 1, .index = index, .data = .qualified_rule });
    }

    fn pushFunction(stack: *Stack, syntax_tree: *SyntaxTree, location: TokenSource.Location, allocator: Allocator) !void {
        const index = try addComponent(syntax_tree, allocator, .{ .skip = undefined, .tag = .function_block, .location = location, .extra = 0 });
        try stack.list.append(allocator, .{ .skip = 1, .index = index, .data = .function });
    }

    fn addSimpleBlock(stack: *Stack, syntax_tree: *SyntaxTree, token: Token, allocator: Allocator) !void {
        const component_tag: Component.Tag = switch (token.tag) {
            .left_curly => .simple_block_curly,
            .left_bracket => .simple_block_bracket,
            .left_paren => .simple_block_paren,
            else => unreachable,
        };
        _ = try addComponent(syntax_tree, allocator, .{ .skip = undefined, .tag = component_tag, .location = token.start, .extra = 0 });
        stack.last().skip += 1;
    }

    fn pushSimpleBlock(stack: *Stack, syntax_tree: *SyntaxTree, token: Token, in_a_rule: bool, allocator: Allocator) !void {
        if (in_a_rule) {
            switch (stack.last().data) {
                .at_rule, .qualified_rule => {},
                else => unreachable,
            }
        }

        const component_tag: Component.Tag = switch (token.tag) {
            .left_curly => .simple_block_curly,
            .left_bracket => .simple_block_bracket,
            .left_paren => .simple_block_paren,
            else => unreachable,
        };
        const index = try addComponent(syntax_tree, allocator, .{ .skip = undefined, .tag = component_tag, .location = token.start, .extra = 0 });
        try stack.list.append(allocator, .{
            .skip = 1,
            .index = index,
            .data = .{ .simple_block = .{ .tag = component_tag, .in_a_rule = in_a_rule } },
        });
    }

    fn popFrame(stack: *Stack, syntax_tree: *SyntaxTree) void {
        const frame = stack.list.pop();
        assert(frame.data != .simple_block); // Use popSimpleBlock instead
        stack.last().skip += frame.skip;
        syntax_tree.components.items(.skip)[frame.index] = frame.skip;
    }

    fn popSimpleBlock(stack: *Stack, syntax_tree: *SyntaxTree) void {
        const frame = stack.list.pop();
        const slice = syntax_tree.components.slice();
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
            slice.items(.extra)[parent_frame.index] = frame.index;
        } else {
            stack.last().skip += frame.skip;
        }
    }

    fn ignoreQualifiedRule(stack: *Stack, syntax_tree: *SyntaxTree) void {
        const frame = stack.list.pop();
        assert(frame.data == .qualified_rule);
        syntax_tree.components.shrinkRetainingCapacity(frame.index);
    }
};

pub fn parseStylesheet(source: *TokenSource, allocator: Allocator) !SyntaxTree {
    var stack = try Stack.init(allocator);
    defer stack.deinit(allocator);

    var syntax_tree = SyntaxTree{ .components = .{} };
    errdefer syntax_tree.deinit(allocator);

    try stack.pushListOfRules(&syntax_tree, source.location(), true, allocator);
    try loop(&stack, &syntax_tree, source, allocator);
    return syntax_tree;
}

fn loop(stack: *Stack, syntax_tree: *SyntaxTree, source: *TokenSource, allocator: Allocator) !void {
    while (stack.list.items.len > 1) {
        const frame = stack.last().*;
        switch (frame.data) {
            .root => unreachable,
            .list_of_rules => try consumeListOfRules(stack, syntax_tree, source, allocator),
            .qualified_rule => try consumeQualifiedRule(stack, syntax_tree, source, allocator),
            .at_rule => try consumeAtRule(stack, syntax_tree, source, allocator),
            .simple_block => try consumeSimpleBlock(stack, syntax_tree, source, allocator),
            .function => try consumeFunction(stack, syntax_tree, source, allocator),
        }
    }
}

fn consumeListOfRules(stack: *Stack, syntax_tree: *SyntaxTree, source: *TokenSource, allocator: Allocator) !void {
    while (true) {
        const next_location = source.location();
        const token = source.next();
        switch (token.tag) {
            .whitespace => {},
            .eof => return stack.popFrame(syntax_tree),
            .cdo, .cdc => {
                const top_level = stack.last().data.list_of_rules.top_level;
                if (!top_level) {
                    source.seek(next_location);
                    try stack.pushQualifiedRule(syntax_tree, token.start, allocator);
                    return;
                }
            },
            .at_keyword => {
                try stack.pushAtRule(syntax_tree, token.start, allocator);
                return;
            },
            else => {
                source.seek(next_location);
                try stack.pushQualifiedRule(syntax_tree, token.start, allocator);
                return;
            },
        }
    }
}

fn consumeAtRule(stack: *Stack, syntax_tree: *SyntaxTree, source: *TokenSource, allocator: Allocator) !void {
    while (true) {
        const token = source.next();
        switch (token.tag) {
            .semicolon => return stack.popFrame(syntax_tree),
            .eof => {
                // NOTE: Parse error
                return stack.popFrame(syntax_tree);
            },
            .left_curly => {
                try stack.pushSimpleBlock(syntax_tree, token, true, allocator);
                return;
            },
            .simple_block_curly => {
                try stack.addSimpleBlock(syntax_tree, token, allocator);
                stack.popFrame(syntax_tree);
                return;
            },
            else => {
                const must_suspend = try consumeComponentValue(stack, syntax_tree, token, allocator);
                if (must_suspend) return;
            },
        }
    }
}

fn consumeQualifiedRule(stack: *Stack, syntax_tree: *SyntaxTree, source: *TokenSource, allocator: Allocator) !void {
    while (true) {
        const token = source.next();
        switch (token.tag) {
            .eof => {
                // NOTE: Parse error
                return stack.ignoreQualifiedRule(syntax_tree);
            },
            .left_curly => {
                try stack.pushSimpleBlock(syntax_tree, token, true, allocator);
                return;
            },
            .simple_block_curly => {
                try stack.addSimpleBlock(syntax_tree, token, allocator);
                stack.popFrame(syntax_tree);
                return;
            },
            else => {
                const must_suspend = try consumeComponentValue(stack, syntax_tree, token, allocator);
                if (must_suspend) return;
            },
        }
    }
}

fn consumeComponentValue(stack: *Stack, syntax_tree: *SyntaxTree, token: Token, allocator: Allocator) !bool {
    switch (token.tag) {
        .left_curly, .left_bracket, .left_paren => {
            try stack.pushSimpleBlock(syntax_tree, token, false, allocator);
            return true;
        },
        .function_token => {
            try stack.pushFunction(syntax_tree, token.start, allocator);
            return true;
        },
        else => {
            try stack.addToken(syntax_tree, token, allocator);
            return false;
        },
    }
}

fn consumeSimpleBlock(stack: *Stack, syntax_tree: *SyntaxTree, source: *TokenSource, allocator: Allocator) !void {
    const ending_tag = stack.last().data.simple_block.endingTokenTag();
    while (true) {
        const token = source.next();
        if (token.tag == ending_tag) {
            return stack.popSimpleBlock(syntax_tree);
        } else if (token.tag == .eof) {
            // NOTE: Parse error
            return stack.popSimpleBlock(syntax_tree);
        } else {
            const must_suspend = try consumeComponentValue(stack, syntax_tree, token, allocator);
            if (must_suspend) return;
        }
    }
}

fn consumeFunction(stack: *Stack, syntax_tree: *SyntaxTree, source: *TokenSource, allocator: Allocator) !void {
    while (true) {
        const token = source.next();
        switch (token.tag) {
            .right_paren => return stack.popFrame(syntax_tree),
            .eof => {
                // NOTE: Parse error
                return stack.popFrame(syntax_tree);
            },
            else => {
                const must_suspend = try consumeComponentValue(stack, syntax_tree, token, allocator);
                if (must_suspend) return;
            },
        }
    }
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const input =
        \\@charset "utf-8";
        \\@new-rule {}
        \\
        \\root {
        \\    print(we, can, parse, this!)
        \\}
        \\broken
    ;
    const ascii = zss.util.asciiString(input);

    var token_source = TokenSource.init(try Source.init(ascii));

    var syntax_tree = try parseStylesheet(&token_source, allocator);
    defer syntax_tree.deinit(allocator);

    const stderr = std.io.getStdErr().writer();
    try debugPrint(syntax_tree, allocator, ascii, stderr);
}

fn debugPrint(syntax_tree: SyntaxTree, allocator: Allocator, input: []const u7, writer: anytype) !void {
    try writer.print("Input:\n{s}\n\nTokens:\n", .{@ptrCast([]const u8, input)});
    {
        var source = try Source.init(input);
        while (true) {
            const token = zss.tokenize.nextToken(&source);
            try writer.print("{s} {}\n", .{ @tagName(token.tag), token.start });
            if (token.tag == .eof) break;
        }
        try writer.writeAll("\n");
    }

    const c = syntax_tree.components;
    try writer.print("Tree:\nlen {}\n", .{c.len});
    if (c.len == 0) return;

    const Item = struct {
        current: SyntaxTree.Size,
        end: SyntaxTree.Size,
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
