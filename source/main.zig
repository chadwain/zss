const std = @import("std");
const testing = std.testing;
const PrefixTree = @import("prefix-tree").PrefixTree;

fn cmp(lhs: u8, rhs: u8) std.math.Order {
    return std.math.order(lhs, rhs);
}

test "basic tree functionality" {
    const allocator = std.heap.page_allocator;
    var tree = try PrefixTree(u8, cmp).init(allocator);
    defer tree.deinit();
    testing.expect(tree.exists(""));
}
