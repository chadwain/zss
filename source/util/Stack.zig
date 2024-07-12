const std = @import("std");
const Allocator = std.mem.Allocator;
const MultiArrayList = std.MultiArrayList;

/// A stack data structure, where the top-most value is stored on the (program) stack.
pub fn Stack(comptime T: type) type {
    return struct {
        /// The top of the stack. When this is null, the stack is completely empty.
        top: ?T = null,
        /// The rest of the stack. Items lower in the stack are earlier in the list.
        rest: MultiArrayList(T) = .{},

        const Self = @This();

        pub fn deinit(stack: *Self, allocator: Allocator) void {
            stack.rest.deinit(allocator);
        }

        pub fn len(stack: Self) usize {
            return @intFromBool(stack.top != null) + stack.rest.len;
        }

        /// Pushes the current value of `stack.top`, and replaces it with `new_top`.
        /// `stack.top` must be set before calling this function.
        pub fn push(stack: *Self, allocator: Allocator, new_top: T) !void {
            try stack.rest.append(allocator, stack.top.?);
            stack.top = new_top;
        }

        /// Returns the current value of `stack.top`, and replaces it with the last value from `stack.rest`.
        /// If there is nothing in `stack.rest`, then `stack.top` becomes null.
        pub fn pop(stack: *Self) T {
            defer stack.top = stack.rest.popOrNull();
            return stack.top.?;
        }
    };
}
