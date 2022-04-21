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
    font: values.Font = .undeclared,

    pub const initial_values = Font{
        .font = .zss_default,
    };
};

pub const BoxStyle = struct {
    display: values.Display = .undeclared,
    position: values.Position = .undeclared,
    float: values.Float = .undeclared,

    pub const initial_values = BoxStyle{
        .display = .inline_,
        .position = .static,
        .float = .none,
    };
};

pub const ContentSize = struct {
    size: values.Size = .undeclared,
    min_size: values.MinSize = .undeclared,
    max_size: values.MaxSize = .undeclared,

    pub const initial_values = ContentSize{
        .size = .auto,
        .min_size = .{ .px = 0 },
        .max_size = .none,
    };
};

pub const BoxEdges = struct {
    padding_start: values.Padding = .undeclared,
    padding_end: values.Padding = .undeclared,
    border_start: values.BorderWidth = .undeclared,
    border_end: values.BorderWidth = .undeclared,
    margin_start: values.Margin = .undeclared,
    margin_end: values.Margin = .undeclared,

    pub const initial_values = BoxEdges{
        .padding_start = .{ .px = 0 },
        .padding_end = .{ .px = 0 },
        .border_start = .{ .px = 0 },
        .border_end = .{ .px = 0 },
        .margin_start = .{ .px = 0 },
        .margin_end = .{ .px = 0 },
    };
};

pub const ZIndex = struct {
    z_index: values.ZIndex = .undeclared,

    pub const initial_values = ZIndex{
        .z_index = .auto,
    };
};

pub const Insets = struct {
    left: values.Inset = .undeclared,
    right: values.Inset = .undeclared,
    top: values.Inset = .undeclared,
    bottom: values.Inset = .undeclared,

    pub const initial_values = Insets{
        .left = .auto,
        .right = .auto,
        .top = .auto,
        .bottom = .auto,
    };
};

pub const Color = struct {
    color: values.Color = .undeclared,

    pub const initial_values = Color{
        .color = values.Color.black,
    };
};

pub const BorderColors = struct {
    left: values.Color = .undeclared,
    right: values.Color = .undeclared,
    top: values.Color = .undeclared,
    bottom: values.Color = .undeclared,

    pub const initial_values = BorderColors{
        .left = .current_color,
        .right = .current_color,
        .top = .current_color,
        .bottom = .current_color,
    };
};

pub const Background1 = struct {
    color: values.Color = .undeclared,
    clip: values.BackgroundClip = .undeclared,

    pub const initial_values = Background1{
        .color = values.Color.transparent,
        .clip = .border_box,
    };
};

pub const Background2 = struct {
    image: values.BackgroundImage = .undeclared,
    repeat: values.BackgroundRepeat = .undeclared,
    position: values.BackgroundPosition = .undeclared,
    origin: values.BackgroundOrigin = .undeclared,
    size: values.BackgroundSize = .undeclared,

    pub const initial_values = Background2{
        .image = .none,
        .repeat = .{ .repeat = .{ .x = .repeat, .y = .repeat } },
        .position = .{ .position = .{
            .x = .{ .side = .left, .offset = .{ .percentage = 0 } },
            .y = .{ .side = .top, .offset = .{ .percentage = 0 } },
        } },
        .origin = .padding_box,
        .size = .{ .size = .{ .width = .auto, .height = .auto } },
    };
};
