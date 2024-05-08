const Images = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const MultiArrayList = std.MultiArrayList;

pub const Handle = enum(u32) { _ };

pub const Image = struct {
    dimensions: Dimensions,
    format: Format,
    /// Externally managed image data.
    data: Data,
};

pub const Dimensions = struct {
    width_px: u32,
    height_px: u32,
};

pub const Format = enum {
    none,
    rgba,
};

pub const Data = union {
    none: void,
    rgba: ?[]const u32,
};

list: List = .{},

const List = MultiArrayList(Image);
pub const Slice = List.Slice;

pub fn deinit(images: *Images, allocator: Allocator) void {
    images.list.deinit(allocator);
}

pub fn addImage(images: *Images, allocator: Allocator, image: Image) !Handle {
    const handle: u32 = @intCast(images.list.len);
    try images.list.append(allocator, image);
    return @enumFromInt(handle);
}

pub fn slice(images: Images) Slice {
    return images.list.slice();
}
