const QuadTree = @This();

const zss = @import("../../zss.zig");
const ZssUnit = zss.used_values.ZssUnit;
const ZssRect = zss.used_values.ZssRect;
const ZssVector = zss.used_values.ZssVector;
const BlockBox = zss.used_values.BlockBox;
const BlockBoxIndex = zss.used_values.BlockBoxIndex;
const SubtreeIndex = zss.used_values.SubtreeIndex;
const BlockSubtree = zss.used_values.BlockSubtree;
const InlineFormattingContextIndex = zss.used_values.InlineFormattingContextIndex;
const BoxTree = zss.used_values.BoxTree;

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

const top_level_size: ZssUnit = 1024 * zss.used_values.units_per_pixel;
const large_object_size = top_level_size;

const PatchCoord = struct {
    x: i32,
    y: i32,
};

const PatchSpan = struct {
    top_left: PatchCoord,
    bottom_right: PatchCoord,

    fn intersects(a: PatchSpan, b: PatchSpan) bool {
        const left = std.math.max(a.top_left.x, b.top_left.x);
        const right = std.math.min(a.bottom_right.x, b.bottom_right.x);
        const top = std.math.max(a.top_left.y, b.top_left.y);
        const bottom = std.math.min(a.bottom_right.y, b.bottom_right.y);
        return right >= left and bottom >= top;
    }
};

pub const Object = union(enum) {
    block_box: BlockBox,
    line_box: LineBox,

    const LineBox = struct {
        ifc_index: InlineFormattingContextIndex,
        line_box_index: usize,
    };

    pub fn format(object: Object, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;

        switch (object) {
            .block_box => |block_box| try writer.print("BlockBox subtree={} index={}", .{ block_box.subtree, block_box.index }),
            .line_box => |line_box| try writer.print("LineBox ifc={} index={}", .{ line_box.ifc_index, line_box.line_box_index }),
        }
    }
};

pub const LargeObject = struct {
    object: Object,
    patch_span: PatchSpan,
};

pub const Node = struct {
    depth: u3 = 0,
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
        if (patch_intersect.w > quadrant_size or patch_intersect.h > quadrant_size or node.depth == 7) {
            try node.objects.append(allocator, object);
            return;
        } else {
            const quadrant_rects = [4]ZssRect{
                ZssRect{ .x = 0, .y = 0, .w = quadrant_size, .h = quadrant_size },
                ZssRect{ .x = quadrant_size, .y = 0, .w = quadrant_size, .h = quadrant_size },
                ZssRect{ .x = 0, .y = quadrant_size, .w = quadrant_size, .h = quadrant_size },
                ZssRect{ .x = quadrant_size, .y = quadrant_size, .w = quadrant_size, .h = quadrant_size },
            };

            var quadrant_index: u2 = undefined;
            var quadrant_intersect: ZssRect = undefined;
            var num_intersects: u3 = 0;
            for (quadrant_rects) |rect, i| {
                const intersection = rect.intersect(patch_intersect);
                if (!intersection.isEmpty()) {
                    num_intersects += 1;
                    quadrant_index = @intCast(u2, i);
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
    }

    fn intersect(node: *const Node, patch_intersect: ZssRect, list: *ArrayListUnmanaged(Object), allocator: Allocator) error{OutOfMemory}!void {
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

        for (quadrant_rects) |rect, i| {
            const child = node.children[i] orelse continue;
            const intersection = rect.intersect(patch_intersect);
            if (intersection.isEmpty()) continue;
            try child.intersect(.{
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
        for (node.children) |child, i| {
            if (child) |child_node| {
                const quadrant_string = switch (@intCast(u2, i)) {
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

patch_map: std.AutoHashMapUnmanaged(PatchCoord, *Node) = .{},
large_objects: ArrayListUnmanaged(LargeObject) = .{},

pub fn create(box_tree: BoxTree, allocator: Allocator) !QuadTree {
    var result = QuadTree{};
    errdefer result.deinit(allocator);

    assert(box_tree.blocks.subtrees.items.len > 0);
    const root_subtree = &box_tree.blocks.subtrees.items[0];
    assert(root_subtree.skip.items.len > 0);

    var subtree_stack = ArrayListUnmanaged(struct { subtree_index: SubtreeIndex, subtree: *const BlockSubtree, index_of_root: usize }){};
    defer subtree_stack.deinit(allocator);

    var block_stack = ArrayListUnmanaged(struct { interval: struct { begin: BlockBoxIndex, end: BlockBoxIndex }, vector: ZssVector }){};
    defer block_stack.deinit(allocator);

    try subtree_stack.append(allocator, .{ .subtree_index = 0, .subtree = root_subtree, .index_of_root = 0 });

    const root_insets = root_subtree.insets.items[0];
    try block_stack.append(allocator, .{ .interval = .{ .begin = 0, .end = root_subtree.skip.items[0] }, .vector = root_insets });

    outerLoop: while (block_stack.items.len > 0) {
        const subtree_item = subtree_stack.items[subtree_stack.items.len - 1];
        const subtree_index = subtree_item.subtree_index;
        const subtree = subtree_item.subtree;

        const block_item = &block_stack.items[block_stack.items.len - 1];
        while (block_item.interval.begin != block_item.interval.end) {
            const block_index = block_item.interval.begin;
            const block_skip = subtree.skip.items[block_index];
            block_item.interval.begin += block_skip;

            const block_type = subtree.type.items[block_index];
            switch (block_type) {
                .block => {
                    const box_offsets = subtree.box_offsets.items[block_index];
                    const insets = subtree.insets.items[block_index];
                    const bounding_box = ZssRect{
                        .x = block_item.vector.x + insets.x + box_offsets.border_pos.x,
                        .y = block_item.vector.y + insets.y + box_offsets.border_pos.y,
                        .w = box_offsets.border_size.w,
                        .h = box_offsets.border_size.h,
                    };

                    const object = Object{ .block_box = .{ .subtree = subtree_index, .index = block_index } };
                    try addObject(&result, allocator, bounding_box, object);

                    if (block_skip != 1) {
                        try block_stack.append(allocator, .{
                            .interval = .{ .begin = block_index + 1, .end = block_index + block_skip },
                            .vector = .{ .x = bounding_box.x + box_offsets.content_pos.x, .y = bounding_box.y + box_offsets.content_pos.y },
                        });
                        continue :outerLoop;
                    }
                },
                .subtree_proxy => |child_subtree_index| {
                    const child_subtree = &box_tree.blocks.subtrees.items[child_subtree_index];
                    try subtree_stack.append(allocator, .{ .subtree_index = child_subtree_index, .subtree = child_subtree, .index_of_root = block_stack.items.len });
                    try block_stack.append(allocator, .{ .interval = .{ .begin = 0, .end = child_subtree.skip.items[0] }, .vector = block_item.vector });
                    continue :outerLoop;
                },
            }
        } else {
            _ = block_stack.pop();
            if (subtree_item.index_of_root == block_stack.items.len) {
                _ = subtree_stack.pop();
            }
        }
    }

    return result;
}

fn addObject(quadtree: *QuadTree, allocator: Allocator, bounding_box: ZssRect, object: Object) !void {
    const patch_span = rectToPatchSpan(bounding_box);

    if (patch_span.top_left.x != patch_span.bottom_right.x or patch_span.top_left.y != patch_span.bottom_right.y) {
        try quadtree.large_objects.append(allocator, .{
            .patch_span = patch_span,
            .object = object,
        });
    } else {
        try patchAddObject(quadtree, allocator, patch_span.top_left, bounding_box, object);
    }
}

fn patchAddObject(quadtree: *QuadTree, allocator: Allocator, patch_coord: PatchCoord, bounding_box: ZssRect, object: Object) !void {
    const gop_result = try quadtree.patch_map.getOrPut(allocator, patch_coord);
    if (!gop_result.found_existing) {
        errdefer quadtree.patch_map.removeByPtr(gop_result.key_ptr);
        const node = try allocator.create(Node);
        node.* = .{};
        gop_result.value_ptr.* = node;
    }

    const patch_rect = ZssRect{
        .x = patch_coord.x * top_level_size,
        .y = patch_coord.y * top_level_size,
        .w = top_level_size,
        .h = top_level_size,
    };
    const patch_intersect = patch_rect.intersect(bounding_box).translate(.{ .x = -patch_rect.x, .y = -patch_rect.y });

    const node = gop_result.value_ptr.*;
    try node.insert(allocator, patch_intersect, object);
}

pub fn deinit(quadtree: *QuadTree, allocator: Allocator) void {
    quadtree.large_objects.deinit(allocator);
    var iterator = quadtree.patch_map.iterator();
    while (iterator.next()) |entry| {
        const node = entry.value_ptr.*;
        node.deinit(allocator);
    }
    quadtree.patch_map.deinit(allocator);
}

pub fn print(quadtree: QuadTree, writer: anytype) !void {
    try writer.writeAll("Large objects:\n");
    for (quadtree.large_objects.items) |large_object| {
        try writer.print("\tPatch span ({}, {}) to ({}, {}), {}\n", .{
            large_object.patch_span.top_left.x,
            large_object.patch_span.top_left.y,
            large_object.patch_span.bottom_right.x,
            large_object.patch_span.bottom_right.y,
            large_object.object,
        });
    }
    try writer.writeAll("\n");

    var iterator = quadtree.patch_map.iterator();
    while (iterator.next()) |entry| {
        const patch_coord = entry.key_ptr.*;
        const node = entry.value_ptr.*;
        try writer.print("Patch ({}, {})\n", .{ patch_coord.x, patch_coord.y });
        try node.print(writer);
    }
}

pub fn intersect(quadtree: QuadTree, rect: ZssRect, allocator: Allocator) ![]Object {
    var result = ArrayListUnmanaged(Object){};
    defer result.deinit(allocator);

    var patch_span = rectToPatchSpan(rect);

    for (quadtree.large_objects.items) |large_object| {
        if (patch_span.intersects(large_object.patch_span)) {
            try result.append(allocator, large_object.object);
        }
    }

    while (patch_span.top_left.x <= patch_span.bottom_right.x) : (patch_span.top_left.x += 1) {
        while (patch_span.top_left.y <= patch_span.bottom_right.y) : (patch_span.top_left.y += 1) {
            const patch_coord = PatchCoord{ .x = patch_span.top_left.x, .y = patch_span.top_left.y };
            if (quadtree.patch_map.get(patch_coord)) |node| {
                const patch_rect = getPatchRect(patch_coord);
                const patch_intersect = patch_rect.intersect(rect).translate(.{ .x = -patch_rect.x, .y = -patch_rect.y });
                try node.intersect(patch_intersect, &result, allocator);
            }
            if (patch_span.top_left.y == patch_span.bottom_right.y) break;
        }
        if (patch_span.top_left.x == patch_span.bottom_right.x) break;
    }

    return result.toOwnedSlice(allocator);
}

fn rectToPatchSpan(rect: ZssRect) PatchSpan {
    return PatchSpan{
        .top_left = .{ .x = @divFloor(rect.x, top_level_size), .y = @divFloor(rect.y, top_level_size) },
        .bottom_right = .{ .x = @divFloor(rect.x + rect.w, top_level_size), .y = @divFloor(rect.y + rect.h, top_level_size) },
    };
}

fn getPatchRect(patch_coord: PatchCoord) ZssRect {
    return .{
        .x = patch_coord.x * top_level_size,
        .y = patch_coord.y * top_level_size,
        .w = top_level_size,
        .h = top_level_size,
    };
}
