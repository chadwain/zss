const std = @import("std");
const expect = std.testing.expect;
const min = std.math.min;
const max = std.math.max;

const zss = @import("../zss.zig");
const CSSUnit = zss.used_values.CSSUnit;

pub fn Ratio(comptime T: type) type {
    return struct { num: T, den: T };
}

pub const CSSSize = struct {
    w: CSSUnit,
    h: CSSUnit,
};

pub const CSSRect = struct {
    x: CSSUnit,
    y: CSSUnit,
    w: CSSUnit,
    h: CSSUnit,

    const Self = @This();

    pub fn isEmpty(self: Self) bool {
        return self.w <= 0 or self.h <= 0;
    }

    pub fn intersect(a: Self, b: Self) Self {
        const left = max(a.x, b.x);
        const right = min(a.x + a.w, b.x + b.w);
        const top = max(a.y, b.y);
        const bottom = min(a.y + a.h, b.y + b.h);

        return Self{
            .x = left,
            .y = top,
            .w = right - left,
            .h = bottom - top,
        };
    }
};

test "CSSRect" {
    const r1 = CSSRect{ .x = 0, .y = 0, .w = 10, .h = 10 };
    const r2 = CSSRect{ .x = 3, .y = 5, .w = 17, .h = 4 };
    const r3 = CSSRect{ .x = 15, .y = 0, .w = 20, .h = 9 };
    const r4 = CSSRect{ .x = 20, .y = 1, .w = 10, .h = 0 };

    const intersect = CSSRect.intersect;
    expect(std.meta.eql(intersect(r1, r2), CSSRect{ .x = 3, .y = 5, .w = 7, .h = 4 }));
    expect(intersect(r1, r3).isEmpty());
    expect(intersect(r1, r4).isEmpty());
    expect(std.meta.eql(intersect(r2, r3), CSSRect{ .x = 15, .y = 5, .w = 5, .h = 4 }));
    expect(intersect(r2, r4).isEmpty());
    expect(intersect(r3, r4).isEmpty());
}

pub const ThreeBoxes = struct {
    border: CSSRect,
    padding: CSSRect,
    content: CSSRect,
};
