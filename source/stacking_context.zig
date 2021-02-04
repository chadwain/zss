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

const zss = @import("../zss.zig");
const BlockFormattingContext = zss.BlockFormattingContext;
const InlineFormattingContext = zss.InlineFormattingContext;
const OffsetTree = zss.offset_tree.OffsetTree;

pub const StackingContext = struct {
    midpoint: usize,
    offset: zss.util.Offset,
    inner_context: union(enum) {
        block: struct {
            context: *const BlockFormattingContext,
            offset_tree: *const OffsetTree,
        },
        inl: struct {
            context: *const InlineFormattingContext,
        },
    },
};

pub const StackingContextId = []const StackingContextIdPart;
pub const StackingContextIdPart = u16;
const PrefixTreeMapUnmanaged = @import("prefix-tree-map").PrefixTreeMapUnmanaged;
fn idCmpFn(lhs: StackingContextIdPart, rhs: StackingContextIdPart) std.math.Order {
    return std.math.order(lhs, rhs);
}
pub const StackingContextTree = PrefixTreeMapUnmanaged(StackingContextIdPart, StackingContext, idCmpFn);
