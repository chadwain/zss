//! Implements the tokenization algorithm of CSS Syntax Level 3.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const zss = @import("../zss.zig");
const hexDigitToNumber = zss.unicode.hexDigitToNumber;
const toLowercase = zss.unicode.latin1ToLowercase;
const CheckedInt = zss.math.CheckedInt;
const Token = zss.syntax.Token;

const u21_max = std.math.maxInt(u21);
const replacement_character: u21 = 0xfffd;
const eof_codepoint = u21_max;

/// A source of `Token`.

// TODO: After parsing, this struct "lingers around" because it is used to get information that isn't stored in `Ast`.
//       A possibly better approach is to store said information into `Ast` (by copying it), eliminating the need for this object.
pub const Source = struct {
    data: []const u8,

    pub const Location = enum(u32) { _ };

    pub fn init(utf8_string: []const u8) error{SourceDataTooLong}!Source {
        if (utf8_string.len > std.math.maxInt(std.meta.Tag(Location))) return error.SourceDataTooLong;
        return Source{ .data = utf8_string };
    }

    pub const Error = error{
        Utf8ExpectedContinuation,
        Utf8OverlongEncoding,
        Utf8EncodesSurrogateHalf,
        Utf8CodepointTooLarge,
        Utf8InvalidStartByte,
        Utf8CodepointTruncated,
    };

    pub fn next(source: Source, location: *Location) Error!Token {
        return try nextToken(source, location);
    }

    /// Asserts that `start` is the location of the start of an ident token.
    pub fn identTokenIterator(source: Source, start: Location) IdentSequenceIterator {
        const next_3, _ = peekCodepoints(3, source, start) catch unreachable;
        assert(codepointsStartAnIdentSequence(next_3));
        return IdentSequenceIterator{ .source = source, .location = start };
    }

    /// Asserts that `start` is the location of the start of an ID hash token.
    pub fn hashIdTokenIterator(source: Source, start: Location) IdentSequenceIterator {
        const hash, const location = peekCodepoint(source, start) catch unreachable;
        assert(hash == '#');
        return IdentSequenceIterator{ .source = source, .location = location };
    }

    /// Asserts that `start` is the location of the start of an at-keyword token.
    pub fn atKeywordTokenIterator(source: Source, start: Location) IdentSequenceIterator {
        const at, const location = peekCodepoint(source, start) catch unreachable;
        assert(at == '@');
        return identTokenIterator(source, location);
    }

    /// Asserts that `start` is the location of the start of a string token.
    pub fn stringTokenIterator(source: Source, start: Location) StringTokenIterator {
        const quote, const location = peekCodepoint(source, start) catch unreachable;
        assert(quote == '"' or quote == '\'');
        return StringTokenIterator{ .source = source, .location = location, .ending_codepoint = quote };
    }

    /// Asserts that `start` is the location of the start of a url token.
    pub fn urlTokenIterator(source: Source, start: Location) UrlTokenIterator {
        const url, var location = peekCodepoints(4, source, start) catch unreachable;
        assert(std.mem.eql(u21, &url, &[4]u21{ 'u', 'r', 'l', '(' }));
        consumeWhitespace(source, &location) catch unreachable;
        return UrlTokenIterator{ .source = source, .location = location };
    }

    pub const CopyMode = union(enum) {
        buffer: []u8,
        allocator: Allocator,
    };

    /// Given that `location` is the location of a <ident-token>, copy that identifier
    pub fn copyIdentifier(source: Source, location: Location, copy_mode: CopyMode) error{OutOfMemory}![]u8 {
        var iterator = identTokenIterator(source, location);
        return copyTokenGeneric(&iterator, copy_mode);
    }

    /// Given that `location` is the location of a <string-token>, copy that string
    pub fn copyString(source: Source, location: Location, copy_mode: CopyMode) error{OutOfMemory}![]u8 {
        var iterator = stringTokenIterator(source, location);
        return copyTokenGeneric(&iterator, copy_mode);
    }

    /// Given that `location` is the location of a <at-keyword-token>, copy that keyword
    pub fn copyAtKeyword(source: Source, location: Location, copy_mode: CopyMode) error{OutOfMemory}![]u8 {
        var iterator = atKeywordTokenIterator(source, location);
        return copyTokenGeneric(&iterator, copy_mode);
    }

    /// Given that `location` is the location of an ID <hash-token>, copy that hash's identifier
    pub fn copyHashId(source: Source, location: Location, copy_mode: CopyMode) error{OutOfMemory}![]u8 {
        var iterator = hashIdTokenIterator(source, location);
        return copyTokenGeneric(&iterator, copy_mode);
    }

    /// Given that `location` is the location of a <url-token>, copy that URL
    pub fn copyUrl(source: Source, location: Location, copy_mode: CopyMode) error{OutOfMemory}![]u8 {
        var iterator = urlTokenIterator(source, location);
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
    pub fn formatIdentToken(source: Source, start: Location) TokenFormatter(identTokenIterator) {
        return formatTokenGeneric(identTokenIterator, source, start);
    }

    /// Asserts that `start` is the location of the start of an ID hash token.
    pub fn formatHashIdToken(source: Source, start: Location) TokenFormatter(hashIdTokenIterator) {
        return formatTokenGeneric(hashIdTokenIterator, source, start);
    }

    /// Asserts that `start` is the location of the start of an at-keyword token.
    pub fn formatAtKeywordToken(source: Source, start: Location) TokenFormatter(atKeywordTokenIterator) {
        return formatTokenGeneric(atKeywordTokenIterator, source, start);
    }

    /// Asserts that `start` is the location of the start of a string token.
    pub fn formatStringToken(source: Source, start: Location) TokenFormatter(stringTokenIterator) {
        return formatTokenGeneric(stringTokenIterator, source, start);
    }

    /// Asserts that `start` is the location of the start of a url token.
    pub fn formatUrlToken(source: Source, start: Location) TokenFormatter(urlTokenIterator) {
        return formatTokenGeneric(urlTokenIterator, source, start);
    }

    fn TokenFormatter(comptime createIterator: anytype) type {
        return struct {
            source: Source,
            location: Location,

            pub fn format(self: @This(), writer: *std.Io.Writer) !void {
                var it = createIterator(self.source, self.location);
                while (it.next()) |codepoint| try writer.print("{u}", .{codepoint});
            }
        };
    }

    fn formatTokenGeneric(comptime createIterator: anytype, source: Source, location: Location) TokenFormatter(createIterator) {
        return TokenFormatter(createIterator){ .source = source, .location = location };
    }

    // TODO: Make other `*Eql` functions, such as stringEql and urlEql.

    /// Given that `location` is the location of an <ident-token>, check if the identifier is equal to `ascii_string`
    /// using case-insensitive matching.
    // TODO: Make it more clear that this only operates on 7-bit ASCII. Alternatively, remove that requirement.
    pub fn identifierEqlIgnoreCase(source: Source, location: Location, ascii_string: []const u8) bool {
        var it = identTokenIterator(source, location);
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
    pub fn mapIdentifierValue(source: Source, location: Location, comptime Type: type, kvs: []const KV(Type)) ?Type {
        // TODO: Use a hash map/trie or something
        for (kvs) |kv| {
            if (identifierEqlIgnoreCase(source, location, kv[0])) return kv[1];
        }
        return null;
    }

    /// Given that `start` is the location of an <ident-token>, if the identifier matches any of the
    /// fields of `Enum` using case-insensitive matching, returns that enum field. If there was no match, null is returned.
    pub fn mapIdentifierEnum(source: Source, start: Location, comptime Enum: type) ?Enum {
        var location = start;
        return consumeIdentSequenceWithMatch(source, &location, Enum) catch unreachable;
    }
};

pub const IdentSequenceIterator = struct {
    source: Source,
    location: Source.Location,

    pub fn next(it: *IdentSequenceIterator) ?u21 {
        return consumeIdentSequenceCodepoint(it.source, &it.location) catch unreachable;
    }
};

pub const StringTokenIterator = struct {
    source: Source,
    location: Source.Location,
    ending_codepoint: u21,

    pub fn next(it: *StringTokenIterator) ?u21 {
        return consumeStringTokenCodepoint(it.source, &it.location, it.ending_codepoint) catch unreachable;
    }
};

/// Used to iterate over <url-token>s (and NOT <bad-url-token>s)
pub const UrlTokenIterator = struct {
    source: Source,
    location: Source.Location,

    pub fn next(it: *UrlTokenIterator) ?u21 {
        return consumeUrlTokenCodepoint(it.source, &it.location) catch unreachable;
    }
};

fn nextCodepoint(source: Source, location: *Source.Location) !u21 {
    var location_int = @intFromEnum(location.*);
    if (location_int == source.data.len) return eof_codepoint;
    defer location.* = @enumFromInt(location_int);

    const unprocessed_codepoint = blk: {
        const len = try std.unicode.utf8ByteSequenceLength(source.data[location_int]);
        if (len > source.data.len - location_int) return error.Utf8CodepointTruncated;
        defer location_int += len;
        break :blk try std.unicode.utf8Decode(source.data[location_int..][0..len]);
    };

    const codepoint: u21 = switch (unprocessed_codepoint) {
        0x00,
        0xD800...0xDBFF,
        0xDC00...0xDFFF,
        => replacement_character,
        '\r' => blk: {
            if (location_int < source.data.len and source.data[location_int] == '\n') {
                location_int += 1;
            }
            break :blk '\n';
        },
        0x0C => '\n',
        0x110000...u21_max => unreachable,
        else => unprocessed_codepoint,
    };

    return codepoint;
}

fn peekCodepoint(source: Source, start: Source.Location) !struct { u21, Source.Location } {
    const codepoint, const location = try peekCodepoints(1, source, start);
    return .{ codepoint[0], location };
}

fn peekCodepoints(comptime amount: std.meta.Tag(Source.Location), source: Source, start: Source.Location) !struct { [amount]u21, Source.Location } {
    var buffer: [amount]u21 = undefined;
    var location = start;
    for (&buffer) |*codepoint| {
        codepoint.* = try nextCodepoint(source, &location);
    }
    return .{ buffer, location };
}

fn moveForwards(location: *Source.Location, amount: std.meta.Tag(Source.Location)) void {
    const int = @intFromEnum(location.*);
    location.* = @enumFromInt(int + amount);
}

fn moveBackwards(location: *Source.Location, amount: std.meta.Tag(Source.Location)) void {
    const int = @intFromEnum(location.*);
    location.* = @enumFromInt(int - amount);
}

fn moveBackwardsNewline(source: Source, location: *Source.Location) void {
    var int = @intFromEnum(location.*) - 1;
    assert(source.data[int] == '\n');
    if (int > 0 and source.data[int - 1] == '\r') int -= 1;
    location.* = @enumFromInt(int);
}

fn nextToken(source: Source, location: *Source.Location) Source.Error!Token {
    const previous_location = location.*;
    const codepoint = try nextCodepoint(source, location);
    switch (codepoint) {
        '/' => {
            const asterisk, _ = try peekCodepoint(source, location.*);
            if (asterisk == '*') {
                moveBackwards(location, 1);
                return consumeComments(source, location);
            } else {
                return .{ .token_delim = codepoint };
            }
        },
        '\n', '\t', ' ' => {
            try consumeWhitespace(source, location);
            return .token_whitespace;
        },
        '"' => return consumeStringToken(source, location, '"'),
        '#' => {
            const next_3, _ = try peekCodepoints(3, source, location.*);
            if (!codepointsStartAHash(next_3[0..2].*)) {
                return .{ .token_delim = '#' };
            }

            const token: Token = if (codepointsStartAnIdentSequence(next_3)) .token_hash_id else .token_hash_unrestricted;
            try consumeIdentSequence(source, location);
            return token;
        },
        '\'' => return consumeStringToken(source, location, '\''),
        '(' => return .token_left_paren,
        ')' => return .token_right_paren,
        '+', '.' => {
            var next_3 = [3]u21{ codepoint, undefined, undefined };
            next_3[1..3].*, _ = try peekCodepoints(2, source, location.*);
            if (codepointsStartANumber(next_3)) {
                moveBackwards(location, 1);
                return consumeNumericToken(source, location);
            } else {
                return .{ .token_delim = codepoint };
            }
        },
        ',' => return .token_comma,
        '-' => {
            var next_3 = [3]u21{ '-', undefined, undefined };
            next_3[1..3].*, const after_cdc = try peekCodepoints(2, source, location.*);
            if (std.mem.eql(u21, next_3[1..3], &[2]u21{ '-', '>' })) {
                location.* = after_cdc;
                return .token_cdc;
            }

            if (codepointsStartANumber(next_3)) {
                moveBackwards(location, 1);
                return consumeNumericToken(source, location);
            } else if (codepointsStartAnIdentSequence(next_3)) {
                moveBackwards(location, 1);
                return consumeIdentLikeToken(source, location);
            } else {
                return .{ .token_delim = codepoint };
            }
        },
        ':' => return .token_colon,
        ';' => return .token_semicolon,
        '<' => {
            const next_3, const after_cdo = try peekCodepoints(3, source, location.*);
            if (std.mem.eql(u21, &next_3, &[3]u21{ '!', '-', '-' })) {
                location.* = after_cdo;
                return .token_cdo;
            } else {
                return .{ .token_delim = codepoint };
            }
        },
        '@' => {
            const next_3, _ = try peekCodepoints(3, source, location.*);

            if (codepointsStartAnIdentSequence(next_3)) {
                const at_rule = try consumeIdentSequenceWithMatch(source, location, Token.AtRule);
                return .{ .token_at_keyword = at_rule };
            } else {
                return .{ .token_delim = codepoint };
            }
        },
        '[' => return .token_left_square,
        '\\' => {
            const first_escaped, _ = try peekCodepoint(source, location.*);
            if (isValidFirstEscapedCodepoint(first_escaped)) {
                moveBackwards(location, 1);
                return consumeIdentLikeToken(source, location);
            } else {
                // NOTE: Parse error
                return .{ .token_delim = codepoint };
            }
        },
        ']' => return .token_right_square,
        '{' => return .token_left_curly,
        '}' => return .token_right_curly,
        '0'...'9' => {
            moveBackwards(location, 1);
            return consumeNumericToken(source, location);
        },
        'A'...'Z',
        'a'...'z',
        '_',
        0x80...0x10FFFF,
        => {
            location.* = previous_location;
            return consumeIdentLikeToken(source, location);
        },
        eof_codepoint => return .token_eof,
        else => return .{ .token_delim = codepoint },
    }
}

fn isIdentStartCodepoint(codepoint: u21) bool {
    switch (codepoint) {
        'A'...'Z',
        'a'...'z',
        '_',
        0x80...0x10FFFF,
        => return true,
        else => return false,
    }
}

fn isValidFirstEscapedCodepoint(codepoint: u21) bool {
    return codepoint != '\n';
}

fn codepointsStartAnIdentSequence(codepoints: [3]u21) bool {
    return switch (codepoints[0]) {
        '-' => isIdentStartCodepoint(codepoints[1]) or
            (codepoints[1] == '-') or
            (codepoints[1] == '\\' and isValidFirstEscapedCodepoint(codepoints[2])),

        'A'...'Z',
        'a'...'z',
        '_',
        0x80...0x10FFFF,
        => true,

        '\\' => isValidFirstEscapedCodepoint(codepoints[1]),

        else => false,
    };
}

fn codepointsStartANumber(codepoints: [3]u21) bool {
    switch (codepoints[0]) {
        '+', '-' => switch (codepoints[1]) {
            '0'...'9' => return true,
            '.' => switch (codepoints[2]) {
                '0'...'9' => return true,
                else => return false,
            },
            else => return false,
        },
        '.' => switch (codepoints[1]) {
            '0'...'9' => return true,
            else => return false,
        },
        '0'...'9' => return true,
        else => return false,
    }
}

fn consumeComments(source: Source, location: *Source.Location) !Token {
    outer: while (true) {
        const next_2, _ = try peekCodepoints(2, source, location.*);
        if (!std.mem.eql(u21, &next_2, &[2]u21{ '/', '*' })) break;

        while (true) {
            const codepoint = try nextCodepoint(source, location);
            switch (codepoint) {
                '*' => {
                    const slash, const comment_end = try peekCodepoint(source, location.*);
                    if (slash == '/') {
                        location.* = comment_end;
                        break;
                    }
                },
                eof_codepoint => {
                    // NOTE: Parse error
                    break :outer;
                },
                else => {},
            }
        }
    }
    return .token_comments;
}

fn consumeWhitespace(source: Source, location: *Source.Location) !void {
    while (true) {
        const previous_location = location.*;
        const codepoint = try nextCodepoint(source, location);
        switch (codepoint) {
            '\n', '\t', ' ' => {},
            else => {
                location.* = previous_location;
                return;
            },
        }
    }
}

fn consumeStringToken(source: Source, location: *Source.Location, ending_codepoint: u21) !Token {
    while (consumeStringTokenCodepoint(source, location, ending_codepoint)) |codepoint| {
        if (codepoint == null) break;
    } else |err| {
        switch (err) {
            error.BadStringToken => return .token_bad_string,
            else => |e| return e,
        }
    }

    const final = nextCodepoint(source, location) catch unreachable;
    assert(final == ending_codepoint or final == eof_codepoint);
    return .token_string;
}

fn consumeStringTokenCodepoint(source: Source, location: *Source.Location, ending_codepoint: u21) !?u21 {
    const codepoint = try nextCodepoint(source, location);
    switch (codepoint) {
        '\n' => {
            moveBackwardsNewline(source, location);
            // NOTE: Parse error
            return error.BadStringToken;
        },
        '\\' => {
            const first_escaped = try nextCodepoint(source, location);
            switch (first_escaped) {
                '\n' => return '\n',
                eof_codepoint => {
                    // NOTE: Parse error
                    return null;
                },
                else => return try consumeEscapedCodepoint(source, location, first_escaped),
            }
        },
        eof_codepoint => {
            // NOTE: Parse error
            return null;
        },
        else => {
            if (codepoint == ending_codepoint) {
                // Move backwards so that this function can be called repeatedly and always return null.
                moveBackwards(location, 1);
                return null;
            } else {
                return codepoint;
            }
        },
    }
}

fn consumeEscapedCodepoint(source: Source, location: *Source.Location, first_escaped: u21) !u21 {
    return switch (first_escaped) {
        '0'...'9', 'A'...'F', 'a'...'f' => blk: {
            var result: u21 = hexDigitToNumber(first_escaped) catch unreachable;
            for (0..5) |_| {
                const previous_location = location.*;
                const digit = try nextCodepoint(source, location);
                switch (digit) {
                    '0'...'9', 'A'...'F', 'a'...'f' => {
                        result = result *| 16 +| (hexDigitToNumber(digit) catch unreachable);
                    },
                    else => {
                        location.* = previous_location;
                        break;
                    },
                }
            }

            const whitespace, const after_whitespace = try peekCodepoint(source, location.*);
            switch (whitespace) {
                '\n', '\t', ' ' => location.* = after_whitespace,
                else => {},
            }

            break :blk switch (result) {
                0x00,
                0xD800...0xDBFF,
                0xDC00...0xDFFF,
                0x110000...u21_max,
                => replacement_character,
                else => result,
            };
        },
        eof_codepoint => replacement_character, // NOTE: Parse error
        '\n' => unreachable,
        else => first_escaped,
    };
}

fn consumeNumericToken(source: Source, location: *Source.Location) !Token {
    const value = try consumeNumber(source, location);
    const next_3, _ = try peekCodepoints(3, source, location.*);

    if (codepointsStartAnIdentSequence(next_3)) {
        const unit_location = location.*;
        const unit = try consumeIdentSequenceWithMatch(source, location, Token.Unit);
        return .{
            .token_dimension = .{
                .number = switch (value) {
                    .integer => |integer| if (integer) |int| @floatFromInt(int) else null,
                    .number => |number| number,
                },
                .unit = unit,
                .unit_location = unit_location,
            },
        };
    }

    if (next_3[0] == '%') {
        moveForwards(location, 1);
        return .{
            .token_percentage = switch (value) {
                .integer => |integer| if (integer) |int| @as(Token.Float, @floatFromInt(int)) / 100.0 else null,
                .number => |number| if (number) |num| num / 100.0 else null,
            },
        };
    }

    return switch (value) {
        .integer => |integer| .{ .token_integer = integer },
        .number => |number| .{ .token_number = number },
    };
}

const ConsumeNumber = union(enum) {
    integer: ?i32,
    number: ?Token.Float,
};

const NumberBuffer = struct {
    data: [64]u8 = undefined,
    len: u8 = 0,

    fn append(buffer: *NumberBuffer, char: u8) void {
        defer buffer.len +|= 1;
        if (buffer.len >= buffer.data.len) return;
        buffer.data[buffer.len] = char;
    }

    fn overflow(buffer: NumberBuffer) bool {
        return buffer.len > buffer.data.len;
    }

    fn slice(buffer: NumberBuffer) []const u8 {
        return buffer.data[0..buffer.len];
    }
};

fn consumeNumber(source: Source, location: *Source.Location) !ConsumeNumber {
    var number_type: std.meta.Tag(ConsumeNumber) = .integer;
    var is_negative: bool = undefined;
    var buffer = NumberBuffer{};

    const start = location.*;
    const leading_sign = try nextCodepoint(source, location);
    if (leading_sign == '+') {
        is_negative = false;
        buffer.append('+');
    } else if (leading_sign == '-') {
        is_negative = true;
        buffer.append('-');
    } else {
        location.* = start;
        is_negative = false;
    }

    try consumeZeroes(source, location);
    var integral_part = try consumeDigits(source, location, &buffer);

    {
        const next_2, _ = try peekCodepoints(2, source, location.*);
        if (next_2[0] == '.' and next_2[1] >= '0' and next_2[1] <= '9') {
            number_type = .number;
            buffer.append('.');
            moveForwards(location, 1);
            // TODO: Skip trailing zeroes
            _ = try consumeDigits(source, location, &buffer);
        }
    }

    {
        const e, const after_e = try peekCodepoint(source, location.*);
        if (e == 'e' or e == 'E') {
            const exponent_sign, const after_exponent_sign = try peekCodepoint(source, after_e);
            const before_exponent_digits = if (exponent_sign == '+' or exponent_sign == '-') after_exponent_sign else after_e;

            const first_digit, _ = try peekCodepoint(source, before_exponent_digits);
            if (first_digit >= '0' and first_digit <= '9') {
                number_type = .number;
                buffer.append('e');
                if (before_exponent_digits == after_exponent_sign) {
                    buffer.append(@intCast(exponent_sign));
                }
                location.* = before_exponent_digits;
                try consumeZeroes(source, location);
                _ = try consumeDigits(source, location, &buffer);
            }
        }
    }

    switch (number_type) {
        .integer => {
            if (is_negative) integral_part.negate();
            const integer = integral_part.unwrap() catch return .{ .integer = null };
            return .{ .integer = integer };
        },
        .number => {
            if (buffer.overflow()) return .{ .number = null };
            var float = std.fmt.parseFloat(Token.Float, buffer.slice()) catch |err| switch (err) {
                error.InvalidCharacter => unreachable,
            };
            // TODO: Preserve negative zero?
            if (std.math.isPositiveZero(float) or std.math.isNegativeZero(float)) {
                float = 0.0;
            } else if (!std.math.isNormal(float)) {
                return .{ .number = null };
            }
            return .{ .number = float };
        },
    }
}

fn consumeZeroes(source: Source, location: *Source.Location) !void {
    while (true) {
        const previous_location = location.*;
        switch (try nextCodepoint(source, location)) {
            '0' => {},
            else => {
                location.* = previous_location;
                return;
            },
        }
    }
}

fn consumeDigits(source: Source, location: *Source.Location, buffer: *NumberBuffer) !CheckedInt(i32) {
    var value: CheckedInt(i32) = .init(0);
    while (true) {
        const previous_location = location.*;
        const codepoint = try nextCodepoint(source, location);
        switch (codepoint) {
            '0'...'9' => {
                value.multiply(10);
                value.add(codepoint - '0');
                buffer.append(@intCast(codepoint));
            },
            else => {
                location.* = previous_location;
                return value;
            },
        }
    }
}

fn consumeIdentSequenceCodepoint(source: Source, location: *Source.Location) !?u21 {
    const previous_location = location.*;
    const codepoint = try nextCodepoint(source, location);
    switch (codepoint) {
        '\\' => {
            const first_escaped = try nextCodepoint(source, location);
            if (isValidFirstEscapedCodepoint(first_escaped)) {
                return try consumeEscapedCodepoint(source, location, first_escaped);
            } else {
                location.* = previous_location;
                return null;
            }
        },
        '0'...'9',
        'A'...'Z',
        'a'...'z',
        '-',
        '_',
        0x80...0x10FFFF,
        => return codepoint,
        else => {
            location.* = previous_location;
            return null;
        },
    }
}

fn consumeIdentSequence(source: Source, location: *Source.Location) !void {
    while (try consumeIdentSequenceCodepoint(source, location)) |_| {}
}

fn ComptimePrefixTree(comptime Enum: type) type {
    const Node = struct {
        skip: u16,
        character: u7,
        field_index: ?usize,
    };

    const fields = @typeInfo(Enum).@"enum".fields;
    @setEvalBranchQuota(fields.len * 200);
    const nodes = comptime nodes: {
        const Interval = struct {
            begin: u16,
            end: u16,

            fn next(interval: *@This(), nodes: []const Node) ?u16 {
                if (interval.begin == interval.end) return null;
                defer interval.begin += nodes[interval.begin].skip;
                return interval.begin;
            }
        };

        const my = struct {
            fn BoundedArray(comptime T: type, comptime max: comptime_int) type {
                return struct {
                    buffer: [max]T = undefined,
                    len: u16 = 0,

                    fn slice(self: *@This()) []T {
                        return self.buffer[0..self.len];
                    }

                    fn append(self: *@This(), item: T) void {
                        defer self.len += 1;
                        self.buffer[self.len] = item;
                    }

                    fn insertManyAsSlice(self: *@This(), insertion_index: u16, n: u16) []T {
                        defer self.len += n;
                        std.mem.copyBackwards(Node, self.buffer[insertion_index + n .. self.len + n], self.buffer[insertion_index..self.len]);
                        return self.buffer[insertion_index..][0..n];
                    }
                };
            }
        };

        const max_tree_size, const max_stack_size = blk: {
            var sum = 0;
            var longest = 0;
            for (fields) |field| {
                sum += field.name.len;
                longest = @max(longest, field.name.len);
            }
            break :blk .{ 1 + sum, 1 + longest };
        };
        var nodes = my.BoundedArray(Node, max_tree_size){};
        var stack = my.BoundedArray(u16, max_stack_size){};
        nodes.append(.{ .skip = 1, .character = 0, .field_index = null });
        for (fields, 0..) |field, field_index| {
            assert(field.value == field_index);
            stack.len = 0;
            stack.append(0);
            var interval = Interval{ .begin = 1, .end = nodes.buffer[0].skip };

            character_loop: for (field.name, 0..) |character, character_index| {
                const normalized = switch (character) {
                    'A'...'Z' => character - 'A' + 'a',
                    0x80...0xFF => @compileError(std.fmt.comptimePrint("Field name '{s}' contains non-ascii characters", .{field.name})),
                    else => character,
                };
                const insertion_index = while (interval.next(nodes.slice())) |index| {
                    switch (std.math.order(normalized, nodes.buffer[index].character)) {
                        .lt => break index,
                        .gt => {},
                        .eq => {
                            if (character_index == field.name.len - 1) {
                                assert(nodes.buffer[index].field_index == null);
                                nodes.buffer[index].field_index = field_index;
                                break :character_loop;
                            } else {
                                stack.append(index);
                                interval = .{ .begin = index + 1, .end = index + nodes.buffer[index].skip };
                                continue :character_loop;
                            }
                        },
                    }
                } else interval.end;

                const new = nodes.insertManyAsSlice(insertion_index, @intCast(field.name.len - character_index));
                for (new, 0..) |*node, i| {
                    node.* = .{
                        .skip = new.len - i,
                        .character = field.name[character_index + i],
                        .field_index = null,
                    };
                }
                new[new.len - 1].field_index = field_index;
                for (stack.slice()) |index| {
                    nodes.buffer[index].skip += new.len;
                }
                break :character_loop;
            } else unreachable;
        }

        break :nodes nodes.buffer[0..nodes.len].*;
    };

    return struct {
        const Index = std.math.IntFittingRange(0, nodes.len);
        const next_siblings = blk: {
            var result: [nodes.len]Index = undefined;
            for (nodes, &result, 0..) |node, *out, index| out.* = index + node.skip;
            break :blk result;
        };
        const characters = blk: {
            var result: [nodes.len]u8 = undefined;
            for (nodes, &result) |node, *out| out.* = node.character;
            break :blk result;
        };
        const leaves = blk: {
            var result: [fields.len]Index = undefined;
            for (nodes, 0..) |node, i| {
                if (node.field_index) |field_index| {
                    result[field_index] = i;
                }
            }
            break :blk result;
        };

        const Self = @This();
        index: Index = 0,

        fn nextCodepoint(self: *Self, codepoint: u21) void {
            if (self.index == nodes.len) return;
            const normalized: u8 = switch (codepoint) {
                'A'...'Z' => @intCast(codepoint - 'A' + 'a'),
                0x80...u21_max => 0xFF,
                else => @intCast(codepoint),
            };
            const end = next_siblings[self.index];
            self.index += 1;
            while (self.index < end) : (self.index = next_siblings[self.index]) {
                if (normalized == characters[self.index]) return;
            }
            self.index = nodes.len;
        }

        fn findMatch(self: Self) ?Enum {
            if (self.index == nodes.len) return null;
            const field_index = std.mem.indexOfScalar(Index, &leaves, self.index) orelse return null;
            return @enumFromInt(field_index);
        }
    };
}

fn consumeIdentSequenceWithMatch(source: Source, location: *Source.Location, comptime Enum: type) !?Enum {
    var prefix_tree = ComptimePrefixTree(Enum){};
    while (try consumeIdentSequenceCodepoint(source, location)) |codepoint| {
        prefix_tree.nextCodepoint(codepoint);
    }
    return prefix_tree.findMatch();
}

fn consumeIdentLikeToken(source: Source, location: *Source.Location) !Token {
    const is_url = try consumeIdentSequenceWithMatch(source, location, enum { url });
    const after_ident = location.*;
    const left_paren = try nextCodepoint(source, location);
    if (left_paren != '(') {
        location.* = after_ident;
        return .token_ident;
    }
    if (is_url == null) return .token_function;

    const after_left_paren = location.*;
    try consumeWhitespace(source, location);
    const quote, _ = try peekCodepoint(source, location.*);
    switch (quote) {
        '\'', '"' => {
            location.* = after_left_paren;
            return .token_function;
        },
        else => return consumeUrlToken(source, location),
    }
}

fn consumeUrlToken(source: Source, location: *Source.Location) !Token {
    // Not consuming whitespace - this is handled already by consumeIdentLikeToken.
    // try consumeWhitespace(source, location);

    while (consumeUrlTokenCodepoint(source, location)) |codepoint| {
        if (codepoint == null) break;
    } else |err| {
        switch (err) {
            error.BadUrlToken => return consumeBadUrl(source, location),
            else => |e| return e,
        }
    }

    switch (nextCodepoint(source, location) catch unreachable) {
        ')', eof_codepoint => {},
        else => unreachable,
    }
    return .token_url;
}

fn consumeUrlTokenCodepoint(source: Source, location: *Source.Location) !?u21 {
    const codepoint = try nextCodepoint(source, location);
    switch (codepoint) {
        ')' => {
            // Move backwards so that this function can be called repeatedly and always return null.
            moveBackwards(location, 1);
            return null;
        },
        '\n', '\t', ' ' => {
            try consumeWhitespace(source, location);
            const right_paren_or_eof, _ = try peekCodepoint(source, location.*);
            switch (right_paren_or_eof) {
                eof_codepoint => {
                    // NOTE: Parse error
                    return null;
                },
                ')' => return null,
                else => return error.BadUrlToken,
            }
        },
        '"', '\'', '(', 0x00...0x08, 0x0B, 0x0E...0x1F, 0x7F => {
            // NOTE: Parse error
            return error.BadUrlToken;
        },
        '\\' => {
            const previous_location = location.*;
            const first_escaped = try nextCodepoint(source, location);
            if (isValidFirstEscapedCodepoint(first_escaped)) {
                return try consumeEscapedCodepoint(source, location, first_escaped);
            } else {
                // NOTE: Parse error
                location.* = previous_location;
                return error.BadUrlToken;
            }
        },
        eof_codepoint => {
            // NOTE: Parse error
            return null;
        },
        else => return codepoint,
    }
}

fn consumeBadUrl(source: Source, location: *Source.Location) !Token {
    while (true) {
        const codepoint = try nextCodepoint(source, location);
        switch (codepoint) {
            ')', eof_codepoint => break,
            '\\' => {
                const previous_location = location.*;
                const first_escaped = try nextCodepoint(source, location);
                if (isValidFirstEscapedCodepoint(first_escaped)) {
                    _ = try consumeEscapedCodepoint(source, location, first_escaped);
                } else {
                    location.* = previous_location;
                }
            },
            else => {},
        }
    }
    return .token_bad_url;
}

fn codepointsStartAHash(codepoints: [2]u21) bool {
    return switch (codepoints[0]) {
        '0'...'9',
        'A'...'Z',
        'a'...'z',
        '-',
        '_',
        0x80...0x10FFFF,
        => true,
        '\\' => isValidFirstEscapedCodepoint(codepoints[1]),
        else => false,
    };
}

// TODO: Replace with fuzz test
test "tokenization" {
    const input =
        \\@charset "utf-8";
        \\#good-id
        \\#1bad-id
        \\
        \\body {
        \\    rule: value url(foo) function(asdf);
        \\}
        \\
        \\/* comments here */
        \\end
    ;
    const source = try Source.init(input);
    const expected = [_]Token{
        .{ .token_at_keyword = null },
        .token_whitespace,
        .token_string,
        .token_semicolon,
        .token_whitespace,
        .token_hash_id,
        .token_whitespace,
        .token_hash_unrestricted,
        .token_whitespace,
        .token_ident,
        .token_whitespace,
        .token_left_curly,
        .token_whitespace,
        .token_ident,
        .token_colon,
        .token_whitespace,
        .token_ident,
        .token_whitespace,
        .token_url,
        .token_whitespace,
        .token_function,
        .token_ident,
        .token_right_paren,
        .token_semicolon,
        .token_whitespace,
        .token_right_curly,
        .token_whitespace,
        .token_comments,
        .token_whitespace,
        .token_ident,
        .token_eof,
    };

    var location: Source.Location = @enumFromInt(0);
    var i: usize = 0;
    while (true) {
        if (i >= expected.len) return error.TestFailure;
        const token = try nextToken(source, &location);
        try std.testing.expectEqual(expected[i], token);
        if (token == .token_eof) break;
        i += 1;
    }
}
