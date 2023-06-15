const std = @import("std");
const assert = std.debug.assert;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const zss = @import("../../zss.zig");
const Element = zss.ElementTree.Element;
const used_values = zss.used_values;
const ZssRect = used_values.ZssRect;

pub fn Ratio(comptime T: type) type {
    const typeInfo = @typeInfo(T).Int;
    const Unsigned = std.meta.Int(.unsigned, typeInfo.bits);
    return struct {
        num: T,
        den: T,

        const Self = @This();

        pub fn fromInt(int: T) Self {
            return Self{
                .num = int,
                .den = 1,
            };
        }

        pub fn initReduce(num: T, den: T) Self {
            assert(den > 0);
            const d = switch (typeInfo.signedness) {
                .signed => @intCast(T, if (num < 0)
                    gcd(Unsigned, @intCast(Unsigned, -num), @intCast(Unsigned, den))
                else
                    gcd(Unsigned, @intCast(Unsigned, num), @intCast(Unsigned, den))),
                .unsigned => gcd(T, num, den),
            };
            return Self{
                .num = @divExact(num, d),
                .den = @divExact(den, d),
            };
        }

        pub fn add(a: Self, b: Self) Self {
            return Self{
                .num = a.num * b.den + a.den * b.num,
                .den = a.den * b.den,
            };
        }

        pub fn sub(a: Self, b: Self) Self {
            return Self{
                .num = a.num * b.den - a.den * b.num,
                .den = a.den * b.den,
            };
        }

        pub fn mul(a: Self, b: Self) Self {
            return Self{
                .num = a.num * b.num,
                .den = a.den * b.den,
            };
        }

        pub fn div(a: Self, b: Self) Self {
            return Self{
                .num = a.num * b.den,
                .den = a.den * b.num,
            };
        }

        pub fn addInt(self: Self, int: T) Self {
            return Self{
                .num = self.num + self.den * int,
                .den = self.den,
            };
        }

        pub fn subInt(self: Self, int: T) Self {
            return Self{
                .num = self.num - self.den * int,
                .den = self.den,
            };
        }

        pub fn eqlInt(self: Self, int: T) bool {
            return self.num == self.den * int;
        }

        pub fn floor(self: Self) T {
            return @divFloor(self.num, self.den);
        }

        pub fn ceil(self: Self) T {
            return divCeil(self.num, self.den);
        }

        pub fn mod(self: Self) T {
            return @mod(self.num, self.den);
        }
    };
}

pub fn gcd(comptime T: type, a: T, b: T) T {
    var x = a;
    var y = b;
    var r = x % y;
    while (r != 0) {
        x = y;
        y = r;
        r = x % y;
    }
    return y;
}

test "gcd" {
    try expectEqual(@as(u32, 4), gcd(u32, 20, 16));
    try expectEqual(@as(u32, 1), gcd(u32, 7, 16));
    try expectEqual(@as(u32, 12), gcd(u32, 96, 60));
    try expectEqual(@as(u32, 3), gcd(u32, 21, 108));
    try expectEqual(@as(u32, 108), gcd(u32, 0, 108));
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

pub fn ElementHashMap(comptime V: type) type {
    const Context = struct {
        pub fn eql(_: @This(), lhs: Element, rhs: Element) bool {
            return lhs.eql(rhs);
        }
        pub fn hash(_: @This(), element: Element) u64 {
            return @bitCast(u32, element);
        }
    };
    return std.HashMapUnmanaged(Element, V, Context, 80);
}

pub fn asciiString(comptime string: []const u8) *const [string.len]u7 {
    comptime {
        var result: [string.len]u7 = undefined;
        for (string) |c, i| {
            result[i] = std.math.cast(u7, c) orelse unreachable;
        }
        return &result;
    }
}
