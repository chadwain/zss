const std = @import("std");
const Allocator = std.mem.Allocator;

const zss = @import("../zss.zig");
const types = zss.values.types;
const Ast = zss.syntax.Ast;
const Component = zss.syntax.Component;
const TokenSource = zss.syntax.TokenSource;
const Unit = zss.syntax.Token.Unit;

/// A source of primitive CSS values.
pub const Source = struct {
    ast: Ast,
    token_source: TokenSource,
    arena: Allocator, // TODO: Store an actual ArenaAllocator
    sequence: Ast.Sequence,

    pub const Item = struct {
        index: Ast.Size,
        tag: Component.Tag,
    };

    pub fn init(ast: Ast, token_source: TokenSource, arena: Allocator) Source {
        return .{ .ast = ast, .token_source = token_source, .arena = arena, .sequence = undefined };
    }

    fn next(source: *Source) ?Item {
        const index = source.sequence.nextSkipSpaces(source.ast) orelse return null;
        const tag = source.ast.tag(index);
        return .{ .index = index, .tag = tag };
    }
};

fn genericLength(source: *Source, comptime Type: type, index: Ast.Size) ?Type {
    var children = source.ast.children(index);
    const unit_index = children.nextSkipSpaces(source.ast).?;

    const number = source.ast.extra(index).number;
    const unit = source.ast.extra(unit_index).unit orelse return null;
    return switch (unit) {
        .px => .{ .px = number },
    };
}

fn genericPercentage(source: *Source, comptime Type: type, index: Ast.Size) Type {
    const value = source.ast.extra(index).number;
    return .{ .percentage = value };
}

pub fn keyword(source: *Source, comptime Type: type, kvs: []const TokenSource.KV(Type)) ?Type {
    const item = source.next() orelse return null;
    if (item.tag == .token_ident) {
        const location = source.ast.location(item.index);
        if (source.token_source.mapIdentifier(location, Type, kvs)) |result| return result;
    }

    source.sequence.reset(item.index);
    return null;
}

pub fn integer(source: *Source) ?i32 {
    const item = source.next() orelse return null;
    if (item.tag == .token_integer) {
        return source.ast.extra(item.index).integer;
    }

    source.sequence.reset(item.index);
    return null;
}

// Spec: CSS 2.2
// <length>
pub fn length(source: *Source, comptime Type: type) ?Type {
    const item = source.next() orelse return null;
    if (item.tag == .token_dimension) {
        if (genericLength(source, Type, item.index)) |result| return result;
    }

    source.sequence.reset(item.index);
    return null;
}

// Spec: CSS 2.2
// <percentage>
pub fn percentage(source: *Source, comptime Type: type) ?Type {
    const item = source.next() orelse return null;
    if (item.tag == .token_percentage) {
        return genericPercentage(source, Type, item.index);
    } else {
        source.sequence.reset(item.index);
        return null;
    }
}

// Spec: CSS 2.2
// <length> | <percentage>
pub fn lengthPercentage(source: *Source, comptime Type: type) ?Type {
    return length(source, Type) orelse percentage(source, Type);
}

// Spec: CSS 2.2
// <length> | <percentage> | auto
pub fn lengthPercentageAuto(source: *Source, comptime Type: type) ?Type {
    return length(source, Type) orelse percentage(source, Type) orelse keyword(source, Type, &.{.{ "auto", .auto }});
}

// Spec: CSS 2.2
// <length> | <percentage> | none
pub fn lengthPercentageNone(source: *Source, comptime Type: type) ?Type {
    return length(source, Type) orelse percentage(source, Type) orelse keyword(source, Type, &.{.{ "none", .none }});
}

pub fn cssWideKeyword(source: *Source) ?types.CssWideKeyword {
    return keyword(source, types.CssWideKeyword, &.{
        .{ "initial", .initial },
        .{ "inherit", .inherit },
        .{ "unset", .unset },
    });
}

pub fn string(source: *Source) ?[]const u8 {
    const item = source.next() orelse return null;
    if (item.tag == .token_string) {
        const location = source.ast.location(item.index);
        return source.token_source.copyString(location, source.arena) catch std.debug.panic("TODO: Allocation failure", .{});
    }

    source.sequence.reset(item.index);
    return null;
}

pub fn hashValue(source: *Source) ?[]const u8 {
    const item = source.next() orelse return null;
    switch (item.tag) {
        .token_hash_id, .token_hash_unrestricted => {
            const location = source.ast.location(item.index);
            return source.token_source.copyHash(location, source.arena) catch std.debug.panic("TODO: Allocation failure", .{});
        },
        else => {},
    }
    source.sequence.reset(item.index);
    return null;
}

/// Spec: CSS Color Level 4
/// Syntax: <color> = <color-base> | currentColor | <system-color>
///         <color-base> = <hex-color> | <color-function> | <named-color> | transparent
pub fn color(source: *Source) ?types.Color {
    // TODO: Named colors, system colors, color functions
    const reset_point = source.sequence.start;
    if (keyword(source, types.Color, &.{
        .{ "currentColor", .current_color },
        .{ "transparent", .transparent },
    })) |value| {
        return value;
    } else if (hashValue(source)) |hash| {
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

    source.sequence.reset(reset_point);
    return null;
}

// Syntax:
// <url> = <url()> | <src()>
// <url()> = url( <string> <url-modifier>* ) | <url-token>
// <src()> = src( <string> <url-modifier>* )
pub fn url(source: *Source) ?[]const u8 {
    const item = source.next() orelse return null;
    switch (item.tag) {
        .token_url => {
            const location = source.ast.location(item.index);
            return source.token_source.copyUrl(location, source.arena) catch std.debug.panic("TODO: Allocation failure", .{});
        },
        .function => blk: {
            const location = source.ast.location(item.index);
            _ = source.token_source.mapIdentifier(location, void, &.{
                .{ "url", {} },
                .{ "src", {} },
            }) orelse break :blk;

            const sequence = source.sequence;
            defer source.sequence = sequence;
            source.sequence = source.ast.children(item.index);

            const str = string(source) orelse break :blk;
            if (source.next()) |_| {
                // The URL may have contained URL modifiers, but these are not supported by zss.

                // TODO: Maybe unnecessary
                source.arena.free(str);

                break :blk;
            }
            return str;
        },
        else => {},
    }

    source.sequence.reset(item.index);
    return null;
}
