const testing = @import("../testing.zig");
const Test = testing.Test;

pub const name = "simple text";

pub fn setup(t: *Test) void {
    const root = t.createRoot();
    const text = t.appendChild(root);

    t.set(.box_style, text, .{ .display = .text });
    t.set(.text, text, .{ .text = testing.strings[0] });
}
