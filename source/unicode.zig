// TODO: The name of this file is misleading.
// It may lead someone to believe that this code is dealing with Unicode, when in fact
// it's just dealing with ASCII (but where the ASCII values are represented with  u21 instead of u8).

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
