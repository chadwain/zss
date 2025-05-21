//! Parsers for every supported CSS property in zss.
//! Each one is named exactly the same as the actual CSS property.
//!
//! Be aware that these parsers WILL NOT parse the CSS-wide keywords.
//! There is also no parser for the 'all' property.
//! These cases are instead handled by `zss.values.parse.cssWideKeyword`.

const std = @import("std");

const zss = @import("../zss.zig");
const TokenSource = zss.syntax.TokenSource;

const values = zss.values;
const types = values.types;
const Context = values.parse.Context;

// Spec: CSS 2.2
// inline | block | list-item | inline-block | table | inline-table | table-row-group | table-header-group
// | table-footer-group | table-row | table-column-group | table-column | table-cell | table-caption | none
pub fn display(ctx: *Context) ?types.Display {
    return values.parse.keyword(ctx, types.Display, &.{
        .{ "inline", .@"inline" },
        .{ "block", .block },
        // .{ "list-item", .list_item },
        .{ "inline-block", .inline_block },
        // .{ "table", .table },
        // .{ "inline-table", .inline_table },
        // .{ "table-row-group", .table_row_group },
        // .{ "table-header-group", .table_header_group },
        // .{ "table-footer-group", .table_footer_group },
        // .{ "table-row", .table_row },
        // .{ "table-column-group", .table_column_group },
        // .{ "table-column", .table_column },
        // .{ "table-cell", .table_cell },
        // .{ "table-caption", .table_caption },
        .{ "none", .none },
    });
}

// Spec: CSS 2.2
// static | relative | absolute | fixed
pub fn position(ctx: *Context) ?types.Position {
    return values.parse.keyword(ctx, types.Position, &.{
        .{ "static", .static },
        .{ "relative", .relative },
        .{ "absolute", .absolute },
        .{ "fixed", .fixed },
    });
}

// Spec: CSS 2.2
// left | right | none
pub fn float(ctx: *Context) ?types.Float {
    return values.parse.keyword(ctx, types.Float, &.{
        .{ "left", .left },
        .{ "right", .right },
        .{ "none", .none },
    });
}

// Spec: CSS 2.2
// auto | <integer>
pub fn @"z-index"(ctx: *Context) ?types.ZIndex {
    if (values.parse.integer(ctx)) |integer| {
        return .{ .integer = integer };
    } else {
        return values.parse.keyword(ctx, types.ZIndex, &.{.{ "auto", .auto }});
    }
}

pub const width = lengthPercentageAuto;
pub const @"min-width" = lengthPercentage;
pub const @"max-width" = maxSize;
pub const height = lengthPercentageAuto;
pub const @"min-height" = lengthPercentage;
pub const @"max-height" = maxSize;

// Spec: CSS 2.2
// <length> | <percentage> | none
fn maxSize(ctx: *Context) ?types.MaxSize {
    return values.parse.lengthPercentageNone(ctx, types.MaxSize);
}

pub const @"padding-left" = lengthPercentage;
pub const @"padding-right" = lengthPercentage;
pub const @"padding-top" = lengthPercentage;
pub const @"padding-bottom" = lengthPercentage;

pub const @"border-left-width" = borderWidth;
pub const @"border-right-width" = borderWidth;
pub const @"border-top-width" = borderWidth;
pub const @"border-bottom-width" = borderWidth;

// Spec: CSS 2.2
// Syntax: <length> | thin | medium | thick
fn borderWidth(ctx: *Context) ?types.BorderWidth {
    return values.parse.length(ctx, types.BorderWidth) orelse
        values.parse.keyword(ctx, types.BorderWidth, &.{
            .{ "thin", .thin },
            .{ "medium", .medium },
            .{ "thick", .thick },
        });
}

pub const @"margin-left" = lengthPercentageAuto;
pub const @"margin-right" = lengthPercentageAuto;
pub const @"margin-top" = lengthPercentageAuto;
pub const @"margin-bottom" = lengthPercentageAuto;

pub const left = lengthPercentageAuto;
pub const right = lengthPercentageAuto;
pub const top = lengthPercentageAuto;
pub const bottom = lengthPercentageAuto;

// Spec: CSS 2.2
// <length> | <percentage>
fn lengthPercentage(ctx: *Context) ?types.LengthPercentage {
    return values.parse.lengthPercentage(ctx, types.LengthPercentage);
}

// Spec: CSS 2.2
// <length> | <percentage> | auto
fn lengthPercentageAuto(ctx: *Context) ?types.LengthPercentageAuto {
    return values.parse.lengthPercentageAuto(ctx, types.LengthPercentageAuto);
}

const background_mod = @import("parse/background.zig");
pub const @"background-color" = values.parse.color;
pub const @"background-image" = background_mod.@"background-image";
pub const @"background-repeat" = background_mod.@"background-repeat";
pub const @"background-attachment" = background_mod.@"background-attachment";
pub const @"background-position" = background_mod.@"background-position";
pub const @"background-clip" = background_mod.@"background-clip";
pub const @"background-origin" = background_mod.@"background-origin";
pub const @"background-size" = background_mod.@"background-size";

pub const color = values.parse.color;

fn testParser(comptime parser: anytype, input: []const u8, expected: @typeInfo(@TypeOf(parser)).@"fn".return_type.?) !void {
    const allocator = std.testing.allocator;

    const token_source = try TokenSource.init(input);
    var ast = try zss.syntax.parse.parseListOfComponentValues(token_source, allocator);
    defer ast.deinit(allocator);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var ctx = Context.init(ast, token_source, arena.allocator());
    ctx.sequence = ast.children(0);

    const actual = parser(&ctx);
    if (expected) |expected_payload| {
        if (actual) |actual_payload| {
            errdefer std.debug.print("Expected: {}\nActual: {}\n", .{ expected_payload, actual_payload });
            return std.testing.expectEqual(expected_payload, actual_payload);
        } else {
            errdefer std.debug.print("Expected: {}, found: null\n", .{expected_payload});
            return error.TestExpectedEqual;
        }
    } else {
        errdefer std.debug.print("Expected: null, found: {}\n", .{actual.?});
        return std.testing.expect(actual == null);
    }
}

test "property parsers" {
    try testParser(display, "block", .block);
    try testParser(display, "inline", .@"inline");

    try testParser(position, "static", .static);

    try testParser(float, "left", .left);
    try testParser(float, "right", .right);
    try testParser(float, "none", .none);

    try testParser(@"z-index", "42", .{ .integer = 42 });
    try testParser(@"z-index", "-42", .{ .integer = -42 });
    try testParser(@"z-index", "auto", .auto);
    try testParser(@"z-index", "9999999999999999", null);
    try testParser(@"z-index", "-9999999999999999", null);

    try testParser(lengthPercentage, "5px", .{ .px = 5 });
    try testParser(lengthPercentage, "5%", .{ .percentage = 5 });
    try testParser(lengthPercentage, "5", null);
    try testParser(lengthPercentage, "auto", null);

    try testParser(lengthPercentageAuto, "5px", .{ .px = 5 });
    try testParser(lengthPercentageAuto, "5%", .{ .percentage = 5 });
    try testParser(lengthPercentageAuto, "5", null);
    try testParser(lengthPercentageAuto, "auto", .auto);

    try testParser(maxSize, "5px", .{ .px = 5 });
    try testParser(maxSize, "5%", .{ .percentage = 5 });
    try testParser(maxSize, "5", null);
    try testParser(maxSize, "auto", null);
    try testParser(maxSize, "none", .none);

    try testParser(borderWidth, "5px", .{ .px = 5 });
    try testParser(borderWidth, "thin", .thin);
    try testParser(borderWidth, "medium", .medium);
    try testParser(borderWidth, "thick", .thick);

    try testParser(@"background-image", "none", .none);
    try testParser(@"background-image", "url(abcd)", .{ .url = .{ .url_token = @enumFromInt(0) } });
    try testParser(@"background-image", "url( \"abcd\" )", .{ .url = .{ .string_token = @enumFromInt(5) } });
    try testParser(@"background-image", "src(\"wxyz\")", .{ .url = .{ .string_token = @enumFromInt(4) } });
    try testParser(@"background-image", "invalid", null);

    try testParser(@"background-repeat", "repeat-x", .{ .repeat = .{ .x = .repeat, .y = .no_repeat } });
    try testParser(@"background-repeat", "repeat-y", .{ .repeat = .{ .x = .no_repeat, .y = .repeat } });
    try testParser(@"background-repeat", "repeat", .{ .repeat = .{ .x = .repeat, .y = .repeat } });
    try testParser(@"background-repeat", "space", .{ .repeat = .{ .x = .space, .y = .space } });
    try testParser(@"background-repeat", "round", .{ .repeat = .{ .x = .round, .y = .round } });
    try testParser(@"background-repeat", "no-repeat", .{ .repeat = .{ .x = .no_repeat, .y = .no_repeat } });
    try testParser(@"background-repeat", "invalid", null);
    try testParser(@"background-repeat", "repeat space", .{ .repeat = .{ .x = .repeat, .y = .space } });
    try testParser(@"background-repeat", "round no-repeat", .{ .repeat = .{ .x = .round, .y = .no_repeat } });
    try testParser(@"background-repeat", "invalid space", null);
    try testParser(@"background-repeat", "space invalid", .{ .repeat = .{ .x = .space, .y = .space } });
    try testParser(@"background-repeat", "repeat-x invalid", .{ .repeat = .{ .x = .repeat, .y = .no_repeat } });

    try testParser(@"background-attachment", "scroll", .scroll);
    try testParser(@"background-attachment", "fixed", .fixed);
    try testParser(@"background-attachment", "local", .local);

    try testParser(@"background-position", "center", .{ .position = .{
        .x = .{ .side = .center, .offset = .{ .percentage = 0 } },
        .y = .{ .side = .center, .offset = .{ .percentage = 0 } },
    } });
    try testParser(@"background-position", "left", .{ .position = .{
        .x = .{ .side = .start, .offset = .{ .percentage = 0 } },
        .y = .{ .side = .center, .offset = .{ .percentage = 0 } },
    } });
    try testParser(@"background-position", "top", .{ .position = .{
        .x = .{ .side = .center, .offset = .{ .percentage = 0 } },
        .y = .{ .side = .start, .offset = .{ .percentage = 0 } },
    } });
    try testParser(@"background-position", "50%", .{ .position = .{
        .x = .{ .side = .start, .offset = .{ .percentage = 50 } },
        .y = .{ .side = .center, .offset = .{ .percentage = 0 } },
    } });
    try testParser(@"background-position", "50px", .{ .position = .{
        .x = .{ .side = .start, .offset = .{ .px = 50 } },
        .y = .{ .side = .center, .offset = .{ .percentage = 0 } },
    } });
    try testParser(@"background-position", "left top", .{ .position = .{
        .x = .{ .side = .start, .offset = .{ .percentage = 0 } },
        .y = .{ .side = .start, .offset = .{ .percentage = 0 } },
    } });
    try testParser(@"background-position", "left center", .{ .position = .{
        .x = .{ .side = .start, .offset = .{ .percentage = 0 } },
        .y = .{ .side = .center, .offset = .{ .percentage = 0 } },
    } });
    try testParser(@"background-position", "center right", .{ .position = .{
        .x = .{ .side = .center, .offset = .{ .percentage = 0 } },
        .y = .{ .side = .center, .offset = .{ .percentage = 0 } },
    } });
    try testParser(@"background-position", "50px right", .{ .position = .{
        .x = .{ .side = .start, .offset = .{ .px = 50 } },
        .y = .{ .side = .center, .offset = .{ .percentage = 0 } },
    } });
    try testParser(@"background-position", "right center", .{ .position = .{
        .x = .{ .side = .end, .offset = .{ .percentage = 0 } },
        .y = .{ .side = .center, .offset = .{ .percentage = 0 } },
    } });
    try testParser(@"background-position", "center center 50%", .{ .position = .{
        .x = .{ .side = .center, .offset = .{ .percentage = 0 } },
        .y = .{ .side = .center, .offset = .{ .percentage = 0 } },
    } });
    try testParser(@"background-position", "left center 20px", .{ .position = .{
        .x = .{ .side = .start, .offset = .{ .percentage = 0 } },
        .y = .{ .side = .center, .offset = .{ .percentage = 0 } },
    } });
    try testParser(@"background-position", "left 20px bottom 50%", .{ .position = .{
        .x = .{ .side = .start, .offset = .{ .px = 20 } },
        .y = .{ .side = .end, .offset = .{ .percentage = 50 } },
    } });
    try testParser(@"background-position", "center bottom 50%", .{ .position = .{
        .x = .{ .side = .center, .offset = .{ .percentage = 0 } },
        .y = .{ .side = .end, .offset = .{ .percentage = 50 } },
    } });
    try testParser(@"background-position", "bottom 50% center", .{ .position = .{
        .x = .{ .side = .center, .offset = .{ .percentage = 0 } },
        .y = .{ .side = .end, .offset = .{ .percentage = 50 } },
    } });
    try testParser(@"background-position", "bottom 50% left 20px", .{ .position = .{
        .x = .{ .side = .start, .offset = .{ .px = 20 } },
        .y = .{ .side = .end, .offset = .{ .percentage = 50 } },
    } });

    try testParser(@"background-clip", "border-box", .border_box);
    try testParser(@"background-clip", "padding-box", .padding_box);
    try testParser(@"background-clip", "content-box", .content_box);

    try testParser(@"background-origin", "border-box", .border_box);
    try testParser(@"background-origin", "padding-box", .padding_box);
    try testParser(@"background-origin", "content-box", .content_box);

    try testParser(@"background-size", "contain", .contain);
    try testParser(@"background-size", "cover", .cover);
    try testParser(@"background-size", "auto", .{ .size = .{ .width = .auto, .height = .auto } });
    try testParser(@"background-size", "auto auto", .{ .size = .{ .width = .auto, .height = .auto } });
    try testParser(@"background-size", "5px", .{ .size = .{ .width = .{ .px = 5 }, .height = .{ .px = 5 } } });
    try testParser(@"background-size", "5px 5%", .{ .size = .{ .width = .{ .px = 5 }, .height = .{ .percentage = 5 } } });

    try testParser(color, "currentColor", .current_color);
    try testParser(color, "transparent", .transparent);
    try testParser(color, "#abc", .{ .rgba = 0xaabbccff });
    try testParser(color, "#abcd", .{ .rgba = 0xaabbccdd });
    try testParser(color, "#123456", .{ .rgba = 0x123456ff });
    try testParser(color, "#12345678", .{ .rgba = 0x12345678 });
}
