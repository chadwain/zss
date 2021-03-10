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
const BoxOffsets = zss.types.BoxOffsets;

usingnamespace @import("properties.zig");

// TODO add data to keep track of which boxes are positioned boxes.
// positioned boxes must be rendered after all other boxes

preorder_array: []u16,
box_offsets: []BoxOffsets,
borders: []Borders,
border_colors: []BorderColor,
background_color: []BackgroundColor,
background_image: []BackgroundImage,
visual_effect: []VisualEffect,

pub fn deinit(self: *@This(), allocator: *Allocator) void {
    allocator.free(self.preorder_array);
    allocator.free(self.box_offsets);
    allocator.free(self.borders);
    allocator.free(self.border_colors);
    allocator.free(self.background_color);
    allocator.free(self.background_image);
    allocator.free(self.visual_effect);
}
