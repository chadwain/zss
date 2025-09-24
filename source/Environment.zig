const Environment = @This();

const zss = @import("zss.zig");
const cascade = zss.cascade;
const syntax = zss.syntax;
const Ast = syntax.Ast;
const Declarations = zss.Declarations;
const IdentifierSet = syntax.IdentifierSet;
const TokenSource = syntax.TokenSource;
const Stylesheet = zss.Stylesheet;

const std = @import("std");
const assert = std.debug.assert;
const panic = std.debug.panic;
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const MultiArrayList = std.MultiArrayList;

allocator: Allocator,
type_or_attribute_names: IdentifierSet,
id_or_class_names: IdentifierSet,
texts: Texts,
attribute_values: zss.StringInterner,
namespaces: Namespaces,

decls: Declarations,
cascade_list: cascade.List,

tree_interface: TreeInterface,
next_node_group: ?std.meta.Tag(NodeGroup),
root_node: ?NodeId,
node_properties: NodeProperties,
ids_to_nodes: std.AutoHashMapUnmanaged(IdId, NodeId),

next_url_id: ?UrlId.Int,
urls_to_images: std.AutoArrayHashMapUnmanaged(UrlId, zss.Images.Handle),

pub fn init(allocator: Allocator) Environment {
    return Environment{
        .allocator = allocator,

        .type_or_attribute_names = .{
            .max_size = NameId.max_value,
            // TODO: This is the wrong value. Case sensitivity of type names and attribute names depends on the document language.
            //       See https://www.w3.org/TR/selectors-4/#case-sensitive
            .case = .insensitive,
        },
        .id_or_class_names = .{
            .max_size = IdId.max_value,
            // TODO: This is the wrong value. Case sensitivity of IDs and class names depends on whether the document is in "quirks mode".
            //       See https://www.w3.org/TR/selectors-4/#id-selectors
            //       See https://www.w3.org/TR/selectors-4/#class-html
            .case = .sensitive,
        },
        .texts = .{},
        .attribute_values = .init(.{
            .max_size = AttributeValueId.num_unique_values,
            // TODO: This is the wrong value. Case sensitivity of attribute values depends on the document language.
            //       Furthermore selectors can also choose their own sensitivity.
            //       See https://www.w3.org/TR/selectors-4/#attribute-case
            .case = .insensitive,
        }),
        .namespaces = .{},

        .decls = .{},
        .cascade_list = .{},

        .tree_interface = .default,
        .next_node_group = 0,
        .root_node = null,
        .node_properties = .{},
        .ids_to_nodes = .empty,

        .next_url_id = 0,
        .urls_to_images = .empty,
    };
}

pub fn deinit(env: *Environment) void {
    env.type_or_attribute_names.deinit(env.allocator);
    env.id_or_class_names.deinit(env.allocator);
    env.texts.deinit(env.allocator);
    env.namespaces.deinit(env.allocator);
    env.decls.deinit(env.allocator);
    env.cascade_list.deinit(env.allocator);
    env.node_properties.deinit(env.allocator);
    env.ids_to_nodes.deinit(env.allocator);
    env.urls_to_images.deinit(env.allocator);
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

    pub fn deinit(namespaces: *Namespaces, allocator: Allocator) void {
        for (namespaces.map.keys()) |key| {
            allocator.free(key);
        }
        namespaces.map.deinit(allocator);
    }
};

pub fn addNamespace(env: *Environment, ast: Ast, source: TokenSource, index: Ast.Index) !Namespaces.Id {
    try env.namespaces.map.ensureUnusedCapacity(env.allocator, 1);
    const location = index.location(ast);
    const namespace = try switch (index.tag(ast)) {
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
    if (iterator.next(source) == null) return .empty_string;
    const id = std.math.cast(std.meta.Tag(TextId), try std.math.add(usize, 1, env.texts.list.items.len)) orelse return error.OutOfTexts;

    try env.texts.list.ensureUnusedCapacity(env.allocator, 1);
    var arena = env.texts.arena.promote(env.allocator);
    defer env.texts.arena = arena.state;
    env.texts.list.appendAssumeCapacity(try source.copyString(string, arena.allocator())); // TODO: Arena allocation wastes memory here
    return @enumFromInt(id);
}

pub fn addTextFromString(env: *Environment, text: []const u8) !TextId {
    if (text.len == 0) return .empty_string;
    const id = std.math.cast(std.meta.Tag(TextId), try std.math.add(usize, 1, env.texts.list.items.len)) orelse return error.OutOfTexts;

    try env.texts.list.ensureUnusedCapacity(env.allocator, 1);
    var arena = env.texts.arena.promote(env.allocator);
    defer env.texts.arena = arena.state;
    env.texts.list.appendAssumeCapacity(try arena.allocator().dupe(u8, text));
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

pub const NodeType = packed struct {
    namespace: Namespaces.Id,
    name: NameId,
};

pub const NodeProperty = struct {
    category: NodeCategory = .text,
    type: NodeType = .{ .namespace = .none, .name = .anonymous },
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
pub fn registerId(env: *Environment, id: IdId, node: NodeId) !void {
    const gop = try env.ids_to_nodes.getOrPut(env.allocator, id);
    // TODO: If `gop.found_existing == true`, the existing element may have been destroyed, so consider allowing the Id to be reused.
    if (gop.found_existing and gop.value_ptr.* != node) return error.IdAlreadyExists;
    gop.value_ptr.* = node;
}

pub fn getElementById(env: *const Environment, id: IdId) ?NodeId {
    // TODO: Even if an element was returned, it could have been destroyed.
    return env.ids_to_nodes.get(id);
}
