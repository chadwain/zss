const Stylesheet = @This();

const zss = @import("../../zss.zig");
const ComplexSelectorList = zss.selectors.ComplexSelectorList;
const ParsedDeclarations = zss.properties.declaration.ParsedDeclarations;

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const MultiArrayList = std.MultiArrayList;

pub const StyleRule = struct {
    selector: ComplexSelectorList,
    declarations: ParsedDeclarations,
};

rules: MultiArrayList(StyleRule) = .{},
arena: ArenaAllocator.State = .{},

pub fn deinit(stylesheet: *Stylesheet, allocator: Allocator) void {
    var arena = stylesheet.arena.promote(allocator);
    defer stylesheet.arena = arena.state;
    arena.deinit();
}
