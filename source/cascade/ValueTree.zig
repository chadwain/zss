const zss = @import("../../zss.zig");
const Index = zss.ElementTree.Index;
const value = zss.value;
const SparseSkipTree = zss.SparseSkipTree;

const std = @import("std");
const Allocator = std.mem.Allocator;

const Self = @This();

pub const Values = struct {
    all: SparseSkipTree(Index, struct { all: value.All }) = .{},
    display: SparseSkipTree(Index, struct { display: value.Display }) = .{},
    position: SparseSkipTree(Index, struct { position: value.Position }) = .{},
    float: SparseSkipTree(Index, struct { float: value.Float }) = .{},
    z_index: SparseSkipTree(Index, struct { z_index: value.ZIndex }) = .{},

    width: SparseSkipTree(Index, struct { width: value.Size }) = .{},
    min_width: SparseSkipTree(Index, struct { min_width: value.MinSize }) = .{},
    max_width: SparseSkipTree(Index, struct { max_width: value.MaxSize }) = .{},
    padding_left: SparseSkipTree(Index, struct { padding_left: value.Padding }) = .{},
    padding_right: SparseSkipTree(Index, struct { padding_right: value.Padding }) = .{},
    border_left: SparseSkipTree(Index, struct { border_left: value.BorderWidth }) = .{},
    border_right: SparseSkipTree(Index, struct { border_right: value.BorderWidth }) = .{},
    margin_left: SparseSkipTree(Index, struct { margin_left: value.Margin }) = .{},
    margin_right: SparseSkipTree(Index, struct { margin_right: value.Margin }) = .{},

    height: SparseSkipTree(Index, struct { height: value.Size }) = .{},
    min_height: SparseSkipTree(Index, struct { min_height: value.MinSize }) = .{},
    max_height: SparseSkipTree(Index, struct { max_height: value.MaxSize }) = .{},
    padding_top: SparseSkipTree(Index, struct { padding_top: value.Padding }) = .{},
    padding_bottom: SparseSkipTree(Index, struct { padding_bottom: value.Padding }) = .{},
    border_top: SparseSkipTree(Index, struct { border_top: value.BorderWidth }) = .{},
    border_bottom: SparseSkipTree(Index, struct { border_bottom: value.BorderWidth }) = .{},
    margin_top: SparseSkipTree(Index, struct { margin_top: value.Margin }) = .{},
    margin_bottom: SparseSkipTree(Index, struct { margin_bottom: value.Margin }) = .{},

    top: SparseSkipTree(Index, struct { top: value.Inset }) = .{},
    right: SparseSkipTree(Index, struct { right: value.Inset }) = .{},
    bottom: SparseSkipTree(Index, struct { bottom: value.Inset }) = .{},
    left: SparseSkipTree(Index, struct { left: value.Inset }) = .{},
};

values: Values = .{},

pub fn deinit(self: *Self, allocator: Allocator) void {
    inline for (std.meta.fields(Values)) |f| {
        @field(self.values, f.name).deinit(allocator);
    }
}
