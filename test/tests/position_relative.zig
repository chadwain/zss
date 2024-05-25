const testing = @import("../testing.zig");
const colors = testing.colors;
const Test = testing.Test;
const TestInfo = testing.TestInfo;

pub const name = "relative positioning";

pub const tests = [_]TestInfo{
    .{ "block box", blockBox },
    .{ "inline box > text", inlineBoxText },
};

pub fn blockBox(t: *Test) void {
    const root = t.createRoot();
    const block = t.appendChild(root, .normal);

    t.set(.content_width, root, .{ .width = .{ .px = 400 } });
    t.set(.content_height, root, .{ .height = .{ .px = 400 } });

    t.set(.box_style, block, .{ .display = .block, .position = .relative });
    t.set(.content_width, block, .{ .width = .{ .px = 100 } });
    t.set(.content_height, block, .{ .height = .{ .px = 100 } });
    t.set(.background1, block, .{ .color = colors[1] });
    t.set(.insets, block, .{ .left = .{ .px = 100 }, .top = .{ .px = 150 } });
}

pub fn inlineBoxText(t: *Test) void {
    const root = t.createRoot();
    const inline_box = t.appendChild(root, .normal);
    const text = t.appendChild(inline_box, .text);

    t.set(.content_width, root, .{ .width = .{ .px = 400 } });
    t.set(.content_height, root, .{ .height = .{ .px = 400 } });

    t.set(.box_style, inline_box, .{ .display = .@"inline", .position = .relative });
    t.set(.background1, inline_box, .{ .color = colors[1] });
    t.set(.insets, inline_box, .{ .left = .{ .px = 100 }, .top = .{ .px = 150 } });

    t.set(.box_style, text, .{ .display = .text });
    t.setText(text, testing.strings[0]);
}
