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
const AutoHashMapUnmanaged = std.AutoHashMapUnmanaged;

const zss = @import("../zss.zig");
const BlockFormattingContext = zss.BlockFormattingContext;
const InlineFormattingContext = zss.InlineFormattingContext;

const Self = @This();

pub const ContextId = struct { v: u32 };

pub const BoxId = u16;

const ElementId = struct {
    ctx: ContextId,
    box: BoxId,
};

pub const FormattingContext = union(enum) {
    block: *BlockFormattingContext,
    @"inline": *InlineFormattingContext,
};

context_id_counter: ContextId = .{ .v = 0 },
root_context_id: ContextId = .{ .v = 0 },
contexts: AutoHashMapUnmanaged(ContextId, FormattingContext) = .{},
descendants: AutoHashMapUnmanaged(ElementId, ContextId) = .{},
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
    try self.contexts.putNoClobber(self.allocator, id, context);
    return id;
}

pub fn getContext(self: Self, ctxId: ContextId) FormattingContext {
    return self.contexts.get(ctxId) orelse unreachable;
}

// Although it is not checked here, the containing box must not have any children within its context.
pub fn setDescendant(self: *Self, ctx: ContextId, box: BoxId, descendant: ContextId) !void {
    try self.descendants.putNoClobber(self.allocator, ElementId{ .ctx = ctx, .box = box }, descendant);
}

pub fn getDescendantOrNull(self: Self, ctx: ContextId, box: BoxId) ?ContextId {
    return self.descendants.get(.{ .ctx = ctx, .box = box });
}
