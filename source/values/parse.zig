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

    pub const ComponentRange = struct {
        index: Ast.Size,
        end: Ast.Size,
    };

    pub const Value = union(enum) {
        unknown,
        keyword,
        integer: i32,
        percentage: f32,
        dimension: Dimension,
        hash: Allocator.Error![]const u8,
        function,
        url: Allocator.Error!?[]const u8,

        pub const Dimension = struct {
            number: f32,
            unit: ?Unit,
        };
    };

    pub const Type = std.meta.Tag(Value);

    pub const Item = struct {
        index: Ast.Size,
        type: Type,
    };

    pub fn init(ast: Ast, token_source: TokenSource, arena: Allocator) Source {
        return .{ .ast = ast, .token_source = token_source, .arena = arena, .sequence = undefined };
    }

    fn getType(source: Source, tag: Component.Tag, index: Ast.Size) Type {
        return switch (tag) {
            .token_ident => .keyword,
            .token_integer => .integer,
            .token_percentage => .percentage,
            .token_dimension => .dimension,
            .token_hash_id, .token_hash_unrestricted => .hash,
            .token_url => .url,
            .function => blk: {
                const location = source.ast.location(index);
                if (source.token_source.identifierEqlIgnoreCase(location, "url"))
                    break :blk .url
                else
                    break :blk .function;
            },
            else => .unknown,
        };
    }

    pub fn next(source: *Source) ?Item {
        const index = source.sequence.nextDeclComponent(source.ast) orelse return null;
        const tag = source.ast.tag(index);
        const @"type" = source.getType(tag, index);
        return Item{ .index = index, .type = @"type" };
    }

    pub fn expect(source: *Source, @"type": Type) ?Item {
        const item = source.next() orelse return null;
        if (item.type == @"type") {
            return item;
        } else {
            source.sequence.reset(item.index);
            return null;
        }
    }

    pub fn value(source: *Source, comptime @"type": Type, index: Ast.Size) std.meta.fieldInfo(Value, @"type").type {
        const tag = source.ast.tag(index);
        std.debug.assert(source.getType(tag, index) == @"type");
        switch (comptime @"type") {
            .keyword => @compileError("use source.mapKeyword() instead"),
            .integer => return source.ast.extra(index).integer,
            .percentage => return source.ast.extra(index).number,
            .dimension => {
                var children = source.ast.children(index);
                const unit_index = children.nextSkipSpaces(source.ast).?;

                const number = source.ast.extra(index).number;
                const unit = source.ast.extra(unit_index).unit;
                return Value.Dimension{ .number = number, .unit = unit };
            },
            .hash => {
                const location = source.ast.location(index);
                return try source.token_source.copyHash(location, source.arena);
            },
            .function => @compileError("TODO: Function values"),
            .url => {
                switch (tag) {
                    .token_url => {
                        const location = source.ast.location(index);
                        return try source.token_source.copyUrl(location, source.arena);
                    },
                    .function => {
                        var function_value = source.ast.children(index);
                        const string = function_value.nextSkipSpaces(source.ast) orelse return null;

                        if (source.ast.tag(string) != .token_string) return null;
                        // NOTE: No URL modifiers are supported
                        if (!function_value.empty()) return null;

                        const location = source.ast.location(string);
                        return try source.token_source.copyString(location, source.arena);
                    },
                    else => unreachable,
                }
            },
            .unknown => @compileError("No value for type 'unknown'"),
        }
    }

    /// Given that `index` belongs to a keyword value, map that keyword to the value given in `kvs`,
    /// using case-insensitive matching. If there was no match, null is returned.
    pub fn mapKeyword(source: Source, index: Ast.Size, comptime ResultType: type, kvs: []const TokenSource.KV(ResultType)) ?ResultType {
        const tag = source.ast.tag(index);
        std.debug.assert(source.getType(tag, index) == .keyword);
        const location = source.ast.location(index);
        return source.token_source.mapIdentifier(location, ResultType, kvs);
    }
};

pub fn parseSingleKeyword(source: *Source, comptime Type: type, kvs: []const TokenSource.KV(Type)) ?Type {
    const keyword = source.next() orelse return null;

    if (keyword.type == .keyword) {
        if (source.mapKeyword(keyword.index, Type, kvs)) |value| {
            return value;
        }
    }

    source.sequence.reset(keyword.index);
    return null;
}

pub fn genericLength(comptime Type: type, dimension: Source.Value.Dimension) ?Type {
    const number = dimension.number;
    const unit = dimension.unit orelse return null;
    return switch (unit) {
        .px => .{ .px = number },
    };
}

pub fn genericLengthPercentage(comptime Type: type, value: anytype) ?Type {
    return switch (@TypeOf(value)) {
        f32 => .{ .percentage = value },
        Source.Value.Dimension => genericLength(Type, value),
        else => @compileError("Invalid type"),
    };
}

pub fn cssWideKeyword(source: *Source) ?types.CssWideKeyword {
    return parseSingleKeyword(source, types.CssWideKeyword, &.{
        .{ "initial", .initial },
        .{ "inherit", .inherit },
        .{ "unset", .unset },
    });
}

/// Spec: CSS Color Level 4
/// Syntax: <color> = <color-base> | currentColor | <system-color>
///         <color-base> = <hex-color> | <color-function> | <named-color> | transparent
pub fn color(source: *Source) ?types.Color {
    // TODO: Named colors, system colors, color functions
    const item = source.next() orelse return null;

    switch (item.type) {
        .keyword => {
            if (source.mapKeyword(item.index, types.Color, &.{
                .{ "currentColor", .current_color },
                .{ "transparent", .transparent },
            })) |value| {
                return value;
            }
        },
        .hash => hash: {
            const hash = source.value(.hash, item.index) catch std.debug.panic("TODO: Allocation failure", .{});
            switch (hash.len) {
                3 => {
                    const rgba = blk: {
                        var result: u32 = 0;
                        for (hash, 0..) |codepoint, i| {
                            const digit: u32 = zss.unicode.hexDigitToNumber(codepoint) catch break :hash;
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
        },
        else => {},
    }

    source.sequence.reset(item.index);
    return null;
}
