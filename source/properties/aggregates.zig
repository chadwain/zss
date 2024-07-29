//! CSS properties are grouped in aggregates.
//! Each aggregate contains properties that are likely to be used together.
//! Within an aggregate, each property *must* have the same inheritance type
//! (i.e. they must be all inherited properties or all non-inherited properties.
//! See https://www.w3.org/TR/css-cascade/#inherited-property).
//!
//! Each aggregate has comments which map each field to a CSS property, in this format:
//! /// <field-name> -> <CSS-property-name>

const zss = @import("../zss.zig");
const types = zss.values.types;

pub const Tag = enum {
    box_style,
    content_width,
    horizontal_edges,
    content_height,
    vertical_edges,
    z_index,
    insets,
    border_colors,
    border_styles,
    background1,
    background2,

    color,
    font,
    // Not yet implemented.
    direction,
    unicode_bidi,
    custom, // Custom property

    pub fn Value(comptime tag: Tag) type {
        return switch (tag) {
            .box_style => BoxStyle,
            .content_width => ContentWidth,
            .horizontal_edges => HorizontalEdges,
            .content_height => ContentHeight,
            .vertical_edges => VerticalEdges,
            .z_index => ZIndex,
            .insets => Insets,
            .border_colors => BorderColors,
            .border_styles => BorderStyles,
            .background1 => Background1,
            .background2 => Background2,
            .color => Color,
            .font => Font,

            .direction,
            .unicode_bidi,
            .custom,
            => @compileError("TODO: Value(" ++ @tagName(tag) ++ ")"),
        };
    }

    pub const InheritanceType = enum { inherited, not_inherited };

    pub fn inheritanceType(tag: Tag) InheritanceType {
        return switch (tag) {
            .box_style,
            .content_width,
            .horizontal_edges,
            .content_height,
            .vertical_edges,
            .z_index,
            .insets,
            .border_colors,
            .border_styles,
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

/// font -> Does not correspond to any CSS property. Instead it represents a font object.
pub const Font = struct {
    font: types.Font = .undeclared,

    pub const initial_values = Font{
        .font = .default,
    };
};

/// display  -> display
/// position -> position
/// float    -> float
pub const BoxStyle = struct {
    display: types.Display = .undeclared,
    position: types.Position = .undeclared,
    float: types.Float = .undeclared,

    pub const initial_values = BoxStyle{
        .display = .@"inline",
        .position = .static,
        .float = .none,
    };
};

/// width     -> width
/// min_width -> min-width
/// max_width -> max-width
pub const ContentWidth = struct {
    width: types.Size = .undeclared,
    min_width: types.MinSize = .undeclared,
    max_width: types.MaxSize = .undeclared,

    pub const initial_values = ContentWidth{
        .width = .auto,
        .min_width = .{ .px = 0 },
        .max_width = .none,
    };
};

/// height     -> height
/// min_height -> min-height
/// max_height -> max-height
pub const ContentHeight = struct {
    height: types.Size = .undeclared,
    min_height: types.MinSize = .undeclared,
    max_height: types.MaxSize = .undeclared,

    pub const initial_values = ContentHeight{
        .height = .auto,
        .min_height = .{ .px = 0 },
        .max_height = .none,
    };
};

/// padding_left  -> padding-left
/// padding_right -> padding-right
/// border_left   -> border-width-left
/// border_right  -> border-width-right
/// margin_left   -> margin-left
/// margin_right  -> margin-right
pub const HorizontalEdges = struct {
    padding_left: types.Padding = .undeclared,
    padding_right: types.Padding = .undeclared,
    border_left: types.BorderWidth = .undeclared,
    border_right: types.BorderWidth = .undeclared,
    margin_left: types.Margin = .undeclared,
    margin_right: types.Margin = .undeclared,

    pub const initial_values = HorizontalEdges{
        .padding_left = .{ .px = 0 },
        .padding_right = .{ .px = 0 },
        .border_left = .medium,
        .border_right = .medium,
        .margin_left = .{ .px = 0 },
        .margin_right = .{ .px = 0 },
    };
};

/// padding_top    -> padding-top
/// padding_bottom -> padding-bottom
/// border_top     -> border-width-top
/// border_bottom  -> border-width-bottom
/// margin_top     -> margin-top
/// margin_bottom  -> margin-bottom
pub const VerticalEdges = struct {
    padding_top: types.Padding = .undeclared,
    padding_bottom: types.Padding = .undeclared,
    border_top: types.BorderWidth = .undeclared,
    border_bottom: types.BorderWidth = .undeclared,
    margin_top: types.Margin = .undeclared,
    margin_bottom: types.Margin = .undeclared,

    pub const initial_values = VerticalEdges{
        .padding_top = .{ .px = 0 },
        .padding_bottom = .{ .px = 0 },
        .border_top = .medium,
        .border_bottom = .medium,
        .margin_top = .{ .px = 0 },
        .margin_bottom = .{ .px = 0 },
    };
};

/// z_index -> z-index
pub const ZIndex = struct {
    z_index: types.ZIndex = .undeclared,

    pub const initial_values = ZIndex{
        .z_index = .auto,
    };
};

/// left   -> left
/// right  -> right
/// top    -> top
/// bottom -> bottom
pub const Insets = struct {
    left: types.Inset = .undeclared,
    right: types.Inset = .undeclared,
    top: types.Inset = .undeclared,
    bottom: types.Inset = .undeclared,

    pub const initial_values = Insets{
        .left = .auto,
        .right = .auto,
        .top = .auto,
        .bottom = .auto,
    };
};

/// color -> color
pub const Color = struct {
    color: types.Color = .undeclared,

    pub const initial_values = Color{
        .color = types.Color.black,
    };
};

/// left   -> border-left-color
/// right  -> border-right-color
/// top    -> border-top-color
/// bottom -> border-bottom-color
pub const BorderColors = struct {
    left: types.Color = .undeclared,
    right: types.Color = .undeclared,
    top: types.Color = .undeclared,
    bottom: types.Color = .undeclared,

    pub const initial_values = BorderColors{
        .left = .current_color,
        .right = .current_color,
        .top = .current_color,
        .bottom = .current_color,
    };
};

/// left   -> border-left-style
/// right  -> border-right-style
/// top    -> border-top-style
/// bottom -> border-bottom-style
pub const BorderStyles = struct {
    left: types.BorderStyle = .undeclared,
    right: types.BorderStyle = .undeclared,
    top: types.BorderStyle = .undeclared,
    bottom: types.BorderStyle = .undeclared,

    pub const initial_values = BorderStyles{
        .left = .none,
        .right = .none,
        .top = .none,
        .bottom = .none,
    };
};

/// color -> background-color
/// clip  -> background-clip
pub const Background1 = struct {
    color: types.Color = .undeclared,
    clip: types.BackgroundClip = .undeclared,

    pub const initial_values = Background1{
        .color = types.Color.transparent,
        .clip = .border_box,
    };
};

/// image    -> background-image
/// repeat   -> background-repeat
/// position -> background-position
/// origin   -> background-origin
/// size     -> background-size
pub const Background2 = struct {
    image: types.BackgroundImage = .undeclared,
    repeat: types.BackgroundRepeat = .undeclared,
    position: types.BackgroundPosition = .undeclared,
    origin: types.BackgroundOrigin = .undeclared,
    size: types.BackgroundSize = .undeclared,

    pub const initial_values = Background2{
        .image = .none,
        .repeat = .{ .repeat = .{ .x = .repeat, .y = .repeat } },
        .position = .{ .position = .{
            .x = .{ .side = .start, .offset = .{ .percentage = 0 } },
            .y = .{ .side = .start, .offset = .{ .percentage = 0 } },
        } },
        .origin = .padding_box,
        .size = .{ .size = .{ .width = .auto, .height = .auto } },
    };
};
