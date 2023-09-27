const testing = @import("../testing.zig");
const Test = testing.Test;

pub const name = "simple text";

pub fn setup(t: *Test) void {
    const root = t.createRoot();
    const text = t.appendChild(root, .text);

    t.set(.box_style, text, .{ .display = .text });
    t.setText(text, testing.strings[0]);
}
