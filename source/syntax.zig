const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const MultiArrayList = std.MultiArrayList;

const zss = @import("zss.zig");
const tokenize = @import("syntax/tokenize.zig");
pub const parse = @import("syntax/parse.zig");
pub const IdentifierSet = @import("syntax/IdentifierSet.zig");

comptime {
    if (@import("builtin").is_test) {
        _ = tokenize;
        _ = parse;
    }
}

/// Each field has the following information:
///     description: A basic description of the component
///        location: What the component's `location` field represents
pub const Token = union(enum) {
    /// description: The end of a sequence of tokens
    ///    location: The end of the source document
    token_eof,
    /// description: A sequence of one or more comment blocks
    ///    location: The opening '/' of the first comment block
    token_comments,
    /// description: An identifier
    ///    location: The first codepoint of the identifier
    token_ident,
    /// description: An identifier + a '(' codepoint
    ///    location: The first codepoint of the identifier
    token_function,
    /// description: An '@' codepoint + an identifier
    ///    location: The '@' codepoint
    token_at_keyword,
    /// description: A '#' codepoint + an identifier that does not form a valid ID selector
    ///    location: The '#' codepoint
    token_hash_unrestricted,
    /// description: A '#' codepoint + an identifier that forms a valid ID selector
    ///    location: The '#' codepoint
    token_hash_id,
    /// description: A quoted string
    ///    location: The beginning '\'' or '"' codepoint
    token_string,
    /// description: A quoted string with an unescaped newline in it
    ///    location: The beginning '\'' or '"' codepoint
    token_bad_string,
    /// description: The identifier "url" + a '(' codepoint + a sequence of codepoints + a ')' codepoint
    ///    location: The 'u' of "url"
    token_url,
    /// description: Identical to `token_url`, but the sequence contains invalid codepoints
    ///    location: The 'u' of "url"
    token_bad_url,
    /// description: A single codepoint
    ///    location: The codepoint
    token_delim: u21,
    /// description: An optional '+' or '-' codepoint + a sequence of digits
    ///    location: The +/- sign or the first digit
    token_integer: i32,
    /// description: A numeric value (integral or floating point)
    ///    location: The first codepoint of the number
    token_number: f32,
    /// description: A numeric value (integral or floating point) + a '%' codepoint
    ///    location: The first codepoint of the number
    token_percentage: f32,
    /// description: A numeric value (integral or floating point) + an identifier
    ///    location: The first codepoint of the number
    token_dimension: Dimension,
    /// description: A series of one or more whitespace codepoints
    ///    location: The first whitespace codepoint
    token_whitespace,
    /// description: The sequence "<!--"
    ///    location: The '<' of the sequence
    token_cdo,
    /// description: The sequence "-->"
    ///    location: The first '-' of the sequence
    token_cdc,
    /// description: A ':' codepoint
    ///    location: The codepoint
    token_colon,
    /// description: A ';' codepoint
    ///    location: The codepoint
    token_semicolon,
    /// description: A ',' codepoint
    ///    location: The codepoint
    token_comma,
    /// description: A '[' codepoint
    ///    location: The codepoint
    token_left_square,
    /// description: A ']' codepoint
    ///    location: The codepoint
    token_right_square,
    /// description: A '(' codepoint
    ///    location: The codepoint
    token_left_paren,
    /// description: A ')' codepoint
    ///    location: The codepoint
    token_right_paren,
    /// description: A '{' codepoint
    ///    location: The codepoint
    token_left_curly,
    /// description: A '}' codepoint
    ///    location: The codepoint
    token_right_curly,

    pub const Unit = enum {
        unrecognized,
        px,
    };

    pub const Dimension = struct {
        number: f32,
        unit: Unit,
        unit_location: TokenSource.Location,
    };

    pub fn cast(token: Token, comptime Derived: type) Derived {
        comptime zss.debug.ensureCompatibleEnums(std.meta.Tag(Token), Derived);
        @setRuntimeSafety(false);
        return @enumFromInt(@intFromEnum(token));
    }
};

pub const TokenSource = tokenize.Source;
pub const IdentSequenceIterator = tokenize.IdentSequenceIterator;
pub const StringSequenceIterator = tokenize.StringSequenceIterator;
pub const UrlSequenceIterator = tokenize.UrlSequenceIterator;
pub const stringIsIdentSequence = tokenize.stringIsIdentSequence;

/// Corresponds to what CSS calls a "component value".
pub const Component = struct {
    next_sibling: Ast.Size,
    tag: Tag,
    /// The location of the Component in whatever Source created it. The meaning of this value depends on `tag`.
    location: TokenSource.Location,
    /// Additional info about the Component. The meaning of this value depends on `tag`.
    extra: Extra,

    // TODO: Make this an untagged union
    pub const Extra = extern struct {
        /// Trying to read/write this field directly should not be attempted.
        /// Better to use one of the member functions instead.
        _: u32,

        pub fn make(int: u32) Extra {
            return @bitCast(int);
        }

        // The following functions cast an extra value to a different type.
        // It is very important to use the right one, in the right context.

        pub fn index(extra: Extra) Ast.Size {
            return @bitCast(extra);
        }

        pub fn codepoint(extra: Extra) u21 {
            return @intCast(@as(u32, @bitCast(extra)));
        }

        pub fn integer(extra: Extra) i32 {
            return @bitCast(extra);
        }

        pub fn number(extra: Extra) f32 {
            return @bitCast(extra);
        }

        pub fn unit(extra: Extra) Token.Unit {
            return @enumFromInt(@as(u32, @bitCast(extra)));
        }
    };

    /// Each field has the following information:
    ///     description: A basic description of the component
    ///        location: What the component's `location` field represents
    ///        children: The children that the component is allowed to have.
    ///                  If not specified, then the component cannot have any children.
    ///           extra: What the component's `extra` field represents.
    ///                  If not specified, then the `extra` field is meaningless.
    ///            note: Additional notes
    ///
    /// Components that represent tokens begin with `token_`. More documentation for these can be found by looking at `Token`.
    /// Components that represent constructs from zml begin with `zml_`.
    /// This enum is derived from `Token`.
    ///
    /// Unless otherwise specified, whitespace (`token_whitespace`) and comments (`token_comments`) may appear
    /// at any position within a sequence of components.
    /// For example, "a sequence of `token_ident`" is really "a sequence of `token_ident`, `token_whitespace`, and `token_comments`".
    pub const Tag = enum {
        ///        note: This component never appears within the Ast
        token_eof,
        token_comments,
        token_ident,
        token_function,
        token_at_keyword,
        token_hash_unrestricted,
        token_hash_id,
        token_string,
        token_bad_string,
        token_url,
        token_bad_url,
        ///       extra: Use `extra.codepoint()` to get the value of the codepoint as a `u21`
        token_delim,
        ///       extra: Use `extra.integer()` to get the integer as an `i32`
        token_integer,
        ///       extra: Use `extra.number()` to get the number as an `f32`
        token_number,
        ///       extra: Use `extra.number()` to get the number as an `f32`
        token_percentage,
        ///    children: The dimension's unit (a `unit`)
        ///       extra: Use `extra.number()` to get the number as an `f32`
        token_dimension,
        token_whitespace,
        token_cdo,
        token_cdc,
        token_colon,
        token_semicolon,
        token_comma,
        token_left_square,
        token_right_square,
        token_left_paren,
        token_right_paren,
        token_left_curly,
        token_right_curly,

        /// description: A dimension's unit (an identifier)
        ///    location: The first codepoint of the unit identifier
        ///       extra: Use `extra.unit()` to get the unit as a `Token.Unit`
        unit,
        /// description: A function
        ///    children: The function's arguments (an arbitrary sequence of components)
        ///    location: The location of the <function-token> that created this component
        function,
        /// description: A '[]-block'
        ///    location: The location of the <[-token> that opens this block
        ///    children: An arbitrary sequence of components
        simple_block_square,
        /// description: A '{}-block'
        ///    location: The location of the <{-token> that opens this block
        ///    children: An arbitrary sequence of components
        simple_block_curly,
        /// description: A '()-block'
        ///    location: The location of the <(-token> that opens this block
        ///    children: An arbitrary sequence of components
        simple_block_paren,

        /// description: A CSS property declaration that does not end with "!important"
        ///    location: The location of the <ident-token> that is the name for this declaration
        ///    children: The declaration's value (an arbitrary sequence of components)
        ///              Trailing and leading <whitespace-token>s are not included
        ///              The ending <semicolon-token> (if it exists) is not included
        ///       extra: Use `extra.index()` to get a component tree index.
        ///              Then, if the value is 0, the declaration is the first declaration in its containing style block.
        ///              Otherwise, the value is the index of the declaration that appeared just before this one
        ///              (with tag = `declaration_normal` or `declaration_important`).
        declaration_normal,
        /// description: A CSS property declaration that ends with "!important"
        ///    location: The location of the <ident-token> that is the name for this declaration
        ///    children: The declaration's value (an arbitrary sequence of components)
        ///              Trailing and leading <whitespace-token>s are not included
        ///              The ending <semicolon-token> (if it exists) is not included
        ///              The <delim-token> and <ident-token> that make up "!important" are not included
        ///       extra: Use `extra.index()` to get a component tree index.
        ///              Then, if the value is 0, the declaration is the first declaration in its containing style block.
        ///              Otherwise, the value is the index of the declaration that appeared just before this one
        ///              (with tag = `declaration_normal` or `declaration_important`).
        declaration_important,

        /// description: A '{}-block' containing style rules
        ///    location: The location of the <{-token> that opens this block
        ///    children: A sequence of `declaration_normal`, `declaration_important`, `qualified_rule`, and `at_rule`
        ///              (Note: This sequence will match the order that each component appeared in the stylesheet.
        ///              However, logically, it must be treated as if all of the declarations appear first, followed by the rules.
        ///              See CSS Syntax Level 3 section 5.4.4 "Consume a style block's contents".)
        ///       extra: Use `extra.index()` to get a component tree index.
        ///              Then, if the value is 0, the style block does not contain any declarations.
        ///              Otherwise, the value is the index of the *last* declaration in the style block
        ///              (with tag = `declaration_normal` or `declaration_important`).
        style_block,
        /// description: An at-rule
        ///    children: A prelude (an arbitrary sequence of components) + optionally, a `simple_block_curly`
        ///    location: The location of the <at-keyword-token> that started this rule
        ///       extra: Use `extra.index()` to get a component tree index.
        ///              Then, if the value is 0, the at-rule does not have an associated <{}-block>.
        ///              Otherwise, the at-rule does have a <{}-block>, and the value is the index of that block (with tag = `simple_block_curly`).
        at_rule,
        /// description: A qualified rule
        ///    location: The location of the first token of the prelude
        ///    children: A prelude (an arbitrary sequence of components) + a `simple_block_curly` or `style_block`
        ///       extra: Use `extra.index()` to get a component tree index.
        ///              The value is the index of the qualified rule's associated <{}-block> (with tag = `simple_block_curly` or `style_block`).
        qualified_rule,
        /// description: A list of at-rules and qualified rules
        ///    location: The beginning of the stylesheet
        ///    children: A sequence of `at_rule` and `qualified_rule`
        rule_list,
        /// description: A list of component values
        ///    location: The beginning of the stylesheet
        ///    children: An arbitrary sequence of components
        component_list,

        /// description: A zml empty feature (a '*' codepoint)
        ///    location: The '*' codepoint
        zml_empty,
        /// description: A zml element type (an identifier)
        ///    location: The identifier's first codepoint
        zml_type,
        /// description: A zml element id (a '#' codepoint + an identifier)
        ///    location: The '#' codepoint
        zml_id,
        /// description: A zml element class (a '.' codepoint + an identifier)
        ///    location: The '.' codepoint
        zml_class,
        /// description: A zml element attribute (a '[]-block' containing (an attribute name + optionally, a '=' codepoint and an attribute value))
        ///    location: The location of the <[-token> that opens the block
        ///    children: The attribute name (a `token_ident`) + optionally, the attribute value (a `token_ident` or `token_string`)
        zml_attribute,
        /// description: A zml element's features (a '*' codepoint, or a sequence of types, ids, classes, and attributes)
        ///    location: The location of the element's first feature
        ///    children: Either a single `zml_empty`, or
        ///              a non-empty sequence of `zml_type`, `zml_id`, `zml_class`, and `zml_attribute` (at most one `zml_type` is allowed)
        zml_features,
        /// description: A zml element's inline style declarations (a '()-block' containing declarations)
        ///    location: The location of the <(-token> that opens the block
        ///    children: A non-empty sequence of `declaration_normal` and `declaration_important`
        ///       extra: Use `extra.index()` to get the component index of the *last* declaration in the inline style block
        ///              (with tag = `declaration_normal` or `declaration_important`).
        zml_styles,
        /// description: A '{}-block' containing a zml element's children
        ///    location: The location of the <{-token> that opens the block
        ///    children: A sequence of `zml_element` and `zml_text_element`
        zml_children,
        /// description: A zml element
        ///    location: The location of the `zml_features`
        ///    children: The element's features (a `zml_features`) +
        ///              optionally, the element's inline style declarations (a `zml_styles`) +
        ///              the element's children (a `zml_children`)
        zml_element,
        /// description: A zml text element (a string)
        ///    location: The beginning '\'' or '"' codepoint
        zml_text_element,
        /// description: A zml document
        ///    location: The beginning of the source document
        ///    children: Optionally, a single `zml_element` or `zml_text_element`
        zml_document,
    };
};

pub const Ast = struct {
    components: List = .{},

    pub const List = MultiArrayList(Component);

    pub const Size = u32;

    pub const Sequence = struct {
        start: Size,
        end: Size,

        pub fn empty(sequence: Sequence) bool {
            return (sequence.start == sequence.end);
        }

        /// Returns the next component in the sequence, skipping over whitespace and comment components.
        pub fn next(sequence: *Sequence, s: Slice) ?Ast.Size {
            if (sequence.empty()) return null;
            const result = sequence.start;
            var current = s.nextSibling(sequence.start);
            while (current != sequence.end) {
                switch (s.tag(current)) {
                    .token_whitespace, .token_comments => current = s.nextSibling(current),
                    else => break,
                }
            }
            sequence.start = current;
            return result;
        }

        /// Returns the next component in a declaration's value.
        pub const nextDeclComponent = next;

        /// Returns to a previously visited point in the sequence.
        /// `index` must be a value that was previously returned from one of the `next*` functions.
        pub fn reset(sequence: *Sequence, index: Ast.Size) void {
            sequence.start = index;
        }
    };

    /// Free resources associated with the Ast.
    pub fn deinit(tree: *Ast, allocator: Allocator) void {
        tree.components.deinit(allocator);
    }

    pub const Slice = struct {
        len: Size,
        ptrs: struct {
            next_sibling: [*]const Ast.Size,
            tag: [*]const Component.Tag,
            location: [*]const TokenSource.Location,
            extra: [*]const Component.Extra,
        },

        pub fn get(self: Slice, index: Ast.Size) Component {
            assert(index < self.len);
            return Component{
                .next_sibling = self.ptrs.next_sibling[index],
                .tag = self.ptrs.tag[index],
                .location = self.ptrs.location[index],
                .extra = self.ptrs.extra[index],
            };
        }

        pub fn nextSibling(self: Slice, index: Ast.Size) Ast.Size {
            assert(index < self.len);
            return self.ptrs.next_sibling[index];
        }

        pub fn tag(self: Slice, index: Ast.Size) Component.Tag {
            assert(index < self.len);
            return self.ptrs.tag[index];
        }

        pub fn location(self: Slice, index: Ast.Size) TokenSource.Location {
            assert(index < self.len);
            return self.ptrs.location[index];
        }

        pub fn extra(self: Slice, index: Ast.Size) Component.Extra {
            assert(index < self.len);
            return self.ptrs.extra[index];
        }

        /// Returns the sequence of the immediate children of `index`
        pub fn children(self: Slice, index: Ast.Size) Sequence {
            var current = index + 1;
            const end = self.nextSibling(index);
            while (current != end) {
                switch (self.tag(current)) {
                    .token_whitespace, .token_comments => current = self.nextSibling(current),
                    else => break,
                }
            }
            return .{ .start = current, .end = end };
        }
    };

    pub fn slice(tree: Ast) Slice {
        const list_slice = tree.components.slice();
        return Slice{
            .len = @intCast(list_slice.len),
            .ptrs = .{
                .next_sibling = list_slice.items(.next_sibling).ptr,
                .tag = list_slice.items(.tag).ptr,
                .location = list_slice.items(.location).ptr,
                .extra = list_slice.items(.extra).ptr,
            },
        };
    }

    pub const debug = struct {
        pub fn print(tree: Ast, allocator: Allocator, writer: std.io.AnyWriter) !void {
            const c = tree.components;
            try writer.print("Ast (index, component, location, extra)\narray len {}\n", .{c.len});
            if (c.len == 0) return;
            try writer.print("tree size {}\n", .{c.items(.next_sibling)[0]});

            const Item = struct {
                current: Ast.Size,
                end: Ast.Size,
            };
            var stack = std.ArrayListUnmanaged(Item){};
            defer stack.deinit(allocator);
            try stack.append(allocator, .{ .current = 0, .end = c.items(.next_sibling)[0] });

            while (stack.items.len > 0) {
                const last = &stack.items[stack.items.len - 1];
                if (last.current != last.end) {
                    const index = last.current;
                    const component = c.get(index);
                    const indent = (stack.items.len - 1) * 4;
                    try writer.writeByteNTimes(' ', indent);
                    try writer.print("{} {s} {} ", .{ index, @tagName(component.tag), @intFromEnum(component.location) });
                    try printExtra(writer, component.tag, component.extra);
                    try writer.writeAll("\n");

                    last.current = component.next_sibling;
                    if (index + 1 != component.next_sibling) {
                        try stack.append(allocator, .{ .current = index + 1, .end = component.next_sibling });
                    }
                } else {
                    _ = stack.pop();
                }
            }
        }

        fn printExtra(writer: std.io.AnyWriter, tag: Component.Tag, extra: Component.Extra) !void {
            switch (tag) {
                .token_delim => try writer.print("U+{X}", .{extra.codepoint()}),
                .token_integer => try writer.print("{}", .{extra.integer()}),
                .token_number, .token_dimension => try writer.print("{d}", .{extra.number()}),
                .unit => try writer.print("{s}", .{@tagName(extra.unit())}),
                .token_percentage => try writer.print("{d}%", .{extra.number()}),
                else => try writer.print("{}", .{@as(u32, @bitCast(extra))}),
            }
        }
    };
};

pub fn ComptimeIdentifierMap(comptime V: type) type {
    return struct {
        map: Map,

        const Self = @This();
        const Map = std.StaticStringMapWithEql(V, stringEql);

        fn stringEql(key: []const u8, str: []const u8) bool {
            for (key, str) |k, s| {
                const lowercase = switch (s) {
                    'A'...'Z' => s - 'A' + 'a',
                    else => s,
                };
                if (k != lowercase) return false;
            }
            return true;
        }

        pub fn init(kvs_list: anytype) Self {
            comptime for (kvs_list) |kv| {
                for (kv[0]) |c| switch (c) {
                    // NOTE: This could be extended to support underscores and digits, but for now it is not needed.
                    'a'...'z', '-' => {},
                    else => @compileError("key must contain only lowercase letters and dashes, got " ++ kv[0]),
                };
            };
            return .{ .map = Map.initComptime(kvs_list) };
        }

        pub fn get(self: Self, str: []const u8) ?V {
            return self.map.get(str);
        }
    };
}
