//! Implements the Tokenizer specified in CSS Syntax Level 3.

const std = @import("std");

pub const Token = struct {
    tag: Tag,
    start: Source.Location,

    pub const Tag = enum {
        eof,
        ident,
        function,
        at_keyword,
        hash_unrestricted,
        hash_id,
        string,
        bad_string,
        url,
        bad_url,
        delim,
        number,
        percentage,
        dimension,
        whitespace,
        cdo,
        cdc,
        colon,
        semicolon,
        comma,
        left_bracket,
        right_bracket,
        left_paren,
        right_paren,
        left_curly,
        right_curly,
        comments,
    };
};

const u21_max = std.math.maxInt(u21);
const replacement_character: u21 = 0xfffd;
const eof_codepoint: u21 = std.math.maxInt(u21);

pub const Source = struct {
    data: []const u7,
    index: u32,

    const Location = u32;

    pub fn init(data: []const u7) !Source {
        if (data.len > std.math.maxInt(Location)) return error.Overflow;
        return Source{ .data = data, .index = 0 };
    }

    fn next(source: *Source) u21 {
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

    fn back(source: *Source) void {
        source.index -= 1;
        if (source.data[source.index] == '\n' and source.index > 0 and source.data[source.index - 1] == '\r') {
            source.index -= 1;
        }
    }

    fn location(source: Source) Location {
        return source.index;
    }

    fn seek(source: *Source, location_: Location) void {
        std.debug.assert(location_ <= source.data.len);
        source.index = location_;
    }

    fn matchAscii(source: *Source, string: []const u7) bool {
        if (source.data.len - source.index >= string.len and std.mem.eql(u7, source.data[source.index..][0..string.len], string)) {
            source.index += @intCast(u32, string.len);
            return true;
        } else {
            return false;
        }
    }
};

pub fn nextToken(source: *Source) Token {
    const location = source.location();
    const codepoint = source.next();
    switch (codepoint) {
        '/' => {
            const next_location = source.location();
            if (source.next() == '*') {
                source.seek(location);
                return consumeComments(source, location);
            } else {
                source.seek(next_location);
                return Token{ .tag = .delim, .start = location };
            }
        },
        '\n', '\t', ' ' => {
            consumeWhitespace(source);
            return Token{ .tag = .whitespace, .start = location };
        },
        '"' => return consumeStringToken(source, location, '"'),
        '#' => return numberSign(source, location),
        '\'' => return consumeStringToken(source, location, '\''),
        '(' => return Token{ .tag = .left_paren, .start = location },
        ')' => return Token{ .tag = .right_paren, .start = location },
        '+' => return plusOrFullStop(source, location),
        ',' => return Token{ .tag = .comma, .start = location },
        '-' => return minus(source, location),
        '.' => return plusOrFullStop(source, location),
        ':' => return Token{ .tag = .colon, .start = location },
        ';' => return Token{ .tag = .semicolon, .start = location },
        '<' => {
            if (source.matchAscii(asciiString("!--"))) {
                return Token{ .tag = .cdo, .start = location };
            } else {
                return Token{ .tag = .delim, .start = location };
            }
        },
        '@' => return commercialAt(source, location),
        '[' => return Token{ .tag = .left_bracket, .start = location },
        '\\' => {
            const next_location = source.location();
            const next = source.next();
            if (isSecondCodepointOfAnEscape(next)) {
                source.seek(location);
                return consumeIdentLikeToken(source, location);
            } else {
                source.seek(next_location);
                return Token{ .tag = .delim, .start = location };
            }
        },
        ']' => return Token{ .tag = .right_bracket, .start = location },
        '{' => return Token{ .tag = .left_curly, .start = location },
        '}' => return Token{ .tag = .right_curly, .start = location },
        '0'...'9' => {
            source.seek(location);
            return consumeNumericToken(source, location);
        },
        'A'...'Z',
        'a'...'z',
        '_',
        0x80...0x10FFFF,
        => {
            source.seek(location);
            return consumeIdentLikeToken(source, location);
        },
        eof_codepoint => return Token{ .tag = .eof, .start = location },
        else => return Token{ .tag = .delim, .start = location },
    }
}

fn asciiString(comptime string: []const u8) *const [string.len]u7 {
    comptime {
        var result: [string.len]u7 = undefined;
        for (string) |c, i| {
            result[i] = std.math.cast(u7, c) orelse unreachable;
        }
        return &result;
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

fn consumeComments(source: *Source, location: Source.Location) Token {
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
    return Token{ .tag = .comments, .start = location };
}

fn consumeWhitespace(source: *Source) void {
    while (true) {
        const next_location = source.location();
        const codepoint = source.next();
        switch (codepoint) {
            '\n', '\t', ' ' => {},
            else => break source.seek(next_location),
        }
    }
}

fn consumeStringToken(source: *Source, location: Source.Location, comptime ending_codepoint: u21) Token {
    while (true) {
        const codepoint = source.next();
        switch (codepoint) {
            ending_codepoint => break,
            '\n' => {
                // NOTE: Parse error
                source.back();
                return Token{ .tag = .bad_string, .start = location };
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

    return Token{ .tag = .string, .start = location };
}

fn consumeEscapedCodepoint(source: *Source, first_codepoint: u21) u21 {
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

fn consumeNumericToken(source: *Source, location: Source.Location) Token {
    const number_type = consumeNumber(source);
    _ = number_type;

    const next_location = source.location();
    var next_3: [3]u21 = undefined;
    for (next_3) |*codepoint| codepoint.* = source.next();
    source.seek(next_location);

    if (codepointsStartAnIdentSequence(next_3)) {
        _ = consumeIdentSequence(source, false);
        return Token{ .tag = .dimension, .start = location };
    }

    const percent_sign = source.next();
    if (percent_sign == '%') {
        return Token{ .tag = .percentage, .start = location };
    }

    source.seek(next_location);
    return Token{ .tag = .number, .start = location };
}

const NumberType = enum { integer, number };

fn consumeNumber(source: *Source) NumberType {
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

fn consumeDigits(source: *Source) void {
    while (true) {
        const next_location = source.location();
        switch (source.next()) {
            '0'...'9' => {},
            else => break source.seek(next_location),
        }
    }
}

// Returns true if the ident sequence is "url", case-insensitively.
fn consumeIdentSequence(source: *Source, look_for_url: bool) bool {
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

fn consumeIdentLikeToken(source: *Source, location: Source.Location) Token {
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
                        return consumeUrlToken(source, location);
                    },
                }
            }
        }

        return Token{ .tag = .function, .start = location };
    }

    source.seek(next_location);
    return Token{ .tag = .ident, .start = location };
}

fn consumeUrlToken(source: *Source, location: Source.Location) Token {
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
                    return consumeBadUrl(source, location);
                }
            },
            '"', '\'', '(', 0x00...0x08, 0x0B, 0x0E...0x1F, 0x7F => {
                // NOTE: Parse error
                return consumeBadUrl(source, location);
            },
            '\\' => {
                const next_codepoint = source.next();
                if (isSecondCodepointOfAnEscape(next_codepoint)) {
                    _ = consumeEscapedCodepoint(source, next_codepoint);
                } else {
                    // NOTE: Parse error
                    return consumeBadUrl(source, location);
                }
            },
            eof_codepoint => {
                // NOTE: Parse error
                break;
            },
            else => {},
        }
    }

    return Token{ .tag = .url, .start = location };
}

fn consumeBadUrl(source: *Source, location: Source.Location) Token {
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
    return Token{ .tag = .bad_url, .start = location };
}

fn numberSign(source: *Source, location: Source.Location) Token {
    const next_location = source.location();
    blk: {
        const first = source.next();
        var second: u21 = eof_codepoint;
        if (!isIdentCodepoint(first)) {
            if (first != '\\') break :blk;
            second = source.next();
            if (!isSecondCodepointOfAnEscape(second)) break :blk;
        }

        var tag: Token.Tag = .hash_unrestricted;
        if (second == eof_codepoint) second = source.next();
        const third = source.next();
        if (codepointsStartAnIdentSequence([3]u21{ first, second, third })) {
            tag = .hash_id;
        }

        source.seek(next_location);
        _ = consumeIdentSequence(source, false);
        return Token{ .tag = tag, .start = location };
    }

    source.seek(next_location);
    return Token{ .tag = .delim, .start = location };
}

fn plusOrFullStop(source: *Source, location: Source.Location) Token {
    const next_location = source.location();
    var next_3: [3]u21 = undefined;
    for (next_3) |*codepoint| codepoint.* = source.next();
    if (codepointsStartANumber(next_3)) {
        source.seek(location);
        return consumeNumericToken(source, location);
    } else {
        source.seek(next_location);
        return Token{ .tag = .delim, .start = location };
    }
}

fn minus(source: *Source, location: Source.Location) Token {
    if (source.matchAscii(asciiString("->"))) {
        return Token{ .tag = .cdc, .start = location };
    }

    const next_location = source.location();
    var next_3: [3]u21 = undefined;
    for (next_3) |*codepoint| codepoint.* = source.next();

    if (codepointsStartANumber(next_3)) {
        source.seek(location);
        return consumeNumericToken(source, location);
    } else if (codepointsStartAnIdentSequence(next_3)) {
        source.seek(location);
        return consumeIdentLikeToken(source, location);
    } else {
        source.seek(next_location);
        return Token{ .tag = .delim, .start = location };
    }
}

fn commercialAt(source: *Source, location: Source.Location) Token {
    const next_location = source.location();
    var next_3: [3]u21 = undefined;
    for (next_3) |*codepoint| codepoint.* = source.next();
    source.seek(next_location);

    if (codepointsStartAnIdentSequence(next_3)) {
        _ = consumeIdentSequence(source, false);
        return Token{ .tag = .at_keyword, .start = location };
    } else {
        return Token{ .tag = .delim, .start = location };
    }
}

pub fn main() !u8 {
    const allocator = std.heap.page_allocator;
    var stdin = std.io.getStdIn().reader();
    const input = try stdin.readAllAlloc(allocator, 4000000);
    defer allocator.free(input);
    for (input) |c| if (c >= 0x80) return 1;

    var source = try Source.init(@ptrCast([]const u7, input));
    while (true) {
        const token = nextToken(&source);
        std.debug.print("{s} {}\n", .{ @tagName(token.tag), token.start });
        if (token.tag == .eof) break;
    }

    return 0;
}
