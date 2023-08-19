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

    pub fn identTokenIterator(source: Source, start: Location) IdentSequenceIterator {
        return .{ .inner = source.inner.identTokenIterator(start) };
    }

    pub fn hashIdTokenIterator(source: Source, start: Location) IdentSequenceIterator {
        return .{ .inner = source.inner.hashIdTokenIterator(start) };
    }

    pub fn matchKeyword(source: Source, location: Location, keyword: []const u21) bool {
        var it = source.inner.identTokenIterator(location);
        for (keyword) |kw_codepoint| {
            const it_codepoint = it.next(source.inner) orelse return false;
            if (toLowercase(kw_codepoint) != toLowercase(it_codepoint)) return false;
        }
        return it.next(source.inner) == null;
    }

    pub fn identTokensEqlIgnoreCase(source: Source, ident1: Location, ident2: Location) bool {
        if (ident1.value == ident2.value) return true;
        var it1 = source.inner.identTokenIterator(ident1);
        var it2 = source.inner.identTokenIterator(ident2);
        while (it1.next(source.inner)) |codepoint1| {
            const codepoint2 = it2.next(source.inner) orelse return false;
            if (toLowercase(codepoint1) != toLowercase(codepoint2)) return false;
        } else {
            return (it2.next(source.inner) == null);
        }
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
            style_block,
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
            index_of_last_three_non_whitespace_components: [3]ComponentTree.Size = undefined,
            num_non_whitespace_components: u2 = 0,
        };

        const SimpleBlock = struct {
            tag: Component.Tag,

            fn endingTokenTag(simple_block: SimpleBlock) Component.Tag {
                return switch (simple_block.tag) {
                    .simple_block_curly => .token_right_curly,
                    .simple_block_bracket => .token_right_bracket,
                    .simple_block_paren => .token_right_paren,
                    else => unreachable,
                };
            }
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
        const index = @intCast(ComponentTree.Size, parser.tree.components.len);
        try parser.tree.components.append(parser.allocator, component);
        return index;
    }

    /// Creates a Component that has no children.
    fn addComponent(parser: *Parser, tag: Component.Tag, location: Source.Location, extra: Component.Extra) !void {
        const index = @intCast(ComponentTree.Size, parser.tree.components.len);
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

    /// `location` must be the location of the first token of the at-rule (i.e. the <at-keyword-token>).
    fn pushAtRule(parser: *Parser, location: Source.Location) !void {
        const index = try parser.allocateComponent(.{
            .next_sibling = undefined,
            .tag = .at_rule,
            .location = location,
            .extra = undefined,
        });
        try parser.stack.append(parser.allocator, .{ .index = index, .data = .{ .at_rule = .{} } });
    }

    /// `location` must be the location of the first token of the qualified rule.
    fn pushQualifiedRule(parser: *Parser, location: Source.Location, is_style_rule: bool) !void {
        const index = try parser.allocateComponent(.{
            .next_sibling = undefined,
            .tag = .qualified_rule,
            .location = location,
            .extra = undefined,
        });
        try parser.stack.append(parser.allocator, .{ .index = index, .data = .{ .qualified_rule = .{ .is_style_rule = is_style_rule } } });
    }

    fn pushStyleBlock(parser: *Parser, location: Source.Location) !void {
        const index = try parser.allocateComponent(.{
            .next_sibling = undefined,
            .tag = .style_block,
            .location = location,
            .extra = Extra.make(0),
        });
        try parser.stack.append(parser.allocator, .{ .index = index, .data = .style_block });
    }

    fn pushDeclarationValue(parser: *Parser, location: Source.Location) !void {
        const index = try parser.allocateComponent(.{
            .next_sibling = undefined,
            .tag = .declaration,
            .location = location,
            .extra = undefined,
        });
        try parser.stack.append(parser.allocator, .{ .index = index, .data = .{ .declaration_value = .{} } });
    }

    fn pushFunction(parser: *Parser, location: Source.Location) !void {
        const index = try parser.allocateComponent(.{
            .next_sibling = undefined,
            .tag = .function,
            .location = location,
            .extra = Extra.make(0),
        });
        try parser.stack.append(parser.allocator, .{ .index = index, .data = .function });
    }

    // fn addSimpleBlock(parser: *Parser, tag: Component.Tag, location: Source.Location) !void {
    //     const component_tag: Component.Tag = switch (tag) {
    //         .simple_block_curly, .simple_block_bracket, .simple_block_paren => {},
    //         else => unreachable,
    //     };
    //     _ = try allocateComponent(tree, allocator, .{
    //         .next_sibling = undefined,
    //         .tag = component_tag,
    //         .location = location,
    //         .extra = Extra.make(0),
    //     });
    //     parser.stack.items[parser.stack.items.len - 1].skip += 1;
    // }

    fn pushSimpleBlock(parser: *Parser, tag: Component.Tag, location: Source.Location) !void {
        const component_tag: Component.Tag = switch (tag) {
            .token_left_curly => .simple_block_curly,
            .token_left_bracket => .simple_block_bracket,
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
            .data = .{ .simple_block = .{ .tag = component_tag } },
        });
    }

    fn popFrame(parser: *Parser) void {
        const frame = parser.stack.pop();
        switch (frame.data) {
            .qualified_rule => unreachable, // use popQualifiedRule instead
            .at_rule => unreachable, // use popAtRule instead
            .declaration_value => unreachable, // use popDeclarationValue instead
            else => {},
        }
        parser.tree.components.items(.next_sibling)[frame.index] = @intCast(ComponentTree.Size, parser.tree.components.len);
    }

    fn popQualifiedRule(parser: *Parser) void {
        const frame = parser.stack.pop();
        parser.tree.components.items(.next_sibling)[frame.index] = @intCast(ComponentTree.Size, parser.tree.components.len);
        parser.tree.components.items(.extra)[frame.index] = Extra.make(frame.data.qualified_rule.index_of_block.?);
    }

    fn popAtRule(parser: *Parser) void {
        const frame = parser.stack.pop();
        parser.tree.components.items(.next_sibling)[frame.index] = @intCast(ComponentTree.Size, parser.tree.components.len);
        parser.tree.components.items(.extra)[frame.index] = Extra.make(frame.data.at_rule.index_of_block orelse 0);
    }

    fn popDeclarationValue(parser: *Parser) void {
        const frame = parser.stack.pop();
        var data = frame.data.declaration_value;
        const slice = parser.tree.components.slice();

        const toUnicode = zss.util.ascii8ToUnicode;
        const is_important = data.num_non_whitespace_components >= 2 and
            slice.items(.tag)[data.index_of_last_three_non_whitespace_components[1]] == .token_delim and
            slice.items(.extra)[data.index_of_last_three_non_whitespace_components[1]].codepoint() == '!' and
            slice.items(.tag)[data.index_of_last_three_non_whitespace_components[2]] == .token_ident and
            parser.source.matchKeyword(slice.items(.location)[data.index_of_last_three_non_whitespace_components[2]], toUnicode("important"));
        if (is_important) {
            slice.items(.extra)[frame.index] = Extra.make(1);
            data.index_of_last_three_non_whitespace_components[2] = data.index_of_last_three_non_whitespace_components[0];
            data.num_non_whitespace_components -= 2;
        } else {
            slice.items(.extra)[frame.index] = Extra.make(0);
        }

        const next_sibling = if (data.num_non_whitespace_components > 0) blk: {
            const last_component = data.index_of_last_three_non_whitespace_components[2];
            const next_sibling = slice.items(.next_sibling)[last_component];
            break :blk next_sibling;
        } else frame.index + 1;
        slice.items(.next_sibling)[frame.index] = next_sibling;

        parser.tree.components.shrinkRetainingCapacity(next_sibling);
    }

    fn ignoreQualifiedRule(parser: *Parser) void {
        const frame = parser.stack.pop();
        assert(frame.data == .qualified_rule);
        parser.tree.components.shrinkRetainingCapacity(frame.index);
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
            .style_block => try consumeStyleBlockContents(parser, location),
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
            .token_eof => return parser.popFrame(),
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
            .token_eof => return parser.popFrame(),
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
                data.index_of_block = @intCast(ComponentTree.Size, parser.tree.components.len);
                try parser.pushSimpleBlock(tag, saved_location);
                return;
            },
            .simple_block_curly => {
                // try parser.addSimpleBlock(tag, saved_location);
                // parser.popFrame();
                // return;

                // NOTE: At the time of writing, this line is unreachable.
                panic("Found a simple block while parsing", .{});
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
                return parser.ignoreQualifiedRule();
            },
            .token_left_curly => {
                data.index_of_block = @intCast(ComponentTree.Size, parser.tree.components.len);
                switch (data.is_style_rule) {
                    false => try parser.pushSimpleBlock(tag, saved_location),
                    true => try parser.pushStyleBlock(saved_location),
                }
                return;
            },
            .simple_block_curly => {
                // try parser.addSimpleBlock(tag, saved_location);
                // parser.popFrame();
                // return;

                // NOTE: At the time of writing, this line is unreachable.
                panic("Found a simple block while parsing", .{});
            },
            else => {
                const must_suspend = try consumeComponentValue(parser, tag, saved_location);
                if (must_suspend) return;
            },
        }
    }
}

fn consumeStyleBlockContents(parser: *Parser, location: *Source.Location) !void {
    while (true) {
        const saved_location = location.*;
        const tag = parser.source.next(location);
        switch (tag) {
            .token_whitespace, .token_semicolon => {},
            .token_right_curly, .token_eof => {
                parser.popFrame();
                return;
            },
            .token_at_keyword => {
                try parser.pushAtRule(saved_location);
                return;
            },
            .token_ident => {
                const must_suspend = try consumeDeclaration(parser, location, saved_location);
                if (must_suspend) return;
            },
            else => {
                if (tag == .token_delim and parser.source.getDelimeter(saved_location) == '&') {
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
    const BlockType = enum { curly, bracket, paren };
    var open_blocks = ArrayListUnmanaged(BlockType){};
    defer open_blocks.deinit(parser.allocator);

    while (true) {
        const saved_location = location.*;
        const tag = parser.source.next(location);
        switch (tag) {
            .token_eof => break,
            .token_semicolon => {
                if (open_blocks.items.len == 0) break;
            },
            .token_function, .token_left_paren => try open_blocks.append(parser.allocator, .paren),
            .token_left_bracket => try open_blocks.append(parser.allocator, .bracket),
            .token_left_curly => try open_blocks.append(parser.allocator, .curly),
            .token_right_bracket => {
                if (open_blocks.items.len > 0 and open_blocks.items[open_blocks.items.len - 1] == .bracket) _ = open_blocks.pop();
            },
            .token_right_curly => {
                if (open_blocks.items.len == 0) {
                    location.* = saved_location;
                    break;
                } else if (open_blocks.items[open_blocks.items.len - 1] == .curly) {
                    _ = open_blocks.pop();
                }
            },
            .token_right_paren => {
                if (open_blocks.items.len > 0 and open_blocks.items[open_blocks.items.len - 1] == .paren) _ = open_blocks.pop();
            },
            else => {},
        }
    }
}

fn consumeDeclaration(parser: *Parser, location: *Source.Location, name_location: Source.Location) !bool {
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
                try parser.pushDeclarationValue(name_location);
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
                try parser.addComponent(tag, saved_location, Extra.make(0));
            },
            else => {
                data.index_of_last_three_non_whitespace_components[0] = data.index_of_last_three_non_whitespace_components[1];
                data.index_of_last_three_non_whitespace_components[1] = data.index_of_last_three_non_whitespace_components[2];
                data.index_of_last_three_non_whitespace_components[2] = @intCast(ComponentTree.Size, parser.tree.components.len);
                data.num_non_whitespace_components +|= 1;

                const must_suspend = try consumeComponentValue(parser, tag, saved_location);
                if (must_suspend) return;
            },
        }
    }
}

fn consumeComponentValue(parser: *Parser, tag: Component.Tag, location: Source.Location) !bool {
    switch (tag) {
        .token_left_curly, .token_left_bracket, .token_left_paren => {
            try parser.pushSimpleBlock(tag, location);
            return true;
        },
        .token_function => {
            try parser.pushFunction(location);
            return true;
        },
        .token_delim => {
            const codepoint = parser.source.getDelimeter(location);
            try parser.addComponent(.token_delim, location, Extra.make(codepoint));
            return false;
        },
        else => {
            try parser.addComponent(tag, location, Extra.make(0));
            return false;
        },
    }
}

fn consumeSimpleBlock(parser: *Parser, location: *Source.Location, data: *const Parser.Frame.SimpleBlock) !void {
    const ending_tag = data.endingTokenTag();
    while (true) {
        const saved_location = location.*;
        const tag = parser.source.next(location);
        if (tag == ending_tag) {
            return parser.popFrame();
        } else if (tag == .token_eof) {
            // NOTE: Parse error
            return parser.popFrame();
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
            .token_right_paren => return parser.popFrame(),
            .token_eof => {
                // NOTE: Parse error
                return parser.popFrame();
            },
            else => {
                const must_suspend = try consumeComponentValue(parser, tag, saved_location);
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
        .{ .next_sibling = 18, .tag = .rule_list,          .location = .{ .value = 0 },  .extra = Extra.make(0)  },
        .{ .next_sibling = 4,  .tag = .at_rule,            .location = .{ .value = 0 },  .extra = Extra.make(0)  },
        .{ .next_sibling = 3,  .tag = .token_whitespace,   .location = .{ .value = 8 },  .extra = Extra.make(0)  },
        .{ .next_sibling = 4,  .tag = .token_string,       .location = .{ .value = 9 },  .extra = Extra.make(0)  },
        .{ .next_sibling = 7,  .tag = .at_rule,            .location = .{ .value = 18 }, .extra = Extra.make(6)  },
        .{ .next_sibling = 6,  .tag = .token_whitespace,   .location = .{ .value = 27 }, .extra = Extra.make(0)  },
        .{ .next_sibling = 7,  .tag = .simple_block_curly, .location = .{ .value = 28 }, .extra = Extra.make(0)  },
        .{ .next_sibling = 14, .tag = .qualified_rule,     .location = .{ .value = 32 }, .extra = Extra.make(10) },
        .{ .next_sibling = 9,  .tag = .token_ident,        .location = .{ .value = 32 }, .extra = Extra.make(0)  },
        .{ .next_sibling = 10, .tag = .token_whitespace,   .location = .{ .value = 36 }, .extra = Extra.make(0)  },
        .{ .next_sibling = 14, .tag = .style_block,        .location = .{ .value = 37 }, .extra = Extra.make(0)  },
        .{ .next_sibling = 13, .tag = .declaration,        .location = .{ .value = 43 }, .extra = Extra.make(0)  },
        .{ .next_sibling = 13, .tag = .token_ident,        .location = .{ .value = 49 }, .extra = Extra.make(0)  },
        .{ .next_sibling = 14, .tag = .declaration,        .location = .{ .value = 60 }, .extra = Extra.make(1)  },
        .{ .next_sibling = 18, .tag = .qualified_rule,     .location = .{ .value = 81 }, .extra = Extra.make(17) },
        .{ .next_sibling = 16, .tag = .token_ident,        .location = .{ .value = 81 }, .extra = Extra.make(0)  },
        .{ .next_sibling = 17, .tag = .token_whitespace,   .location = .{ .value = 86 }, .extra = Extra.make(0)  },
        .{ .next_sibling = 18, .tag = .style_block,        .location = .{ .value = 87 }, .extra = Extra.make(0)  },
    };
    // zig fmt: on

    const slice = tree.components.slice();
    if (expected.len != slice.len) return error.TestFailure;
    for (expected, 0..) |ex, i| {
        const actual = slice.get(i);
        try std.testing.expectEqual(ex, actual);
    }
}
