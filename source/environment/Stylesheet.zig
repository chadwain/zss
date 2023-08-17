const Stylesheet = @This();

const zss = @import("../../zss.zig");
const selectors = zss.selectors;
const Declaration = zss.Environment.declaration.Declaration;

const std = @import("std");
const Allocator = std.mem.Allocator;
const MultiArrayList = std.MultiArrayList;

pub const StyleRule = struct {
    selector: selectors.ComplexSelectorList,
    normal_declarations: []const Declaration,
    important_declarations: []const Declaration,
};

rules: MultiArrayList(StyleRule) = .{},

pub fn deinit(stylesheet: *Stylesheet, allocator: Allocator) void {
    const slice = stylesheet.rules.slice();
    for (slice.items(.selector), slice.items(.normal_declarations), slice.items(.important_declarations)) |*selector, normal, important| {
        selector.deinit(allocator);
        allocator.free(normal);
        allocator.free(important);
    }
    stylesheet.rules.deinit(allocator);
}
