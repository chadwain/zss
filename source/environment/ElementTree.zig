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

const Node = struct {
    generation: Generation,
    first_child: Element,
    last_child: Element,
    next_sibling: Element,

    fq_type: FqType,
};

pub const Size = u16;
const max_size = std.math.maxInt(Size);

pub const Generation = u16;
const max_generation = std.math.maxInt(Generation);

/// A reference to a Node.
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

/// A fully-qualified type.
pub const FqType = struct {
    namespace: NamespaceId,
    name: NameId,
};

pub fn deinit(tree: *ElementTree, allocator: Allocator) void {
    tree.nodes.deinit(allocator);
}

pub fn allocateElement(tree: *ElementTree, allocator: Allocator) !Element {
    var result: [1]Element = undefined;
    try tree.allocateElements(allocator, &result);
    return result[0];
}

/// Populates `buffer` with `buffer.len` newly-created elements.
pub fn allocateElements(tree: *ElementTree, allocator: Allocator, buffer: []Element) !void {
    const num_extra_nodes = buffer.len -| tree.free_list_len;
    const old_nodes_len = tree.nodes.len;
    if (num_extra_nodes >= max_size - old_nodes_len) return error.Overflow;
    try tree.nodes.resize(allocator, old_nodes_len + num_extra_nodes);
    tree.free_list_len = @intCast(u16, @as(usize, tree.free_list_len) -| buffer.len);
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
        element.* = Element{ .index = @intCast(Size, node_index), .generation = 0 };
        nodes.items(.generation)[node_index] = 0;
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
        tree.free_list_len += 1;
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
        fq_type: MultiPtr(FqType),

        pub const Value = struct {
            first_child: Element,
            last_child: Element,
            next_sibling: Element,
            fq_type: FqType,
        };

        pub const Field = std.meta.FieldEnum(Value);

        fn validateElement(self: @This(), element: Element) void {
            assert(element.index < self.len);
            assert(element.generation == self.generation[element.index]);
        }

        pub fn setAll(self: @This(), element: Element, value: anytype) void {
            comptime assert(constness == .Mutable);
            self.validateElement(element);
            inline for (std.meta.fields(@TypeOf(value))) |field_info| {
                @field(self, field_info.name)[element.index] = @field(value, field_info.name);
            }
        }

        pub fn set(self: @This(), comptime field: Field, element: Element, value: std.meta.fieldInfo(Value, field).type) void {
            self.validateElement(element);
            @field(self, @tagName(field))[element.index] = value;
        }

        pub fn get(self: @This(), comptime field: Field, element: Element) std.meta.fieldInfo(Value, field).type {
            self.validateElement(element);
            return @field(self, @tagName(field))[element.index];
        }

        pub fn ptr(self: @This(), comptime field: Field, element: Element) Ptr(std.meta.fieldInfo(Value, field).type) {
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
        .fq_type = nodes.items(.fq_type).ptr,
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
