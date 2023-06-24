const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const MultiArrayList = std.MultiArrayList;

pub const tokenize = @import("./tokenize.zig");
pub const parse = @import("./parse.zig");

comptime {
    if (@import("builtin").is_test) {
        _ = tokenize;
        _ = parse;
    }
}

pub const Component = struct {
    skip: ComponentTree.Size,
    tag: Tag,
    /// The location of this Component in whatever source created it.
    location: parse.Source.Location,
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

        // The "juxtaposition" combinator
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
