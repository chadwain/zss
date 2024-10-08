const std = @import("std");
const assert = std.debug.assert;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const zss = @import("zss.zig");
const Element = zss.ElementTree.Element;

pub const unicode = @import("util/unicode.zig");
pub const Stack = @import("util/Stack.zig").Stack;

fn expectSuccess(error_union: anytype, expected: @typeInfo(@TypeOf(error_union)).ErrorUnion.payload) !void {
    if (error_union) |success| {
        return std.testing.expectEqual(expected, success);
    } else |err| {
        std.debug.print("unexpected error error.{s}\n", .{@errorName(err)});
        return error.TestUnexpectedError;
    }
}

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
            const d: T = switch (typeInfo.signedness) {
                .signed => @intCast(if (num < 0)
                    gcd(Unsigned, @as(Unsigned, @intCast(-num)), @as(Unsigned, @intCast(den)))
                else
                    gcd(Unsigned, @as(Unsigned, @intCast(num)), @as(Unsigned, @intCast(den)))),
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
    const Return = @TypeOf(a, b);
    return @divFloor(a, b) + @as(Return, @intFromBool(@mod(a, b) != 0));
}

pub fn divRound(a: anytype, b: anytype) @TypeOf(a, b) {
    const Return = @TypeOf(a, b);
    return @divFloor(a, b) + @as(Return, @intFromBool(2 * @mod(a, b) >= b));
}

pub fn roundUp(a: anytype, comptime multiple: comptime_int) @TypeOf(a) {
    const Return = @TypeOf(a);
    const mod = @mod(a, multiple);
    return a + (multiple - mod) * @as(Return, @intFromBool(mod != 0));
}

test "roundUp" {
    try expect(roundUp(0, 4) == 0);
    try expect(roundUp(1, 4) == 4);
    try expect(roundUp(3, 4) == 4);
    try expect(roundUp(62, 7) == 63);
}

pub fn CheckedInt(comptime Int: type) type {
    return struct {
        overflow: bool,
        value: Int,

        const Self = @This();

        pub fn init(int: Int) Self {
            return Self{
                .overflow = false,
                .value = int,
            };
        }

        pub fn unwrap(checked: Self) error{Overflow}!Int {
            if (checked.overflow) return error.Overflow;
            return checked.value;
        }

        pub fn add(checked: *Self, int: Int) void {
            const add_result = @addWithOverflow(checked.value, int);
            checked.value = add_result[0];
            checked.overflow = checked.overflow or @bitCast(add_result[1]);
        }

        pub fn multiply(checked: *Self, int: Int) void {
            const mul_result = @mulWithOverflow(checked.value, int);
            checked.value = mul_result[0];
            checked.overflow = checked.overflow or @bitCast(mul_result[1]);
        }

        pub fn alignForward(checked: *Self, comptime alignment: Int) void {
            comptime assert(std.mem.isValidAlign(alignment));
            const lower_addr_bits = checked.value & (alignment - 1);
            if (lower_addr_bits != 0) {
                checked.add(alignment - lower_addr_bits);
            }
        }
    };
}

test "CheckedInt.alignForward" {
    const alignForward = struct {
        fn f(addr: usize, comptime alignment: comptime_int) !usize {
            var checked_int = CheckedInt(usize).init(addr);
            checked_int.alignForward(alignment);
            return checked_int.unwrap();
        }
    }.f;

    try expectSuccess(alignForward(0, 1), 0);
    try expectSuccess(alignForward(1, 1), 1);

    try expectSuccess(alignForward(0, 2), 0);
    try expectSuccess(alignForward(1, 2), 2);
    try expectSuccess(alignForward(2, 2), 2);
    try expectSuccess(alignForward(3, 2), 4);

    try expectSuccess(alignForward(0, 4), 0);
    try expectSuccess(alignForward(1, 4), 4);
    try expectSuccess(alignForward(2, 4), 4);
    try expectSuccess(alignForward(3, 4), 4);
}

pub fn ElementHashMap(comptime V: type) type {
    const Context = struct {
        pub fn eql(_: @This(), lhs: Element, rhs: Element) bool {
            return lhs.eql(rhs);
        }
        pub fn hash(_: @This(), element: Element) u64 {
            return @as(u32, @bitCast(element));
        }
    };
    return std.HashMapUnmanaged(Element, V, Context, 80);
}

pub fn ascii8ToAscii7(comptime string: []const u8) *const [string.len]u7 {
    return comptime blk: {
        var result: [string.len]u7 = undefined;
        for (string, &result) |s, *r| {
            r.* = std.math.cast(u7, s) orelse @compileError("Invalid 7-bit ASCII");
        }
        break :blk &result;
    };
}

pub fn ascii8ToUnicode(comptime string: []const u8) *const [string.len]u21 {
    return comptime blk: {
        var result: [string.len]u21 = undefined;
        for (string, &result) |in, *out| {
            if (in >= 0x80) @compileError("Invalid 7-bit ASCII");
            out.* = in;
        }
        break :blk &result;
    };
}

pub const UnicodeString = struct {
    data: []const u21,

    pub fn format(value: UnicodeString, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        var buf: [4]u8 = undefined;
        for (value.data) |codepoint| {
            const len = std.unicode.utf8Encode(codepoint, &buf) catch unreachable;
            try writer.print("{s}", .{buf[0..len]});
        }
    }
};

pub fn unicodeString(data: []const u21) UnicodeString {
    return .{ .data = data };
}

/// Two enums `Base` and `Derived` are compatible if, for every field of `Base`, there is a field in `Derived` with the same name and value.
pub fn ensureCompatibleEnums(comptime Base: type, comptime Derived: type) void {
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
