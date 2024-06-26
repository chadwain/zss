const testing = @import("../testing.zig");
const Test = testing.Test;

pub const name = "two elements";

pub const tests = [_]testing.TestInfo{
    .{ "block block", blockBlock },
    .{ "block inline", blockInline },
    .{ "block none", blockNone },
    .{ "block text", blockText },
};

pub fn blockBlock(t: *Test) void {
    const root = t.createRoot();
    const child = t.appendChild(root, .normal);
    t.set(.box_style, root, .{ .display = .block });
    t.set(.box_style, child, .{ .display = .block });
}

pub fn blockInline(t: *Test) void {
    const root = t.createRoot();
    const child = t.appendChild(root, .normal);
    t.set(.box_style, root, .{ .display = .block });
    t.set(.box_style, child, .{ .display = .@"inline" });
}

pub fn blockNone(t: *Test) void {
    const root = t.createRoot();
    const child = t.appendChild(root, .normal);
    t.set(.box_style, root, .{ .display = .block });
    t.set(.box_style, child, .{ .display = .none });
}

pub fn blockText(t: *Test) void {
    const root = t.createRoot();
    const child = t.appendChild(root, .text);
    t.set(.box_style, root, .{ .display = .block });
    t.set(.box_style, child, .{ .display = .text });
}
