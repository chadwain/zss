const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

/// A stack data structure, where the top-most value is stored on the (program) stack.
pub fn Stack(comptime T: type) type {
    return struct {
        /// The top of the stack. When this is null, the stack is completely empty.
        top: ?T = null,
        /// The rest of the stack. Items lower in the stack are earlier in the list.
        rest: ArrayListUnmanaged(T) = .empty,

        pub const Item = T;

        pub fn init(top: T) Stack(T) {
            return .{ .top = top };
        }

        pub fn deinit(stack: *Stack(T), allocator: Allocator) void {
            stack.rest.deinit(allocator);
        }

        pub fn len(stack: Stack(T)) usize {
            return @intFromBool(stack.top != null) + stack.rest.items.len;
        }

        /// Causes `new_top` to become the new highest item in the stack.
        /// This function must only be called after setting `stack.top` to a non-null value.
        pub fn push(stack: *Stack(T), allocator: Allocator, new_top: T) !void {
            try stack.rest.append(allocator, stack.top.?);
            stack.top = new_top;
        }

        /// Returns the current value of `stack.top`, and replaces it with the last value from `stack.rest`.
        /// If there is nothing in `stack.rest`, then `stack.top` becomes null.
        /// This function must not be called if `stack.top` is already null.
        pub fn pop(stack: *Stack(T)) T {
            defer stack.top = stack.rest.pop();
            return stack.top.?;
        }
    };
}
