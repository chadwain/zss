//! In zss, CSS properties are grouped in aggregates.
//! Each aggregate contains properties that are likely to be used together.
//! Within an aggregate, each property *must* have the same inheritance type
//! (i.e. they must be all inherited properties or all non-inherited properties.
//! See https://www.w3.org/TR/css-cascade/#inherited-property).
//!
//! Each aggregate has comments which map each field to a CSS property, in this format:
//! /// <field-name> -> <CSS-property-name>

const zss = @import("../zss.zig");
const types = zss.values.types;

const std = @import("std");

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
    background_color,
    background_clip,
    background,

    color,
    font,

    fn Value(comptime tag: Tag) type {
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
            .background_color => BackgroundColor,
            .background_clip => BackgroundClip,
            .background => Background,
            .color => Color,
            .font => Font,
        };
    }

    pub const InheritanceType = enum { inherited, not_inherited };

    pub fn inheritanceType(comptime tag: Tag) InheritanceType {
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
            .background_color,
            .background_clip,
            .background,
            => .not_inherited,

            .color,
            .font,
            => .inherited,
        };
    }

    pub const Size = enum { single, multi };

    pub fn size(comptime tag: Tag) Size {
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
            .background_color,
            .color,
            .font, // TODO: should probably be multi
            => .single,

            .background_clip,
            .background,
            => .multi,
        };
    }

    /// A struct that can represent the declared values of all fields within
    /// the aggregate represented by `tag`.
    pub fn DeclaredValues(comptime tag: Tag) type {
        const ns = struct {
            fn fieldMap(comptime field: tag.FieldEnum()) struct { type, ?*const anyopaque } {
                const Field = tag.FieldType(field);
                const Type = switch (tag.size()) {
                    .single => SingleValue(Field),
                    .multi => MultiValue(Field),
                };
                const default: *const Type = &.undeclared;
                return .{ Type, default };
            }
        };
        return zss.meta.EnumFieldMapStruct(tag.FieldEnum(), ns.fieldMap);
    }

    /// A struct that can represent the cascaded values of all fields within
    /// the aggregate represented by `tag`.
    pub const CascadedValues = DeclaredValues;

    /// A struct that can represent the specified values of all fields within
    /// the aggregate represented by `tag`.
    pub fn SpecifiedValues(comptime tag: Tag) type {
        const ns = struct {
            fn fieldMap(comptime field: tag.FieldEnum()) struct { type, ?*const anyopaque } {
                const Field = tag.FieldType(field);
                const Type = switch (tag.size()) {
                    .single => Field,
                    .multi => []const Field,
                };
                return .{ Type, null };
            }
        };
        return zss.meta.EnumFieldMapStruct(tag.FieldEnum(), ns.fieldMap);
    }

    /// A struct that can represent the computed values of all fields within
    /// the aggregate represented by `tag`.
    pub const ComputedValues = SpecifiedValues;

    pub fn initialValues(comptime tag: Tag) tag.SpecifiedValues() {
        return comptime blk: {
            const Aggregate = tag.Value();
            var result: tag.SpecifiedValues() = undefined;
            switch (tag.size()) {
                .single => {
                    for (std.meta.fields(Aggregate)) |field| {
                        @field(result, field.name) = @field(Aggregate.initial_values, field.name);
                    }
                },
                .multi => {
                    for (std.meta.fields(Aggregate)) |field| {
                        @field(result, field.name) = &.{@field(Aggregate.initial_values, field.name)};
                    }
                },
            }
            break :blk result;
        };
    }

    const AggregateField = struct {
        name: []const u8,
        type: type,
    };

    pub fn fields(comptime tag: Tag) []const AggregateField {
        return comptime blk: {
            const Aggregate = tag.Value();
            const aggregate_fields = std.meta.fields(Aggregate);
            var result: [aggregate_fields.len]AggregateField = undefined;
            for (aggregate_fields, &result) |src, *dest| {
                dest.* = .{ .name = src.name, .type = src.type };
            }
            break :blk &result;
        };
    }

    pub fn FieldEnum(comptime tag: Tag) type {
        const Aggregate = tag.Value();
        @setEvalBranchQuota(@typeInfo(Aggregate).@"struct".fields.len * 800);
        return std.meta.FieldEnum(Aggregate);
    }

    pub fn FieldType(comptime tag: Tag, comptime field: tag.FieldEnum()) type {
        return @FieldType(tag.Value(), @tagName(field));
    }
};

/// Represents either a CSS value, or a CSS-wide keyword, or `undeclared` (the absence of a declared value)
pub const DeclaredValueTag = enum {
    undeclared,
    initial,
    inherit,
    unset,
    declared,
};

/// Represents either a CSS value, or a CSS-wide keyword, or `undeclared` (the absence of a declared value)
pub fn SingleValue(comptime T: type) type {
    return union(DeclaredValueTag) {
        undeclared,
        initial,
        inherit,
        unset,
        declared: T,

        pub fn expectEqual(actual: @This(), expected: @This()) !void {
            try std.testing.expectEqual(@as(DeclaredValueTag, expected), @as(DeclaredValueTag, actual));
            switch (expected) {
                .declared => |expected_value| try std.testing.expectEqual(expected_value, actual.declared),
                else => {},
            }
        }
    };
}

/// Represents either a CSS value, or a CSS-wide keyword, or `undeclared` (the absence of a declared value)
pub fn MultiValue(comptime T: type) type {
    return union(DeclaredValueTag) {
        undeclared,
        initial,
        inherit,
        unset,
        declared: []const T,

        pub fn expectEqual(actual: @This(), expected: @This()) !void {
            try std.testing.expectEqual(@as(DeclaredValueTag, expected), @as(DeclaredValueTag, actual));
            switch (expected) {
                .declared => |expected_value| try std.testing.expectEqualSlices(T, expected_value, actual.declared),
                else => {},
            }
        }
    };
}

// TODO: font does not correspond to any CSS property
pub const Font = struct {
    font: types.Font,

    pub const initial_values = Font{
        .font = .default,
    };
};

/// display  -> display
/// position -> position
/// float    -> float
pub const BoxStyle = struct {
    display: types.Display,
    position: types.Position,
    float: types.Float,

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
    width: types.Size,
    min_width: types.MinSize,
    max_width: types.MaxSize,

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
    height: types.Size,
    min_height: types.MinSize,
    max_height: types.MaxSize,

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
    padding_left: types.Padding,
    padding_right: types.Padding,
    border_left: types.BorderWidth,
    border_right: types.BorderWidth,
    margin_left: types.Margin,
    margin_right: types.Margin,

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
    padding_top: types.Padding,
    padding_bottom: types.Padding,
    border_top: types.BorderWidth,
    border_bottom: types.BorderWidth,
    margin_top: types.Margin,
    margin_bottom: types.Margin,

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
    z_index: types.ZIndex,

    pub const initial_values = ZIndex{
        .z_index = .auto,
    };
};

/// left   -> left
/// right  -> right
/// top    -> top
/// bottom -> bottom
pub const Insets = struct {
    left: types.Inset,
    right: types.Inset,
    top: types.Inset,
    bottom: types.Inset,

    pub const initial_values = Insets{
        .left = .auto,
        .right = .auto,
        .top = .auto,
        .bottom = .auto,
    };
};

/// color -> color
pub const Color = struct {
    color: types.Color,

    pub const initial_values = Color{
        // TODO: According to CSS Color Level 4, the initial value is 'CanvasText'.
        .color = types.Color.black,
    };
};

/// left   -> border-left-color
/// right  -> border-right-color
/// top    -> border-top-color
/// bottom -> border-bottom-color
pub const BorderColors = struct {
    left: types.Color,
    right: types.Color,
    top: types.Color,
    bottom: types.Color,

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
    left: types.BorderStyle,
    right: types.BorderStyle,
    top: types.BorderStyle,
    bottom: types.BorderStyle,

    pub const initial_values = BorderStyles{
        .left = .none,
        .right = .none,
        .top = .none,
        .bottom = .none,
    };
};

/// color -> background-color
pub const BackgroundColor = struct {
    color: types.Color,

    pub const initial_values = BackgroundColor{
        .color = types.Color.transparent,
    };
};

/// clip  -> background-clip
pub const BackgroundClip = struct {
    clip: types.BackgroundClip,

    pub const initial_values = BackgroundClip{
        .clip = .border_box,
    };
};

/// image    -> background-image
/// repeat   -> background-repeat
/// position -> background-position
/// origin   -> background-origin
/// size     -> background-size
pub const Background = struct {
    image: types.BackgroundImage,
    repeat: types.BackgroundRepeat,
    attachment: types.BackgroundAttachment,
    position: types.BackgroundPosition,
    origin: types.BackgroundOrigin,
    size: types.BackgroundSize,

    pub const initial_values = Background{
        .image = .none,
        .repeat = .{ .x = .repeat, .y = .repeat },
        .attachment = .scroll,
        .position = .{
            .x = .{ .side = .start, .offset = .{ .percentage = 0 } },
            .y = .{ .side = .start, .offset = .{ .percentage = 0 } },
        },
        .origin = .padding_box,
        .size = .{ .size = .{ .width = .auto, .height = .auto } },
    };
};
