const std = @import("std");

usingnamespace @import("properties.zig");

pub const BoxTree = struct {
    pdfs_flat_tree: []u16,
    display: []Display,
    inline_size: []LogicalSize,
    block_size: []LogicalSize,
    latin1_text: []Latin1Text,
    font: Font,
    border: []Border,
    background: []Background,
    //position_inset: []PositionInset,
};
