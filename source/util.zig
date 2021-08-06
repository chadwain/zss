const std = @import("std");
const assert = std.debug.assert;
const expect = std.testing.expect;

const zss = @import("../zss.zig");
const used_values = zss.used_values;
const ZssRect = used_values.ZssRect;

pub fn Ratio(comptime T: type) type {
    return struct { num: T, den: T };
}

pub fn divCeil(a: anytype, b: anytype) @TypeOf(a, b) {
    return @divFloor(a, b) + @boolToInt(@mod(a, b) != 0);
}

pub fn divRound(a: anytype, b: anytype) @TypeOf(a, b) {
    return @divFloor(a, b) + @boolToInt(2 * @mod(a, b) >= b);
}

pub fn roundUp(a: anytype, comptime multiple: comptime_int) @TypeOf(a) {
    const mod = @mod(a, multiple);
    return a + (multiple - mod) * @boolToInt(mod != 0);
}

test "roundUp" {
    try expect(roundUp(0, 4) == 0);
    try expect(roundUp(1, 4) == 4);
    try expect(roundUp(3, 4) == 4);
    try expect(roundUp(62, 7) == 63);
}

pub fn StructureArray(comptime T: type) type {
    return struct {
        pub const TreeIterator = struct {
            items: []const T,
            current: T,
            target: T,

            pub fn next(self: *@This()) ?T {
                if (self.target < self.current) return null;
                while (self.target >= self.current + self.items[self.current]) {
                    self.current += self.items[self.current];
                }
                defer self.current += 1;
                return self.current;
            }
        };

        pub fn treeIterator(items: []const T, parent: T, child: T) TreeIterator {
            assert(child >= parent and child < parent + items[parent]);
            return TreeIterator{
                .items = items,
                .current = parent,
                .target = child,
            };
        }

        pub const ChildIterator = struct {
            items: []const T,
            current: T,
            end: T,

            pub fn next(self: *@This()) ?T {
                if (self.current == self.end) return null;
                defer self.current += self.items[self.current];
                return self.current;
            }
        };

        pub fn childIterator(items: []const T, parent: T) ChildIterator {
            return ChildIterator{
                .items = items,
                .current = parent + 1,
                .end = parent + items[parent],
            };
        }
    };
}
