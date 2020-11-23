// This file is a part of zss.
// Copyright (C) 2020 Chadwain Holness
//
// This library is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this library.  If not, see <https://www.gnu.org/licenses/>.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const AutoHashMapUnmanaged = std.AutoHashMapUnmanaged;
usingnamespace @import("properties.zig");
const PrefixTree = @import("prefix-tree").PrefixTree;

allocator: *Allocator,
tree: Tree,

width: AutoHashMapUnmanaged(MapKey, Width) = .{},
height: AutoHashMapUnmanaged(MapKey, Height) = .{},
border_padding_left_right: AutoHashMapUnmanaged(MapKey, BorderPaddingLeftRight) = .{},
border_padding_top_bottom: AutoHashMapUnmanaged(MapKey, BorderPaddingTopBottom) = .{},
margin_left_right: AutoHashMapUnmanaged(MapKey, MarginLeftRight) = .{},
margin_top_bottom: AutoHashMapUnmanaged(MapKey, MarginTopBottom) = .{},
border_colors: AutoHashMapUnmanaged(MapKey, BorderColor) = .{},
background_color: AutoHashMapUnmanaged(MapKey, BackgroundColor) = .{},

const Self = @This();
pub const Tree = PrefixTree(TreeValue, TreeValue.cmpFn);
pub const MapKey = u16;
pub const TreeValue = struct {
    tree_val: u16,
    map_key: MapKey,

    fn cmpFn(lhs: @This(), rhs: @This()) std.math.Order {
        return std.math.order(lhs.tree_val, rhs.tree_val);
    }
};

pub fn init(allocator: *Allocator) !Self {
    return Self{
        .allocator = allocator,
        .tree = try PrefixTree(TreeValue, TreeValue.cmpFn).init(allocator),
    };
}

pub fn deinit(self: *Self) void {
    self.tree.deinit();
    inline for ([_][]const u8{
        "width",
        "height",
        "border_padding_left_right",
        "border_padding_top_bottom",
        "margin_left_right",
        "margin_top_bottom",
        "border_colors",
        "background_color",
    }) |field_name| {
        @field(self, field_name).deinit(self.allocator);
    }
}

test "basic test" {
    const allocator = std.heap.page_allocator;
    var blk_ctx = try init(allocator);
    defer blk_ctx.deinit();
    testing.expect(blk_ctx.tree.exists(&[_]TreeValue{}));
}
