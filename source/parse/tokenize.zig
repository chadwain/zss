//! Implements the Tokenizer specified in CSS Syntax Level 3.

// TODO: Handle all parse errors, instead of erroring out.

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

pub const Source = struct {
    data: []const u7,
    index: u32,

    const Location = u32;

    pub fn init(data: []const u7) !Source {
        if (data.len > std.math.maxInt(Location)) return error.Overflow;
        return Source{ .data = data, .index = 0 };
    }

    fn next(source: *Source) ?u21 {
        if (source.index == source.data.len) return null;
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

    fn matchCdoToken(source: *Source) bool {
        if (source.data.len - source.index >= 3 and std.mem.eql(u7, source.data[source.index..][0..3], asciiString("!--"))) {
            source.index += 3;
            return true;
        } else {
            return false;
        }
    }

    fn matchCdcToken(source: *Source) bool {
        if (source.data.len - source.index >= 2 and std.mem.eql(u7, source.data[source.index..][0..2], asciiString("->"))) {
            source.index += 2;
            return true;
        } else {
            return false;
        }
    }
};

pub fn nextToken(source: *Source) !Token {
    const location = source.location();
    const codepoint = source.next() orelse return Token{
        .tag = .eof,
        .start = location,
    };

    switch (codepoint) {
        '/' => {
            const next_location = source.location();
            if (source.next() == @as(?u21, '*')) {
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
            if (source.matchCdoToken()) {
                return Token{ .tag = .cdo, .start = location };
            } else {
                return Token{ .tag = .delim, .start = location };
            }
        },
        '@' => return commercialAt(source, location),
        '[' => return Token{ .tag = .left_bracket, .start = location },
        '\\' => {
            const next = source.next();
            if (isSecondCodepointOfAnEscape(next)) {
                source.seek(location);
                return consumeIdentLikeToken(source, location);
            } else {
                return error.ParseError;
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

fn isIdentCodepoint(codepoint: ?u21) bool {
    switch (codepoint orelse return false) {
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

fn isIdentStartCodepoint(codepoint: ?u21) bool {
    switch (codepoint orelse return false) {
        'A'...'Z',
        'a'...'z',
        '_',
        0x80...0x10FFFF,
        => return true,
        else => return false,
    }
}

fn isSecondCodepointOfAnEscape(codepoint: ?u21) bool {
    return codepoint != @as(?u21, '\n');
}

fn codepointsStartAnIdentSequence(codepoints: [3]?u21) bool {
    return switch (codepoints[0] orelse return false) {
        '-' => return isIdentStartCodepoint(codepoints[1]) or
            (codepoints[1] == @as(?u21, '-')) or
            (codepoints[1] == @as(?u21, '\\') and isSecondCodepointOfAnEscape(codepoints[2])),

        'A'...'Z',
        'a'...'z',
        '_',
        0x80...0x10FFFF,
        => true,

        '\\' => return isSecondCodepointOfAnEscape(codepoints[1]),

        else => false,
    };
}

fn codepointsStartANumber(codepoints: [3]?u21) bool {
    switch (codepoints[0] orelse return false) {
        '+', '-' => switch (codepoints[1] orelse return false) {
            '0'...'9' => return true,
            '.' => switch (codepoints[2] orelse return false) {
                '0'...'9' => return true,
                else => return false,
            },
            else => return false,
        },
        '.' => switch (codepoints[1] orelse return false) {
            '0'...'9' => return true,
            else => return false,
        },
        '0'...'9' => return true,
        else => return false,
    }
}

fn consumeComments(source: *Source, location: Source.Location) !Token {
    while (true) {
        const next_location = source.location();
        if (source.next() == @as(?u21, '/') and source.next() == @as(?u21, '*')) {
            while (source.next()) |codepoint| {
                if (codepoint == '*' and source.next() == @as(?u21, '/')) break;
            } else {
                return error.ParseError;
            }
        } else {
            break source.seek(next_location);
        }
    }
    return Token{ .tag = .comments, .start = location };
}

fn consumeWhitespace(source: *Source) void {
    while (source.next()) |codepoint| {
        switch (codepoint) {
            '\n', '\t', ' ' => {},
            else => break source.back(),
        }
    }
}

fn consumeStringToken(source: *Source, location: Source.Location, comptime ending_codepoint: u21) !Token {
    while (source.next()) |codepoint| {
        switch (codepoint) {
            ending_codepoint => return Token{ .tag = .string, .start = location },
            '\n' => return error.ParseError,
            '\\' => {
                const next_codepoint = source.next() orelse continue;
                if (next_codepoint != '\n') {
                    _ = try consumeEscapedCodepoint(source, next_codepoint);
                }
            },
            else => {},
        }
    } else {
        return error.ParseError;
    }
}

fn consumeEscapedCodepoint(source: *Source, first_codepoint: ?u21) !u21 {
    switch (first_codepoint orelse return error.ParseError) {
        '0'...'9', 'A'...'F', 'a'...'f' => {
            var result: u21 = hexDigitToNumber(first_codepoint.?);
            var count: u3 = 0;
            while (count < 5) : (count += 1) {
                const codepoint = source.next() orelse break;
                switch (codepoint) {
                    '0'...'9', 'A'...'F', 'a'...'f' => result = result *| 16 +| hexDigitToNumber(codepoint),
                    else => break source.back(),
                }
            }

            if (source.next()) |maybe_whitespace| {
                switch (maybe_whitespace) {
                    '\n', '\t', ' ' => {},
                    else => source.back(),
                }
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
        '\n' => unreachable,
        else => return first_codepoint.?,
    }
}

fn consumeNumericToken(source: *Source, location: Source.Location) !Token {
    const number_type = consumeNumber(source);
    _ = number_type;

    const next_location = source.location();
    var next_3: [3]?u21 = undefined;
    for (next_3) |*codepoint| codepoint.* = source.next();
    source.seek(next_location);

    if (codepointsStartAnIdentSequence(next_3)) {
        _ = try consumeIdentSequence(source, false);
        return Token{ .tag = .dimension, .start = location };
    }

    const percent_sign = source.next();
    if (percent_sign == @as(?u21, '%')) {
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
        if (plus_or_minus != @as(?u21, '+') and plus_or_minus != @as(?u21, '-')) {
            source.seek(next_location);
        }
    }

    consumeDigits(source);

    next_location = source.location();
    decimal: {
        const decimal_point = source.next();
        if (decimal_point != @as(?u21, '.')) break :decimal source.seek(next_location);
        const digit = source.next();
        switch (digit orelse 0) {
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
        if (e != @as(?u21, 'e') and e != @as(?u21, 'E')) break :exponent source.seek(next_location);

        const plus_or_minus = source.next();
        if (plus_or_minus != @as(?u21, '+') and plus_or_minus != @as(?u21, '-')) {
            source.back();
        }

        const digit = source.next();
        switch (digit orelse 0) {
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
        switch (source.next() orelse break) {
            '0'...'9' => {},
            else => {
                source.back();
                break;
            },
        }
    }
}

// Returns true if the ident sequence is "url", case-insensitively.
fn consumeIdentSequence(source: *Source, look_for_url: bool) !bool {
    var string_matcher: struct {
        num_matching_codepoints: u2 = 0,
        matches: ?bool = null,

        const url = "url";

        fn nextCodepoint(self: *@This(), codepoint: ?u21) void {
            const c = codepoint orelse {
                self.matches = false;
                return;
            };

            if (self.matches == null) {
                if (url[self.num_matching_codepoints] == toLowercase(c)) {
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
        const codepoint = source.next() orelse break;
        switch (codepoint) {
            '\\' => {
                const second_codepoint = source.next();
                if (isSecondCodepointOfAnEscape(second_codepoint)) {
                    const escaped_codepoint = try consumeEscapedCodepoint(source, second_codepoint);
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
            else => {
                source.back();
                break;
            },
        }
    }

    return if (look_for_url) (string_matcher.matches orelse false) else @as(bool, undefined);
}

fn consumeIdentLikeToken(source: *Source, location: Source.Location) !Token {
    const is_url = try consumeIdentSequence(source, true);
    const next_location = source.location();

    if (source.next() == @as(?u21, '(')) {
        if (is_url) {
            var preceding_whitespace = false;
            while (source.next()) |codepoint| {
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
                        source.back();
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

fn consumeUrlToken(source: *Source, location: Source.Location) !Token {
    consumeWhitespace(source);
    while (source.next()) |codepoint| {
        switch (codepoint) {
            ')' => return Token{ .tag = .url, .start = location },
            '\n', '\t', ' ' => {
                consumeWhitespace(source);
                const maybe_right_paren = source.next() orelse return error.ParseError;
                if (maybe_right_paren == ')') {
                    return Token{ .tag = .url, .start = location };
                } else {
                    source.back();
                    return consumeBadUrl(source, location);
                }
            },
            '"', '\'', '(', 0x00...0x08, 0x0B, 0x0E...0x1F, 0x7F => return error.ParseError,
            '\\' => {
                const next_codepoint = source.next();
                if (isSecondCodepointOfAnEscape(next_codepoint)) {
                    _ = try consumeEscapedCodepoint(source, next_codepoint);
                } else {
                    return error.ParseError;
                }
            },
            else => {},
        }
    } else {
        return error.ParseError;
    }
}

fn consumeBadUrl(source: *Source, location: Source.Location) !Token {
    while (source.next()) |codepoint| {
        switch (codepoint) {
            ')' => break,
            '\\' => {
                const next_codepoint = source.next();
                if (isSecondCodepointOfAnEscape(next_codepoint)) {
                    _ = try consumeEscapedCodepoint(source, next_codepoint);
                } else {
                    source.back();
                }
            },
            else => {},
        }
    }
    return Token{ .tag = .bad_url, .start = location };
}

fn numberSign(source: *Source, location: Source.Location) !Token {
    const next_location = source.location();
    blk: {
        const first = source.next() orelse break :blk;
        var second: ?u21 = null;
        if (!isIdentCodepoint(first)) {
            if (first != '\\') break :blk;
            second = source.next();
            if (!isSecondCodepointOfAnEscape(second)) break :blk;
        }

        var tag: Token.Tag = .hash_unrestricted;
        if (second == null) second = source.next();
        const third = source.next();
        if (codepointsStartAnIdentSequence([3]?u21{ first, second, third })) {
            tag = .hash_id;
        }

        source.seek(next_location);
        _ = try consumeIdentSequence(source, false);
        return Token{ .tag = tag, .start = location };
    }

    source.seek(next_location);
    return Token{ .tag = .delim, .start = location };
}

fn plusOrFullStop(source: *Source, location: Source.Location) !Token {
    const next_location = source.location();
    var next_3: [3]?u21 = undefined;
    for (next_3) |*codepoint| codepoint.* = source.next();
    if (codepointsStartANumber(next_3)) {
        source.seek(location);
        return consumeNumericToken(source, location);
    } else {
        source.seek(next_location);
        return Token{ .tag = .delim, .start = location };
    }
}

fn minus(source: *Source, location: Source.Location) !Token {
    if (source.matchCdcToken()) {
        return Token{ .tag = .cdc, .start = location };
    }

    const next_location = source.location();
    var next_3: [3]?u21 = undefined;
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

fn commercialAt(source: *Source, location: Source.Location) !Token {
    const next_location = source.location();
    var next_3: [3]?u21 = undefined;
    for (next_3) |*codepoint| codepoint.* = source.next();
    source.seek(next_location);

    if (codepointsStartAnIdentSequence(next_3)) {
        _ = try consumeIdentSequence(source, false);
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
        const token = try nextToken(&source);
        std.debug.print("{s} {}\n", .{ @tagName(token.tag), token.start });
        if (token.tag == .eof) break;
    }

    return 0;
}
