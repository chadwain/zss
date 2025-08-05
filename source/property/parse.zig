//! Parsers for every supported CSS property in zss.
//! Each one is named exactly the same as the actual CSS property.
//!
//! Be aware that these parsers WILL NOT parse the CSS-wide keywords.
//! There is also no parser for the 'all' property.
//! These cases are instead handled by `zss.values.parse.cssWideKeyword`.

const std = @import("std");
const Fba = std.heap.FixedBufferAllocator;

const zss = @import("../zss.zig");
const max_list_len = zss.property.Declarations.max_list_len;
const DeclType = zss.property.Property.DeclarationType;
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
    const save_point = ctx.save();

    const Value = ParseFnValueType(parse_fn);
    const list = try fba.allocator().create(std.BoundedArray(Value, max_list_len));
    list.* = .{};

    try ctx.beginList();
    while (ctx.nextListItem()) |_| {
        const value_or_error = parse_fn(ctx);
        const value_or_null = switch (@typeInfo(@TypeOf(value_or_error))) {
            .error_union => try value_or_error,
            .optional => value_or_error,
            else => comptime unreachable,
        };
        const value = value_or_null orelse break;

        ctx.endListItem() catch break;
        list.append(value) catch break;
    } else {
        return list.constSlice();
    }

    ctx.reset(save_point);
    return null;
}

pub fn display(ctx: *Context) ?DeclType(.display) {
    const value = values.parse.display(ctx) orelse return null;
    return .{ .box_style = .{ .display = .{ .declared = value } } };
}

pub fn position(ctx: *Context) ?DeclType(.position) {
    const value = values.parse.position(ctx) orelse return null;
    return .{ .box_style = .{ .position = .{ .declared = value } } };
}

pub fn float(ctx: *Context) ?DeclType(.float) {
    const value = values.parse.float(ctx) orelse return null;
    return .{ .box_style = .{ .float = .{ .declared = value } } };
}

pub fn @"z-index"(ctx: *Context) ?DeclType(.@"z-index") {
    const value = values.parse.zIndex(ctx) orelse return null;
    return .{ .z_index = .{ .z_index = .{ .declared = value } } };
}

pub fn width(ctx: *Context) ?DeclType(.width) {
    const value = values.parse.lengthPercentageAuto(ctx, types.LengthPercentageAuto) orelse return null;
    return .{ .content_width = .{ .width = .{ .declared = value } } };
}

pub fn @"min-width"(ctx: *Context) ?DeclType(.@"min-width") {
    const value = values.parse.lengthPercentage(ctx, types.LengthPercentage) orelse return null;
    return .{ .content_width = .{ .min_width = .{ .declared = value } } };
}

pub fn @"max-width"(ctx: *Context) ?DeclType(.@"max-width") {
    const value = values.parse.lengthPercentageNone(ctx, types.MaxSize) orelse return null;
    return .{ .content_width = .{ .max_width = .{ .declared = value } } };
}

pub fn height(ctx: *Context) ?DeclType(.height) {
    const value = values.parse.lengthPercentageAuto(ctx, types.LengthPercentageAuto) orelse return null;
    return .{ .content_height = .{ .height = .{ .declared = value } } };
}

pub fn @"min-height"(ctx: *Context) ?DeclType(.@"min-height") {
    const value = values.parse.lengthPercentage(ctx, types.LengthPercentage) orelse return null;
    return .{ .content_height = .{ .min_height = .{ .declared = value } } };
}

pub fn @"max-height"(ctx: *Context) ?DeclType(.@"max-height") {
    const value = values.parse.lengthPercentageNone(ctx, types.MaxSize) orelse return null;
    return .{ .content_height = .{ .max_height = .{ .declared = value } } };
}

pub fn @"padding-left"(ctx: *Context) ?DeclType(.@"padding-left") {
    const value = values.parse.lengthPercentage(ctx, types.LengthPercentage) orelse return null;
    return .{ .horizontal_edges = .{ .padding_left = .{ .declared = value } } };
}

pub fn @"padding-right"(ctx: *Context) ?DeclType(.@"padding-right") {
    const value = values.parse.lengthPercentage(ctx, types.LengthPercentage) orelse return null;
    return .{ .horizontal_edges = .{ .padding_right = .{ .declared = value } } };
}

pub fn @"padding-top"(ctx: *Context) ?DeclType(.@"padding-top") {
    const value = values.parse.lengthPercentage(ctx, types.LengthPercentage) orelse return null;
    return .{ .vertical_edges = .{ .padding_top = .{ .declared = value } } };
}

pub fn @"padding-bottom"(ctx: *Context) ?DeclType(.@"padding-bottom") {
    const value = values.parse.lengthPercentage(ctx, types.LengthPercentage) orelse return null;
    return .{ .vertical_edges = .{ .padding_bottom = .{ .declared = value } } };
}

pub fn @"border-left-width"(ctx: *Context) ?DeclType(.@"border-left-width") {
    const value = values.parse.borderWidth(ctx) orelse return null;
    return .{ .horizontal_edges = .{ .border_left = .{ .declared = value } } };
}

pub fn @"border-right-width"(ctx: *Context) ?DeclType(.@"border-right-width") {
    const value = values.parse.borderWidth(ctx) orelse return null;
    return .{ .horizontal_edges = .{ .border_right = .{ .declared = value } } };
}

pub fn @"border-top-width"(ctx: *Context) ?DeclType(.@"border-top-width") {
    const value = values.parse.borderWidth(ctx) orelse return null;
    return .{ .vertical_edges = .{ .border_top = .{ .declared = value } } };
}

pub fn @"border-bottom-width"(ctx: *Context) ?DeclType(.@"border-bottom-width") {
    const value = values.parse.borderWidth(ctx) orelse return null;
    return .{ .vertical_edges = .{ .border_bottom = .{ .declared = value } } };
}

pub fn @"margin-left"(ctx: *Context) ?DeclType(.@"margin-left") {
    const value = values.parse.lengthPercentageAuto(ctx, types.LengthPercentageAuto) orelse return null;
    return .{ .horizontal_edges = .{ .margin_left = .{ .declared = value } } };
}

pub fn @"margin-right"(ctx: *Context) ?DeclType(.@"margin-right") {
    const value = values.parse.lengthPercentageAuto(ctx, types.LengthPercentageAuto) orelse return null;
    return .{ .horizontal_edges = .{ .margin_right = .{ .declared = value } } };
}

pub fn @"margin-top"(ctx: *Context) ?DeclType(.@"margin-top") {
    const value = values.parse.lengthPercentageAuto(ctx, types.LengthPercentageAuto) orelse return null;
    return .{ .vertical_edges = .{ .margin_top = .{ .declared = value } } };
}

pub fn @"margin-bottom"(ctx: *Context) ?DeclType(.@"margin-bottom") {
    const value = values.parse.lengthPercentageAuto(ctx, types.LengthPercentageAuto) orelse return null;
    return .{ .vertical_edges = .{ .margin_bottom = .{ .declared = value } } };
}

pub fn left(ctx: *Context) ?DeclType(.left) {
    const value = values.parse.lengthPercentageAuto(ctx, types.LengthPercentageAuto) orelse return null;
    return .{ .insets = .{ .left = .{ .declared = value } } };
}

pub fn right(ctx: *Context) ?DeclType(.right) {
    const value = values.parse.lengthPercentageAuto(ctx, types.LengthPercentageAuto) orelse return null;
    return .{ .insets = .{ .right = .{ .declared = value } } };
}

pub fn top(ctx: *Context) ?DeclType(.top) {
    const value = values.parse.lengthPercentageAuto(ctx, types.LengthPercentageAuto) orelse return null;
    return .{ .insets = .{ .top = .{ .declared = value } } };
}

pub fn bottom(ctx: *Context) ?DeclType(.bottom) {
    const value = values.parse.lengthPercentageAuto(ctx, types.LengthPercentageAuto) orelse return null;
    return .{ .insets = .{ .bottom = .{ .declared = value } } };
}

pub fn @"background-color"(ctx: *Context) ?DeclType(.@"background-color") {
    const value = values.parse.color(ctx) orelse return null;
    return .{ .background_color = .{ .color = .{ .declared = value } } };
}

pub fn @"background-image"(ctx: *Context, fba: *Fba) !?DeclType(.@"background-image") {
    const save_point = ctx.save();
    const url_save_point = ctx.saveUrlState();

    const list = try fba.allocator().create([max_list_len]types.BackgroundImage);
    var list_len: usize = 0;

    try ctx.beginList();
    while (ctx.nextListItem()) |_| {
        const value = (try values.parse.background.image(ctx)) orelse break;
        ctx.endListItem() catch break;
        if (list_len == max_list_len) break;
        list[list_len] = value;
        list_len += 1;
    } else {
        return .{ .background = .{ .image = .{ .declared = list[0..list_len] } } };
    }

    ctx.reset(save_point);
    ctx.resetUrlState(url_save_point);
    return null;
}

pub fn @"background-repeat"(ctx: *Context, fba: *Fba) !?DeclType(.@"background-repeat") {
    const list = (try parseList(ctx, fba, values.parse.background.repeat)) orelse return null;
    return .{ .background = .{ .repeat = .{ .declared = list } } };
}

pub fn @"background-attachment"(ctx: *Context, fba: *Fba) !?DeclType(.@"background-attachment") {
    const list = (try parseList(ctx, fba, values.parse.background.attachment)) orelse return null;
    return .{ .background = .{ .attachment = .{ .declared = list } } };
}

pub fn @"background-position"(ctx: *Context, fba: *Fba) !?DeclType(.@"background-position") {
    const list = (try parseList(ctx, fba, values.parse.background.position)) orelse return null;
    return .{ .background = .{ .position = .{ .declared = list } } };
}

pub fn @"background-clip"(ctx: *Context, fba: *Fba) !?DeclType(.@"background-clip") {
    const list = (try parseList(ctx, fba, values.parse.background.clip)) orelse return null;
    return .{ .background_clip = .{ .clip = .{ .declared = list } } };
}

pub fn @"background-origin"(ctx: *Context, fba: *Fba) !?DeclType(.@"background-origin") {
    const list = (try parseList(ctx, fba, values.parse.background.origin)) orelse return null;
    return .{ .background = .{ .origin = .{ .declared = list } } };
}

pub fn @"background-size"(ctx: *Context, fba: *Fba) !?DeclType(.@"background-size") {
    const list = (try parseList(ctx, fba, values.parse.background.size)) orelse return null;
    return .{ .background = .{ .size = .{ .declared = list } } };
}

pub fn color(ctx: *Context) ?DeclType(.color) {
    const value = values.parse.color(ctx) orelse return null;
    return .{ .color = .{ .color = .{ .declared = value } } };
}
