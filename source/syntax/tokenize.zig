//! Implements the tokenization algorithm of CSS Syntax Level 3.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const zss = @import("../zss.zig");
const hexDigitToNumber = zss.unicode.hexDigitToNumber;
const toLowercase = zss.unicode.toLowercase;
const CheckedInt = zss.math.CheckedInt;
const Token = zss.syntax.Token;
const Unit = Token.Unit;

const u21_max = std.math.maxInt(u21);
const replacement_character: u21 = 0xfffd;
const eof_codepoint: u21 = std.math.maxInt(u21);

/// A source of `Token`.

// TODO: After parsing, this struct "lingers around" because it is used to get information that isn't stored in `Ast`.
//       A possibly better approach is to store said information into `Ast` (by copying it), eliminating the need for this object.
pub const Source = struct {
    data: []const u8,

    pub const Location = enum(u32) {
        start = 0,
        _,
    };

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

    pub fn next(source: Source, location: *Location) !Token {
        const next_token = try nextToken(source, location.*);
        location.* = next_token.next_location;
        return next_token.token;
    }

    /// Asserts that `start` is the location of the start of an ident token.
    pub fn identTokenIterator(source: Source, start: Location) IdentSequenceIterator {
        var next_3: [3]u21 = undefined;
        _ = readCodepoints(source, start, &next_3) catch unreachable;
        assert(codepointsStartAnIdentSequence(next_3));
        return IdentSequenceIterator{ .location = start };
    }

    /// Asserts that `start` is the location of the start of a hash token.
    pub fn hashTokenIterator(source: Source, start: Location) IdentSequenceIterator {
        const hash = nextCodepoint(source, start) catch unreachable;
        assert(hash.codepoint == '#');
        return identTokenIterator(source, hash.next_location);
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
        return StringTokenIterator{ .location = quote.next_location, .ending_codepoint = quote.codepoint };
    }

    /// `start` must be the location of a `token_url`.
    pub fn urlTokenIterator(source: Source, start: Location) UrlTokenIterator {
        var next_4: [4]u21 = undefined;
        var location = readCodepoints(source, start, &next_4) catch unreachable;
        assert(std.mem.eql(u21, &next_4, &[4]u21{ 'u', 'r', 'l', '(' }));
        location = consumeWhitespace(source, location) catch unreachable;
        return UrlTokenIterator{ .location = location };
    }

    /// Given that `location` is the location of an <ident-token>, check if the identifier is equal to `ascii_string`
    /// using case-insensitive matching.
    pub fn identifierEqlIgnoreCase(source: Source, location: Location, ascii_string: []const u8) bool {
        var it = identTokenIterator(source, location);
        for (ascii_string) |string_codepoint| {
            assert(string_codepoint <= 0x7F);
            const it_codepoint = it.next(source) orelse return false;
            if (toLowercase(string_codepoint) != toLowercase(it_codepoint)) return false;
        }
        return it.next(source) == null;
    }

    /// Given that `location` is the location of a <ident-token>, copy that identifier
    pub fn copyIdentifier(source: Source, location: Location, allocator: Allocator) ![]const u8 {
        var iterator = identTokenIterator(source, location);
        return copyTokenGeneric(source, &iterator, allocator);
    }

    /// Given that `location` is the location of a <string-token>, copy that string
    pub fn copyString(source: Source, location: Location, allocator: Allocator) ![]const u8 {
        var iterator = stringTokenIterator(source, location);
        return copyTokenGeneric(source, &iterator, allocator);
    }

    /// Given that `location` is the location of a <hash-token>, copy that hash's identifier
    pub fn copyHash(source: Source, location: Location, allocator: Allocator) ![]const u8 {
        var iterator = hashTokenIterator(source, location);
        return copyTokenGeneric(source, &iterator, allocator);
    }

    /// Given that `location` is the location of a <url-token>, copy that URL
    pub fn copyUrl(source: Source, location: Location, allocator: Allocator) ![]const u8 {
        var iterator = urlTokenIterator(source, location);
        return copyTokenGeneric(source, &iterator, allocator);
    }

    // TODO: Provide the option to use a buffer instead of a heap allocation
    fn copyTokenGeneric(source: Source, iterator: anytype, allocator: Allocator) ![]const u8 {
        var list = std.ArrayListUnmanaged(u8){};
        defer list.deinit(allocator);

        var buffer: [4]u8 = undefined;
        while (iterator.next(source)) |codepoint| {
            // TODO: Get a UTF-8 encoded buffer directly from the tokenizer
            const len = std.unicode.utf8Encode(codepoint, &buffer) catch unreachable;
            try list.appendSlice(allocator, buffer[0..len]);
        }

        const bytes = try list.toOwnedSlice(allocator);
        return bytes;
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
    location: Source.Location,

    pub fn next(it: *IdentSequenceIterator, source: Source) ?u21 {
        const next_ = (consumeIdentSequenceCodepoint(source, it.location) catch unreachable) orelse return null;
        it.location = next_.next_location;
        return next_.codepoint;
    }
};

pub const StringTokenIterator = struct {
    location: Source.Location,
    ending_codepoint: u21,

    pub fn next(it: *StringTokenIterator, source: Source) ?u21 {
        const next_ = nextCodepoint(source, it.location) catch unreachable;
        switch (next_.codepoint) {
            '\n' => unreachable,
            '\\' => {
                const first_escaped = nextCodepoint(source, next_.next_location) catch unreachable;
                if (first_escaped.codepoint == '\n') {
                    it.location = first_escaped.next_location;
                    return '\n';
                } else if (first_escaped.codepoint == eof_codepoint) {
                    it.location = next_.next_location;
                    return null;
                } else {
                    const escaped = consumeEscapedCodepoint(source, first_escaped) catch unreachable;
                    it.location = escaped.next_location;
                    return escaped.codepoint;
                }
            },
            eof_codepoint => return null,
            else => {
                if (next_.codepoint == it.ending_codepoint) {
                    return null;
                } else {
                    it.location = next_.next_location;
                    return next_.codepoint;
                }
            },
        }
    }
};

/// Used to iterate over <url-token>s (and NOT <bad-url-token>s)
pub const UrlTokenIterator = struct {
    location: Source.Location,

    pub fn next(it: *UrlTokenIterator, source: Source) ?u21 {
        const next_ = nextCodepoint(source, it.location) catch unreachable;
        switch (next_.codepoint) {
            ')', eof_codepoint => return null,
            '\n', '\t', ' ' => {
                it.location = consumeWhitespace(source, next_.next_location) catch unreachable;
                const right_paren_or_eof = nextCodepoint(source, it.location) catch unreachable;
                switch (right_paren_or_eof.codepoint) {
                    ')', eof_codepoint => return null,
                    else => unreachable,
                }
            },
            '"', '\'', '(', 0x00...0x08, 0x0B, 0x0E...0x1F, 0x7F => unreachable,
            '\\' => {
                const first_escaped = nextCodepoint(source, next_.next_location) catch unreachable;
                assert(isValidFirstEscapedCodepoint(first_escaped.codepoint));
                const escaped = consumeEscapedCodepoint(source, first_escaped) catch unreachable;
                it.location = escaped.next_location;
                return escaped.codepoint;
            },
            else => {
                it.location = next_.next_location;
                return next_.codepoint;
            },
        }
    }
};

pub fn stringIsIdentSequence(utf8_string: []const u8) bool {
    const source = Source.init(utf8_string) catch return false;
    var location: Source.Location = .start;
    var first_3: [3]u21 = undefined;
    _ = readCodepoints(source, location, &first_3) catch return false;
    if (!codepointsStartAnIdentSequence(first_3)) return false;
    location = consumeIdentSequence(source, location) catch return false;
    const final = nextCodepoint(source, location) catch return false;
    return final.codepoint == eof_codepoint;
}

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
                const after_ident = try consumeIdentSequence(source, next.next_location);
                return NextToken{ .token = .token_at_keyword, .next_location = after_ident };
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
    while (true) {
        const next = try nextCodepoint(source, location);
        switch (next.codepoint) {
            '\n' => {
                // NOTE: Parse error
                return NextToken{ .token = .token_bad_string, .next_location = location };
            },
            '\\' => {
                const first_escaped = try nextCodepoint(source, next.next_location);
                if (first_escaped.codepoint == '\n') {
                    location = first_escaped.next_location;
                } else if (first_escaped.codepoint == eof_codepoint) {
                    location = next.next_location;
                } else {
                    location = (try consumeEscapedCodepoint(source, first_escaped)).next_location;
                }
            },
            eof_codepoint => {
                // NOTE: Parse error
                break;
            },
            else => {
                location = next.next_location;
                if (next.codepoint == ending_codepoint) {
                    break;
                }
            },
        }
    }

    return NextToken{ .token = .token_string, .next_location = location };
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
        const consume_unit = try consumeUnit(source, result.after_number);
        const numeric_value: f32 = switch (result.value) {
            .integer => |integer| @floatFromInt(integer),
            .number => |number| number,
        };
        return NextToken{
            .token = .{ .token_dimension = .{
                .number = numeric_value,
                .unit = consume_unit.unit,
                .unit_location = result.after_number,
            } },
            .next_location = consume_unit.after_unit,
        };
    }

    const percent_sign = try nextCodepoint(source, result.after_number);
    if (percent_sign.codepoint == '%') {
        const token: Token = switch (result.value) {
            .integer => |integer| .{ .token_percentage = @floatFromInt(integer) },
            .number => |number| .{ .token_percentage = number },
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

    value: union(Type) {
        integer: i32,
        number: f32,
    },
    after_number: Source.Location,
};

const NumberBuffer = struct {
    data: [63]u8 = undefined,
    len: u8 = 0,

    fn append(buffer: *NumberBuffer, char: u8) void {
        if (buffer.len >= buffer.data.len) return;
        defer buffer.len +|= 1;
        buffer.data[buffer.len] = char;
    }

    fn overflow(buffer: NumberBuffer) bool {
        return buffer.len > buffer.data.len;
    }

    fn slice(buffer: NumberBuffer) []const u8 {
        assert(!buffer.overflow());
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

    const integral_part = try consumeDigits(source, location, &buffer);
    location = integral_part.next_location;

    const dot = try nextCodepoint(source, location);
    if (dot.codepoint == '.') {
        switch ((try nextCodepoint(source, dot.next_location)).codepoint) {
            '0'...'9' => {
                number_type = .number;
                buffer.append('.');
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
                const exponent_part = try consumeDigits(source, location2, &buffer);
                location = exponent_part.next_location;
            },
            else => {},
        }
    }

    switch (number_type) {
        .integer => {
            // TODO: Should the default value be 0, or some really big number?
            const unwrapped = integral_part.value.unwrap() catch 0;
            comptime assert(@TypeOf(unwrapped) == u31);
            var integer: i32 = unwrapped;
            if (is_negative) integer = -integer;
            return ConsumeNumber{ .value = .{ .integer = integer }, .after_number = location };
        },
        .number => {
            var float: f32 = undefined;
            if (buffer.overflow()) {
                // TODO: Should the default value be 0, or some really big number/infinity/NaN?
                float = 0.0;
            } else {
                float = std.fmt.parseFloat(f32, buffer.slice()) catch |err| switch (err) {
                    error.InvalidCharacter => unreachable,
                };
                assert(!std.math.isNan(float));
                if (!std.math.isNormal(float)) {
                    // TODO: Should the default value be 0, or some really big number/infinity/NaN?
                    float = 0.0;
                }
            }
            return ConsumeNumber{ .value = .{ .number = float }, .after_number = location };
        },
    }
}

const ConsumeDigits = struct {
    value: CheckedInt(u31),
    next_location: Source.Location,
};

fn consumeDigits(source: Source, start: Source.Location, buffer: *NumberBuffer) !ConsumeDigits {
    var value: CheckedInt(u31) = .init(0);
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

const ConsumeUnit = struct {
    unit: Unit,
    after_unit: Source.Location,
};

fn consumeUnit(source: Source, start: Source.Location) !ConsumeUnit {
    const map, const max_unit_len = comptime blk: {
        const KV = struct { []const u8, Unit };
        const units = std.meta.fields(Unit);

        var kvs: [units.len - 1]KV = undefined;
        var max_unit_len: usize = 0;
        var i = 0;
        for (units) |field_info| {
            const unit: Unit = @enumFromInt(field_info.value);
            const name = switch (unit) {
                .unrecognized => continue,
                .px => "px",
            };
            kvs[i] = .{ name, unit };
            max_unit_len = @max(max_unit_len, name.len);
            i += 1;
        }

        const map = zss.syntax.ComptimeIdentifierMap(Unit).init(kvs);
        assert(map.get("unrecognized") == null);
        break :blk .{ map, max_unit_len };
    };

    var location = start;
    var unit_buffer: [max_unit_len]u8 = undefined;
    var count: usize = 0;
    while (try consumeIdentSequenceCodepoint(source, location)) |next| {
        if (count < max_unit_len and next.codepoint <= 0xFF) {
            unit_buffer[count] = @intCast(next.codepoint);
            count += 1;
        } else {
            count = comptime max_unit_len + 1;
        }
        location = next.next_location;
    }

    const unit = if (count <= max_unit_len)
        map.get(unit_buffer[0..count]) orelse .unrecognized
    else
        .unrecognized;

    return ConsumeUnit{ .unit = unit, .after_unit = location };
}

fn consumeIdentSequenceCodepoint(source: Source, location: Source.Location) !?NextCodepoint {
    const next = try nextCodepoint(source, location);
    switch (next.codepoint) {
        '\\' => {
            const first_escaped = try nextCodepoint(source, next.next_location);
            if (!isValidFirstEscapedCodepoint(first_escaped.codepoint)) {
                return null;
            }
            return try consumeEscapedCodepoint(source, first_escaped);
        },
        '0'...'9',
        'A'...'Z',
        'a'...'z',
        '-',
        '_',
        0x80...0x10FFFF,
        => return next,
        else => return null,
    }
}

fn consumeIdentSequence(source: Source, start: Source.Location) !Source.Location {
    var location = start;
    while (try consumeIdentSequenceCodepoint(source, location)) |next| {
        location = next.next_location;
    }
    return location;
}

fn ComptimePrefixTree(comptime Enum: type, comptime Index: type, comptime size: Index) type {
    const Node = struct {
        skip: Index,
        character: u7,
        field_index: ?usize,
    };

    const Interval = struct {
        begin: Index,
        end: Index,

        fn next(interval: *@This(), nodes: []const Node) ?Index {
            if (interval.begin == interval.end) return null;
            defer interval.begin += nodes[interval.begin].skip;
            return interval.begin;
        }
    };

    const my = struct {
        fn BoundedArray(comptime T: type, comptime max: Index) type {
            return struct {
                buffer: [max]T = undefined,
                len: Index = 0,

                fn slice(self: *@This()) []T {
                    return self.buffer[0..self.len];
                }

                fn append(self: *@This(), item: T) void {
                    defer self.len += 1;
                    self.buffer[self.len] = item;
                }

                fn insertManyAsSlice(self: *@This(), insertion_index: Index, n: Index) []T {
                    defer self.len += n;
                    std.mem.copyBackwards(Node, self.buffer[insertion_index + n .. self.len + n], self.buffer[insertion_index..self.len]);
                    return self.buffer[insertion_index..][0..n];
                }
            };
        }
    };

    const fields = @typeInfo(Enum).@"enum".fields;
    var stack = my.BoundedArray(Index, 16){};
    comptime var nodes = my.BoundedArray(Node, size){};
    nodes.append(.{ .skip = 1, .character = 0, .field_index = null });
    inline for (fields, 0..) |field, field_index| {
        assert(field.value == field_index);
        stack.len = 0;
        stack.append(0);
        var interval = Interval{ .begin = 1, .end = nodes.buffer[0].skip };

        character_loop: for (field.name, 0..) |character, character_index| {
            const insertion_index = while (interval.next(nodes.slice())) |index| {
                const character_lowercase = switch (character) {
                    'A'...'Z' => character - 'A' + 'a',
                    0x80...0xFF => @compileError(std.fmt.comptimePrint("Field name '{s}' contains non-ascii characters", .{field.name})),
                    else => character,
                };
                switch (std.math.order(character_lowercase, nodes.buffer[index].character)) {
                    .lt => break index,
                    .gt => {},
                    .eq => {
                        stack.append(index);
                        interval = .{ .begin = index + 1, .end = index + nodes.buffer[index].skip };
                        continue :character_loop;
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

    if (nodes.len != size) {
        @compileError(std.fmt.comptimePrint("Expected size {}, got {}", .{ nodes.len, size }));
    }
    const final_nodes: [size]Node = nodes.buffer;

    return struct {
        const skips = blk: {
            var result: [size]Index = undefined;
            for (final_nodes, &result) |in, *out| out.* = in.skip;
            break :blk result;
        };
        const characters = blk: {
            var result: [size]u7 = undefined;
            for (final_nodes, &result) |in, *out| out.* = in.character;
            break :blk result;
        };
        const leaves = blk: {
            var result: [fields.len]Index = undefined;
            for (final_nodes, 0..) |node, i| {
                if (node.field_index) |field_index| {
                    result[field_index] = i;
                }
            }
            break :blk result;
        };

        const Self = @This();
        index: Index = 0,

        fn nextCodepoint(self: *Self, codepoint: u21) void {
            if (self.index == skips.len) return;
            const character: u8 = switch (codepoint) {
                'A'...'Z' => @intCast(codepoint - 'A' + 'a'),
                0x80...std.math.maxInt(u21) => 0xFF,
                else => @intCast(codepoint),
            };
            const end = self.index + skips[self.index];
            self.index += 1;
            while (self.index < end) : (self.index += skips[self.index]) {
                if (character == characters[self.index]) return;
            }
            self.index = skips.len;
        }

        fn findMatch(self: Self) ?Enum {
            if (self.index == skips.len) return null;
            const field_index = std.mem.indexOfScalar(Index, &leaves, self.index) orelse return null;
            return @enumFromInt(field_index);
        }
    };
}

fn consumeIdentSequenceWithPrefixTree(
    source: Source,
    start: Source.Location,
    prefix_tree: anytype,
) !Source.Location {
    var location = start;
    while (try consumeIdentSequenceCodepoint(source, location)) |next| {
        location = next.next_location;
        prefix_tree.nextCodepoint(next.codepoint);
    }
    return location;
}

fn consumeIdentLikeToken(source: Source, start: Source.Location) !NextToken {
    var prefix_tree = ComptimePrefixTree(enum { url }, u8, 4){};
    const after_ident = try consumeIdentSequenceWithPrefixTree(source, start, &prefix_tree);

    const left_paren = try nextCodepoint(source, after_ident);
    if (left_paren.codepoint == '(') {
        if (prefix_tree.findMatch()) |_| {
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
    while (true) {
        const next = try nextCodepoint(source, location);
        switch (next.codepoint) {
            ')' => {
                location = next.next_location;
                break;
            },
            '\n', '\t', ' ' => {
                location = try consumeWhitespace(source, next.next_location);
                const right_paren = try nextCodepoint(source, location);
                if (right_paren.codepoint == eof_codepoint) {
                    // NOTE: Parse error
                    break;
                } else if (right_paren.codepoint == ')') {
                    location = right_paren.next_location;
                    break;
                } else {
                    return consumeBadUrl(source, next.next_location);
                }
            },
            '"', '\'', '(', 0x00...0x08, 0x0B, 0x0E...0x1F, 0x7F => {
                // NOTE: Parse error
                return consumeBadUrl(source, next.next_location);
            },
            '\\' => {
                const first_escaped = try nextCodepoint(source, location);
                if (isValidFirstEscapedCodepoint(first_escaped.codepoint)) {
                    location = (try consumeEscapedCodepoint(source, first_escaped)).next_location;
                } else {
                    // NOTE: Parse error
                    return consumeBadUrl(source, next.next_location);
                }
            },
            eof_codepoint => {
                // NOTE: Parse error
                break;
            },
            else => location = next.next_location,
        }
    }

    return NextToken{ .token = .token_url, .next_location = location };
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
        .token_at_keyword,
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

    var location: Source.Location = .start;
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
