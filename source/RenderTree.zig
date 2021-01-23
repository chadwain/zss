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
const Allocator = std.mem.Allocator;
const HashMapUnmanaged = std.HashMapUnmanaged;
const AutoHashMapUnmanaged = std.AutoHashMapUnmanaged;

const zss = @import("../zss.zig");
const BlockFormattingContext = zss.BlockFormattingContext;
const InlineFormattingContext = zss.InlineFormattingContext;

const Self = @This();

pub const ContextId = struct { v: u32 };

pub const ContextSpecificElementId = []const ContextSpecificElementIdPart;
pub const ContextSpecificElementIdPart = u16;

pub fn cmpPart(lhs: ContextSpecificElementIdPart, rhs: ContextSpecificElementIdPart) std.math.Order {
    return std.math.order(lhs, rhs);
}

pub const BoxId = struct {
    ctx: ContextId,
    box: ContextSpecificElementId,

    fn hash(a: @This()) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(std.mem.asBytes(&a.ctx));
        hasher.update(std.mem.sliceAsBytes(a.box));
        return hasher.final();
    }

    fn eql(a: @This(), b: @This()) bool {
        return a.ctx.v == b.ctx.v and std.mem.eql(ContextSpecificElementIdPart, a.box, b.box);
    }
};

pub const FormattingContext = union(enum) {
    block: *BlockFormattingContext,
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

pub fn getContext(self: Self, ctxId: ContextId) FormattingContext {
    return self.contexts.get(ctxId) orelse unreachable;
}

pub fn setDescendant(self: *Self, box: BoxId, descendant: ContextId) !void {
    assert(blk: {
        const tree = switch (self.getContext(box.ctx)) {
            .block => |b| b.tree,
            .@"inline" => |i| i.tree,
        };
        const find_result = tree.find(box.box);
        break :blk find_result.wasFound() and find_result.parent.child(find_result.index) == null;
    });
    try self.descendants.putNoClobber(self.allocator, box, descendant);
}

pub fn getDescendantOrNull(self: Self, box: BoxId) ?ContextId {
    return self.descendants.get(box);
}
