const Environment = @This();

const zss = @import("zss.zig");
const cascade = zss.cascade;
const syntax = zss.syntax;
const Ast = syntax.Ast;
const Declarations = zss.Declarations;
const TokenSource = syntax.TokenSource;
const Stylesheet = zss.Stylesheet;

const std = @import("std");
const assert = std.debug.assert;
const panic = std.debug.panic;
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const MultiArrayList = std.MultiArrayList;

allocator: Allocator,

type_names: zss.StringInterner,
attribute_names: zss.StringInterner,
id_names: zss.StringInterner,
class_names: zss.StringInterner,
attribute_values: zss.StringInterner,
namespaces: Namespaces,
texts: Texts,

decls: Declarations,
cascade_list: cascade.List,

tree_interface: TreeInterface,
next_node_group: ?std.meta.Tag(NodeGroup),
root_node: ?NodeId,
node_properties: NodeProperties,
ids_to_nodes: std.AutoHashMapUnmanaged(IdName, NodeId),

next_url_id: ?UrlId.Int,
urls_to_images: std.AutoArrayHashMapUnmanaged(UrlId, zss.Images.Handle),

testing: Testing,

pub fn init(allocator: Allocator) Environment {
    return Environment{
        .allocator = allocator,

        .type_names = .init(.{
            .max_size = TypeName.max_unique_values,
            // TODO: This is the wrong value. Case sensitivity of type names depends on the document language.
            //       See https://www.w3.org/TR/selectors-4/#case-sensitive
            .case = .insensitive,
        }),
        .attribute_names = .init(.{
            .max_size = AttributeName.max_unique_values,
            // TODO: This is the wrong value. Case sensitivity of attribute names depends on the document language.
            //       See https://www.w3.org/TR/selectors-4/#case-sensitive
            .case = .insensitive,
        }),
        .id_names = .init(.{
            .max_size = IdName.max_unique_values,
            // TODO: This is the wrong value. Case sensitivity of IDs depends on whether the document is in "quirks mode".
            //       See https://www.w3.org/TR/selectors-4/#id-selectors
            .case = .sensitive,
        }),
        .class_names = .init(.{
            .max_size = ClassName.max_unique_values,
            // TODO: This is the wrong value. Case sensitivity of class names depends on whether the document is in "quirks mode".
            //       See https://www.w3.org/TR/selectors-4/#class-html
            .case = .sensitive,
        }),
        .attribute_values = .init(.{
            .max_size = AttributeValueId.max_unique_values,
            // TODO: This is the wrong value. Case sensitivity of attribute values depends on the document language.
            //       Furthermore selectors can also choose their own sensitivity.
            //       See https://www.w3.org/TR/selectors-4/#attribute-case
            .case = .insensitive,
        }),
        .namespaces = .{},
        .texts = .{},

        .decls = .{},
        .cascade_list = .{},

        .tree_interface = .default,
        .next_node_group = 0,
        .root_node = null,
        .node_properties = .{},
        .ids_to_nodes = .empty,

        .next_url_id = 0,
        .urls_to_images = .empty,

        .testing = .{},
    };
}

pub fn deinit(env: *Environment) void {
    env.type_names.deinit(env.allocator);
    env.attribute_names.deinit(env.allocator);
    env.id_names.deinit(env.allocator);
    env.class_names.deinit(env.allocator);
    env.attribute_values.deinit(env.allocator);
    env.namespaces.deinit(env.allocator);
    env.texts.deinit(env.allocator);

    env.decls.deinit(env.allocator);
    env.cascade_list.deinit(env.allocator);

    env.node_properties.deinit(env.allocator);
    env.ids_to_nodes.deinit(env.allocator);

    env.urls_to_images.deinit(env.allocator);
}

pub const Namespaces = struct {
    // TODO: Consider using zss.StringInterner
    map: std.StringArrayHashMapUnmanaged(void) = .empty,

    /// A handle to an interned namespace string.
    pub const Id = enum(u8) {
        /// Represents the null namespace, a.k.a. no namespace.
        none = max_unique_values,
        /// Not a valid namespace id. This value is used in selectors to represent any namespace.
        any = max_unique_values + 1,
        _,

        pub const max_unique_values = (1 << 8) - 2;
    };

    pub fn deinit(namespaces: *Namespaces, allocator: Allocator) void {
        for (namespaces.map.keys()) |key| {
            allocator.free(key);
        }
        namespaces.map.deinit(allocator);
    }
};

pub const NamespaceLocation = union(enum) {
    string_token: TokenSource.Location,
    url_token: TokenSource.Location,
};

pub fn addNamespace(env: *Environment, src_loc: NamespaceLocation, source: TokenSource) !Namespaces.Id {
    try env.namespaces.map.ensureUnusedCapacity(env.allocator, 1);
    const namespace = switch (src_loc) {
        .string_token => |location| try source.copyString(location, .{ .allocator = env.allocator }),
        .url_token => |location| try source.copyUrl(location, .{ .allocator = env.allocator }),
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

/// A handle to an interned type name string.
pub const TypeName = enum(u20) {
    /// A type name that compares as not equal to any other type name (including other anonymous type names).
    anonymous = max_unique_values,
    /// Not a valid type name. This value is used in selectors to represent the '*' type name selector.
    any = max_unique_values + 1,
    _,

    pub const max_unique_values = (1 << 20) - 2;
};

pub fn addTypeName(
    env: *Environment,
    /// The location of an <ident-token>.
    identifier: TokenSource.Location,
    source: TokenSource,
) !TypeName {
    const index = try env.type_names.addFromIdentToken(env.allocator, identifier, source);
    const type_name: TypeName = @enumFromInt(index);
    assert(type_name != .anonymous);
    assert(type_name != .any);
    return type_name;
}

/// A handle to an interned attribute name string.
pub const AttributeName = enum(u20) {
    /// An attribute name that compares as not equal to any other attribute name (including other anonymous attribute names).
    anonymous = max_unique_values,
    _,

    pub const max_unique_values = (1 << 20) - 1;
};

pub fn addAttributeName(
    env: *Environment,
    /// The location of an <ident-token>.
    identifier: TokenSource.Location,
    source: TokenSource,
) !AttributeName {
    const index = try env.attribute_names.addFromIdentToken(env.allocator, identifier, source);
    const attribute_name: AttributeName = @enumFromInt(index);
    assert(attribute_name != .anonymous);
    return attribute_name;
}

/// A handle to an interned ID string.
pub const IdName = enum(u32) {
    _,
    pub const max_unique_values = 1 << 32;
};

pub fn addIdName(
    env: *Environment,
    /// The location of an ID <hash-token>.
    hash_id: TokenSource.Location,
    source: TokenSource,
) !IdName {
    const index = try env.id_names.addFromHashIdTokenSensitive(env.allocator, hash_id, source);
    return @enumFromInt(index);
}

/// A handle to an interned class name string.
pub const ClassName = enum(u32) {
    _,
    pub const max_unique_values = 1 << 32;
};

pub fn addClassName(
    env: *Environment,
    /// The location of an <ident-token>.
    identifier: TokenSource.Location,
    source: TokenSource,
) !ClassName {
    const index = try env.class_names.addFromIdentTokenSensitive(env.allocator, identifier, source);
    return @enumFromInt(index);
}

pub const AttributeValueId = enum(u32) {
    _,
    const max_unique_values = 1 << 32;
};

pub fn addAttributeValueIdent(
    env: *Environment,
    /// The location of an <ident-token>.
    identifier: TokenSource.Location,
    source: TokenSource,
) !AttributeValueId {
    const index = try env.attribute_values.addFromIdentToken(env.allocator, identifier, source);
    return @enumFromInt(index);
}

pub fn addAttributeValueString(
    env: *Environment,
    /// The location of a <string-token>.
    string: TokenSource.Location,
    source: TokenSource,
) !AttributeValueId {
    const index = try env.attribute_values.addFromStringToken(env.allocator, string, source);
    return @enumFromInt(index);
}

pub const Texts = struct {
    list: std.ArrayListUnmanaged([]const u8) = .empty,
    arena: std.heap.ArenaAllocator.State = .{},

    pub fn deinit(texts: *Texts, allocator: Allocator) void {
        texts.list.deinit(allocator);
        var arena = texts.arena.promote(allocator);
        defer texts.arena = arena.state;
        arena.deinit();
    }
};

pub const TextId = enum(u32) {
    _,
    pub const empty_string: TextId = @enumFromInt(0);
};

pub fn addTextFromStringToken(env: *Environment, string: TokenSource.Location, source: TokenSource) !TextId {
    var iterator = source.stringTokenIterator(string);
    if (iterator.next() == null) return .empty_string;
    const id = std.math.cast(std.meta.Tag(TextId), try std.math.add(usize, 1, env.texts.list.items.len)) orelse return error.OutOfTexts;

    try env.texts.list.ensureUnusedCapacity(env.allocator, 1);
    var arena = env.texts.arena.promote(env.allocator);
    defer env.texts.arena = arena.state;
    env.texts.list.appendAssumeCapacity(try source.copyString(string, .{ .allocator = arena.allocator() })); // TODO: Arena allocation wastes memory here
    return @enumFromInt(id);
}

pub fn addTextFromString(env: *Environment, string: []const u8) !TextId {
    if (string.len == 0) return .empty_string;
    const id = std.math.cast(std.meta.Tag(TextId), try std.math.add(usize, 1, env.texts.list.items.len)) orelse return error.OutOfTexts;

    try env.texts.list.ensureUnusedCapacity(env.allocator, 1);
    var arena = env.texts.arena.promote(env.allocator);
    defer env.texts.arena = arena.state;
    env.texts.list.appendAssumeCapacity(try arena.allocator().dupe(u8, string));
    return @enumFromInt(id);
}

pub fn getText(env: *const Environment, id: TextId) []const u8 {
    const int = @intFromEnum(id);
    if (int == 0) return "";
    return env.texts.list.items[int - 1];
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

pub fn linkUrlToImage(env: *Environment, url: UrlId, image: zss.Images.Handle) !void {
    try env.urls_to_images.put(env.allocator, url, image);
}

pub const NodeGroup = enum(usize) { _ };

pub fn addNodeGroup(env: *Environment) !NodeGroup {
    const int = if (env.next_node_group) |*int| int else return error.OutOfNodeGroups;
    defer env.next_node_group = std.math.add(std.meta.Tag(NodeGroup), int.*, 1) catch null;
    return @enumFromInt(int.*);
}

pub const TreeInterface = struct {
    context: *const anyopaque,
    vtable: *const VTable,

    pub const default: TreeInterface = .{
        .context = undefined,
        .vtable = &.{
            .node_edge = VTable.defaultNodeEdge,
        },
    };

    pub const VTable = struct {
        node_edge: *const fn (context: *const anyopaque, node: NodeId, edge: Edge) ?NodeId,

        pub fn defaultNodeEdge(_: *const anyopaque, _: NodeId, _: Edge) ?NodeId {
            unreachable;
        }
    };

    pub const Edge = enum {
        parent,
        previous_sibling,
        next_sibling,
        first_child,
        last_child,
    };
};

// TODO: Make this a normal struct
pub const NodeId = packed struct {
    group: NodeGroup,
    value: usize,
    // TODO: generational nodes?

    pub fn parent(node: NodeId, env: *const Environment) ?NodeId {
        return env.tree_interface.vtable.node_edge(env.tree_interface.context, node, .parent);
    }

    pub fn previousSibling(node: NodeId, env: *const Environment) ?NodeId {
        return env.tree_interface.vtable.node_edge(env.tree_interface.context, node, .previous_sibling);
    }

    pub fn nextSibling(node: NodeId, env: *const Environment) ?NodeId {
        return env.tree_interface.vtable.node_edge(env.tree_interface.context, node, .next_sibling);
    }

    pub fn firstChild(node: NodeId, env: *const Environment) ?NodeId {
        return env.tree_interface.vtable.node_edge(env.tree_interface.context, node, .first_child);
    }

    pub fn lastChild(node: NodeId, env: *const Environment) ?NodeId {
        return env.tree_interface.vtable.node_edge(env.tree_interface.context, node, .last_child);
    }
};

// TODO: Consider having a category for uninitialized nodes.
pub const NodeCategory = enum { element, text };

// TODO: Make this a normal struct
pub const ElementType = packed struct {
    namespace: Namespaces.Id,
    name: TypeName,
};

pub const ElementAttribute = packed struct {
    namespace: Namespaces.Id,
    name: AttributeName,
};

pub const NodeProperty = struct {
    category: NodeCategory = .text,
    type: ElementType = .{ .namespace = .none, .name = .anonymous },
    cascaded_values: zss.CascadedValues = .{},
    text: TextId = .empty_string,
};

const NodeProperties = struct {
    // TODO: Better memory management

    map: std.AutoHashMapUnmanaged(NodeId, NodeProperty) = .empty,
    /// Only used to store cascaded values.
    arena: std.heap.ArenaAllocator.State = .{},

    fn deinit(np: *NodeProperties, allocator: Allocator) void {
        np.map.deinit(allocator);
        np.arena.promote(allocator).deinit();
    }

    fn getOrPutNode(np: *NodeProperties, allocator: Allocator, node: NodeId) !*NodeProperty {
        const gop = try np.map.getOrPut(allocator, node);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{};
        }
        return gop.value_ptr;
    }
};

pub fn setNodeProperty(
    env: *Environment,
    comptime field: std.meta.FieldEnum(NodeProperty),
    node: NodeId,
    value: @FieldType(NodeProperty, @tagName(field)),
) !void {
    const value_ptr = try env.node_properties.getOrPutNode(env.allocator, node);
    @field(value_ptr, @tagName(field)) = value;
}

pub fn getNodeProperty(
    env: *const Environment,
    comptime field: std.meta.FieldEnum(NodeProperty),
    node: NodeId,
) @FieldType(NodeProperty, @tagName(field)) {
    const value_ptr: *const NodeProperty = env.node_properties.map.getPtr(node) orelse &.{};
    return @field(value_ptr, @tagName(field));
}

pub fn getNodePropertyPtr(
    env: *Environment,
    comptime field: std.meta.FieldEnum(NodeProperty),
    node: NodeId,
) !*@FieldType(NodeProperty, @tagName(field)) {
    const value_ptr = try env.node_properties.getOrPutNode(env.allocator, node);
    return &@field(value_ptr, @tagName(field));
}

/// Returns `error.IdAlreadyExists` if `id` was already registered.
pub fn registerId(env: *Environment, id: IdName, node: NodeId) !void {
    const gop = try env.ids_to_nodes.getOrPut(env.allocator, id);
    // TODO: If `gop.found_existing == true`, the existing element may have been destroyed, so consider allowing the Id to be reused.
    if (gop.found_existing and gop.value_ptr.* != node) return error.IdAlreadyExists;
    gop.value_ptr.* = node;
}

pub fn getElementById(env: *const Environment, id: IdName) ?NodeId {
    // TODO: Even if an element was returned, it could have been destroyed.
    return env.ids_to_nodes.get(id);
}

pub const Testing = struct {
    pub fn expectEqualTypeNames(testing: *const Testing, expected: []const u8, type_name: TypeName) !void {
        const env: *const Environment = @alignCast(@fieldParentPtr("testing", testing));
        var iterator = env.type_names.iterator(@intFromEnum(type_name));
        try std.testing.expect(iterator.eql(expected));
    }
};
