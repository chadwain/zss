const std = @import("std");

const zss = @import("../../zss.zig");
const TokenSource = zss.syntax.TokenSource;

const values = zss.values;
const types = values.types;
const Source = values.Source;

// Spec: CSS Backgrounds and Borders Level 3
// Syntax: <image> | none
//         <image> = <url> | <gradient>
//         <gradient> = <linear-gradient()> | <repeating-linear-gradient()> | <radial-gradient()> | <repeating-radial-gradient()>
pub fn @"background-image"(source: *Source) ?types.BackgroundImage {
    // TODO: parse gradient functions
    if (values.parse.keyword(source, types.BackgroundImage, &.{.{ "none", .none }})) |value| {
        return value;
    } else if (values.parse.url(source)) |value| {
        return .{ .url = value };
    } else {
        return null;
    }
}

// Spec: CSS Backgrounds and Borders Level 3
// Syntax: <repeat-style> = repeat-x | repeat-y | [repeat | space | round | no-repeat]{1,2}
pub fn @"background-repeat"(source: *Source) ?types.BackgroundRepeat {
    if (values.parse.keyword(source, types.BackgroundRepeat.Repeat, &.{
        .{ "repeat-x", .{ .x = .repeat, .y = .no_repeat } },
        .{ "repeat-y", .{ .x = .no_repeat, .y = .repeat } },
    })) |value| {
        return .{ .repeat = value };
    }

    const Style = types.BackgroundRepeat.Style;
    const map = comptime &[_]TokenSource.KV(Style){
        .{ "repeat", .repeat },
        .{ "space", .space },
        .{ "round", .round },
        .{ "no-repeat", .no_repeat },
    };
    if (values.parse.keyword(source, Style, map)) |x| {
        const y = values.parse.keyword(source, Style, map) orelse x;
        return .{ .repeat = .{ .x = x, .y = y } };
    }

    return null;
}

// Spec: CSS Backgrounds and Borders Level 3
// Syntax: <attachment> = scroll | fixed | local
pub fn @"background-attachment"(source: *Source) ?types.BackgroundAttachment {
    return values.parse.keyword(source, types.BackgroundAttachment, &.{
        .{ "scroll", .scroll },
        .{ "fixed", .fixed },
        .{ "local", .local },
    });
}

const bg_position = struct {
    const Side = types.BackgroundPosition.Side;
    const Offset = types.BackgroundPosition.Offset;
    const Axis = enum { x, y, either };

    const KeywordMapValue = struct { axis: Axis, side: Side };
    // zig fmt: off
    const keyword_map = &[_]TokenSource.KV(KeywordMapValue){
        .{ "center", .{ .axis = .either, .side = .center } },
        .{ "left",   .{ .axis = .x,      .side = .start  } },
        .{ "right",  .{ .axis = .x,      .side = .end    } },
        .{ "top",    .{ .axis = .y,      .side = .start  } },
        .{ "bottom", .{ .axis = .y,      .side = .end    } },
    };
    // zig fmt: on

    const Info = struct {
        axis: Axis,
        side: Side,
        offset: Offset,
    };

    const ResultTuple = struct {
        bg_position: types.BackgroundPosition,
        num_items_used: u3,
    };
};

/// Spec: CSS Backgrounds and Borders Level 3
/// Syntax: <bg-position> = [ left | center | right | top | bottom | <length-percentage> ]
///                       |
///                         [ left | center | right | <length-percentage> ]
///                         [ top | center | bottom | <length-percentage> ]
///                       |
///                         [ center | [ left | right ] <length-percentage>? ] &&
///                         [ center | [ top | bottom ] <length-percentage>? ]
pub fn @"background-position"(source: *Source) ?types.BackgroundPosition {
    const reset_point = source.sequence.start;
    return backgroundPosition3Or4Values(source) orelse blk: {
        source.sequence.reset(reset_point);
        break :blk backgroundPosition1Or2Values(source);
    };
}

/// Spec: CSS Backgrounds and Borders Level 3
/// Syntax: [ center | [ left | right ] <length-percentage>? ] &&
///         [ center | [ top | bottom ] <length-percentage>? ]
fn backgroundPosition3Or4Values(source: *Source) ?types.BackgroundPosition {
    const first, const num_values1 = backgroundPosition3Or4ValuesInfo(source) orelse return null;
    const second, const num_values2 = backgroundPosition3Or4ValuesInfo(source) orelse return null;
    if (num_values1 + num_values2 < 3) return null;

    var x_axis: *const bg_position.Info = undefined;
    var y_axis: *const bg_position.Info = undefined;

    switch (first.axis) {
        .x => {
            x_axis = &first;
            y_axis = switch (second.axis) {
                .x => return null,
                .y => &second,
                .either => &second,
            };
        },
        .y => {
            x_axis = switch (second.axis) {
                .x => &second,
                .y => return null,
                .either => &second,
            };
            y_axis = &first;
        },
        .either => switch (second.axis) {
            .x => {
                x_axis = &second;
                y_axis = &first;
            },
            .y, .either => {
                x_axis = &first;
                y_axis = &second;
            },
        },
    }

    return .{
        .position = .{
            .x = .{
                .side = x_axis.side,
                .offset = x_axis.offset,
            },
            .y = .{
                .side = y_axis.side,
                .offset = y_axis.offset,
            },
        },
    };
}

fn backgroundPosition3Or4ValuesInfo(source: *Source) ?struct { bg_position.Info, u3 } {
    const map_value = values.parse.keyword(source, bg_position.KeywordMapValue, bg_position.keyword_map) orelse return null;

    const offset: bg_position.Offset, const num_values: u3 = blk: {
        if (map_value.side != .center) {
            if (values.parse.lengthPercentage(source, bg_position.Offset)) |value| {
                break :blk .{ value, 2 };
            }
        }
        break :blk .{ .{ .percentage = 0 }, 1 };
    };

    return .{ .{ .axis = map_value.axis, .side = map_value.side, .offset = offset }, num_values };
}

/// Spec: CSS Backgrounds and Borders Level 3
/// Syntax: [ left | center | right | top | bottom | <length-percentage> ]
///       |
///         [ left | center | right | <length-percentage> ]
///         [ top | center | bottom | <length-percentage> ]
fn backgroundPosition1Or2Values(source: *Source) ?types.BackgroundPosition {
    const first = backgroundPosition1Or2ValuesInfo(source) orelse return null;
    twoValues: {
        if (first.axis == .y) break :twoValues;
        const reset_point = source.sequence.start;
        const second = backgroundPosition1Or2ValuesInfo(source) orelse break :twoValues;
        if (second.axis == .x) {
            source.sequence.reset(reset_point);
            break :twoValues;
        }

        return .{
            .position = .{
                .x = .{
                    .side = first.side,
                    .offset = first.offset,
                },
                .y = .{
                    .side = second.side,
                    .offset = second.offset,
                },
            },
        };
    }

    var result = types.BackgroundPosition{
        .position = .{
            .x = .{
                .side = first.side,
                .offset = first.offset,
            },
            .y = .{
                .side = .center,
                .offset = .{ .percentage = 0 },
            },
        },
    };
    if (first.axis == .y) {
        std.mem.swap(types.BackgroundPosition.SideOffset, &result.position.x, &result.position.y);
    }
    return result;
}

fn backgroundPosition1Or2ValuesInfo(source: *Source) ?bg_position.Info {
    if (values.parse.keyword(source, bg_position.KeywordMapValue, bg_position.keyword_map)) |map_value| {
        return .{ .axis = map_value.axis, .side = map_value.side, .offset = .{ .percentage = 0 } };
    } else if (values.parse.lengthPercentage(source, bg_position.Offset)) |offset| {
        return .{ .axis = .either, .side = .start, .offset = offset };
    } else {
        return null;
    }
}

/// Spec: CSS Backgrounds and Borders Level 3
/// Syntax: <box> = border-box | padding-box | content-box
pub fn @"background-clip"(source: *Source) ?types.BackgroundClip {
    return values.parse.keyword(source, types.BackgroundClip, &.{
        .{ "border-box", .border_box },
        .{ "padding-box", .padding_box },
        .{ "content-box", .content_box },
    });
}

/// Spec: CSS Backgrounds and Borders Level 3
/// Syntax: <box> = border-box | padding-box | content-box
pub fn @"background-origin"(source: *Source) ?types.BackgroundOrigin {
    return values.parse.keyword(source, types.BackgroundOrigin, &.{
        .{ "border-box", .border_box },
        .{ "padding-box", .padding_box },
        .{ "content-box", .content_box },
    });
}

/// Spec: CSS Backgrounds and Borders Level 3
/// Syntax: <bg-size> = [ <length-percentage [0,infinity]> | auto ]{1,2} | cover | contain
pub fn @"background-size"(source: *Source) ?types.BackgroundSize {
    if (values.parse.keyword(source, types.BackgroundSize, &.{
        .{ "cover", .cover },
        .{ "contain", .contain },
    })) |value| return value;

    const reset_point = source.sequence.start;
    // TODO: Range checking?
    if (values.parse.lengthPercentageAuto(source, types.BackgroundSize.SizeType)) |width| {
        const height = values.parse.lengthPercentageAuto(source, types.BackgroundSize.SizeType) orelse width;
        return types.BackgroundSize{ .size = .{ .width = width, .height = height } };
    }

    source.sequence.reset(reset_point);
    return null;
}
