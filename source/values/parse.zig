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
    ast: Ast.Slice,
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
        function,
        url: Allocator.Error!?[]const u8,

        pub const Dimension = struct {
            number: f32,
            unit: Unit,
        };
    };

    pub const Type = std.meta.Tag(Value);

    pub const Item = struct {
        index: Ast.Size,
        type: Type,
    };

    pub fn init(ast: Ast.Slice, token_source: TokenSource, arena: Allocator) Source {
        return .{ .ast = ast, .token_source = token_source, .arena = arena, .sequence = undefined };
    }

    fn getType(source: Source, tag: Component.Tag, index: Ast.Size) Type {
        return switch (tag) {
            .token_ident => .keyword,
            .token_integer => .integer,
            .token_percentage => .percentage,
            .token_dimension => .dimension,
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
            .integer => return source.ast.extra(index).integer(),
            .percentage => return source.ast.extra(index).number(),
            .dimension => {
                var children = source.ast.children(index);
                const unit_index = children.next(source.ast).?;

                const number = source.ast.extra(index).number();
                const unit = source.ast.extra(unit_index).unit();
                return Value.Dimension{ .number = number, .unit = unit };
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
                        const string = function_value.next(source.ast) orelse return null;

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

/// Maps a value type to the function that will be used to parse it.
pub fn typeToParseFn(comptime Type: type) switch (Type) {
    types.Display => @TypeOf(display),
    types.Position => @TypeOf(position),
    types.Float => @TypeOf(float),
    types.ZIndex => @TypeOf(zIndex),
    types.LengthPercentage => @TypeOf(lengthPercentage),
    types.LengthPercentageAuto => @TypeOf(lengthPercentageAuto),
    types.BorderWidth => @TypeOf(borderWidth),
    types.MaxSize => @TypeOf(maxSize),
    types.BackgroundImage => @TypeOf(backgroundImage),
    types.BackgroundRepeat => @TypeOf(backgroundRepeat),
    types.BackgroundAttachment => @TypeOf(backgroundAttachment),
    types.BackgroundPosition => @TypeOf(backgroundPosition),
    types.BackgroundClip => @TypeOf(backgroundClip),
    types.BackgroundOrigin => @TypeOf(backgroundOrigin),
    types.BackgroundSize => @TypeOf(backgroundSize),
    else => @compileError("Unknown CSS value type: " ++ @typeName(Type)),
} {
    return switch (Type) {
        types.Display => display,
        types.Position => position,
        types.Float => float,
        types.ZIndex => zIndex,
        types.LengthPercentage => lengthPercentage,
        types.LengthPercentageAuto => lengthPercentageAuto,
        types.BorderWidth => borderWidth,
        types.MaxSize => maxSize,
        types.BackgroundImage => backgroundImage,
        types.BackgroundRepeat => backgroundRepeat,
        types.BackgroundAttachment => backgroundAttachment,
        types.BackgroundPosition => backgroundPosition,
        types.BackgroundClip => backgroundClip,
        types.BackgroundOrigin => backgroundOrigin,
        types.BackgroundSize => backgroundSize,
        else => @compileError("Unknown CSS value type: " ++ @typeName(Type)),
    };
}

fn testParsing(comptime T: type, input: []const u8, expected: ?T, is_complete: bool) !void {
    const allocator = std.testing.allocator;

    const token_source = try TokenSource.init(input);
    var tree = try zss.syntax.parse.parseListOfComponentValues(token_source, allocator);
    defer tree.deinit(allocator);
    const slice = tree.slice();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var source = Source.init(slice, token_source, arena.allocator());
    source.sequence = slice.children(0);
    const parseFn = typeToParseFn(T);
    const actual = parseFn(&source) catch |err| switch (err) {
        error.ParseError => error.ParseError,
        else => |e| return e,
    };
    if (expected) |expected_payload| {
        if (actual) |actual_payload| {
            if (is_complete) {
                try std.testing.expect(source.sequence.empty());
            } else {
                try std.testing.expect(!source.sequence.empty());
            }
            errdefer std.debug.print("Expected: {}\nActual: {}\n", .{ expected_payload, actual_payload });
            return switch (T) {
                types.BackgroundImage => expected_payload.expectEqualBackgroundImages(actual_payload),
                else => std.testing.expectEqual(expected_payload, actual_payload),
            };
        } else |_| {
            return error.TestExpectedEqual;
        }
    } else {
        errdefer std.debug.print("Expected: null, found: {}\n", .{actual catch unreachable});
        return std.testing.expect(std.meta.isError(actual));
    }
}

test "css value parsing" {
    try testParsing(types.Display, "block", .block, true);
    try testParsing(types.Display, "inline", .@"inline", true);

    try testParsing(types.Position, "static", .static, true);

    try testParsing(types.Float, "left", .left, true);
    try testParsing(types.Float, "right", .right, true);
    try testParsing(types.Float, "none", .none, true);

    try testParsing(types.ZIndex, "42", .{ .integer = 42 }, true);
    try testParsing(types.ZIndex, "-42", .{ .integer = -42 }, true);
    try testParsing(types.ZIndex, "auto", .auto, true);
    try testParsing(types.ZIndex, "9999999999999999", .{ .integer = 0 }, true);
    try testParsing(types.ZIndex, "-9999999999999999", .{ .integer = 0 }, true);

    try testParsing(types.LengthPercentage, "5px", .{ .px = 5 }, true);
    try testParsing(types.LengthPercentage, "5%", .{ .percentage = 5 }, true);
    try testParsing(types.LengthPercentage, "5", null, true);
    try testParsing(types.LengthPercentage, "auto", null, true);

    try testParsing(types.LengthPercentageAuto, "5px", .{ .px = 5 }, true);
    try testParsing(types.LengthPercentageAuto, "5%", .{ .percentage = 5 }, true);
    try testParsing(types.LengthPercentageAuto, "5", null, true);
    try testParsing(types.LengthPercentageAuto, "auto", .auto, true);

    try testParsing(types.MaxSize, "5px", .{ .px = 5 }, true);
    try testParsing(types.MaxSize, "5%", .{ .percentage = 5 }, true);
    try testParsing(types.MaxSize, "5", null, true);
    try testParsing(types.MaxSize, "auto", null, true);
    try testParsing(types.MaxSize, "none", .none, true);

    try testParsing(types.BorderWidth, "5px", .{ .px = 5 }, true);
    try testParsing(types.BorderWidth, "thin", .thin, true);
    try testParsing(types.BorderWidth, "medium", .medium, true);
    try testParsing(types.BorderWidth, "thick", .thick, true);

    try testParsing(types.BackgroundImage, "none", .none, true);
    try testParsing(types.BackgroundImage, "url(abcd)", .{ .url = "abcd" }, true);
    try testParsing(types.BackgroundImage, "url( \"abcd\" )", .{ .url = "abcd" }, true);
    try testParsing(types.BackgroundImage, "invalid", null, true);

    try testParsing(types.BackgroundRepeat, "repeat-x", .{ .repeat = .{ .x = .repeat, .y = .no_repeat } }, true);
    try testParsing(types.BackgroundRepeat, "repeat-y", .{ .repeat = .{ .x = .no_repeat, .y = .repeat } }, true);
    try testParsing(types.BackgroundRepeat, "repeat", .{ .repeat = .{ .x = .repeat, .y = .repeat } }, true);
    try testParsing(types.BackgroundRepeat, "space", .{ .repeat = .{ .x = .space, .y = .space } }, true);
    try testParsing(types.BackgroundRepeat, "round", .{ .repeat = .{ .x = .round, .y = .round } }, true);
    try testParsing(types.BackgroundRepeat, "no-repeat", .{ .repeat = .{ .x = .no_repeat, .y = .no_repeat } }, true);
    try testParsing(types.BackgroundRepeat, "invalid", null, true);
    try testParsing(types.BackgroundRepeat, "repeat space", .{ .repeat = .{ .x = .repeat, .y = .space } }, true);
    try testParsing(types.BackgroundRepeat, "round no-repeat", .{ .repeat = .{ .x = .round, .y = .no_repeat } }, true);
    try testParsing(types.BackgroundRepeat, "invalid space", null, true);
    try testParsing(types.BackgroundRepeat, "space invalid", .{ .repeat = .{ .x = .space, .y = .space } }, false);
    try testParsing(types.BackgroundRepeat, "repeat-x invalid", .{ .repeat = .{ .x = .repeat, .y = .no_repeat } }, false);

    try testParsing(types.BackgroundAttachment, "scroll", .scroll, true);
    try testParsing(types.BackgroundAttachment, "fixed", .fixed, true);
    try testParsing(types.BackgroundAttachment, "local", .local, true);

    try testParsing(types.BackgroundPosition, "center", .{ .position = .{
        .x = .{ .side = .center, .offset = .{ .percentage = 0 } },
        .y = .{ .side = .center, .offset = .{ .percentage = 0 } },
    } }, true);
    try testParsing(types.BackgroundPosition, "left", .{ .position = .{
        .x = .{ .side = .start, .offset = .{ .percentage = 0 } },
        .y = .{ .side = .center, .offset = .{ .percentage = 0 } },
    } }, true);
    try testParsing(types.BackgroundPosition, "top", .{ .position = .{
        .x = .{ .side = .center, .offset = .{ .percentage = 0 } },
        .y = .{ .side = .start, .offset = .{ .percentage = 0 } },
    } }, true);
    try testParsing(types.BackgroundPosition, "50%", .{ .position = .{
        .x = .{ .side = .start, .offset = .{ .percentage = 50 } },
        .y = .{ .side = .center, .offset = .{ .percentage = 0 } },
    } }, true);
    try testParsing(types.BackgroundPosition, "50px", .{ .position = .{
        .x = .{ .side = .start, .offset = .{ .px = 50 } },
        .y = .{ .side = .center, .offset = .{ .percentage = 0 } },
    } }, true);
    try testParsing(types.BackgroundPosition, "left top", .{ .position = .{
        .x = .{ .side = .start, .offset = .{ .percentage = 0 } },
        .y = .{ .side = .start, .offset = .{ .percentage = 0 } },
    } }, true);
    try testParsing(types.BackgroundPosition, "left center", .{ .position = .{
        .x = .{ .side = .start, .offset = .{ .percentage = 0 } },
        .y = .{ .side = .center, .offset = .{ .percentage = 0 } },
    } }, true);
    try testParsing(types.BackgroundPosition, "center right", .{ .position = .{
        .x = .{ .side = .center, .offset = .{ .percentage = 0 } },
        .y = .{ .side = .center, .offset = .{ .percentage = 0 } },
    } }, false);
    try testParsing(types.BackgroundPosition, "50px right", .{ .position = .{
        .x = .{ .side = .start, .offset = .{ .px = 50 } },
        .y = .{ .side = .center, .offset = .{ .percentage = 0 } },
    } }, false);
    try testParsing(types.BackgroundPosition, "right center", .{ .position = .{
        .x = .{ .side = .end, .offset = .{ .percentage = 0 } },
        .y = .{ .side = .center, .offset = .{ .percentage = 0 } },
    } }, true);
    try testParsing(types.BackgroundPosition, "center center 50%", .{ .position = .{
        .x = .{ .side = .center, .offset = .{ .percentage = 0 } },
        .y = .{ .side = .center, .offset = .{ .percentage = 0 } },
    } }, false);
    try testParsing(types.BackgroundPosition, "left center 20px", .{ .position = .{
        .x = .{ .side = .start, .offset = .{ .percentage = 0 } },
        .y = .{ .side = .center, .offset = .{ .percentage = 0 } },
    } }, false);
    try testParsing(types.BackgroundPosition, "left 20px bottom 50%", .{ .position = .{
        .x = .{ .side = .start, .offset = .{ .px = 20 } },
        .y = .{ .side = .end, .offset = .{ .percentage = 50 } },
    } }, true);
    try testParsing(types.BackgroundPosition, "center bottom 50%", .{ .position = .{
        .x = .{ .side = .center, .offset = .{ .percentage = 0 } },
        .y = .{ .side = .end, .offset = .{ .percentage = 50 } },
    } }, true);
    try testParsing(types.BackgroundPosition, "bottom 50% center", .{ .position = .{
        .x = .{ .side = .center, .offset = .{ .percentage = 0 } },
        .y = .{ .side = .end, .offset = .{ .percentage = 50 } },
    } }, true);
    try testParsing(types.BackgroundPosition, "bottom 50% left 20px", .{ .position = .{
        .x = .{ .side = .start, .offset = .{ .px = 20 } },
        .y = .{ .side = .end, .offset = .{ .percentage = 50 } },
    } }, true);

    try testParsing(types.BackgroundClip, "border-box", .border_box, true);
    try testParsing(types.BackgroundClip, "padding-box", .padding_box, true);
    try testParsing(types.BackgroundClip, "content-box", .content_box, true);

    try testParsing(types.BackgroundOrigin, "border-box", .border_box, true);
    try testParsing(types.BackgroundOrigin, "padding-box", .padding_box, true);
    try testParsing(types.BackgroundOrigin, "content-box", .content_box, true);

    try testParsing(types.BackgroundSize, "contain", .contain, true);
    try testParsing(types.BackgroundSize, "cover", .cover, true);
    try testParsing(types.BackgroundSize, "auto", .{ .size = .{ .width = .auto, .height = .auto } }, true);
    try testParsing(types.BackgroundSize, "auto auto", .{ .size = .{ .width = .auto, .height = .auto } }, true);
    try testParsing(types.BackgroundSize, "5px", .{ .size = .{ .width = .{ .px = 5 }, .height = .{ .px = 5 } } }, true);
    try testParsing(types.BackgroundSize, "5px 5%", .{ .size = .{ .width = .{ .px = 5 }, .height = .{ .percentage = 5 } } }, true);
}

pub fn parseSingleKeyword(source: *Source, comptime Type: type, kvs: []const TokenSource.KV(Type)) !Type {
    const keyword = source.next() orelse return error.ParseError;
    errdefer source.sequence.reset(keyword.index);

    if (keyword.type == .keyword) {
        if (source.mapKeyword(keyword.index, Type, kvs)) |value| {
            return value;
        }
    }

    return error.ParseError;
}

pub fn genericLength(comptime Type: type, dimension: Source.Value.Dimension) !Type {
    const number = dimension.number;
    return switch (dimension.unit) {
        .unrecognized => error.ParseError,
        .px => .{ .px = number },
    };
}

pub fn genericLengthPercentage(comptime Type: type, value: anytype) !Type {
    return switch (@TypeOf(value)) {
        f32 => .{ .percentage = value },
        Source.Value.Dimension => genericLength(Type, value),
        else => @compileError("Invalid type"),
    };
}

pub fn cssWideKeyword(source: *Source) !types.CssWideKeyword {
    return parseSingleKeyword(source, types.CssWideKeyword, &.{
        .{ "initial", .initial },
        .{ "inherit", .inherit },
        .{ "unset", .unset },
    });
}

// Spec: CSS 2.2
// inline | block | list-item | inline-block | table | inline-table | table-row-group | table-header-group
// | table-footer-group | table-row | table-column-group | table-column | table-cell | table-caption | none
pub fn display(source: *Source) !types.Display {
    return parseSingleKeyword(source, types.Display, &.{
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
pub fn position(source: *Source) !types.Position {
    return parseSingleKeyword(source, types.Position, &.{
        .{ "static", .static },
        .{ "relative", .relative },
        .{ "absolute", .absolute },
        .{ "fixed", .fixed },
    });
}

// Spec: CSS 2.2
// left | right | none
pub fn float(source: *Source) !types.Float {
    return parseSingleKeyword(source, types.Float, &.{
        .{ "left", .left },
        .{ "right", .right },
        .{ "none", .none },
    });
}

// Spec: CSS 2.2
// auto | <integer>
pub fn zIndex(source: *Source) !types.ZIndex {
    const auto_or_int = source.next() orelse return error.ParseError;
    errdefer source.sequence.reset(auto_or_int.index);
    switch (auto_or_int.type) {
        .integer => return types.ZIndex{ .integer = source.value(.integer, auto_or_int.index) },
        .keyword => return source.mapKeyword(auto_or_int.index, types.ZIndex, &.{
            .{ "auto", .auto },
        }) orelse error.ParseError,
        else => return error.ParseError,
    }
}

// Spec: CSS 2.2
// <length> | <percentage>
pub fn lengthPercentage(source: *Source) !types.LengthPercentage {
    const item = source.next() orelse return error.ParseError;
    errdefer source.sequence.reset(item.index);
    switch (item.type) {
        .dimension => return genericLength(types.LengthPercentage, source.value(.dimension, item.index)),
        .percentage => return .{ .percentage = source.value(.percentage, item.index) },
        else => return error.ParseError,
    }
}

// Spec: CSS 2.2
// <length> | <percentage> | auto
pub fn lengthPercentageAuto(source: *Source) !types.LengthPercentageAuto {
    const item = source.next() orelse return error.ParseError;
    errdefer source.sequence.reset(item.index);
    switch (item.type) {
        .dimension => return genericLength(types.LengthPercentageAuto, source.value(.dimension, item.index)),
        .percentage => return .{ .percentage = source.value(.percentage, item.index) },
        .keyword => return source.mapKeyword(item.index, types.LengthPercentageAuto, &.{
            .{ "auto", .auto },
        }) orelse error.ParseError,
        else => return error.ParseError,
    }
}

// Spec: CSS 2.2
// <length> | <percentage> | none
pub fn maxSize(source: *Source) !types.MaxSize {
    const item = source.next() orelse return error.ParseError;
    errdefer source.sequence.reset(item.index);
    switch (item.type) {
        .dimension => return genericLength(types.MaxSize, source.value(.dimension, item.index)),
        .percentage => return .{ .percentage = source.value(.percentage, item.index) },
        .keyword => return source.mapKeyword(item.index, types.MaxSize, &.{
            .{ "none", .none },
        }) orelse error.ParseError,
        else => return error.ParseError,
    }
}

// Spec: CSS 2.2
// Syntax: <length> | thin | medium | thick
pub fn borderWidth(source: *Source) !types.BorderWidth {
    const item = source.next() orelse return error.ParseError;
    errdefer source.sequence.reset(item.index);
    switch (item.type) {
        .dimension => return genericLength(types.BorderWidth, source.value(.dimension, item.index)),
        .keyword => return source.mapKeyword(item.index, types.BorderWidth, &.{
            .{ "thin", .thin },
            .{ "medium", .medium },
            .{ "thick", .thick },
        }) orelse error.ParseError,
        else => return error.ParseError,
    }
}

// Spec: CSS Backgrounds and Borders Level 3
// Syntax: <image> | none
//         <image> = <url> | <gradient>
//         <gradient> = <linear-gradient()> | <repeating-linear-gradient()> | <radial-gradient()> | <repeating-radial-gradient()>
pub fn backgroundImage(source: *Source) !types.BackgroundImage {
    const item = source.next() orelse return error.ParseError;
    errdefer source.sequence.reset(item.index);
    switch (item.type) {
        .url => {
            const url = (try source.value(.url, item.index)) orelse return error.ParseError;
            return .{ .url = url };
        },
        .function => {
            // TODO: parse an <image>
            return error.ParseError;
        },
        .keyword => return source.mapKeyword(item.index, types.BackgroundImage, &.{
            .{ "none", .none },
        }) orelse error.ParseError,
        else => return error.ParseError,
    }
}

// Spec: CSS Backgrounds and Borders Level 3
// Syntax: <repeat-style> = repeat-x | repeat-y | [repeat | space | round | no-repeat]{1,2}
pub fn backgroundRepeat(source: *Source) !types.BackgroundRepeat {
    // TODO: reset point incorrect
    const keyword1 = source.expect(.keyword) orelse return error.ParseError;
    errdefer source.sequence.reset(keyword1.index);
    if (source.mapKeyword(keyword1.index, types.BackgroundRepeat.Repeat, &.{
        .{ "repeat-x", .{ .x = .repeat, .y = .no_repeat } },
        .{ "repeat-y", .{ .x = .no_repeat, .y = .repeat } },
    })) |value| {
        return .{ .repeat = value };
    }

    const Style = types.BackgroundRepeat.Style;
    const map = comptime &[_]TokenSource.KV(Style){
        .{ "repeat", .repeat },
        .{ "space", .space },
        .{ "round", .round },
        .{ "no-repeat", .no_repeat },
    };
    const x = source.mapKeyword(keyword1.index, Style, map) orelse return error.ParseError;
    const y = parseSingleKeyword(source, Style, map) catch x;
    return .{ .repeat = .{ .x = x, .y = y } };
}

// Spec: CSS Backgrounds and Borders Level 3
// Syntax: <attachment> = scroll | fixed | local
pub fn backgroundAttachment(source: *Source) !types.BackgroundAttachment {
    return parseSingleKeyword(source, types.BackgroundAttachment, &.{
        .{ "scroll", .scroll },
        .{ "fixed", .fixed },
        .{ "local", .local },
    });
}

const bg_position = struct {
    const Side = types.BackgroundPosition.Side;
    const Offset = types.BackgroundPosition.Offset;
    const Axis = enum { x, y, either };

    const KeywordMapValue = struct { axis: Axis, side: Side };
    // zig fmt: off
    const keyword_map = &[_]TokenSource.KV(KeywordMapValue){
        .{ "center", .{ .axis = .either, .side = .center } },
        .{ "left",   .{ .axis = .x,      .side = .start  } },
        .{ "right",  .{ .axis = .x,      .side = .end    } },
        .{ "top",    .{ .axis = .y,      .side = .start  } },
        .{ "bottom", .{ .axis = .y,      .side = .end    } },
    };
    // zig fmt: on

    const Info = struct {
        axis: Axis,
        side: Side,
        offset: Offset,
    };

    const ResultTuple = struct {
        bg_position: types.BackgroundPosition,
        num_items_used: u3,
    };
};

/// Spec: CSS Backgrounds and Borders Level 3
/// Syntax: <bg-position> = [ left | center | right | top | bottom | <length-percentage> ]
///                       |
///                         [ left | center | right | <length-percentage> ]
///                         [ top | center | bottom | <length-percentage> ]
///                       |
///                         [ center | [ left | right ] <length-percentage>? ] &&
///                         [ center | [ top | bottom ] <length-percentage>? ]
pub fn backgroundPosition(source: *Source) !types.BackgroundPosition {
    const first_item = source.next() orelse return error.ParseError;
    errdefer source.sequence.reset(first_item.index);

    var items: [4]Source.Item = .{ first_item, undefined, undefined, undefined };
    for (items[1..]) |*item| {
        item.* = source.next() orelse .{ .type = .unknown, .index = source.sequence.end };
    }

    const result =
        backgroundPosition3Or4Values(items, source) catch
        backgroundPosition1Or2Values(items, source) catch
        return error.ParseError;

    if (result.num_items_used < 4) {
        source.sequence.reset(items[result.num_items_used].index);
    }
    return result.bg_position;
}

/// Spec: CSS Backgrounds and Borders Level 3
/// Syntax: [ center | [ left | right ] <length-percentage>? ] &&
///         [ center | [ top | bottom ] <length-percentage>? ]
fn backgroundPosition3Or4Values(items: [4]Source.Item, source: *Source) !bg_position.ResultTuple {
    var num_items_used: u3 = 0;
    const first = try backgroundPosition3Or4ValuesInfo(items, &num_items_used, source);
    const second = try backgroundPosition3Or4ValuesInfo(items, &num_items_used, source);
    if (num_items_used < 3) return error.ParseError;

    var x_axis: *const bg_position.Info = undefined;
    var y_axis: *const bg_position.Info = undefined;

    switch (first.axis) {
        .x => {
            x_axis = &first;
            y_axis = switch (second.axis) {
                .x => return error.ParseError,
                .y => &second,
                .either => &second,
            };
        },
        .y => {
            x_axis = switch (second.axis) {
                .x => &second,
                .y => return error.ParseError,
                .either => &second,
            };
            y_axis = &first;
        },
        .either => switch (second.axis) {
            .x => {
                x_axis = &second;
                y_axis = &first;
            },
            .y, .either => {
                x_axis = &first;
                y_axis = &second;
            },
        },
    }

    const result = types.BackgroundPosition{
        .position = .{
            .x = .{
                .side = x_axis.side,
                .offset = x_axis.offset,
            },
            .y = .{
                .side = y_axis.side,
                .offset = y_axis.offset,
            },
        },
    };
    return .{ .bg_position = result, .num_items_used = num_items_used };
}

fn backgroundPosition3Or4ValuesInfo(items: [4]Source.Item, num_items_used: *u3, source: *Source) !bg_position.Info {
    const side_item = items[num_items_used.*];
    if (side_item.type != .keyword) return error.ParseError;
    const map_value = source.mapKeyword(side_item.index, bg_position.KeywordMapValue, bg_position.keyword_map) orelse return error.ParseError;

    var offset: bg_position.Offset = undefined;
    switch (map_value.side) {
        .center => {
            num_items_used.* += 1;
            offset = .{ .percentage = 0 };
        },
        else => {
            const offset_item = items[num_items_used.* + 1];
            switch (offset_item.type) {
                inline .dimension, .percentage => |@"type"| {
                    if (genericLengthPercentage(bg_position.Offset, source.value(@"type", offset_item.index))) |value| {
                        num_items_used.* += 2;
                        offset = value;
                    } else |_| {
                        num_items_used.* += 1;
                        offset = .{ .percentage = 0 };
                    }
                },
                else => {
                    num_items_used.* += 1;
                    offset = .{ .percentage = 0 };
                },
            }
        },
    }

    return .{ .axis = map_value.axis, .side = map_value.side, .offset = offset };
}

/// Spec: CSS Backgrounds and Borders Level 3
/// Syntax: [ left | center | right | top | bottom | <length-percentage> ]
///       |
///         [ left | center | right | <length-percentage> ]
///         [ top | center | bottom | <length-percentage> ]
fn backgroundPosition1Or2Values(items: [4]Source.Item, source: *Source) !bg_position.ResultTuple {
    const first = try backgroundPosition1Or2ValuesInfo(items[0], source);
    twoValues: {
        if (first.axis == .y) break :twoValues;
        const second = backgroundPosition1Or2ValuesInfo(items[1], source) catch break :twoValues;
        if (second.axis == .x) break :twoValues;

        const result = types.BackgroundPosition{
            .position = .{
                .x = .{
                    .side = first.side,
                    .offset = first.offset,
                },
                .y = .{
                    .side = second.side,
                    .offset = second.offset,
                },
            },
        };
        return .{ .bg_position = result, .num_items_used = 2 };
    }

    var result = types.BackgroundPosition{
        .position = .{
            .x = .{
                .side = first.side,
                .offset = first.offset,
            },
            .y = .{
                .side = .center,
                .offset = .{ .percentage = 0 },
            },
        },
    };
    if (first.axis == .y) {
        std.mem.swap(types.BackgroundPosition.SideOffset, &result.position.x, &result.position.y);
    }
    return .{ .bg_position = result, .num_items_used = 1 };
}

fn backgroundPosition1Or2ValuesInfo(item: Source.Item, source: *Source) !bg_position.Info {
    switch (item.type) {
        .keyword => {
            const map_value = source.mapKeyword(item.index, bg_position.KeywordMapValue, bg_position.keyword_map) orelse return error.ParseError;
            return .{ .axis = map_value.axis, .side = map_value.side, .offset = .{ .percentage = 0 } };
        },
        inline .dimension, .percentage => |@"type"| {
            const offset = try genericLengthPercentage(bg_position.Offset, source.value(@"type", item.index));
            return .{ .axis = .either, .side = .start, .offset = offset };
        },
        else => return error.ParseError,
    }
}

/// Spec: CSS Backgrounds and Borders Level 3
/// Syntax: <box> = border-box | padding-box | content-box
pub fn backgroundClip(source: *Source) !types.BackgroundClip {
    return parseSingleKeyword(source, types.BackgroundClip, &.{
        .{ "border-box", .border_box },
        .{ "padding-box", .padding_box },
        .{ "content-box", .content_box },
    });
}

/// Spec: CSS Backgrounds and Borders Level 3
/// Syntax: <box> = border-box | padding-box | content-box
pub fn backgroundOrigin(source: *Source) !types.BackgroundOrigin {
    return parseSingleKeyword(source, types.BackgroundOrigin, &.{
        .{ "border-box", .border_box },
        .{ "padding-box", .padding_box },
        .{ "content-box", .content_box },
    });
}

/// Spec: CSS Backgrounds and Borders Level 3
/// Syntax: <bg-size> = [ <length-percentage [0,infinity]> | auto ]{1,2} | cover | contain
pub fn backgroundSize(source: *Source) !types.BackgroundSize {
    // TODO: reset point incorrect
    const first = source.next() orelse return error.ParseError;
    switch (first.type) {
        .keyword => {
            if (source.mapKeyword(first.index, types.BackgroundSize, &.{
                .{ "cover", .cover },
                .{ "contain", .contain },
            })) |value| return value;
        },
        else => {},
    }

    const width = try backgroundSizeOne(first, source);
    const height = blk: {
        const second = source.next() orelse break :blk width;
        const result = backgroundSizeOne(second, source) catch break :blk width;
        break :blk result;
    };
    return types.BackgroundSize{ .size = .{ .width = width, .height = height } };
}

fn backgroundSizeOne(item: Source.Item, source: *Source) !types.BackgroundSize.SizeType {
    switch (item.type) {
        inline .dimension, .percentage => |@"type"| {
            // TODO: Range checking?
            return genericLengthPercentage(types.BackgroundSize.SizeType, source.value(@"type", item.index));
        },
        .keyword => return source.mapKeyword(item.index, types.BackgroundSize.SizeType, &.{
            .{ "auto", .auto },
        }) orelse error.ParseError,
        else => return error.ParseError,
    }
}
