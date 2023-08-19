pub fn toLowercase(codepoint: u21) u21 {
    return switch (codepoint) {
        'A'...'Z' => codepoint - 'A' + 'a',
        else => codepoint,
    };
}

pub fn hexDigitToNumber(codepoint: u21) u4 {
    return @intCast(switch (codepoint) {
        '0'...'9' => codepoint - '0',
        'A'...'F' => codepoint - 'A' + 10,
        'a'...'f' => codepoint - 'a' + 10,
        else => unreachable,
    });
}
