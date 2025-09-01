//! Parsers for every supported CSS property in zss.
//! Each one is named exactly the same as the actual CSS property.
//!
//! Be aware that these parsers WILL NOT parse the CSS-wide keywords.
//! There is also no parser for the 'all' property.
//! These cases are instead handled by `zss.values.parse.cssWideKeyword`.

const std = @import("std");
const Fba = std.heap.FixedBufferAllocator;

const zss = @import("../zss.zig");
const max_list_len = zss.Declarations.max_list_len;
const ReturnType = zss.property.Property.ParseFnReturnType;
const TokenSource = zss.syntax.TokenSource;

const values = zss.values;
const types = values.types;
const Context = values.parse.Context;

fn ParseFnValueType(comptime function: anytype) type {
    const return_type = @typeInfo(@TypeOf(function)).@"fn".return_type.?;
    const no_error = switch (@typeInfo(return_type)) {
        .error_union => |eu| eu.payload,
        else => return_type,
    };
    const no_optional = switch (@typeInfo(no_error)) {
        .optional => |o| o.child,
        else => no_error,
    };
    return no_optional;
}

fn parseList(ctx: *Context, fba: *Fba, parse_fn: anytype) !?[]const ParseFnValueType(parse_fn) {
    const save_point = ctx.enterTopLevelList() orelse return null;

    const Value = ParseFnValueType(parse_fn);
    const list = try fba.allocator().create(std.BoundedArray(Value, max_list_len));
    list.* = .{};

    while (ctx.nextListItem()) |_| {
        const value_or_error = parse_fn(ctx);
        const value_or_null = switch (@typeInfo(@TypeOf(value_or_error))) {
            .error_union => try value_or_error,
            .optional => value_or_error,
            else => comptime unreachable,
        };
        const value = value_or_null orelse break;

        ctx.endListItem() orelse break;
        list.append(value) catch break;
    } else {
        return list.constSlice();
    }

    ctx.resetState(save_point);
    return null;
}

pub fn display(ctx: *Context) ?ReturnType(.display) {
    const value = values.parse.display(ctx) orelse return null;
    return .{ .box_style = .{ .display = .{ .declared = value } } };
}

pub fn position(ctx: *Context) ?ReturnType(.position) {
    const value = values.parse.position(ctx) orelse return null;
    return .{ .box_style = .{ .position = .{ .declared = value } } };
}

pub fn float(ctx: *Context) ?ReturnType(.float) {
    const value = values.parse.float(ctx) orelse return null;
    return .{ .box_style = .{ .float = .{ .declared = value } } };
}

pub fn @"z-index"(ctx: *Context) ?ReturnType(.@"z-index") {
    const value = values.parse.zIndex(ctx) orelse return null;
    return .{ .z_index = .{ .z_index = .{ .declared = value } } };
}

pub fn width(ctx: *Context) ?ReturnType(.width) {
    const value = values.parse.lengthPercentageAuto(ctx, types.LengthPercentageAuto) orelse return null;
    return .{ .content_width = .{ .width = .{ .declared = value } } };
}

pub fn @"min-width"(ctx: *Context) ?ReturnType(.@"min-width") {
    const value = values.parse.lengthPercentage(ctx, types.LengthPercentage) orelse return null;
    return .{ .content_width = .{ .min_width = .{ .declared = value } } };
}

pub fn @"max-width"(ctx: *Context) ?ReturnType(.@"max-width") {
    const value = values.parse.lengthPercentageNone(ctx, types.MaxSize) orelse return null;
    return .{ .content_width = .{ .max_width = .{ .declared = value } } };
}

pub fn height(ctx: *Context) ?ReturnType(.height) {
    const value = values.parse.lengthPercentageAuto(ctx, types.LengthPercentageAuto) orelse return null;
    return .{ .content_height = .{ .height = .{ .declared = value } } };
}

pub fn @"min-height"(ctx: *Context) ?ReturnType(.@"min-height") {
    const value = values.parse.lengthPercentage(ctx, types.LengthPercentage) orelse return null;
    return .{ .content_height = .{ .min_height = .{ .declared = value } } };
}

pub fn @"max-height"(ctx: *Context) ?ReturnType(.@"max-height") {
    const value = values.parse.lengthPercentageNone(ctx, types.MaxSize) orelse return null;
    return .{ .content_height = .{ .max_height = .{ .declared = value } } };
}

pub fn @"padding-left"(ctx: *Context) ?ReturnType(.@"padding-left") {
    const value = values.parse.lengthPercentage(ctx, types.LengthPercentage) orelse return null;
    return .{ .horizontal_edges = .{ .padding_left = .{ .declared = value } } };
}

pub fn @"padding-right"(ctx: *Context) ?ReturnType(.@"padding-right") {
    const value = values.parse.lengthPercentage(ctx, types.LengthPercentage) orelse return null;
    return .{ .horizontal_edges = .{ .padding_right = .{ .declared = value } } };
}

pub fn @"padding-top"(ctx: *Context) ?ReturnType(.@"padding-top") {
    const value = values.parse.lengthPercentage(ctx, types.LengthPercentage) orelse return null;
    return .{ .vertical_edges = .{ .padding_top = .{ .declared = value } } };
}

pub fn @"padding-bottom"(ctx: *Context) ?ReturnType(.@"padding-bottom") {
    const value = values.parse.lengthPercentage(ctx, types.LengthPercentage) orelse return null;
    return .{ .vertical_edges = .{ .padding_bottom = .{ .declared = value } } };
}

pub fn padding(ctx: *Context) ?ReturnType(.padding) {
    var sizes: [4]values.groups.SingleValue(types.LengthPercentage) = undefined;
    var num: u3 = 0;
    for (0..4) |i| {
        const size = values.parse.lengthPercentage(ctx, types.LengthPercentage) orelse break;
        sizes[i] = .{ .declared = size };
        num += 1;
    }
    switch (num) {
        0 => return null,
        1 => return .{
            .horizontal_edges = .{ .padding_left = sizes[0], .padding_right = sizes[0] },
            .vertical_edges = .{ .padding_top = sizes[0], .padding_bottom = sizes[0] },
        },
        2 => return .{
            .horizontal_edges = .{ .padding_left = sizes[1], .padding_right = sizes[1] },
            .vertical_edges = .{ .padding_top = sizes[0], .padding_bottom = sizes[0] },
        },
        3 => return .{
            .horizontal_edges = .{ .padding_left = sizes[1], .padding_right = sizes[1] },
            .vertical_edges = .{ .padding_top = sizes[0], .padding_bottom = sizes[2] },
        },
        4 => return .{
            .horizontal_edges = .{ .padding_left = sizes[3], .padding_right = sizes[1] },
            .vertical_edges = .{ .padding_top = sizes[0], .padding_bottom = sizes[2] },
        },
        else => unreachable,
    }
}

pub fn @"border-left-width"(ctx: *Context) ?ReturnType(.@"border-left-width") {
    const value = values.parse.borderWidth(ctx) orelse return null;
    return .{ .horizontal_edges = .{ .border_left = .{ .declared = value } } };
}

pub fn @"border-right-width"(ctx: *Context) ?ReturnType(.@"border-right-width") {
    const value = values.parse.borderWidth(ctx) orelse return null;
    return .{ .horizontal_edges = .{ .border_right = .{ .declared = value } } };
}

pub fn @"border-top-width"(ctx: *Context) ?ReturnType(.@"border-top-width") {
    const value = values.parse.borderWidth(ctx) orelse return null;
    return .{ .vertical_edges = .{ .border_top = .{ .declared = value } } };
}

pub fn @"border-bottom-width"(ctx: *Context) ?ReturnType(.@"border-bottom-width") {
    const value = values.parse.borderWidth(ctx) orelse return null;
    return .{ .vertical_edges = .{ .border_bottom = .{ .declared = value } } };
}

pub fn @"border-width"(ctx: *Context) ?ReturnType(.@"border-width") {
    var widths: [4]types.BorderWidth = undefined;
    var num: u3 = 0;
    for (0..4) |i| {
        widths[i] = values.parse.borderWidth(ctx) orelse break;
        num += 1;
    }
    switch (num) {
        0 => return null,
        1 => return .{
            .horizontal_edges = .{ .border_left = .{ .declared = widths[0] }, .border_right = .{ .declared = widths[0] } },
            .vertical_edges = .{ .border_top = .{ .declared = widths[0] }, .border_bottom = .{ .declared = widths[0] } },
        },
        2 => return .{
            .horizontal_edges = .{ .border_left = .{ .declared = widths[1] }, .border_right = .{ .declared = widths[1] } },
            .vertical_edges = .{ .border_top = .{ .declared = widths[0] }, .border_bottom = .{ .declared = widths[0] } },
        },
        3 => return .{
            .horizontal_edges = .{ .border_left = .{ .declared = widths[1] }, .border_right = .{ .declared = widths[1] } },
            .vertical_edges = .{ .border_top = .{ .declared = widths[0] }, .border_bottom = .{ .declared = widths[2] } },
        },
        4 => return .{
            .horizontal_edges = .{ .border_left = .{ .declared = widths[3] }, .border_right = .{ .declared = widths[1] } },
            .vertical_edges = .{ .border_top = .{ .declared = widths[0] }, .border_bottom = .{ .declared = widths[2] } },
        },
        else => unreachable,
    }
}

pub fn @"margin-left"(ctx: *Context) ?ReturnType(.@"margin-left") {
    const value = values.parse.lengthPercentageAuto(ctx, types.LengthPercentageAuto) orelse return null;
    return .{ .horizontal_edges = .{ .margin_left = .{ .declared = value } } };
}

pub fn @"margin-right"(ctx: *Context) ?ReturnType(.@"margin-right") {
    const value = values.parse.lengthPercentageAuto(ctx, types.LengthPercentageAuto) orelse return null;
    return .{ .horizontal_edges = .{ .margin_right = .{ .declared = value } } };
}

pub fn @"margin-top"(ctx: *Context) ?ReturnType(.@"margin-top") {
    const value = values.parse.lengthPercentageAuto(ctx, types.LengthPercentageAuto) orelse return null;
    return .{ .vertical_edges = .{ .margin_top = .{ .declared = value } } };
}

pub fn @"margin-bottom"(ctx: *Context) ?ReturnType(.@"margin-bottom") {
    const value = values.parse.lengthPercentageAuto(ctx, types.LengthPercentageAuto) orelse return null;
    return .{ .vertical_edges = .{ .margin_bottom = .{ .declared = value } } };
}

pub fn left(ctx: *Context) ?ReturnType(.left) {
    const value = values.parse.lengthPercentageAuto(ctx, types.LengthPercentageAuto) orelse return null;
    return .{ .insets = .{ .left = .{ .declared = value } } };
}

pub fn right(ctx: *Context) ?ReturnType(.right) {
    const value = values.parse.lengthPercentageAuto(ctx, types.LengthPercentageAuto) orelse return null;
    return .{ .insets = .{ .right = .{ .declared = value } } };
}

pub fn top(ctx: *Context) ?ReturnType(.top) {
    const value = values.parse.lengthPercentageAuto(ctx, types.LengthPercentageAuto) orelse return null;
    return .{ .insets = .{ .top = .{ .declared = value } } };
}

pub fn bottom(ctx: *Context) ?ReturnType(.bottom) {
    const value = values.parse.lengthPercentageAuto(ctx, types.LengthPercentageAuto) orelse return null;
    return .{ .insets = .{ .bottom = .{ .declared = value } } };
}

pub fn @"border-left-color"(ctx: *Context) ?ReturnType(.@"border-left-color") {
    const value = values.parse.color(ctx) orelse return null;
    return .{ .border_colors = .{ .left = .{ .declared = value } } };
}

pub fn @"border-right-color"(ctx: *Context) ?ReturnType(.@"border-right-color") {
    const value = values.parse.color(ctx) orelse return null;
    return .{ .border_colors = .{ .right = .{ .declared = value } } };
}

pub fn @"border-top-color"(ctx: *Context) ?ReturnType(.@"border-top-color") {
    const value = values.parse.color(ctx) orelse return null;
    return .{ .border_colors = .{ .top = .{ .declared = value } } };
}

pub fn @"border-bottom-color"(ctx: *Context) ?ReturnType(.@"border-bottom-color") {
    const value = values.parse.color(ctx) orelse return null;
    return .{ .border_colors = .{ .bottom = .{ .declared = value } } };
}

pub fn @"border-left-style"(ctx: *Context) ?ReturnType(.@"border-left-style") {
    const value = values.parse.borderStyle(ctx) orelse return null;
    return .{ .border_styles = .{ .left = .{ .declared = value } } };
}

pub fn @"border-right-style"(ctx: *Context) ?ReturnType(.@"border-right-style") {
    const value = values.parse.borderStyle(ctx) orelse return null;
    return .{ .border_styles = .{ .right = .{ .declared = value } } };
}

pub fn @"border-top-style"(ctx: *Context) ?ReturnType(.@"border-top-style") {
    const value = values.parse.borderStyle(ctx) orelse return null;
    return .{ .border_styles = .{ .top = .{ .declared = value } } };
}

pub fn @"border-bottom-style"(ctx: *Context) ?ReturnType(.@"border-bottom-style") {
    const value = values.parse.borderStyle(ctx) orelse return null;
    return .{ .border_styles = .{ .bottom = .{ .declared = value } } };
}

pub fn @"border-style"(ctx: *Context) ?ReturnType(.@"border-style") {
    var styles: [4]types.BorderStyle = undefined;
    var num: u3 = 0;
    for (0..4) |i| {
        styles[i] = values.parse.borderStyle(ctx) orelse break;
        num += 1;
    }
    switch (num) {
        0 => return null,
        1 => return .{
            .border_styles = .{ .left = .{ .declared = styles[0] }, .right = .{ .declared = styles[0] }, .top = .{ .declared = styles[0] }, .bottom = .{ .declared = styles[0] } },
        },
        2 => return .{
            .border_styles = .{ .left = .{ .declared = styles[1] }, .right = .{ .declared = styles[1] }, .top = .{ .declared = styles[0] }, .bottom = .{ .declared = styles[0] } },
        },
        3 => return .{
            .border_styles = .{ .left = .{ .declared = styles[1] }, .right = .{ .declared = styles[1] }, .top = .{ .declared = styles[0] }, .bottom = .{ .declared = styles[2] } },
        },
        4 => return .{
            .border_styles = .{ .left = .{ .declared = styles[3] }, .right = .{ .declared = styles[1] }, .top = .{ .declared = styles[0] }, .bottom = .{ .declared = styles[2] } },
        },
        else => unreachable,
    }
}

pub fn color(ctx: *Context) ?ReturnType(.color) {
    const value = values.parse.color(ctx) orelse return null;
    return .{ .color = .{ .color = .{ .declared = value } } };
}

pub fn @"background-color"(ctx: *Context) ?ReturnType(.@"background-color") {
    const value = values.parse.color(ctx) orelse return null;
    return .{ .background_color = .{ .color = .{ .declared = value } } };
}

pub fn @"background-image"(ctx: *Context, fba: *Fba, urls: zss.values.parse.Urls.Managed) !?ReturnType(.@"background-image") {
    const save_point = ctx.enterTopLevelList() orelse return null;
    const url_save_point = urls.save();

    const list = try fba.allocator().create([max_list_len]types.BackgroundImage);
    var list_len: usize = 0;

    while (ctx.nextListItem()) |_| {
        const value = (try values.parse.background.image(ctx, urls)) orelse break;
        ctx.endListItem() orelse break;
        if (list_len == max_list_len) break;
        list[list_len] = value;
        list_len += 1;
    } else {
        return .{ .background = .{ .image = .{ .declared = list[0..list_len] } } };
    }

    ctx.resetState(save_point);
    urls.reset(url_save_point);
    return null;
}

pub fn @"background-repeat"(ctx: *Context, fba: *Fba) !?ReturnType(.@"background-repeat") {
    const list = (try parseList(ctx, fba, values.parse.background.repeat)) orelse return null;
    return .{ .background = .{ .repeat = .{ .declared = list } } };
}

pub fn @"background-attachment"(ctx: *Context, fba: *Fba) !?ReturnType(.@"background-attachment") {
    const list = (try parseList(ctx, fba, values.parse.background.attachment)) orelse return null;
    return .{ .background = .{ .attachment = .{ .declared = list } } };
}

pub fn @"background-position"(ctx: *Context, fba: *Fba) !?ReturnType(.@"background-position") {
    const list = (try parseList(ctx, fba, values.parse.background.position)) orelse return null;
    return .{ .background = .{ .position = .{ .declared = list } } };
}

pub fn @"background-clip"(ctx: *Context, fba: *Fba) !?ReturnType(.@"background-clip") {
    const list = (try parseList(ctx, fba, values.parse.background.clip)) orelse return null;
    return .{ .background_clip = .{ .clip = .{ .declared = list } } };
}

pub fn @"background-origin"(ctx: *Context, fba: *Fba) !?ReturnType(.@"background-origin") {
    const list = (try parseList(ctx, fba, values.parse.background.origin)) orelse return null;
    return .{ .background = .{ .origin = .{ .declared = list } } };
}

pub fn @"background-size"(ctx: *Context, fba: *Fba) !?ReturnType(.@"background-size") {
    const list = (try parseList(ctx, fba, values.parse.background.size)) orelse return null;
    return .{ .background = .{ .size = .{ .declared = list } } };
}
