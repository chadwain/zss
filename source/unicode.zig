pub fn latin1ToLowercase(codepoint: u21) u21 {
    return switch (codepoint) {
        'A'...'Z' => codepoint - 'A' + 'a',
        else => codepoint,
    };
}

pub fn hexDigitToNumber(codepoint: u21) !u4 {
    return switch (codepoint) {
        '0'...'9' => @intCast(codepoint - '0'),
        'A'...'F' => @intCast(codepoint - 'A' + 10),
        'a'...'f' => @intCast(codepoint - 'a' + 10),
        else => return error.InvalidCodepoint,
    };
}
