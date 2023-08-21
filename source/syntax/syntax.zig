const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const MultiArrayList = std.MultiArrayList;

pub const tokenize = @import("./tokenize.zig");
pub const parse = @import("./parse.zig");
pub const IdentifierSet = @import("./IdentifierSet.zig");

comptime {
    if (@import("builtin").is_test) {
        _ = tokenize;
        _ = parse;
    }
}

/// Corresponds to what CSS calls a "component value".
pub const Component = struct {
    next_sibling: ComponentTree.Size,
    tag: Tag,
    /// The location of this Component in whatever Source created it. The meaning of this value depends on `tag`.
    location: parse.Source.Location,
    /// Additional info about the Component. The meaning of this value depends on `tag`.
    extra: Extra,

    pub const Extra = extern struct {
        /// Trying to read/write this field directly should not be attempted.
        /// Better to use one of the member functions instead.
        _: u32,

        pub fn make(int: u32) Extra {
            return @bitCast(int);
        }

        pub fn index(extra: Extra) ComponentTree.Size {
            return @bitCast(extra);
        }

        pub fn codepoint(extra: Extra) u21 {
            return @intCast(@as(u32, @bitCast(extra)));
        }

        pub fn important(extra: Extra) bool {
            return @as(u32, @bitCast(extra)) != 0;
        }
    };

    pub const Tag = enum {
        /// The end of a sequence of tokens
        /// location: The end of the stylesheet
        token_eof,
        /// A sequence of one or more comment blocks
        /// location: The opening '/' of the first comment block
        token_comments,

        /// An identifier
        /// location: The first codepoint of the identifier
        token_ident,
        /// An identifier + a '(' codepoint
        /// location: The first codepoint of the identifier
        token_function,
        /// An '@' codepoint + an identifier
        /// location: The '@' codepoint
        token_at_keyword,
        /// A '#' codepoint + an identifier, that does not form a valid ID selector
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
        /// location: The 'u' of "url"
        token_bad_url,
        /// A single codepoint
        /// location: The codepoint
        /// extra: Use `extra.codepoint()` to get the value of the codepoint.
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

        /// An at-rule
        /// children: A prelude (an arbitrary sequence of components) + optionally, a `simple_block_curly`
        /// location: The location of the <at-keyword-token> that started this rule
        /// extra: Use `extra.index()` to get a component tree index.
        ///        Then, if the value is 0, the at-rule does not have an associated <{}-block>.
        ///        Otherwise, the at-rule does have a <{}-block>, and the value is the index of that block (with tag = `simple_block_curly`).
        at_rule,
        /// A qualified rule
        /// children: A prelude (an arbitrary sequence of components) + a `simple_block_curly` or `style_block`
        /// location: The location of the first token of the prelude
        /// extra: Use `extra.index()` to get a component tree index.
        ///        The value is the index of the qualified rule's associated <{}-block> (with tag = `simple_block_curly` or `style_block`).
        qualified_rule,
        /// A '{}-block' containing style rules
        /// children: A sequence of `declaration`, `qualified_rule`, and `at_rule`
        ///           (Note: This sequence will match the order that each component appeared in the source.
        ///           However, logically, it must be treated as if the declarations appear first, followed by the rules.
        ///           See CSS Syntax Level 3 section 5.4.4 "Consume a style block’s contents".)
        /// location: The location of the <{-token> that opens this block
        style_block,
        /// A CSS property declaration
        /// children: The declaration's value (an arbitrary sequence of components)
        ///           If the declaration's value originally ended with "!important", those tokens are not included in the tree
        /// location: The location of the <ident-token> that is the name for this declaration
        /// extra: Use `extra.important()` to see if this declaration was marked with "!important"
        declaration,
        /// A function
        /// children: An arbitrary sequence of components
        /// location: The location of the <function-token> that created this component
        function,
        /// A '[]-block'
        /// children: An arbitrary sequence of components
        /// location: The location of the <[-token> that opens this block
        simple_block_bracket,
        /// A '{}-block'
        /// children: An arbitrary sequence of components
        /// location: The location of the <{-token> that opens this block
        simple_block_curly,
        /// A '()-block'
        /// children: An arbitrary sequence of components
        /// location: The location of the <(-token> that opens this block
        simple_block_paren,

        /// A list of at-rules and qualified rules
        /// children: A sequence of `at_rule` and `qualified_rule`
        /// location: The beginning of the stylesheet
        rule_list,
        /// A list of component values
        /// children: An arbitrary sequence of components
        /// location: The beginning of the stylesheet
        component_list,
    };
};

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
            try writer.print("tree size {}\n", .{c.items(.next_sibling)[0]});

            const Item = struct {
                current: ComponentTree.Size,
                end: ComponentTree.Size,
            };
            var stack = ArrayListUnmanaged(Item){};
            defer stack.deinit(allocator);
            try stack.append(allocator, .{ .current = 0, .end = c.items(.next_sibling)[0] });

            while (stack.items.len > 0) {
                const last = &stack.items[stack.items.len - 1];
                if (last.current != last.end) {
                    const index = last.current;
                    const component = c.get(index);
                    const indent = (stack.items.len - 1) * 4;
                    try writer.writeByteNTimes(' ', indent);
                    try writer.print("{} {s} {} {}\n", .{ index, @tagName(component.tag), component.location.value, @as(u32, @bitCast(component.extra)) });

                    last.current = component.next_sibling;
                    if (index + 1 != component.next_sibling) {
                        try stack.append(allocator, .{ .current = index + 1, .end = component.next_sibling });
                    }
                } else {
                    _ = stack.pop();
                }
            }
        }
    };
};
