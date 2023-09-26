const zss = @import("../../zss.zig");
const AggregateTag = zss.properties.aggregates.Tag;
const Environment = zss.Environment;
const NamespaceId = Environment.NamespaceId;
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
pub const CascadedValues = @import("./CascadedValues.zig");

comptime {
    if (@import("builtin").is_test) {
        _ = CascadedValues;
    }
}

nodes: MultiArrayList(Node) = .{},
free_list_head: Size = max_size,
free_list_len: Size = 0,
cascaded_values_arena: ArenaAllocator.State = .{},

/// If a Node is in the free list, then node.next_sibling.index stores the next item in the free list, and
/// node.cascaded_values has its default value.
const Node = struct {
    generation: Generation,
    parent: Element,
    first_child: Element,
    last_child: Element,
    next_sibling: Element,
    previous_sibling: Element,

    category: Category,
    fq_type: FqType,
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

pub fn deinit(tree: *ElementTree, allocator: Allocator) void {
    var arena = tree.cascaded_values_arena.promote(allocator);
    defer tree.cascaded_values_arena = arena.state;
    arena.deinit();
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
    if (num_extra_nodes >= max_size - old_nodes_len) return error.ElementTreeMaxSizeExceeded;
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

            .parent = nodes.items(.parent).ptr,
            .first_child = nodes.items(.first_child).ptr,
            .last_child = nodes.items(.last_child).ptr,
            .next_sibling = nodes.items(.next_sibling).ptr,
            .previous_sibling = nodes.items(.previous_sibling).ptr,

            .category = nodes.items(.category).ptr,
            .fq_type = nodes.items(.fq_type).ptr,
            .cascaded_values = nodes.items(.cascaded_values).ptr,
        },
        .cascaded_values_arena = &tree.cascaded_values_arena,
    };
}

pub const Slice = struct {
    len: Size,
    ptrs: struct {
        generation: [*]Generation,

        parent: [*]Element,
        first_child: [*]Element,
        last_child: [*]Element,
        next_sibling: [*]Element,
        previous_sibling: [*]Element,

        category: [*]Category,
        fq_type: [*]FqType,
        cascaded_values: [*]CascadedValues,
    },
    cascaded_values_arena: *ArenaAllocator.State,

    pub const Value = struct {
        category: Category = .normal,
        fq_type: FqType = .{ .namespace = .none, .name = .unspecified },
    };

    pub const Field = std.meta.FieldEnum(Value);
    const fields = std.meta.fields(Value);

    fn validateElement(self: Slice, element: Element) void {
        assert(element.index < self.len);
        assert(element.generation == self.ptrs.generation[element.index]);
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

    pub fn set(self: Slice, comptime field: Field, element: Element, value: std.meta.fieldInfo(Value, field).type) void {
        self.validateElement(element);
        @field(self.ptrs, @tagName(field))[element.index] = value;
    }

    pub fn get(self: Slice, comptime field: Field, element: Element) std.meta.fieldInfo(Value, field).type {
        self.validateElement(element);
        return @field(self.ptrs, @tagName(field))[element.index];
    }

    pub fn ptr(self: Slice, comptime field: Field, element: Element) *std.meta.fieldInfo(Value, field).type {
        self.validateElement(element);
        return &@field(self.ptrs, @tagName(field))[element.index];
    }

    pub fn initElement(self: Slice, element: Element, value: Value) void {
        self.validateElement(element);
        inline for (fields) |field_info| {
            @field(self.ptrs, field_info.name)[element.index] = @field(value, field_info.name);
        }
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
                self.ptrs.parent[element.index] = Element.null_element;
                self.ptrs.first_child[element.index] = Element.null_element;
                self.ptrs.last_child[element.index] = Element.null_element;
                self.ptrs.next_sibling[element.index] = Element.null_element;
                self.ptrs.previous_sibling[element.index] = Element.null_element;
            },
            .first_child_of => {
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
                self.ptrs.first_child[element.index] = Element.null_element;
                self.ptrs.last_child[element.index] = Element.null_element;
                self.ptrs.next_sibling[element.index] = former_first_child;
                self.ptrs.previous_sibling[element.index] = Element.null_element;
            },
            .last_child_of => {
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
                self.ptrs.first_child[element.index] = Element.null_element;
                self.ptrs.last_child[element.index] = Element.null_element;
                self.ptrs.next_sibling[element.index] = Element.null_element;
                self.ptrs.previous_sibling[element.index] = former_last_child;
            },
        }
    }

    pub fn runCascade(
        self: Slice,
        element: Element,
        allocator: Allocator,
        env: *const Environment,
    ) !void {
        self.validateElement(element);

        if (env.stylesheets.items.len == 0) return .{};
        if (env.stylesheets.items.len > 1) panic("TODO: runCascade: Can only handle one stylesheet", .{});

        var sources = ArrayListUnmanaged(*const CascadedValues){};
        defer sources.deinit(allocator);

        // Determines the order for values that have the same precedence in the cascade (i.e. they have the same origin, specificity, etc.).
        const ValuePrecedence = struct {
            specificity: Specificity,
            important: bool,
        };

        var precedences = MultiArrayList(ValuePrecedence){};
        defer precedences.deinit(allocator);

        const stylesheet_index: usize = 0;
        const rules = env.stylesheets.items[stylesheet_index].rules.slice();
        for (rules.items(.selector), rules.items(.declarations)) |selector, declarations| {
            const specificity = selector.matchElement(self, element) orelse continue;

            var precendence = ValuePrecedence{
                .specificity = specificity,
                .important = undefined,
            };

            if (declarations.important.size() > 0) {
                precendence.important = true;
                try sources.append(allocator, &declarations.important);
                try precedences.append(allocator, precendence);
            }

            if (declarations.normal.size() > 0) {
                precendence.important = false;
                try sources.append(allocator, &declarations.normal);
                try precedences.append(allocator, precendence);
            }
        }

        // Sort the declared values such that values that are of higher precedence in the cascade are earlier in the list.
        const SortContext = struct {
            sources: []*const CascadedValues,
            precedences: MultiArrayList(ValuePrecedence).Slice,

            pub fn swap(sc: @This(), a_index: usize, b_index: usize) void {
                std.mem.swap(*const CascadedValues, &sc.sources[a_index], &sc.sources[b_index]);
                inline for (std.meta.fields(ValuePrecedence), 0..) |field_info, i| {
                    const field = @as(std.meta.FieldEnum(ValuePrecedence), @enumFromInt(i));
                    const items = sc.precedences.items(field);
                    std.mem.swap(field_info.type, &items[a_index], &items[b_index]);
                }
            }

            pub fn lessThan(sc: @This(), a_index: usize, b_index: usize) bool {
                const left_important = sc.precedences.items(.important)[a_index];
                const right_important = sc.precedences.items(.important)[b_index];
                if (left_important != right_important) {
                    return left_important;
                }

                const left_specificity = sc.precedences.items(.specificity)[a_index];
                const right_specificity = sc.precedences.items(.specificity)[b_index];
                switch (left_specificity.order(right_specificity)) {
                    .lt => return false,
                    .gt => return true,
                    .eq => {},
                }

                return false;
            }
        };

        // Must be a stable sort.
        std.sort.insertionContext(0, sources.len, SortContext{ .sources = sources.items, .precedences = precedences.slice() });

        var arena = self.cascaded_values_arena.promote(allocator);
        defer self.cascaded_values_arena.* = arena.state;
        const arena_allocator = arena.allocator();

        const cascaded_values = &self.items(.cascaded_values)[element.index];
        for (sources) |source| {
            // TODO: CascadedValues should have a higher level API
            cascaded_values.addAll(source.all);
            for (source.indeces.keys()) |tag| {
                switch (tag) {
                    inline else => {
                        const source_value = source.get(tag).?;
                        try cascaded_values.add(arena_allocator, tag, source_value);
                    },
                }
            }
        }
    }

    pub fn setCascadedValue(self: Slice, allocator: Allocator, element: Element, comptime tag: AggregateTag, value: tag.Value()) !void {
        self.validateElement(element);
        var arena = self.cascaded_values_arena.promote(allocator);
        defer self.cascaded_values_arena.* = arena.state;
        const cascaded_values = &self.items(.cascaded_values)[element.index];
        try cascaded_values.addNewValues(arena.allocator(), tag, value);
    }
};
