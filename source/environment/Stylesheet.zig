const Stylesheet = @This();

const zss = @import("../../zss.zig");
const ComplexSelectorList = zss.selectors.ComplexSelectorList;
const ParsedDeclarations = zss.declaration.ParsedDeclarations;

const std = @import("std");
const Allocator = std.mem.Allocator;
const MultiArrayList = std.MultiArrayList;

pub const StyleRule = struct {
    selector: ComplexSelectorList,
    declarations: ParsedDeclarations,
};

rules: MultiArrayList(StyleRule) = .{},

pub fn deinit(stylesheet: *Stylesheet, allocator: Allocator) void {
    const slice = stylesheet.rules.slice();
    for (slice.items(.selector), slice.items(.declarations)) |*selector, *decls| {
        selector.deinit(allocator);
        decls.deinit(allocator);
    }
    stylesheet.rules.deinit(allocator);
}
