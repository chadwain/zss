//! Implements the Tokenizer specified in CSS Syntax Level 3.

const std = @import("std");

const zss = @import("../../zss.zig");
const Tag = zss.syntax.Component.Tag;
const asciiString = zss.util.asciiString;

const u21_max = std.math.maxInt(u21);
const replacement_character: u21 = 0xfffd;
const eof_codepoint: u21 = std.math.maxInt(u21);

pub const CodepointSource = struct {
    data: []const u7,
    index: u32,

    pub const Location = zss.syntax.Source.Location;

    pub fn init(data: []const u7) !CodepointSource {
        if (data.len > std.math.maxInt(Location.Value)) return error.Overflow;
        return CodepointSource{ .data = data, .index = 0 };
    }

    pub fn next(source: *CodepointSource) u21 {
        if (source.index == source.data.len) return eof_codepoint;
        defer source.index += 1;
        const codepoint: u21 = switch (source.data[source.index]) {
            0x00 => replacement_character,
            '\r' => blk: {
                if (source.index + 1 < source.data.len and source.data[source.index + 1] == '\n') {
                    source.index += 1;
                }
                break :blk '\n';
            },
            0x0C => '\n',
            else => |c| c,
        };
        return codepoint;
    }

    fn back(source: *CodepointSource) void {
        source.index -= 1;
        if (source.data[source.index] == '\n' and source.index > 0 and source.data[source.index - 1] == '\r') {
            source.index -= 1;
        }
    }

    pub fn location(source: CodepointSource) Location {
        return Location{ .value = source.index };
    }

    pub fn seek(source: *CodepointSource, loc: Location) void {
        std.debug.assert(loc.value <= source.data.len);
        source.index = loc.value;
    }

    pub fn matchDelimeter(source: *CodepointSource, codepoint: u21) bool {
        const loc = source.location();
        if (source.next() == codepoint) {
            return true;
        } else {
            source.seek(loc);
            return false;
        }
    }

    pub fn matchKeyword(source: *CodepointSource, keyword: []const u7) bool {
        for (keyword) |kw| {
            const next_location = source.location();
            const codepoint = source.next();
            const actual_codepoint = switch (codepoint) {
                '\\' => blk: {
                    const second_codepoint = source.next();
                    if (isSecondCodepointOfAnEscape(second_codepoint)) {
                        break :blk consumeEscapedCodepoint(source, second_codepoint);
                    } else {
                        break :blk null;
                    }
                },
                '0'...'9',
                'A'...'Z',
                'a'...'z',
                '-',
                '_',
                0x80...0x10FFFF,
                => codepoint,
                else => null,
            };

            if (actual_codepoint == null or toLowercase(kw) != toLowercase(actual_codepoint.?)) {
                source.seek(next_location);
                return false;
            }
        }

        return true;
    }

    fn matchAscii(source: *CodepointSource, string: []const u7) bool {
        if (source.data.len - source.index >= string.len and std.mem.eql(u7, source.data[source.index..][0..string.len], string)) {
            source.index += @intCast(u32, string.len);
            return true;
        } else {
            return false;
        }
    }
};

pub fn nextToken(source: *CodepointSource) Tag {
    const location = source.location();
    const codepoint = source.next();
    switch (codepoint) {
        '/' => {
            const next_location = source.location();
            if (source.next() == '*') {
                source.seek(location);
                return consumeComments(source);
            } else {
                source.seek(next_location);
                return .token_delim;
            }
        },
        '\n', '\t', ' ' => {
            consumeWhitespace(source);
            return .token_whitespace;
        },
        '"' => return consumeStringToken(source, '"'),
        '#' => return numberSign(source),
        '\'' => return consumeStringToken(source, '\''),
        '(' => return .token_left_paren,
        ')' => return .token_right_paren,
        '+' => return plusOrFullStop(source, location),
        ',' => return .token_comma,
        '-' => return minus(source, location),
        '.' => return plusOrFullStop(source, location),
        ':' => return .token_colon,
        ';' => return .token_semicolon,
        '<' => {
            if (source.matchAscii(asciiString("!--"))) {
                return .token_cdo;
            } else {
                return .token_delim;
            }
        },
        '@' => return commercialAt(source),
        '[' => return .token_left_bracket,
        '\\' => {
            const next_location = source.location();
            const next = source.next();
            if (isSecondCodepointOfAnEscape(next)) {
                source.seek(location);
                return consumeIdentLikeToken(source);
            } else {
                source.seek(next_location);
                return .token_delim;
            }
        },
        ']' => return .token_right_bracket,
        '{' => return .token_left_curly,
        '}' => return .token_right_curly,
        '0'...'9' => {
            source.seek(location);
            return consumeNumericToken(source);
        },
        'A'...'Z',
        'a'...'z',
        '_',
        0x80...0x10FFFF,
        => {
            source.seek(location);
            return consumeIdentLikeToken(source);
        },
        eof_codepoint => return .token_eof,
        else => return .token_delim,
    }
}

fn toLowercase(codepoint: u21) u21 {
    return switch (codepoint) {
        'A'...'Z' => codepoint - 'A' + 'a',
        else => codepoint,
    };
}

fn hexDigitToNumber(codepoint: u21) u4 {
    return @intCast(u4, switch (codepoint) {
        '0'...'9' => codepoint - '0',
        'A'...'F' => codepoint - 'A' + 10,
        'a'...'f' => codepoint - 'a' + 10,
        else => unreachable,
    });
}

fn isIdentCodepoint(codepoint: u21) bool {
    switch (codepoint) {
        '0'...'9',
        'A'...'Z',
        'a'...'z',
        '-',
        '_',
        0x80...0x10FFFF,
        => return true,
        else => return false,
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

fn isSecondCodepointOfAnEscape(codepoint: u21) bool {
    return codepoint != '\n';
}

fn codepointsStartAnIdentSequence(codepoints: [3]u21) bool {
    return switch (codepoints[0]) {
        '-' => return isIdentStartCodepoint(codepoints[1]) or
            (codepoints[1] == '-') or
            (codepoints[1] == '\\' and isSecondCodepointOfAnEscape(codepoints[2])),

        'A'...'Z',
        'a'...'z',
        '_',
        0x80...0x10FFFF,
        => true,

        '\\' => return isSecondCodepointOfAnEscape(codepoints[1]),

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

fn consumeComments(source: *CodepointSource) Tag {
    outer: while (true) {
        const next_location = source.location();
        if (source.next() == '/' and source.next() == '*') {
            while (true) {
                const codepoint = source.next();
                if (codepoint == eof_codepoint) {
                    // NOTE: Parse error
                    break :outer;
                }

                if (codepoint == '*' and source.next() == '/') break;
            }
        } else {
            break source.seek(next_location);
        }
    }
    return .token_comments;
}

fn consumeWhitespace(source: *CodepointSource) void {
    while (true) {
        const next_location = source.location();
        const codepoint = source.next();
        switch (codepoint) {
            '\n', '\t', ' ' => {},
            else => break source.seek(next_location),
        }
    }
}

fn consumeStringToken(source: *CodepointSource, comptime ending_codepoint: u21) Tag {
    while (true) {
        const codepoint = source.next();
        switch (codepoint) {
            ending_codepoint => break,
            '\n' => {
                // NOTE: Parse error
                source.back();
                return .token_bad_string;
            },
            '\\' => {
                const next_codepoint = source.next();
                if (next_codepoint != '\n' and next_codepoint != eof_codepoint) {
                    _ = consumeEscapedCodepoint(source, next_codepoint);
                }
            },
            eof_codepoint => {
                // NOTE: Parse error
                break;
            },
            else => {},
        }
    }

    return .token_string;
}

fn consumeEscapedCodepoint(source: *CodepointSource, first_codepoint: u21) u21 {
    switch (first_codepoint) {
        '0'...'9', 'A'...'F', 'a'...'f' => {
            var result: u21 = hexDigitToNumber(first_codepoint);
            var count: u3 = 0;
            while (count < 5) : (count += 1) {
                const next_location = source.location();
                const codepoint = source.next();
                switch (codepoint) {
                    '0'...'9', 'A'...'F', 'a'...'f' => result = result *| 16 +| hexDigitToNumber(codepoint),
                    eof_codepoint => break,
                    else => break source.seek(next_location),
                }
            }

            const whitespace = source.next();
            switch (whitespace) {
                '\n', '\t', ' ', eof_codepoint => {},
                else => source.back(),
            }

            switch (result) {
                0x00,
                0xD800...0xDBFF,
                0xDC00...0xDFFF,
                0x110000...u21_max,
                => return replacement_character,
                else => return result,
            }
        },
        eof_codepoint => {
            // NOTE: Parse error
            return replacement_character;
        },
        '\n' => unreachable,
        else => return first_codepoint,
    }
}

fn consumeNumericToken(source: *CodepointSource) Tag {
    const number_type = consumeNumber(source);
    _ = number_type;

    const next_location = source.location();
    var next_3: [3]u21 = undefined;
    for (&next_3) |*codepoint| codepoint.* = source.next();
    source.seek(next_location);

    if (codepointsStartAnIdentSequence(next_3)) {
        _ = consumeIdentSequence(source, false);
        return .token_dimension;
    }

    const percent_sign = source.next();
    if (percent_sign == '%') {
        return .token_percentage;
    }

    source.seek(next_location);
    return .token_number;
}

const NumberType = enum { integer, number };

fn consumeNumber(source: *CodepointSource) NumberType {
    var result = NumberType.integer;
    var next_location = source.location();

    {
        const plus_or_minus = source.next();
        if (plus_or_minus != '+' and plus_or_minus != '-') {
            source.seek(next_location);
        }
    }

    consumeDigits(source);

    next_location = source.location();
    decimal: {
        const decimal_point = source.next();
        if (decimal_point != '.') break :decimal source.seek(next_location);
        const digit = source.next();
        switch (digit) {
            '0'...'9' => {
                result = .number;
                consumeDigits(source);
            },
            else => break :decimal source.seek(next_location),
        }
    }

    next_location = source.location();
    exponent: {
        const e = source.next();
        if (e != 'e' and e != 'E') break :exponent source.seek(next_location);

        const plus_or_minus_location = source.location();
        const plus_or_minus = source.next();
        if (plus_or_minus != '+' and plus_or_minus != '-') {
            source.seek(plus_or_minus_location);
        }

        const digit = source.next();
        switch (digit) {
            '0'...'9' => {
                result = .number;
                consumeDigits(source);
            },
            else => break :exponent source.seek(next_location),
        }
    }

    return result;
}

fn consumeDigits(source: *CodepointSource) void {
    while (true) {
        const next_location = source.location();
        switch (source.next()) {
            '0'...'9' => {},
            else => break source.seek(next_location),
        }
    }
}

// Returns true if the ident sequence is "url", case-insensitively.
fn consumeIdentSequence(source: *CodepointSource, look_for_url: bool) bool {
    var string_matcher: struct {
        num_matching_codepoints: u2 = 0,
        matches: ?bool = null,

        const url = "url";

        fn nextCodepoint(self: *@This(), codepoint: u21) void {
            if (self.matches == null) {
                if (url[self.num_matching_codepoints] == toLowercase(codepoint)) {
                    self.num_matching_codepoints += 1;
                    if (self.num_matching_codepoints == url.len) {
                        self.matches = true;
                    }
                } else {
                    self.matches = false;
                }
            } else {
                self.matches = false;
            }
        }
    } = undefined;
    if (look_for_url) string_matcher = .{};

    while (true) {
        const next_location = source.location();
        const codepoint = source.next();
        switch (codepoint) {
            '\\' => {
                const second_codepoint = source.next();
                if (isSecondCodepointOfAnEscape(second_codepoint)) {
                    const escaped_codepoint = consumeEscapedCodepoint(source, second_codepoint);
                    if (look_for_url) string_matcher.nextCodepoint(escaped_codepoint);
                } else {
                    source.seek(next_location);
                    break;
                }
            },
            '0'...'9',
            'A'...'Z',
            'a'...'z',
            '-',
            '_',
            0x80...0x10FFFF,
            => {
                if (look_for_url) string_matcher.nextCodepoint(codepoint);
            },
            eof_codepoint => break,
            else => break source.back(),
        }
    }

    return if (look_for_url) (string_matcher.matches orelse false) else @as(bool, undefined);
}

fn consumeIdentLikeToken(source: *CodepointSource) Tag {
    const is_url = consumeIdentSequence(source, true);
    const next_location = source.location();

    if (source.next() == '(') {
        if (is_url) {
            var preceding_whitespace = false;
            while (true) {
                const codepoint = source.next();
                switch (codepoint) {
                    '\n', '\t', ' ' => preceding_whitespace = true,
                    '\'', '"' => {
                        source.back();
                        if (preceding_whitespace) {
                            source.back();
                        }
                        break;
                    },
                    else => {
                        if (codepoint != eof_codepoint) {
                            source.back();
                        }
                        if (preceding_whitespace) {
                            source.back();
                        }
                        return consumeUrlToken(source);
                    },
                }
            }
        }

        return .token_function;
    }

    source.seek(next_location);
    return .token_ident;
}

fn consumeUrlToken(source: *CodepointSource) Tag {
    consumeWhitespace(source);
    while (true) {
        const codepoint = source.next();
        switch (codepoint) {
            ')' => break,
            '\n', '\t', ' ' => {
                consumeWhitespace(source);
                const right_paren = source.next();
                if (right_paren == eof_codepoint) {
                    // NOTE: Parse error
                    break;
                } else if (right_paren == ')') {
                    break;
                } else {
                    source.back();
                    return consumeBadUrl(source);
                }
            },
            '"', '\'', '(', 0x00...0x08, 0x0B, 0x0E...0x1F, 0x7F => {
                // NOTE: Parse error
                return consumeBadUrl(source);
            },
            '\\' => {
                const next_codepoint = source.next();
                if (isSecondCodepointOfAnEscape(next_codepoint)) {
                    _ = consumeEscapedCodepoint(source, next_codepoint);
                } else {
                    // NOTE: Parse error
                    return consumeBadUrl(source);
                }
            },
            eof_codepoint => {
                // NOTE: Parse error
                break;
            },
            else => {},
        }
    }

    return .token_url;
}

fn consumeBadUrl(source: *CodepointSource) Tag {
    while (true) {
        const codepoint = source.next();
        switch (codepoint) {
            ')', eof_codepoint => break,
            '\\' => {
                const next_codepoint = source.next();
                if (isSecondCodepointOfAnEscape(next_codepoint)) {
                    _ = consumeEscapedCodepoint(source, next_codepoint);
                } else {
                    source.back();
                }
            },
            else => {},
        }
    }
    return .token_bad_url;
}

fn numberSign(source: *CodepointSource) Tag {
    const next_location = source.location();
    blk: {
        const first = source.next();
        var second: u21 = eof_codepoint;
        if (!isIdentCodepoint(first)) {
            if (first != '\\') break :blk;
            second = source.next();
            if (!isSecondCodepointOfAnEscape(second)) break :blk;
        }

        var tag: Tag = .token_hash_unrestricted;
        if (second == eof_codepoint) second = source.next();
        const third = source.next();
        if (codepointsStartAnIdentSequence([3]u21{ first, second, third })) {
            tag = .token_hash_id;
        }

        source.seek(next_location);
        _ = consumeIdentSequence(source, false);
        return tag;
    }

    source.seek(next_location);
    return .token_delim;
}

fn plusOrFullStop(source: *CodepointSource, location: CodepointSource.Location) Tag {
    const next_location = source.location();
    var next_3: [3]u21 = undefined;
    for (&next_3) |*codepoint| codepoint.* = source.next();
    if (codepointsStartANumber(next_3)) {
        source.seek(location);
        return consumeNumericToken(source);
    } else {
        source.seek(next_location);
        return .token_delim;
    }
}

fn minus(source: *CodepointSource, location: CodepointSource.Location) Tag {
    if (source.matchAscii(asciiString("->"))) {
        return .token_cdc;
    }

    const next_location = source.location();
    var next_3: [3]u21 = undefined;
    for (&next_3) |*codepoint| codepoint.* = source.next();

    if (codepointsStartANumber(next_3)) {
        source.seek(location);
        return consumeNumericToken(source);
    } else if (codepointsStartAnIdentSequence(next_3)) {
        source.seek(location);
        return consumeIdentLikeToken(source);
    } else {
        source.seek(next_location);
        return .token_delim;
    }
}

fn commercialAt(source: *CodepointSource) Tag {
    const next_location = source.location();
    var next_3: [3]u21 = undefined;
    for (&next_3) |*codepoint| codepoint.* = source.next();
    source.seek(next_location);

    if (codepointsStartAnIdentSequence(next_3)) {
        _ = consumeIdentSequence(source, false);
        return .token_at_keyword;
    } else {
        return .token_delim;
    }
}

test "tokenizer" {
    const input =
        \\@charset "utf-8";
        \\
        \\body {
        \\    rule: value;
        \\}
        \\
        \\end
    ;
    var source = try CodepointSource.init(asciiString(input));
    var expected = [_]Tag{
        .token_at_keyword,
        .token_whitespace,
        .token_string,
        .token_semicolon,
        .token_whitespace,
        .token_ident,
        .token_whitespace,
        .token_left_curly,
        .token_whitespace,
        .token_ident,
        .token_colon,
        .token_whitespace,
        .token_ident,
        .token_semicolon,
        .token_whitespace,
        .token_right_curly,
        .token_whitespace,
        .token_ident,
        .token_eof,
    };

    var i: usize = 0;
    while (true) {
        if (i >= expected.len) return error.TestFailure;
        const tag = nextToken(&source);
        try std.testing.expectEqual(expected[i], tag);
        if (tag == .token_eof) break;
        i += 1;
    }
}
