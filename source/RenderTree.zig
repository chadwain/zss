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
const Allocator = std.mem.Allocator;
const HashMapUnmanaged = std.HashMapUnmanaged;
const AutoHashMapUnmanaged = std.AutoHashMapUnmanaged;

const zss = @import("../zss.zig");
const BlockFormattingContext = zss.BlockFormattingContext;
const InlineFormattingContext = zss.InlineFormattingContext;
const OffsetTree = zss.offset_tree.OffsetTree;

const Self = @This();

pub const ContextId = struct { v: u32 };

pub const ContextSpecificBoxId = []const ContextSpecificBoxIdPart;
pub const ContextSpecificBoxIdPart = u16;

pub fn cmpPart(lhs: ContextSpecificBoxIdPart, rhs: ContextSpecificBoxIdPart) std.math.Order {
    return std.math.order(lhs, rhs);
}

pub const BoxId = struct {
    context_id: ContextId,
    specific_id: ContextSpecificBoxId,

    fn hash(a: @This()) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(std.mem.asBytes(&a.context_id));
        hasher.update(std.mem.sliceAsBytes(a.specific_id));
        return hasher.final();
    }

    fn eql(a: @This(), b: @This()) bool {
        return a.context_id.v == b.context_id.v and std.mem.eql(ContextSpecificBoxIdPart, a.specific_id, b.specific_id);
    }
};

pub const FormattingContext = union(enum) {
    block: struct {
        context: *BlockFormattingContext,
        offset_tree: *OffsetTree,
    },
    @"inline": *InlineFormattingContext,
};

context_id_counter: ContextId = .{ .v = 0 },
root_context_id: ContextId = .{ .v = 0 },
contexts: AutoHashMapUnmanaged(ContextId, FormattingContext) = .{},
descendants: HashMapUnmanaged(BoxId, ContextId, BoxId.hash, BoxId.eql, 80) = .{},
allocator: *Allocator,

pub fn init(allocator: *Allocator) Self {
    return Self{
        .allocator = allocator,
    };
}

pub fn deinit(self: *Self) void {
    self.contexts.deinit(self.allocator);
    self.descendants.deinit(self.allocator);
}

pub fn newContext(self: *Self, context: FormattingContext) !ContextId {
    const id = self.context_id_counter;
    self.context_id_counter.v = try std.math.add(u32, self.context_id_counter.v, 1);
    errdefer self.context_id_counter.v -= 1;
    try self.contexts.putNoClobber(self.allocator, id, context);
    return id;
}

pub fn getContext(self: Self, context_id: ContextId) FormattingContext {
    return self.contexts.get(context_id) orelse unreachable;
}

pub fn setDescendant(self: *Self, box: BoxId, descendant: ContextId) !void {
    assert(blk: {
        const tree = switch (self.getContext(box.context_id)) {
            .block => |b| b.context.tree,
            .@"inline" => |i| i.tree,
        };
        const find_result = tree.find(box.specific_id);
        break :blk find_result.wasFound() and find_result.parent.child(find_result.index) == null;
    });
    try self.descendants.putNoClobber(self.allocator, box, descendant);
}

pub fn getDescendantOrNull(self: Self, box: BoxId) ?ContextId {
    return self.descendants.get(box);
}
