//! Provides an interface that can represent a node in any document tree structure.

const Node = @This();
const zss = @import("zss.zig");

vtable: *const VTable,
id: Id,

pub const Id = enum(u32) { _ };

pub const VTable = struct {
    /// Return the node that has the relationship to `node` specified by `which`, or
    /// `null` if there is no such node.
    edge: *const fn (node: *Node, which: Edge) ?*Node,
};

pub const Edge = enum {
    parent,
    next_sibling,
    previous_sibling,
    first_child,
    last_child,
};

pub const Category = enum { element, text };

pub const Type = packed struct {
    namespace: zss.Environment.Namespaces.Id,
    name: zss.Environment.NameId,
};

pub fn parent(node: *Node) ?*Node {
    return node.vtable.edge(node, .parent);
}

pub fn nextSibling(node: *Node) ?*Node {
    return node.vtable.edge(node, .next_sibling);
}

pub fn previousSibling(node: *Node) ?*Node {
    return node.vtable.edge(node, .previous_sibling);
}

pub fn firstChild(node: *Node) ?*Node {
    return node.vtable.edge(node, .first_child);
}

pub fn lastChild(node: *Node) ?*Node {
    return node.vtable.edge(node, .last_child);
}
