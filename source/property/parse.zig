//! Parsers for every supported CSS property in zss.
//! Each one is named exactly the same as the actual CSS property.
//!
//! Be aware that these parsers WILL NOT parse the CSS-wide keywords.
//! There is also no parser for the 'all' property.
//! These cases are instead handled by `zss.values.parse.cssWideKeyword`.

const std = @import("std");
const Fba = std.heap.FixedBufferAllocator;

const zss = @import("../zss.zig");
const DeclType = zss.property.Property.DeclarationType;
const TokenSource = zss.syntax.TokenSource;

const values = zss.values;
const types = values.types;
const Context = values.parse.Context;

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
    // TODO: Parse a list of values
    const value_ptr = try fba.allocator().create(types.BackgroundImage);
    value_ptr.* = values.parse.background.image(ctx) orelse return null;
    return .{ .background = .{ .image = .{ .declared = value_ptr[0..1] } } };
}

pub fn @"background-repeat"(ctx: *Context, fba: *Fba) !?DeclType(.@"background-repeat") {
    // TODO: Parse a list of values
    const value_ptr = try fba.allocator().create(types.BackgroundRepeat);
    value_ptr.* = values.parse.background.repeat(ctx) orelse return null;
    return .{ .background = .{ .repeat = .{ .declared = value_ptr[0..1] } } };
}

pub fn @"background-attachment"(ctx: *Context, fba: *Fba) !?DeclType(.@"background-attachment") {
    // TODO: Parse a list of values
    const value_ptr = try fba.allocator().create(types.BackgroundAttachment);
    value_ptr.* = values.parse.background.attachment(ctx) orelse return null;
    return .{ .background = .{ .attachment = .{ .declared = value_ptr[0..1] } } };
}

pub fn @"background-position"(ctx: *Context, fba: *Fba) !?DeclType(.@"background-position") {
    // TODO: Parse a list of values
    const value_ptr = try fba.allocator().create(types.BackgroundPosition);
    value_ptr.* = values.parse.background.position(ctx) orelse return null;
    return .{ .background = .{ .position = .{ .declared = value_ptr[0..1] } } };
}

pub fn @"background-clip"(ctx: *Context, fba: *Fba) !?DeclType(.@"background-clip") {
    // TODO: Parse a list of values
    const value_ptr = try fba.allocator().create(types.BackgroundClip);
    value_ptr.* = values.parse.background.clip(ctx) orelse return null;
    return .{ .background_clip = .{ .clip = .{ .declared = value_ptr[0..1] } } };
}

pub fn @"background-origin"(ctx: *Context, fba: *Fba) !?DeclType(.@"background-origin") {
    // TODO: Parse a list of values
    const value_ptr = try fba.allocator().create(types.BackgroundOrigin);
    value_ptr.* = values.parse.background.origin(ctx) orelse return null;
    return .{ .background = .{ .origin = .{ .declared = value_ptr[0..1] } } };
}

pub fn @"background-size"(ctx: *Context, fba: *Fba) !?DeclType(.@"background-size") {
    // TODO: Parse a list of values
    const value_ptr = try fba.allocator().create(types.BackgroundSize);
    value_ptr.* = values.parse.background.size(ctx) orelse return null;
    return .{ .background = .{ .size = .{ .declared = value_ptr[0..1] } } };
}

pub fn color(ctx: *Context) ?DeclType(.color) {
    const value = values.parse.color(ctx) orelse return null;
    return .{ .color = .{ .color = .{ .declared = value } } };
}
