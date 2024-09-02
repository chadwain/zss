const std = @import("std");
const Allocator = std.mem.Allocator;

const zss = @import("../zss.zig");
const BlockBox = zss.used_values.BlockBox;
const Element = zss.ElementTree.Element;
const BoxStyle = zss.used_values.BoxStyle;
const Position = zss.values.types.Position;

const Absolute = @This();

containing_block_tag: std.ArrayListUnmanaged(Tag) = .{},
containing_block_index: std.ArrayListUnmanaged(u32) = .{},
current_containing_block_index: u32 = undefined,

containing_blocks: std.MultiArrayList(ContainingBlock) = .{},
next_containing_block_id: std.meta.Tag(ContainingBlock.Id) = 0,

blocks: std.ArrayListUnmanaged(Block) = .{},

pub fn deinit(absolute: *Absolute, allocator: Allocator) void {
    absolute.containing_block_tag.deinit(allocator);
    absolute.containing_block_index.deinit(allocator);
    absolute.containing_blocks.deinit(allocator);
}

pub const ContainingBlock = struct {
    id: Id,
    block_box: BlockBox,

    pub const Id = enum(u32) { _ };
};

pub const Block = struct {
    containing_block: ContainingBlock.Id,
    element: Element,
    inner_box_style: BoxStyle.InnerBlock,
};

const Tag = enum {
    none,
    exists,
};

pub fn pushContainingBlock(absolute: *Absolute, allocator: Allocator, box_style: BoxStyle, block_box: BlockBox) !?ContainingBlock.Id {
    switch (box_style.position) {
        .static => {
            try absolute.containing_block_tag.append(allocator, .none);
            return null;
        },
        .relative, .absolute => return try absolute.newContainingBlock(allocator, block_box),
    }
}

pub const pushInitialContainingBlock = newContainingBlock;

fn newContainingBlock(absolute: *Absolute, allocator: Allocator, block_box: BlockBox) !ContainingBlock.Id {
    const id: ContainingBlock.Id = @enumFromInt(absolute.next_containing_block_id);
    const index: u32 = @intCast(absolute.containing_blocks.len);
    try absolute.containing_block_tag.append(allocator, .exists);
    try absolute.containing_block_index.append(allocator, index);
    try absolute.containing_blocks.append(allocator, .{ .id = id, .block_box = block_box });
    absolute.current_containing_block_index = index;
    absolute.next_containing_block_id += 1;
    return id;
}

pub fn popContainingBlock(absolute: *Absolute) void {
    const tag = absolute.containing_block_tag.pop();
    if (tag == .none) return;
    _ = absolute.containing_block_index.pop();

    if (absolute.containing_block_tag.items.len > 0) {
        absolute.current_containing_block_index = absolute.containing_block_index.items[absolute.containing_block_index.items.len - 1];
    } else {
        absolute.current_containing_block_index = undefined;
    }
}

pub fn fixupContainingBlock(absolute: *Absolute, id: ContainingBlock.Id, block_box: BlockBox) void {
    const slice = absolute.containing_blocks.slice();
    const index: u32 = @intCast(std.mem.indexOfScalar(ContainingBlock.Id, slice.items(.id), id).?);
    slice.items(.block_box)[index] = block_box;
}

pub fn addBlock(absolute: *Absolute, allocator: Allocator, element: Element, inner_box_style: BoxStyle.InnerBlock) !void {
    const index = absolute.current_containing_block_index;
    const id = absolute.containing_blocks.items[index].id;
    try absolute.blocks.append(allocator, .{ .containing_block = id, .element = element, .inner_box_style = inner_box_style });
}
