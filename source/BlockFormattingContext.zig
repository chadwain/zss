// This file is a part of zss.
// Copyright (C) 2020-2021 Chadwain Holness
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
const assert = std.debug.assert;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const AutoHashMapUnmanaged = std.AutoHashMapUnmanaged;

const zss = @import("../zss.zig");
pub const Id = zss.context.ContextSpecificBoxId;
pub const IdPart = zss.context.ContextSpecificBoxIdPart;
usingnamespace @import("properties.zig");

allocator: *Allocator,
tree: TreeMap(bool) = .{},

width: TreeMap(Width) = .{},
height: TreeMap(Height) = .{},
borders: TreeMap(Borders) = .{},
padding: TreeMap(Padding) = .{},
margin_left_right: TreeMap(MarginLeftRight) = .{},
margin_top_bottom: TreeMap(MarginTopBottom) = .{},
border_colors: TreeMap(BorderColor) = .{},
background_color: TreeMap(BackgroundColor) = .{},

const Self = @This();

fn TreeMap(comptime V: type) type {
    return @import("prefix-tree-map").PrefixTreeMapUnmanaged(IdPart, V, zss.context.cmpPart);
}

pub const Properties = enum {
    width,
    height,
    borders,
    padding,
    margin_left_right,
    margin_top_bottom,
    border_colors,
    background_color,

    pub fn toType(comptime prop: @This()) type {
        const Enum = std.meta.FieldEnum(Self);
        return @TypeOf(@field(@as(Self, undefined), @tagName(prop))).Value;
    }
};

pub fn init(allocator: *Allocator) Self {
    return Self{ .allocator = allocator };
}

pub fn deinit(self: *Self) void {
    self.tree.deinitRecursive(self.allocator);
    inline for (std.meta.fields(Properties)) |field| {
        @field(self, field.name).deinitRecursive(self.allocator);
    }
}

pub fn new(self: *Self, id: Id) !void {
    _ = try self.tree.insert(self.allocator, id, true, false);
}

pub fn set(self: *Self, id: Id, comptime property: Properties, value: property.toType()) !void {
    assert(self.tree.exists(id));
    const T = property.toType();
    _ = try @field(self, @tagName(property)).insert(self.allocator, id, value, T{});
}

pub fn get(self: Self, id: Id, comptime property: Properties) property.toType() {
    assert(self.tree.exists(id));
    const T = property.toType();
    return @field(self, @tagName(property)).get(id) orelse T{};
}
