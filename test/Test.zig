const Test = @This();

const zss = @import("zss");
const aggregates = zss.properties.aggregates;
const ElementTree = zss.ElementTree;
const Element = ElementTree.Element;
const null_element = Element.null_element;

const testing = @import("./testing.zig");
const allocator = testing.allocator;

const std = @import("std");
const assert = std.debug.assert;

const hb = @import("mach-harfbuzz").c;

name: []const u8 = undefined,
slice: ElementTree.Slice = undefined,
ft_face: hb.FT_Face = undefined,
hb_font: ?*hb.hb_font_t = undefined,

element_tree: ElementTree,
root: Element = null_element,
width: u32 = 400,
height: u32 = 400,
font: [:0]const u8 = testing.fonts[0],
font_size: u32 = 12,
font_color: u32 = 0xffffffff,

pub fn init() Test {
    return Test{ .element_tree = ElementTree.init(allocator) };
}

pub fn createRoot(self: *Test) Element {
    const element = self.element_tree.allocateElement() catch |err| fail(err);
    self.root = element;
    const slice = self.element_tree.slice();
    slice.initElement(element, .normal, .orphan, {});
    return element;
}

pub fn appendChild(self: *Test, parent: Element, category: ElementTree.Category) Element {
    const element = self.element_tree.allocateElement() catch |err| fail(err);
    const slice = self.element_tree.slice();
    slice.initElement(element, category, .last_child_of, parent);
    return element;
}

pub fn set(self: *Test, comptime tag: aggregates.Tag, element: Element, value: tag.Value()) void {
    const slice = self.element_tree.slice();
    const cv = slice.ptr(.cascaded_values, element);
    cv.add(slice.arena, tag, value) catch |err| fail(err);
}

pub fn setText(self: *Test, element: Element, value: ElementTree.Text) void {
    const slice = self.element_tree.slice();
    slice.set(.text, element, value);
}

fn fail(err: anyerror) noreturn {
    std.debug.print("Error during a test: {s}\n", .{@errorName(err)});
    std.process.abort();
}
