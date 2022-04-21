const zss = @import("../../zss.zig");
const ReferencedSkipTree = zss.ReferencedSkipTree;

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const ElementIndex = u16;
pub const ElementRef = u16;

pub const ElementTree = struct {
    tree: ReferencedSkipTree(ElementIndex, ElementRef, struct {}) = .{},

    const Self = @This();

    pub fn deinit(self: *Self, allocator: Allocator) void {
        self.tree.deinit(allocator);
    }

    pub fn size(self: Self) ElementIndex {
        return self.tree.size();
    }

    pub fn ensureTotalCapacity(self: *Self, allocator: Allocator, count: ElementIndex) error{ OutOfRefs, OutOfMemory }!void {
        return self.tree.ensureTotalCapacity(allocator, count);
    }

    pub fn createRootAssumeCapacity(self: *Self) ElementRef {
        return self.tree.createRootAssumeCapacity(.{});
    }

    pub fn appendChildAssumeCapacity(self: *Self, parent: ElementRef) ElementRef {
        return self.tree.appendChildAssumeCapacity(parent, .{});
    }
};
