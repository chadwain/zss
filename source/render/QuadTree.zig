const QuadTree = @This();

const zss = @import("../zss.zig");
const ZssUnit = zss.used_values.ZssUnit;
const ZssRect = zss.used_values.ZssRect;
const ZssVector = zss.used_values.ZssVector;
const BlockBox = zss.used_values.BlockBox;
const BlockBoxIndex = zss.used_values.BlockBoxIndex;
const SubtreeIndex = zss.used_values.SubtreeIndex;
const BlockSubtree = zss.used_values.BlockSubtree;
const InlineFormattingContextIndex = zss.used_values.InlineFormattingContextIndex;
const BoxTree = zss.used_values.BoxTree;
const DrawOrderList = @import("./DrawOrderList.zig");

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

// A "patch" is a square with side length `top_level_size`.
// Space is represented as an infinite grid of patches.
// Each patch has a coordinate (x, y), with x increasing to the left and y increasing downwards.
// Patches can be subdivided into 4 equally sized smaller squares called quadrants.
// Each quadrant can also be subdivided recursively, up to a maximum of `maximum_node_depth` times.

const top_level_size: ZssUnit = 1024 * zss.used_values.units_per_pixel;
const maximum_node_depth = 7;

/// The coordinates of a patch.
const PatchCoord = struct {
    x: i32,
    y: i32,
};

/// Represents a 2D range of patches.
/// The bottom-right-most patch coordinate is NOT included in the range.
const PatchSpan = struct {
    top_left: PatchCoord,
    bottom_right: PatchCoord,

    fn intersects(a: PatchSpan, b: PatchSpan) bool {
        const left = @max(a.top_left.x, b.top_left.x);
        const right = @min(a.bottom_right.x, b.bottom_right.x);
        const top = @max(a.top_left.y, b.top_left.y);
        const bottom = @min(a.bottom_right.y, b.bottom_right.y);
        return left < right and top < bottom;
    }
};

/// The objects that are stored in the QuadTree.
pub const Object = DrawOrderList.DrawableRef;

/// An object is considered "large" if its bounding box spans more than one patch.
const LargeObject = struct {
    object: Object,
    patch_span: PatchSpan,
};

patch_map: std.AutoHashMapUnmanaged(PatchCoord, *Node) = .{},
large_objects: ArrayListUnmanaged(LargeObject) = .{},

/// Destroy the QuadTree.
pub fn deinit(quad_tree: *QuadTree, allocator: Allocator) void {
    quad_tree.large_objects.deinit(allocator);
    var iterator = quad_tree.patch_map.iterator();
    while (iterator.next()) |entry| {
        const node = entry.value_ptr.*;
        node.deinit(allocator);
    }
    quad_tree.patch_map.deinit(allocator);
}

/// A `Node` represents either a patch or a patch quadrant.
const Node = struct {
    depth: u3,
    objects: ArrayListUnmanaged(Object) = .{},
    /// children are ordered: top left, top right, bottom left, bottom right
    children: [4]?*Node = .{ null, null, null, null },

    fn deinit(node: *Node, allocator: Allocator) void {
        node.objects.deinit(allocator);
        for (node.children) |child| {
            if (child) |child_node| child_node.deinit(allocator);
        }
        allocator.destroy(node);
    }

    fn insert(node: *Node, allocator: Allocator, patch_intersect: ZssRect, object: Object) error{OutOfMemory}!void {
        assert(!patch_intersect.isEmpty());
        const patch_size = top_level_size >> node.depth;
        const quadrant_size = patch_size >> 1;
        if (patch_intersect.w > quadrant_size or patch_intersect.h > quadrant_size or node.depth == maximum_node_depth) {
            try node.objects.append(allocator, object);
            return;
        }

        const quadrant_rects = [4]ZssRect{
            ZssRect{ .x = 0, .y = 0, .w = quadrant_size, .h = quadrant_size },
            ZssRect{ .x = quadrant_size, .y = 0, .w = quadrant_size, .h = quadrant_size },
            ZssRect{ .x = 0, .y = quadrant_size, .w = quadrant_size, .h = quadrant_size },
            ZssRect{ .x = quadrant_size, .y = quadrant_size, .w = quadrant_size, .h = quadrant_size },
        };

        var quadrant_index: u2 = undefined;
        var quadrant_intersect: ZssRect = undefined;
        var num_intersects: u3 = 0;
        for (quadrant_rects, 0..) |rect, i| {
            const intersection = rect.intersect(patch_intersect);
            if (!intersection.isEmpty()) {
                num_intersects += 1;
                quadrant_index = @intCast(i);
                quadrant_intersect = intersection;
            }
        }

        switch (num_intersects) {
            0, 5...7 => unreachable,
            1 => {
                const child_rect = quadrant_rects[quadrant_index];
                const child = node.children[quadrant_index] orelse blk: {
                    const child = try allocator.create(Node);
                    child.* = .{ .depth = node.depth + 1 };
                    node.children[quadrant_index] = child;
                    break :blk child;
                };
                try child.insert(allocator, .{
                    .x = quadrant_intersect.x - child_rect.x,
                    .y = quadrant_intersect.y - child_rect.y,
                    .w = quadrant_intersect.w,
                    .h = quadrant_intersect.h,
                }, object);
                return;
            },
            2...4 => {
                try node.objects.append(allocator, object);
                return;
            },
        }
    }

    fn findObjectsInRect(
        node: *const Node,
        patch_intersect: ZssRect,
        list: *ArrayListUnmanaged(Object),
        allocator: Allocator,
    ) error{OutOfMemory}!void {
        assert(!patch_intersect.isEmpty());
        try list.appendSlice(allocator, node.objects.items);

        if (node.depth == 7) {
            return;
        }

        const patch_size = top_level_size >> node.depth;
        const quadrant_size = patch_size >> 1;
        const quadrant_rects = [4]ZssRect{
            ZssRect{ .x = 0, .y = 0, .w = quadrant_size, .h = quadrant_size },
            ZssRect{ .x = quadrant_size, .y = 0, .w = quadrant_size, .h = quadrant_size },
            ZssRect{ .x = 0, .y = quadrant_size, .w = quadrant_size, .h = quadrant_size },
            ZssRect{ .x = quadrant_size, .y = quadrant_size, .w = quadrant_size, .h = quadrant_size },
        };

        for (quadrant_rects, node.children) |rect, child_opt| {
            const child = child_opt orelse continue;
            const intersection = rect.intersect(patch_intersect);
            if (intersection.isEmpty()) continue;
            try child.findObjectsInRect(.{
                .x = intersection.x - rect.x,
                .y = intersection.y - rect.y,
                .w = intersection.w,
                .h = intersection.h,
            }, list, allocator);
        }
    }

    fn print(node: Node, writer: anytype) @TypeOf(writer).Error!void {
        const indent = @as(usize, node.depth) * 4;
        try writer.writeByteNTimes(' ', indent);
        try writer.print("Depth {}\n", .{node.depth});
        for (node.objects.items) |object| {
            try writer.writeByteNTimes(' ', indent);
            try writer.print("{}\n", .{object});
        }
        for (node.children, 0..) |child, i| {
            if (child) |child_node| {
                const quadrant_string = switch (@as(u2, @intCast(i))) {
                    0 => "top left",
                    1 => "top right",
                    2 => "bottom left",
                    3 => "bottom right",
                };
                try writer.writeByteNTimes(' ', indent);
                try writer.print("Quadrant {s}\n", .{quadrant_string});
                try child_node.print(writer);
            }
        }
    }
};

/// Insert an object into the QuadTree.
pub fn insert(quad_tree: *QuadTree, allocator: Allocator, bounding_box: ZssRect, object: Object) !void {
    const patch_span = rectToPatchSpan(bounding_box);

    if (patch_span.bottom_right.x - patch_span.top_left.x > 1 or patch_span.bottom_right.y - patch_span.top_left.y > 1) {
        try quad_tree.large_objects.append(allocator, .{
            .patch_span = patch_span,
            .object = object,
        });
    } else {
        const patch_coord = patch_span.top_left;
        const node = try quad_tree.getNode(allocator, patch_coord);
        const patch_rect = getPatchRect(patch_coord);
        const patch_intersect = patch_rect.intersect(bounding_box).translate(.{ .x = -patch_rect.x, .y = -patch_rect.y });
        try node.insert(allocator, patch_intersect, object);
    }
}

fn getNode(quad_tree: *QuadTree, allocator: Allocator, patch_coord: PatchCoord) !*Node {
    const gop_result = try quad_tree.patch_map.getOrPut(allocator, patch_coord);
    if (gop_result.found_existing) {
        return gop_result.value_ptr.*;
    } else {
        errdefer quad_tree.patch_map.removeByPtr(gop_result.key_ptr);
        const node = try allocator.create(Node);
        node.* = .{ .depth = 0 };
        gop_result.value_ptr.* = node;
        return node;
    }
}

pub fn print(quad_tree: QuadTree, writer: anytype) !void {
    try writer.writeAll("Large objects:\n");
    for (quad_tree.large_objects.items) |large_object| {
        try writer.print("\tPatch span ({}, {}) to ({}, {}), {}\n", .{
            large_object.patch_span.top_left.x,
            large_object.patch_span.top_left.y,
            large_object.patch_span.bottom_right.x,
            large_object.patch_span.bottom_right.y,
            large_object.object,
        });
    }
    try writer.writeAll("\n");

    var iterator = quad_tree.patch_map.iterator();
    while (iterator.next()) |entry| {
        const patch_coord = entry.key_ptr.*;
        const node = entry.value_ptr.*;
        try writer.print("Patch ({}, {})\n", .{ patch_coord.x, patch_coord.y });
        try node.print(writer);
    }
}

/// Creates an unordered list of objects which may intersect with the rectangle `rect`.
/// Some objects may not actually intersect the rectangle.
/// The memory is owned by the caller.
pub fn findObjectsInRect(quad_tree: QuadTree, rect: ZssRect, allocator: Allocator) ![]Object {
    var result = ArrayListUnmanaged(Object){};
    defer result.deinit(allocator);

    var patch_span = rectToPatchSpan(rect);

    for (quad_tree.large_objects.items) |large_object| {
        if (patch_span.intersects(large_object.patch_span)) {
            try result.append(allocator, large_object.object);
        }
    }

    while (patch_span.top_left.x < patch_span.bottom_right.x) : (patch_span.top_left.x += 1) {
        while (patch_span.top_left.y < patch_span.bottom_right.y) : (patch_span.top_left.y += 1) {
            const patch_coord = PatchCoord{ .x = patch_span.top_left.x, .y = patch_span.top_left.y };
            if (quad_tree.patch_map.get(patch_coord)) |node| {
                const patch_rect = getPatchRect(patch_coord);
                const patch_intersect = patch_rect.intersect(rect).translate(.{ .x = -patch_rect.x, .y = -patch_rect.y });
                try node.findObjectsInRect(patch_intersect, &result, allocator);
            }
        }
    }

    return result.toOwnedSlice(allocator);
}

/// Given a rectangle, returns a span of all patches that the rectangle intersects.
fn rectToPatchSpan(rect: ZssRect) PatchSpan {
    assert(rect.w >= 0);
    assert(rect.h >= 0);
    const roundUp = zss.util.roundUp;
    return PatchSpan{
        .top_left = .{
            .x = @divFloor(rect.x, top_level_size),
            .y = @divFloor(rect.y, top_level_size),
        },
        .bottom_right = .{
            .x = @divFloor(roundUp(rect.x + rect.w, top_level_size), top_level_size),
            .y = @divFloor(roundUp(rect.y + rect.h, top_level_size), top_level_size),
        },
    };
}

/// Returns the region of space associated with a patch.
fn getPatchRect(patch_coord: PatchCoord) ZssRect {
    return .{
        .x = patch_coord.x * top_level_size,
        .y = patch_coord.y * top_level_size,
        .w = top_level_size,
        .h = top_level_size,
    };
}
