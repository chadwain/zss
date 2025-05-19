const zss = @import("zss.zig");
const AggregateTag = zss.property.aggregates.Tag;
const CascadedValues = zss.CascadedValues;
const Environment = zss.Environment;
const NamespaceId = Environment.Namespaces.Id;
const NameId = Environment.NameId;
const Specificity = zss.selectors.Specificity;

const std = @import("std");
const assert = std.debug.assert;
const panic = std.debug.panic;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const MultiArrayList = std.MultiArrayList;

const ElementTree = @This();
pub const Text = ?[]const u8;

nodes: MultiArrayList(Node) = .{},
free_list_head: Size = max_size,
free_list_len: Size = 0,
arena: ArenaAllocator,

/// If a Node is in the free list, then node.next_sibling.index stores the next item in the free list, and
/// node.cascaded_values has its default value.
const Node = struct {
    generation: Generation,
    category: Category,
    parent: Element,
    first_child: Element,
    last_child: Element,
    next_sibling: Element,
    previous_sibling: Element,

    fq_type: FqType,
    // TODO: text should be owned by ElementTree
    text: Text,
    cascaded_values: CascadedValues,
};

const Generation = u16;
const max_generation = std.math.maxInt(Generation);

pub const Size = u16;
const max_size = std.math.maxInt(Size);

/// A reference to a Node.
// TODO: Remove packed
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

pub const Category = enum {
    normal,
    text,
};

/// A fully-qualified type.
pub const FqType = struct {
    namespace: NamespaceId,
    name: NameId,
};

pub fn init(allocator: Allocator) ElementTree {
    return ElementTree{ .arena = ArenaAllocator.init(allocator) };
}

pub fn deinit(tree: *ElementTree) void {
    const allocator = tree.arena.child_allocator;
    tree.nodes.deinit(allocator);
    tree.arena.deinit();
}

/// Creates a new element.
/// The element has undefined data and must be initialized.
/// Invalidates slices.
pub fn allocateElement(tree: *ElementTree) !Element {
    var result: [1]Element = undefined;
    try tree.allocateElements(&result);
    return result[0];
}

/// Populates `buffer` with `buffer.len` newly-created elements.
/// The elements have undefined data and must be initialized.
/// Invalidates slices.
pub fn allocateElements(tree: *ElementTree, buffer: []Element) !void {
    const num_extra_nodes = buffer.len -| tree.free_list_len;
    const old_nodes_len = tree.nodes.len;
    if (num_extra_nodes >= max_size - old_nodes_len) return error.ElementTreeMaxSizeExceeded;
    const allocator = tree.arena.child_allocator;
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
        nodes.items(.cascaded_values)[node_index] = .{};
    }
}

// TODO: Consider moving this function into Slice
pub fn destroyElement(tree: *ElementTree, element: Element) void {
    var new_node_value = @as(Node, undefined);
    new_node_value.generation = tree.nodes.items(.generation)[element.index];
    assert(element.generation == new_node_value.generation);

    if (new_node_value.generation != max_generation) {
        // This node can be used again: add it to the free list.
        new_node_value.generation += 1;
        new_node_value.next_sibling = .{ .index = tree.free_list_head, .generation = undefined };
        new_node_value.cascaded_values = .{};
        tree.free_list_head = element.index;
        tree.free_list_len += 1;
    }

    const parent = tree.nodes.items(.parent)[element.index];
    if (!parent.eqlNull()) {
        const parent_first_child = &tree.nodes.items(.parent_first_child)[parent.index];
        const parent_last_child = &tree.nodes.items(.parent_last_child)[parent.index];
        if (parent_first_child.eql(element)) parent_first_child.* = Element.null_element;
        if (parent_last_child.eql(element)) parent_last_child.* = Element.null_element;
    }

    const previous_sibling = tree.nodes.items(.previous_sibling)[element.index];
    const next_sibling = tree.nodes.items(.next_sibling)[element.index];
    if (!previous_sibling.eqlNull()) tree.nodes.items(.next_sibling)[previous_sibling.index] = next_sibling;
    if (!next_sibling.eqlNull()) tree.nodes.items(.previous_sibling)[next_sibling.index] = previous_sibling;

    tree.nodes.set(element.index, new_node_value);
}

pub fn slice(tree: *ElementTree) Slice {
    const nodes = tree.nodes.slice();
    return Slice{
        .len = @intCast(nodes.len),
        .ptrs = .{
            .generation = nodes.items(.generation).ptr,

            .category = nodes.items(.category).ptr,
            .parent = nodes.items(.parent).ptr,
            .first_child = nodes.items(.first_child).ptr,
            .last_child = nodes.items(.last_child).ptr,
            .next_sibling = nodes.items(.next_sibling).ptr,
            .previous_sibling = nodes.items(.previous_sibling).ptr,

            .fq_type = nodes.items(.fq_type).ptr,
            .text = nodes.items(.text).ptr,
            .cascaded_values = nodes.items(.cascaded_values).ptr,
        },
        .arena = &tree.arena,
    };
}

pub const Slice = struct {
    len: Size,
    ptrs: struct {
        generation: [*]Generation,

        category: [*]Category,
        parent: [*]Element,
        first_child: [*]Element,
        last_child: [*]Element,
        next_sibling: [*]Element,
        previous_sibling: [*]Element,

        fq_type: [*]FqType,
        text: [*]Text,
        cascaded_values: [*]CascadedValues,
    },
    arena: *ArenaAllocator,

    fn validateElement(self: Slice, element: Element) void {
        assert(element.index < self.len);
        assert(element.generation == self.ptrs.generation[element.index]);
    }

    pub fn category(self: Slice, element: Element) Category {
        self.validateElement(element);
        return self.ptrs.category[element.index];
    }

    pub fn parent(self: Slice, element: Element) Element {
        self.validateElement(element);
        return self.ptrs.parent[element.index];
    }

    pub fn firstChild(self: Slice, element: Element) Element {
        self.validateElement(element);
        return self.ptrs.first_child[element.index];
    }

    pub fn lastChild(self: Slice, element: Element) Element {
        self.validateElement(element);
        return self.ptrs.last_child[element.index];
    }

    pub fn nextSibling(self: Slice, element: Element) Element {
        self.validateElement(element);
        return self.ptrs.next_sibling[element.index];
    }

    pub fn previousSibling(self: Slice, element: Element) Element {
        self.validateElement(element);
        return self.ptrs.previous_sibling[element.index];
    }

    pub const Field = enum {
        fq_type,
        text,
        cascaded_values,

        pub fn Type(comptime field: Field) type {
            return switch (field) {
                .fq_type => FqType,
                .text => Text,
                .cascaded_values => CascadedValues,
            };
        }

        pub fn default(comptime field: Field) field.Type() {
            return switch (field) {
                .fq_type => FqType{ .namespace = .none, .name = .anonymous },
                .text => @as(Text, null),
                .cascaded_values => CascadedValues{},
            };
        }
    };

    pub fn set(self: Slice, comptime field: Field, element: Element, value: field.Type()) void {
        self.validateElement(element);
        @field(self.ptrs, @tagName(field))[element.index] = value;
    }

    pub fn get(self: Slice, comptime field: Field, element: Element) field.Type() {
        self.validateElement(element);
        return @field(self.ptrs, @tagName(field))[element.index];
    }

    pub fn ptr(self: Slice, comptime field: Field, element: Element) *field.Type() {
        self.validateElement(element);
        return &@field(self.ptrs, @tagName(field))[element.index];
    }

    pub const NodePlacement = union(enum) {
        orphan,
        first_child_of: Element,
        last_child_of: Element,
    };

    /// Initializes an element and places it at the specificied spot in the tree.
    /// If `payload` is an Element, it is a prerequisite that that element must have already been initialized.
    pub fn initElement(self: Slice, element: Element, initial_category: Category, placement: NodePlacement) void {
        self.validateElement(element);
        self.ptrs.category[element.index] = initial_category;
        self.ptrs.first_child[element.index] = Element.null_element;
        self.ptrs.last_child[element.index] = Element.null_element;
        switch (placement) {
            .orphan => {
                self.ptrs.parent[element.index] = Element.null_element;
                self.ptrs.next_sibling[element.index] = Element.null_element;
                self.ptrs.previous_sibling[element.index] = Element.null_element;
            },
            .first_child_of => |payload| {
                self.validateElement(payload);
                switch (self.ptrs.category[payload.index]) {
                    .normal => {},
                    .text => unreachable,
                }

                const former_first_child = self.ptrs.first_child[payload.index];
                self.ptrs.first_child[payload.index] = element;
                if (former_first_child.eqlNull()) {
                    self.ptrs.last_child[payload.index] = element;
                } else {
                    self.ptrs.previous_sibling[former_first_child.index] = element;
                }

                self.ptrs.parent[element.index] = payload;
                self.ptrs.next_sibling[element.index] = former_first_child;
                self.ptrs.previous_sibling[element.index] = Element.null_element;
            },
            .last_child_of => |payload| {
                self.validateElement(payload);
                switch (self.ptrs.category[payload.index]) {
                    .normal => {},
                    .text => unreachable,
                }

                const former_last_child = self.ptrs.last_child[payload.index];
                self.ptrs.last_child[payload.index] = element;
                if (former_last_child.eqlNull()) {
                    self.ptrs.first_child[payload.index] = element;
                } else {
                    self.ptrs.next_sibling[former_last_child.index] = element;
                }

                self.ptrs.parent[element.index] = payload;
                self.ptrs.next_sibling[element.index] = Element.null_element;
                self.ptrs.previous_sibling[element.index] = former_last_child;
            },
        }

        inline for (comptime std.meta.tags(Field)) |tag| {
            @field(self.ptrs, @tagName(tag))[element.index] = tag.default();
        }
    }

    pub fn runCascade(
        self: Slice,
        element: Element,
        allocator: Allocator,
        env: *const Environment,
    ) !void {
        self.validateElement(element);

        if (env.stylesheets.items.len == 0) return;
        if (env.stylesheets.items.len > 1) panic("TODO: runCascade: Can only handle one stylesheet", .{});

        var decl_blocks: std.AutoArrayHashMapUnmanaged(zss.Stylesheet.DeclBlockIndex, *const CascadedValues) = .empty;
        defer decl_blocks.deinit(allocator);

        const stylesheet = env.stylesheets.items[0];
        const Important = enum { yes, no };
        for ([_]Important{ .yes, .no }) |importance| {
            const selectors = switch (importance) {
                .yes => &stylesheet.selectors_important,
                .no => &stylesheet.selectors_normal,
            };
            for (selectors.items(.complex), selectors.items(.decl_block_index)) |complex_selector, index| {
                if (decl_blocks.contains(index)) continue;
                if (complex_selector.matchElement(self, element)) {
                    try decl_blocks.putNoClobber(allocator, index, &stylesheet.decl_blocks[index]);
                }
            }
        }

        try updateCascadedValues(self, element, decl_blocks.values());
    }

    pub fn updateCascadedValues(
        self: Slice,
        element: Element,
        /// This slice should be such that sources with a higher cascade order appear earlier.
        sources: []const *const CascadedValues,
    ) !void {
        self.validateElement(element);
        const cascaded_values = &self.ptrs.cascaded_values[element.index];
        for (sources) |source| {
            // TODO: CascadedValues should have a higher level API
            if (source.all) |all| cascaded_values.addAll(all);
            for (source.map.keys(), 0..) |tag, index| {
                switch (tag) {
                    inline else => |tag_comptime| {
                        const source_value = source.getByIndex(tag_comptime, index);
                        try cascaded_values.add(self.arena, tag_comptime, source_value);
                    },
                    .direction, .unicode_bidi, .custom => std.debug.panic("TODO", .{}),
                }
            }
        }
    }
};
