const zss = @import("../../zss.zig");
const Index = zss.ElementTree.Index;
const value = zss.value;
const SparseSkipTree = zss.SparseSkipTree;

const std = @import("std");
const Allocator = std.mem.Allocator;

const Self = @This();

pub const AggregatePropertyEnum = enum {
    all,
    display_position_float,
    widths,
    horizontal_sizes,
    heights,
    vertical_sizes,
    z_index,
    insets,

    // Not yet implemented.
    direction,
    unicode_bidi,
    custom, // Custom property

    pub fn Value(comptime self: @This()) type {
        const Enum = std.meta.FieldEnum(Values);
        const name = @tagName(self);
        const tag = std.meta.stringToEnum(Enum, name) orelse @compileError("TODO: Value(" ++ name ++ ")");
        const field = std.meta.fieldInfo(Values, tag);
        return field.field_type.Value;
    }

    pub const InheritanceType = enum { inherited, not_inherited, neither };

    pub fn inheritanceType(self: @This()) InheritanceType {
        return switch (self) {
            .all => .neither,

            .display_position_float,
            .widths,
            .horizontal_sizes,
            .heights,
            .vertical_sizes,
            .z_index,
            .insets,
            .unicode_bidi,
            => .not_inherited,

            .direction,
            .custom,
            => .inherited,
        };
    }
};

pub const Values = struct {
    all: SparseSkipTree(Index, struct { all: value.All }) = .{},

    display_position_float: SparseSkipTree(Index, DisplayPositionFloat) = .{},

    widths: SparseSkipTree(Index, Sizes) = .{},
    horizontal_sizes: SparseSkipTree(Index, PaddingBorderMargin) = .{},

    heights: SparseSkipTree(Index, Sizes) = .{},
    vertical_sizes: SparseSkipTree(Index, PaddingBorderMargin) = .{},

    z_index: SparseSkipTree(Index, struct { z_index: value.ZIndex = .auto }) = .{},
    insets: SparseSkipTree(Index, Insets) = .{},
};

values: Values = .{},

pub fn deinit(self: *Self, allocator: Allocator) void {
    inline for (std.meta.fields(Values)) |f| {
        @field(self.values, f.name).deinit(allocator);
    }
}

pub const DisplayPositionFloat = struct {
    display: value.Display = .inline_,
    position: value.Position = .static,
    float: value.Float = .none,
};

pub const Sizes = struct {
    size: value.Size = .auto,
    min_size: value.MinSize = .{ .px = 0 },
    max_size: value.MaxSize = .none,
};

pub const PaddingBorderMargin = struct {
    padding_start: value.Padding = .{ .px = 0 },
    padding_end: value.Padding = .{ .px = 0 },
    border_start: value.BorderWidth = .medium,
    border_end: value.BorderWidth = .medium,
    margin_start: value.Margin = .{ .px = 0 },
    margin_end: value.Margin = .{ .px = 0 },
};

pub const Insets = struct {
    top: value.Inset = .auto,
    right: value.Inset = .auto,
    bottom: value.Inset = .auto,
    left: value.Inset = .auto,
};
