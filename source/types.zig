// This file is a part of zss.
// Copyright (C) 2020-2021 Chadwain Holness
//
// This library is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this library.  If not, see <https://www.gnu.org/licenses/>.

const std = @import("std");
const expect = std.testing.expect;
const min = std.math.min;
const max = std.math.max;

const zss = @import("../zss.zig");
const Borders = zss.properties.Borders;
const OffsetInfo = zss.offset_tree.OffsetInfo;

/// An integral, indivisible unit of space which is the basis for all CSS layout
/// computations.
pub const CSSUnit = i32;

pub const Percentage = f32;

pub fn Ratio(comptime T: type) type {
    return struct { num: T, den: T };
}

pub const Offset = struct {
    x: CSSUnit,
    y: CSSUnit,

    const Self = @This();
    pub fn add(lhs: Self, rhs: Self) Self {
        return Self{ .x = lhs.x + rhs.x, .y = lhs.y + rhs.y };
    }
};

pub const BoxOffsets = struct {
    border_top_left: Offset,
    border_bottom_right: Offset,
    content_top_left: Offset,
    content_bottom_right: Offset,
};

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
