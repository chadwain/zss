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

    pub fn init(utf8_string: []const u8) !Source {
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
        const next_token = try nextToken(source, location.*);
        location.* = next_token.next_location;
        return next_token.token;
    }

    /// Asserts that `start` is the location of the start of an ident token.
    pub fn identTokenIterator(source: Source, start: Location) IdentSequenceIterator {
        var next_3: [3]u21 = undefined;
        _ = readCodepoints(source, start, &next_3) catch unreachable;
        assert(codepointsStartAnIdentSequence(next_3));
        return IdentSequenceIterator{ .source = source, .location = start };
    }

    /// Asserts that `start` is the location of the start of an ID hash token.
    pub fn hashIdTokenIterator(source: Source, start: Location) IdentSequenceIterator {
        const hash = nextCodepoint(source, start) catch unreachable;
        assert(hash.codepoint == '#');
        return IdentSequenceIterator{ .source = source, .location = hash.next_location };
    }

    /// Asserts that `start` is the location of the start of a at-keyword token.
    pub fn atKeywordTokenIterator(source: Source, start: Location) IdentSequenceIterator {
        const at = nextCodepoint(source, start) catch unreachable;
        assert(at.codepoint == '@');
        return identTokenIterator(source, at.next_location);
    }

    /// Asserts that `start` is the location of the start of a string token.
    pub fn stringTokenIterator(source: Source, start: Location) StringTokenIterator {
        const quote = nextCodepoint(source, start) catch unreachable;
        assert(quote.codepoint == '"' or quote.codepoint == '\'');
        return StringTokenIterator{ .source = source, .location = quote.next_location, .ending_codepoint = quote.codepoint };
    }

    /// `start` must be the location of a `token_url`.
    pub fn urlTokenIterator(source: Source, start: Location) UrlTokenIterator {
        var next_4: [4]u21 = undefined;
        var location = readCodepoints(source, start, &next_4) catch unreachable;
        assert(std.mem.eql(u21, &next_4, &[4]u21{ 'u', 'r', 'l', '(' }));
        location = consumeWhitespace(source, location) catch unreachable;
        return UrlTokenIterator{ .source = source, .location = location };
    }

    pub const CopyMode = union(enum) {
        buffer: []u8,
        allocator: Allocator,
    };

    /// Given that `location` is the location of a <ident-token>, copy that identifier
    pub fn copyIdentifier(source: Source, location: Location, copy_mode: CopyMode) ![]u8 {
        var iterator = identTokenIterator(source, location);
        return copyTokenGeneric(&iterator, copy_mode);
    }

    /// Given that `location` is the location of a <string-token>, copy that string
    pub fn copyString(source: Source, location: Location, copy_mode: CopyMode) ![]u8 {
        var iterator = stringTokenIterator(source, location);
        return copyTokenGeneric(&iterator, copy_mode);
    }

    /// Given that `location` is the location of a <at-keyword-token>, copy that keyword
    pub fn copyAtKeyword(source: Source, location: Location, copy_mode: CopyMode) ![]u8 {
        var iterator = atKeywordTokenIterator(source, location);
        return copyTokenGeneric(&iterator, copy_mode);
    }

    /// Given that `location` is the location of an ID <hash-token>, copy that hash's identifier
    pub fn copyHashId(source: Source, location: Location, copy_mode: CopyMode) ![]u8 {
        var iterator = hashIdTokenIterator(source, location);
        return copyTokenGeneric(&iterator, copy_mode);
    }

    /// Given that `location` is the location of a <url-token>, copy that URL
    pub fn copyUrl(source: Source, location: Location, copy_mode: CopyMode) ![]u8 {
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

    /// Given that `location` is the location of an <ident-token>, if the identifier matches any of the
    /// fields of `Enum` using case-insensitive matching, returns that enum field. If there was no match, null is returned.
    pub fn matchIdentifierEnum(source: Source, location: Location, comptime Enum: type) ?Enum {
        const result, _ = consumeIdentSequenceWithMatch(source, location, Enum) catch unreachable;
        return result;
    }
};

pub const IdentSequenceIterator = struct {
    source: Source,
    location: Source.Location,

    pub fn next(it: *IdentSequenceIterator) ?u21 {
        return consumeIdentSequenceCodepoint(it.source, &it.location) catch unreachable;
    }

    pub fn format(it: *IdentSequenceIterator, writer: *std.io.Writer) std.io.Writer.Error!void {
        while (it.next()) |codepoint| try writer.print("{u}", .{codepoint});
    }
};

pub const StringTokenIterator = struct {
    source: Source,
    location: Source.Location,
    ending_codepoint: u21,

    pub fn next(it: *StringTokenIterator) ?u21 {
        return consumeStringTokenCodepoint(it.source, &it.location, it.ending_codepoint) catch unreachable;
    }

    pub fn format(it: *StringTokenIterator, writer: *std.io.Writer) std.io.Writer.Error!void {
        while (it.next()) |codepoint| try writer.print("{u}", .{codepoint});
    }
};

/// Used to iterate over <url-token>s (and NOT <bad-url-token>s)
pub const UrlTokenIterator = struct {
    source: Source,
    location: Source.Location,

    pub fn next(it: *UrlTokenIterator) ?u21 {
        return consumeUrlTokenCodepoint(it.source, &it.location) catch unreachable;
    }

    pub fn format(it: *UrlTokenIterator, writer: *std.io.Writer) std.io.Writer.Error!void {
        while (it.next()) |codepoint| try writer.print("{u}", .{codepoint});
    }
};

const NextCodepoint = struct { next_location: Source.Location, codepoint: u21 };

fn nextCodepoint(source: Source, location: Source.Location) !NextCodepoint {
    if (@intFromEnum(location) == source.data.len) return NextCodepoint{ .next_location = location, .codepoint = eof_codepoint };

    var next_location = @intFromEnum(location);
    const unprocessed_codepoint = blk: {
        const len = try std.unicode.utf8ByteSequenceLength(source.data[next_location]);
        if (source.data.len - next_location < len) return error.Utf8CodepointTruncated;
        defer next_location += len;
        break :blk try std.unicode.utf8Decode(source.data[next_location..][0..len]);
    };

    const codepoint: u21 = switch (unprocessed_codepoint) {
        0x00,
        0xD800...0xDBFF,
        0xDC00...0xDFFF,
        => replacement_character,
        '\r' => blk: {
            if (next_location < source.data.len and source.data[next_location] == '\n') {
                next_location += 1;
            }
            break :blk '\n';
        },
        0x0C => '\n',
        0x110000...u21_max => unreachable,
        else => unprocessed_codepoint,
    };

    return NextCodepoint{ .next_location = @enumFromInt(next_location), .codepoint = codepoint };
}

fn readCodepoints(source: Source, start: Source.Location, buffer: []u21) !Source.Location {
    var location = start;
    for (buffer) |*codepoint| {
        const next_ = try nextCodepoint(source, location);
        codepoint.* = next_.codepoint;
        location = next_.next_location;
    }
    return location;
}

const NextToken = struct {
    token: Token,
    next_location: Source.Location,
};

fn nextToken(source: Source, location: Source.Location) Source.Error!NextToken {
    const next = try nextCodepoint(source, location);
    switch (next.codepoint) {
        '/' => {
            const asterisk = try nextCodepoint(source, next.next_location);
            if (asterisk.codepoint == '*') {
                return consumeComments(source, location);
            } else {
                return NextToken{ .token = .{ .token_delim = next.codepoint }, .next_location = next.next_location };
            }
        },
        '\n', '\t', ' ' => {
            const after_whitespace = try consumeWhitespace(source, next.next_location);
            return NextToken{ .token = .token_whitespace, .next_location = after_whitespace };
        },
        '"' => return consumeStringToken(source, next.next_location, '"'),
        '#' => return numberSign(source, next.next_location),
        '\'' => return consumeStringToken(source, next.next_location, '\''),
        '(' => return NextToken{ .token = .token_left_paren, .next_location = next.next_location },
        ')' => return NextToken{ .token = .token_right_paren, .next_location = next.next_location },
        '+', '.' => {
            var next_3 = [3]u21{ next.codepoint, undefined, undefined };
            _ = try readCodepoints(source, next.next_location, next_3[1..3]);
            if (codepointsStartANumber(next_3)) {
                return consumeNumericToken(source, location);
            } else {
                return NextToken{ .token = .{ .token_delim = next.codepoint }, .next_location = next.next_location };
            }
        },
        ',' => return NextToken{ .token = .token_comma, .next_location = next.next_location },
        '-' => {
            var next_3 = [3]u21{ '-', undefined, undefined };
            const after_cdc = try readCodepoints(source, next.next_location, next_3[1..3]);
            if (std.mem.eql(u21, next_3[1..3], &[2]u21{ '-', '>' })) {
                return NextToken{ .token = .token_cdc, .next_location = after_cdc };
            }

            if (codepointsStartANumber(next_3)) {
                return consumeNumericToken(source, location);
            } else if (codepointsStartAnIdentSequence(next_3)) {
                return consumeIdentLikeToken(source, location);
            } else {
                return NextToken{ .token = .{ .token_delim = next.codepoint }, .next_location = next.next_location };
            }
        },
        ':' => return NextToken{ .token = .token_colon, .next_location = next.next_location },
        ';' => return NextToken{ .token = .token_semicolon, .next_location = next.next_location },
        '<' => {
            var next_3: [3]u21 = undefined;
            const after_cdo = try readCodepoints(source, next.next_location, &next_3);
            if (std.mem.eql(u21, &next_3, &[3]u21{ '!', '-', '-' })) {
                return NextToken{ .token = .token_cdo, .next_location = after_cdo };
            } else {
                return NextToken{ .token = .{ .token_delim = next.codepoint }, .next_location = next.next_location };
            }
        },
        '@' => {
            var next_3: [3]u21 = undefined;
            _ = try readCodepoints(source, next.next_location, &next_3);

            if (codepointsStartAnIdentSequence(next_3)) {
                const at_rule, const after_ident = try consumeIdentSequenceWithMatch(source, next.next_location, Token.AtRule);
                return NextToken{ .token = .{ .token_at_keyword = at_rule }, .next_location = after_ident };
            } else {
                return NextToken{ .token = .{ .token_delim = next.codepoint }, .next_location = next.next_location };
            }
        },
        '[' => return NextToken{ .token = .token_left_square, .next_location = next.next_location },
        '\\' => {
            const first_escaped = try nextCodepoint(source, next.next_location);
            if (isValidFirstEscapedCodepoint(first_escaped.codepoint)) {
                return consumeIdentLikeToken(source, location);
            } else {
                // NOTE: Parse error
                return NextToken{ .token = .{ .token_delim = next.codepoint }, .next_location = next.next_location };
            }
        },
        ']' => return NextToken{ .token = .token_right_square, .next_location = next.next_location },
        '{' => return NextToken{ .token = .token_left_curly, .next_location = next.next_location },
        '}' => return NextToken{ .token = .token_right_curly, .next_location = next.next_location },
        '0'...'9' => return consumeNumericToken(source, location),
        'A'...'Z',
        'a'...'z',
        '_',
        0x80...0x10FFFF,
        => return consumeIdentLikeToken(source, location),
        eof_codepoint => return NextToken{ .token = .token_eof, .next_location = next.next_location },
        else => return NextToken{ .token = .{ .token_delim = next.codepoint }, .next_location = next.next_location },
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

fn consumeComments(source: Source, start: Source.Location) !NextToken {
    var location = start;
    outer: while (true) {
        var next_2: [2]u21 = undefined;
        const comment_start = try readCodepoints(source, location, &next_2);
        if (std.mem.eql(u21, &next_2, &[2]u21{ '/', '*' })) {
            location = comment_start;
            while (true) {
                const next = try nextCodepoint(source, location);
                switch (next.codepoint) {
                    '*' => {
                        const comment_end = try nextCodepoint(source, next.next_location);
                        if (comment_end.codepoint == '/') {
                            location = comment_end.next_location;
                            break;
                        }
                    },
                    eof_codepoint => {
                        // NOTE: Parse error
                        break :outer;
                    },
                    else => {},
                }
                location = next.next_location;
            }
        } else {
            break;
        }
    }
    return NextToken{ .token = .token_comments, .next_location = location };
}

fn consumeWhitespace(source: Source, start: Source.Location) !Source.Location {
    var location = start;
    while (true) {
        const next = try nextCodepoint(source, location);
        switch (next.codepoint) {
            '\n', '\t', ' ' => location = next.next_location,
            else => return location,
        }
    }
}

fn consumeStringToken(source: Source, after_quote: Source.Location, ending_codepoint: u21) !NextToken {
    var location = after_quote;
    while (consumeStringTokenCodepoint(source, &location, ending_codepoint) catch |err| switch (err) {
        error.BadStringToken => return .{ .token = .token_bad_string, .next_location = location },
        else => |e| return e,
    }) |_| {}

    return NextToken{ .token = .token_string, .next_location = (nextCodepoint(source, location) catch unreachable).next_location };
}

fn consumeStringTokenCodepoint(source: Source, location: *Source.Location, ending_codepoint: u21) !?u21 {
    const next = try nextCodepoint(source, location.*);
    sw: switch (next.codepoint) {
        '\n' => {
            // NOTE: Parse error
            return error.BadStringToken;
        },
        '\\' => {
            const first_escaped = try nextCodepoint(source, next.next_location);
            if (first_escaped.codepoint == '\n') {
                location.* = first_escaped.next_location;
                return '\n';
            } else if (first_escaped.codepoint == eof_codepoint) {
                location.* = next.next_location;
                continue :sw eof_codepoint;
            } else {
                const escaped = (try consumeEscapedCodepoint(source, first_escaped));
                location.* = escaped.next_location;
                return escaped.codepoint;
            }
        },
        eof_codepoint => {
            // NOTE: Parse error
            return null;
        },
        else => {
            if (next.codepoint == ending_codepoint) {
                return null;
            } else {
                location.* = next.next_location;
                return next.codepoint;
            }
        },
    }
}

fn consumeEscapedCodepoint(source: Source, first_escaped: NextCodepoint) !NextCodepoint {
    var location = first_escaped.next_location;
    const codepoint = switch (first_escaped.codepoint) {
        '0'...'9', 'A'...'F', 'a'...'f' => blk: {
            var result: u21 = hexDigitToNumber(first_escaped.codepoint) catch unreachable;
            var count: u3 = 0;
            while (count < 5) : (count += 1) {
                const next = try nextCodepoint(source, location);
                switch (next.codepoint) {
                    '0'...'9', 'A'...'F', 'a'...'f' => {
                        result = result *| 16 +| (hexDigitToNumber(next.codepoint) catch unreachable);
                        location = next.next_location;
                    },
                    else => break,
                }
            }

            const whitespace = try nextCodepoint(source, location);
            switch (whitespace.codepoint) {
                '\n', '\t', ' ' => location = whitespace.next_location,
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
        else => first_escaped.codepoint,
    };

    return NextCodepoint{ .codepoint = codepoint, .next_location = location };
}

fn consumeNumericToken(source: Source, start: Source.Location) !NextToken {
    const result = try consumeNumber(source, start);

    var next_3: [3]u21 = undefined;
    _ = try readCodepoints(source, result.after_number, &next_3);

    if (codepointsStartAnIdentSequence(next_3)) {
        const unit, const after_unit = try consumeIdentSequenceWithMatch(source, result.after_number, Token.Unit);
        const token: Token = .{
            .token_dimension = .{
                .number = switch (result.value) {
                    .integer => |integer| if (integer) |int| @floatFromInt(int) else null,
                    .number => |number| number,
                },
                .unit = unit,
                .unit_location = result.after_number,
            },
        };
        return NextToken{ .token = token, .next_location = after_unit };
    }

    const percent_sign = try nextCodepoint(source, result.after_number);
    if (percent_sign.codepoint == '%') {
        const token: Token = .{
            .token_percentage = switch (result.value) {
                .integer => |integer| if (integer) |int| @as(Token.Float, @floatFromInt(int)) / 100.0 else null,
                .number => |number| if (number) |num| num / 100.0 else null,
            },
        };
        return NextToken{ .token = token, .next_location = percent_sign.next_location };
    }

    const token: Token = switch (result.value) {
        .integer => |integer| .{ .token_integer = integer },
        .number => |number| .{ .token_number = number },
    };
    return NextToken{ .token = token, .next_location = result.after_number };
}

const ConsumeNumber = struct {
    const Type = enum { integer, number };
    const Value = union(Type) {
        integer: ?i32,
        number: ?Token.Float,
    };

    value: Value,
    after_number: Source.Location,
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

fn consumeNumber(source: Source, start: Source.Location) !ConsumeNumber {
    var number_type = ConsumeNumber.Type.integer;
    var buffer = NumberBuffer{};
    var location = start;

    var is_negative: bool = undefined;
    const leading_sign = try nextCodepoint(source, location);
    if (leading_sign.codepoint == '+') {
        is_negative = false;
        buffer.append('+');
        location = leading_sign.next_location;
    } else if (leading_sign.codepoint == '-') {
        is_negative = true;
        buffer.append('-');
        location = leading_sign.next_location;
    } else {
        is_negative = false;
    }

    // TODO: Skip leading zeroes
    var integral_part = try consumeDigits(source, location, &buffer);
    location = integral_part.next_location;

    const dot = try nextCodepoint(source, location);
    if (dot.codepoint == '.') {
        switch ((try nextCodepoint(source, dot.next_location)).codepoint) {
            '0'...'9' => {
                number_type = .number;
                buffer.append('.');
                // TODO: Skip trailing zeroes
                const fractional_part = try consumeDigits(source, dot.next_location, &buffer);
                location = fractional_part.next_location;
            },
            else => {},
        }
    }

    const e = try nextCodepoint(source, location);
    if (e.codepoint == 'e' or e.codepoint == 'E') {
        var location2 = e.next_location;
        const exponent_sign = try nextCodepoint(source, location2);
        if (exponent_sign.codepoint == '+' or exponent_sign.codepoint == '-') {
            location2 = exponent_sign.next_location;
        }

        switch ((try nextCodepoint(source, location2)).codepoint) {
            '0'...'9' => {
                number_type = .number;
                buffer.append('e');
                if (location2 != e.next_location) {
                    // There was an exponent sign
                    buffer.append(@intCast(exponent_sign.codepoint));
                }
                // TODO: Skip trailing zeroes
                const exponent_part = try consumeDigits(source, location2, &buffer);
                location = exponent_part.next_location;
            },
            else => {},
        }
    }

    const value: ConsumeNumber.Value = value: switch (number_type) {
        .integer => {
            if (is_negative) integral_part.value.negate();
            const integer = integral_part.value.unwrap() catch break :value .{ .integer = null };
            break :value .{ .integer = integer };
        },
        .number => {
            if (buffer.overflow()) break :value .{ .number = null };
            var float = std.fmt.parseFloat(Token.Float, buffer.slice()) catch |err| switch (err) {
                error.InvalidCharacter => unreachable,
            };
            // TODO: Preserve negative zero?
            if (std.math.isPositiveZero(float) or std.math.isNegativeZero(float)) {
                float = 0.0;
            } else if (!std.math.isNormal(float)) {
                break :value .{ .number = null };
            }
            break :value .{ .number = float };
        },
    };
    return ConsumeNumber{ .value = value, .after_number = location };
}

const ConsumeDigits = struct {
    value: CheckedInt(i32),
    next_location: Source.Location,
};

fn consumeDigits(source: Source, start: Source.Location, buffer: *NumberBuffer) !ConsumeDigits {
    var value: CheckedInt(i32) = .init(0);
    var location = start;
    while (true) {
        const next = try nextCodepoint(source, location);
        switch (next.codepoint) {
            '0'...'9' => {
                value.multiply(10);
                value.add(next.codepoint - '0');
                buffer.append(@intCast(next.codepoint));
                location = next.next_location;
            },
            else => return ConsumeDigits{ .value = value, .next_location = location },
        }
    }
}

fn consumeIdentSequenceCodepoint(source: Source, location: *Source.Location) !?u21 {
    const next = try nextCodepoint(source, location.*);
    switch (next.codepoint) {
        '\\' => {
            const first_escaped = try nextCodepoint(source, next.next_location);
            if (isValidFirstEscapedCodepoint(first_escaped.codepoint)) {
                const escaped = try consumeEscapedCodepoint(source, first_escaped);
                location.* = escaped.next_location;
                return escaped.codepoint;
            } else {
                return null;
            }
        },
        '0'...'9',
        'A'...'Z',
        'a'...'z',
        '-',
        '_',
        0x80...0x10FFFF,
        => {
            location.* = next.next_location;
            return next.codepoint;
        },
        else => return null,
    }
}

fn consumeIdentSequence(source: Source, start: Source.Location) !Source.Location {
    var location = start;
    while (try consumeIdentSequenceCodepoint(source, &location)) |_| {}
    return location;
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

fn consumeIdentSequenceWithMatch(
    source: Source,
    start: Source.Location,
    comptime Enum: type,
) !struct { ?Enum, Source.Location } {
    var location = start;
    var prefix_tree = ComptimePrefixTree(Enum){};
    while (try consumeIdentSequenceCodepoint(source, &location)) |codepoint| {
        prefix_tree.nextCodepoint(codepoint);
    }
    return .{ prefix_tree.findMatch(), location };
}

fn consumeIdentLikeToken(source: Source, start: Source.Location) !NextToken {
    const is_url, const after_ident = try consumeIdentSequenceWithMatch(source, start, enum { url });

    const left_paren = try nextCodepoint(source, after_ident);
    if (left_paren.codepoint == '(') {
        if (is_url) |_| {
            var previous_location: Source.Location = undefined;
            var location = left_paren.next_location;
            var has_preceding_whitespace = false;
            while (true) {
                const next = try nextCodepoint(source, location);
                switch (next.codepoint) {
                    '\n', '\t', ' ' => {
                        has_preceding_whitespace = true;
                        previous_location = location;
                        location = next.next_location;
                    },
                    '\'', '"' => {
                        if (has_preceding_whitespace) {
                            // TODO: rewrite this to preserve the location of the first whitespace codepoint
                            location = previous_location;
                        }
                        return NextToken{ .token = .token_function, .next_location = location };
                    },
                    else => return consumeUrlToken(source, location),
                }
            }
        }

        return NextToken{ .token = .token_function, .next_location = left_paren.next_location };
    }

    return NextToken{ .token = .token_ident, .next_location = after_ident };
}

fn consumeUrlToken(source: Source, start: Source.Location) !NextToken {
    var location = try consumeWhitespace(source, start);
    while (consumeUrlTokenCodepoint(source, &location) catch |err| switch (err) {
        error.BadUrlToken => return consumeBadUrl(source, location),
        else => |e| return e,
    }) |_| {}

    return NextToken{ .token = .token_url, .next_location = (nextCodepoint(source, location) catch unreachable).next_location };
}

fn consumeUrlTokenCodepoint(source: Source, location: *Source.Location) !?u21 {
    const next = try nextCodepoint(source, location.*);
    switch (next.codepoint) {
        ')' => return null,
        '\n', '\t', ' ' => {
            location.* = try consumeWhitespace(source, next.next_location);
            const right_paren_or_eof = try nextCodepoint(source, location.*);
            if (right_paren_or_eof.codepoint == eof_codepoint) {
                // NOTE: Parse error
                return null;
            } else if (right_paren_or_eof.codepoint == ')') {
                return null;
            } else {
                location.* = next.next_location;
                return error.BadUrlToken;
            }
        },
        '"', '\'', '(', 0x00...0x08, 0x0B, 0x0E...0x1F, 0x7F => {
            // NOTE: Parse error
            location.* = next.next_location;
            return error.BadUrlToken;
        },
        '\\' => {
            const first_escaped = try nextCodepoint(source, next.next_location);
            if (isValidFirstEscapedCodepoint(first_escaped.codepoint)) {
                const escaped = (try consumeEscapedCodepoint(source, first_escaped));
                location.* = escaped.next_location;
                return escaped.codepoint;
            } else {
                // NOTE: Parse error
                location.* = next.next_location;
                return error.BadUrlToken;
            }
        },
        eof_codepoint => {
            // NOTE: Parse error
            return null;
        },
        else => {
            location.* = next.next_location;
            return next.codepoint;
        },
    }
}

fn consumeBadUrl(source: Source, start: Source.Location) !NextToken {
    var location = start;
    while (true) {
        const next = try nextCodepoint(source, location);
        switch (next.codepoint) {
            ')', eof_codepoint => {
                location = next.next_location;
                break;
            },
            '\\' => {
                const first_escaped = try nextCodepoint(source, location);
                if (isValidFirstEscapedCodepoint(first_escaped.codepoint)) {
                    location = (try consumeEscapedCodepoint(source, first_escaped)).next_location;
                } else {
                    location = next.next_location;
                }
            },
            else => location = next.next_location,
        }
    }
    return NextToken{ .token = .token_bad_url, .next_location = location };
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

fn numberSign(source: Source, after_number_sign: Source.Location) !NextToken {
    var next_3: [3]u21 = undefined;
    const after_first_two = try readCodepoints(source, after_number_sign, next_3[0..2]);
    if (!codepointsStartAHash(next_3[0..2].*)) {
        return NextToken{ .token = .{ .token_delim = '#' }, .next_location = after_number_sign };
    }

    next_3[2] = (try nextCodepoint(source, after_first_two)).codepoint;
    const token: Token = if (codepointsStartAnIdentSequence(next_3)) .token_hash_id else .token_hash_unrestricted;
    const after_ident = try consumeIdentSequence(source, after_number_sign);
    return NextToken{ .token = token, .next_location = after_ident };
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
        const next = try nextToken(source, location);
        const token = next.token;
        try std.testing.expectEqual(expected[i], token);
        if (token == .token_eof) break;
        location = next.next_location;
        i += 1;
    }
}
