const Node = @This();

vtable: *const VTable,

pub const VTable = struct {
    edge: *const fn (node: *Node, edge: Edge) ?*Node,
};

pub const Edge = enum {
    parent,
    next_sibling,
    previous_sibling,
    first_child,
    last_child,
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
