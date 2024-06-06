const std = @import("std");

const zss = @import("../zss.zig");
const aggregates = zss.properties.aggregates;
const types = zss.values.types;
const units_per_pixel = used_values.units_per_pixel;
const used_values = zss.used_values;
const ZssUnit = used_values.ZssUnit;

pub const LengthUnit = enum { px };

pub fn length(comptime unit: LengthUnit, value: f32) ZssUnit {
    return switch (unit) {
        .px => @as(ZssUnit, @intFromFloat(@round(value * units_per_pixel))),
    };
}

pub fn positiveLength(comptime unit: LengthUnit, value: f32) !ZssUnit {
    // TODO: This check isn't good enough. Must check what class of floating point value this belongs to.
    if (value < 0) return error.InvalidValue;
    return length(unit, value);
}

pub fn percentage(value: f32, unit: ZssUnit) ZssUnit {
    return @as(ZssUnit, @intFromFloat(@round(@as(f32, @floatFromInt(unit)) * value)));
}

pub fn positivePercentage(value: f32, unit: ZssUnit) !ZssUnit {
    // TODO: This check isn't good enough. Must check what class of floating point value this belongs to.
    if (value < 0) return error.InvalidValue;
    return percentage(value, unit);
}

pub fn clampSize(size: ZssUnit, min_size: ZssUnit, max_size: ZssUnit) ZssUnit {
    return @max(min_size, @min(size, max_size));
}

pub fn borderWidth(comptime thickness: std.meta.Tag(types.BorderWidth)) f32 {
    return switch (thickness) {
        // TODO: Let these values be user-customizable.
        .thin => 1,
        .medium => 3,
        .thick => 5,
        else => @compileError("invalid value"),
    };
}

pub fn borderWidthMultiplier(border_style: types.BorderStyle) f32 {
    return switch (border_style) {
        .none, .hidden => 0,
        .initial, .inherit, .unset, .undeclared => unreachable,
        else => 1,
    };
}

pub fn color(col: types.Color, current_color: used_values.Color) used_values.Color {
    return switch (col) {
        .rgba => |rgba| used_values.Color.fromRgbaInt(rgba),
        .current_color => current_color,
        .initial, .inherit, .unset, .undeclared => unreachable,
    };
}

pub fn currentColor(col: types.Color) used_values.Color {
    return switch (col) {
        .rgba => |rgba| used_values.Color.fromRgbaInt(rgba),
        .current_color => unreachable,
        .initial, .inherit, .unset, .undeclared => unreachable,
    };
}

pub const IsRoot = enum {
    Root,
    NonRoot,
};

pub fn boxStyle(specified: aggregates.BoxStyle, comptime is_root: IsRoot) aggregates.BoxStyle {
    var computed: aggregates.BoxStyle = .{
        .display = undefined,
        .position = specified.position,
        .float = specified.float,
    };
    if (specified.display == .none) {
        computed.display = .none;
    } else if (specified.position == .absolute or specified.position == .fixed) {
        computed.display = @"CSS2.2Section9.7Table"(specified.display);
        computed.float = .none;
    } else if (specified.float != .none) {
        computed.display = @"CSS2.2Section9.7Table"(specified.display);
    } else if (is_root == .Root) {
        // TODO: There should be a slightly different version of this function for the root element. (See rule 4 of section 9.7)
        computed.display = @"CSS2.2Section9.7Table"(specified.display);
    } else {
        computed.display = specified.display;
    }
    return computed;
}

/// Given a specified value for 'display', returns the computed value according to the table found in section 9.7 of CSS2.2.
fn @"CSS2.2Section9.7Table"(display: types.Display) types.Display {
    // TODO: This is incomplete, fill in the rest when more values of the 'display' property are supported.
    // TODO: There should be a slightly different version of this switch table for the root element. (See rule 4 of secion 9.7)
    return switch (display) {
        .@"inline", .inline_block, .text => .block,
        .initial, .inherit, .unset, .undeclared => unreachable,
        else => display,
    };
}

pub fn borderColors(border_colors: aggregates.BorderColors, current_color: used_values.Color) used_values.BorderColor {
    return used_values.BorderColor{
        .left = color(border_colors.left, current_color),
        .right = color(border_colors.right, current_color),
        .top = color(border_colors.top, current_color),
        .bottom = color(border_colors.bottom, current_color),
    };
}

pub fn borderStyles(border_styles: aggregates.BorderStyles) void {
    const solveOne = struct {
        fn f(border_style: types.BorderStyle) void {
            switch (border_style) {
                .none, .hidden, .solid => {},
                .initial, .inherit, .unset, .undeclared => unreachable,
                else => std.debug.panic("TODO: border-style: {s}", .{@tagName(border_style)}),
            }
        }
    }.f;

    inline for (std.meta.fields(aggregates.BorderStyles)) |field_info| {
        solveOne(@field(border_styles, field_info.name));
    }
}

pub fn backgroundClip(clip: types.BackgroundClip) used_values.BackgroundClip {
    return switch (clip) {
        .border_box => .border,
        .padding_box => .padding,
        .content_box => .content,
        .many => unreachable,
        .initial, .inherit, .unset, .undeclared => unreachable,
    };
}

pub fn inlineBoxBackground(col: types.Color, clip: types.BackgroundClip, current_color: used_values.Color) used_values.InlineBoxBackground {
    return .{
        .color = color(col, current_color),
        .clip = backgroundClip(clip),
    };
}

pub fn backgroundImage(
    handle: zss.Images.Handle,
    dimensions: zss.Images.Dimensions,
    specified: struct {
        origin: types.BackgroundOrigin,
        position: types.BackgroundPosition,
        size: types.BackgroundSize,
        repeat: types.BackgroundRepeat,
        clip: types.BackgroundClip,
    },
    box_offsets: *const used_values.BoxOffsets,
    borders: *const used_values.Borders,
) !used_values.BackgroundImage {
    // TODO: Handle background-attachment

    const NaturalSize = struct {
        width: ZssUnit,
        height: ZssUnit,
        has_aspect_ratio: bool,
    };

    const natural_size: NaturalSize = blk: {
        const width = try positiveLength(.px, @floatFromInt(dimensions.width_px));
        const height = try positiveLength(.px, @floatFromInt(dimensions.height_px));
        break :blk .{
            .width = width,
            .height = height,
            .has_aspect_ratio = width != 0 and height != 0,
        };
    };

    const border_width = box_offsets.border_size.w;
    const border_height = box_offsets.border_size.h;
    const padding_width = border_width - borders.left - borders.right;
    const padding_height = border_height - borders.top - borders.bottom;
    const content_width = box_offsets.content_size.w;
    const content_height = box_offsets.content_size.h;
    const positioning_area: struct { origin: used_values.BackgroundImage.Origin, width: ZssUnit, height: ZssUnit } = switch (specified.origin) {
        .border_box => .{ .origin = .border, .width = border_width, .height = border_height },
        .padding_box => .{ .origin = .padding, .width = padding_width, .height = padding_height },
        .content_box => .{ .origin = .content, .width = content_width, .height = content_height },
        .many => unreachable,
        .initial, .inherit, .unset, .undeclared => unreachable,
    };

    var width_was_auto = false;
    var height_was_auto = false;
    var size: used_values.BackgroundImage.Size = switch (specified.size) {
        .size => |size| .{
            .w = switch (size.width) {
                .px => |val| try positiveLength(.px, val),
                .percentage => |p| try positivePercentage(p, positioning_area.width),
                .auto => blk: {
                    width_was_auto = true;
                    break :blk 0;
                },
            },
            .h = switch (size.height) {
                .px => |val| try positiveLength(.px, val),
                .percentage => |p| try positivePercentage(p, positioning_area.height),
                .auto => blk: {
                    height_was_auto = true;
                    break :blk 0;
                },
            },
        },
        .contain, .cover => blk: {
            if (!natural_size.has_aspect_ratio) break :blk used_values.BackgroundImage.Size{ .w = natural_size.width, .h = natural_size.height };

            const positioning_area_is_wider_than_image = positioning_area.width * natural_size.height > positioning_area.height * natural_size.width;
            const is_contain = (specified.size == .contain);

            if (positioning_area_is_wider_than_image == is_contain) {
                break :blk used_values.BackgroundImage.Size{
                    .w = @divFloor(positioning_area.height * natural_size.width, natural_size.height),
                    .h = positioning_area.height,
                };
            } else {
                break :blk used_values.BackgroundImage.Size{
                    .w = positioning_area.width,
                    .h = @divFloor(positioning_area.width * natural_size.height, natural_size.width),
                };
            }
        },
        .many => unreachable,
        .initial, .inherit, .unset, .undeclared => unreachable,
    };

    const repeat: used_values.BackgroundImage.Repeat = switch (specified.repeat) {
        .repeat => |repeat| .{
            .x = switch (repeat.x) {
                .no_repeat => .none,
                .repeat => .repeat,
                .space => .space,
                .round => .round,
            },
            .y = switch (repeat.y) {
                .no_repeat => .none,
                .repeat => .repeat,
                .space => .space,
                .round => .round,
            },
        },
        .many => unreachable,
        .initial, .inherit, .unset, .undeclared => unreachable,
    };

    // TODO: Needs review
    if (width_was_auto or height_was_auto or repeat.x == .round or repeat.y == .round) {
        const divRound = zss.util.divRound;

        if (width_was_auto and height_was_auto) {
            size.w = natural_size.width;
            size.h = natural_size.height;
        } else if (width_was_auto) {
            size.w = if (natural_size.has_aspect_ratio)
                divRound(size.h * natural_size.width, natural_size.height)
            else
                positioning_area.width;
        } else if (height_was_auto) {
            size.h = if (natural_size.has_aspect_ratio)
                divRound(size.w * natural_size.height, natural_size.width)
            else
                positioning_area.height;
        }

        if (repeat.x == .round and repeat.y == .round) {
            size.w = @divFloor(positioning_area.width, @max(1, divRound(positioning_area.width, size.w)));
            size.h = @divFloor(positioning_area.height, @max(1, divRound(positioning_area.height, size.h)));
        } else if (repeat.x == .round) {
            if (size.w > 0) size.w = @divFloor(positioning_area.width, @max(1, divRound(positioning_area.width, size.w)));
            if (height_was_auto and natural_size.has_aspect_ratio) size.h = @divFloor(size.w * natural_size.height, natural_size.width);
        } else if (repeat.y == .round) {
            if (size.h > 0) size.h = @divFloor(positioning_area.height, @max(1, divRound(positioning_area.height, size.h)));
            if (width_was_auto and natural_size.has_aspect_ratio) size.w = @divFloor(size.h * natural_size.width, natural_size.height);
        }
    }

    const position: used_values.BackgroundImage.Position = switch (specified.position) {
        .position => |position| .{
            .x = blk: {
                const available_space = positioning_area.width - size.w;
                switch (position.x.side) {
                    .start, .end => {
                        switch (position.x.offset) {
                            .px => |val| {
                                const offset = length(.px, val);
                                const offset_adjusted = if (position.x.side == .start) offset else available_space - offset;
                                break :blk offset_adjusted;
                            },
                            .percentage => |p| {
                                const percentage_adjusted = if (position.x.side == .start) p else 1 - p;
                                break :blk percentage(percentage_adjusted, available_space);
                            },
                        }
                    },
                    .center => break :blk percentage(0.5, available_space),
                }
            },
            .y = blk: {
                const available_space = positioning_area.height - size.h;
                switch (position.y.side) {
                    .start, .end => {
                        switch (position.y.offset) {
                            .px => |val| {
                                const offset = length(.px, val);
                                const offset_adjusted = if (position.y.side == .start) offset else available_space - offset;
                                break :blk offset_adjusted;
                            },
                            .percentage => |p| {
                                const percentage_adjusted = if (position.y.side == .start) p else 1 - p;
                                break :blk percentage(percentage_adjusted, available_space);
                            },
                        }
                    },
                    .center => break :blk percentage(0.5, available_space),
                }
            },
        },
        .many => unreachable,
        .initial, .inherit, .unset, .undeclared => unreachable,
    };

    const clip = backgroundClip(specified.clip);

    return used_values.BackgroundImage{
        .handle = handle,
        .origin = positioning_area.origin,
        .position = position,
        .size = size,
        .repeat = repeat,
        .clip = clip,
    };
}
