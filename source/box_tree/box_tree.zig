const std = @import("std");

usingnamespace @import("properties.zig");

pub const BoxTree = struct {
    pdfs_flat_tree: []u16,
    inline_size: []LogicalSize,
    block_size: []LogicalSize,
    display: []Display,
    position_inset: []PositionInset,
    latin1_text: []Latin1Text,
    font: Font,
};

test "box tree" {
    var tree = @as(BoxTree, undefined);
}
