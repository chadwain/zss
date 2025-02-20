const std = @import("std");
const Allocator = std.mem.Allocator;

const zss = @import("../zss.zig");
const types = zss.values.types;
const Ast = zss.syntax.Ast;
const Component = zss.syntax.Component;
const TokenSource = zss.syntax.TokenSource;
const Location = TokenSource.Location;

// TODO: Consider using a static, fixed-size buffer to store any allocations

pub const Context = struct {
    ast: Ast,
    token_source: TokenSource,
    arena: Allocator, // TODO: Store an actual ArenaAllocator
    sequence: Ast.Sequence,

    pub fn init(ast: Ast, token_source: TokenSource, arena: Allocator) Context {
        return .{ .ast = ast, .token_source = token_source, .arena = arena, .sequence = undefined };
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

pub fn cssWideKeyword(ctx: *Context, comptime Type: type) ?Type {
    return keyword(ctx, Type, &.{
        .{ "initial", .initial },
        .{ "inherit", .inherit },
        .{ "unset", .unset },
    });
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
