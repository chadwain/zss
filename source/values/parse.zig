const std = @import("std");
const Allocator = std.mem.Allocator;

const zss = @import("../zss.zig");
const types = zss.values.types;
const Ast = zss.syntax.Ast;
const Component = zss.syntax.Component;
const TokenSource = zss.syntax.TokenSource;
const Location = TokenSource.Location;

pub const Context = struct {
    ast: Ast,
    token_source: TokenSource,
    sequence: Ast.Sequence,

    /// Initializes a `Context`. You must manually set `sequence` before using this context.
    pub fn init(ast: Ast, token_source: TokenSource) Context {
        return .{ .ast = ast, .token_source = token_source, .sequence = undefined };
    }

    const Item = struct {
        index: Ast.Size,
        tag: Component.Tag,
    };

    fn next(ctx: *Context) ?Item {
        const index = ctx.sequence.nextSkipSpaces(ctx.ast) orelse return null;
        const tag = ctx.ast.tag(index);
        return .{ .index = index, .tag = tag };
    }

    fn empty(ctx: *Context) bool {
        return ctx.sequence.empty();
    }
};

pub const background = @import("parse/background.zig");

pub fn cssWideKeyword(ctx: *Context) ?types.CssWideKeyword {
    return keyword(ctx, types.CssWideKeyword, &.{
        .{ "initial", .initial },
        .{ "inherit", .inherit },
        .{ "unset", .unset },
    });
}

fn genericLength(ctx: *const Context, comptime Type: type, index: Ast.Size) ?Type {
    var children = ctx.ast.children(index);
    const unit_index = children.nextSkipSpaces(ctx.ast).?;

    const number = ctx.ast.extra(index).number orelse return null;
    const unit = ctx.ast.extra(unit_index).unit orelse return null;
    return switch (unit) {
        .px => .{ .px = number },
    };
}

fn genericPercentage(ctx: *const Context, comptime Type: type, index: Ast.Size) ?Type {
    const value = ctx.ast.extra(index).number orelse return null;
    return .{ .percentage = value };
}

pub fn keyword(ctx: *Context, comptime Type: type, kvs: []const TokenSource.KV(Type)) ?Type {
    const item = ctx.next() orelse return null;
    if (item.tag == .token_ident) {
        const location = ctx.ast.location(item.index);
        if (ctx.token_source.mapIdentifier(location, Type, kvs)) |result| return result;
    }

    ctx.sequence.reset(item.index);
    return null;
}

pub fn integer(ctx: *Context) ?i32 {
    const item = ctx.next() orelse return null;
    if (item.tag == .token_integer) {
        if (ctx.ast.extra(item.index).integer) |value| return value;
    }

    ctx.sequence.reset(item.index);
    return null;
}

// Spec: CSS 2.2
// <length>
pub fn length(ctx: *Context, comptime Type: type) ?Type {
    const item = ctx.next() orelse return null;
    if (item.tag == .token_dimension) {
        if (genericLength(ctx, Type, item.index)) |result| return result;
    }

    ctx.sequence.reset(item.index);
    return null;
}

// Spec: CSS 2.2
// <percentage>
pub fn percentage(ctx: *Context, comptime Type: type) ?Type {
    const item = ctx.next() orelse return null;
    if (item.tag == .token_percentage) {
        if (genericPercentage(ctx, Type, item.index)) |value| return value;
    }

    ctx.sequence.reset(item.index);
    return null;
}

// Spec: CSS 2.2
// <length> | <percentage>
pub fn lengthPercentage(ctx: *Context, comptime Type: type) ?Type {
    return length(ctx, Type) orelse percentage(ctx, Type);
}

// Spec: CSS 2.2
// <length> | <percentage> | auto
pub fn lengthPercentageAuto(ctx: *Context, comptime Type: type) ?Type {
    return length(ctx, Type) orelse percentage(ctx, Type) orelse keyword(ctx, Type, &.{.{ "auto", .auto }});
}

// Spec: CSS 2.2
// <length> | <percentage> | none
pub fn lengthPercentageNone(ctx: *Context, comptime Type: type) ?Type {
    return length(ctx, Type) orelse percentage(ctx, Type) orelse keyword(ctx, Type, &.{.{ "none", .none }});
}

pub fn string(ctx: *Context) ?Location {
    const item = ctx.next() orelse return null;
    if (item.tag == .token_string) {
        return ctx.ast.location(item.index);
    }

    ctx.sequence.reset(item.index);
    return null;
}

pub fn hash(ctx: *Context) ?Location {
    const item = ctx.next() orelse return null;
    switch (item.tag) {
        .token_hash_id, .token_hash_unrestricted => return ctx.ast.location(item.index),
        else => {},
    }
    ctx.sequence.reset(item.index);
    return null;
}

/// Spec: CSS Color Level 4
/// Syntax: <color> = <color-base> | currentColor | <system-color>
///         <color-base> = <hex-color> | <color-function> | <named-color> | transparent
pub fn color(ctx: *Context) ?types.Color {
    // TODO: Named colors, system colors, color functions
    const reset_point = ctx.sequence.start;
    if (keyword(ctx, types.Color, &.{
        .{ "currentColor", .current_color },
        .{ "transparent", .transparent },
    })) |value| {
        return value;
    } else if (hash(ctx)) |location| blk: {
        var digits: @Vector(8, u8) = undefined;
        const len = len: {
            var iterator = ctx.token_source.hashTokenIterator(location);
            var index: u4 = 0;
            while (iterator.next(ctx.token_source)) |codepoint| : (index += 1) {
                if (index == 8) break :blk;
                digits[index] = zss.unicode.hexDigitToNumber(codepoint) catch break :blk;
            }
            break :len index;
        };

        const rgba_vec: @Vector(4, u8) = sw: switch (len) {
            3 => {
                digits[3] = 0xF;
                continue :sw 4;
            },
            4 => {
                const vec = @shuffle(u8, digits, undefined, @Vector(4, i32){ 0, 1, 2, 3 });
                break :sw (vec << @splat(4)) | vec;
            },
            6 => {
                digits[6] = 0xF;
                digits[7] = 0xF;
                continue :sw 8;
            },
            8 => {
                const high = @shuffle(u8, digits, undefined, @Vector(4, i32){ 0, 2, 4, 6 });
                const low = @shuffle(u8, digits, undefined, @Vector(4, i32){ 1, 3, 5, 7 });
                break :sw (high << @splat(4)) | low;
            },
            else => break :blk,
        };

        var rgba = std.mem.bytesToValue(u32, &@as([4]u8, rgba_vec));
        rgba = std.mem.bigToNative(u32, rgba);
        return .{ .rgba = rgba };
    }

    ctx.sequence.reset(reset_point);
    return null;
}

// Syntax:
// <url> = <url()> | <src()>
// <url()> = url( <string> <url-modifier>* ) | <url-token>
// <src()> = src( <string> <url-modifier>* )
pub fn url(ctx: *Context) ?types.Url {
    const item = ctx.next() orelse return null;
    switch (item.tag) {
        .token_url => {
            return .{ .url_token = ctx.ast.location(item.index) };
        },
        .function => blk: {
            const location = ctx.ast.location(item.index);
            _ = ctx.token_source.mapIdentifier(location, void, &.{
                .{ "url", {} },
                .{ "src", {} },
            }) orelse break :blk;

            const sequence = ctx.sequence;
            defer ctx.sequence = sequence;
            ctx.sequence = ctx.ast.children(item.index);

            const str = string(ctx) orelse break :blk;
            if (!ctx.empty()) {
                // The URL may have contained URL modifiers, but these are not supported by zss.
                break :blk;
            }
            return .{ .string_token = str };
        },
        else => {},
    }

    ctx.sequence.reset(item.index);
    return null;
}

// Spec: CSS 2.2
// inline | block | list-item | inline-block | table | inline-table | table-row-group | table-header-group
// | table-footer-group | table-row | table-column-group | table-column | table-cell | table-caption | none
pub fn display(ctx: *Context) ?types.Display {
    return keyword(ctx, types.Display, &.{
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
    return keyword(ctx, types.Position, &.{
        .{ "static", .static },
        .{ "relative", .relative },
        .{ "absolute", .absolute },
        .{ "fixed", .fixed },
    });
}

// Spec: CSS 2.2
// left | right | none
pub fn float(ctx: *Context) ?types.Float {
    return keyword(ctx, types.Float, &.{
        .{ "left", .left },
        .{ "right", .right },
        .{ "none", .none },
    });
}

// Spec: CSS 2.2
// auto | <integer>
pub fn zIndex(ctx: *Context) ?types.ZIndex {
    if (integer(ctx)) |int| {
        return .{ .integer = int };
    } else {
        return keyword(ctx, types.ZIndex, &.{.{ "auto", .auto }});
    }
}

// Spec: CSS 2.2
// Syntax: <length> | thin | medium | thick
pub fn borderWidth(ctx: *Context) ?types.BorderWidth {
    return length(ctx, types.BorderWidth) orelse
        keyword(ctx, types.BorderWidth, &.{
            .{ "thin", .thin },
            .{ "medium", .medium },
            .{ "thick", .thick },
        });
}

fn testParser(comptime parser: anytype, input: []const u8, expected: @typeInfo(@TypeOf(parser)).@"fn".return_type.?) !void {
    const allocator = std.testing.allocator;

    const token_source = try TokenSource.init(input);
    var ast = try zss.syntax.parse.parseListOfComponentValues(token_source, allocator);
    defer ast.deinit(allocator);

    var ctx = Context.init(ast, token_source);
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

    try testParser(zIndex, "42", .{ .integer = 42 });
    try testParser(zIndex, "-42", .{ .integer = -42 });
    try testParser(zIndex, "auto", .auto);
    try testParser(zIndex, "9999999999999999", null);
    try testParser(zIndex, "-9999999999999999", null);

    // try testParser(lengthPercentage, "5px", .{ .px = 5 });
    // try testParser(lengthPercentage, "5%", .{ .percentage = 5 });
    // try testParser(lengthPercentage, "5", null);
    // try testParser(lengthPercentage, "auto", null);

    // try testParser(lengthPercentageAuto, "5px", .{ .px = 5 });
    // try testParser(lengthPercentageAuto, "5%", .{ .percentage = 5 });
    // try testParser(lengthPercentageAuto, "5", null);
    // try testParser(lengthPercentageAuto, "auto", .auto);

    // try testParser(lengthPercentageNone, "5px", .{ .px = 5 });
    // try testParser(lengthPercentageNone, "5%", .{ .percentage = 5 });
    // try testParser(lengthPercentageNone, "5", null);
    // try testParser(lengthPercentageNone, "auto", null);
    // try testParser(lengthPercentageNone, "none", .none);

    try testParser(borderWidth, "5px", .{ .px = 5 });
    try testParser(borderWidth, "thin", .thin);
    try testParser(borderWidth, "medium", .medium);
    try testParser(borderWidth, "thick", .thick);

    try testParser(background.image, "none", .none);
    try testParser(background.image, "url(abcd)", .{ .url = .{ .url_token = @enumFromInt(0) } });
    try testParser(background.image, "url( \"abcd\" )", .{ .url = .{ .string_token = @enumFromInt(5) } });
    try testParser(background.image, "src(\"wxyz\")", .{ .url = .{ .string_token = @enumFromInt(4) } });
    try testParser(background.image, "invalid", null);

    try testParser(background.repeat, "repeat-x", .{ .x = .repeat, .y = .no_repeat });
    try testParser(background.repeat, "repeat-y", .{ .x = .no_repeat, .y = .repeat });
    try testParser(background.repeat, "repeat", .{ .x = .repeat, .y = .repeat });
    try testParser(background.repeat, "space", .{ .x = .space, .y = .space });
    try testParser(background.repeat, "round", .{ .x = .round, .y = .round });
    try testParser(background.repeat, "no-repeat", .{ .x = .no_repeat, .y = .no_repeat });
    try testParser(background.repeat, "invalid", null);
    try testParser(background.repeat, "repeat space", .{ .x = .repeat, .y = .space });
    try testParser(background.repeat, "round no-repeat", .{ .x = .round, .y = .no_repeat });
    try testParser(background.repeat, "invalid space", null);
    try testParser(background.repeat, "space invalid", .{ .x = .space, .y = .space });
    try testParser(background.repeat, "repeat-x invalid", .{ .x = .repeat, .y = .no_repeat });

    try testParser(background.attachment, "scroll", .scroll);
    try testParser(background.attachment, "fixed", .fixed);
    try testParser(background.attachment, "local", .local);

    try testParser(background.position, "center", .{
        .x = .{ .side = .center, .offset = .{ .percentage = 0 } },
        .y = .{ .side = .center, .offset = .{ .percentage = 0 } },
    });
    try testParser(background.position, "left", .{
        .x = .{ .side = .start, .offset = .{ .percentage = 0 } },
        .y = .{ .side = .center, .offset = .{ .percentage = 0 } },
    });
    try testParser(background.position, "top", .{
        .x = .{ .side = .center, .offset = .{ .percentage = 0 } },
        .y = .{ .side = .start, .offset = .{ .percentage = 0 } },
    });
    try testParser(background.position, "50%", .{
        .x = .{ .side = .start, .offset = .{ .percentage = 50 } },
        .y = .{ .side = .center, .offset = .{ .percentage = 0 } },
    });
    try testParser(background.position, "50px", .{
        .x = .{ .side = .start, .offset = .{ .px = 50 } },
        .y = .{ .side = .center, .offset = .{ .percentage = 0 } },
    });
    try testParser(background.position, "left top", .{
        .x = .{ .side = .start, .offset = .{ .percentage = 0 } },
        .y = .{ .side = .start, .offset = .{ .percentage = 0 } },
    });
    try testParser(background.position, "left center", .{
        .x = .{ .side = .start, .offset = .{ .percentage = 0 } },
        .y = .{ .side = .center, .offset = .{ .percentage = 0 } },
    });
    try testParser(background.position, "center right", .{
        .x = .{ .side = .center, .offset = .{ .percentage = 0 } },
        .y = .{ .side = .center, .offset = .{ .percentage = 0 } },
    });
    try testParser(background.position, "50px right", .{
        .x = .{ .side = .start, .offset = .{ .px = 50 } },
        .y = .{ .side = .center, .offset = .{ .percentage = 0 } },
    });
    try testParser(background.position, "right center", .{
        .x = .{ .side = .end, .offset = .{ .percentage = 0 } },
        .y = .{ .side = .center, .offset = .{ .percentage = 0 } },
    });
    try testParser(background.position, "center center 50%", .{
        .x = .{ .side = .center, .offset = .{ .percentage = 0 } },
        .y = .{ .side = .center, .offset = .{ .percentage = 0 } },
    });
    try testParser(background.position, "left center 20px", .{
        .x = .{ .side = .start, .offset = .{ .percentage = 0 } },
        .y = .{ .side = .center, .offset = .{ .percentage = 0 } },
    });
    try testParser(background.position, "left 20px bottom 50%", .{
        .x = .{ .side = .start, .offset = .{ .px = 20 } },
        .y = .{ .side = .end, .offset = .{ .percentage = 50 } },
    });
    try testParser(background.position, "center bottom 50%", .{
        .x = .{ .side = .center, .offset = .{ .percentage = 0 } },
        .y = .{ .side = .end, .offset = .{ .percentage = 50 } },
    });
    try testParser(background.position, "bottom 50% center", .{
        .x = .{ .side = .center, .offset = .{ .percentage = 0 } },
        .y = .{ .side = .end, .offset = .{ .percentage = 50 } },
    });
    try testParser(background.position, "bottom 50% left 20px", .{
        .x = .{ .side = .start, .offset = .{ .px = 20 } },
        .y = .{ .side = .end, .offset = .{ .percentage = 50 } },
    });

    try testParser(background.clip, "border-box", .border_box);
    try testParser(background.clip, "padding-box", .padding_box);
    try testParser(background.clip, "content-box", .content_box);

    try testParser(background.origin, "border-box", .border_box);
    try testParser(background.origin, "padding-box", .padding_box);
    try testParser(background.origin, "content-box", .content_box);

    try testParser(background.size, "contain", .contain);
    try testParser(background.size, "cover", .cover);
    try testParser(background.size, "auto", .{ .size = .{ .width = .auto, .height = .auto } });
    try testParser(background.size, "auto auto", .{ .size = .{ .width = .auto, .height = .auto } });
    try testParser(background.size, "5px", .{ .size = .{ .width = .{ .px = 5 }, .height = .{ .px = 5 } } });
    try testParser(background.size, "5px 5%", .{ .size = .{ .width = .{ .px = 5 }, .height = .{ .percentage = 5 } } });

    try testParser(color, "currentColor", .current_color);
    try testParser(color, "transparent", .transparent);
    try testParser(color, "#abc", .{ .rgba = 0xaabbccff });
    try testParser(color, "#abcd", .{ .rgba = 0xaabbccdd });
    try testParser(color, "#123456", .{ .rgba = 0x123456ff });
    try testParser(color, "#12345678", .{ .rgba = 0x12345678 });
}
