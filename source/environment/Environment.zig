const Environment = @This();

const zss = @import("../zss.zig");
const syntax = zss.syntax;
const ParserSource = syntax.parse.Source;
const IdentifierSet = syntax.IdentifierSet;

pub const Stylesheet = @import("./Stylesheet.zig");

const std = @import("std");
const assert = std.debug.assert;
const panic = std.debug.panic;
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

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
    env.images.deinit(env.allocator);
}

pub fn addStylesheet(env: *Environment, source: ParserSource) !void {
    var components = try syntax.parse.parseCssStylesheet(source, env.allocator);
    defer components.deinit(env.allocator);
    const slice = components.slice();

    try env.stylesheets.ensureUnusedCapacity(env.allocator, 1);
    const stylesheet = try Stylesheet.create(slice, source, env.allocator, env);
    env.stylesheets.appendAssumeCapacity(stylesheet);
}

pub const NamespaceId = enum(u8) {
    pub const Value = u8;

    none = 0,
    any = 255,
    _,
};

pub const NameId = enum(u24) {
    pub const Value = u24;
    const max_value = std.math.maxInt(Value) - 1;

    anonymous = max_value,
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
