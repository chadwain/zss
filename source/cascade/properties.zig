//! Each struct defines 1 or more CSS properties.
//!
//! We group several related properties together (into an aggregate), rather
//! than having every property be separate.
//!
//! Within an aggregate, each property *must* have the same inheritance type
//! (meaning, they must be all inherited properties or all non-inherited properties).
//! The default value of each field is the initial value of that property.

const zss = @import("../../zss.zig");
const values = zss.values;

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
    font,
    // Not yet implemented.
    direction,
    unicode_bidi,
    custom, // Custom property

    pub fn Value(comptime self: @This()) type {
        return switch (self) {
            .box_style => BoxStyle,
            .content_width => ContentSize,
            .horizontal_edges => BoxEdges,
            .content_height => ContentSize,
            .vertical_edges => BoxEdges,
            .z_index => ZIndex,
            .insets => Insets,
            .border_colors => BorderColors,
            .background1 => Background1,
            .background2 => Background2,
            .color => Color,
            .font => Font,

            .direction,
            .unicode_bidi,
            .custom,
            => @compileError("TODO: Value(" ++ @tagName(self) ++ ")"),
        };
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
            .font,
            .direction,
            .custom,
            => .inherited,
        };
    }
};

pub const All = struct {
    all: values.All,
};

pub const Text = struct {
    text: values.Text,
};

pub const Font = struct {
    font: values.Font = .zss_default,
};

pub const BoxStyle = struct {
    display: values.Display = .inline_,
    position: values.Position = .static,
    float: values.Float = .none,
};

pub const ContentSize = struct {
    size: values.Size = .auto,
    min_size: values.MinSize = .{ .px = 0 },
    max_size: values.MaxSize = .none,
};

pub const BoxEdges = struct {
    padding_start: values.Padding = .{ .px = 0 },
    padding_end: values.Padding = .{ .px = 0 },
    border_start: values.BorderWidth = .{ .px = 0 },
    border_end: values.BorderWidth = .{ .px = 0 },
    margin_start: values.Margin = .{ .px = 0 },
    margin_end: values.Margin = .{ .px = 0 },
};

pub const ZIndex = struct {
    z_index: values.ZIndex = .auto,
};

pub const Insets = struct {
    left: values.Inset = .auto,
    right: values.Inset = .auto,
    top: values.Inset = .auto,
    bottom: values.Inset = .auto,
};

pub const Color = struct {
    color: values.Color = values.Color.black,
};

pub const BorderColors = struct {
    left: values.Color = .current_color,
    right: values.Color = .current_color,
    top: values.Color = .current_color,
    bottom: values.Color = .current_color,
};

pub const Background1 = struct {
    color: values.Color = values.Color.transparent,
    clip: values.BackgroundClip = .border_box,
};

pub const Background2 = struct {
    image: values.BackgroundImage = .none,
    repeat: values.BackgroundRepeat = .{ .repeat = .{ .x = .repeat, .y = .repeat } },
    position: values.BackgroundPosition = .{ .position = .{
        .x = .{ .side = .left, .offset = .{ .percentage = 0 } },
        .y = .{ .side = .top, .offset = .{ .percentage = 0 } },
    } },
    origin: values.BackgroundOrigin = .padding_box,
    size: values.BackgroundSize = .{ .size = .{ .width = .auto, .height = .auto } },
};
