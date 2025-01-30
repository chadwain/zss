const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn ArrayListSized(comptime Item: type) type {
    return struct {
        std_list: std.ArrayListUnmanaged(Item) = .empty,
        max_size: usize,

        const Self = @This();

        pub fn deinit(self: *Self, allocator: Allocator) void {
            self.std_list.deinit(allocator);
        }

        pub fn len(self: Self) usize {
            return self.std_list.items.len;
        }

        pub fn items(self: Self) []Item {
            return self.std_list.items;
        }

        pub fn append(self: *Self, allocator: Allocator, item: Item) !void {
            if (self.std_list.items.len == self.max_size) return error.OutOfMemory;
            return self.std_list.append(allocator, item);
        }

        pub fn appendSlice(self: *Self, allocator: Allocator, slice: []const Item) !void {
            if (self.max_size -| slice.len <= self.std_list.items.len) return error.OutOfMemory;
            return self.std_list.appendSlice(allocator, slice);
        }

        pub fn toOwnedSlice(self: *Self, allocator: Allocator) ![]Item {
            return self.std_list.toOwnedSlice(allocator);
        }

        pub fn clearRetainingCapacity(self: *Self) void {
            self.std_list.clearRetainingCapacity();
        }
    };
}
