const DrawOrderList = @This();

const zss = @import("../../zss.zig");
const used_values = zss.used_values;
const BlockBoxIndex = used_values.BlockBoxIndex;
const BlockBox = used_values.BlockBox;
const BlockSubtree = used_values.BlockSubtree;
const InlineFormattingContextIndex = used_values.InlineFormattingContextIndex;
const StackingContextIndex = used_values.StackingContextIndex;
const StackingContextTree = used_values.StackingContextTree;
const BoxTree = used_values.BoxTree;

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

pub const Item = union(enum) {
    block_box: BlockBox,
    ifc: InlineFormattingContextIndex,
    stacking_context: StackingContext,

    const StackingContext = struct { sc_index: StackingContextIndex, sub_list: DrawOrderList };
};

items: ArrayListUnmanaged(Item) = .{},

pub fn create(box_tree: BoxTree, allocator: Allocator) !DrawOrderList {
    var result = DrawOrderList{};
    errdefer result.deinit(allocator);

    // Add the initial containing block to the list.
    assert(box_tree.blocks.subtrees.items.len > 0);
    assert(box_tree.blocks.subtrees.items[0].skip.items.len > 0);
    const initial_containing_block = BlockBox{ .subtree = 0, .index = 0 };
    try result.items.append(allocator, Item{ .block_box = initial_containing_block });

    const slice = box_tree.stacking_contexts.list.slice();
    if (slice.len > 0) {
        var stacking_context = try createStackingContextList(box_tree, allocator, slice, 0);
        errdefer stacking_context.sub_list.deinit(allocator);
        try result.items.append(allocator, Item{ .stacking_context = stacking_context });
    }

    return result;
}

fn createStackingContextList(
    box_tree: BoxTree,
    allocator: Allocator,
    slice: StackingContextTree.List.Slice,
    sc_index: StackingContextIndex,
) error{OutOfMemory}!Item.StackingContext {
    var result = DrawOrderList{};
    errdefer result.deinit(allocator);

    const sc_root_block = slice.items(.block_box)[sc_index];
    const sc_root_block_subtree = &box_tree.blocks.subtrees.items[sc_root_block.subtree];
    try result.items.append(allocator, Item{ .block_box = sc_root_block });

    // Add lower stacking contexts
    var i = sc_index + 1;
    const end = sc_index + slice.items(.__skip)[sc_index];
    while (i < end and slice.items(.z_index)[i] < 0) : (i += slice.items(.__skip)[i]) {
        var stacking_context = try createStackingContextList(box_tree, allocator, slice, i);
        errdefer stacking_context.sub_list.deinit(allocator);
        try result.items.append(allocator, Item{ .stacking_context = stacking_context });
    }

    var stack = ArrayListUnmanaged(struct { begin: BlockBoxIndex, end: BlockBoxIndex, subtree: *const BlockSubtree }){};
    defer stack.deinit(allocator);
    try stack.append(allocator, .{
        .begin = sc_root_block.index + 1,
        .end = sc_root_block.index + sc_root_block_subtree.skip.items[sc_root_block.index],
        .subtree = sc_root_block_subtree,
    });

    // Add child block boxes
    outerLoop: while (stack.items.len > 0) {
        const last = &stack.items[stack.items.len - 1];
        const subtree = last.subtree;
        while (last.begin < last.end) {
            const block_type = subtree.type.items[last.begin];
            switch (block_type) {
                .block => |block_info| {
                    if (block_info.stacking_context) |_| {
                        last.begin += subtree.skip.items[last.begin];
                    } else {
                        try result.items.append(allocator, Item{ .block_box = .{ .subtree = sc_index, .index = last.begin } });
                        last.begin += 1;
                    }
                },
                .subtree_proxy => |subtree_index| {
                    last.begin += 1;
                    const child_subtree = &box_tree.blocks.subtrees.items[subtree_index];
                    try stack.append(allocator, .{
                        .begin = 0,
                        .end = @intCast(BlockBoxIndex, child_subtree.skip.items.len),
                        .subtree = child_subtree,
                    });
                    continue :outerLoop;
                },
            }
        } else {
            _ = stack.pop();
        }
    }

    // Add inline formatting contexts
    for (slice.items(.ifcs)[sc_index].items) |ifc_index| {
        try result.items.append(allocator, Item{ .ifc = ifc_index });
    }

    // Add higher stacking contexts
    while (i < end) : (i += slice.items(.__skip)[i]) {
        var stacking_context = try createStackingContextList(box_tree, allocator, slice, i);
        errdefer stacking_context.sub_list.deinit(allocator);
        try result.items.append(allocator, Item{ .stacking_context = stacking_context });
    }

    return Item.StackingContext{ .sc_index = sc_index, .sub_list = result };
}

pub fn deinit(list: *DrawOrderList, allocator: Allocator) void {
    for (list.items.items) |*item| {
        switch (item.*) {
            .block_box, .ifc => {},
            .stacking_context => |*stacking_context| stacking_context.sub_list.deinit(allocator),
        }
    }
    list.items.deinit(allocator);
}

pub fn print(list: DrawOrderList, writer: anytype, allocator: Allocator) !void {
    var stack = ArrayListUnmanaged(struct { sub_list: DrawOrderList, index: usize = 0, indent: usize }){};
    defer stack.deinit(allocator);
    try stack.append(allocator, .{ .sub_list = list, .indent = 0 });

    outerLoop: while (stack.items.len > 0) {
        const last = &stack.items[stack.items.len - 1];
        while (last.index < last.sub_list.items.items.len) {
            const index = last.index;
            last.index += 1;
            try writer.writeByteNTimes(' ', last.indent * 4);
            switch (last.sub_list.items.items[index]) {
                .block_box => |block_box| try writer.print("BlockBox subtree={} index={}\n", .{ block_box.subtree, block_box.index }),
                .ifc => |ifc_index| try writer.print("InlineFormattingContext index={}\n", .{ifc_index}),
                .stacking_context => |stacking_context| {
                    try writer.print("StackingContext index={}\n", .{stacking_context.sc_index});
                    try stack.append(allocator, .{ .sub_list = stacking_context.sub_list, .indent = last.indent + 1 });
                    continue :outerLoop;
                },
            }
        } else {
            _ = stack.pop();
        }
    }
}

// pub fn format(list: DrawOrderList, comptime fmt: []const u8, options: std.fmt.FormatOptions, underlying_writer: anytype) IndentedWriter(@TypeOf(underlying_writer)).Error!void {
//     _ = fmt;
//     _ = options;
//
//     var writer = indentedWriter(underlying_writer);
//     for (list.items.items) |item| {
//         switch (item) {
//             .block_box => |block_box| try writer.print("BlockBox subtree={} index={}\n", .{ block_box.subtree, block_box.index }),
//             .ifc => |ifc_index| try writer.print("InlineFormattingContext index={}\n", .{ifc_index}),
//             .stacking_context => |sub_list| {
//                 try writer.writeAll("StackingContext\n");
//                 writer.context.indent += 1;
//                 try writer.print("{}\n", .{sub_list});
//                 writer.context.indent -= 1;
//             },
//         }
//     }
// }
//
// fn IndentedWriter(comptime UnderlyingWriter: type) type {
//     const Context = struct {
//         indent: usize = 0,
//         was_newline: bool = true,
//         writer: UnderlyingWriter,
//
//         fn write(self: *@This(), bytes: []const u8) !usize {
//             for (bytes) |byte| {
//                 if (self.was_newline) {
//                     self.was_newline = false;
//                     try self.writer.writeByteNTimes(' ', self.indent * 4);
//                 }
//                 if (byte == '\n') {
//                     self.was_newline = true;
//                 }
//             }
//             return bytes.len;
//         }
//     };
//
//     return std.io.Writer(*Context, UnderlyingWriter.Error, Context.write);
// }
//
// fn indentedWriter(underlying_writer: anytype) IndentedWriter(@TypeOf(underlying_writer)) {
//     return .{ .writer = underlying_writer };
// }
