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
