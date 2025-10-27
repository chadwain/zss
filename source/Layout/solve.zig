const std = @import("std");

const zss = @import("../zss.zig");
const types = zss.values.types;
const BoxTree = zss.BoxTree;

const groups = zss.values.groups;
const ComputedValues = groups.Tag.ComputedValues;
const SpecifiedValues = groups.Tag.SpecifiedValues;

const math = zss.math;
const Unit = math.Unit;
const units_per_pixel = math.units_per_pixel;

pub const LengthUnit = enum { px };

pub fn length(comptime unit: LengthUnit, value: f32) Unit {
    return switch (unit) {
        .px => @as(Unit, @intFromFloat(@round(value * units_per_pixel))),
    };
}

pub fn positiveLength(comptime unit: LengthUnit, value: f32) Unit {
    if (value < 0.0 or !std.math.isNormal(value)) return 0;
    return length(unit, value);
}

pub fn percentage(value: f32, unit: Unit) Unit {
    return @intFromFloat(@round(@as(f32, @floatFromInt(unit)) * value));
}

pub fn positivePercentage(value: f32, unit: Unit) Unit {
    if (value < 0.0 or !std.math.isNormal(value)) return 0;
    return percentage(value, unit);
}

pub fn clampSize(size: Unit, min_size: Unit, max_size: Unit) Unit {
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
        .solid,
        .dotted,
        .dashed,
        .double,
        .groove,
        .ridge,
        .inset,
        .outset,
        => 1,
    };
}

pub fn color(col: types.Color, current_color: math.Color) math.Color {
    return switch (col) {
        .rgba => |rgba| math.Color.fromRgbaInt(rgba),
        .transparent => .transparent,
        .current_color => current_color,
    };
}

/// Use to resolve the value of the 'color' property.
/// To resolve the value of just a normal color value, use `color` instead.
pub fn colorProperty(specified: SpecifiedValues(.color)) struct { ComputedValues(.color), math.Color } {
    const computed = specified;
    const used: math.Color = switch (computed.color) {
        .rgba => |rgba| .fromRgbaInt(rgba),
        .transparent => .transparent,
        .current_color => std.debug.panic("TODO: 'currentColor' on the 'color' property", .{}),
    };
    return .{ computed, used };
}

/// Implements the rules specified in section 9.7 of CSS2.2.
pub fn boxStyle(specified: SpecifiedValues(.box_style), comptime is_root: zss.Layout.IsRoot) struct { ComputedValues(.box_style), BoxTree.BoxStyle } {
    var computed: ComputedValues(.box_style) = .{
        .display = undefined,
        .position = specified.position,
        .float = specified.float,
    };

    if (specified.display == .none) {
        computed.display = .none;
        return .{ computed, .{ .outer = .none, .position = .static } };
    }

    var position: BoxTree.BoxStyle.Position = undefined;
    switch (is_root) {
        .not_root => {
            switch (specified.position) {
                .absolute => {
                    computed.display = blockify(specified.display);
                    computed.float = .none;
                    const used: BoxTree.BoxStyle = .{
                        .outer = .{ .absolute = innerBlockType(computed.display) },
                        .position = .absolute,
                    };
                    return .{ computed, used };
                },
                .fixed => std.debug.panic("TODO: fixed positioning", .{}),
                .static, .relative, .sticky => {},
            }

            if (specified.float != .none) {
                std.debug.panic("TODO: floats", .{});
            }

            computed.display = specified.display;
            position = switch (computed.position) {
                .static => .static,
                .relative => .relative,
                .sticky => std.debug.panic("TODO: sticky positioning", .{}),
                .absolute, .fixed => unreachable,
            };
        },
        .root => {
            computed.display = blockify(specified.display);
            computed.position = .static;
            computed.float = .none;
            position = .static;
        },
    }

    const used: BoxTree.BoxStyle = .{
        .outer = switch (computed.display) {
            .block => .{ .block = .flow },
            .@"inline" => .{ .@"inline" = .@"inline" },
            .inline_block => .{ .@"inline" = .{ .block = .flow } },
            .none => unreachable,
        },
        .position = position,
    };

    return .{ computed, used };
}

/// Given a specified value for 'display', returns the computed value according to the table found in section 9.7 of CSS2.2.
fn blockify(display: types.Display) types.Display {
    // TODO: This is incomplete, fill in the rest when more values of the 'display' property are supported.
    // TODO: There should be a slightly different version of this switch table for the root element. (See rule 4 of secion 9.7)
    return switch (display) {
        .block => .block,
        .@"inline", .inline_block => .block,
        .none => unreachable,
    };
}

fn innerBlockType(computed_display: types.Display) BoxTree.BoxStyle.InnerBlock {
    return switch (computed_display) {
        .block => .flow,
        .@"inline", .inline_block, .none => unreachable,
    };
}

pub fn insets(specified: SpecifiedValues(.insets)) ComputedValues(.insets) {
    var computed: ComputedValues(.insets) = undefined;
    inline for (std.meta.fields(ComputedValues(.insets))) |field_info| {
        @field(computed, field_info.name) = switch (@field(specified, field_info.name)) {
            .px => |value| .{ .px = value },
            .percentage => |value| .{ .percentage = value },
            .auto => .auto,
        };
    }
    return computed;
}

pub fn borderColors(border_colors: SpecifiedValues(.border_colors), current_color: math.Color) BoxTree.BorderColors {
    return .{
        .left = color(border_colors.left, current_color),
        .right = color(border_colors.right, current_color),
        .top = color(border_colors.top, current_color),
        .bottom = color(border_colors.bottom, current_color),
    };
}

pub fn borderStyles(border_styles: SpecifiedValues(.border_styles)) void {
    const ns = struct {
        fn solveOne(border_style: types.BorderStyle) void {
            switch (border_style) {
                .none, .hidden, .solid => {},
                .dotted,
                .dashed,
                .double,
                .groove,
                .ridge,
                .inset,
                .outset,
                => std.debug.panic("TODO: border-style: {s}", .{@tagName(border_style)}),
            }
        }
    };

    inline for (std.meta.fields(groups.BorderStyles)) |field_info| {
        ns.solveOne(@field(border_styles, field_info.name));
    }
}

pub fn backgroundClip(clip: types.BackgroundClip) BoxTree.BackgroundClip {
    return switch (clip) {
        .border_box => .border,
        .padding_box => .padding,
        .content_box => .content,
    };
}

pub fn inlineBoxBackground(col: types.Color, clip: types.BackgroundClip, current_color: math.Color) BoxTree.InlineBoxBackground {
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
        attachment: types.BackgroundAttachment,
        clip: types.BackgroundClip,
    },
    box_offsets: *const BoxTree.BoxOffsets,
    borders: *const BoxTree.Borders,
) BoxTree.BackgroundImage {
    // TODO: Handle background-attachment

    const NaturalSize = struct {
        width: Unit,
        height: Unit,
        has_aspect_ratio: bool,
    };

    const natural_size: NaturalSize = blk: {
        const width = positiveLength(.px, @floatFromInt(dimensions.width_px));
        const height = positiveLength(.px, @floatFromInt(dimensions.height_px));
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
    const positioning_area: struct { origin: BoxTree.BackgroundImage.Origin, width: Unit, height: Unit } = switch (specified.origin) {
        .border_box => .{ .origin = .border, .width = border_width, .height = border_height },
        .padding_box => .{ .origin = .padding, .width = padding_width, .height = padding_height },
        .content_box => .{ .origin = .content, .width = content_width, .height = content_height },
    };

    var width_was_auto = false;
    var height_was_auto = false;
    var size: BoxTree.BackgroundImage.Size = switch (specified.size) {
        .size => |size| .{
            .w = switch (size.width) {
                .px => |val| positiveLength(.px, val),
                .percentage => |p| positivePercentage(p, positioning_area.width),
                .auto => blk: {
                    width_was_auto = true;
                    break :blk 0;
                },
            },
            .h = switch (size.height) {
                .px => |val| positiveLength(.px, val),
                .percentage => |p| positivePercentage(p, positioning_area.height),
                .auto => blk: {
                    height_was_auto = true;
                    break :blk 0;
                },
            },
        },
        .contain, .cover => blk: {
            if (!natural_size.has_aspect_ratio) break :blk BoxTree.BackgroundImage.Size{ .w = natural_size.width, .h = natural_size.height };

            const positioning_area_is_wider_than_image = positioning_area.width * natural_size.height > positioning_area.height * natural_size.width;
            const is_contain = (specified.size == .contain);

            if (positioning_area_is_wider_than_image == is_contain) {
                break :blk BoxTree.BackgroundImage.Size{
                    .w = @divFloor(positioning_area.height * natural_size.width, natural_size.height),
                    .h = positioning_area.height,
                };
            } else {
                break :blk BoxTree.BackgroundImage.Size{
                    .w = positioning_area.width,
                    .h = @divFloor(positioning_area.width * natural_size.height, natural_size.width),
                };
            }
        },
    };

    const repeat: BoxTree.BackgroundImage.Repeat = .{
        .x = switch (specified.repeat.x) {
            .no_repeat => .none,
            .repeat => .repeat,
            .space => .space,
            .round => .round,
        },
        .y = switch (specified.repeat.y) {
            .no_repeat => .none,
            .repeat => .repeat,
            .space => .space,
            .round => .round,
        },
    };

    // TODO: Needs review
    if (width_was_auto or height_was_auto or repeat.x == .round or repeat.y == .round) {
        const divRound = math.divRound;

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

    const position: BoxTree.BackgroundImage.Position = .{
        .x = blk: {
            const available_space = positioning_area.width - size.w;
            switch (specified.position.x.side) {
                .start, .end => {
                    switch (specified.position.x.offset) {
                        .px => |val| {
                            const offset = length(.px, val);
                            const offset_adjusted = if (specified.position.x.side == .start) offset else available_space - offset;
                            break :blk offset_adjusted;
                        },
                        .percentage => |p| {
                            const percentage_adjusted = if (specified.position.x.side == .start) p else 1 - p;
                            break :blk percentage(percentage_adjusted, available_space);
                        },
                    }
                },
                .center => break :blk percentage(0.5, available_space),
            }
        },
        .y = blk: {
            const available_space = positioning_area.height - size.h;
            switch (specified.position.y.side) {
                .start, .end => {
                    switch (specified.position.y.offset) {
                        .px => |val| {
                            const offset = length(.px, val);
                            const offset_adjusted = if (specified.position.y.side == .start) offset else available_space - offset;
                            break :blk offset_adjusted;
                        },
                        .percentage => |p| {
                            const percentage_adjusted = if (specified.position.y.side == .start) p else 1 - p;
                            break :blk percentage(percentage_adjusted, available_space);
                        },
                    }
                },
                .center => break :blk percentage(0.5, available_space),
            }
        },
    };

    const clip = backgroundClip(specified.clip);

    return BoxTree.BackgroundImage{
        .handle = handle,
        .origin = positioning_area.origin,
        .position = position,
        .size = size,
        .repeat = repeat,
        .clip = clip,
    };
}
