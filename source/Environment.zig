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
recent_urls: RecentUrls = .{},
urls_to_images: std.AutoArrayHashMapUnmanaged(UrlId, Images.Handle) = .empty,
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
    env.recent_urls.deinit(env.allocator);
    env.urls_to_images.deinit(env.allocator);
    env.images.deinit(env.allocator);
}

pub fn addStylesheet(env: *Environment, source: TokenSource) !void {
    var ast = blk: {
        var parser = syntax.Parser.init(source, env.allocator);
        defer parser.deinit();
        break :blk try parser.parseCssStylesheet(env.allocator);
    };
    defer ast.deinit(env.allocator);

    env.recentUrlsManaged().clearUrls();
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

/// A unique identifier for each URL.
pub const UrlId = enum(u16) {
    _,

    const Int = std.meta.Tag(@This());
};

/// Stores the source locations of URLs found within the most recently parsed `Ast`.
// TODO: Deduplicate identical URLs.
pub const RecentUrls = struct {
    start_id: ?UrlId.Int = 0,
    descriptions: MultiArrayList(Description) = .empty,

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

    fn deinit(urls: *RecentUrls, allocator: Allocator) void {
        urls.descriptions.deinit(allocator);
    }

    pub const Iterator = struct {
        index: usize,
        recent_urls: *const RecentUrls,

        pub const Item = struct {
            id: UrlId,
            desc: Description,
        };

        pub fn next(it: *Iterator) ?Item {
            if (it.index == it.recent_urls.descriptions.len) return null;
            defer it.index += 1;

            const id: UrlId = @enumFromInt(it.recent_urls.start_id.? + it.index);
            const desc = it.recent_urls.descriptions.get(it.index);
            return .{ .id = id, .desc = desc };
        }
    };

    /// Returns an iterator over all URLs currently stored within `recent_urls`.
    pub fn iterator(recent_urls: *const RecentUrls) Iterator {
        return .{ .index = 0, .recent_urls = recent_urls };
    }

    pub const Managed = struct {
        unmanaged: *RecentUrls,
        allocator: Allocator,

        fn nextId(recent_urls: Managed) ?UrlId.Int {
            const start_id = recent_urls.unmanaged.start_id orelse return null;
            const len = std.math.cast(UrlId.Int, recent_urls.unmanaged.descriptions.len) orelse return null;
            const int = std.math.add(UrlId.Int, start_id, len) catch return null;
            return int;
        }

        pub fn addUrl(recent_urls: Managed, desc: Description) !UrlId {
            const int = recent_urls.nextId() orelse return error.OutOfUrls;
            try recent_urls.unmanaged.descriptions.append(recent_urls.allocator, desc);
            return @enumFromInt(int);
        }

        pub fn save(recent_urls: Managed) usize {
            return recent_urls.unmanaged.descriptions.len;
        }

        pub fn reset(recent_urls: Managed, previous_state: usize) void {
            recent_urls.unmanaged.descriptions.shrinkRetainingCapacity(previous_state);
        }

        pub fn clearUrls(recent_urls: Managed) void {
            recent_urls.unmanaged.start_id = recent_urls.nextId();
            recent_urls.unmanaged.descriptions.clearRetainingCapacity();
        }
    };
};

pub fn recentUrlsManaged(env: *Environment) RecentUrls.Managed {
    return .{ .unmanaged = &env.recent_urls, .allocator = env.allocator };
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
