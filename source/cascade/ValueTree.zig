const zss = @import("../../zss.zig");
const Index = zss.ElementTree.Index;
const value = zss.value;
const SparseSkipTree = zss.SparseSkipTree;

const std = @import("std");
const Allocator = std.mem.Allocator;

const Self = @This();

pub const AggregatePropertyEnum = enum {
    box_style,
    content_width,
    horizontal_edges,
    content_height,
    vertical_edges,
    z_index,
    insets,
    border_colors,
    background1,
    background2,

    color,
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

    pub const InheritanceType = enum { inherited, not_inherited };

    pub fn inheritanceType(self: @This()) InheritanceType {
        return switch (self) {
            .box_style,
            .content_width,
            .horizontal_edges,
            .content_height,
            .vertical_edges,
            .z_index,
            .insets,
            .border_colors,
            .background1,
            .background2,
            .unicode_bidi,
            => .not_inherited,

            .color,
            .direction,
            .custom,
            => .inherited,
        };
    }
};

pub const Values = struct {
    all: SparseSkipTree(Index, All) = .{},
    text: SparseSkipTree(Index, Text) = .{},

    box_style: SparseSkipTree(Index, BoxStyle) = .{},

    content_width: SparseSkipTree(Index, ContentSize) = .{},
    horizontal_edges: SparseSkipTree(Index, BoxEdges) = .{},

    content_height: SparseSkipTree(Index, ContentSize) = .{},
    vertical_edges: SparseSkipTree(Index, BoxEdges) = .{},

    z_index: SparseSkipTree(Index, ZIndex) = .{},
    insets: SparseSkipTree(Index, Insets) = .{},

    color: SparseSkipTree(Index, Color) = .{},
    border_colors: SparseSkipTree(Index, BorderColors) = .{},
    background1: SparseSkipTree(Index, Background1) = .{},
    background2: SparseSkipTree(Index, Background2) = .{},
};

pub const Font = struct {
    const hb = @import("harfbuzz");

    font: *hb.hb_font_t,
    color: value.Color,
};

values: Values = .{},
font: Font,

pub fn deinit(self: *Self, allocator: Allocator) void {
    inline for (std.meta.fields(Values)) |f| {
        @field(self.values, f.name).deinit(allocator);
    }
}

pub const All = struct {
    all: value.All,
};

pub const Text = struct {
    text: value.Text,
};

pub const BoxStyle = struct {
    display: value.Display = .inline_,
    position: value.Position = .static,
    float: value.Float = .none,
};

pub const ContentSize = struct {
    size: value.Size = .auto,
    min_size: value.MinSize = .{ .px = 0 },
    max_size: value.MaxSize = .none,
};

pub const BoxEdges = struct {
    padding_start: value.Padding = .{ .px = 0 },
    padding_end: value.Padding = .{ .px = 0 },
    border_start: value.BorderWidth = .{ .px = 0 },
    border_end: value.BorderWidth = .{ .px = 0 },
    margin_start: value.Margin = .{ .px = 0 },
    margin_end: value.Margin = .{ .px = 0 },
};

pub const ZIndex = struct {
    z_index: value.ZIndex = .auto,
};

pub const Insets = struct {
    top: value.Inset = .auto,
    right: value.Inset = .auto,
    bottom: value.Inset = .auto,
    left: value.Inset = .auto,
};

pub const Color = struct {
    color: value.Color = value.Color.transparent,
};

pub const BorderColors = struct {
    top: value.Color = .current_color,
    right: value.Color = .current_color,
    bottom: value.Color = .current_color,
    left: value.Color = .current_color,
};

pub const Background1 = struct {
    color: value.Color = value.Color.transparent,
    clip: value.BackgroundClip = .border_box,
};

pub const Background2 = struct {
    image: value.BackgroundImage = .none,
    repeat: value.BackgroundRepeat = .{ .repeat = .{ .x = .repeat, .y = .repeat } },
    position: value.BackgroundPosition = .{ .position = .{ .x = .{ .side = .left, .offset = .{ .percentage = 0 } }, .y = .{ .side = .top, .offset = .{ .percentage = 0 } } } },
    origin: value.BackgroundOrigin = .padding_box,
    size: value.BackgroundSize = .{ .size = .{ .width = .auto, .height = .auto } },
};
