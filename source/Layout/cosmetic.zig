const std = @import("std");
const assert = std.debug.assert;
const panic = std.debug.panic;
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

const zss = @import("../zss.zig");
const aggregates = zss.property.aggregates;
const solve = @import("./solve.zig");
const types = zss.values.types;
const Layout = zss.Layout;
const StyleComputer = @import("./StyleComputer.zig");

const Color = zss.math.Color;
const Size = zss.math.Size;
const Unit = zss.math.Unit;

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

    const root_element = layout.inputs.root_element;
    if (root_element.eqlNull()) return;
    try layout.computer.setCurrentElement(.cosmetic, root_element);

    var context = Context{ .allocator = layout.allocator };
    defer context.deinit();

    {
        const initial_containing_block_subtree = layout.box_tree.ptr.getSubtree(initial_containing_block.subtree);
        const box_offsets = initial_containing_block_subtree.view().items(.box_offsets)[initial_containing_block.index];
        try context.mode.append(context.allocator, .InitialContainingBlock);
        try context.containing_block_size.append(context.allocator, box_offsets.content_size);
    }

    {
        const box_type = layout.box_tree.ptr.element_to_generated_box.get(root_element) orelse return;
        switch (box_type) {
            .block_ref => |ref| {
                try blockBoxCosmeticLayout(layout, context, ref, .Root);
                layout.computer.commitElement(.cosmetic);

                if (!layout.computer.element_tree_slice.firstChild(root_element).eqlNull()) {
                    const subtree = layout.box_tree.ptr.getSubtree(ref.subtree).view();
                    const box_offsets = subtree.items(.box_offsets)[ref.index];
                    try context.mode.append(context.allocator, .Flow);
                    try context.containing_block_size.append(context.allocator, box_offsets.content_size);
                    try layout.pushElement();
                } else {
                    layout.advanceElement();
                }
            },
            .text => layout.advanceElement(),
            .inline_box => unreachable,
        }
    }

    while (context.mode.items.len > 1) {
        const element = layout.currentElement();
        if (!element.eqlNull()) {
            try layout.computer.setCurrentElement(.cosmetic, element);
            const box_type = layout.box_tree.ptr.element_to_generated_box.get(element) orelse {
                layout.advanceElement();
                continue;
            };
            const has_children = !layout.computer.element_tree_slice.firstChild(element).eqlNull();
            switch (box_type) {
                .text => layout.advanceElement(),
                .block_ref => |ref| {
                    try blockBoxCosmeticLayout(layout, context, ref, .NonRoot);
                    layout.computer.commitElement(.cosmetic);

                    if (has_children) {
                        const subtree = layout.box_tree.ptr.getSubtree(ref.subtree).view();
                        const box_offsets = subtree.items(.box_offsets)[ref.index];
                        try context.mode.append(context.allocator, .Flow);
                        try context.containing_block_size.append(context.allocator, box_offsets.content_size);
                        try layout.pushElement();
                    } else {
                        layout.advanceElement();
                    }
                },
                .inline_box => |inline_box| {
                    const ifc = layout.box_tree.ptr.getIfc(inline_box.ifc_id);
                    inlineBoxCosmeticLayout(layout, context, ifc, inline_box.index);
                    layout.computer.commitElement(.cosmetic);

                    if (has_children) {
                        try context.mode.append(context.allocator, .InlineBox);
                        try layout.pushElement();
                    } else {
                        layout.advanceElement();
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
            layout.popElement();
        }
    }

    assert(context.mode.pop() == .InitialContainingBlock);
    layout.popElement();
}

fn blockBoxCosmeticLayout(layout: *Layout, context: Context, ref: BlockRef, comptime is_root: Layout.IsRoot) !void {
    const specified = .{
        .box_style = layout.computer.getSpecifiedValue(.cosmetic, .box_style),
        .color = layout.computer.getSpecifiedValue(.cosmetic, .color),
        .border_colors = layout.computer.getSpecifiedValue(.cosmetic, .border_colors),
        .border_styles = layout.computer.getSpecifiedValue(.cosmetic, .border_styles),
        .background1 = layout.computer.getSpecifiedValue(.cosmetic, .background1),
        .background2 = layout.computer.getSpecifiedValue(.cosmetic, .background2),
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

    var computed_insets: aggregates.Insets = undefined;
    {
        const used_insets = &subtree.items(.insets)[ref.index];
        switch (computed_box_style.position) {
            .static => solveInsetsStatic(specified.insets, &computed_insets, used_insets),
            .relative => {
                const containing_block_size = context.containing_block_size.items[context.containing_block_size.items.len - 1];
                solveInsetsRelative(specified.insets, containing_block_size, &computed_insets, used_insets);
            },
            .initial, .inherit, .unset, .undeclared => unreachable,
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
            .{ .background1 = &specified.background1, .background2 = &specified.background2 },
            background_ptr,
        );
    }

    layout.computer.setComputedValue(.cosmetic, .box_style, computed_box_style);
    layout.computer.setComputedValue(.cosmetic, .insets, computed_insets);
    layout.computer.setComputedValue(.cosmetic, .color, computed_color);
    // TODO: Pretending that specified values are computed values...
    layout.computer.setComputedValue(.cosmetic, .border_colors, specified.border_colors);
    layout.computer.setComputedValue(.cosmetic, .border_styles, specified.border_styles);
    layout.computer.setComputedValue(.cosmetic, .background1, specified.background1);
    layout.computer.setComputedValue(.cosmetic, .background2, specified.background2);
}

fn solveInsetsStatic(
    specified: aggregates.Insets,
    computed: *aggregates.Insets,
    used: *BoxTree.Insets,
) void {
    computed.* = .{
        .left = switch (specified.left) {
            .px => |value| .{ .px = value },
            .percentage => |value| .{ .percentage = value },
            .auto => .auto,
            .initial, .inherit, .unset, .undeclared => unreachable,
        },
        .right = switch (specified.right) {
            .px => |value| .{ .px = value },
            .percentage => |value| .{ .percentage = value },
            .auto => .auto,
            .initial, .inherit, .unset, .undeclared => unreachable,
        },
        .top = switch (specified.top) {
            .px => |value| .{ .px = value },
            .percentage => |value| .{ .percentage = value },
            .auto => .auto,
            .initial, .inherit, .unset, .undeclared => unreachable,
        },
        .bottom = switch (specified.bottom) {
            .px => |value| .{ .px = value },
            .percentage => |value| .{ .percentage = value },
            .auto => .auto,
            .initial, .inherit, .unset, .undeclared => unreachable,
        },
    };
    used.* = .{ .x = 0, .y = 0 };
}

fn solveInsetsRelative(
    specified: aggregates.Insets,
    containing_block_size: Size,
    computed: *aggregates.Insets,
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
        .initial, .inherit, .unset, .undeclared => unreachable,
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
        .initial, .inherit, .unset, .undeclared => unreachable,
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
        .initial, .inherit, .unset, .undeclared => unreachable,
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
        .initial, .inherit, .unset, .undeclared => unreachable,
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
        background1: *const aggregates.Background1,
        background2: *const aggregates.Background2,
    },
    background_ptr: *BoxTree.BlockBoxBackground,
) !void {
    background_ptr.color = solve.color(specified.background1.color, current_color);

    const images: []const types.BackgroundImage = switch (specified.background2.image) {
        .many => |storage_handle| inputs.storage.get(types.BackgroundImage, storage_handle),
        .image, .url => (&specified.background2.image)[0..1],
        .none => {
            background_ptr.images = .invalid;
            background_ptr.color_clip = comptime solve.backgroundClip(aggregates.Background1.initial_values.clip);
            return;
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    };
    const clips = getBackgroundPropertyArray(inputs, &specified.background1.clip);
    background_ptr.color_clip = solve.backgroundClip(clips[(images.len - 1) % clips.len]);

    const origins = getBackgroundPropertyArray(inputs, &specified.background2.origin);
    const positions = getBackgroundPropertyArray(inputs, &specified.background2.position);
    const sizes = getBackgroundPropertyArray(inputs, &specified.background2.size);
    const repeats = getBackgroundPropertyArray(inputs, &specified.background2.repeat);

    const handle, const buffer = try box_tree.allocBackgroundImages(@intCast(images.len));
    for (images, buffer, 0..) |image, *dest, index| {
        const image_handle = switch (image) {
            .image => |image_handle| image_handle,
            .url => std.debug.panic("TODO: background-image URLs", .{}),
            .none => {
                dest.* = .{};
                continue;
            },
            .many => unreachable,
            .initial, .inherit, .unset, .undeclared => unreachable,
        };
        const dimensions = inputs.images.items(.dimensions)[@intFromEnum(image_handle)];
        dest.* = solve.backgroundImage(
            image_handle,
            dimensions,
            .{
                .origin = origins[index % origins.len],
                .position = positions[index % positions.len],
                .size = sizes[index % sizes.len],
                .repeat = repeats[index % repeats.len],
                .clip = clips[index % clips.len],
            },
            box_offsets,
            borders,
        );
    }
    background_ptr.images = handle;
}

fn getBackgroundPropertyArray(inputs: Layout.Inputs, ptr_to_value: anytype) []const std.meta.Child(@TypeOf(ptr_to_value)) {
    const T = std.meta.Child(@TypeOf(ptr_to_value));
    switch (ptr_to_value.*) {
        .many => |storage_handle| return inputs.storage.get(T, storage_handle),
        .initial, .inherit, .unset, .undeclared => unreachable,
        else => return @as(*const [1]T, @ptrCast(ptr_to_value)),
    }
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
        .background1 = layout.computer.getSpecifiedValue(.cosmetic, .background1),
        .background2 = layout.computer.getSpecifiedValue(.cosmetic, .background2), // TODO: Inline boxes don't need background2
        .insets = layout.computer.getSpecifiedValue(.cosmetic, .insets),
    };

    const computed_box_style, _ = solve.boxStyle(specified.box_style, .NonRoot);

    var computed_insets: aggregates.Insets = undefined;
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
            .initial, .inherit, .unset, .undeclared => unreachable,
        }
    }

    const computed_color, const used_color = solve.colorProperty(specified.color);

    const border_colors = solve.borderColors(specified.border_colors, used_color);
    ifc_slice.items(.inline_start)[inline_box_index].border_color = border_colors.left;
    ifc_slice.items(.inline_end)[inline_box_index].border_color = border_colors.right;
    ifc_slice.items(.block_start)[inline_box_index].border_color = border_colors.top;
    ifc_slice.items(.block_end)[inline_box_index].border_color = border_colors.bottom;

    solve.borderStyles(specified.border_styles);

    {
        const background_clip = switch (specified.background1.clip) {
            .many => |storage_handle| blk: {
                const array = layout.inputs.storage.get(zss.values.types.BackgroundClip, storage_handle);
                // CSS-BACKGROUNDS-3§2.2:
                // The background color is clipped according to the background-clip value associated with the bottom-most background image layer.
                break :blk array[array.len - 1];
            },
            else => |tag| tag,
        };
        const background_ptr = &ifc_slice.items(.background)[inline_box_index];
        background_ptr.* = solve.inlineBoxBackground(specified.background1.color, background_clip, used_color);
    }

    layout.computer.setComputedValue(.cosmetic, .box_style, computed_box_style);
    layout.computer.setComputedValue(.cosmetic, .insets, computed_insets);
    layout.computer.setComputedValue(.cosmetic, .color, computed_color);
    // TODO: Pretending that specified values are computed values...
    layout.computer.setComputedValue(.cosmetic, .border_colors, specified.border_colors);
    layout.computer.setComputedValue(.cosmetic, .border_styles, specified.border_styles);
    layout.computer.setComputedValue(.cosmetic, .background1, specified.background1);
    layout.computer.setComputedValue(.cosmetic, .background2, specified.background2);
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
