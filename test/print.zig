const zss = @import("zss");
const BoxTree = zss.used_values.BoxTree;
const Subtree = zss.used_values.BlockSubtree;
const SubtreeIndex = zss.used_values.SubtreeIndex;
const BlockBoxIndex = zss.used_values.BlockBoxIndex;

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

const Test = @import("./testing.zig").Test;

pub fn run(tests: []const Test) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    const stdout = std.io.getStdOut().writer();

    for (tests, 0..) |t, i| {
        try stdout.print("print: ({}/{}) \"{s}\" ... \n", .{ i + 1, tests.len, t.name });
        defer stdout.writeAll("\n") catch {};

        var box_tree = try zss.layout.doLayout(
            t.slice,
            t.root,
            &t.cascaded_values,
            allocator,
            .{ .width = t.width, .height = t.height },
        );
        defer box_tree.deinit();

        try printBlocks(box_tree, stdout, allocator);
    }
}

fn printBlocks(box_tree: BoxTree, stdout: anytype, allocator: Allocator) !void {
    const SubtreeStackItem = struct {
        index: SubtreeIndex,
        subtree: *const Subtree,
        index_of_root: usize,
    };
    var subtree_stack = ArrayListUnmanaged(SubtreeStackItem){};
    defer subtree_stack.deinit(allocator);

    const BlockStackItem = struct {
        begin: BlockBoxIndex,
        end: BlockBoxIndex,
        indent: usize,
    };
    var block_stack = ArrayListUnmanaged(BlockStackItem){};
    defer block_stack.deinit(allocator);

    const subtrees = box_tree.blocks.subtrees.items;
    try subtree_stack.append(allocator, .{ .index = 0, .subtree = subtrees[0], .index_of_root = 0 });
    try block_stack.append(allocator, .{ .begin = 0, .end = subtrees[0].skip.items[0], .indent = 0 });

    while (block_stack.items.len > 0) {
        const top = &block_stack.items[block_stack.items.len - 1];
        const subtree = subtree_stack.items[subtree_stack.items.len - 1];
        if (top.begin != top.end) {
            const index = top.begin;
            const skip = subtree.subtree.skip.items[index];
            top.begin += skip;

            switch (subtree.subtree.type.items[index]) {
                .subtree_proxy => |subtree_index| {
                    try stdout.writeByteNTimes(' ', top.indent * 4);
                    try stdout.print("subtree index={}\n", .{subtree_index});

                    const new_subtree = subtrees[subtree_index];
                    try subtree_stack.append(allocator, .{ .index = subtree_index, .subtree = new_subtree, .index_of_root = block_stack.items.len });
                    try block_stack.append(allocator, .{ .begin = 0, .end = @intCast(new_subtree.skip.items.len), .indent = top.indent + 1 });
                },
                .block => {
                    const box_offsets = subtree.subtree.box_offsets.items[index];
                    const borders = subtree.subtree.borders.items[index];
                    const margins = subtree.subtree.margins.items[index];
                    const width = box_offsets.content_size.w;
                    const height = box_offsets.content_size.h;
                    const anchor = box_offsets.border_pos;
                    const padding_left = box_offsets.content_pos.x - borders.left;
                    const padding_top = box_offsets.content_pos.y - borders.top;
                    const padding_right = box_offsets.border_size.w - box_offsets.content_pos.x - width - borders.right;
                    const padding_bottom = box_offsets.border_size.h - box_offsets.content_pos.y - height - borders.bottom;

                    try stdout.writeByteNTimes(' ', top.indent * 4);
                    try stdout.print(
                        "block subtree={} index={} skip={} width={} height={} padding={},{},{},{} border={},{},{},{} margin={},{},{},{} anchor={},{}\n",
                        .{
                            subtree.index,
                            index,
                            skip,
                            width,
                            height,
                            padding_top,
                            padding_right,
                            padding_bottom,
                            padding_left,
                            borders.top,
                            borders.right,
                            borders.bottom,
                            borders.left,
                            margins.top,
                            margins.right,
                            margins.bottom,
                            margins.left,
                            anchor.x,
                            anchor.y,
                        },
                    );
                    try block_stack.append(allocator, .{ .begin = index + 1, .end = index + skip, .indent = top.indent + 1 });
                },
                .ifc_container => {
                    const box_offsets = subtree.subtree.box_offsets.items[index];
                    const width = box_offsets.content_size.w;
                    const height = box_offsets.content_size.h;
                    const anchor = box_offsets.border_pos;

                    try stdout.writeByteNTimes(' ', top.indent * 4);
                    try stdout.print(
                        "ifc_container subtree={} index={} skip={} width={} height={} anchor={},{}\n",
                        .{
                            subtree.index,
                            index,
                            skip,
                            width,
                            height,
                            anchor.x,
                            anchor.y,
                        },
                    );
                    try block_stack.append(allocator, .{ .begin = index + 1, .end = index + skip, .indent = top.indent + 1 });
                },
            }
        } else {
            if (subtree.index_of_root == block_stack.items.len) {
                _ = subtree_stack.pop();
            }
            _ = block_stack.pop();
        }
    }
}
