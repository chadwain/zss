//! This struct maps elements to their CSS cascaded values.
//!
//! Each field of this struct has a doc comment which specifies how each field
//! of the value struct corresponds to a particular CSS property.

const zss = @import("../../zss.zig");
const aggregates = zss.values.aggregates;
const Element = zss.ElementTree.Element;

const std = @import("std");
const Allocator = std.mem.Allocator;

const CascadedValueStore = @This();

pub fn Store(comptime ValueType: type) type {
    return struct {
        map: Map = .{},

        pub const Key = Element;
        pub const Value = ValueType;
        pub const Map = std.AutoHashMapUnmanaged(Key, Value);

        pub fn deinit(self: *@This(), allocator: Allocator) void {
            self.map.deinit(allocator);
        }

        pub fn ensureTotalCapacity(self: *@This(), allocator: Allocator, count: Map.Size) !void {
            return self.map.ensureTotalCapacity(allocator, count);
        }

        pub fn ensureUnusedCapacity(self: *@This(), allocator: Allocator, count: Map.Size) !void {
            return self.map.ensureUnusedCapacity(allocator, count);
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
all: Store(aggregates.All) = .{},

/// * text -> Does not correspond to any CSS property. Instead it represents the text of a text element.
text: Store(aggregates.Text) = .{},

/// * display  -> display
/// * position -> position
/// * float    -> float
box_style: Store(aggregates.BoxStyle) = .{},

/// * size     -> width
/// * min_size -> min-width
/// * max_size -> max-width
content_width: Store(aggregates.ContentSize) = .{},

/// * padding_start -> padding-left
/// * padding_end   -> padding-right
/// * border_start  -> border-width-left
/// * border_end    -> border-width-right
/// * margin_start  -> margin-left
/// * margin_end    -> margin-right
horizontal_edges: Store(aggregates.BoxEdges) = .{},

/// * size     -> height
/// * min_size -> min-height
/// * max_size -> max-height
content_height: Store(aggregates.ContentSize) = .{},

/// * padding_start -> padding-top
/// * padding_end   -> padding-bottom
/// * border_start  -> border-width-top
/// * border_end    -> border-width-bottom
/// * margin_start  -> margin-top
/// * margin_end    -> margin-bottom
vertical_edges: Store(aggregates.BoxEdges) = .{},

/// * z_index -> z-index
z_index: Store(aggregates.ZIndex) = .{},

/// * left   -> left
/// * right  -> right
/// * top    -> top
/// * bottom -> bottom
insets: Store(aggregates.Insets) = .{},

/// * color -> color
color: Store(aggregates.Color) = .{},

/// * left   -> border-left-color
/// * right  -> border-right-color
/// * top    -> border-top-color
/// * bottom -> border-bottom-color
border_colors: Store(aggregates.BorderColors) = .{},

/// * left   -> border-left-style
/// * right  -> border-right-style
/// * top    -> border-top-style
/// * bottom -> border-bottom-style
border_styles: Store(aggregates.BorderStyles) = .{},

/// * color -> background-color
/// * clip  -> background-clip
background1: Store(aggregates.Background1) = .{},

/// * image    -> background-image
/// * repeat   -> background-image
/// * position -> background-position
/// * origin   -> background-origin
/// * size     -> background-size
background2: Store(aggregates.Background2) = .{},

/// * font -> Does not correspond to any CSS property. Instead it represents a font object.
font: Store(aggregates.Font) = .{},

pub fn deinit(self: *CascadedValueStore, allocator: Allocator) void {
    inline for (std.meta.fields(CascadedValueStore)) |field_info| {
        @field(self, field_info.name).deinit(allocator);
    }
}

pub fn ensureTotalCapacity(self: *CascadedValueStore, allocator: Allocator, count: u32) !void {
    inline for (std.meta.fields(CascadedValueStore)) |field_info| {
        try @field(self, field_info.name).ensureTotalCapacity(allocator, count);
    }
}
