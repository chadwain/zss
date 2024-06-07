const std = @import("std");
const Allocator = std.mem.Allocator;
const MultiArrayList = std.MultiArrayList;

const zss = @import("../zss.zig");
const DebugOptional = zss.util.DebugOptional;

/// A stack data structure, where the top-most value is stored on the (program) stack.
pub fn Stack(comptime T: type) type {
    return struct {
        /// The top of the stack. This is undefined in exactly two scenarios:
        ///     1. Just after stack initialization.
        ///     2. There is nothing in `rest`, and `pop` is called.
        top: DebugOptional(T) = DebugOptional(T).init(),
        /// The rest of the stack. Items lower in the stack are earlier in the list.
        rest: MultiArrayList(T) = .{},

        const Self = @This();

        pub fn deinit(stack: *Self, allocator: Allocator) void {
            stack.rest.deinit(allocator);
        }

        /// Pushes the current value of `stack.top`, and replaces it with `new_top`.
        /// Before calling this function, you must have given `stack.top` a value.
        pub fn push(stack: *Self, allocator: Allocator, new_top: T) !void {
            try stack.rest.append(allocator, stack.top.unwrap);
            stack.top.set(new_top);
        }

        /// Returns the current value of `stack.top`, and replaces it with the last value from `stack.rest`.
        /// If there is nothing in `stack.rest`, then `stack.top` becomes undefined.
        pub fn pop(stack: *Self) T {
            defer if (stack.rest.len == 0) stack.top.unset() else stack.top.set(stack.rest.pop());
            return stack.top.unwrap;
        }
    };
}
