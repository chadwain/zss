const std = @import("std");

const zss = @import("../zss.zig");
const aggregates = zss.properties.aggregates;
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
    if (value < 0) return error.InvalidValue;
    return length(unit, value);
}

pub fn percentage(value: f32, unit: ZssUnit) ZssUnit {
    return @as(ZssUnit, @intFromFloat(@round(@as(f32, @floatFromInt(unit)) * value)));
}

pub fn positivePercentage(value: f32, unit: ZssUnit) !ZssUnit {
    if (value < 0) return error.InvalidValue;
    return percentage(value, unit);
}

pub fn clampSize(size: ZssUnit, min_size: ZssUnit, max_size: ZssUnit) ZssUnit {
    return @max(min_size, @min(size, max_size));
}

pub const BorderThickness = enum { thin, medium, thick };

pub fn borderWidth(comptime thickness: BorderThickness) f32 {
    return switch (thickness) {
        // TODO: Let these values be user-customizable.
        .thin => 1,
        .medium => 3,
        .thick => 5,
    };
}

pub fn borderWidthMultiplier(border_style: zss.values.types.BorderStyle) f32 {
    return switch (border_style) {
        .none, .hidden => 0,
        .initial, .inherit, .unset, .undeclared => unreachable,
        else => 1,
    };
}

pub fn color(col: zss.values.types.Color, current_color: used_values.Color) used_values.Color {
    return switch (col) {
        .rgba => |rgba| used_values.Color.fromRgbaInt(rgba),
        .current_color => current_color,
        .initial, .inherit, .unset, .undeclared => unreachable,
    };
}

pub fn currentColor(col: zss.values.types.Color) used_values.Color {
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
        // TODO: There should be a slightly different version of this function for the root element. (See rule 4 of secion 9.7)
        computed.display = @"CSS2.2Section9.7Table"(specified.display);
    } else {
        computed.display = specified.display;
    }
    return computed;
}

/// Given a specified value for 'display', returns the computed value according to the table found in section 9.7 of CSS2.2.
fn @"CSS2.2Section9.7Table"(display: zss.values.types.Display) zss.values.types.Display {
    // TODO: This is incomplete, fill in the rest when more values of the 'display' property are supported.
    // TODO: There should be a slightly different version of this switch table for the root element. (See rule 4 of secion 9.7)
    return switch (display) {
        .inline_, .inline_block, .text => .block,
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
        fn f(border_style: zss.values.types.BorderStyle) void {
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

pub fn background1(bg: aggregates.Background1, current_color: used_values.Color) used_values.Background1 {
    return used_values.Background1{
        .color = color(bg.color, current_color),
        .clip = switch (bg.clip) {
            .border_box => .Border,
            .padding_box => .Padding,
            .content_box => .Content,
            .initial, .inherit, .unset, .undeclared => unreachable,
        },
    };
}

pub fn background2(
    bg: aggregates.Background2,
    box_offsets: *const used_values.BoxOffsets,
    borders: *const used_values.Borders,
) !used_values.Background2 {
    var object = switch (bg.image) {
        .object => |object| object,
        .url => std.debug.panic("TODO: background-image: <url-token>", .{}),
        .none => return used_values.Background2{},
        .initial, .inherit, .unset, .undeclared => unreachable,
    };

    const border_width = box_offsets.border_size.w;
    const border_height = box_offsets.border_size.h;
    const padding_width = border_width - borders.left - borders.right;
    const padding_height = border_height - borders.top - borders.bottom;
    const content_width = box_offsets.content_size.w;
    const content_height = box_offsets.content_size.h;
    const positioning_area: struct { origin: used_values.Background2.Origin, width: ZssUnit, height: ZssUnit } = switch (bg.origin) {
        .border_box => .{ .origin = .Border, .width = border_width, .height = border_height },
        .padding_box => .{ .origin = .Padding, .width = padding_width, .height = padding_height },
        .content_box => .{ .origin = .Content, .width = content_width, .height = content_height },
        .initial, .inherit, .unset, .undeclared => unreachable,
    };

    const NaturalSize = struct {
        width: ZssUnit,
        height: ZssUnit,
        has_aspect_ratio: bool,

        fn init(obj: *zss.values.types.BackgroundImage.Object) !@This() {
            const n = obj.getNaturalSize();
            const width = try positiveLength(.px, n.width);
            const height = try positiveLength(.px, n.height);
            return @This(){
                .width = width,
                .height = height,
                .has_aspect_ratio = width != 0 and height != 0,
            };
        }
    };
    // Initialize on first use.
    var natural: ?NaturalSize = null;

    var width_was_auto = false;
    var height_was_auto = false;
    var size: used_values.Background2.Size = switch (bg.size) {
        .size => |size| .{
            .width = switch (size.width) {
                .px => |val| try positiveLength(.px, val),
                .percentage => |p| try positivePercentage(p, positioning_area.width),
                .auto => blk: {
                    width_was_auto = true;
                    break :blk 0;
                },
            },
            .height = switch (size.height) {
                .px => |val| try positiveLength(.px, val),
                .percentage => |p| try positivePercentage(p, positioning_area.height),
                .auto => blk: {
                    height_was_auto = true;
                    break :blk 0;
                },
            },
        },
        .contain, .cover => blk: {
            if (natural == null) natural = try NaturalSize.init(&object);
            if (!natural.?.has_aspect_ratio) break :blk used_values.Background2.Size{ .width = natural.?.width, .height = natural.?.height };

            const positioning_area_is_wider_than_image = positioning_area.width * natural.?.height > positioning_area.height * natural.?.width;
            const is_contain = (bg.size == .contain);

            if (positioning_area_is_wider_than_image == is_contain) {
                break :blk used_values.Background2.Size{
                    .width = @divFloor(positioning_area.height * natural.?.width, natural.?.height),
                    .height = positioning_area.height,
                };
            } else {
                break :blk used_values.Background2.Size{
                    .width = positioning_area.width,
                    .height = @divFloor(positioning_area.width * natural.?.height, natural.?.width),
                };
            }
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    };

    const repeat: used_values.Background2.Repeat = switch (bg.repeat) {
        .repeat => |repeat| .{
            .x = switch (repeat.x) {
                .no_repeat => .None,
                .repeat => .Repeat,
                .space => .Space,
                .round => .Round,
            },
            .y = switch (repeat.y) {
                .no_repeat => .None,
                .repeat => .Repeat,
                .space => .Space,
                .round => .Round,
            },
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    };

    if (width_was_auto or height_was_auto or repeat.x == .Round or repeat.y == .Round) {
        const divRound = zss.util.divRound;
        if (natural == null) natural = try NaturalSize.init(&object);

        if (width_was_auto and height_was_auto) {
            size.width = natural.?.width;
            size.height = natural.?.height;
        } else if (width_was_auto) {
            size.width = if (natural.?.has_aspect_ratio) divRound(size.height * natural.?.width, natural.?.height) else positioning_area.width;
        } else if (height_was_auto) {
            size.height = if (natural.?.has_aspect_ratio) divRound(size.width * natural.?.height, natural.?.width) else positioning_area.height;
        }

        if (repeat.x == .Round and repeat.y == .Round) {
            size.width = @divFloor(positioning_area.width, @max(1, divRound(positioning_area.width, size.width)));
            size.height = @divFloor(positioning_area.height, @max(1, divRound(positioning_area.height, size.height)));
        } else if (repeat.x == .Round) {
            if (size.width > 0) size.width = @divFloor(positioning_area.width, @max(1, divRound(positioning_area.width, size.width)));
            if (height_was_auto and natural.?.has_aspect_ratio) size.height = @divFloor(size.width * natural.?.height, natural.?.width);
        } else if (repeat.y == .Round) {
            if (size.height > 0) size.height = @divFloor(positioning_area.height, @max(1, divRound(positioning_area.height, size.height)));
            if (width_was_auto and natural.?.has_aspect_ratio) size.width = @divFloor(size.height * natural.?.width, natural.?.height);
        }
    }

    const position: used_values.Background2.Position = switch (bg.position) {
        .position => |position| .{
            .x = blk: {
                const available_space = positioning_area.width - size.width;
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
                const available_space = positioning_area.height - size.height;
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
        .initial, .inherit, .unset, .undeclared => unreachable,
    };

    return used_values.Background2{
        .image = object.data,
        .origin = positioning_area.origin,
        .position = position,
        .size = size,
        .repeat = repeat,
    };
}
