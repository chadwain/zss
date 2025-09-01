const Images = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Handle = enum(u32) { _ };

pub const Description = struct {
    dimensions: Dimensions,
    format: Format,
    /// Externally managed image data.
    /// Use `null` to signal that the data is not available.
    data: ?[]const u8,
};

pub const Dimensions = struct {
    width_px: u32,
    height_px: u32,
};

pub const Format = enum {
    rgba,
};

descriptions: std.MultiArrayList(Description).Slice,

pub fn init() Images {
    return .{
        .descriptions = .empty,
    };
}

pub fn deinit(images: *Images, allocator: Allocator) void {
    images.descriptions.deinit(allocator);
}

pub fn addImage(images: *Images, allocator: Allocator, desc: Description) !Handle {
    var list = images.descriptions.toMultiArrayList();
    defer images.descriptions = list.slice();

    const handle = images.nextHandle() orelse return error.OutOfImages;
    try list.append(allocator, desc);
    return handle;
}

fn nextHandle(images: Images) ?Handle {
    if (images.descriptions.len == std.math.maxInt(std.meta.Tag(Handle))) return null;
    return @enumFromInt(images.descriptions.len);
}

pub fn dimensions(images: *const Images, handle: Handle) Dimensions {
    return images.descriptions.items(.dimensions)[@intFromEnum(handle)];
}

pub fn format(images: *const Images, handle: Handle) Format {
    return images.descriptions.items(.format)[@intFromEnum(handle)];
}

pub fn data(images: *const Images, handle: Handle) []const u8 {
    return images.descriptions.items(.data)[@intFromEnum(handle)];
}

pub fn get(images: *const Images, handle: Handle) Description {
    return images.descriptions.get(@intFromEnum(handle));
}
