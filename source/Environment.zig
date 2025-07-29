const Environment = @This();

const zss = @import("zss.zig");
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
stylesheets: ArrayListUnmanaged(Stylesheet) = .{},
type_or_attribute_names: IdentifierSet = .{ .max_size = NameId.max_value, .case = .insensitive },
// TODO: Case sensitivity depends on whether quirks mode is on
id_or_class_names: IdentifierSet = .{ .max_size = IdId.max_value, .case = .sensitive },
namespaces: Namespaces = .{},
decls: Declarations = .{},
urls: Urls = .{},
images: Images = .{},

pub fn init(allocator: Allocator) Environment {
    return Environment{ .allocator = allocator };
}

pub fn deinit(env: *Environment) void {
    env.type_or_attribute_names.deinit(env.allocator);
    env.id_or_class_names.deinit(env.allocator);
    for (env.stylesheets.items) |*stylesheet| {
        stylesheet.deinit(env.allocator);
    }
    env.stylesheets.deinit(env.allocator);
    env.namespaces.deinit(env.allocator);
    env.decls.deinit(env.allocator);
    env.urls.deinit(env.allocator);
    env.images.deinit(env.allocator);
}

pub fn addStylesheet(env: *Environment, source: TokenSource) !void {
    var ast = blk: {
        var parser = syntax.Parser.init(source, env.allocator);
        defer parser.deinit();
        break :blk try parser.parseCssStylesheet(env.allocator);
    };
    defer ast.deinit(env.allocator);

    env.urls.clear();
    try env.stylesheets.ensureUnusedCapacity(env.allocator, 1);
    const stylesheet = try Stylesheet.create(ast, 0, source, env, env.allocator);
    env.stylesheets.appendAssumeCapacity(stylesheet);
}

test addStylesheet {
    var env = Environment.init(std.testing.allocator);
    defer env.deinit();

    const input = "test {}";
    const token_source = try TokenSource.init(input);
    try env.addStylesheet(token_source);
}

// TODO: consider making an `IdentifierMap` structure for this use case
pub const Namespaces = struct {
    map: std.StringArrayHashMapUnmanaged(void) = .empty,

    pub const Id = enum(u8) {
        /// Represents the null namespace.
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

pub fn addClassName(env: *Environment, identifier: TokenSource.Location, source: TokenSource) !ClassId {
    const index = try env.id_or_class_names.getOrPutFromSource(env.allocator, source, source.identTokenIterator(identifier));
    return @enumFromInt(@as(ClassId.Value, @intCast(index)));
}

/// Stores the source locations of URLs found within the most recently parsed `Ast`.
// TODO: Deduplicate identical URLs.
pub const Urls = struct {
    start_id: ?Id.Int = 0,
    descriptions: MultiArrayList(Description) = .empty,

    /// A unique identifier for each URL.
    pub const Id = enum(u16) {
        _,

        const Int = std.meta.Tag(@This());
    };

    pub const Description = struct {
        type: Type,
        src_loc: SourceLocation,
    };

    pub const Type = enum {
        image,
    };

    pub const SourceLocation = union(enum) {
        /// The location of a `token_url` Ast node.
        url_token: TokenSource.Location,
        /// The location of a `token_string` Ast node.
        string_token: TokenSource.Location,
    };

    fn deinit(urls: *Urls, allocator: Allocator) void {
        urls.descriptions.deinit(allocator);
    }

    fn clear(urls: *Urls) void {
        urls.start_id = urls.nextId();
        urls.descriptions.clearRetainingCapacity();
    }

    fn nextId(urls: *const Urls) ?Id.Int {
        const start_id = urls.start_id orelse return null;
        const len = std.math.cast(Id.Int, urls.descriptions.len) orelse return null;
        const int = std.math.add(Id.Int, start_id, len) catch return null;
        return int;
    }

    pub const Iterator = struct {
        index: usize,
        urls: *const Urls,

        pub const Item = struct {
            id: Id,
            type: Type,
            src_loc: SourceLocation,
        };

        pub fn next(it: *Iterator) ?Item {
            const index = it.index;
            if (index == it.urls.descriptions.len) return null;
            it.index += 1;

            const id = it.urls.start_id.? + index;
            const desc = it.urls.descriptions.get(index);
            return .{ .id = id, .type = desc.type, .src_loc = desc.src_loc };
        }
    };

    /// Returns an iterator over all URLs currently stored within `urls`.
    pub fn iterator(urls: *const Urls) Iterator {
        return .{ .index = 0, .urls = urls };
    }
};

pub fn addUrl(env: *Environment, desc: Urls.Description) !Urls.Id {
    const int = env.urls.nextId() orelse return error.OutOfUrls;
    try env.urls.descriptions.append(env.allocator, desc);
    return @enumFromInt(int);
}

pub const Images = struct {
    pub const Handle = enum(u32) { _ };

    pub const Image = struct {
        dimensions: Dimensions,
        format: Format,
        /// Externally managed image data.
        /// `null` means the data is not available.
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
