const std = @import("std");
const assert = std.debug.assert;
const panic = std.debug.panic;
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
const Token = tokenize.Token;

/// A source of `Token`.
pub const Source = struct {
    inner: tokenize.Source,

    pub const Location = tokenize.Source.Location;

    pub fn init(inner: tokenize.Source) Source {
        return Source{ .inner = inner };
    }

    /// Returns the next component tag, ignoring comments.
    pub fn next(source: Source, location: *Location) Token {
        var next_location = location.*;
        while (true) {
            const next_token = tokenize.nextToken(source.inner, next_location);
            if (next_token.token != .token_comments) {
                location.* = next_token.next_location;
                return next_token.token;
            }
            next_location = next_token.next_location;
        }
    }

    pub fn identTokenIterator(source: Source, start: Location) IdentSequenceIterator {
        return .{ .inner = source.inner.identTokenIterator(start) };
    }

    pub fn hashIdTokenIterator(source: Source, start: Location) IdentSequenceIterator {
        return .{ .inner = source.inner.hashIdTokenIterator(start) };
    }

    pub fn KV(comptime Type: type) type {
        return struct { []const u8, Type };
    }

    /// Given that `location` is the location of an <ident-token>, map the identifier at that location
    /// to the value given in `kvs`, using case-insensitive matching. If there was no match, null is returned.
    pub fn mapIdentifier(source: Source, location: Location, comptime Type: type, kvs: []const KV(Type)) ?Type {
        // TODO: Use a hash map/trie or something
        for (kvs) |kv| {
            var it = source.inner.identTokenIterator(location);
            for (kv[0]) |kw_codepoint| {
                const it_codepoint = it.next(source.inner) orelse break;
                if (toLowercase(kw_codepoint) != toLowercase(it_codepoint)) break;
            }
            if (it.next(source.inner) == null) return kv[1];
        }
        return null;
    }
};

pub const IdentSequenceIterator = struct {
    inner: tokenize.IdentSequenceIterator,

    pub fn next(it: *IdentSequenceIterator, source: Source) ?u21 {
        return it.inner.next(source.inner);
    }
};

pub fn parseCssStylesheet(source: Source, allocator: Allocator) !ComponentTree {
    var parser = try Parser.init(source, allocator);
    defer parser.deinit();

    var location = Source.Location{};
    try parser.pushListOfRules(location, true);
    try loop(&parser, &location);

    return parser.finish();
}

pub fn parseListOfComponentValues(source: Source, allocator: Allocator) !ComponentTree {
    var parser = try Parser.init(source, allocator);
    defer parser.deinit();

    var location = Source.Location{};
    try parser.pushListOfComponentValues(location);
    try loop(&parser, &location);

    return parser.finish();
}

const Parser = struct {
    stack: ArrayListUnmanaged(Frame),
    tree: ComponentTree,
    source: Source,
    allocator: Allocator,

    const Frame = struct {
        index: ComponentTree.Size,
        data: Data,

        const Data = union(enum) {
            root,
            list_of_rules: ListOfRules,
            list_of_component_values,
            style_block: StyleBlock,
            declaration_value: DeclarationValue,
            qualified_rule: QualifiedRule,
            at_rule: AtRule,
            simple_block: SimpleBlock,
            function,
        };

        const ListOfRules = struct {
            top_level: bool,
        };

        const QualifiedRule = struct {
            index_of_block: ?ComponentTree.Size = null,
            is_style_rule: bool,
        };

        const AtRule = struct {
            index_of_block: ?ComponentTree.Size = null,
        };

        const DeclarationValue = struct {
            /// A queue of the 3 most recent non-whitespace components.
            /// The most recent component is at the end (index 2).
            index_of_last_three_non_whitespace_components: [3]ComponentTree.Size = undefined,
            num_non_whitespace_components: u2 = 0,
        };

        const StyleBlock = struct {
            index_of_last_declaration: ComponentTree.Size = 0,
        };

        const SimpleBlock = struct {
            ending_token: Component.Tag,
        };
    };

    fn init(source: Source, allocator: Allocator) !Parser {
        var stack = ArrayListUnmanaged(Frame){};
        try stack.append(allocator, .{ .index = undefined, .data = .root });

        return Parser{
            .stack = stack,
            .tree = .{},
            .source = source,
            .allocator = allocator,
        };
    }

    fn deinit(parser: *Parser) void {
        parser.stack.deinit(parser.allocator);
        parser.tree.deinit(parser.allocator);
    }

    fn finish(parser: *Parser) ComponentTree {
        const tree = parser.tree;
        parser.tree = .{};
        return tree;
    }

    fn allocateComponent(parser: *Parser, component: Component) !ComponentTree.Size {
        if (parser.tree.components.len == std.math.maxInt(ComponentTree.Size)) return error.Overflow;
        const index = @as(ComponentTree.Size, @intCast(parser.tree.components.len));
        try parser.tree.components.append(parser.allocator, component);
        return index;
    }

    /// Creates a "basic" Component (one that has no children).
    fn appendBasicComponent(parser: *Parser, tag: Component.Tag, location: Source.Location, extra: Component.Extra) !void {
        const index = @as(ComponentTree.Size, @intCast(parser.tree.components.len));
        _ = try parser.allocateComponent(.{
            .next_sibling = index + 1,
            .tag = tag,
            .location = location,
            .extra = extra,
        });
    }

    fn pushListOfRules(parser: *Parser, location: Source.Location, top_level: bool) !void {
        const index = try parser.allocateComponent(.{
            .next_sibling = undefined,
            .tag = .rule_list,
            .location = location,
            .extra = Extra.make(0),
        });
        try parser.stack.append(parser.allocator, .{
            .index = index,
            .data = .{ .list_of_rules = .{ .top_level = top_level } },
        });
    }

    fn pushListOfComponentValues(parser: *Parser, location: Source.Location) !void {
        const index = try parser.allocateComponent(.{
            .next_sibling = undefined,
            .tag = .component_list,
            .location = location,
            .extra = Extra.make(0),
        });
        try parser.stack.append(parser.allocator, .{ .index = index, .data = .list_of_component_values });
    }

    /// `location` must be the location of a <function-token>.
    fn pushFunction(parser: *Parser, location: Source.Location) !void {
        const index = try parser.allocateComponent(.{
            .next_sibling = undefined,
            .tag = .function,
            .location = location,
            .extra = Extra.make(0),
        });
        try parser.stack.append(parser.allocator, .{ .index = index, .data = .function });
    }

    /// `location` must be the location of a <{-token>, <[-token>, or <(-token>.
    fn pushSimpleBlock(parser: *Parser, tag: Component.Tag, location: Source.Location) !void {
        const component_tag: Component.Tag = switch (tag) {
            .token_left_curly => .simple_block_curly,
            .token_left_square => .simple_block_square,
            .token_left_paren => .simple_block_paren,
            else => unreachable,
        };
        const index = try parser.allocateComponent(.{
            .next_sibling = undefined,
            .tag = component_tag,
            .location = location,
            .extra = Extra.make(0),
        });
        try parser.stack.append(parser.allocator, .{
            .index = index,
            .data = .{ .simple_block = .{ .ending_token = mirrorToken(tag) } },
        });
    }

    fn popComponent(parser: *Parser) void {
        const frame = parser.stack.pop();
        switch (frame.data) {
            .qualified_rule => unreachable, // use popQualifiedRule instead
            .at_rule => unreachable, // use popAtRule instead
            .style_block => unreachable, // use popStyleBlock instead
            .declaration_value => unreachable, // use popDeclarationValue instead
            else => {},
        }
        parser.tree.components.items(.next_sibling)[frame.index] = @intCast(parser.tree.components.len);
    }

    /// `location` must be the location of the first token of the at-rule (i.e. the <at-keyword-token>).
    /// To finish this component, use `popAtRule`.
    fn pushAtRule(parser: *Parser, location: Source.Location) !void {
        const index = try parser.allocateComponent(.{
            .next_sibling = undefined,
            .tag = .at_rule,
            .location = location,
            .extra = undefined,
        });
        try parser.stack.append(parser.allocator, .{ .index = index, .data = .{ .at_rule = .{} } });
    }

    fn popAtRule(parser: *Parser) void {
        const frame = parser.stack.pop();
        parser.tree.components.items(.next_sibling)[frame.index] = @intCast(parser.tree.components.len);
        parser.tree.components.items(.extra)[frame.index] = Extra.make(frame.data.at_rule.index_of_block orelse 0);
    }

    /// `location` must be the location of the first token of the qualified rule.
    /// To finish this component, use either `popQualifiedRule` or `discardQualifiedRule`.
    fn pushQualifiedRule(parser: *Parser, location: Source.Location, is_style_rule: bool) !void {
        const index = try parser.allocateComponent(.{
            .next_sibling = undefined,
            .tag = .qualified_rule,
            .location = location,
            .extra = undefined,
        });
        try parser.stack.append(parser.allocator, .{ .index = index, .data = .{ .qualified_rule = .{ .is_style_rule = is_style_rule } } });
    }

    fn popQualifiedRule(parser: *Parser) void {
        const frame = parser.stack.pop();
        parser.tree.components.items(.next_sibling)[frame.index] = @intCast(parser.tree.components.len);
        parser.tree.components.items(.extra)[frame.index] = Extra.make(frame.data.qualified_rule.index_of_block.?);
    }

    fn discardQualifiedRule(parser: *Parser) void {
        const frame = parser.stack.pop();
        assert(frame.data == .qualified_rule);
        parser.tree.components.shrinkRetainingCapacity(frame.index);
    }

    /// `location` must be the location of a <{-token>.
    /// To finish this component, use `popStyleBlock`.
    fn pushStyleBlock(parser: *Parser, location: Source.Location) !void {
        const index = try parser.allocateComponent(.{
            .next_sibling = undefined,
            .tag = .style_block,
            .location = location,
            .extra = undefined,
        });
        try parser.stack.append(parser.allocator, .{ .index = index, .data = .{ .style_block = .{} } });
    }

    fn popStyleBlock(parser: *Parser) void {
        const frame = parser.stack.pop();
        parser.tree.components.items(.next_sibling)[frame.index] = @intCast(parser.tree.components.len);
        parser.tree.components.items(.extra)[frame.index] = Extra.make(frame.data.style_block.index_of_last_declaration);
    }

    /// To finish this component, use `popDeclarationValue`.
    fn pushDeclarationValue(parser: *Parser, location: Source.Location, previous_declaration: ComponentTree.Size) !void {
        const index = try parser.allocateComponent(.{
            .next_sibling = undefined,
            .tag = undefined,
            .location = location,
            .extra = Extra.make(previous_declaration),
        });
        try parser.stack.append(parser.allocator, .{ .index = index, .data = .{ .declaration_value = .{} } });
    }

    fn popDeclarationValue(parser: *Parser) void {
        const frame = parser.stack.pop();
        var data = frame.data.declaration_value;
        const slice = parser.tree.slice();

        const is_important = blk: {
            if (data.num_non_whitespace_components < 2) break :blk false;
            const exclamation = data.index_of_last_three_non_whitespace_components[1];
            const important_string = data.index_of_last_three_non_whitespace_components[2];
            break :blk slice.tag(exclamation) == .token_delim and
                slice.extra(exclamation).codepoint() == '!' and
                slice.tag(important_string) == .token_ident and
                parser.source.mapIdentifier(slice.location(important_string), void, &.{.{ "important", {} }}) != null;
        };
        if (is_important) {
            slice.tags()[frame.index] = .declaration_important;
            data.index_of_last_three_non_whitespace_components[2] = data.index_of_last_three_non_whitespace_components[0];
            data.num_non_whitespace_components -= 2;
        } else {
            slice.tags()[frame.index] = .declaration_normal;
        }

        const next_sibling = if (data.num_non_whitespace_components > 0) blk: {
            const last_component = data.index_of_last_three_non_whitespace_components[2];
            break :blk slice.nextSibling(last_component);
        } else frame.index + 1;
        slice.nextSiblings()[frame.index] = next_sibling;

        parser.tree.components.shrinkRetainingCapacity(next_sibling);
    }
};

fn loop(parser: *Parser, location: *Source.Location) !void {
    while (parser.stack.items.len > 1) {
        const frame = &parser.stack.items[parser.stack.items.len - 1];
        switch (frame.data) {
            .root => unreachable,
            .list_of_rules => |*list_of_rules| try consumeListOfRules(parser, location, list_of_rules),
            .list_of_component_values => try consumeListOfComponentValues(parser, location),
            .qualified_rule => |*qualified_rule| try consumeQualifiedRule(parser, location, qualified_rule),
            .at_rule => |*at_rule| try consumeAtRule(parser, location, at_rule),
            .style_block => |*style_block| try consumeStyleBlockContents(parser, location, style_block),
            .declaration_value => |*declaration_value| try consumeDeclarationValue(parser, location, declaration_value),
            .simple_block => |*simple_block| try consumeSimpleBlock(parser, location, simple_block),
            .function => try consumeFunction(parser, location),
        }
    }
}

fn consumeListOfRules(parser: *Parser, location: *Source.Location, data: *const Parser.Frame.ListOfRules) !void {
    while (true) {
        const saved_location = location.*;
        const tag = parser.source.next(location);
        switch (tag) {
            .token_whitespace => {},
            .token_eof => return parser.popComponent(),
            .token_cdo, .token_cdc => {
                if (!data.top_level) {
                    location.* = saved_location;
                    try parser.pushQualifiedRule(saved_location, false);
                    return;
                }
            },
            .token_at_keyword => {
                try parser.pushAtRule(saved_location);
                return;
            },
            else => {
                location.* = saved_location;
                try parser.pushQualifiedRule(saved_location, data.top_level);
                return;
            },
        }
    }
}

fn consumeListOfComponentValues(parser: *Parser, location: *Source.Location) !void {
    while (true) {
        const saved_location = location.*;
        const tag = parser.source.next(location);
        switch (tag) {
            .token_eof => return parser.popComponent(),
            else => {
                const must_suspend = try consumeComponentValue(parser, tag, saved_location);
                if (must_suspend) return;
            },
        }
    }
}

fn consumeAtRule(parser: *Parser, location: *Source.Location, data: *Parser.Frame.AtRule) !void {
    if (data.index_of_block != null) {
        parser.popAtRule();
        return;
    }

    while (true) {
        const saved_location = location.*;
        const tag = parser.source.next(location);
        switch (tag) {
            .token_semicolon => return parser.popAtRule(),
            .token_eof => {
                // NOTE: Parse error
                return parser.popAtRule();
            },
            .token_left_curly => {
                data.index_of_block = @intCast(parser.tree.components.len);
                try parser.pushSimpleBlock(tag, saved_location);
                return;
            },
            else => {
                const must_suspend = try consumeComponentValue(parser, tag, saved_location);
                if (must_suspend) return;
            },
        }
    }
}

fn consumeQualifiedRule(parser: *Parser, location: *Source.Location, data: *Parser.Frame.QualifiedRule) !void {
    if (data.index_of_block != null) {
        parser.popQualifiedRule();
        return;
    }

    while (true) {
        const saved_location = location.*;
        const tag = parser.source.next(location);
        switch (tag) {
            .token_eof => {
                // NOTE: Parse error
                return parser.discardQualifiedRule();
            },
            .token_left_curly => {
                data.index_of_block = @intCast(parser.tree.components.len);
                switch (data.is_style_rule) {
                    false => try parser.pushSimpleBlock(tag, saved_location),
                    true => try parser.pushStyleBlock(saved_location),
                }
                return;
            },
            else => {
                const must_suspend = try consumeComponentValue(parser, tag, saved_location);
                if (must_suspend) return;
            },
        }
    }
}

fn consumeStyleBlockContents(parser: *Parser, location: *Source.Location, data: *Parser.Frame.StyleBlock) !void {
    while (true) {
        const saved_location = location.*;
        const tag = parser.source.next(location);
        switch (tag) {
            .token_right_curly, .token_eof => {
                // NOTE: This prong replicates the behavior of consumeSimpleBlock (because style blocks are simple blocks)
                // NOTE: Parse error, if it's an <EOF-token>
                parser.popStyleBlock();
                return;
            },
            .token_whitespace, .token_semicolon => {},
            .token_at_keyword => {
                try parser.pushAtRule(saved_location);
                return;
            },
            .token_ident => {
                const last_declaration: ComponentTree.Size = @intCast(parser.tree.components.len);
                const must_suspend = try consumeDeclaration(parser, location, saved_location, data.index_of_last_declaration);
                if (must_suspend) {
                    data.index_of_last_declaration = last_declaration;
                    return;
                }
            },
            else => {
                if (tag == .token_delim and tag.token_delim == '&') {
                    location.* = saved_location;
                    try parser.pushQualifiedRule(saved_location, false);
                    return;
                } else {
                    // NOTE: Parse error
                    location.* = saved_location;
                    try discardDeclaration(parser, location);
                }
            },
        }
    }
}

fn discardDeclaration(parser: *Parser, location: *Source.Location) !void {
    while (true) {
        const saved_location = location.*;
        const tag = parser.source.next(location);
        switch (tag) {
            .token_semicolon, .token_eof => break,
            .token_right_curly => {
                location.* = saved_location;
                break;
            },
            else => try ignoreComponentValue(parser, tag, location),
        }
    }
}

/// Returns true if there is a valid declaration.
fn consumeDeclaration(parser: *Parser, location: *Source.Location, name_location: Source.Location, previous_declaration: ComponentTree.Size) !bool {
    while (true) {
        const saved_location = location.*;
        const tag = parser.source.next(location);
        switch (tag) {
            .token_whitespace => {},
            .token_colon => break,
            else => {
                // NOTE: Parse error
                location.* = saved_location;
                return false;
            },
        }
    }

    while (true) {
        const saved_location = location.*;
        const tag = parser.source.next(location);
        switch (tag) {
            .token_whitespace => {},
            else => {
                location.* = saved_location;
                try parser.pushDeclarationValue(name_location, previous_declaration);
                return true;
            },
        }
    }
}

fn consumeDeclarationValue(parser: *Parser, location: *Source.Location, data: *Parser.Frame.DeclarationValue) !void {
    while (true) {
        const saved_location = location.*;
        const tag = parser.source.next(location);
        switch (tag) {
            .token_semicolon, .token_eof => {
                parser.popDeclarationValue();
                return;
            },
            .token_right_curly => {
                location.* = saved_location;
                parser.popDeclarationValue();
                return;
            },
            .token_whitespace => {
                try parser.appendBasicComponent(tag, saved_location, Extra.make(0));
            },
            else => {
                data.index_of_last_three_non_whitespace_components[0] = data.index_of_last_three_non_whitespace_components[1];
                data.index_of_last_three_non_whitespace_components[1] = data.index_of_last_three_non_whitespace_components[2];
                data.index_of_last_three_non_whitespace_components[2] = @intCast(parser.tree.components.len);
                data.num_non_whitespace_components +|= 1;

                const must_suspend = try consumeComponentValue(parser, tag, saved_location);
                if (must_suspend) return;
            },
        }
    }
}

/// Returns true if the component is "complex" (it may contain children).
fn consumeComponentValue(parser: *Parser, tag: Token, location: Source.Location) !bool {
    switch (tag) {
        .token_left_curly, .token_left_square, .token_left_paren => {
            try parser.pushSimpleBlock(tag, location);
            return true;
        },
        .token_function => {
            try parser.pushFunction(location);
            return true;
        },
        .token_delim => |codepoint| {
            try parser.appendBasicComponent(.token_delim, location, Extra.make(codepoint));
            return false;
        },
        .token_integer => |integer| {
            try parser.appendBasicComponent(.token_integer, location, Extra.make(@bitCast(integer)));
            return false;
        },
        .token_number => |number| {
            try parser.appendBasicComponent(.token_number, location, Extra.make(@bitCast(number)));
            return false;
        },
        else => {
            try parser.appendBasicComponent(tag, location, Extra.make(0));
            return false;
        },
    }
}

fn ignoreComponentValue(parser: *Parser, first_tag: Component.Tag, location: *Source.Location) !void {
    switch (first_tag) {
        .token_left_curly, .token_left_square, .token_left_paren, .token_function => {},
        else => return,
    }

    const initial_len = parser.stack.items.len;
    defer assert(parser.stack.items.len == initial_len);

    var tag = first_tag;
    while (true) {
        switch (tag) {
            .token_left_curly, .token_left_square, .token_left_paren, .token_function => try parser.stack.append(parser.allocator, .{
                .index = undefined,
                .data = .{ .simple_block = .{ .ending_token = mirrorToken(tag) } },
            }),
            .token_right_curly, .token_right_square, .token_right_paren => {
                if (parser.stack.items[parser.stack.items.len - 1].data.simple_block.ending_token == tag) {
                    _ = parser.stack.pop();
                    if (parser.stack.items.len == initial_len) return;
                }
            },
            .token_eof => {
                parser.stack.shrinkRetainingCapacity(initial_len);
                return;
            },
            else => {},
        }
        tag = parser.source.next(location);
    }
}

fn consumeSimpleBlock(parser: *Parser, location: *Source.Location, data: *const Parser.Frame.SimpleBlock) !void {
    while (true) {
        const saved_location = location.*;
        const tag = parser.source.next(location);
        if (tag == data.ending_token) {
            return parser.popComponent();
        } else if (tag == .token_eof) {
            // NOTE: Parse error
            return parser.popComponent();
        } else {
            const must_suspend = try consumeComponentValue(parser, tag, saved_location);
            if (must_suspend) return;
        }
    }
}

fn consumeFunction(parser: *Parser, location: *Source.Location) !void {
    while (true) {
        const saved_location = location.*;
        const tag = parser.source.next(location);
        switch (tag) {
            .token_right_paren => return parser.popComponent(),
            .token_eof => {
                // NOTE: Parse error
                return parser.popComponent();
            },
            else => {
                const must_suspend = try consumeComponentValue(parser, tag, saved_location);
                if (must_suspend) return;
            },
        }
    }
}

/// Given a token that opens a block, return the token that would close the block.
fn mirrorToken(token: Component.Tag) Component.Tag {
    return switch (token) {
        .token_left_square => .token_right_square,
        .token_left_curly => .token_right_curly,
        .token_left_paren, .token_function => .token_right_paren,
        else => unreachable,
    };
}

test "parse a stylesheet" {
    const allocator = std.testing.allocator;
    const input =
        \\@charset "utf-8";
        \\@new-rule {}
        \\
        \\root {
        \\    prop: value;
        \\    prop2: !important
        \\}
        \\
        \\other {}
        \\
        \\broken_rule
    ;
    const token_source = Source.init(try tokenize.Source.init(input));

    var tree = try parseCssStylesheet(token_source, allocator);
    defer tree.deinit(allocator);

    // zig fmt: off
    const expected = [18]Component{
        .{ .next_sibling = 18, .tag = .rule_list,             .location = .{ .value = 0 },  .extra = Extra.make(0)  },
        .{ .next_sibling = 4,  .tag = .at_rule,               .location = .{ .value = 0 },  .extra = Extra.make(0)  },
        .{ .next_sibling = 3,  .tag = .token_whitespace,      .location = .{ .value = 8 },  .extra = Extra.make(0)  },
        .{ .next_sibling = 4,  .tag = .token_string,          .location = .{ .value = 9 },  .extra = Extra.make(0)  },
        .{ .next_sibling = 7,  .tag = .at_rule,               .location = .{ .value = 18 }, .extra = Extra.make(6)  },
        .{ .next_sibling = 6,  .tag = .token_whitespace,      .location = .{ .value = 27 }, .extra = Extra.make(0)  },
        .{ .next_sibling = 7,  .tag = .simple_block_curly,    .location = .{ .value = 28 }, .extra = Extra.make(0)  },
        .{ .next_sibling = 14, .tag = .qualified_rule,        .location = .{ .value = 32 }, .extra = Extra.make(10) },
        .{ .next_sibling = 9,  .tag = .token_ident,           .location = .{ .value = 32 }, .extra = Extra.make(0)  },
        .{ .next_sibling = 10, .tag = .token_whitespace,      .location = .{ .value = 36 }, .extra = Extra.make(0)  },
        .{ .next_sibling = 14, .tag = .style_block,           .location = .{ .value = 37 }, .extra = Extra.make(13) },
        .{ .next_sibling = 13, .tag = .declaration_normal,    .location = .{ .value = 43 }, .extra = Extra.make(0)  },
        .{ .next_sibling = 13, .tag = .token_ident,           .location = .{ .value = 49 }, .extra = Extra.make(0)  },
        .{ .next_sibling = 14, .tag = .declaration_important, .location = .{ .value = 60 }, .extra = Extra.make(11) },
        .{ .next_sibling = 18, .tag = .qualified_rule,        .location = .{ .value = 81 }, .extra = Extra.make(17) },
        .{ .next_sibling = 16, .tag = .token_ident,           .location = .{ .value = 81 }, .extra = Extra.make(0)  },
        .{ .next_sibling = 17, .tag = .token_whitespace,      .location = .{ .value = 86 }, .extra = Extra.make(0)  },
        .{ .next_sibling = 18, .tag = .style_block,           .location = .{ .value = 87 }, .extra = Extra.make(0)  },
    };
    // zig fmt: on

    const slice = tree.slice();
    if (expected.len != slice.len) return error.TestFailure;
    for (expected, 0..) |ex, i| {
        const actual = slice.get(@intCast(i));
        try std.testing.expectEqual(ex, actual);
    }
}
