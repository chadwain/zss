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
const Allocator = std.mem.Allocator;

const zss = @import("../../zss.zig");
const CSSUnit = zss.types.CSSUnit;
const Offset = zss.types.Offset;

usingnamespace @import("properties.zig");

pub const InlineBoxFragment = struct {
    offset: Offset,
    width: CSSUnit,
    height: CSSUnit,
    inline_box_id: u16,
    include_top: bool,
    include_right: bool,
    include_bottom: bool,
    include_left: bool,
};

pub const BoxMeasures = struct {
    border: CSSUnit = 0,
    padding: CSSUnit = 0,
    border_color_rgba: u32 = 0,
};

// TODO add data to keep track of which boxes are positioned boxes.
// positioned boxes must be rendered after all other boxes

// per fragment
fragments: []InlineBoxFragment,

// per inline element
measures_top: []BoxMeasures,
measures_right: []BoxMeasures,
measures_bottom: []BoxMeasures,
measures_left: []BoxMeasures,
background_color: []BackgroundColor,
// TODO
// background_image: []BackgroundImage,

pub fn deinit(self: *@This(), allocator: *Allocator) void {
    allocator.free(self.fragments);
    allocator.free(self.box_offsets);
    allocator.free(self.borders);
    allocator.free(self.border_colors);
    allocator.free(self.background_color);
}
