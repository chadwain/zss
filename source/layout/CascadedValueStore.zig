//! This struct maps elements to their CSS cascaded values.
//!
//! Each field of this struct has a doc comment which specifies how each field
//! of the value struct corresponds to a particular CSS property.

const zss = @import("../../zss.zig");
const aggregates = zss.properties.aggregates;
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

all: Store(aggregates.All) = .{},
text: Store(aggregates.Text) = .{},
box_style: Store(aggregates.BoxStyle) = .{},
content_width: Store(aggregates.ContentWidth) = .{},
horizontal_edges: Store(aggregates.HorizontalEdges) = .{},
content_height: Store(aggregates.ContentHeight) = .{},
vertical_edges: Store(aggregates.VerticalEdges) = .{},
z_index: Store(aggregates.ZIndex) = .{},
insets: Store(aggregates.Insets) = .{},
color: Store(aggregates.Color) = .{},
border_colors: Store(aggregates.BorderColors) = .{},
border_styles: Store(aggregates.BorderStyles) = .{},
background1: Store(aggregates.Background1) = .{},
background2: Store(aggregates.Background2) = .{},
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
