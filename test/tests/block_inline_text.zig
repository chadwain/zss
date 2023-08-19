const testing = @import("../testing.zig");
const Test = testing.Test;
const strings = testing.strings;

pub const name = "block inline text";

pub fn setup(t: *Test) void {
    const block = t.createRoot();
    const inline_box = t.appendChild(block, .normal);
    const text = t.appendChild(inline_box, .text);

    t.set(.box_style, block, .{ .display = .block });
    t.set(.box_style, inline_box, .{ .display = .inline_ });
    t.set(.box_style, text, .{ .display = .text });
    t.set(.text, text, .{ .text = strings[0] });
    t.font_size = 18;
}
