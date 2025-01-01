const std = @import("std");
const assert = std.debug.assert;
const expect = std.testing.expect;

/// The smallest unit of space in the zss coordinate system.
pub const Unit = i32;

/// The number of Units contained wthin the width or height of 1 screen pixel.
pub const units_per_pixel = 4;

pub fn pixelsToUnits(px: anytype) ?Unit {
    const scaled = std.math.mul(@TypeOf(px), px, units_per_pixel) catch return null;
    return std.math.cast(Unit, scaled);
}

pub const Vector = struct {
    x: Unit,
    y: Unit,

    pub const zero: Vector = .{ .x = 0, .y = 0 };

    pub fn add(lhs: Vector, rhs: Vector) Vector {
        return Vector{ .x = lhs.x + rhs.x, .y = lhs.y + rhs.y };
    }

    pub fn sub(lhs: Vector, rhs: Vector) Vector {
        return Vector{ .x = lhs.x - rhs.x, .y = lhs.y - rhs.y };
    }

    pub fn eql(lhs: Vector, rhs: Vector) bool {
        return lhs.x == rhs.x and lhs.y == rhs.y;
    }
};

pub const Size = struct {
    w: Unit,
    h: Unit,
};

pub const Range = struct {
    start: Unit,
    length: Unit,
};

pub const Rect = struct {
    x: Unit,
    y: Unit,
    w: Unit,
    h: Unit,

    pub fn xRange(rect: Rect) Range {
        return .{ .start = rect.x, .length = rect.w };
    }

    pub fn yRange(rect: Rect) Range {
        return .{ .start = rect.y, .length = rect.h };
    }

    // TODO: Is this a good definition of "emptiness"?
    pub fn isEmpty(rect: Rect) bool {
        return rect.w < 0 or rect.h < 0;
    }

    pub fn translate(rect: Rect, vec: Vector) Rect {
        return Rect{
            .x = rect.x + vec.x,
            .y = rect.y + vec.y,
            .w = rect.w,
            .h = rect.h,
        };
    }

    pub fn intersect(a: Rect, b: Rect) Rect {
        const left = @max(a.x, b.x);
        const right = @min(a.x + a.w, b.x + b.w);
        const top = @max(a.y, b.y);
        const bottom = @min(a.y + a.h, b.y + b.h);

        return Rect{
            .x = left,
            .y = top,
            .w = right - left,
            .h = bottom - top,
        };
    }
};

test Rect {
    const r1 = Rect{ .x = 0, .y = 0, .w = 10, .h = 10 };
    const r2 = Rect{ .x = 3, .y = 5, .w = 17, .h = 4 };
    const r3 = Rect{ .x = 15, .y = 0, .w = 20, .h = 9 };
    const r4 = Rect{ .x = 20, .y = 1, .w = 10, .h = 0 };

    const intersect = Rect.intersect;
    try expect(std.meta.eql(intersect(r1, r2), Rect{ .x = 3, .y = 5, .w = 7, .h = 4 }));
    try expect(intersect(r1, r3).isEmpty());
    try expect(intersect(r1, r4).isEmpty());
    try expect(std.meta.eql(intersect(r2, r3), Rect{ .x = 15, .y = 5, .w = 5, .h = 4 }));
    try expect(intersect(r2, r4).isEmpty());
    try expect(!intersect(r3, r4).isEmpty());
}

pub const Ratio = struct {
    num: Unit,
    den: Unit,
};

pub fn divRound(a: anytype, b: anytype) @TypeOf(a, b) {
    const Return = @TypeOf(a, b);
    return @divFloor(a, b) + @as(Return, @intFromBool(2 * @mod(a, b) >= b));
}

pub fn roundUp(a: anytype, comptime multiple: comptime_int) @TypeOf(a) {
    const Return = @TypeOf(a);
    const mod = @mod(a, multiple);
    return a + (multiple - mod) * @as(Return, @intFromBool(mod != 0));
}

test roundUp {
    try expect(roundUp(0, 4) == 0);
    try expect(roundUp(1, 4) == 4);
    try expect(roundUp(3, 4) == 4);
    try expect(roundUp(62, 7) == 63);
}

pub const Color = extern struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,

    pub fn toRgbaArray(color: Color) [4]u8 {
        return @bitCast(color);
    }

    pub fn toRgbaInt(color: Color) u32 {
        return std.mem.bigToNative(u32, @bitCast(color));
    }

    pub fn fromRgbaInt(value: u32) Color {
        return @bitCast(std.mem.nativeToBig(u32, value));
    }

    comptime {
        const eql = std.meta.eql;
        assert(eql(toRgbaArray(.{ .r = 0, .g = 0, .b = 0, .a = 0 }), .{ 0x00, 0x00, 0x00, 0x00 }));
        assert(eql(toRgbaArray(.{ .r = 255, .g = 0, .b = 0, .a = 128 }), .{ 0xff, 0x00, 0x00, 0x80 }));
        assert(eql(toRgbaArray(.{ .r = 0, .g = 20, .b = 50, .a = 200 }), .{ 0x00, 0x14, 0x32, 0xC8 }));

        assert(toRgbaInt(.{ .r = 0, .g = 0, .b = 0, .a = 0 }) == 0x00000000);
        assert(toRgbaInt(.{ .r = 255, .g = 0, .b = 0, .a = 128 }) == 0xff000080);
        assert(toRgbaInt(.{ .r = 0, .g = 20, .b = 50, .a = 200 }) == 0x001432C8);
    }

    pub const transparent = Color{ .r = 0, .g = 0, .b = 0, .a = 0 };
    pub const white = Color{ .r = 0xff, .g = 0xff, .b = 0xff, .a = 0xff };
    pub const black = Color{ .r = 0, .g = 0, .b = 0, .a = 0xff };
};

pub fn CheckedInt(comptime Int: type) type {
    return struct {
        overflow: bool,
        value: Int,

        pub fn init(int: Int) CheckedInt(Int) {
            return .{
                .overflow = false,
                .value = int,
            };
        }

        pub fn unwrap(checked: CheckedInt(Int)) error{Overflow}!Int {
            if (checked.overflow) return error.Overflow;
            return checked.value;
        }

        pub fn add(checked: *CheckedInt(Int), int: Int) void {
            const add_result = @addWithOverflow(checked.value, int);
            checked.value = add_result[0];
            checked.overflow = checked.overflow or @bitCast(add_result[1]);
        }

        pub fn multiply(checked: *CheckedInt(Int), int: Int) void {
            const mul_result = @mulWithOverflow(checked.value, int);
            checked.value = mul_result[0];
            checked.overflow = checked.overflow or @bitCast(mul_result[1]);
        }
    };
}
