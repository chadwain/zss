const std = @import("std");
const Allocator = std.mem.Allocator;

const zss = @import("../../zss.zig");
const types = zss.values.types;
const Component = zss.syntax.Component;
const ComponentTree = zss.syntax.ComponentTree;
const ParserSource = zss.syntax.parse.Source;
const Utf8String = zss.util.Utf8String;

/// A source of primitive CSS values.
pub const Source = struct {
    components: ComponentTree.Slice,
    parser_source: ParserSource,
    arena: Allocator,
    end: ComponentTree.Size,
    position: ComponentTree.Size,

    pub const Value = union(enum) {
        unknown,
        keyword,
        integer: i32,
        percentage: f32,
        dimension: Dimension,
        function,
        url: Allocator.Error!?Utf8String,

        pub const Dimension = struct { number: f32, unit_position: ComponentTree.Size };
    };

    pub const Type = std.meta.Tag(Value);

    pub const Item = struct {
        position: ComponentTree.Size,
        type: Type,
    };

    fn getType(source: *const Source, pos: ComponentTree.Size, tag: Component.Tag) Type {
        return switch (tag) {
            .token_ident => .keyword,
            .token_integer => .integer,
            .token_percentage => .percentage,
            .token_dimension => .dimension,
            .token_url => .url,
            .function => blk: {
                const location = source.components.location(pos);
                if (source.parser_source.identifierEqlIgnoreCase(location, "url"))
                    break :blk .url
                else
                    break :blk .function;
            },
            else => .unknown,
        };
    }

    pub fn next(source: *Source) ?Item {
        while (source.position < source.end) {
            defer source.position = source.components.nextSibling(source.position);
            const tag = source.components.tag(source.position);
            switch (tag) {
                .token_whitespace, .token_comments => {},
                else => {
                    const @"type" = source.getType(source.position, tag);
                    return Item{ .position = source.position, .type = @"type" };
                },
            }
        } else return null;
    }

    pub fn expect(source: *Source, @"type": Type) ?Item {
        const reset = source.position;
        const item = source.next();
        if (item != null and item.?.type == @"type") {
            return item;
        } else {
            source.position = reset;
            return null;
        }
    }

    pub fn value(source: *const Source, comptime @"type": Type, pos: ComponentTree.Size) std.meta.fieldInfo(Value, @"type").type {
        const tag = source.components.tag(pos);
        std.debug.assert(source.getType(pos, tag) == @"type");
        switch (comptime @"type") {
            .keyword => @compileError("use source.mapKeyword() instead"),
            .integer => return source.components.extra(pos).integer(),
            .percentage => return source.components.extra(pos).number(),
            .dimension => {
                const number = source.components.extra(pos).number();
                const unit_position = pos + 1;
                return Value.Dimension{ .number = number, .unit_position = unit_position };
            },
            .function => @compileError("TODO: Function values"),
            .url => {
                switch (tag) {
                    .token_url => {
                        const location = source.components.location(pos);
                        var it = source.parser_source.urlTokenIterator(location);
                        var list = std.ArrayListUnmanaged(u8){};
                        // TODO: Don't bother with decoding UTF-8
                        var buffer: [4]u8 = undefined;
                        while (it.next(source.parser_source)) |codepoint| {
                            const len = std.unicode.utf8Encode(codepoint, &buffer) catch unreachable;
                            try list.appendSlice(source.arena, buffer[0..len]);
                        }
                        const bytes = try list.toOwnedSlice(source.arena);
                        return Utf8String{ .data = bytes };
                    },
                    .function => {
                        const end = source.components.nextSibling(pos);
                        // TODO: Need to allow for whitespace
                        // TODO: parsing url() functions with more than one parameter
                        if (end - pos > 2) return null;
                        const string = pos + 1;
                        if (source.components.tag(string) != .token_string) return null;

                        const location = source.components.location(string);
                        var it = source.parser_source.stringTokenIterator(location);
                        var list = std.ArrayListUnmanaged(u8){};
                        // TODO: Don't bother with decoding UTF-8
                        var buffer: [4]u8 = undefined;
                        while (it.next(source.parser_source)) |codepoint| {
                            const len = std.unicode.utf8Encode(codepoint, &buffer) catch unreachable;
                            try list.appendSlice(source.arena, buffer[0..len]);
                        }
                        const bytes = try list.toOwnedSlice(source.arena);
                        return Utf8String{ .data = bytes };
                    },
                    else => unreachable,
                }
            },
            .unknown => return {},
        }
    }

    /// Given that `pos` belongs to a keyword value, map that keyword to the value given in `kvs`,
    /// using case-insensitive matching. If there was no match, null is returned.
    pub fn mapKeyword(source: Source, pos: ComponentTree.Size, comptime ResultType: type, kvs: []const ParserSource.KV(ResultType)) ?ResultType {
        const tag = source.components.tag(pos);
        std.debug.assert(source.getType(pos, tag) == .keyword);
        const location = source.components.location(pos);
        return source.parser_source.mapIdentifier(location, ResultType, kvs);
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
        else => @compileError("Unknown CSS value type: " ++ @typeName(Type)),
    };
}

fn testParsing(comptime T: type, input: []const u8, expected: ?T, is_complete: bool) !void {
    const allocator = std.testing.allocator;

    const parser_source = ParserSource.init(try zss.syntax.tokenize.Source.init(input));
    var tree = try zss.syntax.parse.parseListOfComponentValues(parser_source, allocator);
    defer tree.deinit(allocator);
    const slice = tree.slice();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var source = Source{
        .components = slice,
        .parser_source = parser_source,
        .arena = arena.allocator(),
        .end = slice.nextSibling(0),
        .position = 1,
    };
    const parseFn = typeToParseFn(T);
    const actual = try parseFn(&source);
    if (expected) |expected_payload| {
        if (actual) |actual_payload| {
            if (is_complete) {
                try std.testing.expectEqual(source.end, source.position);
            } else {
                try std.testing.expect(source.end != source.position);
            }
            return switch (T) {
                types.BackgroundImage => expected_payload.expectEqualBackgroundImages(actual_payload),
                else => std.testing.expectEqual(expected_payload, actual_payload),
            };
        } else {
            return error.TestExpectedEqual;
        }
    } else {
        return std.testing.expect(actual == null);
    }
}

test "css value parsing" {
    try testParsing(types.Display, "block", .block, true);
    try testParsing(types.Display, "inline", .inline_, true);

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
    try testParsing(types.BackgroundImage, "url(abcd)", .{ .url = .{ .data = "abcd" } }, true);
    try testParsing(types.BackgroundImage, "url(\"abcd\")", .{ .url = .{ .data = "abcd" } }, true);
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
}

pub fn parseSingleKeyword(source: *Source, comptime Type: type, kvs: []const ParserSource.KV(Type)) ?Type {
    const reset = source.position;
    if (source.next()) |keyword| {
        if (keyword.type == .keyword) {
            if (source.mapKeyword(keyword.position, Type, kvs)) |value| {
                return value;
            }
        }
    }

    source.position = reset;
    return null;
}

pub fn length(source: *Source, dimension: Source.Value.Dimension, comptime Type: type) ?Type {
    const number = dimension.number;
    // TODO: consider using @unionInit()
    // TODO: Source.Value.Dimension should store its unit as an enum rather than a source location
    return source.mapKeyword(dimension.unit_position, Type, &.{
        .{ "px", .{ .px = number } },
    });
}

pub fn cssWideKeyword(
    components: zss.syntax.ComponentTree.Slice,
    parser_source: zss.syntax.parse.Source,
    declaration_index: ComponentTree.Size,
    declaration_end: ComponentTree.Size,
) ?types.CssWideKeyword {
    if (declaration_end - declaration_index == 2) {
        if (components.tag(declaration_index + 1) == .token_ident) {
            const location = components.location(declaration_index + 1);
            return parser_source.mapIdentifier(location, types.CssWideKeyword, &.{
                .{ "initial", .initial },
                .{ "inherit", .inherit },
                .{ "unset", .unset },
            });
        }
    }
    return null;
}

// Spec: CSS 2.2
// inline | block | list-item | inline-block | table | inline-table | table-row-group | table-header-group
// | table-footer-group | table-row | table-column-group | table-column | table-cell | table-caption | none
pub fn display(source: *Source) !?types.Display {
    return parseSingleKeyword(source, types.Display, &.{
        .{ "inline", .inline_ },
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
pub fn position(source: *Source) !?types.Position {
    return parseSingleKeyword(source, types.Position, &.{
        .{ "static", .static },
        .{ "relative", .relative },
        .{ "absolute", .absolute },
        .{ "fixed", .fixed },
    });
}

// Spec: CSS 2.2
// left | right | none
pub fn float(source: *Source) !?types.Float {
    return parseSingleKeyword(source, types.Float, &.{
        .{ "left", .left },
        .{ "right", .right },
        .{ "none", .none },
    });
}

// Spec: CSS 2.2
// auto | <integer>
pub fn zIndex(source: *Source) !?types.ZIndex {
    const auto_or_int = source.next() orelse return null;
    switch (auto_or_int.type) {
        .integer => return types.ZIndex{ .integer = source.value(.integer, auto_or_int.position) },
        .keyword => return source.mapKeyword(auto_or_int.position, types.ZIndex, &.{
            .{ "auto", .auto },
        }),
        else => return null,
    }
}

// Spec: CSS 2.2
// <length> | <percentage>
pub fn lengthPercentage(source: *Source) !?types.LengthPercentage {
    const item = source.next() orelse return null;
    switch (item.type) {
        .dimension => return length(source, source.value(.dimension, item.position), types.LengthPercentage),
        .percentage => return .{ .percentage = source.value(.percentage, item.position) },
        else => return null,
    }
}

// Spec: CSS 2.2
// <length> | <percentage> | auto
pub fn lengthPercentageAuto(source: *Source) !?types.LengthPercentageAuto {
    const item = source.next() orelse return null;
    switch (item.type) {
        .dimension => return length(source, source.value(.dimension, item.position), types.LengthPercentageAuto),
        .percentage => return .{ .percentage = source.value(.percentage, item.position) },
        .keyword => return source.mapKeyword(item.position, types.LengthPercentageAuto, &.{
            .{ "auto", .auto },
        }),
        else => return null,
    }
}

// Spec: CSS 2.2
// <length> | <percentage> | none
pub fn maxSize(source: *Source) !?types.MaxSize {
    const item = source.next() orelse return null;
    switch (item.type) {
        .dimension => return length(source, source.value(.dimension, item.position), types.MaxSize),
        .percentage => return .{ .percentage = source.value(.percentage, item.position) },
        .keyword => return source.mapKeyword(item.position, types.MaxSize, &.{
            .{ "none", .none },
        }),
        else => return null,
    }
}

// Spec: CSS 2.2
// Syntax: <length> | thin | medium | thick
pub fn borderWidth(source: *Source) !?types.BorderWidth {
    const item = source.next() orelse return null;
    switch (item.type) {
        .dimension => return length(source, source.value(.dimension, item.position), types.BorderWidth),
        .keyword => return source.mapKeyword(item.position, types.BorderWidth, &.{
            .{ "thin", .thin },
            .{ "medium", .medium },
            .{ "thick", .thick },
        }),
        else => return null,
    }
}

// Spec: CSS Backgrounds and Borders Level 3
// Syntax: <image> | none
//         <image> = <url> | <gradient>
//         <gradient> = <linear-gradient()> | <repeating-linear-gradient()> | <radial-gradient()> | <repeating-radial-gradient()>
pub fn backgroundImage(source: *Source) !?types.BackgroundImage {
    const item = source.next() orelse return null;
    switch (item.type) {
        .url => {
            const url = (try source.value(.url, item.position)) orelse return null;
            return .{ .url = url };
        },
        .function => {
            // TODO: parse an <image>
            return null;
        },
        .keyword => return source.mapKeyword(item.position, types.BackgroundImage, &.{
            .{ "none", .none },
        }),
        else => return null,
    }
}

// Spec: CSS Backgrounds and Borders Level 3
// Syntax: <repeat-style> = repeat-x | repeat-y | [repeat | space | round | no-repeat]{1,2}
pub fn backgroundRepeat(source: *Source) !?types.BackgroundRepeat {
    const keyword1 = source.expect(.keyword) orelse return null;
    if (source.mapKeyword(keyword1.position, types.BackgroundRepeat.Repeat, &.{
        .{ "repeat-x", .{ .x = .repeat, .y = .no_repeat } },
        .{ "repeat-y", .{ .x = .no_repeat, .y = .repeat } },
    })) |value| {
        return .{ .repeat = value };
    }

    const Style = types.BackgroundRepeat.Style;
    const map = comptime &[_]ParserSource.KV(Style){
        .{ "repeat", .repeat },
        .{ "space", .space },
        .{ "round", .round },
        .{ "no-repeat", .no_repeat },
    };
    const x = source.mapKeyword(keyword1.position, Style, map) orelse return null;
    const y = parseSingleKeyword(source, Style, map) orelse x;
    return .{ .repeat = .{ .x = x, .y = y } };
}

// Spec: CSS Backgrounds and Borders Level 3
// Syntax: <attachment> = scroll | fixed | local
pub fn backgroundAttachment(source: *Source) !?types.BackgroundAttachment {
    return parseSingleKeyword(source, types.BackgroundAttachment, &.{
        .{ "scroll", .scroll },
        .{ "fixed", .fixed },
        .{ "local", .local },
    });
}
