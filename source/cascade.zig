const std = @import("std");
const Allocator = std.mem.Allocator;

const zss = @import("zss.zig");
const selectors = zss.selectors;
const Block = zss.property.Declarations.Block;
const Element = zss.ElementTree.Element;

pub const Tree = struct {
    user: Node = .{ .inner = .empty },
    author: Node = .{ .inner = .empty },
    user_agent: Node = .{ .inner = .empty },
    nodes: std.ArrayListUnmanaged(*Node) = .empty,

    pub const Node = union(enum) {
        leaf: *const Source,
        inner: std.ArrayListUnmanaged(*Node),
    };

    pub fn deinit(tree: *Tree, allocator: Allocator) void {
        for (tree.nodes.items) |node| {
            switch (node.*) {
                .leaf => {},
                .inner => |*list| list.deinit(allocator),
            }
            allocator.destroy(node);
        }
        tree.nodes.deinit(allocator);
    }

    pub fn createNode(tree: *Tree, allocator: Allocator, value: Node) !*Node {
        try tree.nodes.ensureUnusedCapacity(allocator, 1);
        const node = try allocator.create(Node);
        node.* = value;
        tree.nodes.appendAssumeCapacity(node);
        return node;
    }
};

pub const Origin = enum { user, author, user_agent };

pub const Source = struct {
    style_attrs_important: std.AutoHashMapUnmanaged(Element, Block) = .empty,
    style_attrs_normal: std.AutoHashMapUnmanaged(Element, Block) = .empty,
    selectors_important: std.MultiArrayList(SelectorBlock) = .empty,
    selectors_normal: std.MultiArrayList(SelectorBlock) = .empty,
    selector_data: std.ArrayListUnmanaged(selectors.Code) = .empty,

    pub fn deinit(source: *Source, allocator: Allocator) void {
        source.style_attrs_important.deinit(allocator);
        source.style_attrs_normal.deinit(allocator);
        source.selectors_important.deinit(allocator);
        source.selectors_normal.deinit(allocator);
        source.selector_data.deinit(allocator);
    }
};

pub const SelectorBlock = struct {
    selector: selectors.Size,
    block: Block,
};
