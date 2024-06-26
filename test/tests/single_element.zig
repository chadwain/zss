const testing = @import("../testing.zig");
const Test = testing.Test;

pub const name = "single element";

pub const tests = [_]testing.TestInfo{
    .{ "display: none", none },
    .{ "display: inline", @"inline" },
    .{ "display: block", block },
    .{ "display: text", text },
};

pub fn none(t: *Test) void {
    const root = t.createRoot();
    t.set(.box_style, root, .{ .display = .none });
}

pub fn @"inline"(t: *Test) void {
    const root = t.createRoot();
    t.set(.box_style, root, .{ .display = .@"inline" });
}

pub fn block(t: *Test) void {
    const root = t.createRoot();
    t.set(.box_style, root, .{ .display = .block });
}

pub fn text(t: *Test) void {
    const root = t.createRoot();
    t.set(.box_style, root, .{ .display = .text });
}
