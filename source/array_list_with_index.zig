const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn ArrayListWithIndex(comptime Item: type, comptime Index: type) type {
    return struct {
        std_list: std.ArrayListUnmanaged(Item) = .empty,

        const Self = @This();
        const max_size = std.math.maxInt(Index);

        pub const empty = Self{
            .std_list = .empty,
        };

        pub fn deinit(self: *Self, allocator: Allocator) void {
            self.std_list.deinit(allocator);
        }

        pub fn len(self: Self) Index {
            return @intCast(self.std_list.items.len);
        }

        pub fn items(self: Self) []Item {
            return self.std_list.items;
        }

        pub fn append(self: *Self, allocator: Allocator, item: Item) !void {
            if (self.std_list.items.len == max_size) return error.OutOfMemory;
            return self.std_list.append(allocator, item);
        }

        pub fn appendSlice(self: *Self, allocator: Allocator, slice: []const Item) !void {
            const new_len = std.math.add(usize, self.std_list.items.len, slice.len) catch return error.OutOfMemory;
            _ = std.math.cast(Index, new_len) orelse return error.OutOfMemory;
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
