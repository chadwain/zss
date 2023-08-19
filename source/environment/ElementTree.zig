const zss = @import("../../zss.zig");
const Environment = zss.Environment;
const NamespaceId = Environment.NamespaceId;
const NameId = Environment.NameId;

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const MultiArrayList = std.MultiArrayList;
const builtin = @import("builtin");

const ElementTree = @This();

nodes: MultiArrayList(Node) = .{},
free_list_head: Size = max_size,
free_list_len: Size = 0,

/// If a Node is in the free list, then node.next_sibling.index stores the next item in the free list.
const Node = struct {
    generation: Generation,
    first_child: Element,
    last_child: Element,
    next_sibling: Element,

    fq_type: FqType,
};

const Generation = u16;
const max_generation = std.math.maxInt(Generation);

pub const Size = u16;
const max_size = std.math.maxInt(Size);

/// A reference to a Node.
pub const Element = packed struct {
    generation: Generation,
    index: Size,

    pub const null_element = Element{ .index = max_size, .generation = 0 };

    pub fn eql(self: Element, other: Element) bool {
        return self.index == other.index and
            self.generation == other.generation;
    }

    pub fn eqlNull(self: Element) bool {
        return self.eql(null_element);
    }
};

/// A fully-qualified type.
pub const FqType = struct {
    namespace: NamespaceId,
    name: NameId,
};

pub fn deinit(tree: *ElementTree, allocator: Allocator) void {
    tree.nodes.deinit(allocator);
}

/// Creates a new element.
/// The element has undefined data and must be initialized.
/// Invalidates slices.
pub fn allocateElement(tree: *ElementTree, allocator: Allocator) !Element {
    var result: [1]Element = undefined;
    try tree.allocateElements(allocator, &result);
    return result[0];
}

/// Populates `buffer` with `buffer.len` newly-created elements.
/// The elements have undefined data and must be initialized.
/// Invalidates slices.
pub fn allocateElements(tree: *ElementTree, allocator: Allocator, buffer: []Element) !void {
    const num_extra_nodes = buffer.len -| tree.free_list_len;
    const old_nodes_len = tree.nodes.len;
    if (num_extra_nodes >= max_size - old_nodes_len) return error.Overflow;
    try tree.nodes.resize(allocator, old_nodes_len + num_extra_nodes);
    tree.free_list_len = @intCast(@as(usize, tree.free_list_len) -| buffer.len);
    const nodes = tree.nodes.slice();

    var free_element = tree.free_list_head;
    var buffer_index: Size = 0;
    while (true) {
        if (buffer_index == buffer.len) {
            tree.free_list_head = free_element;
            return;
        }
        if (free_element == max_size) break;
        buffer[buffer_index] = Element{ .index = free_element, .generation = nodes.items(.generation)[free_element] };
        buffer_index += 1;
        free_element = nodes.items(.next_sibling)[free_element].index;
    }

    // Free list is completely used up.
    tree.free_list_head = max_size;
    for (buffer[buffer_index..], old_nodes_len..) |*element, node_index| {
        element.* = Element{ .index = @intCast(node_index), .generation = 0 };
        nodes.items(.generation)[node_index] = 0;
    }
}

pub fn destroyElement(tree: *ElementTree, element: Element) void {
    var new_node_value = @as(Node, undefined);
    new_node_value.generation = tree.nodes.items(.generation)[element.index];
    assert(element.generation == new_node_value.generation);

    if (new_node_value.generation != max_generation) {
        // This node can be used again: add it to the free list.
        new_node_value.generation += 1;
        new_node_value.next_sibling = .{ .index = tree.free_list_head, .generation = undefined };
        tree.free_list_head = element.index;
        tree.free_list_len += 1;
    }

    tree.nodes.set(element.index, new_node_value);
}

pub fn slice(tree: *const ElementTree) Slice {
    const nodes = tree.nodes.slice();
    return Slice{
        .len = @intCast(nodes.len),
        .generation = nodes.items(.generation).ptr,
        .first_child = nodes.items(.first_child).ptr,
        .last_child = nodes.items(.last_child).ptr,
        .next_sibling = nodes.items(.next_sibling).ptr,
        .fq_type = nodes.items(.fq_type).ptr,
    };
}

pub const Slice = struct {
    len: Size,
    generation: [*]Generation,
    first_child: [*]Element,
    last_child: [*]Element,
    next_sibling: [*]Element,
    fq_type: [*]FqType,

    pub const Value = struct {
        fq_type: FqType,
    };

    pub const Field = std.meta.FieldEnum(Value);

    fn validateElement(self: Slice, element: Element) void {
        assert(element.index < self.len);
        assert(element.generation == self.generation[element.index]);
    }

    pub fn firstChild(self: Slice, element: Element) Element {
        self.validateElement(element);
        return self.first_child[element.index];
    }

    pub fn lastChild(self: Slice, element: Element) Element {
        self.validateElement(element);
        return self.last_child[element.index];
    }

    pub fn nextSibling(self: Slice, element: Element) Element {
        self.validateElement(element);
        return self.next_sibling[element.index];
    }

    pub fn set(self: Slice, comptime field: Field, element: Element, value: std.meta.fieldInfo(Value, field).type) void {
        self.validateElement(element);
        @field(self, @tagName(field))[element.index] = value;
    }

    pub fn get(self: Slice, comptime field: Field, element: Element) std.meta.fieldInfo(Value, field).type {
        self.validateElement(element);
        return @field(self, @tagName(field))[element.index];
    }

    pub fn ptr(self: Slice, comptime field: Field, element: Element) *std.meta.fieldInfo(Value, field).type {
        self.validateElement(element);
        return &@field(self, @tagName(field))[element.index];
    }

    pub const NodePlacement = enum {
        root,
        first_child_of,
        last_child_of,

        fn Payload(comptime tag: NodePlacement) type {
            return switch (tag) {
                .root => void,
                .first_child_of => Element,
                .last_child_of => Element,
            };
        }
    };

    /// Places an element at the specificied spot in the tree.
    /// If `payload` is an Element, it is a prerequisite that that element must have already been placed.
    pub fn placeElement(self: Slice, element: Element, comptime placement: NodePlacement, payload: placement.Payload()) void {
        self.validateElement(element);
        switch (placement) {
            .root => {
                self.first_child[element.index] = Element.null_element;
                self.last_child[element.index] = Element.null_element;
                self.next_sibling[element.index] = Element.null_element;
            },
            .first_child_of => {
                self.validateElement(payload);
                const former_first_child = self.first_child[payload.index];
                self.first_child[payload.index] = element;
                if (former_first_child.eqlNull()) {
                    self.last_child[payload.index] = element;
                }

                self.first_child[element.index] = Element.null_element;
                self.last_child[element.index] = Element.null_element;
                self.next_sibling[element.index] = former_first_child;
            },
            .last_child_of => {
                self.validateElement(payload);
                const former_last_child = self.last_child[payload.index];
                self.last_child[payload.index] = element;
                if (former_last_child.eqlNull()) {
                    self.first_child[payload.index] = element;
                } else {
                    self.next_sibling[former_last_child.index] = element;
                }

                self.first_child[element.index] = Element.null_element;
                self.last_child[element.index] = Element.null_element;
                self.next_sibling[element.index] = Element.null_element;
            },
        }
    }
};
