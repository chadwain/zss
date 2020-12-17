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
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const AutoHashMapUnmanaged = std.AutoHashMapUnmanaged;

usingnamespace @import("properties.zig");
const PrefixTreeNode = @import("prefix-tree").PrefixTreeNode;
const hb = @import("../zss.zig").harfbuzz.harfbuzz;

allocator: *Allocator,
tree: *Tree,
line_boxes: ArrayListUnmanaged(LineBox) = .{},
counter: MapKey = 0,

width: AutoHashMapUnmanaged(MapKey, Width) = .{},
height: AutoHashMapUnmanaged(MapKey, Height) = .{},
margin_border_padding_left_right: AutoHashMapUnmanaged(MapKey, MarginBorderPaddingLeftRight) = .{},
margin_border_padding_top_bottom: AutoHashMapUnmanaged(MapKey, MarginBorderPaddingTopBottom) = .{},
border_colors: AutoHashMapUnmanaged(MapKey, BorderColor) = .{},
background_color: AutoHashMapUnmanaged(MapKey, BackgroundColor) = .{},
position: AutoHashMapUnmanaged(MapKey, Position) = .{},
data: AutoHashMapUnmanaged(MapKey, Data) = .{},

const Self = @This();

pub const Tree = @import("prefix-tree-map").PrefixTreeMapUnmanaged(TreeKeyPart, MapKey, cmpFn);
pub const TreeKeyPart = u16;
pub const MapKey = u16;
fn cmpFn(lhs: TreeKeyPart, rhs: TreeKeyPart) std.math.Order {
    return std.math.order(lhs, rhs);
}

pub const LineBox = struct {
    y_pos: CSSUnit,
    baseline: CSSUnit,
};

pub const Position = struct {
    line_box_index: usize,
    advance: CSSUnit,
    ascender: CSSUnit,
};

pub const Data = union(enum) {
    empty_space,
    text: []hb.FT_BitmapGlyph,
};

pub const Properties = enum {
    width,
    height,
    margin_border_padding_left_right,
    margin_border_padding_top_bottom,
    border_colors,
    background_color,
    position,
    data,

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
    self.line_boxes.deinit(self.allocator);
    inline for (std.meta.fields(Properties)) |field| {
        @field(self, field.name).deinit(self.allocator);
    }
}

pub fn new(self: *Self, parent: []const TreeKeyPart, k: TreeKeyPart) !MapKey {
    try self.tree.insertChild(parent, k, self.counter, self.allocator);
    defer self.counter += 1;
    return self.counter;
}

pub fn set(self: *Self, key: MapKey, comptime property: Properties, value: property.toType()) !void {
    return @field(self, @tagName(property)).putNoClobber(self.allocator, key, value);
}

pub fn get(self: Self, key: MapKey, comptime property: Properties) property.toType() {
    const T = property.toType();
    const optional = @field(self, @tagName(property)).get(key);
    if (T == Position or T == Data) {
        return optional orelse unreachable;
    } else {
        return optional orelse T{};
    }
}
