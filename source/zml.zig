const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const zss = @import("zss.zig");
const Ast = zss.syntax.Ast;
const ElementTree = zss.ElementTree;
const Element = ElementTree.Element;
const Stack = zss.util.Stack;

pub const Parser = @import("syntax/zml.zig").Parser;

comptime {
    if (@import("builtin").is_test) {
        std.testing.refAllDecls(@This());
    }
}
