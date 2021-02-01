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
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const AutoHashMapUnmanaged = std.AutoHashMapUnmanaged;

const zss = @import("../zss.zig");
pub const Id = zss.context.ContextSpecificBoxId;
pub const IdPart = zss.context.ContextSpecificBoxIdPart;
usingnamespace @import("properties.zig");
const PrefixTreeNode = @import("prefix-tree").PrefixTreeNode;
const ft = @import("freetype");

allocator: *Allocator,
tree: *TreeMap(bool),
line_boxes: ArrayListUnmanaged(LineBox),

width: *TreeMap(Width),
height: *TreeMap(Height),
margin_border_padding_left_right: *TreeMap(MarginBorderPaddingLeftRight),
margin_border_padding_top_bottom: *TreeMap(MarginBorderPaddingTopBottom),
border_colors: *TreeMap(BorderColor),
background_color: *TreeMap(BackgroundColor),
position: *TreeMap(Position),
data: *TreeMap(Data),

const Self = @This();

fn TreeMap(comptime V: type) type {
    return @import("prefix-tree-map").PrefixTreeMapUnmanaged(IdPart, V, zss.context.cmpPart);
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
    text: []ft.FT_BitmapGlyph,
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

    pub fn toType(comptime prop: @This()) type {
        return std.meta.Child(@TypeOf(@field(@as(Self, undefined), @tagName(prop)))).Value;
    }
};

pub fn init(allocator: *Allocator) !Self {
    var result = @as(Self, undefined);
    result.allocator = allocator;
    result.line_boxes = ArrayListUnmanaged(LineBox){};
    result.tree = try TreeMap(bool).init(allocator);
    errdefer result.tree.deinitRecursive(allocator);

    comptime const fields = std.meta.fields(Properties);
    var count: usize = 0;
    errdefer {
        inline for (fields) |f, i| {
            if (i < count) @field(result, f.name).deinitRecursive(allocator);
        }
    }
    inline for (fields) |f| {
        @field(result, f.name) = try std.meta.Child(@TypeOf(@field(result, f.name))).init(allocator);
        count += 1;
    }

    return result;
}

pub fn deinit(self: *Self) void {
    self.tree.deinitRecursive(self.allocator);
    self.line_boxes.deinit(self.allocator);
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
    const filler = if (T == Position or T == Data) undefined else T{};
    _ = try @field(self, @tagName(property)).insert(self.allocator, id, value, filler);
}

pub fn get(self: Self, id: Id, comptime property: Properties) property.toType() {
    assert(self.tree.exists(id));
    const T = property.toType();
    const optional = @field(self, @tagName(property)).get(id);

    if (T == Position or T == Data) {
        return optional orelse unreachable;
    } else {
        return optional orelse T{};
    }
}
