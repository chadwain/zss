//! TODO delete this file!

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const AutoHashMapUnmanaged = std.AutoHashMapUnmanaged;

const zss = @import("../../zss.zig");
const CSSUnit = zss.types.CSSUnit;

const context = @import("context.zig");
pub const Id = context.ContextSpecificBoxId;
pub const IdPart = context.ContextSpecificBoxIdPart;
usingnamespace @import("properties.zig");

const ft = @import("freetype");

allocator: *Allocator,
tree: TreeMap(bool) = .{},
line_boxes: ArrayListUnmanaged(LineBox) = .{},

dimension: TreeMap(Dimension) = .{},
margin_border_padding_left_right: TreeMap(MarginBorderPaddingLeftRight) = .{},
margin_border_padding_top_bottom: TreeMap(MarginBorderPaddingTopBottom) = .{},
border_colors: TreeMap(BorderColor) = .{},
background_color: TreeMap(BackgroundColor) = .{},
position: TreeMap(Position) = .{},
data: TreeMap(Data) = .{},

const Self = @This();

fn TreeMap(comptime V: type) type {
    return @import("prefix-tree-map").PrefixTreeMapUnmanaged(IdPart, V, context.cmpPart);
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
    dimension,
    margin_border_padding_left_right,
    margin_border_padding_top_bottom,
    border_colors,
    background_color,
    position,
    data,

    pub fn toType(comptime prop: @This()) type {
        return @TypeOf(@field(@as(Self, undefined), @tagName(prop))).Value;
    }
};

pub fn init(allocator: *Allocator) Self {
    return Self{ .allocator = allocator };
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