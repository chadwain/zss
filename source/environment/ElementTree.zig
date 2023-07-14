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

const Node = struct {
    generation: Generation,
    first_child: Element,
    last_child: Element,
    next_sibling: Element,

    type: Type,
};

pub const Size = u16;
const max_size = std.math.maxInt(Size);

pub const Generation = u16;
const max_generation = std.math.maxInt(Generation);

pub const Element = packed struct {
    index: Size,
    generation: Generation,

    pub const null_element = Element{ .index = max_size, .generation = 0 };

    pub fn eql(self: Element, other: Element) bool {
        return self.index == other.index and
            self.generation == other.generation;
    }

    pub fn eqlNull(self: Element) bool {
        return self.eql(null_element);
    }
};

pub const Type = struct {
    namespace: NamespaceId,
    name: NameId,
};

pub fn deinit(tree: *ElementTree, allocator: Allocator) void {
    tree.nodes.deinit(allocator);
}

pub fn allocateElement(tree: *ElementTree, allocator: Allocator) !Element {
    if (tree.free_list_head == max_size) {
        var result: [1]Element = undefined;
        try tree.allocateElementsNoFreeList(allocator, &result);
        return result[0];
    } else {
        const index = tree.free_list_head;
        const generation = tree.nodes.items(.generation)[index];
        const next_sibling = &tree.nodes.items(.next_sibling)[index];
        const next_free_list = next_sibling.index;
        next_sibling.index = undefined;
        tree.free_list_head = next_free_list;
        return Element{ .index = index, .generation = generation };
    }
}

pub fn allocateElements(tree: *ElementTree, allocator: Allocator, buffer: []Element) !void {
    const nodes = tree.nodes.slice();
    var i: Size = 0;
    var free_element = tree.free_list_head;
    while (i < buffer.len) : (i += 1) {
        if (free_element == max_size) {
            try tree.allocateElementsNoFreeList(allocator, buffer[i..]);
            tree.free_list_head = max_size;
            return;
        }
        buffer[i] = Element{ .index = free_element, .generation = nodes.items(.generation)[free_element] };
        free_element = nodes.items(.next_sibling)[free_element].index;
    }
    tree.free_list_head = free_element;
}

fn allocateElementsNoFreeList(tree: *ElementTree, allocator: Allocator, buffer: []Element) !void {
    const nodes_len = @intCast(Size, tree.nodes.len);
    if (buffer.len >= max_size - nodes_len) return error.OutOfMemory;

    try tree.nodes.resize(allocator, nodes_len + @intCast(Size, buffer.len));
    var nodes = tree.nodes.slice();

    var i: Size = 0;
    while (i < buffer.len) : (i += 1) {
        buffer[i] = Element{ .index = nodes_len + i, .generation = 0 };
        nodes.set(nodes_len + i, Node{
            .generation = 0,
            .next_sibling = Element.null_element,
            .first_child = Element.null_element,
            .last_child = Element.null_element,
            .type = Type{
                .namespace = NamespaceId.none,
                .name = NameId.unspecified,
            },
        });
    }
}

pub fn freeElement(tree: *ElementTree, element: Element) void {
    var new_node_value = @as(Node, undefined);
    new_node_value.generation = tree.nodes.items(.generation)[element.index];
    assert(element.generation == new_node_value.generation);

    if (new_node_value.generation != max_generation) {
        // This node can be used again; add it to the free list.
        new_node_value.generation += 1;
        new_node_value.next_sibling = .{ .index = tree.free_list_head, .generation = undefined };
        tree.free_list_head = element.index;
    }

    tree.nodes.set(element.index, new_node_value);
}

const Constness = enum { Const, Mutable };

fn SliceTemplate(comptime constness: Constness) type {
    const Ptr = struct {
        fn f(comptime T: type) type {
            return switch (constness) {
                .Const => *const T,
                .Mutable => *T,
            };
        }
    }.f;

    const MultiPtr = struct {
        fn f(comptime T: type) type {
            return switch (constness) {
                .Const => [*]const T,
                .Mutable => [*]T,
            };
        }
    }.f;

    return struct {
        len: Size,
        generation: MultiPtr(Generation),
        first_child: MultiPtr(Element),
        last_child: MultiPtr(Element),
        next_sibling: MultiPtr(Element),

        pub const Value = struct {
            first_child: Element,
            last_child: Element,
            next_sibling: Element,
        };

        pub const Field = std.meta.FieldEnum(Value);

        fn validateElement(self: @This(), element: Element) void {
            assert(element.index < self.len);
            assert(element.generation == self.generation[element.index]);
        }

        pub fn setAll(self: @This(), element: Element, value: Value) void {
            comptime assert(constness == .Mutable);
            self.validateElement(element);
            inline for (std.meta.fields(Value)) |field_info| {
                @field(self, field_info.name)[element.index] = @field(value, field_info.name);
            }
        }

        pub fn get(self: @This(), comptime field: Field, element: Element) Element {
            self.validateElement(element);
            return @field(self, @tagName(field))[element.index];
        }

        pub fn ptr(self: @This(), comptime field: Field, element: Element) Ptr(Element) {
            self.validateElement(element);
            return &@field(self, @tagName(field))[element.index];
        }
    };
}

fn sliceTemplate(tree: *const ElementTree, comptime constness: Constness) SliceTemplate(constness) {
    const nodes = tree.nodes.slice();
    return SliceTemplate(constness){
        .len = @intCast(Size, nodes.len),
        .generation = nodes.items(.generation).ptr,
        .first_child = nodes.items(.first_child).ptr,
        .last_child = nodes.items(.last_child).ptr,
        .next_sibling = nodes.items(.next_sibling).ptr,
    };
}

pub const Slice = SliceTemplate(.Mutable);
pub const ConstSlice = SliceTemplate(.Const);

pub fn slice(tree: *ElementTree) Slice {
    return tree.sliceTemplate(.Mutable);
}

pub fn constSlice(tree: *const ElementTree) ConstSlice {
    return tree.sliceTemplate(.Const);
}
