//! Implements the tokenization algorithm of CSS Syntax Level 3.

const std = @import("std");
const assert = std.debug.assert;

const zss = @import("../zss.zig");
const hexDigitToNumber = zss.unicode.hexDigitToNumber;
const CheckedInt = zss.math.CheckedInt;
const SourceCode = zss.syntax.SourceCode;
const Token = zss.syntax.Token;

const u21_max = std.math.maxInt(u21);
const replacement_character: u21 = 0xfffd;
const eof_codepoint = u21_max;

pub const Error = error{
    Utf8ExpectedContinuation,
    Utf8OverlongEncoding,
    Utf8EncodesSurrogateHalf,
    Utf8CodepointTooLarge,
    Utf8InvalidStartByte,
    Utf8CodepointTruncated,
};

pub fn nextCodepoint(source_code: SourceCode, location: *SourceCode.Location) Error!u21 {
    var location_int = @intFromEnum(location.*);
    if (location_int == source_code.text.len) return eof_codepoint;
    defer location.* = @enumFromInt(location_int);

    const unprocessed_codepoint = blk: {
        const len = try std.unicode.utf8ByteSequenceLength(source_code.text[location_int]);
        if (len > source_code.text.len - location_int) return error.Utf8CodepointTruncated;
        defer location_int += len;
        break :blk try std.unicode.utf8Decode(source_code.text[location_int..][0..len]);
    };

    const codepoint: u21 = switch (unprocessed_codepoint) {
        0x00,
        0xD800...0xDBFF,
        0xDC00...0xDFFF,
        => replacement_character,
        '\r' => blk: {
            if (location_int < source_code.text.len and source_code.text[location_int] == '\n') {
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

pub fn peekCodepoint(source_code: SourceCode, start: SourceCode.Location) !struct { u21, SourceCode.Location } {
    const codepoint, const location = try peekCodepoints(1, source_code, start);
    return .{ codepoint[0], location };
}

pub fn peekCodepoints(comptime amount: std.meta.Tag(SourceCode.Location), source_code: SourceCode, start: SourceCode.Location) !struct { [amount]u21, SourceCode.Location } {
    var buffer: [amount]u21 = undefined;
    var location = start;
    for (&buffer) |*codepoint| {
        codepoint.* = try nextCodepoint(source_code, &location);
    }
    return .{ buffer, location };
}

pub fn moveForwards(location: *SourceCode.Location, amount: std.meta.Tag(SourceCode.Location)) void {
    const int = @intFromEnum(location.*);
    location.* = @enumFromInt(int + amount);
}

pub fn moveBackwards(location: *SourceCode.Location, amount: std.meta.Tag(SourceCode.Location)) void {
    const int = @intFromEnum(location.*);
    location.* = @enumFromInt(int - amount);
}

pub fn moveBackwardsNewline(source_code: SourceCode, location: *SourceCode.Location) void {
    var int = @intFromEnum(location.*) - 1;
    assert(source_code.text[int] == '\n');
    if (int > 0 and source_code.text[int - 1] == '\r') int -= 1;
    location.* = @enumFromInt(int);
}

/// Returns the token found at `location` within the source code, and updates `location` to point to the next token.
/// If `location` points to the end of the source code, then `.token_eof` is returned, and `location` is not updated.
/// Performs UTF-8 validation on the source code.
pub fn nextToken(source_code: SourceCode, location: *SourceCode.Location) Error!Token {
    const previous_location = location.*;
    const codepoint = try nextCodepoint(source_code, location);
    switch (codepoint) {
        '/' => {
            const asterisk, _ = try peekCodepoint(source_code, location.*);
            if (asterisk == '*') {
                moveBackwards(location, 1);
                return consumeComments(source_code, location);
            } else {
                return .{ .token_delim = codepoint };
            }
        },
        '\n', '\t', ' ' => {
            try consumeWhitespace(source_code, location);
            return .token_whitespace;
        },
        '"' => return consumeStringToken(source_code, location, '"'),
        '#' => {
            const next_3, _ = try peekCodepoints(3, source_code, location.*);
            if (!codepointsStartAHash(next_3[0..2].*)) {
                return .{ .token_delim = '#' };
            }

            const token: Token = if (codepointsStartAnIdentSequence(next_3)) .token_hash_id else .token_hash_unrestricted;
            try consumeIdentSequence(source_code, location);
            return token;
        },
        '\'' => return consumeStringToken(source_code, location, '\''),
        '(' => return .token_left_paren,
        ')' => return .token_right_paren,
        '+', '.' => {
            var next_3 = [3]u21{ codepoint, undefined, undefined };
            next_3[1..3].*, _ = try peekCodepoints(2, source_code, location.*);
            if (codepointsStartANumber(next_3)) {
                moveBackwards(location, 1);
                return consumeNumericToken(source_code, location);
            } else {
                return .{ .token_delim = codepoint };
            }
        },
        ',' => return .token_comma,
        '-' => {
            var next_3 = [3]u21{ '-', undefined, undefined };
            next_3[1..3].*, const after_cdc = try peekCodepoints(2, source_code, location.*);
            if (std.mem.eql(u21, next_3[1..3], &[2]u21{ '-', '>' })) {
                location.* = after_cdc;
                return .token_cdc;
            }

            if (codepointsStartANumber(next_3)) {
                moveBackwards(location, 1);
                return consumeNumericToken(source_code, location);
            } else if (codepointsStartAnIdentSequence(next_3)) {
                moveBackwards(location, 1);
                return consumeIdentLikeToken(source_code, location);
            } else {
                return .{ .token_delim = codepoint };
            }
        },
        ':' => return .token_colon,
        ';' => return .token_semicolon,
        '<' => {
            const next_3, const after_cdo = try peekCodepoints(3, source_code, location.*);
            if (std.mem.eql(u21, &next_3, &[3]u21{ '!', '-', '-' })) {
                location.* = after_cdo;
                return .token_cdo;
            } else {
                return .{ .token_delim = codepoint };
            }
        },
        '@' => {
            const next_3, _ = try peekCodepoints(3, source_code, location.*);

            if (codepointsStartAnIdentSequence(next_3)) {
                const at_rule = try consumeIdentSequenceWithMatch(source_code, location, Token.AtRule);
                return .{ .token_at_keyword = at_rule };
            } else {
                return .{ .token_delim = codepoint };
            }
        },
        '[' => return .token_left_square,
        '\\' => {
            const first_escaped, _ = try peekCodepoint(source_code, location.*);
            if (isValidFirstEscapedCodepoint(first_escaped)) {
                moveBackwards(location, 1);
                return consumeIdentLikeToken(source_code, location);
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
            return consumeNumericToken(source_code, location);
        },
        'A'...'Z',
        'a'...'z',
        '_',
        0x80...0x10FFFF,
        => {
            location.* = previous_location;
            return consumeIdentLikeToken(source_code, location);
        },
        eof_codepoint => return .token_eof,
        else => return .{ .token_delim = codepoint },
    }
}

pub fn isIdentStartCodepoint(codepoint: u21) bool {
    switch (codepoint) {
        'A'...'Z',
        'a'...'z',
        '_',
        0x80...0x10FFFF,
        => return true,
        else => return false,
    }
}

pub fn isValidFirstEscapedCodepoint(codepoint: u21) bool {
    return codepoint != '\n';
}

pub fn codepointsStartAnIdentSequence(codepoints: [3]u21) bool {
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

pub fn codepointsStartANumber(codepoints: [3]u21) bool {
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

pub fn consumeComments(source_code: SourceCode, location: *SourceCode.Location) !Token {
    outer: while (true) {
        const next_2, _ = try peekCodepoints(2, source_code, location.*);
        if (!std.mem.eql(u21, &next_2, &[2]u21{ '/', '*' })) break;

        while (true) {
            const codepoint = try nextCodepoint(source_code, location);
            switch (codepoint) {
                '*' => {
                    const slash, const comment_end = try peekCodepoint(source_code, location.*);
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

pub fn consumeWhitespace(source_code: SourceCode, location: *SourceCode.Location) !void {
    while (true) {
        const previous_location = location.*;
        const codepoint = try nextCodepoint(source_code, location);
        switch (codepoint) {
            '\n', '\t', ' ' => {},
            else => {
                location.* = previous_location;
                return;
            },
        }
    }
}

pub fn consumeStringToken(source_code: SourceCode, location: *SourceCode.Location, ending_codepoint: u21) !Token {
    while (consumeStringTokenCodepoint(source_code, location, ending_codepoint)) |codepoint| {
        if (codepoint == null) break;
    } else |err| {
        switch (err) {
            error.BadStringToken => return .token_bad_string,
            else => |e| return e,
        }
    }

    const final = nextCodepoint(source_code, location) catch unreachable;
    assert(final == ending_codepoint or final == eof_codepoint);
    return .token_string;
}

pub fn consumeStringTokenCodepoint(source_code: SourceCode, location: *SourceCode.Location, ending_codepoint: u21) !?u21 {
    const codepoint = try nextCodepoint(source_code, location);
    switch (codepoint) {
        '\n' => {
            moveBackwardsNewline(source_code, location);
            // NOTE: Parse error
            return error.BadStringToken;
        },
        '\\' => {
            const first_escaped = try nextCodepoint(source_code, location);
            switch (first_escaped) {
                '\n' => return '\n',
                eof_codepoint => {
                    // NOTE: Parse error
                    return null;
                },
                else => return try consumeEscapedCodepoint(source_code, location, first_escaped),
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

pub fn consumeEscapedCodepoint(source_code: SourceCode, location: *SourceCode.Location, first_escaped: u21) !u21 {
    return switch (first_escaped) {
        '0'...'9', 'A'...'F', 'a'...'f' => blk: {
            var result: u21 = hexDigitToNumber(first_escaped) catch unreachable;
            for (0..5) |_| {
                const previous_location = location.*;
                const digit = try nextCodepoint(source_code, location);
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

            const whitespace, const after_whitespace = try peekCodepoint(source_code, location.*);
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

pub fn consumeNumericToken(source_code: SourceCode, location: *SourceCode.Location) !Token {
    const value = try consumeNumber(source_code, location);
    const next_3, _ = try peekCodepoints(3, source_code, location.*);

    if (codepointsStartAnIdentSequence(next_3)) {
        const unit_location = location.*;
        const unit = try consumeIdentSequenceWithMatch(source_code, location, Token.Unit);
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

pub fn consumeNumber(source_code: SourceCode, location: *SourceCode.Location) !ConsumeNumber {
    var number_type: std.meta.Tag(ConsumeNumber) = .integer;
    var is_negative: bool = undefined;
    var buffer = NumberBuffer{};

    const start = location.*;
    const leading_sign = try nextCodepoint(source_code, location);
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

    try consumeZeroes(source_code, location);
    var integral_part = try consumeDigits(source_code, location, &buffer);

    {
        const next_2, _ = try peekCodepoints(2, source_code, location.*);
        if (next_2[0] == '.' and next_2[1] >= '0' and next_2[1] <= '9') {
            number_type = .number;
            buffer.append('.');
            moveForwards(location, 1);
            // TODO: Skip trailing zeroes
            _ = try consumeDigits(source_code, location, &buffer);
        }
    }

    {
        const e, const after_e = try peekCodepoint(source_code, location.*);
        if (e == 'e' or e == 'E') {
            const exponent_sign, const after_exponent_sign = try peekCodepoint(source_code, after_e);
            const before_exponent_digits = if (exponent_sign == '+' or exponent_sign == '-') after_exponent_sign else after_e;

            const first_digit, _ = try peekCodepoint(source_code, before_exponent_digits);
            if (first_digit >= '0' and first_digit <= '9') {
                number_type = .number;
                buffer.append('e');
                if (before_exponent_digits == after_exponent_sign) {
                    buffer.append(@intCast(exponent_sign));
                }
                location.* = before_exponent_digits;
                try consumeZeroes(source_code, location);
                _ = try consumeDigits(source_code, location, &buffer);
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

pub fn consumeZeroes(source_code: SourceCode, location: *SourceCode.Location) !void {
    while (true) {
        const previous_location = location.*;
        switch (try nextCodepoint(source_code, location)) {
            '0' => {},
            else => {
                location.* = previous_location;
                return;
            },
        }
    }
}

pub fn consumeDigits(source_code: SourceCode, location: *SourceCode.Location, buffer: *NumberBuffer) !CheckedInt(i32) {
    var value: CheckedInt(i32) = .init(0);
    while (true) {
        const previous_location = location.*;
        const codepoint = try nextCodepoint(source_code, location);
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

pub fn consumeIdentSequenceCodepoint(source_code: SourceCode, location: *SourceCode.Location) !?u21 {
    const previous_location = location.*;
    const codepoint = try nextCodepoint(source_code, location);
    switch (codepoint) {
        '\\' => {
            const first_escaped = try nextCodepoint(source_code, location);
            if (isValidFirstEscapedCodepoint(first_escaped)) {
                return try consumeEscapedCodepoint(source_code, location, first_escaped);
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

pub fn consumeIdentSequence(source_code: SourceCode, location: *SourceCode.Location) !void {
    while (try consumeIdentSequenceCodepoint(source_code, location)) |_| {}
}

pub fn ComptimePrefixTree(comptime Enum: type) type {
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

pub fn consumeIdentSequenceWithMatch(source_code: SourceCode, location: *SourceCode.Location, comptime Enum: type) !?Enum {
    var prefix_tree = ComptimePrefixTree(Enum){};
    while (try consumeIdentSequenceCodepoint(source_code, location)) |codepoint| {
        prefix_tree.nextCodepoint(codepoint);
    }
    return prefix_tree.findMatch();
}

pub fn consumeIdentLikeToken(source_code: SourceCode, location: *SourceCode.Location) !Token {
    const is_url = try consumeIdentSequenceWithMatch(source_code, location, enum { url });
    const after_ident = location.*;
    const left_paren = try nextCodepoint(source_code, location);
    if (left_paren != '(') {
        location.* = after_ident;
        return .token_ident;
    }
    if (is_url == null) return .token_function;

    const after_left_paren = location.*;
    try consumeWhitespace(source_code, location);
    const quote, _ = try peekCodepoint(source_code, location.*);
    switch (quote) {
        '\'', '"' => {
            location.* = after_left_paren;
            return .token_function;
        },
        else => return consumeUrlToken(source_code, location),
    }
}

pub fn consumeUrlToken(source_code: SourceCode, location: *SourceCode.Location) !Token {
    // Not consuming whitespace - this is handled already by consumeIdentLikeToken.
    // try consumeWhitespace(source_code, location);

    while (consumeUrlTokenCodepoint(source_code, location)) |codepoint| {
        if (codepoint == null) break;
    } else |err| {
        switch (err) {
            error.BadUrlToken => return consumeBadUrl(source_code, location),
            else => |e| return e,
        }
    }

    switch (nextCodepoint(source_code, location) catch unreachable) {
        ')', eof_codepoint => {},
        else => unreachable,
    }
    return .token_url;
}

pub fn consumeUrlTokenCodepoint(source_code: SourceCode, location: *SourceCode.Location) !?u21 {
    const codepoint = try nextCodepoint(source_code, location);
    switch (codepoint) {
        ')' => {
            // Move backwards so that this function can be called repeatedly and always return null.
            moveBackwards(location, 1);
            return null;
        },
        '\n', '\t', ' ' => {
            try consumeWhitespace(source_code, location);
            const right_paren_or_eof, _ = try peekCodepoint(source_code, location.*);
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
            const first_escaped = try nextCodepoint(source_code, location);
            if (isValidFirstEscapedCodepoint(first_escaped)) {
                return try consumeEscapedCodepoint(source_code, location, first_escaped);
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

pub fn consumeBadUrl(source_code: SourceCode, location: *SourceCode.Location) !Token {
    while (true) {
        const codepoint = try nextCodepoint(source_code, location);
        switch (codepoint) {
            ')', eof_codepoint => break,
            '\\' => {
                const previous_location = location.*;
                const first_escaped = try nextCodepoint(source_code, location);
                if (isValidFirstEscapedCodepoint(first_escaped)) {
                    _ = try consumeEscapedCodepoint(source_code, location, first_escaped);
                } else {
                    location.* = previous_location;
                }
            },
            else => {},
        }
    }
    return .token_bad_url;
}

pub fn codepointsStartAHash(codepoints: [2]u21) bool {
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
    const source_code = try SourceCode.init(input);
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

    var tokenizer = zss.syntax.Tokenizer.init(source_code);
    var index: usize = 0;
    while (try tokenizer.next()) |item| : (index += 1) {
        if (index >= expected.len) return error.TestFailure;
        const token, _ = item;
        try std.testing.expectEqual(expected[index], token);
    }
}
