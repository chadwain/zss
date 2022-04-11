const zss = @import("../../zss.zig");
const properties = zss.properties;
const ElementRef = zss.ElementTree.Ref;

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

all: Store(properties.All) = .{},
text: Store(properties.Text) = .{},

box_style: Store(properties.BoxStyle) = .{},

content_width: Store(properties.ContentSize) = .{},
horizontal_edges: Store(properties.BoxEdges) = .{},

content_height: Store(properties.ContentSize) = .{},
vertical_edges: Store(properties.BoxEdges) = .{},

z_index: Store(properties.ZIndex) = .{},
insets: Store(properties.Insets) = .{},

color: Store(properties.Color) = .{},
border_colors: Store(properties.BorderColors) = .{},
background1: Store(properties.Background1) = .{},
background2: Store(properties.Background2) = .{},

font: properties.Font,

pub fn deinit(self: *Self, allocator: Allocator) void {
    inline for (std.meta.fields(Self)) |field_info| {
        if (field_info.field_type != properties.Font) {
            @field(self, field_info.name).deinit(allocator);
        }
    }
}
