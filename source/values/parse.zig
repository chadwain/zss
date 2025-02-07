const std = @import("std");
const Allocator = std.mem.Allocator;

const zss = @import("../zss.zig");
const types = zss.values.types;
const Ast = zss.syntax.Ast;
const Component = zss.syntax.Component;
const TokenSource = zss.syntax.TokenSource;

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
};

fn genericLength(ctx: *Context, comptime Type: type, index: Ast.Size) ?Type {
    var children = ctx.ast.children(index);
    const unit_index = children.nextSkipSpaces(ctx.ast).?;

    const number = ctx.ast.extra(index).number;
    const unit = ctx.ast.extra(unit_index).unit orelse return null;
    return switch (unit) {
        .px => .{ .px = number },
    };
}

fn genericPercentage(ctx: *Context, comptime Type: type, index: Ast.Size) Type {
    const value = ctx.ast.extra(index).number;
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
        return ctx.ast.extra(item.index).integer;
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
        return genericPercentage(ctx, Type, item.index);
    } else {
        ctx.sequence.reset(item.index);
        return null;
    }
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

pub fn cssWideKeyword(ctx: *Context) ?types.CssWideKeyword {
    return keyword(ctx, types.CssWideKeyword, &.{
        .{ "initial", .initial },
        .{ "inherit", .inherit },
        .{ "unset", .unset },
    });
}

pub fn string(ctx: *Context) ?[]const u8 {
    const item = ctx.next() orelse return null;
    if (item.tag == .token_string) {
        const location = ctx.ast.location(item.index);
        return ctx.token_source.copyString(location, ctx.arena) catch std.debug.panic("TODO: Allocation failure", .{});
    }

    ctx.sequence.reset(item.index);
    return null;
}

pub fn hashValue(ctx: *Context) ?[]const u8 {
    const item = ctx.next() orelse return null;
    switch (item.tag) {
        .token_hash_id, .token_hash_unrestricted => {
            const location = ctx.ast.location(item.index);
            return ctx.token_source.copyHash(location, ctx.arena) catch std.debug.panic("TODO: Allocation failure", .{});
        },
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
    } else if (hashValue(ctx)) |hash| {
        sw: switch (hash.len) {
            3 => {
                const rgba = blk: {
                    var result: u32 = 0;
                    for (hash, 0..) |codepoint, i| {
                        const digit: u32 = zss.unicode.hexDigitToNumber(codepoint) catch break :sw;
                        const digit_duped = digit | (digit << 4);
                        result |= (digit_duped << @intCast((3 - i) * 8));
                    }
                    break :blk result;
                };
                return .{ .rgba = rgba };
            },
            // TODO: 4, 6, and 8 color hex values
            4, 6, 8 => {},
            else => {},
        }
    }

    ctx.sequence.reset(reset_point);
    return null;
}

// Syntax:
// <url> = <url()> | <src()>
// <url()> = url( <string> <url-modifier>* ) | <url-token>
// <src()> = src( <string> <url-modifier>* )
pub fn url(ctx: *Context) ?[]const u8 {
    const item = ctx.next() orelse return null;
    switch (item.tag) {
        .token_url => {
            const location = ctx.ast.location(item.index);
            return ctx.token_source.copyUrl(location, ctx.arena) catch std.debug.panic("TODO: Allocation failure", .{});
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
            if (ctx.next()) |_| {
                // The URL may have contained URL modifiers, but these are not supported by zss.

                // TODO: Maybe unnecessary
                ctx.arena.free(str);

                break :blk;
            }
            return str;
        },
        else => {},
    }

    ctx.sequence.reset(item.index);
    return null;
}
