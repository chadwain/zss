const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const zss = @import("../zss.zig");
const types = zss.values.types;
const Ast = zss.syntax.Ast;
const Component = zss.syntax.Component;
const Environment = zss.Environment;
const TokenSource = zss.syntax.TokenSource;
const Location = TokenSource.Location;

pub const Context = struct {
    ast: Ast,
    token_source: TokenSource,
    state: State,

    pub const State = struct {
        mode: Mode,
        sequence: Ast.Sequence,

        pub const Mode = enum {
            /// For parsing a general sequence of Ast nodes.
            normal,
            /// For parsing CSS declarations.
            decl,
            /// For parsing comma-separated lists within a CSS declaration.
            decl_list,
        };
    };

    pub fn init(ast: Ast, token_source: TokenSource) Context {
        return .{
            .ast = ast,
            .token_source = token_source,
            .state = undefined,
        };
    }

    /// Sets `sequence` as the current node sequence to iterate over.
    pub fn initSequence(ctx: *Context, sequence: Ast.Sequence) void {
        ctx.state = .{
            .mode = .normal,
            .sequence = sequence,
        };
    }

    /// Sets the children of `declaration_index` as the current node sequence to iterate over.
    pub fn initDecl(ctx: *Context, declaration_index: Ast.Index) void {
        switch (declaration_index.tag(ctx.ast)) {
            .declaration_normal, .declaration_important => {},
            else => unreachable,
        }
        ctx.state = .{
            .mode = .decl,
            .sequence = declaration_index.children(ctx.ast),
        };
    }

    /// Sets the children of `declaration_index` as the current node sequence to iterate over.
    /// In addition, it treats the sequence as a comma-separated list.
    /// A return value of `null` represents a parse error.
    pub fn initDeclList(ctx: *Context, declaration_index: Ast.Index) ?void {
        switch (declaration_index.tag(ctx.ast)) {
            .declaration_normal, .declaration_important => {},
            else => unreachable,
        }
        ctx.state = .{
            .mode = .decl_list,
            .sequence = declaration_index.children(ctx.ast),
        };
        return ctx.beginList();
    }

    pub const Item = struct {
        index: Ast.Index,
        tag: Component.Tag,
    };

    fn rawNext(ctx: *Context) ?Item {
        const index = ctx.state.sequence.nextSkipSpaces(ctx.ast) orelse return null;
        const tag = index.tag(ctx.ast);
        return .{ .index = index, .tag = tag };
    }

    /// Returns the next item in the current sequence or list item.
    pub fn next(ctx: *Context) ?Item {
        switch (ctx.state.mode) {
            .normal => return ctx.rawNext(),
            .decl => return ctx.rawNext(),
            .decl_list => {
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

    /// Checks if the current sequence or list item is empty.
    pub fn empty(ctx: *Context) bool {
        switch (ctx.state.mode) {
            .normal => return ctx.state.sequence.emptySkipSpaces(ctx.ast),
            .decl => return ctx.state.sequence.emptySkipSpaces(ctx.ast),
            .decl_list => {
                const item = ctx.rawNext() orelse return true;
                ctx.state.sequence.reset(item.index);
                return item.tag == .token_comma;
            },
        }
    }

    /// Save the current point in the current sequence or list item.
    pub fn savePoint(ctx: *Context) Ast.Index {
        return ctx.state.sequence.start;
    }

    pub fn resetPoint(ctx: *Context, save_point: Ast.Index) void {
        ctx.state.sequence.reset(save_point);
    }

    /// Sets the children of the Ast node `index` as the current node sequence to iterate over.
    pub fn enterSequence(ctx: *Context, index: Ast.Index) State {
        const new_state: State = .{
            .sequence = index.children(ctx.ast),
            .mode = switch (ctx.state.mode) {
                .normal => .normal,
                .decl, .decl_list => .decl,
            },
        };
        defer ctx.state = new_state;
        return ctx.state;
    }

    pub fn resetState(ctx: *Context, previous_state: State) void {
        ctx.state = previous_state;
    }

    /// Checks for the beginning of a valid comma-separated list.
    /// A return value of `null` represents a parse error.
    fn beginList(ctx: *Context) ?void {
        ctx.assertIsList();
        const item = ctx.rawNext() orelse return;
        ctx.state.sequence.reset(item.index);
        if (item.tag == .token_comma) {
            return null; // Leading comma
        }
    }

    /// Checks that a list item in a comma-separated list has been fully consumed, and
    /// advances to the next list item.
    /// A return value of `null` represents a parse error.
    pub fn endListItem(ctx: *Context) ?void {
        ctx.assertIsList();
        const comma = ctx.rawNext() orelse return;
        if (comma.tag != .token_comma) return null; // List item not fully consumed
        const item = ctx.rawNext() orelse return null; // Trailing comma
        ctx.state.sequence.reset(item.index);
        if (item.tag == .token_comma) return null; // Two commas in a row
    }

    /// Checks for the presence of a next list item in a comma-separated list.
    /// A return value of `null` represents the end of the list.
    pub fn nextListItem(ctx: *Context) ?void {
        ctx.assertIsList();
        const item = ctx.rawNext() orelse return null;
        ctx.state.sequence.reset(item.index);
    }

    fn assertIsList(ctx: *const Context) void {
        switch (ctx.state.mode) {
            .normal, .decl => unreachable,
            .decl_list => {},
        }
    }
};

/// Stores the source locations of URLs found within the most recently parsed `Ast`.
// TODO: Deduplicate identical URLs.
pub const Urls = struct {
    start_id: ?UrlId.Int,
    descriptions: std.MultiArrayList(Description),

    const UrlId = Environment.UrlId;

    pub const Description = struct {
        type: Type,
        src_loc: SourceLocation,
    };

    pub const Type = enum {
        background_image,
    };

    pub const SourceLocation = union(enum) {
        /// The location of a `token_url` Ast node.
        url_token: TokenSource.Location,
        /// The location of a `token_string` Ast node.
        string_token: TokenSource.Location,
    };

    pub fn init(env: *const Environment) Urls {
        return .{
            .start_id = env.next_url_id,
            .descriptions = .empty,
        };
    }

    pub fn deinit(urls: *Urls, allocator: Allocator) void {
        urls.descriptions.deinit(allocator);
    }

    fn nextId(urls: *const Urls) ?UrlId.Int {
        const start_id = urls.start_id orelse return null;
        const len = std.math.cast(UrlId.Int, urls.descriptions.len) orelse return null;
        const int = std.math.add(UrlId.Int, start_id, len) catch return null;
        return int;
    }

    pub fn commit(urls: *const Urls, env: *Environment) void {
        assert(urls.start_id == env.next_url_id);
        env.next_url_id = urls.nextId();
    }

    pub fn clear(urls: *Urls, env: *const Environment) void {
        urls.start_id = env.next_url_id;
        urls.descriptions.clearRetainingCapacity();
    }

    pub const Iterator = struct {
        index: usize,
        urls: *const Urls,

        pub const Item = struct {
            id: UrlId,
            desc: Description,
        };

        pub fn next(it: *Iterator) ?Item {
            if (it.index == it.urls.descriptions.len) return null;
            defer it.index += 1;

            const id: UrlId = @enumFromInt(it.urls.start_id.? + it.index);
            const desc = it.urls.descriptions.get(it.index);
            return .{ .id = id, .desc = desc };
        }
    };

    /// Returns an iterator over all URLs currently stored within `urls`.
    pub fn iterator(urls: *const Urls) Iterator {
        return .{ .index = 0, .urls = urls };
    }

    pub const Managed = struct {
        unmanaged: *Urls,
        allocator: Allocator,

        pub fn addUrl(urls: Managed, desc: Description) !UrlId {
            const int = urls.unmanaged.nextId() orelse return error.OutOfUrls;
            try urls.unmanaged.descriptions.append(urls.allocator, desc);
            return @enumFromInt(int);
        }

        pub fn save(urls: Managed) usize {
            return urls.unmanaged.descriptions.len;
        }

        pub fn reset(urls: Managed, previous_state: usize) void {
            urls.unmanaged.descriptions.shrinkRetainingCapacity(previous_state);
        }
    };

    pub fn toManaged(urls: *Urls, allocator: Allocator) Managed {
        return .{ .unmanaged = urls, .allocator = allocator };
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

fn genericLength(ctx: *const Context, comptime Type: type, index: Ast.Index) ?Type {
    var children = index.children(ctx.ast);
    const unit_index = children.nextSkipSpaces(ctx.ast).?;

    const number = index.extra(ctx.ast).number orelse return null;
    const unit = unit_index.extra(ctx.ast).unit orelse return null;
    return switch (unit) {
        .px => .{ .px = number },
    };
}

fn genericPercentage(ctx: *const Context, comptime Type: type, index: Ast.Index) ?Type {
    const value = index.extra(ctx.ast).number orelse return null;
    return .{ .percentage = value };
}

pub fn identifier(ctx: *Context) ?Location {
    const item = ctx.next() orelse return null;
    if (item.tag == .token_ident) return item.index.location(ctx.ast);

    ctx.resetPoint(item.index);
    return null;
}

pub fn keyword(ctx: *Context, comptime Type: type, kvs: []const TokenSource.KV(Type)) ?Type {
    const save_point = ctx.savePoint();
    const ident = identifier(ctx) orelse return null;
    if (ctx.token_source.mapIdentifierValue(ident, Type, kvs)) |result| {
        return result;
    } else {
        ctx.resetPoint(save_point);
        return null;
    }
}

pub fn integer(ctx: *Context) ?i32 {
    const item = ctx.next() orelse return null;
    if (item.tag == .token_integer) {
        if (item.index.extra(ctx.ast).integer) |value| return value;
    }

    ctx.resetPoint(item.index);
    return null;
}

// Spec: CSS 2.2
// <length>
pub fn length(ctx: *Context, comptime Type: type) ?Type {
    const item = ctx.next() orelse return null;
    if (item.tag == .token_dimension) {
        if (genericLength(ctx, Type, item.index)) |result| return result;
    }

    ctx.resetPoint(item.index);
    return null;
}

// Spec: CSS 2.2
// <percentage>
pub fn percentage(ctx: *Context, comptime Type: type) ?Type {
    const item = ctx.next() orelse return null;
    if (item.tag == .token_percentage) {
        if (genericPercentage(ctx, Type, item.index)) |value| return value;
    }

    ctx.resetPoint(item.index);
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
        return item.index.location(ctx.ast);
    }

    ctx.resetPoint(item.index);
    return null;
}

pub fn hash(ctx: *Context) ?Location {
    const item = ctx.next() orelse return null;
    switch (item.tag) {
        .token_hash_id, .token_hash_unrestricted => return item.index.location(ctx.ast),
        else => {},
    }
    ctx.resetPoint(item.index);
    return null;
}

/// Spec: CSS Color Level 4
/// Syntax: <color> = <color-base> | currentColor | <system-color>
///         <color-base> = <hex-color> | <color-function> | <named-color> | transparent
pub fn color(ctx: *Context) ?types.Color {
    // TODO: Named colors, system colors, color functions
    if (keyword(ctx, types.Color, &.{
        .{ "currentColor", .current_color },
        .{ "transparent", .transparent },
    })) |value| {
        return value;
    } else if (hash(ctx)) |location| blk: {
        var digits: @Vector(8, u8) = undefined;
        const len = len: {
            var iterator = ctx.token_source.hashIdTokenIterator(location);
            var index: u4 = 0;
            while (iterator.next()) |codepoint| : (index += 1) {
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

    return null;
}

// Syntax:
// <url> = <url()> | <src()>
// <url()> = url( <string> <url-modifier>* ) | <url-token>
// <src()> = src( <string> <url-modifier>* )
pub fn url(ctx: *Context) ?Urls.SourceLocation {
    const item = ctx.next() orelse return null;
    switch (item.tag) {
        .token_url => return .{ .url_token = item.index.location(ctx.ast) },
        .function => blk: {
            const location = item.index.location(ctx.ast);
            _ = ctx.token_source.mapIdentifierValue(location, void, &.{
                .{ "url", {} },
                .{ "src", {} },
            }) orelse break :blk;

            const state = ctx.enterSequence(item.index);
            defer ctx.resetState(state);

            const str = string(ctx) orelse break :blk;
            if (!ctx.empty()) {
                // The URL may have contained URL modifiers, but these are not supported by zss.
                break :blk;
            }

            return .{ .string_token = str };
        },
        else => {},
    }

    ctx.resetPoint(item.index);
    return null;
}

pub fn urlManaged(ctx: *Context, urls: Urls.Managed, @"type": Urls.Type) !?Environment.UrlId {
    const src_loc = url(ctx) orelse return null;
    const id = try urls.addUrl(.{ .type = @"type", .src_loc = src_loc });
    return id;
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

// Spec: CSS Backgrounds and Borders Level 3
// Syntax: <line-style> = none | hidden | dotted | dashed | solid | double | groove | ridge | inset | outset
pub fn borderStyle(ctx: *Context) ?types.BorderStyle {
    return keyword(ctx, types.BorderStyle, &.{
        .{ "none", .none },
        .{ "hidden", .hidden },
        .{ "dotted", .dotted },
        .{ "dashed", .dashed },
        .{ "solid", .solid },
        .{ "double", .double },
        .{ "groove", .groove },
        .{ "ridge", .ridge },
        .{ "inset", .inset },
        .{ "outset", .outset },
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
            var ast, const component_list_index = blk: {
                var syntax_parser = zss.syntax.Parser.init(token_source, allocator);
                defer syntax_parser.deinit();
                break :blk try syntax_parser.parseListOfComponentValues(allocator);
            };
            defer ast.deinit(allocator);

            var ctx = Context.init(ast, token_source);
            _ = ctx.enterSequence(component_list_index);

            switch (std.meta.ArgsTuple(@TypeOf(parser))) {
                struct { *Context } => return parser(&ctx),
                struct { *Context, Urls.Managed } => {
                    var env = Environment.init(allocator, .temp_default, .no_quirks);
                    defer env.deinit();
                    var urls = Urls.init(&env);
                    defer urls.deinit(allocator);
                    const value = try parser(&ctx, urls.toManaged(allocator));
                    urls.commit(&env);
                    return value;
                },
                else => |T| @compileError(@typeName(T) ++ " is not a supported argument list for a value parser"),
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

        const LengthPercentage = union(enum) { px: f32, percentage: f32 };

        fn lengthPercentage(ctx: *Context) ?LengthPercentage {
            return zss.values.parse.lengthPercentage(ctx, LengthPercentage);
        }

        const LengthPercentageAuto = union(enum) { px: f32, percentage: f32, auto };

        fn lengthPercentageAuto(ctx: *Context) ?LengthPercentageAuto {
            return zss.values.parse.lengthPercentageAuto(ctx, LengthPercentageAuto);
        }

        const LengthPercentageNone = union(enum) { px: f32, percentage: f32, none };

        fn lengthPercentageNone(ctx: *Context) ?LengthPercentageNone {
            return zss.values.parse.lengthPercentageNone(ctx, LengthPercentageNone);
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

    try ns.expectValue(ns.lengthPercentage, "5px", .{ .px = 5 });
    try ns.expectValue(ns.lengthPercentage, "5%", .{ .percentage = 0.05 });
    try ns.expectValue(ns.lengthPercentage, "5", null);
    try ns.expectValue(ns.lengthPercentage, "auto", null);

    try ns.expectValue(ns.lengthPercentageAuto, "5px", .{ .px = 5 });
    try ns.expectValue(ns.lengthPercentageAuto, "5%", .{ .percentage = 0.05 });
    try ns.expectValue(ns.lengthPercentageAuto, "5", null);
    try ns.expectValue(ns.lengthPercentageAuto, "auto", .auto);

    try ns.expectValue(ns.lengthPercentageNone, "5px", .{ .px = 5 });
    try ns.expectValue(ns.lengthPercentageNone, "5%", .{ .percentage = 0.05 });
    try ns.expectValue(ns.lengthPercentageNone, "5", null);
    try ns.expectValue(ns.lengthPercentageNone, "auto", null);
    try ns.expectValue(ns.lengthPercentageNone, "none", .none);

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
        .x = .{ .side = .start, .offset = .{ .percentage = 0.5 } },
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
        .y = .{ .side = .end, .offset = .{ .percentage = 0.5 } },
    });
    try ns.expectValue(background.position, "center bottom 50%", .{
        .x = .{ .side = .center, .offset = .{ .percentage = 0 } },
        .y = .{ .side = .end, .offset = .{ .percentage = 0.5 } },
    });
    try ns.expectValue(background.position, "bottom 50% center", .{
        .x = .{ .side = .center, .offset = .{ .percentage = 0 } },
        .y = .{ .side = .end, .offset = .{ .percentage = 0.5 } },
    });
    try ns.expectValue(background.position, "bottom 50% left 20px", .{
        .x = .{ .side = .start, .offset = .{ .px = 20 } },
        .y = .{ .side = .end, .offset = .{ .percentage = 0.5 } },
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
    try ns.expectValue(background.size, "5px 5%", .{ .size = .{ .width = .{ .px = 5 }, .height = .{ .percentage = 0.05 } } });

    try ns.expectValue(color, "currentColor", .current_color);
    try ns.expectValue(color, "transparent", .transparent);
    try ns.expectValue(color, "#abc", .{ .rgba = 0xaabbccff });
    try ns.expectValue(color, "#abcd", .{ .rgba = 0xaabbccdd });
    try ns.expectValue(color, "#123456", .{ .rgba = 0x123456ff });
    try ns.expectValue(color, "#12345678", .{ .rgba = 0x12345678 });

    try ns.expectValue(borderStyle, "none", .none);
    try ns.expectValue(borderStyle, "ridge", .ridge);
}
