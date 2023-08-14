const Stylesheet = @This();

const zss = @import("../../zss.zig");
const selectors = zss.selectors;

const std = @import("std");
const Allocator = std.mem.Allocator;
const MultiArrayList = std.MultiArrayList;

pub const StyleRule = struct {
    selector: selectors.ComplexSelectorList,
    normal_declarations: DeclarationList,
    important_declarations: DeclarationList,
};

pub const DeclarationList = struct {
    list: []Declaration,

    pub fn deinit(list: *DeclarationList, allocator: Allocator) void {
        allocator.free(list.list);
    }
};

pub const Declaration = struct {
    name: zss.declaration.Name,
    component_index: zss.syntax.ComponentTree.Size,
};

rules: MultiArrayList(StyleRule) = .{},

pub fn deinit(stylesheet: *Stylesheet, allocator: Allocator) void {
    const slice = stylesheet.rules.slice();
    for (slice.items(.selector)) |*selector| {
        selector.deinit(allocator);
    }
    for (slice.items(.normal_declarations)) |*decl| {
        decl.deinit(allocator);
    }
    for (slice.items(.important_declarations)) |*decl| {
        decl.deinit(allocator);
    }
    stylesheet.rules.deinit(allocator);
}
