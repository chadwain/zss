//! Implements the tokenization algorithm of CSS Syntax Level 3.

const std = @import("std");
const assert = std.debug.assert;

const zss = @import("../../zss.zig");
const hexDigitToNumber = zss.util.unicode.hexDigitToNumber;
const toLowercase = zss.util.unicode.toLowercase;
const CheckedInt = zss.util.CheckedInt;
const Component = zss.syntax.Component;
const Unit = zss.syntax.Unit;
const Utf8String = zss.util.Utf8String;

const u21_max = std.math.maxInt(u21);
const replacement_character: u21 = 0xfffd;
const eof_codepoint: u21 = std.math.maxInt(u21);

pub const Source = struct {
    data: []const u8,

    pub const Location = struct {
        value: Value = 0,

        const Value = u32;

        fn eql(lhs: Location, rhs: Location) bool {
            return lhs.value == rhs.value;
        }
    };

    pub fn init(string: Utf8String) !Source {
        if (string.data.len > std.math.maxInt(Location.Value)) return error.SourceStringTooLong;
        return Source{ .data = string.data };
    }

    /// Asserts that `start` is the location of the start of an ident token.
    pub fn identTokenIterator(source: Source, start: Location) IdentSequenceIterator {
        var next_3: [3]u21 = undefined;
        _ = source.read(start, &next_3) catch unreachable;
        assert(codepointsStartAnIdentSequence(next_3));
        return IdentSequenceIterator{ .location = start };
    }

    /// Asserts that `start` is the location of the start of a hash id token.
    pub fn hashIdTokenIterator(source: Source, start: Location) IdentSequenceIterator {
        const hash = source.next(start) catch unreachable;
        assert(hash.codepoint == '#');
        return identTokenIterator(source, hash.next_location);
    }

    /// Asserts that `start` is the location of the start of a string token.
    pub fn stringTokenIterator(source: Source, start: Location) StringTokenIterator {
        const quote = source.next(start) catch unreachable;
        assert(quote.codepoint == '"' or quote.codepoint == '\'');
        return StringTokenIterator{ .location = quote.next_location, .ending_codepoint = quote.codepoint };
    }

    /// `start` must be the location of a `token_url`.
    pub fn urlTokenIterator(source: Source, start: Location) UrlTokenIterator {
        var next_4: [4]u21 = undefined;
        var location = source.read(start, &next_4) catch unreachable;
        assert(std.meta.eql(next_4, [4]u21{ 'u', 'r', 'l', '(' }));
        location = consumeWhitespace(source, location) catch unreachable;
        return UrlTokenIterator{ .location = location };
    }

    const Next = struct { next_location: Location, codepoint: u21 };

    fn next(source: Source, location: Location) !Next {
        if (location.value == source.data.len) return Next{ .next_location = location, .codepoint = eof_codepoint };

        var next_location = location.value;
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
            else => |c| c,
        };

        return Next{ .next_location = .{ .value = next_location }, .codepoint = codepoint };
    }

    fn read(source: Source, start: Location, buffer: []u21) !Location {
        var location = start;
        for (buffer) |*codepoint| {
            const next_ = try source.next(location);
            codepoint.* = next_.codepoint;
            location = next_.next_location;
        }
        return location;
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
        const next_ = source.next(it.location) catch unreachable;
        switch (next_.codepoint) {
            '\n' => unreachable,
            '\\' => {
                const first_escaped = source.next(next_.next_location) catch unreachable;
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
        const next_ = source.next(it.location) catch unreachable;
        switch (next_.codepoint) {
            ')', eof_codepoint => return null,
            '\n', '\t', ' ' => {
                it.location = consumeWhitespace(source, next_.next_location) catch unreachable;
                const right_paren_or_eof = source.next(it.location) catch unreachable;
                switch (right_paren_or_eof.codepoint) {
                    ')', eof_codepoint => return null,
                    else => unreachable,
                }
            },
            '"', '\'', '(', 0x00...0x08, 0x0B, 0x0E...0x1F, 0x7F => unreachable,
            '\\' => {
                const first_escaped = source.next(next_.next_location) catch unreachable;
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

pub fn stringIsIdentSequence(string: Utf8String) bool {
    const source = Source.init(string) catch return false;
    var location = Source.Location{};
    var first_3: [3]u21 = undefined;
    _ = source.read(location, &first_3) catch return false;
    if (!codepointsStartAnIdentSequence(first_3)) return false;
    location = consumeIdentSequence(source, location) catch return false;
    const final = source.next(location) catch return false;
    return final.codepoint == eof_codepoint;
}

pub const Token = union(Component.Tag) {
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
    token_delim: u21,
    token_integer: i32,
    token_number: f32,
    token_percentage: f32,
    token_dimension: Dimension,
    token_unit,
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

    at_rule,
    qualified_rule,
    style_block,
    declaration_normal,
    declaration_important,
    function,
    simple_block_square,
    simple_block_curly,
    simple_block_paren,

    rule_list,
    component_list,

    pub const Dimension = struct {
        number: f32,
        unit: Unit,
        unit_location: Source.Location,
    };
};

pub const NextToken = struct {
    token: Token,
    next_location: Source.Location,
};

pub fn nextToken(source: Source, location: Source.Location) !NextToken {
    const next = try source.next(location);
    switch (next.codepoint) {
        '/' => {
            const asterisk = try source.next(next.next_location);
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
            _ = try source.read(next.next_location, next_3[1..3]);
            if (codepointsStartANumber(next_3)) {
                return consumeNumericToken(source, location);
            } else {
                return NextToken{ .token = .{ .token_delim = next.codepoint }, .next_location = next.next_location };
            }
        },
        ',' => return NextToken{ .token = .token_comma, .next_location = next.next_location },
        '-' => {
            var next_3 = [3]u21{ '-', undefined, undefined };
            const after_cdc = try source.read(next.next_location, next_3[1..3]);
            if (next_3[1] == '-' and next_3[2] == '>') {
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
            const after_cdo = try source.read(next.next_location, &next_3);
            if (next_3[0] == '!' and next_3[1] == '-' and next_3[2] == '-') {
                return NextToken{ .token = .token_cdo, .next_location = after_cdo };
            } else {
                return NextToken{ .token = .{ .token_delim = next.codepoint }, .next_location = next.next_location };
            }
        },
        '@' => {
            var next_3: [3]u21 = undefined;
            _ = try source.read(next.next_location, &next_3);

            if (codepointsStartAnIdentSequence(next_3)) {
                const after_ident = try consumeIdentSequence(source, next.next_location);
                return NextToken{ .token = .token_at_keyword, .next_location = after_ident };
            } else {
                return NextToken{ .token = .{ .token_delim = next.codepoint }, .next_location = next.next_location };
            }
        },
        '[' => return NextToken{ .token = .token_left_square, .next_location = next.next_location },
        '\\' => {
            const first_escaped = try source.next(next.next_location);
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
        const comment_start = try source.read(location, &next_2);
        if (next_2[0] == '/' and next_2[1] == '*') {
            location = comment_start;
            while (true) {
                const next = try source.next(location);
                switch (next.codepoint) {
                    '*' => {
                        const comment_end = try source.next(next.next_location);
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
        const next = try source.next(location);
        switch (next.codepoint) {
            '\n', '\t', ' ' => location = next.next_location,
            else => return location,
        }
    }
}

fn consumeStringToken(source: Source, after_quote: Source.Location, ending_codepoint: u21) !NextToken {
    var location = after_quote;
    while (true) {
        const next = try source.next(location);
        switch (next.codepoint) {
            '\n' => {
                // NOTE: Parse error
                return NextToken{ .token = .token_bad_string, .next_location = location };
            },
            '\\' => {
                const first_escaped = try source.next(next.next_location);
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

fn consumeEscapedCodepoint(source: Source, first_escaped: Source.Next) !Source.Next {
    var location = first_escaped.next_location;
    const codepoint = switch (first_escaped.codepoint) {
        '0'...'9', 'A'...'F', 'a'...'f' => blk: {
            var result: u21 = hexDigitToNumber(first_escaped.codepoint);
            var count: u3 = 0;
            while (count < 5) : (count += 1) {
                const next = try source.next(location);
                switch (next.codepoint) {
                    '0'...'9', 'A'...'F', 'a'...'f' => {
                        result = result *| 16 +| hexDigitToNumber(next.codepoint);
                        location = next.next_location;
                    },
                    else => break,
                }
            }

            const whitespace = try source.next(location);
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

    return Source.Next{ .codepoint = codepoint, .next_location = location };
}

fn consumeNumericToken(source: Source, start: Source.Location) !NextToken {
    const result = try consumeNumber(source, start);

    var next_3: [3]u21 = undefined;
    _ = try source.read(result.after_number, &next_3);

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

    const percent_sign = try source.next(result.after_number);
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
        defer buffer.len +|= 1;
        if (buffer.len >= buffer.data.len) return;
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
    const leading_sign = try source.next(location);
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

    const dot = try source.next(location);
    if (dot.codepoint == '.') {
        switch ((try source.next(dot.next_location)).codepoint) {
            '0'...'9' => {
                number_type = .number;
                buffer.append('.');
                const fractional_part = try consumeDigits(source, dot.next_location, &buffer);
                location = fractional_part.next_location;
            },
            else => {},
        }
    }

    const e = try source.next(location);
    if (e.codepoint == 'e' or e.codepoint == 'E') {
        var location2 = e.next_location;
        const exponent_sign = try source.next(location2);
        if (exponent_sign.codepoint == '+' or exponent_sign.codepoint == '-') {
            location2 = exponent_sign.next_location;
        }

        switch ((try source.next(location2)).codepoint) {
            '0'...'9' => {
                number_type = .number;
                buffer.append('e');
                if (!location2.eql(e.next_location)) {
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
            // NOTE: Should the default value be 0, or some really big number?
            const unwrapped = integral_part.value.unwrap() catch 0;
            comptime assert(@TypeOf(unwrapped) == u31);
            var integer: i32 = unwrapped;
            if (is_negative) integer = -integer;
            return ConsumeNumber{ .value = .{ .integer = integer }, .after_number = location };
        },
        .number => {
            var float: f32 = undefined;
            if (buffer.overflow()) {
                // NOTE: Should the default value be 0, or some really big number/infinity/NaN?
                float = 0.0;
            } else {
                float = std.fmt.parseFloat(f32, buffer.slice()) catch |err| switch (err) {
                    error.InvalidCharacter => unreachable,
                };
                assert(!std.math.isNan(float));
                assert(!std.math.isInf(float));
                if (!std.math.isNormal(float) and float != 0.0) {
                    // It's either a denormal/subnormal or negative zero
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
    var value = CheckedInt(u31).init(0);
    var location = start;
    while (true) {
        const next = try source.next(location);
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
    const units = comptime std.meta.fields(Unit);
    const max_unit_len = comptime blk: {
        var result: comptime_int = 0;
        for (units) |field_info| {
            if (@as(Unit, @enumFromInt(field_info.value)) == .unrecognized) continue;
            result = @max(result, field_info.name.len);
        }
        break :blk result;
    };
    const Count = comptime std.math.IntFittingRange(0, max_unit_len + 1);
    const map = comptime blk: {
        const KV = struct { []const u8, Unit };
        var kvs: [units.len - 1]KV = undefined;
        var i = 0;
        for (units) |field_info| {
            const unit: Unit = @enumFromInt(field_info.value);
            const name = switch (unit) {
                .unrecognized => continue,
                .px => "px",
            };
            kvs[i] = .{ name, unit };
            i += 1;
        }
        const map = zss.syntax.ComptimeIdentifierMap(Unit, kvs);
        assert(map.get("unrecognized") == null);
        break :blk map;
    };

    var location = start;
    var unit_buffer: [max_unit_len]u8 = undefined;
    var count: Count = 0;
    while (try consumeIdentSequenceCodepoint(source, location)) |next| {
        if (count < max_unit_len and next.codepoint <= 0xFF) {
            unit_buffer[count] = @intCast(next.codepoint);
            count += 1;
        } else {
            count = std.math.maxInt(Count);
        }
        location = next.next_location;
    }

    const unit = if (count <= max_unit_len)
        map.get(unit_buffer[0..count]) orelse .unrecognized
    else
        .unrecognized;

    return ConsumeUnit{ .unit = unit, .after_unit = location };
}

fn consumeIdentSequenceCodepoint(source: Source, location: Source.Location) !?Source.Next {
    const next = try source.next(location);
    switch (next.codepoint) {
        '\\' => {
            const first_escaped = try source.next(next.next_location);
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

const ComsumeIdentSequenceMatch = struct { after_ident: Source.Location, matches: bool };

fn consumeIdentSequenceMatch(
    source: Source,
    start: Source.Location,
    string: []const u21,
    comptime ignore_case: bool,
    keep_going: bool,
) !ComsumeIdentSequenceMatch {
    var string_matcher = struct {
        num_matching_codepoints: usize = 0,
        matches: ?bool = null,

        fn nextCodepoint(self: *@This(), str: []const u21, codepoint: u21) void {
            if (self.matches == null) {
                const is_eql = switch (ignore_case) {
                    false => str[self.num_matching_codepoints] == codepoint,
                    true => toLowercase(str[self.num_matching_codepoints]) == toLowercase(codepoint),
                };

                if (is_eql) {
                    self.num_matching_codepoints += 1;
                    if (self.num_matching_codepoints == str.len) {
                        self.matches = true;
                    }
                } else {
                    self.matches = false;
                }
            } else {
                self.matches = false;
            }
        }
    }{};

    var location = start;
    while (try consumeIdentSequenceCodepoint(source, location)) |next| {
        location = next.next_location;
        string_matcher.nextCodepoint(string, next.codepoint);
        if (keep_going) continue;
        if (string_matcher.matches == false) {
            return ComsumeIdentSequenceMatch{ .after_ident = undefined, .matches = false };
        }
    }

    return ComsumeIdentSequenceMatch{ .after_ident = location, .matches = string_matcher.matches orelse false };
}

fn consumeIdentLikeToken(source: Source, start: Source.Location) !NextToken {
    const result = try consumeIdentSequenceMatch(source, start, &.{ 'u', 'r', 'l' }, true, true);

    const left_paren = try source.next(result.after_ident);
    if (left_paren.codepoint == '(') {
        if (result.matches) {
            var previous_location: Source.Location = undefined;
            var location = left_paren.next_location;
            var has_preceding_whitespace = false;
            while (true) {
                const next = try source.next(location);
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

    return NextToken{ .token = .token_ident, .next_location = result.after_ident };
}

fn consumeUrlToken(source: Source, start: Source.Location) !NextToken {
    var location = try consumeWhitespace(source, start);
    while (true) {
        const next = try source.next(location);
        switch (next.codepoint) {
            ')' => {
                location = next.next_location;
                break;
            },
            '\n', '\t', ' ' => {
                location = try consumeWhitespace(source, next.next_location);
                const right_paren = try source.next(location);
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
                const first_escaped = try source.next(location);
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
        const next = try source.next(location);
        switch (next.codepoint) {
            ')', eof_codepoint => {
                location = next.next_location;
                break;
            },
            '\\' => {
                const first_escaped = try source.next(location);
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
    const after_first_two = try source.read(after_number_sign, next_3[0..2]);
    if (!codepointsStartAHash(next_3[0..2].*)) {
        return NextToken{ .token = .{ .token_delim = '#' }, .next_location = after_number_sign };
    }

    next_3[2] = (try source.next(after_first_two)).codepoint;
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
    const source = try Source.init(Utf8String{ .data = input });
    const expected = [_]Component.Tag{
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

    var location = Source.Location{};
    var i: usize = 0;
    while (true) {
        if (i >= expected.len) return error.TestFailure;
        const next = try nextToken(source, location);
        const token = next.token;
        try std.testing.expectEqual(expected[i], @as(Component.Tag, token));
        if (token == .token_eof) break;
        location = next.next_location;
        i += 1;
    }
}
