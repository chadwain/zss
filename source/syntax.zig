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
    /// description: A value that could not be represented as a token, and therefore raised a tokenization error
    ///    location: The location should be interpreted as if this token was equal to the `tokenize_as` field of the error payload
    token_error: Error,
    /// description: A sequence of one or more consecutive comment blocks
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
    token_at_keyword: ?AtRule,
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

    pub const Error = struct {
        tokenize_as: TokenizeAs,
        cause: Cause,

        pub const TokenizeAs = enum {
            token_integer,
            token_number,
            token_percentage,
            token_dimension,
        };

        pub const Cause = enum {
            /// The integer value could not fit into the destination integer type.
            integer_overflow,
            /// The floating point value was too long to be parsed.
            float_too_long,
            /// The floating point value was either a subnormal, infinity, or NaN.
            /// Floating point values must be either positive zero, negative zero, or normal.
            invalid_float,
        };
    };

    pub const Unit = enum {
        px,
    };

    pub const Dimension = struct {
        number: f32,
        unit: ?Unit,
        unit_location: TokenSource.Location,
    };

    pub const AtRule = enum {
        import,
        namespace,
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
    /// The location of the Component in whatever TokenSource it originated from. The meaning of this value depends on `tag`.
    location: TokenSource.Location,
    /// Additional info about the Component. The meaning of this value depends on `tag`.
    extra: Extra,

    pub const Extra = union {
        index: Ast.Size,
        codepoint: u21,
        integer: i32,
        number: f32,
        @"error": Token.Error,
        unit: ?Token.Unit,
        at_rule: ?Token.AtRule,

        pub const undef: Extra = .{ .index = 0 };
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
    /// Whitespace (`token_whitespace`) and comments (`token_comments`) are collectively referred to as "space components".
    /// Unless otherwise specified, space components may appear at any position within a sequence of components.
    /// For example, "a sequence of `token_ident`" is really "a sequence of `token_ident`, `token_whitespace`, and `token_comments`".
    pub const Tag = enum {
        ///        note: This component never appears within the Ast
        token_eof,
        ///       extra: Use `extra.@"error"` to get the error as a `Token.Error`
        token_error,
        token_comments,
        token_ident,
        ///        note: This component never appears within the Ast
        token_function,
        token_at_keyword,
        token_hash_unrestricted,
        token_hash_id,
        token_string,
        token_bad_string,
        token_url,
        token_bad_url,
        ///       extra: Use `extra.codepoint` to get the value of the codepoint as a `u21`
        token_delim,
        ///       extra: Use `extra.integer` to get the integer as an `i32`
        token_integer,
        ///       extra: Use `extra.number` to get the number as an `f32`
        token_number,
        ///       extra: Use `extra.number` to get the number as an `f32`
        token_percentage,
        ///    children: The dimension's unit (a `unit`)
        ///       extra: Use `extra.number` to get the number as an `f32`
        token_dimension,
        token_whitespace,
        token_cdo,
        token_cdc,
        token_colon,
        token_semicolon,
        token_comma,
        ///        note: This component never appears within the Ast
        token_left_square,
        ///        note: This component never appears within the Ast
        token_right_square,
        ///        note: This component never appears within the Ast
        token_left_paren,
        token_right_paren,
        token_left_curly,
        token_right_curly,

        /// description: A dimension's unit (an identifier)
        ///    location: The first codepoint of the unit identifier
        ///       extra: Use `extra.unit` to get the unit as a `Token.Unit`
        ///              A value of `null` represents an unrecognized unit.
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
        ///       extra: Use `extra.index` to get a component tree index.
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
        ///       extra: Use `extra.index` to get a component tree index.
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
        ///       extra: Use `extra.index` to get a component tree index.
        ///              Then, if the value is 0, the style block does not contain any declarations.
        ///              Otherwise, the value is the index of the *last* declaration in the style block
        ///              (with tag = `declaration_normal` or `declaration_important`).
        style_block,
        /// description: An at-rule
        ///    children: A prelude (an arbitrary sequence of components) + optionally, a `simple_block_curly`
        ///    location: The location of the <at-keyword-token> that started this rule
        ///       extra: Use `extra.at_rule` to get the at-rule.
        ///              A value of `null` represents an unrecognized at-rule.
        at_rule,
        /// description: A qualified rule
        ///    location: The location of the first token of the prelude
        ///    children: A prelude (an arbitrary sequence of components) + a `simple_block_curly` or `style_block`
        ///       extra: Use `extra.index` to get a component tree index.
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
        ///       extra: Use `extra.index` to get the component index of the *last* declaration in the inline style block
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
    components: MultiArrayList(Component).Slice,
    debug: Debug = .{},

    pub const Size = u32;

    pub const Sequence = struct {
        start: Size,
        end: Size,

        pub fn empty(sequence: Sequence) bool {
            return (sequence.start == sequence.end);
        }

        /// Returns the next component in the sequence.
        pub fn nextKeepSpaces(sequence: *Sequence, ast: Ast) ?Size {
            if (sequence.empty()) return null;
            assert(sequence.start < sequence.end);

            defer sequence.start = ast.nextSibling(sequence.start);
            return sequence.start;
        }

        /// Returns the next component in the sequence, skipping over space components.
        pub fn nextSkipSpaces(sequence: *Sequence, ast: Ast) ?Size {
            if (sequence.empty()) return null;
            assert(sequence.start < sequence.end);

            var current = ast.nextSibling(sequence.start);
            defer sequence.start = while (current != sequence.end) {
                assert(current < sequence.end);
                switch (ast.tag(current)) {
                    .token_whitespace, .token_comments => current = ast.nextSibling(current),
                    else => break current,
                }
            } else sequence.end;
            return sequence.start;
        }

        /// Returns the next component in a declaration's value.
        pub const nextDeclComponent = nextSkipSpaces;

        /// Returns true if any space components were encountered.
        pub fn skipSpaces(sequence: *Sequence, ast: Ast) bool {
            const initial_index = sequence.start;
            while (sequence.start != sequence.end) {
                assert(sequence.start < sequence.end);
                switch (ast.tag(sequence.start)) {
                    .token_whitespace, .token_comments => sequence.start = ast.nextSibling(sequence.start),
                    else => break,
                }
            }
            return sequence.start != initial_index;
        }

        /// Returns to a previously visited point in the sequence.
        /// `index` must be a value that was previously returned from one of the `next*` functions.
        pub fn reset(sequence: *Sequence, index: Size) void {
            sequence.start = index;
        }
    };

    /// Free resources associated with the Ast.
    pub fn deinit(ast: *Ast, allocator: Allocator) void {
        ast.components.deinit(allocator);
    }

    pub fn nextSibling(ast: Ast, index: Size) Size {
        return ast.components.items(.next_sibling)[index];
    }

    pub fn tag(ast: Ast, index: Size) Component.Tag {
        return ast.components.items(.tag)[index];
    }

    pub fn location(ast: Ast, index: Size) TokenSource.Location {
        return ast.components.items(.location)[index];
    }

    pub fn extra(ast: Ast, index: Size) Component.Extra {
        return ast.components.items(.extra)[index];
    }

    /// Returns the sequence of the immediate children of `index`
    // TODO: Change the name to reflect that this skips leading space components
    pub fn children(ast: Ast, index: Size) Sequence {
        var current = index + 1;
        const end = ast.nextSibling(index);
        while (current != end) {
            switch (ast.tag(current)) {
                .token_whitespace, .token_comments => current = ast.nextSibling(current),
                else => break,
            }
        }
        return .{ .start = current, .end = end };
    }

    pub const Debug = struct {
        pub fn print(debug: *const Debug, allocator: Allocator, writer: std.io.AnyWriter) !void {
            const ast = @as(*const Ast, @alignCast(@fieldParentPtr("debug", debug))).*;
            try writer.print("Ast (index, component, location, extra), size = {}\n", .{ast.components.len});
            if (ast.components.len == 0) return;

            var stack = zss.Stack(Sequence){};
            defer stack.deinit(allocator);
            stack.top = .{ .start = 0, .end = ast.nextSibling(0) };

            while (stack.top) |*top| {
                const index = top.nextKeepSpaces(ast) orelse {
                    _ = stack.pop();
                    continue;
                };
                const component = ast.components.get(index);
                const indent = (stack.len() - 1) * 4;
                try writer.writeByteNTimes(' ', indent);
                try writer.print("{} {s} {} ", .{
                    index,
                    if (component.tag != .token_error) @tagName(component.tag) else @tagName(component.extra.@"error".tokenize_as),
                    @intFromEnum(component.location),
                });
                try printExtra(writer, component.tag, component.extra);
                try writer.writeAll("\n");

                const children_sequence = ast.children(index);
                if (!children_sequence.empty()) {
                    try stack.push(allocator, children_sequence);
                }
            }
        }

        fn printExtra(writer: std.io.AnyWriter, component_tag: Component.Tag, component_extra: Component.Extra) !void {
            switch (component_tag) {
                .token_delim => try writer.print("U+{X}", .{component_extra.codepoint}),
                .token_integer => try writer.print("{}", .{component_extra.integer}),
                .token_number, .token_dimension => try writer.print("{d}", .{component_extra.number}),
                .token_error => try writer.print("(error: {s})", .{@tagName(component_extra.@"error".cause)}),
                .unit => if (component_extra.unit) |unit| try writer.print("{s}", .{@tagName(unit)}),
                .token_percentage => try writer.print("{d}%", .{component_extra.number}),
                .declaration_normal,
                .declaration_important,
                .style_block,
                .zml_styles,
                .qualified_rule,
                => try writer.print("{}", .{component_extra.index}),
                .at_rule => if (component_extra.at_rule) |at_rule| try writer.print("@{s}", .{@tagName(at_rule)}),
                else => {},
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
