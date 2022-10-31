const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const MultiArrayList = std.MultiArrayList;
const builtin = @import("builtin");

const ElementTree = @This();

list: MultiArrayList(ListItem) = .{},
free_list: Size = max_size,

const ListItem = struct {
    generation: Generation,
    first_child: Element,
    last_child: Element,
    next_sibling: Element,
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

pub fn deinit(tree: *ElementTree, allocator: Allocator) void {
    tree.list.deinit(allocator);
}

pub fn allocateElement(tree: *ElementTree, allocator: Allocator) !Element {
    if (tree.free_list == max_size) {
        var result: [1]Element = undefined;
        try tree.allocateElementsNoFreeList(allocator, &result);
        return result[0];
    } else {
        const index = tree.free_list;
        const generation = tree.list.items(.generation)[index];
        const next_sibling = &tree.list.items(.next_sibling)[index];
        const next_free_list = next_sibling.index;
        next_sibling.index = undefined;
        tree.free_list = next_free_list;
        return Element{ .index = index, .generation = generation };
    }
}

pub fn allocateElements(tree: *ElementTree, allocator: Allocator, buffer: []Element) !void {
    const list_slice = tree.list.slice();
    var i: Size = 0;
    var free_element = tree.free_list;
    while (i < buffer.len) : (i += 1) {
        if (free_element == max_size) {
            try tree.allocateElementsNoFreeList(allocator, buffer[i..]);
            tree.free_list = max_size;
            return;
        }
        buffer[i] = Element{ .index = free_element, .generation = list_slice.items(.generation)[free_element] };
        free_element = list_slice.items(.next_sibling)[free_element].index;
    }
    tree.free_list = free_element;
}

pub fn allocateElementsNoFreeList(tree: *ElementTree, allocator: Allocator, buffer: []Element) !void {
    const list_len = @intCast(Size, tree.list.len);
    if (buffer.len >= max_size - list_len) return error.ExhaustedAllPossibleElements;
    const buffer_len = @intCast(Size, buffer.len);
    try tree.list.resize(allocator, list_len + buffer.len);

    const generation = tree.list.items(.generation);
    var i: Size = 0;
    while (i < buffer_len) : (i += 1) {
        generation[list_len + i] = 0;
        buffer[i] = Element{ .index = list_len + i, .generation = 0 };
    }
}

pub fn freeElement(tree: *ElementTree, element: Element) void {
    assert(element.index < tree.list.len);
    const generation = &tree.list.items(.generation)[element.index];
    assert(element.generation == generation.*);
    const next_sibling = &tree.list.items(.next_sibling)[element.index];
    if (generation.* != max_generation) {
        generation.* += 1;
        next_sibling.* = .{ .index = tree.free_list, .generation = undefined };
        tree.free_list = element.index;
    } else {
        next_sibling.* = undefined;
    }

    if (builtin.mode == .Debug) {
        tree.list.items(.first_child)[element.index] = undefined;
        tree.list.items(.last_child)[element.index] = undefined;
    }
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
    const list_slice = tree.list.slice();
    return SliceTemplate(constness){
        .len = @intCast(Size, list_slice.len),
        .generation = list_slice.items(.generation).ptr,
        .first_child = list_slice.items(.first_child).ptr,
        .last_child = list_slice.items(.last_child).ptr,
        .next_sibling = list_slice.items(.next_sibling).ptr,
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
