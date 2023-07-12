const Stylesheet = @This();

const zss = @import("../../zss.zig");
const ParserSource = zss.syntax.parse.Source;
const selectors = zss.selectors;

const std = @import("std");
const Allocator = std.mem.Allocator;
const MultiArrayList = std.MultiArrayList;

pub const StyleRule = struct {
    selector: selectors.ComplexSelectorList,
};

rules: MultiArrayList(StyleRule) = .{},

pub fn deinit(stylesheet: *Stylesheet, allocator: Allocator) void {
    for (stylesheet.rules.items(.selector)) |*selector| {
        selector.deinit(allocator);
    }
    stylesheet.rules.deinit(allocator);
}
