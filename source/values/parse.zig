const std = @import("std");
const Allocator = std.mem.Allocator;

const zss = @import("../zss.zig");
const types = zss.values.types;
const Ast = zss.syntax.Ast;
const Component = zss.syntax.Component;
const Environment = zss.Environment;
const TokenSource = zss.syntax.TokenSource;
const Location = TokenSource.Location;

pub const Context = struct {
    env: *Environment,
    ast: Ast,
    token_source: TokenSource,
    state: State,

    pub const State = struct {
        sequence: Ast.Sequence,
        mode: enum { normal, list },
    };

    /// Initializes a `Context`. You must manually call `setSequence` before using this context.
    pub fn init(env: *Environment, ast: Ast, token_source: TokenSource) Context {
        return .{
            .env = env,
            .ast = ast,
            .token_source = token_source,
            .state = .{
                .sequence = undefined,
                .mode = .normal,
            },
        };
    }

    pub const Item = struct {
        index: Ast.Size,
        tag: Component.Tag,
    };

    fn rawNext(ctx: *Context) ?Item {
        const index = ctx.state.sequence.nextSkipSpaces(ctx.ast) orelse return null;
        const tag = ctx.ast.tag(index);
        return .{ .index = index, .tag = tag };
    }

    pub fn next(ctx: *Context) ?Item {
        switch (ctx.state.mode) {
            .normal => return ctx.rawNext(),
            .list => {
                const item = ctx.rawNext() orelse return null;
                if (item.tag == .token_comma) {
                    ctx.state.sequence.reset(item.index);
                    return null;
                } else {
                    return item;
                }
            },
        }
    }

    pub fn beginList(ctx: *Context) !void {
        std.debug.assert(ctx.state.mode == .normal);
        ctx.state.mode = .list;
        const item = ctx.rawNext() orelse return;
        if (item.tag == .token_comma) return error.ParseError; // Leading comma
        ctx.state.sequence.reset(item.index);
    }

    pub fn endListItem(ctx: *Context) !void {
        const comma = ctx.rawNext() orelse return;
        if (comma.tag != .token_comma) return error.ParseError; // List item not fully consumed
        const item = ctx.rawNext() orelse return error.ParseError; // Trailing comma
        if (item.tag == .token_comma) return error.ParseError; // Two commas in a row
        ctx.state.sequence.reset(item.index);
    }

    pub fn nextListItem(ctx: *Context) ?void {
        const item = ctx.rawNext() orelse return null;
        ctx.state.sequence.reset(item.index);
    }

    pub fn save(ctx: *Context) Ast.Size {
        return ctx.state.sequence.start;
    }

    pub fn reset(ctx: *Context, save_point: Ast.Size) void {
        ctx.state.sequence.reset(save_point);
    }

    pub fn enterSequence(ctx: *Context, index: Ast.Size) State {
        defer ctx.state = .{
            .sequence = ctx.ast.children(index),
            .mode = .normal,
        };
        return ctx.state;
    }

    pub fn exitSequence(ctx: *Context, previous_state: State) void {
        ctx.state = previous_state;
    }

    pub fn empty(ctx: *Context) bool {
        switch (ctx.state.mode) {
            .normal => return ctx.state.sequence.empty(),
            .list => {
                const item = ctx.rawNext() orelse return true;
                ctx.state.sequence.reset(item.index);
                return item.tag == .token_comma;
            },
        }
    }

    pub fn saveUrlState(ctx: *Context) usize {
        return ctx.env.recent_urls.descriptions.len;
    }

    pub fn resetUrlState(ctx: *Context, previous_state: usize) void {
        ctx.env.recent_urls.descriptions.shrinkRetainingCapacity(previous_state);
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

    ctx.reset(item.index);
    return null;
}

pub fn integer(ctx: *Context) ?i32 {
    const item = ctx.next() orelse return null;
    if (item.tag == .token_integer) {
        if (ctx.ast.extra(item.index).integer) |value| return value;
    }

    ctx.reset(item.index);
    return null;
}

// Spec: CSS 2.2
// <length>
pub fn length(ctx: *Context, comptime Type: type) ?Type {
    const item = ctx.next() orelse return null;
    if (item.tag == .token_dimension) {
        if (genericLength(ctx, Type, item.index)) |result| return result;
    }

    ctx.reset(item.index);
    return null;
}

// Spec: CSS 2.2
// <percentage>
pub fn percentage(ctx: *Context, comptime Type: type) ?Type {
    const item = ctx.next() orelse return null;
    if (item.tag == .token_percentage) {
        if (genericPercentage(ctx, Type, item.index)) |value| return value;
    }

    ctx.reset(item.index);
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

    ctx.reset(item.index);
    return null;
}

pub fn hash(ctx: *Context) ?Location {
    const item = ctx.next() orelse return null;
    switch (item.tag) {
        .token_hash_id, .token_hash_unrestricted => return ctx.ast.location(item.index),
        else => {},
    }
    ctx.reset(item.index);
    return null;
}

/// Spec: CSS Color Level 4
/// Syntax: <color> = <color-base> | currentColor | <system-color>
///         <color-base> = <hex-color> | <color-function> | <named-color> | transparent
pub fn color(ctx: *Context) ?types.Color {
    // TODO: Named colors, system colors, color functions
    const save_point = ctx.save();
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

    ctx.reset(save_point);
    return null;
}

// Syntax:
// <url> = <url()> | <src()>
// <url()> = url( <string> <url-modifier>* ) | <url-token>
// <src()> = src( <string> <url-modifier>* )
pub fn url(ctx: *Context) !?zss.Environment.UrlId {
    const item = ctx.next() orelse return null;
    switch (item.tag) {
        .token_url => return try ctx.env.addUrl(.{
            .type = .image,
            .src_loc = .{ .url_token = ctx.ast.location(item.index) },
        }),
        .function => blk: {
            const location = ctx.ast.location(item.index);
            _ = ctx.token_source.mapIdentifier(location, void, &.{
                .{ "url", {} },
                .{ "src", {} },
            }) orelse break :blk;

            const state = ctx.enterSequence(item.index);
            defer ctx.exitSequence(state);

            const str = string(ctx) orelse break :blk;
            if (!ctx.empty()) {
                // The URL may have contained URL modifiers, but these are not supported by zss.
                break :blk;
            }

            return try ctx.env.addUrl(.{
                .type = .image,
                .src_loc = .{ .string_token = str },
            });
        },
        else => {},
    }

    ctx.reset(item.index);
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

test "value parsers" {
    const ns = struct {
        fn expectValue(comptime parser: anytype, input: []const u8, expected: ExpectedType(parser)) !void {
            const actual = try runParser(parser, input);
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

        fn runParser(comptime parser: anytype, input: []const u8) !ExpectedType(parser) {
            const allocator = std.testing.allocator;

            const token_source = try TokenSource.init(input);
            var ast = blk: {
                var syntax_parser = zss.syntax.Parser.init(token_source, allocator);
                defer syntax_parser.deinit();
                break :blk try syntax_parser.parseListOfComponentValues(allocator);
            };
            defer ast.deinit(allocator);

            var env = Environment.init(allocator);
            defer env.deinit();

            var ctx = Context.init(&env, ast, token_source);
            _ = ctx.enterSequence(0);

            const parsed_value = parser(&ctx);
            switch (@typeInfo(@TypeOf(parsed_value))) {
                .error_union => return try parsed_value,
                .optional => return parsed_value,
                else => comptime unreachable,
            }
        }

        fn ExpectedType(comptime parser: anytype) type {
            const return_type = @typeInfo(@TypeOf(parser)).@"fn".return_type.?;
            return switch (@typeInfo(return_type)) {
                .error_union => |eu| eu.payload,
                .optional => return_type,
                else => comptime unreachable,
            };
        }
    };

    try ns.expectValue(display, "block", .block);
    try ns.expectValue(display, "inline", .@"inline");

    try ns.expectValue(position, "static", .static);

    try ns.expectValue(float, "left", .left);
    try ns.expectValue(float, "right", .right);
    try ns.expectValue(float, "none", .none);

    try ns.expectValue(zIndex, "42", .{ .integer = 42 });
    try ns.expectValue(zIndex, "-42", .{ .integer = -42 });
    try ns.expectValue(zIndex, "auto", .auto);
    try ns.expectValue(zIndex, "9999999999999999", null);
    try ns.expectValue(zIndex, "-9999999999999999", null);

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

    try ns.expectValue(borderWidth, "5px", .{ .px = 5 });
    try ns.expectValue(borderWidth, "thin", .thin);
    try ns.expectValue(borderWidth, "medium", .medium);
    try ns.expectValue(borderWidth, "thick", .thick);

    try ns.expectValue(background.image, "none", .none);
    _ = try ns.runParser(background.image, "url(abcd)");
    _ = try ns.runParser(background.image, "url( \"abcd\" )");
    _ = try ns.runParser(background.image, "src(\"wxyz\")");
    try ns.expectValue(background.image, "invalid", null);

    try ns.expectValue(background.repeat, "repeat-x", .{ .x = .repeat, .y = .no_repeat });
    try ns.expectValue(background.repeat, "repeat-y", .{ .x = .no_repeat, .y = .repeat });
    try ns.expectValue(background.repeat, "repeat", .{ .x = .repeat, .y = .repeat });
    try ns.expectValue(background.repeat, "space", .{ .x = .space, .y = .space });
    try ns.expectValue(background.repeat, "round", .{ .x = .round, .y = .round });
    try ns.expectValue(background.repeat, "no-repeat", .{ .x = .no_repeat, .y = .no_repeat });
    try ns.expectValue(background.repeat, "invalid", null);
    try ns.expectValue(background.repeat, "repeat space", .{ .x = .repeat, .y = .space });
    try ns.expectValue(background.repeat, "round no-repeat", .{ .x = .round, .y = .no_repeat });
    try ns.expectValue(background.repeat, "invalid space", null);
    try ns.expectValue(background.repeat, "space invalid", .{ .x = .space, .y = .space });
    try ns.expectValue(background.repeat, "repeat-x invalid", .{ .x = .repeat, .y = .no_repeat });

    try ns.expectValue(background.attachment, "scroll", .scroll);
    try ns.expectValue(background.attachment, "fixed", .fixed);
    try ns.expectValue(background.attachment, "local", .local);

    try ns.expectValue(background.position, "center", .{
        .x = .{ .side = .center, .offset = .{ .percentage = 0 } },
        .y = .{ .side = .center, .offset = .{ .percentage = 0 } },
    });
    try ns.expectValue(background.position, "left", .{
        .x = .{ .side = .start, .offset = .{ .percentage = 0 } },
        .y = .{ .side = .center, .offset = .{ .percentage = 0 } },
    });
    try ns.expectValue(background.position, "top", .{
        .x = .{ .side = .center, .offset = .{ .percentage = 0 } },
        .y = .{ .side = .start, .offset = .{ .percentage = 0 } },
    });
    try ns.expectValue(background.position, "50%", .{
        .x = .{ .side = .start, .offset = .{ .percentage = 50 } },
        .y = .{ .side = .center, .offset = .{ .percentage = 0 } },
    });
    try ns.expectValue(background.position, "50px", .{
        .x = .{ .side = .start, .offset = .{ .px = 50 } },
        .y = .{ .side = .center, .offset = .{ .percentage = 0 } },
    });
    try ns.expectValue(background.position, "left top", .{
        .x = .{ .side = .start, .offset = .{ .percentage = 0 } },
        .y = .{ .side = .start, .offset = .{ .percentage = 0 } },
    });
    try ns.expectValue(background.position, "left center", .{
        .x = .{ .side = .start, .offset = .{ .percentage = 0 } },
        .y = .{ .side = .center, .offset = .{ .percentage = 0 } },
    });
    try ns.expectValue(background.position, "center right", .{
        .x = .{ .side = .center, .offset = .{ .percentage = 0 } },
        .y = .{ .side = .center, .offset = .{ .percentage = 0 } },
    });
    try ns.expectValue(background.position, "50px right", .{
        .x = .{ .side = .start, .offset = .{ .px = 50 } },
        .y = .{ .side = .center, .offset = .{ .percentage = 0 } },
    });
    try ns.expectValue(background.position, "right center", .{
        .x = .{ .side = .end, .offset = .{ .percentage = 0 } },
        .y = .{ .side = .center, .offset = .{ .percentage = 0 } },
    });
    try ns.expectValue(background.position, "center center 50%", .{
        .x = .{ .side = .center, .offset = .{ .percentage = 0 } },
        .y = .{ .side = .center, .offset = .{ .percentage = 0 } },
    });
    try ns.expectValue(background.position, "left center 20px", .{
        .x = .{ .side = .start, .offset = .{ .percentage = 0 } },
        .y = .{ .side = .center, .offset = .{ .percentage = 0 } },
    });
    try ns.expectValue(background.position, "left 20px bottom 50%", .{
        .x = .{ .side = .start, .offset = .{ .px = 20 } },
        .y = .{ .side = .end, .offset = .{ .percentage = 50 } },
    });
    try ns.expectValue(background.position, "center bottom 50%", .{
        .x = .{ .side = .center, .offset = .{ .percentage = 0 } },
        .y = .{ .side = .end, .offset = .{ .percentage = 50 } },
    });
    try ns.expectValue(background.position, "bottom 50% center", .{
        .x = .{ .side = .center, .offset = .{ .percentage = 0 } },
        .y = .{ .side = .end, .offset = .{ .percentage = 50 } },
    });
    try ns.expectValue(background.position, "bottom 50% left 20px", .{
        .x = .{ .side = .start, .offset = .{ .px = 20 } },
        .y = .{ .side = .end, .offset = .{ .percentage = 50 } },
    });

    try ns.expectValue(background.clip, "border-box", .border_box);
    try ns.expectValue(background.clip, "padding-box", .padding_box);
    try ns.expectValue(background.clip, "content-box", .content_box);

    try ns.expectValue(background.origin, "border-box", .border_box);
    try ns.expectValue(background.origin, "padding-box", .padding_box);
    try ns.expectValue(background.origin, "content-box", .content_box);

    try ns.expectValue(background.size, "contain", .contain);
    try ns.expectValue(background.size, "cover", .cover);
    try ns.expectValue(background.size, "auto", .{ .size = .{ .width = .auto, .height = .auto } });
    try ns.expectValue(background.size, "auto auto", .{ .size = .{ .width = .auto, .height = .auto } });
    try ns.expectValue(background.size, "5px", .{ .size = .{ .width = .{ .px = 5 }, .height = .{ .px = 5 } } });
    try ns.expectValue(background.size, "5px 5%", .{ .size = .{ .width = .{ .px = 5 }, .height = .{ .percentage = 5 } } });

    try ns.expectValue(color, "currentColor", .current_color);
    try ns.expectValue(color, "transparent", .transparent);
    try ns.expectValue(color, "#abc", .{ .rgba = 0xaabbccff });
    try ns.expectValue(color, "#abcd", .{ .rgba = 0xaabbccdd });
    try ns.expectValue(color, "#123456", .{ .rgba = 0x123456ff });
    try ns.expectValue(color, "#12345678", .{ .rgba = 0x12345678 });
}
