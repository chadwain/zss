const Environment = @This();

const zss = @import("zss.zig");
const cascade = zss.cascade;
const syntax = zss.syntax;
const Ast = syntax.Ast;
const Declarations = zss.property.Declarations;
const TokenSource = syntax.TokenSource;
const Stylesheet = zss.Stylesheet;
const IdentifierSet = syntax.IdentifierSet;

const std = @import("std");
const assert = std.debug.assert;
const panic = std.debug.panic;
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const MultiArrayList = std.MultiArrayList;

allocator: Allocator,
type_or_attribute_names: IdentifierSet,
id_or_class_names: IdentifierSet,
attribute_values: zss.StringInterner,
namespaces: Namespaces,
decls: Declarations,
cascade_list: cascade.List,
element_tree: zss.ElementTree,
next_url_id: ?UrlId.Int,
urls_to_images: std.AutoArrayHashMapUnmanaged(UrlId, Images.Handle),
images: Images,

pub fn init(allocator: Allocator) Environment {
    return Environment{
        .allocator = allocator,
        .type_or_attribute_names = .{ .max_size = NameId.max_value, .case = .insensitive },
        // TODO: Case sensitivity depends on whether quirks mode is on
        .id_or_class_names = .{ .max_size = IdId.max_value, .case = .sensitive },
        .attribute_values = .init(.{ .max_size = AttributeValueId.num_unique_values }),
        .namespaces = .{},
        .decls = .{},
        .cascade_list = .{},
        .element_tree = .init,
        .next_url_id = 0,
        .urls_to_images = .empty,
        .images = .{},
    };
}

pub fn deinit(env: *Environment) void {
    env.type_or_attribute_names.deinit(env.allocator);
    env.id_or_class_names.deinit(env.allocator);
    env.namespaces.deinit(env.allocator);
    env.decls.deinit(env.allocator);
    env.cascade_list.deinit(env.allocator);
    env.element_tree.deinit(env.allocator);
    env.urls_to_images.deinit(env.allocator);
    env.images.deinit(env.allocator);
}

// TODO: consider making an `IdentifierMap` structure for this use case
pub const Namespaces = struct {
    map: std.StringArrayHashMapUnmanaged(void) = .empty,

    pub const Id = enum(u8) {
        /// Represents the null namespace, a.k.a. no namespace.
        none = 254,
        /// Not a valid namespace id. It represents a match on any namespace (in e.g. a type selector).
        any = 255,
        _,
    };

    fn deinit(namespaces: *Namespaces, allocator: Allocator) void {
        for (namespaces.map.keys()) |key| {
            allocator.free(key);
        }
        namespaces.map.deinit(allocator);
    }
};

pub fn addNamespace(env: *Environment, ast: Ast, source: TokenSource, index: Ast.Size) !Namespaces.Id {
    try env.namespaces.map.ensureUnusedCapacity(env.allocator, 1);
    const location = ast.location(index);
    const namespace = try switch (ast.tag(index)) {
        .token_string => source.copyString(location, env.allocator),
        .token_url, .token_bad_url => panic("TODO: addNamespace with a URL", .{}),
        else => unreachable,
    };
    if (namespace.len == 0) {
        env.allocator.free(namespace);
        // TODO: Does an empty URL represent the null namespace?
        return .none;
    }
    const gop_result = env.namespaces.map.getOrPutAssumeCapacity(namespace);
    if (gop_result.index >= @intFromEnum(Namespaces.Id.none)) {
        env.allocator.free(namespace);
        env.namespaces.map.orderedRemoveAt(gop_result.index);
        return error.MaxNamespaceLimitReached;
    }
    if (gop_result.found_existing) {
        env.allocator.free(namespace);
    }
    return @enumFromInt(gop_result.index);
}

pub const NameId = enum(u24) {
    pub const Value = u24;
    const max_value = std.math.maxInt(Value) - 1;

    anonymous = max_value,
    any = max_value + 1,
    _,
};

pub fn addTypeOrAttributeName(env: *Environment, identifier: TokenSource.Location, source: TokenSource) !NameId {
    const index = try env.type_or_attribute_names.getOrPutFromSource(env.allocator, source, source.identTokenIterator(identifier));
    return @enumFromInt(@as(NameId.Value, @intCast(index)));
}

// TODO: This is only used in tests
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

pub fn addIdName(env: *Environment, hash_id: TokenSource.Location, source: TokenSource) !IdId {
    const index = try env.id_or_class_names.getOrPutFromSource(env.allocator, source, source.hashTokenIterator(hash_id));
    return @enumFromInt(@as(IdId.Value, @intCast(index)));
}

// TODO: This is only used in tests
pub fn addIdNameString(env: *Environment, string: []const u8) !IdId {
    const index = try env.id_or_class_names.getOrPutFromString(env.allocator, string);
    return @enumFromInt(@as(IdId.Value, @intCast(index)));
}

pub fn addClassName(env: *Environment, identifier: TokenSource.Location, source: TokenSource) !ClassId {
    const index = try env.id_or_class_names.getOrPutFromSource(env.allocator, source, source.identTokenIterator(identifier));
    return @enumFromInt(@as(ClassId.Value, @intCast(index)));
}

pub const AttributeValueId = enum(u32) {
    _,
    const num_unique_values = 1 << 32;
};

pub fn addAttributeValueIdent(env: *Environment, identifier: TokenSource.Location, source: TokenSource) !AttributeValueId {
    const index = try env.attribute_values.addFromIdentToken(env.allocator, identifier, source);
    return @enumFromInt(index);
}

pub fn addAttributeValueString(env: *Environment, string: TokenSource.Location, source: TokenSource) !AttributeValueId {
    const index = try env.attribute_values.addFromStringToken(env.allocator, string, source);
    return @enumFromInt(index);
}

/// A unique identifier for each URL.
pub const UrlId = enum(u16) {
    _,

    pub const Int = std.meta.Tag(@This());
};

/// Create a new URL value.
pub fn createUrl(env: *Environment) !UrlId {
    const int = if (env.next_url_id) |*int| int else return error.OutOfUrls;
    defer env.next_url_id = std.math.add(UrlId.Int, int.*, 1) catch null;
    return int.*;
}

pub fn linkUrlToImage(env: *Environment, url: UrlId, image: Images.Handle) !void {
    try env.urls_to_images.put(env.allocator, url, image);
}

pub const Images = struct {
    pub const Handle = enum(u32) { _ };

    pub const Image = struct {
        dimensions: Dimensions,
        format: Format,
        /// Externally managed image data.
        /// Use `null` to signal that the data is not available.
        data: ?[]const u8,
    };

    pub const Dimensions = struct {
        width_px: u32,
        height_px: u32,
    };

    pub const Format = enum {
        rgba,
    };

    list: MultiArrayList(Image) = .{},

    fn deinit(images: *Images, allocator: Allocator) void {
        images.list.deinit(allocator);
    }

    fn nextHandle(images: Images) ?Handle {
        if (images.list.len == std.math.maxInt(std.meta.Tag(Handle))) return null;
        return @enumFromInt(images.list.len);
    }

    pub const View = struct {
        slice: MultiArrayList(Image).Slice,

        pub fn dimensions(v: View, handle: Handle) Dimensions {
            return v.slice.items(.dimensions)[@intFromEnum(handle)];
        }

        pub fn format(v: View, handle: Handle) Format {
            return v.slice.items(.format)[@intFromEnum(handle)];
        }

        pub fn data(v: View, handle: Handle) []const u8 {
            return v.slice.items(.data)[@intFromEnum(handle)];
        }

        pub fn get(v: View, handle: Handle) Image {
            return v.slice.get(@intFromEnum(handle));
        }
    };

    pub fn view(images: Images) View {
        return .{ .slice = images.list.slice() };
    }
};

pub fn addImage(env: *Environment, image: Images.Image) !Images.Handle {
    const handle = env.images.nextHandle() orelse return error.OutOfImages;
    try env.images.list.append(env.allocator, image);
    return handle;
}
