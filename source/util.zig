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

const zss = @import("../zss.zig");
usingnamespace zss.types;
const used = zss.used_properties;
const OffsetInfo = zss.offset_tree.OffsetInfo;

pub fn getThreeBoxes(offset: Offset, offset_info: OffsetInfo, borders: used.Borders) ThreeBoxes {
    const border_x = offset.x + offset_info.border_top_left.x;
    const border_y = offset.y + offset_info.border_top_left.y;
    const border_w = offset_info.border_bottom_right.x - offset_info.border_top_left.x;
    const border_h = offset_info.border_bottom_right.y - offset_info.border_top_left.y;

    return ThreeBoxes{
        .border = CSSRect{
            .x = border_x,
            .y = border_y,
            .w = border_w,
            .h = border_h,
        },
        .padding = CSSRect{
            .x = border_x + borders.left,
            .y = border_y + borders.top,
            .w = border_w - borders.left - borders.right,
            .h = border_h - borders.top - borders.bottom,
        },
        .content = CSSRect{
            .x = offset.x + offset_info.content_top_left.x,
            .y = offset.y + offset_info.content_top_left.y,
            .w = offset_info.content_bottom_right.x - offset_info.content_top_left.x,
            .h = offset_info.content_bottom_right.y - offset_info.content_top_left.y,
        },
    };
}

pub fn divCeil(comptime T: type, a: T, b: T) T {
    return @divFloor(a, b) + @boolToInt(@mod(a, b) != 0);
}
