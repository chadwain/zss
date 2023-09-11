//! Implements the tokenization algorithm of CSS Syntax Level 3.

const std = @import("std");
const assert = std.debug.assert;

const zss = @import("../../zss.zig");
const Tag = zss.syntax.Component.Tag;
const toLowercase = zss.util.unicode.toLowercase;
const hexDigitToNumber = zss.util.unicode.hexDigitToNumber;

const u21_max = std.math.maxInt(u21);
const replacement_character: u21 = 0xfffd;
const eof_codepoint: u21 = std.math.maxInt(u21);

pub const Source = struct {
    data: []const u8,

    pub const Location = struct {
        value: Value = 0,

        const Value = u32;
    };

    /// `data` is expected to be an 8-bit ASCII string.
    pub fn init(data: []const u8) !Source {
        if (data.len > std.math.maxInt(Location.Value)) return error.SourceDataTooLong;
        return Source{ .data = data };
    }

    pub fn delimTokenCodepoint(source: Source, location: Location) u21 {
        return source.next(location).codepoint;
    }

    /// Asserts that `start` is the location of the start of an ident token.
    pub fn identTokenIterator(source: Source, start: Location) IdentSequenceIterator {
        var next_3: [3]u21 = undefined;
        _ = source.read(start, &next_3);
        assert(codepointsStartAnIdentSequence(next_3));
        return IdentSequenceIterator{ .location = start };
    }

    /// Asserts that `start` is the location of the start of a hash id token.
    pub fn hashIdTokenIterator(source: Source, start: Location) IdentSequenceIterator {
        const hash = source.next(start);
        assert(hash.codepoint == '#');
        return identTokenIterator(source, hash.location);
    }

    const Next = struct { location: Location, codepoint: u21 };

    fn next(source: Source, location: Location) Next {
        if (location.value == source.data.len) return Next{ .location = location, .codepoint = eof_codepoint };

        var next_value = location.value + 1;
        const input = source.data[location.value];
        const codepoint: u21 = switch (input) {
            0x00,
            0x80...0xFF,
            => replacement_character,
            '\r' => blk: {
                if (next_value < source.data.len and source.data[next_value] == '\n') {
                    next_value += 1;
                }
                break :blk '\n';
            },
            0x0C => '\n',
            else => |c| c,
        };

        // TODO: If @TypeOf(input) == u21, use this code instead of the above.
        comptime assert(@TypeOf(input) == u8);
        // const codepoint: u21 = switch (input) {
        //     0x00,
        //     0xD800...0xDBFF,
        //     0xDC00...0xDFFF,
        //     => replacement_character,
        //     '\r' => blk: {
        //         if (next_value < source.data.len and source.data[next_value] == '\n') {
        //             next_value += 1;
        //         }
        //         break :blk '\n';
        //     },
        //     0x0C => '\n',
        //     0x110000...u21_max => replacement_character,
        //     else => |c| c,
        // };

        return Next{ .location = .{ .value = next_value }, .codepoint = codepoint };
    }

    fn read(source: Source, start: Location, buffer: []u21) Location {
        var location = start;
        for (buffer) |*codepoint| {
            const next_ = source.next(location);
            codepoint.* = next_.codepoint;
            location = next_.location;
        }
        return location;
    }
};

pub const IdentSequenceIterator = struct {
    location: Source.Location,

    pub fn next(it: *IdentSequenceIterator, source: Source) ?u21 {
        const next_ = consumeIdentSequenceCodepoint(source, it.location) orelse return null;
        it.location = next_.location;
        return next_.codepoint;
    }
};

pub fn stringIsIdentSequence(string: []const u8) !bool {
    const source = try Source.init(string);
    var location = Source.Location{};
    var first_3: [3]u21 = undefined;
    _ = source.read(location, &first_3);
    if (!codepointsStartAnIdentSequence(first_3)) return false;
    location = consumeIdentSequence(source, location);
    return source.next(location).codepoint == eof_codepoint;
}

pub const NextToken = struct { tag: Tag, next_location: Source.Location };

pub fn nextToken(source: Source, location: Source.Location) NextToken {
    const next = source.next(location);
    switch (next.codepoint) {
        '/' => {
            const asterisk = source.next(next.location);
            if (asterisk.codepoint == '*') {
                return consumeComments(source, location);
            } else {
                return NextToken{ .tag = .token_delim, .next_location = next.location };
            }
        },
        '\n', '\t', ' ' => {
            const after_whitespace = consumeWhitespace(source, next.location);
            return NextToken{ .tag = .token_whitespace, .next_location = after_whitespace };
        },
        '"' => return consumeStringToken(source, next.location, '"'),
        '#' => return numberSign(source, next.location),
        '\'' => return consumeStringToken(source, next.location, '\''),
        '(' => return NextToken{ .tag = .token_left_paren, .next_location = next.location },
        ')' => return NextToken{ .tag = .token_right_paren, .next_location = next.location },
        '+', '.' => {
            var next_3 = [3]u21{ next.codepoint, undefined, undefined };
            _ = source.read(next.location, next_3[1..3]);
            if (codepointsStartANumber(next_3)) {
                return consumeNumericToken(source, location);
            } else {
                return NextToken{ .tag = .token_delim, .next_location = next.location };
            }
        },
        ',' => return NextToken{ .tag = .token_comma, .next_location = next.location },
        '-' => {
            var next_3 = [3]u21{ '-', undefined, undefined };
            const after_cdc = source.read(next.location, next_3[1..3]);
            if (next_3[1] == '-' and next_3[2] == '>') {
                return NextToken{ .tag = .token_cdc, .next_location = after_cdc };
            }

            if (codepointsStartANumber(next_3)) {
                return consumeNumericToken(source, location);
            } else if (codepointsStartAnIdentSequence(next_3)) {
                return consumeIdentLikeToken(source, location);
            } else {
                return NextToken{ .tag = .token_delim, .next_location = next.location };
            }
        },
        ':' => return NextToken{ .tag = .token_colon, .next_location = next.location },
        ';' => return NextToken{ .tag = .token_semicolon, .next_location = next.location },
        '<' => {
            var next_3: [3]u21 = undefined;
            const after_cdo = source.read(next.location, &next_3);
            if (next_3[0] == '!' and next_3[1] == '-' and next_3[2] == '-') {
                return NextToken{ .tag = .token_cdo, .next_location = after_cdo };
            } else {
                return NextToken{ .tag = .token_delim, .next_location = next.location };
            }
        },
        '@' => {
            var next_3: [3]u21 = undefined;
            _ = source.read(next.location, &next_3);

            if (codepointsStartAnIdentSequence(next_3)) {
                const after_ident = consumeIdentSequence(source, next.location);
                return NextToken{ .tag = .token_at_keyword, .next_location = after_ident };
            } else {
                return NextToken{ .tag = .token_delim, .next_location = next.location };
            }
        },
        '[' => return NextToken{ .tag = .token_left_square, .next_location = next.location },
        '\\' => {
            const first_escaped = source.next(next.location);
            if (isValidFirstEscapedCodepoint(first_escaped.codepoint)) {
                return consumeIdentLikeToken(source, location);
            } else {
                // NOTE: Parse error
                return NextToken{ .tag = .token_delim, .next_location = next.location };
            }
        },
        ']' => return NextToken{ .tag = .token_right_square, .next_location = next.location },
        '{' => return NextToken{ .tag = .token_left_curly, .next_location = next.location },
        '}' => return NextToken{ .tag = .token_right_curly, .next_location = next.location },
        '0'...'9' => return consumeNumericToken(source, location),
        'A'...'Z',
        'a'...'z',
        '_',
        0x80...0x10FFFF,
        => return consumeIdentLikeToken(source, location),
        eof_codepoint => return NextToken{ .tag = .token_eof, .next_location = next.location },
        else => return NextToken{ .tag = .token_delim, .next_location = next.location },
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

fn consumeComments(source: Source, start: Source.Location) NextToken {
    var location = start;
    outer: while (true) {
        var next_2: [2]u21 = undefined;
        const comment_start = source.read(location, &next_2);
        if (next_2[0] == '/' and next_2[1] == '*') {
            location = comment_start;
            while (true) {
                const next = source.next(location);
                switch (next.codepoint) {
                    '*' => {
                        const comment_end = source.next(next.location);
                        if (comment_end.codepoint == '/') {
                            location = comment_end.location;
                            break;
                        }
                    },
                    eof_codepoint => {
                        // NOTE: Parse error
                        break :outer;
                    },
                    else => {},
                }
                location = next.location;
            }
        } else {
            break;
        }
    }
    return NextToken{ .tag = .token_comments, .next_location = location };
}

fn consumeWhitespace(source: Source, start: Source.Location) Source.Location {
    var location = start;
    while (true) {
        const next = source.next(location);
        switch (next.codepoint) {
            '\n', '\t', ' ' => location = next.location,
            else => return location,
        }
    }
}

fn consumeStringToken(source: Source, after_quote: Source.Location, ending_codepoint: u21) NextToken {
    var location = after_quote;
    while (true) {
        var next = source.next(location);
        switch (next.codepoint) {
            '\n' => {
                // NOTE: Parse error
                return NextToken{ .tag = .token_bad_string, .next_location = location };
            },
            '\\' => {
                const first_escaped = source.next(next.location);
                if (first_escaped.codepoint == '\n') {
                    location = first_escaped.location;
                } else if (first_escaped.codepoint == eof_codepoint) {
                    location = next.location;
                } else {
                    location = consumeEscapedCodepoint(source, first_escaped).location;
                }
            },
            eof_codepoint => {
                // NOTE: Parse error
                break;
            },
            else => {
                location = next.location;
                if (next.codepoint == ending_codepoint) {
                    break;
                }
            },
        }
    }

    return NextToken{ .tag = .token_string, .next_location = location };
}

fn consumeEscapedCodepoint(source: Source, first_escaped: Source.Next) Source.Next {
    var location = first_escaped.location;
    const codepoint = switch (first_escaped.codepoint) {
        '0'...'9', 'A'...'F', 'a'...'f' => blk: {
            var result: u21 = hexDigitToNumber(first_escaped.codepoint);
            var count: u3 = 0;
            while (count < 5) : (count += 1) {
                const next = source.next(location);
                switch (next.codepoint) {
                    '0'...'9', 'A'...'F', 'a'...'f' => {
                        result = result *| 16 +| hexDigitToNumber(next.codepoint);
                        location = next.location;
                    },
                    else => break,
                }
            }

            const whitespace = source.next(location);
            switch (whitespace.codepoint) {
                '\n', '\t', ' ' => location = whitespace.location,
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

    return Source.Next{ .codepoint = codepoint, .location = location };
}

fn consumeNumericToken(source: Source, start: Source.Location) NextToken {
    const result = consumeNumber(source, start);

    var next_3: [3]u21 = undefined;
    _ = source.read(result.after_number, &next_3);

    if (codepointsStartAnIdentSequence(next_3)) {
        const after_ident = consumeIdentSequence(source, result.after_number);
        return NextToken{ .tag = .token_dimension, .next_location = after_ident };
    }

    const percent_sign = source.next(result.after_number);
    if (percent_sign.codepoint == '%') {
        return NextToken{ .tag = .token_percentage, .next_location = percent_sign.location };
    }

    return NextToken{ .tag = .token_number, .next_location = result.after_number };
}

const ConsumeNumber = struct {
    const Type = enum { integer, number };

    type: Type,
    after_number: Source.Location,
};

fn consumeNumber(source: Source, start: Source.Location) ConsumeNumber {
    var number_type = ConsumeNumber.Type.integer;
    var location = start;

    const leading_sign = source.next(location);
    if (leading_sign.codepoint == '+' or leading_sign.codepoint == '-') {
        location = leading_sign.location;
    }

    location = consumeDigits(source, location);

    var next_2: [2]u21 = undefined;
    const after_first_decimal = source.read(location, &next_2);
    if (next_2[0] == '.') {
        switch (next_2[1]) {
            '0'...'9' => {
                number_type = .number;
                location = consumeDigits(source, after_first_decimal);
            },
            else => {},
        }
    }

    const e = source.next(location);
    if (e.codepoint == 'e' or e.codepoint == 'E') {
        var location2 = e.location;
        const exponent_sign = source.next(location2);
        if (exponent_sign.codepoint == '+' or exponent_sign.codepoint == '-') {
            location2 = exponent_sign.location;
        }

        const first_exponent_digit = source.next(location2);
        switch (first_exponent_digit.codepoint) {
            '0'...'9' => {
                number_type = .number;
                location = consumeDigits(source, first_exponent_digit.location);
            },
            else => {},
        }
    }

    return ConsumeNumber{ .type = number_type, .after_number = location };
}

fn consumeDigits(source: Source, start: Source.Location) Source.Location {
    var location = start;
    while (true) {
        const next = source.next(location);
        switch (next.codepoint) {
            '0'...'9' => location = next.location,
            else => return location,
        }
    }
}

fn consumeIdentSequenceCodepoint(source: Source, location: Source.Location) ?Source.Next {
    const next = source.next(location);
    switch (next.codepoint) {
        '\\' => {
            const first_escaped = source.next(next.location);
            if (!isValidFirstEscapedCodepoint(first_escaped.codepoint)) {
                return null;
            }
            return consumeEscapedCodepoint(source, first_escaped);
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

fn consumeIdentSequence(source: Source, start: Source.Location) Source.Location {
    var location = start;
    while (consumeIdentSequenceCodepoint(source, location)) |next| {
        location = next.location;
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
) ComsumeIdentSequenceMatch {
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
    while (consumeIdentSequenceCodepoint(source, location)) |next| {
        location = next.location;
        string_matcher.nextCodepoint(string, next.codepoint);
        if (keep_going) continue;
        if (string_matcher.matches == false) {
            return ComsumeIdentSequenceMatch{ .after_ident = undefined, .matches = false };
        }
    }

    return ComsumeIdentSequenceMatch{ .after_ident = location, .matches = string_matcher.matches orelse false };
}

fn consumeIdentLikeToken(source: Source, start: Source.Location) NextToken {
    const result = consumeIdentSequenceMatch(source, start, &.{ 'u', 'r', 'l' }, true, true);

    const left_paren = source.next(result.after_ident);
    if (left_paren.codepoint == '(') {
        if (result.matches) {
            var previous_location: Source.Location = undefined;
            var location = left_paren.location;
            var has_preceding_whitespace = false;
            while (true) {
                const next = source.next(location);
                switch (next.codepoint) {
                    '\n', '\t', ' ' => {
                        has_preceding_whitespace = true;
                        previous_location = location;
                        location = next.location;
                    },
                    '\'', '"' => {
                        if (has_preceding_whitespace) {
                            location = previous_location;
                        }
                        return NextToken{ .tag = .token_function, .next_location = location };
                    },
                    else => return consumeUrlToken(source, location),
                }
            }
        }

        return NextToken{ .tag = .token_function, .next_location = left_paren.location };
    }

    return NextToken{ .tag = .token_ident, .next_location = result.after_ident };
}

fn consumeUrlToken(source: Source, start: Source.Location) NextToken {
    var location = consumeWhitespace(source, start);
    while (true) {
        const next = source.next(location);
        switch (next.codepoint) {
            ')' => break,
            '\n', '\t', ' ' => {
                location = consumeWhitespace(source, next.location);
                const right_paren = source.next(location);
                if (right_paren.codepoint == eof_codepoint) {
                    // NOTE: Parse error
                    break;
                } else if (right_paren.codepoint == ')') {
                    break;
                } else {
                    return consumeBadUrl(source, next.location);
                }
            },
            '"', '\'', '(', 0x00...0x08, 0x0B, 0x0E...0x1F, 0x7F => {
                // NOTE: Parse error
                return consumeBadUrl(source, next.location);
            },
            '\\' => {
                const first_escaped = source.next(location);
                if (isValidFirstEscapedCodepoint(first_escaped.codepoint)) {
                    location = consumeEscapedCodepoint(source, first_escaped).location;
                } else {
                    // NOTE: Parse error
                    return consumeBadUrl(source, next.location);
                }
            },
            eof_codepoint => {
                // NOTE: Parse error
                break;
            },
            else => location = next.location,
        }
    }

    return NextToken{ .tag = .token_url, .next_location = location };
}

fn consumeBadUrl(source: Source, start: Source.Location) NextToken {
    var location = start;
    while (true) {
        const next = source.next(location);
        switch (next.codepoint) {
            ')', eof_codepoint => {
                location = next.location;
                break;
            },
            '\\' => {
                const first_escaped = source.next(location);
                if (isValidFirstEscapedCodepoint(first_escaped.codepoint)) {
                    location = consumeEscapedCodepoint(source, first_escaped).location;
                } else {
                    location = next.location;
                }
            },
            else => location = next.location,
        }
    }
    return NextToken{ .tag = .token_bad_url, .next_location = location };
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

fn numberSign(source: Source, after_number_sign: Source.Location) NextToken {
    var next_3: [3]u21 = undefined;
    const after_first_two = source.read(after_number_sign, next_3[0..2]);
    if (!codepointsStartAHash(next_3[0..2].*)) {
        return NextToken{ .tag = .token_delim, .next_location = after_number_sign };
    }

    next_3[2] = source.next(after_first_two).codepoint;
    const tag: Tag = if (codepointsStartAnIdentSequence(next_3)) .token_hash_id else .token_hash_unrestricted;
    const after_ident = consumeIdentSequence(source, after_number_sign);
    return NextToken{ .tag = tag, .next_location = after_ident };
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
    const expected = [_]Tag{
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
        .token_right_paren,
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
        const next = nextToken(source, location);
        const tag = next.tag;
        try std.testing.expectEqual(expected[i], tag);
        if (tag == .token_eof) break;
        location = next.next_location;
        i += 1;
    }
}
