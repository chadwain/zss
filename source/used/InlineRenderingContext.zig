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

const hb = @import("../../dependencies/harfbuzz.zig");

pub const BoxMeasures = struct {
    border: CSSUnit = 0,
    padding: CSSUnit = 0,
    border_color_rgba: u32 = 0,
};

pub const Heights = struct {
    above_baseline: CSSUnit,
    below_baseline: CSSUnit,
};

pub const LineBox = struct {
    baseline: CSSUnit,
    elements: [2]usize,
};

pub const special_index = 0xFFFF;
pub const SpecialMeaning = enum { BoxStart, BoxEnd, Literal_FFFF };

// NOTE may need to make sure this is never a valid glyph index when bitcasted
pub const Special = struct {
    meaning: SpecialMeaning,
    id: u16,
};

pub fn encodeSpecial(comptime meaning: SpecialMeaning, id: u16) hb.hb_codepoint_t {
    const result = Special{ .meaning = meaning, .id = id };
    return @bitCast(hb.hb_codepoint_t, result);
}

pub fn decodeSpecial(glyph_index: hb.hb_codepoint_t) Special {
    return @bitCast(Special, glyph_index);
}

pub const Position = struct {
    offset: CSSUnit,
    advance: CSSUnit,
    width: CSSUnit,
};

// TODO add data to keep track of which boxes are positioned boxes.
// positioned boxes must be rendered after all other boxes

glyph_indeces: []hb.hb_codepoint_t,
positions: []Position,
line_boxes: []LineBox,
// TODO one global font for the entire context. should be removed at a later date.
font: *hb.hb_font_t,

// per inline element
measures_top: []BoxMeasures,
measures_right: []BoxMeasures,
measures_bottom: []BoxMeasures,
measures_left: []BoxMeasures,
heights: []Heights,
background_color: []BackgroundColor,
// TODO
// background_image: []BackgroundImage,

pub fn deinit(self: *@This(), allocator: *Allocator) void {
    allocator.free(self.glyph_indeces);
    allocator.free(self.positions);
    allocator.free(self.line_boxes);
    allocator.free(self.measures_top);
    allocator.free(self.measures_right);
    allocator.free(self.measures_bottom);
    allocator.free(self.measures_left);
    allocator.free(self.heights);
    allocator.free(self.background_color);
}
