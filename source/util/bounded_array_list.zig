const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn BoundedArrayList(comptime T: type, comptime upper_bound: comptime_int) type {
    return struct {
        inner: std.ArrayListUnmanaged(T) = .{},

        const Self = @This();
        pub const Size = std.math.IntFittingRange(0, upper_bound);
        const Index = Size;

        pub inline fn deinit(list: *Self, allocator: Allocator) void {
            list.inner.deinit(allocator);
        }

        pub inline fn size(list: Self) Index {
            return @intCast(Index, list.inner.items.len);
        }

        pub inline fn items(list: Self) []T {
            return list.inner.items;
        }

        pub inline fn ensureUnusedCapacity(list: *Self, allocator: Allocator, amount: Size) !void {
            if (list.inner.items.len +| amount > upper_bound) return error.Overflow;
            try list.inner.ensureUnusedCapacity(allocator, amount);
        }

        pub inline fn addOneAssumeCapacity(list: *Self) Index {
            const index = list.size();
            list.inner.items.len += 1;
            return index;
        }
    };
}
