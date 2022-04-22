//! This struct maps elements to their CSS cascaded values.
//! These values are all structs defined in ./properties.zig.
//!
//! Each field of this struct has a doc comment which specifies how each field
//! of the value struct corresponds to a particular CSS property.

const zss = @import("../../zss.zig");
const properties = zss.properties;
const ElementRef = zss.ElementRef;

const std = @import("std");
const Allocator = std.mem.Allocator;

const Self = @This();

pub fn Store(comptime ValueType: type) type {
    return struct {
        map: Map = .{},

        pub const Key = ElementRef;
        pub const Value = ValueType;
        pub const Map = std.AutoHashMapUnmanaged(Key, Value);

        pub fn deinit(self: *@This(), allocator: Allocator) void {
            self.map.deinit(allocator);
        }

        pub fn ensureTotalCapacity(self: *@This(), allocator: Allocator, count: Map.Size) !void {
            return self.map.ensureTotalCapacity(allocator, count);
        }

        pub fn setAssumeCapacity(self: *@This(), key: Key, v: Value) void {
            self.map.putAssumeCapacity(key, v);
        }

        pub fn get(self: @This(), key: Key) ?Value {
            return self.map.get(key);
        }
    };
}

/// * all -> all
all: Store(properties.All) = .{},

/// * text -> Does not correspond to any CSS property. Instead it represents the text of a text element.
text: Store(properties.Text) = .{},

/// * display  -> display
/// * position -> position
/// * float    -> float
box_style: Store(properties.BoxStyle) = .{},

/// * size     -> width
/// * min_size -> min-width
/// * max_size -> max-width
content_width: Store(properties.ContentSize) = .{},

/// * padding_start -> padding-left
/// * padding_end   -> padding-right
/// * border_start  -> border-width-left
/// * border_end    -> border-width-right
/// * margin_start  -> margin-left
/// * margin_end    -> margin-right
horizontal_edges: Store(properties.BoxEdges) = .{},

/// * size     -> height
/// * min_size -> min-height
/// * max_size -> max-height
content_height: Store(properties.ContentSize) = .{},

/// * padding_start -> padding-top
/// * padding_end   -> padding-bottom
/// * border_start  -> border-width-top
/// * border_end    -> border-width-bottom
/// * margin_start  -> margin-top
/// * margin_end    -> margin-bottom
vertical_edges: Store(properties.BoxEdges) = .{},

/// * z_index -> z-index
z_index: Store(properties.ZIndex) = .{},

/// * left   -> left
/// * right  -> right
/// * top    -> top
/// * bottom -> bottom
insets: Store(properties.Insets) = .{},

/// * color -> color
color: Store(properties.Color) = .{},

/// * left   -> border-left-color
/// * right  -> border-right-color
/// * top    -> border-top-color
/// * bottom -> border-bottom-color
border_colors: Store(properties.BorderColors) = .{},

/// * left   -> border-left-style
/// * right  -> border-right-style
/// * top    -> border-top-style
/// * bottom -> border-bottom-style
border_styles: Store(properties.BorderStyles) = .{},

/// * color -> background-color
/// * clip  -> background-clip
background1: Store(properties.Background1) = .{},

/// * image    -> background-image
/// * repeat   -> background-image
/// * position -> background-position
/// * origin   -> background-origin
/// * size     -> background-size
background2: Store(properties.Background2) = .{},

/// * font -> Does not correspond to any CSS property. Instead it represents a font object.
font: Store(properties.Font) = .{},

pub fn deinit(self: *Self, allocator: Allocator) void {
    inline for (std.meta.fields(Self)) |field_info| {
        @field(self, field_info.name).deinit(allocator);
    }
}

pub fn ensureTotalCapacity(self: *Self, allocator: Allocator, count: ElementRef) !void {
    inline for (std.meta.fields(Self)) |field_info| {
        try @field(self, field_info.name).ensureTotalCapacity(allocator, count);
    }
}
