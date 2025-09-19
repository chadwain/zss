const NodeTree = @This();

const zss = @import("../zss.zig");
const Environment = zss.Environment;

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

nodes: std.MultiArrayList(NodeData).Slice,
free_list_head: Size,
free_list_len: Size,
node_group: Environment.NodeGroup,

// If a Node is in the free list, then node.next_sibling.index stores the next item in the free list.
const NodeData = struct {
    generation: Generation,
    parent: Node,
    first_child: Node,
    last_child: Node,
    // When a node is destroyed, this field is re-purposed to store the next free list entry.
    next_sibling: Node,
    previous_sibling: Node,

    const fields = std.enums.values(std.meta.FieldEnum(NodeData));
};

const Generation = u16;
const max_generation = std.math.maxInt(Generation);

pub const Size = u16;
const max_size = std.math.maxInt(Size);

pub const Node = packed struct {
    generation: Generation,
    index: Size,

    const null_node = Node{ .generation = 0, .index = max_size };

    fn assertGeneration(node: Node, tree: *const NodeTree) void {
        assert(node.generation == tree.nodes.items(.generation)[node.index]);
    }

    pub fn parent(node: Node, tree: *const NodeTree) ?Node {
        node.assertGeneration(tree);
        const result = tree.nodes.items(.parent)[node.index];
        if (result == null_node) return null;
        return result;
    }

    pub fn firstChild(node: Node, tree: *const NodeTree) ?Node {
        node.assertGeneration(tree);
        const result = tree.nodes.items(.first_child)[node.index];
        if (result == null_node) return null;
        return result;
    }

    pub fn lastChild(node: Node, tree: *const NodeTree) ?Node {
        node.assertGeneration(tree);
        const result = tree.nodes.items(.last_child)[node.index];
        if (result == null_node) return null;
        return result;
    }

    pub fn nextSibling(node: Node, tree: *const NodeTree) ?Node {
        node.assertGeneration(tree);
        const result = tree.nodes.items(.next_sibling)[node.index];
        if (result == null_node) return null;
        return result;
    }

    pub fn previousSibling(node: Node, tree: *const NodeTree) ?Node {
        node.assertGeneration(tree);
        const result = tree.nodes.items(.previous_sibling)[node.index];
        if (result == null_node) return null;
        return result;
    }

    pub fn toZssNode(node: Node, tree: *const NodeTree) Environment.NodeId {
        node.assertGeneration(tree);
        return .{ .group = tree.node_group, .value = @as(u32, @bitCast(node)) };
    }

    pub fn fromZssNode(tree: *const NodeTree, zss_node: Environment.NodeId) Node {
        const node: Node = @bitCast(@as(u32, @truncate(zss_node.value)));
        node.assertGeneration(tree);
        return node;
    }
};

pub fn init(env: *Environment) !NodeTree {
    return .{
        .nodes = .empty,
        .free_list_head = max_size,
        .free_list_len = 0,
        .node_group = try env.addNodeGroup(),
    };
}

pub fn deinit(tree: *NodeTree, allocator: Allocator) void {
    tree.nodes.deinit(allocator);
}

/// Creates a new node.
/// The node has undefined data and must be initialized by calling `initNode`.
pub fn allocateNode(tree: *NodeTree, allocator: Allocator) !Node {
    var result: [1]Node = undefined;
    try tree.allocateNodes(allocator, &result);
    return result[0];
}

/// Populates `buffer` with `buffer.len` newly-created nodes.
/// The nodes have undefined data and must be initialized by calling `initNode`.
pub fn allocateNodes(tree: *NodeTree, allocator: Allocator, buffer: []Node) !void {
    const num_extra_nodes = buffer.len -| tree.free_list_len;
    const old_nodes_len = tree.nodes.len;
    if (num_extra_nodes >= max_size - old_nodes_len) return error.NodeTreeMaxSizeExceeded;
    tree.free_list_len = @intCast(@as(usize, tree.free_list_len) -| buffer.len);

    {
        var list = tree.nodes.toMultiArrayList();
        defer tree.nodes = list.slice();
        try list.resize(allocator, old_nodes_len + num_extra_nodes);
    }

    var free_node = tree.free_list_head;
    var buffer_index: Size = 0;
    while (true) {
        if (buffer_index == buffer.len) {
            tree.free_list_head = free_node;
            return;
        }
        if (free_node == max_size) break;
        buffer[buffer_index] = Node{ .index = free_node, .generation = tree.nodes.items(.generation)[free_node] };
        buffer_index += 1;
        free_node = tree.nodes.items(.next_sibling)[free_node].index;
    }

    // Free list is completely used up.
    tree.free_list_head = max_size;
    for (buffer[buffer_index..], old_nodes_len..) |*node, node_index| {
        node.* = Node{ .index = @intCast(node_index), .generation = 0 };
        tree.nodes.items(.generation)[node_index] = 0;
    }
}

// pub fn destroyNode(tree: *NodeTree, node: Node) void {
//     tree.assertGeneration(node);

//     var data = @as(NodeData, undefined);
//     data.generation = node.generation;

//     if (data.generation != max_generation) {
//         // This node can be used again: add it to the free list.
//         data.generation += 1;
//         data.next_sibling = .{ .index = tree.free_list_head, .generation = undefined };
//         tree.free_list_head = node.index;
//         tree.free_list_len += 1;
//     }

//     const parent_node = tree.nodes.items(.parent)[node.index];
//     if (!parent_node.eqlNull()) {
//         const parent_first_child = &tree.nodes.items(.first_child)[parent_node.index];
//         const parent_last_child = &tree.nodes.items(.last_child)[parent_node.index];
//         if (parent_first_child.eql(node)) parent_first_child.* = Node.null_node;
//         if (parent_last_child.eql(node)) parent_last_child.* = Node.null_node;
//     }

//     const previous_sibling = tree.nodes.items(.previous_sibling)[node.index];
//     const next_sibling = tree.nodes.items(.next_sibling)[node.index];
//     if (!previous_sibling.eqlNull()) tree.nodes.items(.next_sibling)[previous_sibling.index] = next_sibling;
//     if (!next_sibling.eqlNull()) tree.nodes.items(.previous_sibling)[next_sibling.index] = previous_sibling;

//     tree.nodes.set(node.index, data);
// }

pub const NodePlacement = union(enum) {
    orphan,
    first_child_of: Node,
    last_child_of: Node,
};

/// Initializes a node and places it at the specified spot in the tree.
/// If the payload of `placement` is an Node, it is a prerequisite that that node must have already been initialized.
pub fn initNode(tree: *const NodeTree, node: Node, placement: NodePlacement, env: *Environment, category: Environment.NodeCategory) !void {
    node.assertGeneration(tree);
    const zss_node = node.toZssNode(tree);

    var data: NodeData = undefined;
    data.first_child = Node.null_node;
    data.last_child = Node.null_node;
    switch (placement) {
        .orphan => {
            data.parent = Node.null_node;
            data.next_sibling = Node.null_node;
            data.previous_sibling = Node.null_node;
        },
        .first_child_of => |parent_node| {
            parent_node.assertGeneration(tree);
            switch (env.getNodeProperty(.category, parent_node.toZssNode(tree))) {
                .element => {},
                .text => unreachable,
            }

            const former_first_child = tree.nodes.items(.first_child)[parent_node.index];
            tree.nodes.items(.first_child)[parent_node.index] = node;
            if (former_first_child == Node.null_node) {
                tree.nodes.items(.last_child)[parent_node.index] = node;
            } else {
                tree.nodes.items(.previous_sibling)[former_first_child.index] = node;
            }

            data.parent = parent_node;
            data.next_sibling = former_first_child;
            data.previous_sibling = Node.null_node;
        },
        .last_child_of => |parent_node| {
            parent_node.assertGeneration(tree);
            switch (env.getNodeProperty(.category, parent_node.toZssNode(tree))) {
                .element => {},
                .text => unreachable,
            }

            const former_last_child = tree.nodes.items(.last_child)[parent_node.index];
            tree.nodes.items(.last_child)[parent_node.index] = node;
            if (former_last_child == Node.null_node) {
                tree.nodes.items(.first_child)[parent_node.index] = node;
            } else {
                tree.nodes.items(.next_sibling)[former_last_child.index] = node;
            }

            data.parent = parent_node;
            data.next_sibling = Node.null_node;
            data.previous_sibling = former_last_child;
        },
    }

    inline for (NodeData.fields) |field| {
        if (field != .generation) {
            tree.nodes.items(field)[node.index] = @field(data, @tagName(field));
        }
    }

    try env.setNodeProperty(.category, zss_node, category);
}

pub fn setTreeInterface(tree: *const NodeTree, root_node: Node, env: *Environment) void {
    env.root_node = root_node.toZssNode(tree);
    env.tree_interface = .{
        .context = tree,
        .vtable = comptime &.{
            .node_edge = tree_interface_fns.node_edge,
        },
    };
}

pub const tree_interface_fns = struct {
    pub fn node_edge(context: *const anyopaque, zss_node: Environment.NodeId, edge: Environment.TreeInterface.Edge) ?Environment.NodeId {
        const tree: *const NodeTree = @alignCast(@ptrCast(context));
        assert(tree.node_group == zss_node.group);

        const node: Node = .fromZssNode(tree, zss_node);
        const result_node = switch (edge) {
            .parent => node.parent(tree),
            .previous_sibling => node.previousSibling(tree),
            .next_sibling => node.nextSibling(tree),
            .first_child => node.firstChild(tree),
            .last_child => node.lastChild(tree),
        } orelse return null;
        return result_node.toZssNode(tree);
    }
};

test "node tree" {
    const allocator = std.testing.allocator;

    var env = Environment.init(allocator);
    defer env.deinit();

    var tree = try init(&env);
    defer tree.deinit(allocator);

    const root = try tree.allocateNode(allocator);
    try tree.initNode(root, .orphan, &env, .element);
    // tree.destroyNode(root);
}
