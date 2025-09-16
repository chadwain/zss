const std = @import("std");
const assert = std.debug.assert;
const panic = std.debug.panic;
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

const zss = @import("../zss.zig");
const solve = @import("./solve.zig");
const types = zss.values.types;
const Layout = zss.Layout;
const StyleComputer = Layout.StyleComputer;

const Color = zss.math.Color;
const Size = zss.math.Size;
const Unit = zss.math.Unit;

const groups = zss.values.groups;
const ComputedValues = groups.Tag.ComputedValues;
const SpecifiedValues = groups.Tag.SpecifiedValues;

const BoxTree = zss.BoxTree;
const BlockRef = BoxTree.BlockRef;
const Ifc = BoxTree.InlineFormattingContext;

const Mode = enum {
    InitialContainingBlock,
    Flow,
    InlineBox,
};

const Context = struct {
    mode: ArrayListUnmanaged(Mode) = .{},
    containing_block_size: ArrayListUnmanaged(Size) = .{},
    allocator: Allocator,

    fn deinit(context: *Context) void {
        context.mode.deinit(context.allocator);
        context.containing_block_size.deinit(context.allocator);
    }
};

pub fn run(layout: *Layout) !void {
    const initial_containing_block = layout.box_tree.ptr.initial_containing_block;
    anonymousBlockBoxCosmeticLayout(layout.box_tree, initial_containing_block);
    // TODO: Also process any anonymous block boxes.

    for (layout.box_tree.ptr.ifcs.items) |ifc| {
        rootInlineBoxCosmeticLayout(ifc);
    }

    const root_node = layout.inputs.env.root_node orelse return;
    try layout.computer.setCurrentNode(.cosmetic, root_node);

    var context = Context{ .allocator = layout.allocator };
    defer context.deinit();

    {
        const initial_containing_block_subtree = layout.box_tree.ptr.getSubtree(initial_containing_block.subtree);
        const box_offsets = initial_containing_block_subtree.view().items(.box_offsets)[initial_containing_block.index];
        try context.mode.append(context.allocator, .InitialContainingBlock);
        try context.containing_block_size.append(context.allocator, box_offsets.content_size);
    }

    {
        const box_type = layout.box_tree.ptr.node_to_generated_box.get(root_node) orelse return;
        switch (box_type) {
            .block_ref => |ref| {
                try blockBoxCosmeticLayout(layout, context, ref, .Root);
                layout.computer.commitNode(.cosmetic);

                if (root_node.firstChild(layout.inputs.env)) |_| {
                    const subtree = layout.box_tree.ptr.getSubtree(ref.subtree).view();
                    const box_offsets = subtree.items(.box_offsets)[ref.index];
                    try context.mode.append(context.allocator, .Flow);
                    try context.containing_block_size.append(context.allocator, box_offsets.content_size);
                    try layout.pushNode();
                } else {
                    layout.advanceNode();
                }
            },
            .text => layout.advanceNode(),
            .inline_box => unreachable,
        }
    }

    while (context.mode.items.len > 1) {
        if (layout.currentNode()) |node| {
            try layout.computer.setCurrentNode(.cosmetic, node);
            const box_type = layout.box_tree.ptr.node_to_generated_box.get(node) orelse {
                layout.advanceNode();
                continue;
            };
            switch (box_type) {
                .text => layout.advanceNode(),
                .block_ref => |ref| {
                    try blockBoxCosmeticLayout(layout, context, ref, .NonRoot);
                    layout.computer.commitNode(.cosmetic);

                    const has_children = node.firstChild(layout.inputs.env) != null;
                    if (has_children) {
                        const subtree = layout.box_tree.ptr.getSubtree(ref.subtree).view();
                        const box_offsets = subtree.items(.box_offsets)[ref.index];
                        try context.mode.append(context.allocator, .Flow);
                        try context.containing_block_size.append(context.allocator, box_offsets.content_size);
                        try layout.pushNode();
                    } else {
                        layout.advanceNode();
                    }
                },
                .inline_box => |inline_box| {
                    const ifc = layout.box_tree.ptr.getIfc(inline_box.ifc_id);
                    inlineBoxCosmeticLayout(layout, context, ifc, inline_box.index);
                    layout.computer.commitNode(.cosmetic);

                    const has_children = node.firstChild(layout.inputs.env) != null;
                    if (has_children) {
                        try context.mode.append(context.allocator, .InlineBox);
                        try layout.pushNode();
                    } else {
                        layout.advanceNode();
                    }
                },
            }
        } else {
            const mode = context.mode.pop().?;
            switch (mode) {
                .InitialContainingBlock => unreachable,
                .Flow => {
                    _ = context.containing_block_size.pop();
                },
                .InlineBox => {},
            }
            layout.popNode();
        }
    }

    assert(context.mode.pop() == .InitialContainingBlock);
    layout.popNode();
}

fn blockBoxCosmeticLayout(layout: *Layout, context: Context, ref: BlockRef, comptime is_root: Layout.IsRoot) !void {
    const specified = .{
        .box_style = layout.computer.getSpecifiedValue(.cosmetic, .box_style),
        .color = layout.computer.getSpecifiedValue(.cosmetic, .color),
        .border_colors = layout.computer.getSpecifiedValue(.cosmetic, .border_colors),
        .border_styles = layout.computer.getSpecifiedValue(.cosmetic, .border_styles),
        .background_color = layout.computer.getSpecifiedValue(.cosmetic, .background_color),
        .background_clip = layout.computer.getSpecifiedValue(.cosmetic, .background_clip),
        .background = layout.computer.getSpecifiedValue(.cosmetic, .background),
        .insets = layout.computer.getSpecifiedValue(.cosmetic, .insets),
    };

    const subtree = layout.box_tree.ptr.getSubtree(ref.subtree).view();

    const computed_box_style, _ = solve.boxStyle(specified.box_style, is_root);
    const computed_color, const used_color = solve.colorProperty(specified.color);

    // TODO: Temporary jank to set the text color for IFCs.
    if (is_root == .Root) {
        for (layout.box_tree.ptr.ifcs.items) |ifc| {
            ifc.font_color = used_color;
        }
    }

    var computed_insets: ComputedValues(.insets) = undefined;
    {
        const used_insets = &subtree.items(.insets)[ref.index];
        switch (computed_box_style.position) {
            .static => solveInsetsStatic(specified.insets, &computed_insets, used_insets),
            .relative => {
                const containing_block_size = context.containing_block_size.items[context.containing_block_size.items.len - 1];
                solveInsetsRelative(specified.insets, containing_block_size, &computed_insets, used_insets);
            },
            else => panic("TODO: Block insets with {s} positioning", .{@tagName(computed_box_style.position)}),
        }
    }

    const box_offsets_ptr = &subtree.items(.box_offsets)[ref.index];
    const borders_ptr = &subtree.items(.borders)[ref.index];

    {
        const border_colors_ptr = &subtree.items(.border_colors)[ref.index];
        border_colors_ptr.* = solve.borderColors(specified.border_colors, used_color);
    }

    solve.borderStyles(specified.border_styles);

    {
        const background_ptr = &subtree.items(.background)[ref.index];
        try blockBoxBackgrounds(
            layout.box_tree,
            layout.inputs,
            box_offsets_ptr,
            borders_ptr,
            used_color,
            .{
                .background_color = &specified.background_color,
                .background_clip = &specified.background_clip,
                .background = &specified.background,
            },
            background_ptr,
        );
    }

    layout.computer.setComputedValue(.cosmetic, .box_style, computed_box_style);
    layout.computer.setComputedValue(.cosmetic, .insets, computed_insets);
    layout.computer.setComputedValue(.cosmetic, .color, computed_color);
    // TODO: Pretending that specified values are computed values...
    layout.computer.setComputedValue(.cosmetic, .border_colors, specified.border_colors);
    layout.computer.setComputedValue(.cosmetic, .border_styles, specified.border_styles);
    layout.computer.setComputedValue(.cosmetic, .background_color, specified.background_color);
    layout.computer.setComputedValue(.cosmetic, .background_clip, specified.background_clip);
    layout.computer.setComputedValue(.cosmetic, .background, specified.background);
}

fn solveInsetsStatic(
    specified: SpecifiedValues(.insets),
    computed: *ComputedValues(.insets),
    used: *BoxTree.Insets,
) void {
    computed.* = .{
        .left = switch (specified.left) {
            .px => |value| .{ .px = value },
            .percentage => |value| .{ .percentage = value },
            .auto => .auto,
        },
        .right = switch (specified.right) {
            .px => |value| .{ .px = value },
            .percentage => |value| .{ .percentage = value },
            .auto => .auto,
        },
        .top = switch (specified.top) {
            .px => |value| .{ .px = value },
            .percentage => |value| .{ .percentage = value },
            .auto => .auto,
        },
        .bottom = switch (specified.bottom) {
            .px => |value| .{ .px = value },
            .percentage => |value| .{ .percentage = value },
            .auto => .auto,
        },
    };
    used.* = .{ .x = 0, .y = 0 };
}

fn solveInsetsRelative(
    specified: SpecifiedValues(.insets),
    containing_block_size: Size,
    computed: *ComputedValues(.insets),
    used: *BoxTree.Insets,
) void {
    var left: ?Unit = undefined;
    var right: ?Unit = undefined;
    var top: ?Unit = undefined;
    var bottom: ?Unit = undefined;

    switch (specified.left) {
        .px => |value| {
            computed.left = .{ .px = value };
            left = solve.length(.px, value);
        },
        .percentage => |value| {
            computed.left = .{ .percentage = value };
            left = solve.percentage(value, containing_block_size.w);
        },
        .auto => {
            computed.left = .auto;
            left = null;
        },
    }
    switch (specified.right) {
        .px => |value| {
            computed.right = .{ .px = value };
            right = -solve.length(.px, value);
        },
        .percentage => |value| {
            computed.right = .{ .percentage = value };
            right = -solve.percentage(value, containing_block_size.w);
        },
        .auto => {
            computed.right = .auto;
            right = null;
        },
    }
    switch (specified.top) {
        .px => |value| {
            computed.top = .{ .px = value };
            top = solve.length(.px, value);
        },
        .percentage => |value| {
            computed.top = .{ .percentage = value };
            top = solve.percentage(value, containing_block_size.h);
        },
        .auto => {
            computed.top = .auto;
            top = null;
        },
    }
    switch (specified.bottom) {
        .px => |value| {
            computed.bottom = .{ .px = value };
            bottom = -solve.length(.px, value);
        },
        .percentage => |value| {
            computed.bottom = .{ .percentage = value };
            bottom = -solve.percentage(value, containing_block_size.h);
        },
        .auto => {
            computed.bottom = .auto;
            bottom = null;
        },
    }

    used.* = .{
        // TODO: This depends on the writing mode of the containing block
        .x = left orelse right orelse 0,
        // TODO: This depends on the writing mode of the containing block
        .y = top orelse bottom orelse 0,
    };
}

fn blockBoxBackgrounds(
    box_tree: Layout.BoxTreeManaged,
    inputs: Layout.Inputs,
    box_offsets: *const BoxTree.BoxOffsets,
    borders: *const BoxTree.Borders,
    current_color: Color,
    specified: struct {
        background_color: *const SpecifiedValues(.background_color),
        background_clip: *const SpecifiedValues(.background_clip),
        background: *const SpecifiedValues(.background),
    },
    background_ptr: *BoxTree.BlockBoxBackground,
) !void {
    background_ptr.color = solve.color(specified.background_color.color, current_color);

    const images = specified.background.image;
    const clips = specified.background_clip.clip;
    background_ptr.color_clip = solve.backgroundClip(clips[(images.len - 1) % clips.len]);

    const num_images = blk: {
        var result: usize = 0;
        for (images) |image| switch (image) {
            .none => {},
            .image, .url => result += 1,
        };
        break :blk result;
    };
    if (num_images == 0) {
        background_ptr.images = .invalid;
        return;
    }

    const origins = specified.background.origin;
    const positions = specified.background.position;
    const sizes = specified.background.size;
    const repeats = specified.background.repeat;
    const attachments = specified.background.attachment;

    const handle, const buffer = try box_tree.allocBackgroundImages(@intCast(num_images));
    var buffer_index: usize = 0;
    for (images, 0..) |image, index| {
        if (image == .none) continue;
        defer buffer_index += 1;

        const image_handle = switch (image) {
            .image => |image_handle| image_handle,
            .url => |url| inputs.env.urls_to_images.get(url) orelse {
                buffer[buffer_index] = .{};
                continue;
            },
            .none => unreachable,
        };

        const dimensions = inputs.images.dimensions(image_handle);
        buffer[buffer_index] = solve.backgroundImage(
            image_handle,
            dimensions,
            .{
                .origin = origins[index % origins.len],
                .position = positions[index % positions.len],
                .size = sizes[index % sizes.len],
                .repeat = repeats[index % repeats.len],
                .attachment = attachments[index % attachments.len],
                .clip = clips[index % clips.len],
            },
            box_offsets,
            borders,
        );
    }
    background_ptr.images = handle;
}

fn anonymousBlockBoxCosmeticLayout(box_tree: Layout.BoxTreeManaged, ref: BlockRef) void {
    const subtree = box_tree.ptr.getSubtree(ref.subtree).view();
    subtree.items(.border_colors)[ref.index] = .{};
    subtree.items(.background)[ref.index] = .{};
    subtree.items(.insets)[ref.index] = .{ .x = 0, .y = 0 };
}

fn inlineBoxCosmeticLayout(
    layout: *Layout,
    context: Context,
    ifc: *Ifc,
    inline_box_index: Ifc.Size,
) void {
    const ifc_slice = ifc.slice();

    const specified = .{
        .box_style = layout.computer.getSpecifiedValue(.cosmetic, .box_style),
        .color = layout.computer.getSpecifiedValue(.cosmetic, .color),
        .border_colors = layout.computer.getSpecifiedValue(.cosmetic, .border_colors),
        .border_styles = layout.computer.getSpecifiedValue(.cosmetic, .border_styles),
        .background_color = layout.computer.getSpecifiedValue(.cosmetic, .background_color),
        .background_clip = layout.computer.getSpecifiedValue(.cosmetic, .background_clip),
        .background = layout.computer.getSpecifiedValue(.cosmetic, .background), // TODO: Inline boxes don't need background
        .insets = layout.computer.getSpecifiedValue(.cosmetic, .insets),
    };

    const computed_box_style, _ = solve.boxStyle(specified.box_style, .NonRoot);

    var computed_insets: ComputedValues(.insets) = undefined;
    {
        const used_insets = &ifc_slice.items(.insets)[inline_box_index];
        switch (computed_box_style.position) {
            .static => solveInsetsStatic(specified.insets, &computed_insets, used_insets),
            .relative => {
                const containing_block_size = context.containing_block_size.items[context.containing_block_size.items.len - 1];
                solveInsetsRelative(specified.insets, containing_block_size, &computed_insets, used_insets);
            },
            .sticky => panic("TODO: Inline insets with {s} positioning", .{@tagName(computed_box_style.position)}),
            .absolute, .fixed => unreachable,
        }
    }

    const computed_color, const used_color = solve.colorProperty(specified.color);

    const border_colors = solve.borderColors(specified.border_colors, used_color);
    ifc_slice.items(.inline_start)[inline_box_index].border_color = border_colors.left;
    ifc_slice.items(.inline_end)[inline_box_index].border_color = border_colors.right;
    ifc_slice.items(.block_start)[inline_box_index].border_color = border_colors.top;
    ifc_slice.items(.block_end)[inline_box_index].border_color = border_colors.bottom;

    solve.borderStyles(specified.border_styles);

    const images = specified.background.image;
    const clips = specified.background_clip.clip;
    const background_clip = clips[(images.len - 1) % clips.len];
    const background_ptr = &ifc_slice.items(.background)[inline_box_index];
    background_ptr.* = solve.inlineBoxBackground(specified.background_color.color, background_clip, used_color);

    layout.computer.setComputedValue(.cosmetic, .box_style, computed_box_style);
    layout.computer.setComputedValue(.cosmetic, .insets, computed_insets);
    layout.computer.setComputedValue(.cosmetic, .color, computed_color);
    // TODO: Pretending that specified values are computed values...
    layout.computer.setComputedValue(.cosmetic, .border_colors, specified.border_colors);
    layout.computer.setComputedValue(.cosmetic, .border_styles, specified.border_styles);
    layout.computer.setComputedValue(.cosmetic, .background_color, specified.background_color);
    layout.computer.setComputedValue(.cosmetic, .background_clip, specified.background_clip);
    layout.computer.setComputedValue(.cosmetic, .background, specified.background);
}

fn rootInlineBoxCosmeticLayout(ifc: *Ifc) void {
    const ifc_slice = ifc.slice();

    ifc_slice.items(.inline_start)[0].border_color = .transparent;
    ifc_slice.items(.inline_end)[0].border_color = .transparent;
    ifc_slice.items(.block_start)[0].border_color = .transparent;
    ifc_slice.items(.block_end)[0].border_color = .transparent;

    ifc_slice.items(.background)[0] = .{};
    ifc_slice.items(.insets)[0] = .{ .x = 0, .y = 0 };
}
