const Test = @This();

const zss = @import("zss");
const ElementTree = zss.ElementTree;
const ElementRef = zss.ElementRef;
const CascadedValueStore = zss.CascadedValueStore;
const allocator = zss.testing.allocator;

const std = @import("std");
const assert = std.debug.assert;

const hb = @import("harfbuzz");

name: []const u8,
ft_face: hb.FT_Face,
hb_font: ?*hb.hb_font_t,

element_tree: ElementTree = .{},
cascaded_values: CascadedValueStore = .{},
width: u32 = 400,
height: u32 = 400,
font: [:0]const u8 = zss.testing.fonts[0],
font_size: u32 = 12,
font_color: u32 = 0xffffffff,

const store_fields = std.meta.fields(CascadedValueStore);
const FieldEnum = std.meta.FieldEnum(CascadedValueStore);

pub fn createRoot(self: *Test) ElementRef {
    assert(self.element_tree.size() == 0);
    self.element_tree.ensureTotalCapacity(allocator, 1) catch |err| fail(err);
    return self.element_tree.createRootAssumeCapacity();
}

pub fn appendChild(self: *Test, parent: ElementRef) ElementRef {
    self.element_tree.ensureTotalCapacity(allocator, self.element_tree.size() + 1) catch |err| fail(err);
    return self.element_tree.appendChildAssumeCapacity(parent);
}

pub fn set(self: *Test, comptime field: FieldEnum, element_ref: ElementRef, value: store_fields[@enumToInt(field)].field_type.Value) void {
    const store = &@field(self.cascaded_values, @tagName(field));
    store.ensureTotalCapacity(allocator, store.map.size + 1) catch |err| fail(err);
    store.setAssumeCapacity(element_ref, value);
}

fn fail(err: anyerror) noreturn {
    std.debug.print("Error during a test: {s}\n", .{@errorName(err)});
    std.os.abort();
}
