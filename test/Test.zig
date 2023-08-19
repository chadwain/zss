const Test = @This();

const zss = @import("zss");
const ElementTree = zss.ElementTree;
const Element = ElementTree.Element;
const null_element = Element.null_element;
const CascadedValueStore = zss.CascadedValueStore;

const testing = @import("./testing.zig");
const allocator = testing.allocator;

const std = @import("std");
const assert = std.debug.assert;

const hb = @import("harfbuzz");

name: []const u8,
ft_face: hb.FT_Face,
hb_font: ?*hb.hb_font_t,

element_tree: ElementTree = .{},
root: Element = null_element,
cascaded_values: CascadedValueStore = .{},
width: u32 = 400,
height: u32 = 400,
font: [:0]const u8 = testing.fonts[0],
font_size: u32 = 12,
font_color: u32 = 0xffffffff,

const store_fields = std.meta.fields(CascadedValueStore);
const FieldEnum = std.meta.FieldEnum(CascadedValueStore);

pub fn createRoot(self: *Test) Element {
    const element = self.element_tree.allocateElement(allocator) catch |err| fail(err);
    self.root = element;
    const slice = self.element_tree.slice();
    slice.initElement(element, .{});
    slice.placeElement(element, .root, {});
    return element;
}

pub fn appendChild(self: *Test, parent: Element, category: ElementTree.Category) Element {
    const element = self.element_tree.allocateElement(allocator) catch |err| fail(err);
    const slice = self.element_tree.slice();
    slice.initElement(element, .{ .category = category });
    slice.placeElement(element, .last_child_of, parent);
    return element;
}

pub fn set(self: *Test, comptime field: FieldEnum, element: Element, value: store_fields[@intFromEnum(field)].type.Value) void {
    const store = &@field(self.cascaded_values, @tagName(field));
    store.ensureTotalCapacity(allocator, store.map.size + 1) catch |err| fail(err);
    store.setAssumeCapacity(element, value);
}

fn fail(err: anyerror) noreturn {
    std.debug.print("Error during a test: {s}\n", .{@errorName(err)});
    std.os.abort();
}
