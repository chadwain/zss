const Environment = @This();

const zss = @import("../../zss.zig");
const syntax = zss.syntax;
const ComponentTree = syntax.ComponentTree;
const ParserSource = syntax.parse.Source;
const IdentifierSet = syntax.IdentifierSet;
const namespace = @import("./namespace.zig");
pub const NamespaceId = namespace.NamespaceId;
pub const Stylesheet = @import("./Stylesheet.zig");

const std = @import("std");
const assert = std.debug.assert;
const panic = std.debug.panic;
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const AutoArrayHashMapUnmanaged = std.AutoArrayHashMapUnmanaged;
const SegmentedList = std.SegmentedList;

allocator: Allocator,
stylesheets: ArrayListUnmanaged(Stylesheet) = .{},
type_or_attribute_names: IdentifierSet = .{ .max_size = NameId.max_value, .case = .insensitive },
// TODO: Case sensitivity depends on whether quirks mode is on
id_or_class_names: IdentifierSet = .{ .max_size = IdId.max_value, .case = .sensitive },
default_namespace: ?NamespaceId = null,

pub fn init(allocator: Allocator) Environment {
    return Environment{ .allocator = allocator };
}

pub fn deinit(env: *Environment) void {
    env.type_or_attribute_names.deinit(env.allocator);
    env.id_or_class_names.deinit(env.allocator);
    for (env.stylesheets.items) |*stylesheet| stylesheet.deinit(env.allocator);
    env.stylesheets.deinit(env.allocator);
}

pub fn addStylesheet(env: *Environment, source: ParserSource) !void {
    var tree = try syntax.parse.parseCssStylesheet(source, env.allocator);
    defer tree.deinit(env.allocator);

    const slice = tree.slice();

    try env.stylesheets.ensureUnusedCapacity(env.allocator, 1);
    var stylesheet = Stylesheet{};
    errdefer stylesheet.deinit(env.allocator);

    var arena = stylesheet.arena.promote(env.allocator);
    defer stylesheet.arena = arena.state;
    const arena_allocator = arena.allocator();

    assert(slice.tag(0) == .rule_list);
    var next_index: ComponentTree.Size = 1;
    const end_of_stylesheet = slice.nextSibling(0);
    while (next_index < end_of_stylesheet) {
        const index = next_index;
        next_index = slice.nextSibling(next_index);
        switch (slice.tag(index)) {
            .at_rule => panic("TODO: At-rules in a stylesheet\n", .{}),
            .qualified_rule => {
                const end_of_prelude = slice.extra(index).index();

                try stylesheet.rules.ensureUnusedCapacity(arena_allocator, 1);
                const selector_list = (try zss.selectors.parseSelectorList(env, &arena, source, slice, index + 1, end_of_prelude)) orelse continue;
                const decls = try zss.declaration.parse.parseStyleBlockDeclarations(&arena, slice, source, end_of_prelude);
                stylesheet.rules.appendAssumeCapacity(.{ .selector = selector_list, .declarations = decls });
            },
            else => unreachable,
        }
    }

    env.stylesheets.appendAssumeCapacity(stylesheet);
}

pub const NameId = enum(u24) {
    pub const Value = u24;
    const max_value = std.math.maxInt(Value) - 1;

    unspecified = max_value,
    any = max_value + 1,
    _,
};

pub fn addTypeOrAttributeName(env: *Environment, identifier: ParserSource.Location, source: ParserSource) !NameId {
    const index = try env.type_or_attribute_names.getOrPutFromSource(env.allocator, source, source.identTokenIterator(identifier));
    return @enumFromInt(@as(NameId.Value, @intCast(index)));
}

pub fn addTypeOrAttributeNameString(env: *Environment, string: []const u8) !NameId {
    const index = try env.type_or_attribute_names.getOrPutFromString(env.allocator, string);
    return @enumFromInt(@as(NameId.Value, @intCast(index)));
}

pub const IdId = enum(u32) {
    pub const Value = u32;
    const max_value = std.math.maxInt(Value);

    _,
};

pub const ClassId = enum(u32) {
    pub const Value = u32;
    const max_value = std.math.maxInt(Value);

    _,
};

comptime {
    assert(IdId.max_value == ClassId.max_value);
}

pub fn addIdName(env: *Environment, hash_id: ParserSource.Location, source: ParserSource) !IdId {
    const index = try env.id_or_class_names.getOrPutFromSource(env.allocator, source, source.hashIdTokenIterator(hash_id));
    return @enumFromInt(@as(IdId.Value, @intCast(index)));
}

pub fn addClassName(env: *Environment, identifier: ParserSource.Location, source: ParserSource) !ClassId {
    const index = try env.id_or_class_names.getOrPutFromSource(env.allocator, source, source.identTokenIterator(identifier));
    return @enumFromInt(@as(ClassId.Value, @intCast(index)));
}
