// This file is a part of zss.
// Copyright (C) 2020 Chadwain Holness
//
// This library is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this library.  If not, see <https://www.gnu.org/licenses/>.

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
