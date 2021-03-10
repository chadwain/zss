// This file is a part of zss.
// Copyright (C) 2020-2021 Chadwain Holness
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

usingnamespace @import("properties.zig");

pub const BoxTree = struct {
    preorder_array: []u16,
    inline_size: []LogicalSize,
    block_size: []LogicalSize,
    display: []Display,
    position_inset: []PositionInset,
};

test "box tree" {
    var tree = @as(BoxTree, undefined);
}
