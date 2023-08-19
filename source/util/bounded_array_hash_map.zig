const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn BoundedArrayHashMap(
    comptime Key: type,
    comptime Value: type,
    comptime Context: type,
    comptime store_hash: bool,
    comptime upper_bound: comptime_int,
) type {
    return struct {
        inner: std.ArrayHashMapUnmanaged(Key, Value, Context, store_hash) = .{},

        const Self = @This();
        pub const Index = std.math.IntFittingRange(0, upper_bound);
        pub const GetOrPutResult = struct {
            key_ptr: *Key,
            value_ptr: *Value,
            found_existing: bool,
            index: Index,
        };

        pub inline fn deinit(map: *Self, allocator: Allocator) void {
            map.inner.deinit(allocator);
        }

        pub inline fn size(map: Self) Index {
            return @intCast(map.inner.count());
        }

        pub fn values(map: Self) []Value {
            return map.inner.values();
        }

        pub inline fn getOrPutContext(map: *Self, allocator: Allocator, key: Key, context: Context) !GetOrPutResult {
            const result = try map.inner.getOrPutContext(allocator, key, context);
            if (map.inner.count() > upper_bound) {
                map.inner.swapRemoveAtContext(result.index, context);
                return error.Overflow;
            }

            return GetOrPutResult{
                .key_ptr = result.key_ptr,
                .value_ptr = result.value_ptr,
                .found_existing = result.found_existing,
                .index = @intCast(result.index),
            };
        }
    };
}
