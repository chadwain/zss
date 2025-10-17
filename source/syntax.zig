const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const MultiArrayList = std.MultiArrayList;

const zss = @import("zss.zig");
const tokenize = @import("syntax/tokenize.zig");
const parse = @import("syntax/parse.zig");

pub const Parser = parse.Parser;

comptime {
    if (@import("builtin").is_test) {
        _ = tokenize;
        _ = parse;
    }
}

/// Each field has the following information:
///     description: A basic description of the component
///        location: Where the component's `location` field points to in the source document
pub const Token = union(enum) {
    /// description: The end of a sequence of tokens
    ///    location: The end of the source document
    token_eof,
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
    token_integer: ?i32,
    /// description: A numeric value (integral or floating point)
    ///    location: The first codepoint of the number
    token_number: ?Float,
    /// description: A numeric value (integral or floating point) + a '%' codepoint
    ///    location: The first codepoint of the number
    token_percentage: ?Float,
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

    pub const Float = f32;

    pub const Unit = enum {
        px,
    };

    pub const Dimension = struct {
        number: ?Float,
        unit: ?Unit,
        unit_location: SourceCode.Location,
    };

    pub const AtRule = enum {
        import,
        namespace,
    };

    pub fn cast(token: Token, comptime Derived: type) Derived {
        return zss.meta.coerceEnum(Derived, token);
    }
};

/// A simple wrapper around a UTF-8 encoded text buffer.
/// The text buffer has a length limit of `Source.max_input_len`.
/// If there is any invalid UTF-8 in the text buffer, it will be detected during tokenization.
/// Outside of tokenization and parsing, it is generally illegal behavior to use this if the text buffer contains invalid UTF-8.
pub const SourceCode = struct {
    // TODO: Consider making keeping source code unnecessary, by copying some source code text into Ast

    text: []const u8,

    /// A byte-offset into the source code text.
    pub const Location = enum(u32) { _ };
    pub const max_input_len = std.math.maxInt(std.meta.Tag(Location));

    pub fn init(text: []const u8) error{SourceCodeTooLong}!SourceCode {
        if (text.len > max_input_len) return error.SourceCodeTooLong;
        return SourceCode{ .text = text };
    }

    /// Asserts that `start` is the location of the start of an ident token.
    pub fn identTokenIterator(source_code: SourceCode, start: Location) IdentSequenceIterator {
        const next_3, _ = tokenize.peekCodepoints(3, source_code, start) catch unreachable;
        assert(tokenize.codepointsStartAnIdentSequence(next_3));
        return IdentSequenceIterator{ .source_code = source_code, .location = start };
    }

    /// Asserts that `start` is the location of the start of an ID hash token.
    pub fn hashIdTokenIterator(source_code: SourceCode, start: Location) IdentSequenceIterator {
        const hash, const location = tokenize.peekCodepoint(source_code, start) catch unreachable;
        assert(hash == '#');
        return IdentSequenceIterator{ .source_code = source_code, .location = location };
    }

    /// Asserts that `start` is the location of the start of an at-keyword token.
    pub fn atKeywordTokenIterator(source_code: SourceCode, start: Location) IdentSequenceIterator {
        const at, const location = tokenize.peekCodepoint(source_code, start) catch unreachable;
        assert(at == '@');
        return identTokenIterator(source_code, location);
    }

    /// Asserts that `start` is the location of the start of a string token.
    pub fn stringTokenIterator(source_code: SourceCode, start: Location) StringTokenIterator {
        const quote, const location = tokenize.peekCodepoint(source_code, start) catch unreachable;
        assert(quote == '"' or quote == '\'');
        return StringTokenIterator{ .source_code = source_code, .location = location, .ending_codepoint = quote };
    }

    /// Asserts that `start` is the location of the start of a url token.
    pub fn urlTokenIterator(source_code: SourceCode, start: Location) UrlTokenIterator {
        const url, var location = tokenize.peekCodepoints(4, source_code, start) catch unreachable;
        assert(std.mem.eql(u21, &url, &[4]u21{ 'u', 'r', 'l', '(' }));
        tokenize.consumeWhitespace(source_code, &location) catch unreachable;
        return UrlTokenIterator{ .source_code = source_code, .location = location };
    }

    pub const CopyMode = union(enum) {
        buffer: []u8,
        allocator: Allocator,
    };

    /// Given that `location` is the location of a <ident-token>, copy that identifier
    pub fn copyIdentifier(source_code: SourceCode, location: Location, copy_mode: CopyMode) error{OutOfMemory}![]u8 {
        var iterator = identTokenIterator(source_code, location);
        return copyTokenGeneric(&iterator, copy_mode);
    }

    /// Given that `location` is the location of a <string-token>, copy that string
    pub fn copyString(source_code: SourceCode, location: Location, copy_mode: CopyMode) error{OutOfMemory}![]u8 {
        var iterator = stringTokenIterator(source_code, location);
        return copyTokenGeneric(&iterator, copy_mode);
    }

    /// Given that `location` is the location of a <at-keyword-token>, copy that keyword
    pub fn copyAtKeyword(source_code: SourceCode, location: Location, copy_mode: CopyMode) error{OutOfMemory}![]u8 {
        var iterator = atKeywordTokenIterator(source_code, location);
        return copyTokenGeneric(&iterator, copy_mode);
    }

    /// Given that `location` is the location of an ID <hash-token>, copy that hash's identifier
    pub fn copyHashId(source_code: SourceCode, location: Location, copy_mode: CopyMode) error{OutOfMemory}![]u8 {
        var iterator = hashIdTokenIterator(source_code, location);
        return copyTokenGeneric(&iterator, copy_mode);
    }

    /// Given that `location` is the location of a <url-token>, copy that URL
    pub fn copyUrl(source_code: SourceCode, location: Location, copy_mode: CopyMode) error{OutOfMemory}![]u8 {
        var iterator = urlTokenIterator(source_code, location);
        return copyTokenGeneric(&iterator, copy_mode);
    }

    /// A wrapper over std.ArrayList that abstracts over bounded vs. dynamic allocation.
    const ArrayListManaged = struct {
        array_list: std.ArrayList(u8),
        mode: union(enum) {
            bounded,
            dynamic: Allocator,
        },

        fn init(copy_mode: CopyMode) ArrayListManaged {
            return switch (copy_mode) {
                .buffer => |buffer| .{
                    .array_list = .initBuffer(buffer),
                    .mode = .bounded,
                },
                .allocator => |allocator| .{
                    .array_list = .empty,
                    .mode = .{ .dynamic = allocator },
                },
            };
        }

        fn deinit(list: *ArrayListManaged) void {
            switch (list.mode) {
                .bounded => {},
                .dynamic => |allocator| list.array_list.deinit(allocator),
            }
        }

        fn appendSlice(list: *ArrayListManaged, slice: []const u8) !void {
            switch (list.mode) {
                .bounded => try list.array_list.appendSliceBounded(slice),
                .dynamic => |allocator| try list.array_list.appendSlice(allocator, slice),
            }
        }

        fn toOwnedSlice(list: *ArrayListManaged) ![]u8 {
            switch (list.mode) {
                .bounded => return list.array_list.items,
                .dynamic => |allocator| return try list.array_list.toOwnedSlice(allocator),
            }
        }
    };

    fn copyTokenGeneric(iterator: anytype, copy_mode: CopyMode) error{OutOfMemory}![]u8 {
        var list = ArrayListManaged.init(copy_mode);
        defer list.deinit();

        var buffer: [4]u8 = undefined;
        while (iterator.next()) |codepoint| {
            const len = std.unicode.utf8Encode(codepoint, &buffer) catch unreachable;
            try list.appendSlice(buffer[0..len]);
        }

        return try list.toOwnedSlice();
    }

    /// Asserts that `start` is the location of the start of an ident token.
    pub fn formatIdentToken(source_code: SourceCode, start: Location) TokenFormatter(identTokenIterator) {
        return formatTokenGeneric(identTokenIterator, source_code, start);
    }

    /// Asserts that `start` is the location of the start of an ID hash token.
    pub fn formatHashIdToken(source_code: SourceCode, start: Location) TokenFormatter(hashIdTokenIterator) {
        return formatTokenGeneric(hashIdTokenIterator, source_code, start);
    }

    /// Asserts that `start` is the location of the start of an at-keyword token.
    pub fn formatAtKeywordToken(source_code: SourceCode, start: Location) TokenFormatter(atKeywordTokenIterator) {
        return formatTokenGeneric(atKeywordTokenIterator, source_code, start);
    }

    /// Asserts that `start` is the location of the start of a string token.
    pub fn formatStringToken(source_code: SourceCode, start: Location) TokenFormatter(stringTokenIterator) {
        return formatTokenGeneric(stringTokenIterator, source_code, start);
    }

    /// Asserts that `start` is the location of the start of a url token.
    pub fn formatUrlToken(source_code: SourceCode, start: Location) TokenFormatter(urlTokenIterator) {
        return formatTokenGeneric(urlTokenIterator, source_code, start);
    }

    fn TokenFormatter(comptime createIterator: anytype) type {
        return struct {
            source_code: SourceCode,
            location: Location,

            pub fn format(self: @This(), writer: *std.Io.Writer) !void {
                var it = createIterator(self.source_code, self.location);
                while (it.next()) |codepoint| try writer.print("{u}", .{codepoint});
            }
        };
    }

    fn formatTokenGeneric(comptime createIterator: anytype, source_code: SourceCode, location: Location) TokenFormatter(createIterator) {
        return TokenFormatter(createIterator){ .source_code = source_code, .location = location };
    }

    // TODO: Make other `*Eql` functions, such as stringEql and urlEql.

    /// Given that `location` is the location of an <ident-token>, check if the identifier is equal to `ascii_string`
    /// using case-insensitive matching.
    // TODO: Make it more clear that this only operates on 7-bit ASCII. Alternatively, remove that requirement.
    pub fn identifierEqlIgnoreCase(source_code: SourceCode, location: Location, ascii_string: []const u8) bool {
        const toLowercase = zss.unicode.latin1ToLowercase;
        var it = identTokenIterator(source_code, location);
        for (ascii_string) |string_codepoint| {
            assert(string_codepoint <= 0x7F);
            const it_codepoint = it.next() orelse return false;
            if (toLowercase(string_codepoint) != toLowercase(it_codepoint)) return false;
        }
        return it.next() == null;
    }

    /// A key-value pair.
    pub fn KV(comptime Type: type) type {
        return struct {
            /// This must be an ASCII string.
            []const u8,
            Type,
        };
    }

    /// Given that `location` is the location of an <ident-token>, if the identifier matches any of the
    /// key strings in `kvs` using case-insensitive matching, returns the corresponding value. If there was no match, null is returned.
    pub fn mapIdentifierValue(source_code: SourceCode, location: Location, comptime Type: type, kvs: []const KV(Type)) ?Type {
        // TODO: Use a hash map/trie or something
        for (kvs) |kv| {
            if (identifierEqlIgnoreCase(source_code, location, kv[0])) return kv[1];
        }
        return null;
    }

    /// Given that `start` is the location of an <ident-token>, if the identifier matches any of the
    /// fields of `Enum` using case-insensitive matching, returns that enum field. If there was no match, null is returned.
    pub fn mapIdentifierEnum(source_code: SourceCode, start: Location, comptime Enum: type) ?Enum {
        var location = start;
        return tokenize.consumeIdentSequenceWithMatch(source_code, &location, Enum) catch unreachable;
    }
};

pub const IdentSequenceIterator = struct {
    source_code: SourceCode,
    location: SourceCode.Location,

    pub fn next(it: *IdentSequenceIterator) ?u21 {
        return tokenize.consumeIdentSequenceCodepoint(it.source_code, &it.location) catch unreachable;
    }
};

pub const StringTokenIterator = struct {
    source_code: SourceCode,
    location: SourceCode.Location,
    ending_codepoint: u21,

    pub fn next(it: *StringTokenIterator) ?u21 {
        return tokenize.consumeStringTokenCodepoint(it.source_code, &it.location, it.ending_codepoint) catch unreachable;
    }
};

/// Used to iterate over <url-token>s (and NOT <bad-url-token>s)
pub const UrlTokenIterator = struct {
    source_code: SourceCode,
    location: SourceCode.Location,

    pub fn next(it: *UrlTokenIterator) ?u21 {
        return tokenize.consumeUrlTokenCodepoint(it.source_code, &it.location) catch unreachable;
    }
};

pub const Tokenizer = struct {
    source_code: SourceCode,
    location: SourceCode.Location,

    pub fn init(source_code: SourceCode) Tokenizer {
        return .{ .source_code = source_code, .location = @enumFromInt(0) };
    }

    /// Returns the next token, or `null` if it was `token_eof`.
    pub fn next(tokenizer: *Tokenizer) !?struct { Token, SourceCode.Location } {
        const location = tokenizer.location;
        const token = try tokenize.nextToken(tokenizer.source_code, &tokenizer.location);
        if (token == .token_eof) return null;
        return .{ token, location };
    }
};

/// Corresponds to what CSS calls a "component value".
pub const Component = struct {
    /// The index of the Component's next sibling component, if it has one.
    next_sibling: Ast.Size,
    tag: Tag,
    /// The location of the Component in whatever SourceCode it originated from. The meaning of this value depends on `tag`.
    location: SourceCode.Location,
    /// Additional info about the Component. The meaning of this value depends on `tag`.
    extra: Extra,

    // TODO: size goal: 4 bytes (in unsafe builds)
    pub const Extra = union {
        undef: void,
        index: Ast.Index,
        codepoint: u21,
        integer: ?i32,
        number: ?f32,
        unit: ?Token.Unit,
        at_rule: ?Token.AtRule,
    };

    /// Each field has the following information:
    ///     description: A basic description of the component
    ///        location: Where the component's `location` field points to in the source document
    ///        children: The children that the component is allowed to have.
    ///                  If not specified, then the component cannot have any children.
    ///           extra: What the component's `extra` field represents.
    ///                  If not specified, then the `extra` field is `.undef`.
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
        token_comments,
        token_ident,
        ///        note: This component never appears within the Ast, because
        ///              the equivalent token will always create a `function` component instead.
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
        ///       extra: Use `extra.integer` to get the integer as a `?i32`
        token_integer,
        ///       extra: Use `extra.number` to get the number as a `?f32`
        token_number,
        ///       extra: Use `extra.number` to get the number as a `?f32`
        token_percentage,
        ///    children: The dimension's unit (a `unit`)
        ///       extra: Use `extra.number` to get the number as a `?f32`
        token_dimension,
        token_whitespace,
        token_cdo,
        token_cdc,
        token_colon,
        token_semicolon,
        token_comma,
        ///        note: This component never appears within the Ast, because
        ///              the equivalent token will always create a `simple_block_square` component instead.
        token_left_square,
        token_right_square,
        ///        note: This component never appears within the Ast, because
        ///              the equivalent token will always create a `simple_block_paren` component instead.
        token_left_paren,
        token_right_paren,
        ///        note: This component never appears within the Ast, because
        ///              the equivalent token will always create a `simple_block_curly` component instead.
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
        ///       extra: Use `extra.index` to get a component tree index.
        ///              Then, if the value is 0, the style block does not contain any declarations.
        ///              Otherwise, the value is the index of the *last* declaration in the style block
        ///              (with tag = `declaration_normal` or `declaration_important`).
        ///        note: This element's children will be in the order that each component appeared in the stylesheet.
        ///              However, logically, it must be treated as if all of the declarations appear first, followed by the rules.
        ///              See CSS Syntax Level 3 section 5.4.4 "Consume a style block's contents".)
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
        ///    children: A sequence of `zml_node`
        zml_children,
        /// description: A zml element
        ///    location: The location of the `zml_features`
        ///    children: The element's features (a `zml_features`) +
        ///              optionally, the element's inline style declarations (a `zml_styles`) +
        ///              the element's children (a `zml_children`)
        zml_element,
        /// description: A zml text string (a string)
        ///    location: The beginning '\'' or '"' codepoint
        zml_text,
        /// description: A zml directive (an <at-keyword-token> + '(' + arguments + ')')
        ///    location: The location of the <at-keyword-token> that starts this directive
        ///    children: An arbitrary sequence of components
        zml_directive,
        /// description: A zml node
        ///    location: The location of the first child component
        ///    children: A sequence of `zml_directive` + either a `zml_element` or `zml_text`
        zml_node,
        /// description: A zml document
        ///    location: The beginning of the source document
        ///    children: Optionally, a `zml_node`
        zml_document,
    };
};

pub const Ast = struct {
    components: MultiArrayList(Component).Slice,
    debug: Debug = .{},

    pub const Size = u32;

    pub const Index = enum(Size) {
        _,

        pub fn nextSibling(index: Index, ast: Ast) Index {
            return @enumFromInt(ast.components.items(.next_sibling)[@intFromEnum(index)]);
        }

        pub fn tag(index: Index, ast: Ast) Component.Tag {
            return ast.components.items(.tag)[@intFromEnum(index)];
        }

        pub fn location(index: Index, ast: Ast) SourceCode.Location {
            return ast.components.items(.location)[@intFromEnum(index)];
        }

        pub fn extra(index: Index, ast: Ast) Component.Extra {
            return ast.components.items(.extra)[@intFromEnum(index)];
        }

        /// Returns the sequence of the immediate children of `index`.
        pub fn children(index: Index, ast: Ast) Sequence {
            const int = @intFromEnum(index);
            return .{ .start = @enumFromInt(int + 1), .end = index.nextSibling(ast) };
        }
    };

    pub const Sequence = struct {
        start: Index,
        end: Index,

        /// Returns `true` if there are no more components in the sequence.
        pub fn emptyKeepSpaces(sequence: Sequence) bool {
            return (sequence.start == sequence.end);
        }

        /// Returns `true` if there are no more components in the sequence except for spaces.
        pub fn emptySkipSpaces(sequence: *Sequence, ast: Ast) bool {
            _ = sequence.skipSpaces(ast);
            return sequence.emptyKeepSpaces();
        }

        /// Returns the next component in the sequence.
        pub fn nextKeepSpaces(sequence: *Sequence, ast: Ast) ?Index {
            if (sequence.start == sequence.end) return null;
            defer sequence.start = sequence.start.nextSibling(ast);
            return sequence.start;
        }

        /// Returns the next component in the sequence, skipping over leading space components.
        pub fn nextSkipSpaces(sequence: *Sequence, ast: Ast) ?Index {
            _ = sequence.skipSpaces(ast);
            return sequence.nextKeepSpaces(ast);
        }

        /// Returns true if any space components were encountered.
        pub fn skipSpaces(sequence: *Sequence, ast: Ast) bool {
            const initial_index = sequence.start;
            while (sequence.start != sequence.end) {
                assert(@intFromEnum(sequence.start) < @intFromEnum(sequence.end));
                switch (sequence.start.tag(ast)) {
                    .token_whitespace, .token_comments => sequence.start = sequence.start.nextSibling(ast),
                    else => break,
                }
            }
            return sequence.start != initial_index;
        }

        /// Returns to a previously visited point in the sequence.
        /// `index` must be a value that was previously returned from one of the `next*` functions.
        pub fn reset(sequence: *Sequence, index: Index) void {
            assert(@intFromEnum(index) < @intFromEnum(sequence.end));
            sequence.start = index;
        }
    };

    /// Free resources associated with the Ast.
    pub fn deinit(ast: *Ast, allocator: Allocator) void {
        ast.components.deinit(allocator);
    }

    pub fn qualifiedRulePrelude(ast: Ast, qualified_rule_index: Index) Sequence {
        const int = @intFromEnum(qualified_rule_index);
        return .{ .start = @enumFromInt(int + 1), .end = qualified_rule_index.extra(ast).index };
    }

    pub const Debug = struct {
        pub fn print(debug: *const Debug, allocator: Allocator, writer: *std.Io.Writer) !void {
            const ast = @as(*const Ast, @alignCast(@fieldParentPtr("debug", debug))).*;
            try writer.print("Ast (index, component, location, extra), size = {}\n", .{ast.components.len});
            if (ast.components.len == 0) return;

            var stack = zss.Stack(Sequence){};
            defer stack.deinit(allocator);
            const first_index: Index = @enumFromInt(0);
            stack.top = .{ .start = first_index, .end = first_index.nextSibling(ast) };

            while (stack.top) |*top| {
                const index = top.nextKeepSpaces(ast) orelse {
                    _ = stack.pop();
                    continue;
                };

                const component = ast.components.get(@intFromEnum(index));
                const indent = stack.lenExcludingTop() * 4;
                try writer.splatByteAll(' ', indent);
                try writer.print("{} {s} {} ", .{ @intFromEnum(index), @tagName(component.tag), @intFromEnum(component.location) });
                try printExtra(writer, component.tag, component.extra);
                try writer.writeAll("\n");

                const children_sequence = index.children(ast);
                if (!children_sequence.emptyKeepSpaces()) {
                    try stack.push(allocator, children_sequence);
                }
            }
        }

        fn printExtra(writer: *std.Io.Writer, component_tag: Component.Tag, component_extra: Component.Extra) !void {
            switch (component_tag) {
                .token_delim => try writer.print("U+{X}", .{component_extra.codepoint}),
                .token_integer => if (component_extra.integer) |integer| try writer.print("{}", .{integer}),
                .token_number,
                .token_dimension,
                => if (component_extra.number) |number| try writer.print("{d}", .{number}),
                .unit => if (component_extra.unit) |unit| try writer.print("{s}", .{@tagName(unit)}),
                .token_percentage => if (component_extra.number) |number| try writer.print("{d}%", .{number}),
                .declaration_normal,
                .declaration_important,
                .style_block,
                .zml_styles,
                .qualified_rule,
                => try writer.print("{}", .{@intFromEnum(component_extra.index)}),
                .at_rule => if (component_extra.at_rule) |at_rule| try writer.print("@{s}", .{@tagName(at_rule)}),
                else => {},
            }
        }
    };
};
