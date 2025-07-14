const std = @import("std");

const zss = @import("zss.zig");
const Stack = zss.Stack;

pub const runtime_safety = switch (@import("builtin").mode) {
    .Debug, .ReleaseSafe => true,
    .ReleaseFast, .ReleaseSmall => false,
};

/// Iterate over an array of skips, while also being given the depth of each element.
pub fn skipArrayIterate(
    comptime Size: type,
    skips: []const Size,
    context: anytype,
    comptime callback: fn (@TypeOf(context), index: Size, depth: Size) anyerror!void,
    allocator: std.mem.Allocator,
) !void {
    if (skips.len == 0) return;

    const Interval = struct {
        begin: Size,
        end: Size,
    };

    var stack: Stack(Interval) = .{};
    defer stack.deinit(allocator);
    stack.top = .{ .begin = 0, .end = skips[0] };

    while (stack.top) |*top| {
        const index = index: {
            if (top.begin == top.end) {
                _ = stack.pop();
                continue;
            }
            defer top.begin += skips[top.begin];
            break :index top.begin;
        };
        try callback(context, index, @intCast(stack.lenExcludingTop()));
        const skip = skips[index];
        if (skip != 1) {
            try stack.push(allocator, .{ .begin = index + 1, .end = index + skip });
        }
    }
}
