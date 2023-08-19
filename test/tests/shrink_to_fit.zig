const testing = @import("../testing.zig");
const Test = testing.Test;
const TestInfo = testing.TestInfo;

pub const name = "shrink to fit";

pub const tests = [_]TestInfo{
    .{ "inline block", inlineBlock },
    .{ "two nested inline blocks", twoNestedInlineBlocks },
    .{ "inline block text", inlineBlockText },
    .{ "inline block with fixed width child", inlineBlockWithFixedWidthChild },
};

fn inlineBlock(t: *Test) void {
    const root = t.createRoot();
    const inline_block = t.appendChild(root, .normal);

    t.set(.box_style, inline_block, .{ .display = .inline_block });
}

fn twoNestedInlineBlocks(t: *Test) void {
    const root = t.createRoot();
    const inline_block = t.appendChild(root, .normal);
    const inline_block_child_1 = t.appendChild(inline_block, .normal);
    const inline_block_child_2 = t.appendChild(inline_block, .normal);

    t.set(.box_style, inline_block, .{ .display = .inline_block });
    t.set(.box_style, inline_block_child_1, .{ .display = .inline_block });
    t.set(.box_style, inline_block_child_2, .{ .display = .inline_block });
}

fn inlineBlockText(t: *Test) void {
    const root = t.createRoot();
    const inline_block = t.appendChild(root, .normal);
    const text = t.appendChild(inline_block, .text);

    t.set(.box_style, inline_block, .{ .display = .inline_block });
    t.set(.box_style, text, .{ .display = .text });
    t.set(.text, text, .{ .text = testing.strings[1] });
}

fn inlineBlockWithFixedWidthChild(t: *Test) void {
    const root = t.createRoot();
    const inline_block = t.appendChild(root, .normal);
    const block = t.appendChild(inline_block, .normal);

    t.set(.box_style, inline_block, .{ .display = .inline_block });
    t.set(.box_style, block, .{ .display = .block });
    t.set(.content_width, block, .{ .size = .{ .px = 50 } });
}
