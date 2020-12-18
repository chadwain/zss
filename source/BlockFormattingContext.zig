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

const BoxId = @import("../zss.zig").RenderTree.BoxId;
usingnamespace @import("properties.zig");

allocator: *Allocator,
tree: *Tree,
counter: BoxId = 0,

width: AutoHashMapUnmanaged(BoxId, Width) = .{},
height: AutoHashMapUnmanaged(BoxId, Height) = .{},
border_padding_left_right: AutoHashMapUnmanaged(BoxId, BorderPaddingLeftRight) = .{},
border_padding_top_bottom: AutoHashMapUnmanaged(BoxId, BorderPaddingTopBottom) = .{},
margin_left_right: AutoHashMapUnmanaged(BoxId, MarginLeftRight) = .{},
margin_top_bottom: AutoHashMapUnmanaged(BoxId, MarginTopBottom) = .{},
border_colors: AutoHashMapUnmanaged(BoxId, BorderColor) = .{},
background_color: AutoHashMapUnmanaged(BoxId, BackgroundColor) = .{},

const Self = @This();

pub const Tree = @import("prefix-tree-map").PrefixTreeMapUnmanaged(TreeKeyPart, BoxId, cmpFn);
pub const TreeKeyPart = u16;
fn cmpFn(lhs: TreeKeyPart, rhs: TreeKeyPart) std.math.Order {
    return std.math.order(lhs, rhs);
}

pub const Properties = enum {
    width,
    height,
    border_padding_left_right,
    border_padding_top_bottom,
    margin_left_right,
    margin_top_bottom,
    border_colors,
    background_color,

    pub fn toType(comptime self: @This()) type {
        return std.meta.fieldInfo(std.meta.fieldInfo(Self, @tagName(self)).field_type.Entry, "value").field_type;
    }
};

pub fn init(allocator: *Allocator) !Self {
    return Self{
        .allocator = allocator,
        .tree = try Tree.init(allocator),
    };
}

pub fn deinit(self: *Self) void {
    self.tree.deinit(self.allocator);
    inline for (std.meta.fields(Properties)) |field| {
        @field(self, field.name).deinit(self.allocator);
    }
}

pub fn new(self: *Self, parent: []const TreeKeyPart, k: TreeKeyPart) !BoxId {
    try self.tree.insertChild(parent, k, self.counter, self.allocator);
    defer self.counter += 1;
    return self.counter;
}

pub fn set(self: *Self, box: BoxId, comptime property: Properties, value: property.toType()) !void {
    return @field(self, @tagName(property)).putNoClobber(self.allocator, box, value);
}

pub fn get(self: Self, box: BoxId, comptime property: Properties) property.toType() {
    const T = property.toType();
    return @field(self, @tagName(property)).get(box) orelse T{};
}

test "basic test" {
    const allocator = std.heap.page_allocator;
    var blk_ctx = try init(allocator);
    defer blk_ctx.deinit();
    testing.expect(!blk_ctx.tree.exists(&[_]TreeKeyPart{}));
}
