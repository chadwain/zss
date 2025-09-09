const zss = @import("zss.zig");
const AggregateTag = zss.property.aggregates.Tag;
const CascadedValues = zss.CascadedValues;
const Declarations = zss.Declarations;
const Environment = zss.Environment;
const Importance = Declarations.Importance;
const NamespaceId = Environment.Namespaces.Id;
const NameId = Environment.NameId;
const Specificity = zss.selectors.Specificity;
const TextId = Environment.TextId;

const std = @import("std");
const assert = std.debug.assert;
const panic = std.debug.panic;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const MultiArrayList = std.MultiArrayList;

const ElementTree = @This();

nodes: MultiArrayList(Node).Slice,
free_list_head: Size,
free_list_len: Size,
ids: std.AutoHashMapUnmanaged(Environment.IdId, Element),
arena: ArenaAllocator.State,

/// If a Node is in the free list, then node.next_sibling.index stores the next item in the free list, and
/// node.cascaded_values has its default value.
const Node = struct {
    generation: Generation,
    category: Category,
    parent: Element,
    first_child: Element,
    last_child: Element,
    // When a node is destroyed, this field is re-purposed to store the next free list entry.
    next_sibling: Element,
    previous_sibling: Element,

    fq_type: FqType,
    text: TextId,
    cascaded_values: CascadedValues,

    const fields = std.enums.values(std.meta.FieldEnum(Node));
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

    // TODO: Stop using "in-band" nullability
    pub fn eqlNull(self: Element) bool {
        return self.eql(null_element);
    }
};

pub const Category = enum {
    normal,
    text,
};

/// A fully-qualified type.
// TODO: This is identical to `zss.selectors.QualifiedName`
pub const FqType = struct {
    namespace: NamespaceId,
    name: NameId,

    fn assertValidElementType(fq_type: FqType) void {
        assert(fq_type.namespace != .any);
        assert(fq_type.name != .any);
    }
};

pub const init = ElementTree{
    .nodes = .empty,
    .free_list_head = max_size,
    .free_list_len = 0,
    .ids = .empty,
    .arena = .{},
};

pub fn deinit(tree: *ElementTree, allocator: Allocator) void {
    tree.nodes.deinit(allocator);
    tree.ids.deinit(allocator);

    var arena = tree.arena.promote(allocator);
    defer tree.arena = arena.state;
    arena.deinit();
}

/// Creates a new element.
/// The element has undefined data and must be initialized by calling `initElement`.
pub fn allocateElement(tree: *ElementTree, allocator: Allocator) !Element {
    var result: [1]Element = undefined;
    try tree.allocateElements(allocator, &result);
    return result[0];
}

/// Populates `buffer` with `buffer.len` newly-created elements.
/// The elements have undefined data and must be initialized by calling `initElement`.
pub fn allocateElements(tree: *ElementTree, allocator: Allocator, buffer: []Element) !void {
    const num_extra_nodes = buffer.len -| tree.free_list_len;
    const old_nodes_len = tree.nodes.len;
    if (num_extra_nodes >= max_size - old_nodes_len) return error.ElementTreeMaxSizeExceeded;
    tree.free_list_len = @intCast(@as(usize, tree.free_list_len) -| buffer.len);

    {
        var list = tree.nodes.toMultiArrayList();
        defer tree.nodes = list.slice();
        try list.resize(allocator, old_nodes_len + num_extra_nodes);
    }

    var free_element = tree.free_list_head;
    var buffer_index: Size = 0;
    while (true) {
        if (buffer_index == buffer.len) {
            tree.free_list_head = free_element;
            return;
        }
        if (free_element == max_size) break;
        buffer[buffer_index] = Element{ .index = free_element, .generation = tree.nodes.items(.generation)[free_element] };
        buffer_index += 1;
        free_element = tree.nodes.items(.next_sibling)[free_element].index;
    }

    // Free list is completely used up.
    tree.free_list_head = max_size;
    for (buffer[buffer_index..], old_nodes_len..) |*element, node_index| {
        element.* = Element{ .index = @intCast(node_index), .generation = 0 };
        tree.nodes.items(.generation)[node_index] = 0;
    }
}

pub fn destroyElement(tree: *ElementTree, element: Element) void {
    tree.assertGeneration(element);

    var node = @as(Node, undefined);
    node.generation = element.generation;

    if (node.generation != max_generation) {
        // This node can be used again: add it to the free list.
        node.generation += 1;
        node.next_sibling = .{ .index = tree.free_list_head, .generation = undefined };
        tree.free_list_head = element.index;
        tree.free_list_len += 1;
    }

    const parent_node = tree.nodes.items(.parent)[element.index];
    if (!parent_node.eqlNull()) {
        const parent_first_child = &tree.nodes.items(.first_child)[parent_node.index];
        const parent_last_child = &tree.nodes.items(.last_child)[parent_node.index];
        if (parent_first_child.eql(element)) parent_first_child.* = Element.null_element;
        if (parent_last_child.eql(element)) parent_last_child.* = Element.null_element;
    }

    const previous_sibling = tree.nodes.items(.previous_sibling)[element.index];
    const next_sibling = tree.nodes.items(.next_sibling)[element.index];
    if (!previous_sibling.eqlNull()) tree.nodes.items(.next_sibling)[previous_sibling.index] = next_sibling;
    if (!next_sibling.eqlNull()) tree.nodes.items(.previous_sibling)[next_sibling.index] = previous_sibling;

    tree.nodes.set(element.index, node);
}

pub const NodePlacement = union(enum) {
    orphan,
    first_child_of: Element,
    last_child_of: Element,
};

/// Initializes an element and places it at the specificied spot in the tree.
/// If the payload of `placement` is an Element, it is a prerequisite that that element must have already been initialized.
pub fn initElement(tree: *const ElementTree, element: Element, initial_category: Category, placement: NodePlacement) void {
    tree.assertGeneration(element);

    var node: Node = undefined;
    node.category = initial_category;
    node.first_child = Element.null_element;
    node.last_child = Element.null_element;
    switch (placement) {
        .orphan => {
            node.parent = Element.null_element;
            node.next_sibling = Element.null_element;
            node.previous_sibling = Element.null_element;
        },
        .first_child_of => |parent_node| {
            tree.assertGeneration(parent_node);
            switch (tree.nodes.items(.category)[parent_node.index]) {
                .normal => {},
                .text => unreachable,
            }

            const former_first_child = tree.nodes.items(.first_child)[parent_node.index];
            tree.nodes.items(.first_child)[parent_node.index] = element;
            if (former_first_child.eqlNull()) {
                tree.nodes.items(.last_child)[parent_node.index] = element;
            } else {
                tree.nodes.items(.previous_sibling)[former_first_child.index] = element;
            }

            node.parent = parent_node;
            node.next_sibling = former_first_child;
            node.previous_sibling = Element.null_element;
        },
        .last_child_of => |parent_node| {
            tree.assertGeneration(parent_node);
            switch (tree.nodes.items(.category)[parent_node.index]) {
                .normal => {},
                .text => unreachable,
            }

            const former_last_child = tree.nodes.items(.last_child)[parent_node.index];
            tree.nodes.items(.last_child)[parent_node.index] = element;
            if (former_last_child.eqlNull()) {
                tree.nodes.items(.first_child)[parent_node.index] = element;
            } else {
                tree.nodes.items(.next_sibling)[former_last_child.index] = element;
            }

            node.parent = parent_node;
            node.next_sibling = Element.null_element;
            node.previous_sibling = former_last_child;
        },
    }

    node.fq_type = .{ .namespace = .none, .name = .anonymous };
    node.text = .empty;
    node.cascaded_values = .{};

    inline for (Node.fields) |field| {
        if (field != .generation) {
            tree.nodes.items(field)[element.index] = @field(node, @tagName(field));
        }
    }
}

fn assertGeneration(tree: *const ElementTree, element: Element) void {
    assert(element.generation == tree.nodes.items(.generation)[element.index]);
}

fn assertIsNormal(tree: *const ElementTree, element: Element) void {
    tree.assertGeneration(element);
    assert(tree.nodes.items(.category)[element.index] == .normal);
}

fn assertIsText(tree: *const ElementTree, element: Element) void {
    tree.assertGeneration(element);
    assert(tree.nodes.items(.category)[element.index] == .text);
}

pub fn category(tree: *const ElementTree, element: Element) Category {
    tree.assertGeneration(element);
    return tree.nodes.items(.category)[element.index];
}

pub fn parent(tree: *const ElementTree, element: Element) Element {
    tree.assertGeneration(element);
    return tree.nodes.items(.parent)[element.index];
}

pub fn firstChild(tree: *const ElementTree, element: Element) Element {
    tree.assertIsNormal(element);
    return tree.nodes.items(.first_child)[element.index];
}

pub fn lastChild(tree: *const ElementTree, element: Element) Element {
    tree.assertIsNormal(element);
    return tree.nodes.items(.last_child)[element.index];
}

pub fn nextSibling(tree: *const ElementTree, element: Element) Element {
    tree.assertGeneration(element);
    return tree.nodes.items(.next_sibling)[element.index];
}

pub fn previousSibling(tree: *const ElementTree, element: Element) Element {
    tree.assertGeneration(element);
    return tree.nodes.items(.previous_sibling)[element.index];
}

pub fn fqType(tree: *const ElementTree, element: Element) FqType {
    tree.assertIsNormal(element);
    return tree.nodes.items(.fq_type)[element.index];
}

pub fn text(tree: *const ElementTree, element: Element) TextId {
    tree.assertIsText(element);
    return tree.nodes.items(.text)[element.index];
}

pub fn cascadedValues(tree: *const ElementTree, element: Element) CascadedValues {
    tree.assertIsNormal(element);
    return tree.nodes.items(.cascaded_values)[element.index];
}

pub fn setFqType(tree: *const ElementTree, element: Element, fq_type: FqType) void {
    tree.assertIsNormal(element);
    fq_type.assertValidElementType();
    tree.nodes.items(.fq_type)[element.index] = fq_type;
}

pub fn cascadedValuesPtr(tree: *const ElementTree, element: Element) *CascadedValues {
    tree.assertIsNormal(element);
    return &tree.nodes.items(.cascaded_values)[element.index];
}

pub fn setText(tree: *const ElementTree, element: Element, text_: TextId) void {
    tree.assertIsText(element);
    tree.nodes.items(.text)[element.index] = text_;
}

/// Returns `error.IdAlreadyExists` if `id` was already registered.
pub fn registerId(tree: *ElementTree, allocator: Allocator, id: Environment.IdId, element: Element) !void {
    tree.assertIsNormal(element);
    const gop = try tree.ids.getOrPut(allocator, id);
    // TODO: If `gop.found_existing == true`, the existing element may have been destroyed, so consider allowing the Id to be reused.
    if (gop.found_existing and gop.value_ptr.* != element) return error.IdAlreadyExists;
    gop.value_ptr.* = element;
}

pub fn getElementById(tree: *const ElementTree, id: Environment.IdId) ?Element {
    // TODO: Even if an element was returned, it could have been destroyed.
    return tree.ids.get(id);
}

test "element tree" {
    const allocator = std.testing.allocator;

    var tree = init;
    defer tree.deinit(allocator);

    const root = try tree.allocateElement(allocator);
    tree.initElement(root, .normal, .orphan);
    tree.destroyElement(root);
}
