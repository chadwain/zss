const std = @import("std");

const zss = @import("zss.zig");
const Stack = zss.Stack;

/// Two enums `Base` and `Derived` are compatible if, for every field of `Base`, there is a field in `Derived` with the same name and value.
pub fn ensureCompatibleEnums(comptime Base: type, comptime Derived: type) void {
    comptime {
        @setEvalBranchQuota(std.meta.fields(Derived).len * 1000);
        for (std.meta.fields(Base)) |field_info| {
            const derived_field = std.meta.stringToEnum(Derived, field_info.name) orelse
                @compileError(@typeName(Derived) ++ " has no field named " ++ field_info.name);
            const derived_value = @intFromEnum(derived_field);
            if (field_info.value != derived_value)
                @compileError(std.fmt.comptimePrint(
                    "{s}.{s} has value {}, expected {}",
                    .{ @typeName(Derived), field_info.name, derived_value, field_info.value },
                ));
        }
    }
}

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
