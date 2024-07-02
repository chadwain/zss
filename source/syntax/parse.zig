const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

const zss = @import("../zss.zig");
const syntax = zss.syntax;
const tokenize = syntax.tokenize;
const Component = syntax.Component;
const ComponentTree = syntax.ComponentTree;
const Extra = Component.Extra;
const Stack = zss.util.Stack;
const Token = tokenize.Token;
const Utf8String = zss.util.Utf8String;

/// A source of `Token`.

// TODO: After parsing, this struct "lingers around" because it is used to get information that isn't stored in `ComponentTree`.
//       A possibly better approach is to store said information into `ComponentTree` (by copying it), eliminating the need for this object.
pub const Source = struct {
    inner: tokenize.Source,

    pub const Location = tokenize.Source.Location;

    pub fn init(string: Utf8String) !Source {
        const inner = try tokenize.Source.init(string);
        return Source{ .inner = inner };
    }

    /// Returns the next component tag, ignoring comments.
    pub fn next(source: Source, location: *Location) !Token {
        var next_location = location.*;
        while (true) {
            const next_token = try tokenize.nextToken(source.inner, next_location);
            if (next_token.token != .token_comments) {
                location.* = next_token.next_location;
                return next_token.token;
            }
            next_location = next_token.next_location;
        }
    }

    /// `start` must be the location of a `.token_ident` component
    pub fn identTokenIterator(source: Source, start: Location) IdentSequenceIterator {
        return .{ .inner = source.inner.identTokenIterator(start) };
    }

    /// `start` must be the location of a `.token_hash_id` component
    pub fn hashIdTokenIterator(source: Source, start: Location) IdentSequenceIterator {
        return .{ .inner = source.inner.hashIdTokenIterator(start) };
    }

    /// `start` must be the location of a `.token_string` component
    pub fn stringTokenIterator(source: Source, start: Location) StringTokenIterator {
        return .{ .inner = source.inner.stringTokenIterator(start) };
    }

    /// `start` must be the location of a `.token_url` component
    /// It CANNOT be the location of a `token_bad_url` component
    pub fn urlTokenIterator(source: Source, start: Location) UrlTokenIterator {
        return UrlTokenIterator{ .inner = source.inner.urlTokenIterator(start) };
    }

    /// Given that `location` is the location of an <ident-token>, check if the identifier is equal to `ascii_string`
    /// using case-insensitive matching.
    pub fn identifierEqlIgnoreCase(source: Source, location: Location, ascii_string: []const u8) bool {
        const toLowercase = zss.util.unicode.toLowercase;
        var it = identTokenIterator(source, location);
        for (ascii_string) |string_codepoint| {
            assert(string_codepoint <= 0x7F);
            const it_codepoint = it.next(source) orelse return false;
            if (toLowercase(string_codepoint) != toLowercase(it_codepoint)) return false;
        }
        return it.next(source) == null;
    }

    /// Given that `location` is the location of a <string-token>, copy that string
    pub fn copyString(source: Source, location: Location, allocator: Allocator) !Utf8String {
        var iterator = stringTokenIterator(source, location);
        return copyTokenGeneric(source, &iterator, allocator);
    }

    /// Given that `location` is the location of a <url-token>, copy that URL
    pub fn copyUrl(source: Source, location: Location, allocator: Allocator) !Utf8String {
        var iterator = urlTokenIterator(source, location);
        return copyTokenGeneric(source, &iterator, allocator);
    }

    fn copyTokenGeneric(source: Source, iterator: anytype, allocator: Allocator) !Utf8String {
        var list = std.ArrayListUnmanaged(u8){};
        defer list.deinit(allocator);

        var buffer: [4]u8 = undefined;
        while (iterator.next(source)) |codepoint| {
            // TODO: Get a UTF-8 encoded buffer directly from the tokenizer
            const len = std.unicode.utf8Encode(codepoint, &buffer) catch unreachable;
            try list.appendSlice(allocator, buffer[0..len]);
        }

        const bytes = try list.toOwnedSlice(allocator);
        return Utf8String{ .data = bytes };
    }

    pub fn KV(comptime Type: type) type {
        return struct {
            /// This must be an ASCII string.
            []const u8,
            Type,
        };
    }

    /// Given that `location` is the location of an <ident-token>, map the identifier at that location
    /// to the value given in `kvs`, using case-insensitive matching. If there was no match, null is returned.
    pub fn mapIdentifier(source: Source, location: Location, comptime Type: type, kvs: []const KV(Type)) ?Type {
        // TODO: Use a hash map/trie or something
        for (kvs) |kv| {
            if (identifierEqlIgnoreCase(source, location, kv[0])) return kv[1];
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

pub const StringTokenIterator = struct {
    inner: tokenize.StringTokenIterator,

    pub fn next(it: *StringTokenIterator, source: Source) ?u21 {
        return it.inner.next(source.inner);
    }
};

pub const UrlTokenIterator = struct {
    inner: tokenize.UrlTokenIterator,

    pub fn next(it: *UrlTokenIterator, source: Source) ?u21 {
        return it.inner.next(source.inner);
    }
};

/// Creates a ComponentTree with a root node with tag `rule_list`
/// Implements CSS Syntax Level 3 Section 9 "Parse a CSS stylesheet"
pub fn parseCssStylesheet(source: Source, allocator: Allocator) !ComponentTree {
    var parser: Parser = .{ .source = source, .allocator = allocator };
    defer parser.deinit();

    var location: Source.Location = .start;
    try parser.initListOfRules(location, true);
    try loop(&parser, &location);

    return parser.finish();
}

/// Creates a ComponentTree with a root node with tag `component_list`
/// Implements CSS Syntax Level 3 Section 5.3.10 "Parse a list of component values"
pub fn parseListOfComponentValues(source: Source, allocator: Allocator) !ComponentTree {
    var parser: Parser = .{ .source = source, .allocator = allocator };
    defer parser.deinit();

    var location: Source.Location = .start;
    try parser.initListOfComponentValues(location);
    try loop(&parser, &location);

    return parser.finish();
}

const Parser = struct {
    stack: Stack(Frame) = .{},
    tree: ComponentTree = .{},
    source: Source,
    allocator: Allocator,

    const Frame = struct {
        index: ComponentTree.Size,
        data: Data,

        const Data = union(enum) {
            list_of_rules: ListOfRules,
            list_of_component_values,
            style_block: StyleBlock,
            declaration_value: DeclarationValue,
            qualified_rule: QualifiedRule,
            at_rule: AtRule,
            simple_block: SimpleBlock,
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

    fn deinit(parser: *Parser) void {
        parser.stack.deinit(parser.allocator);
        parser.tree.deinit(parser.allocator);
    }

    fn initListOfRules(parser: *Parser, location: Source.Location, top_level: bool) !void {
        const index = try parser.newComponent(.{
            .next_sibling = undefined,
            .tag = .rule_list,
            .location = location,
            .extra = Extra.make(0),
        });
        parser.stack.top = .{
            .index = index,
            .data = .{ .list_of_rules = .{ .top_level = top_level } },
        };
    }

    fn initListOfComponentValues(parser: *Parser, location: Source.Location) !void {
        const index = try parser.newComponent(.{
            .next_sibling = undefined,
            .tag = .component_list,
            .location = location,
            .extra = Extra.make(0),
        });
        parser.stack.top = .{ .index = index, .data = .list_of_component_values };
    }

    fn finish(parser: *Parser) ComponentTree {
        const tree = parser.tree;
        parser.tree = .{};
        return tree;
    }

    /// Returns the index of the new component
    fn newComponent(parser: *Parser, component: Component) !ComponentTree.Size {
        if (parser.tree.components.len == std.math.maxInt(ComponentTree.Size)) return error.Overflow;
        const index = @as(ComponentTree.Size, @intCast(parser.tree.components.len));
        try parser.tree.components.append(parser.allocator, component);
        return index;
    }

    fn pushFrame(parser: *Parser, frame: Frame) !void {
        try parser.stack.push(parser.allocator, frame);
        // This error forces the current stack frame being evaluated to stop executing.
        // This error will then be caught in the `loop` function.
        return error.ControlFlowSuspend;
    }

    /// Appends any object that can be represented with a single component
    fn appendComponentValue(parser: *Parser, tag: Component.Tag, location: Source.Location, extra: Component.Extra) !void {
        const index = @as(ComponentTree.Size, @intCast(parser.tree.components.len));
        _ = try parser.newComponent(.{
            .next_sibling = index + 1,
            .tag = tag,
            .location = location,
            .extra = extra,
        });
    }

    fn appendDimension(parser: *Parser, location: Source.Location, dimension: Token.Dimension) !void {
        // TODO: Using two components for a dimension is overkill. Find a way to make it just one.
        const index = @as(ComponentTree.Size, @intCast(parser.tree.components.len));
        _ = try parser.newComponent(.{
            .next_sibling = index + 2,
            .tag = .token_dimension,
            .location = location,
            .extra = Extra.make(@bitCast(dimension.number)),
        });
        _ = try parser.newComponent(.{
            .next_sibling = index + 2,
            .tag = .token_unit,
            .location = dimension.unit_location,
            .extra = Extra.make(@intFromEnum(dimension.unit)),
        });
    }

    /// `location` must be the location of a <function-token>.
    fn pushFunction(parser: *Parser, location: Source.Location) !void {
        const index = try parser.newComponent(.{
            .next_sibling = undefined,
            .tag = .function,
            .location = location,
            .extra = Extra.make(0),
        });
        try parser.pushFrame(.{
            .index = index,
            .data = .{ .simple_block = .{ .ending_token = .token_right_paren } },
        });
    }

    /// `location` must be the location of a <{-token>, <[-token>, or <(-token>.
    fn pushSimpleBlock(parser: *Parser, tag: Component.Tag, location: Source.Location) !void {
        const component_tag: Component.Tag = switch (tag) {
            .token_left_curly => .simple_block_curly,
            .token_left_square => .simple_block_square,
            .token_left_paren => .simple_block_paren,
            else => unreachable,
        };
        const index = try parser.newComponent(.{
            .next_sibling = undefined,
            .tag = component_tag,
            .location = location,
            .extra = Extra.make(0),
        });
        try parser.pushFrame(.{
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
        const index = try parser.newComponent(.{
            .next_sibling = undefined,
            .tag = .at_rule,
            .location = location,
            .extra = undefined,
        });
        try parser.pushFrame(.{ .index = index, .data = .{ .at_rule = .{} } });
    }

    fn popAtRule(parser: *Parser) void {
        const frame = parser.stack.pop();
        parser.tree.components.items(.next_sibling)[frame.index] = @intCast(parser.tree.components.len);
        parser.tree.components.items(.extra)[frame.index] = Extra.make(frame.data.at_rule.index_of_block orelse 0);
    }

    /// `location` must be the location of the first token of the qualified rule.
    /// To finish this component, use either `popQualifiedRule` or `discardQualifiedRule`.
    fn pushQualifiedRule(parser: *Parser, location: Source.Location, is_style_rule: bool) !void {
        const index = try parser.newComponent(.{
            .next_sibling = undefined,
            .tag = .qualified_rule,
            .location = location,
            .extra = undefined,
        });
        try parser.pushFrame(.{ .index = index, .data = .{ .qualified_rule = .{ .is_style_rule = is_style_rule } } });
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
        const index = try parser.newComponent(.{
            .next_sibling = undefined,
            .tag = .style_block,
            .location = location,
            .extra = undefined,
        });
        try parser.pushFrame(.{ .index = index, .data = .{ .style_block = .{} } });
    }

    fn popStyleBlock(parser: *Parser) void {
        const frame = parser.stack.pop();
        parser.tree.components.items(.next_sibling)[frame.index] = @intCast(parser.tree.components.len);
        parser.tree.components.items(.extra)[frame.index] = Extra.make(frame.data.style_block.index_of_last_declaration);
    }

    /// To finish this component, use `popDeclarationValue`.
    fn pushDeclarationValue(
        parser: *Parser,
        location: Source.Location,
        style_block: *Frame.StyleBlock,
        previous_declaration: ComponentTree.Size,
    ) !void {
        const index = try parser.newComponent(.{
            .next_sibling = undefined,
            .tag = undefined,
            .location = location,
            .extra = Extra.make(previous_declaration),
        });
        style_block.index_of_last_declaration = index;
        try parser.pushFrame(.{ .index = index, .data = .{ .declaration_value = .{} } });
    }

    fn popDeclarationValue(parser: *Parser) void {
        const frame = parser.stack.pop();
        const slice = parser.tree.slice();
        var data = frame.data.declaration_value;

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

fn nextSimpleBlockToken(parser: *Parser, location: *Source.Location, ending_token: Component.Tag) !?Token {
    const tag = try parser.source.next(location);
    if (tag == ending_token) {
        return null;
    } else if (tag == .token_eof) {
        // NOTE: Parse error
        return null;
    } else {
        return tag;
    }
}

fn loop(parser: *Parser, location: *Source.Location) !void {
    while (parser.stack.top) |*frame| {
        // zig fmt: off
        const result = switch (frame.data) {
            // NOTE: `parser` and `&frame.data` alias
            .list_of_rules            =>     |*list_of_rules| consumeListOfRules(parser, location, list_of_rules),
            .list_of_component_values =>                      consumeListOfComponentValues(parser, location),
            .qualified_rule           =>    |*qualified_rule| consumeQualifiedRule(parser, location, qualified_rule),
            .at_rule                  =>           |*at_rule| consumeAtRule(parser, location, at_rule),
            .style_block              =>       |*style_block| consumeStyleBlockContents(parser, location, style_block),
            .declaration_value        => |*declaration_value| consumeDeclarationValue(parser, location, declaration_value),
            .simple_block             =>      |*simple_block| consumeSimpleBlock(parser, location, simple_block),
        };
        // zig fmt: on
        result catch |err| switch (err) {
            error.ControlFlowSuspend => {},
            else => |e| return e,
        };
    }
}

fn consumeListOfRules(parser: *Parser, location: *Source.Location, data: *const Parser.Frame.ListOfRules) !void {
    while (true) {
        const saved_location = location.*;
        const tag = try parser.source.next(location);
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
                return parser.pushAtRule(saved_location);
            },
            else => {
                location.* = saved_location;
                return parser.pushQualifiedRule(saved_location, data.top_level);
            },
        }
    }
}

fn consumeListOfComponentValues(parser: *Parser, location: *Source.Location) !void {
    while (true) {
        const saved_location = location.*;
        const tag = try parser.source.next(location);
        switch (tag) {
            .token_eof => return parser.popComponent(),
            else => try consumeComponentValue(parser, tag, saved_location),
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
        const tag = try parser.source.next(location);
        switch (tag) {
            .token_semicolon => return parser.popAtRule(),
            .token_eof => {
                // NOTE: Parse error
                return parser.popAtRule();
            },
            .token_left_curly => {
                data.index_of_block = @intCast(parser.tree.components.len);
                return parser.pushSimpleBlock(tag, saved_location);
            },
            else => try consumeComponentValue(parser, tag, saved_location),
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
        const tag = try parser.source.next(location);
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
            },
            else => try consumeComponentValue(parser, tag, saved_location),
        }
    }
}

fn consumeStyleBlockContents(parser: *Parser, location: *Source.Location, data: *Parser.Frame.StyleBlock) !void {
    while (true) {
        const saved_location = location.*;
        const tag = (try nextSimpleBlockToken(parser, location, .token_right_curly)) orelse {
            parser.popStyleBlock();
            return;
        };
        switch (tag) {
            .token_whitespace, .token_semicolon => {},
            .token_at_keyword => {
                try parser.pushAtRule(saved_location);
            },
            .token_ident => try consumeDeclarationStart(parser, location, data, saved_location, data.index_of_last_declaration),
            else => {
                if (tag == .token_delim and tag.token_delim == '&') {
                    location.* = saved_location;
                    try parser.pushQualifiedRule(saved_location, false);
                } else {
                    // NOTE: Parse error
                    location.* = saved_location;
                    try seekToEndOfDeclaration(parser, location);
                }
            },
        }
    }
}

fn seekToEndOfDeclaration(parser: *Parser, location: *Source.Location) !void {
    while (true) {
        const saved_location = location.*;
        const tag = try parser.source.next(location);
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

/// If a declaration's start can be successfully parsed, this pushes a new frame onto the parser's stack.
fn consumeDeclarationStart(
    parser: *Parser,
    location: *Source.Location,
    style_block: *Parser.Frame.StyleBlock,
    name_location: Source.Location,
    previous_declaration: ComponentTree.Size,
) !void {
    while (true) {
        const saved_location = location.*;
        const tag = try parser.source.next(location);
        switch (tag) {
            .token_whitespace => {},
            .token_colon => break,
            else => {
                // NOTE: Parse error
                location.* = saved_location;
                return;
            },
        }
    }

    while (true) {
        const saved_location = location.*;
        const tag = try parser.source.next(location);
        switch (tag) {
            .token_whitespace => {},
            else => {
                location.* = saved_location;
                try parser.pushDeclarationValue(name_location, style_block, previous_declaration);
            },
        }
    }
}

fn consumeDeclarationValue(parser: *Parser, location: *Source.Location, data: *Parser.Frame.DeclarationValue) !void {
    while (true) {
        const saved_location = location.*;
        const tag = try parser.source.next(location);
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
                try parser.appendComponentValue(tag, saved_location, Extra.make(0));
            },
            else => {
                data.index_of_last_three_non_whitespace_components[0] = data.index_of_last_three_non_whitespace_components[1];
                data.index_of_last_three_non_whitespace_components[1] = data.index_of_last_three_non_whitespace_components[2];
                data.index_of_last_three_non_whitespace_components[2] = @intCast(parser.tree.components.len);
                data.num_non_whitespace_components +|= 1;

                try consumeComponentValue(parser, tag, saved_location);
            },
        }
    }
}

fn consumeComponentValue(parser: *Parser, tag: Token, location: Source.Location) !void {
    // zig fmt: off
    switch (tag) {
        .token_left_curly,
        .token_left_square,
        .token_left_paren,
        =>                               try parser.pushSimpleBlock(tag, location),
        .token_function   =>             try parser.pushFunction(location),
        .token_delim      => |codepoint| try parser.appendComponentValue(.token_delim, location, Extra.make(codepoint)),
        .token_integer    =>   |integer| try parser.appendComponentValue(.token_integer, location, Extra.make(@bitCast(integer))),
        .token_number     =>    |number| try parser.appendComponentValue(.token_number, location, Extra.make(@bitCast(number))),
        .token_percentage =>    |number| try parser.appendComponentValue(.token_percentage, location, Extra.make(@bitCast(number))),
        .token_dimension  => |dimension| try parser.appendDimension(location, dimension),
        else              =>             try parser.appendComponentValue(tag, location, Extra.make(0)),
    }
    // zig fmt: on
}

fn ignoreComponentValue(parser: *Parser, first_tag: Component.Tag, location: *Source.Location) !void {
    switch (first_tag) {
        .token_left_curly, .token_left_square, .token_left_paren, .token_function => {},
        else => return,
    }

    const allocator = parser.allocator;
    var block_stack = ArrayListUnmanaged(Component.Tag){};
    defer block_stack.deinit(allocator);

    var tag = first_tag;
    while (true) : (tag = try parser.source.next(location)) {
        switch (tag) {
            .token_left_curly, .token_left_square, .token_left_paren, .token_function => {
                try block_stack.append(allocator, mirrorToken(tag));
            },
            .token_right_curly, .token_right_square, .token_right_paren => {
                if (block_stack.items[block_stack.items.len - 1] == tag) {
                    _ = block_stack.pop();
                    if (block_stack.items.len == 0) return;
                }
            },
            .token_eof => return,
            else => {},
        }
    }
}

fn consumeSimpleBlock(parser: *Parser, location: *Source.Location, data: *const Parser.Frame.SimpleBlock) !void {
    while (true) {
        const saved_location = location.*;
        const tag = (try nextSimpleBlockToken(parser, location, data.ending_token)) orelse {
            return parser.popComponent();
        };
        try consumeComponentValue(parser, tag, saved_location);
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
        \\    prop2: func(abc) !important
        \\}
        \\
        \\other {}
        \\
        \\broken_rule
    ;
    const token_source = try Source.init(Utf8String{ .data = input });

    var tree = try parseCssStylesheet(token_source, allocator);
    defer tree.deinit(allocator);

    // zig fmt: off
    const expected = [20]Component{
        .{ .next_sibling = 20, .tag = .rule_list,             .location = @enumFromInt(0),  .extra = Extra.make(0)  },
        .{ .next_sibling = 4,  .tag = .at_rule,               .location = @enumFromInt(0),  .extra = Extra.make(0)  },
        .{ .next_sibling = 3,  .tag = .token_whitespace,      .location = @enumFromInt(8),  .extra = Extra.make(0)  },
        .{ .next_sibling = 4,  .tag = .token_string,          .location = @enumFromInt(9),  .extra = Extra.make(0)  },
        .{ .next_sibling = 7,  .tag = .at_rule,               .location = @enumFromInt(18), .extra = Extra.make(6)  },
        .{ .next_sibling = 6,  .tag = .token_whitespace,      .location = @enumFromInt(27), .extra = Extra.make(0)  },
        .{ .next_sibling = 7,  .tag = .simple_block_curly,    .location = @enumFromInt(28), .extra = Extra.make(0)  },
        .{ .next_sibling = 16, .tag = .qualified_rule,        .location = @enumFromInt(32), .extra = Extra.make(10) },
        .{ .next_sibling = 9,  .tag = .token_ident,           .location = @enumFromInt(32), .extra = Extra.make(0)  },
        .{ .next_sibling = 10, .tag = .token_whitespace,      .location = @enumFromInt(36), .extra = Extra.make(0)  },
        .{ .next_sibling = 16, .tag = .style_block,           .location = @enumFromInt(37), .extra = Extra.make(13) },
        .{ .next_sibling = 13, .tag = .declaration_normal,    .location = @enumFromInt(43), .extra = Extra.make(0)  },
        .{ .next_sibling = 13, .tag = .token_ident,           .location = @enumFromInt(49), .extra = Extra.make(0)  },
        .{ .next_sibling = 16, .tag = .declaration_important, .location = @enumFromInt(60), .extra = Extra.make(11) },
        .{ .next_sibling = 16, .tag = .function,              .location = @enumFromInt(67), .extra = Extra.make(0)  },
        .{ .next_sibling = 16, .tag = .token_ident,           .location = @enumFromInt(72), .extra = Extra.make(0)  },
        .{ .next_sibling = 20, .tag = .qualified_rule,        .location = @enumFromInt(91), .extra = Extra.make(19) },
        .{ .next_sibling = 18, .tag = .token_ident,           .location = @enumFromInt(91), .extra = Extra.make(0)  },
        .{ .next_sibling = 19, .tag = .token_whitespace,      .location = @enumFromInt(96), .extra = Extra.make(0)  },
        .{ .next_sibling = 20, .tag = .style_block,           .location = @enumFromInt(97), .extra = Extra.make(0)  },
    };
    // zig fmt: on

    const slice = tree.slice();
    if (expected.len != slice.len) return error.TestFailure;
    for (expected, 0..) |ex, i| {
        const actual = slice.get(@intCast(i));
        try std.testing.expectEqual(ex, actual);
    }
}
