const std = @import("std");
const assert = std.debug.assert;
const panic = std.debug.panic;
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

const zss = @import("../zss.zig");
const Layout = zss.layout.Layout;
const StyleComputer = @import("./StyleComputer.zig");
const aggregates = zss.properties.aggregates;
const solve = @import("./solve.zig");
const types = zss.values.types;

const used_values = zss.used_values;
const BlockBox = used_values.BlockBox;
const BoxTree = used_values.BoxTree;
const InlineBoxIndex = used_values.InlineBoxIndex;
const InlineFormattingContext = used_values.InlineFormattingContext;
const ZssSize = used_values.ZssSize;
const ZssUnit = used_values.ZssUnit;

const Mode = enum {
    InitialContainingBlock,
    Flow,
    InlineBox,
};

const Context = struct {
    mode: ArrayListUnmanaged(Mode) = .{},
    containing_block_size: ArrayListUnmanaged(ZssSize) = .{},
    allocator: Allocator,

    fn deinit(context: *Context) void {
        context.mode.deinit(context.allocator);
        context.containing_block_size.deinit(context.allocator);
    }
};

pub fn run(layout: *Layout) !void {
    const initial_containing_block = layout.box_tree.blocks.initial_containing_block;
    anonymousBlockBoxCosmeticLayout(layout.box_tree, initial_containing_block);
    // TODO: Also process any anonymous block boxes.

    for (layout.box_tree.ifcs.items) |ifc| {
        rootInlineBoxCosmeticLayout(ifc);
    }

    if (layout.inputs.root_element.eqlNull()) return;
    layout.computer.setRootElement(.cosmetic, layout.inputs.root_element);

    var context = Context{ .allocator = layout.allocator };
    defer context.deinit();

    {
        const initial_containing_block_subtree = layout.box_tree.blocks.subtree(initial_containing_block.subtree);
        const box_offsets = initial_containing_block_subtree.slice().items(.box_offsets)[initial_containing_block.index];
        try context.mode.append(context.allocator, .InitialContainingBlock);
        try context.containing_block_size.append(context.allocator, box_offsets.content_size);
    }

    {
        const root_element = layout.computer.getCurrentElement();
        const box_type = layout.box_tree.element_to_generated_box.get(root_element) orelse return;
        switch (box_type) {
            .block_box => |block_box| {
                try blockBoxCosmeticLayout(layout, context, block_box, .Root);

                // TODO: Temporary jank to set the text color.
                const computed_color = layout.computer.stage.cosmetic.current_values.color;
                const used_color = solve.currentColor(computed_color.color);
                for (layout.box_tree.ifcs.items) |ifc| {
                    ifc.font_color = used_color;
                }

                if (!layout.computer.element_tree_slice.firstChild(root_element).eqlNull()) {
                    const subtree_slice = layout.box_tree.blocks.subtree(block_box.subtree).slice();
                    const box_offsets = subtree_slice.items(.box_offsets)[block_box.index];
                    try context.mode.append(context.allocator, .Flow);
                    try context.containing_block_size.append(context.allocator, box_offsets.content_size);
                    try layout.computer.pushElement(.cosmetic);
                } else {
                    layout.computer.advanceElement(.cosmetic);
                }
            },
            .text => layout.computer.advanceElement(.cosmetic),
            .inline_box => unreachable,
        }
    }

    while (context.mode.items.len > 1) {
        const element = layout.computer.getCurrentElement();
        if (!element.eqlNull()) {
            const box_type = layout.box_tree.element_to_generated_box.get(element) orelse {
                layout.computer.advanceElement(.cosmetic);
                continue;
            };
            const has_children = !layout.computer.element_tree_slice.firstChild(element).eqlNull();
            switch (box_type) {
                .text => layout.computer.advanceElement(.cosmetic),
                .block_box => |block_box| {
                    try blockBoxCosmeticLayout(layout, context, block_box, .NonRoot);

                    if (has_children) {
                        const subtree_slice = layout.box_tree.blocks.subtree(block_box.subtree).slice();
                        const box_offsets = subtree_slice.items(.box_offsets)[block_box.index];
                        try context.mode.append(context.allocator, .Flow);
                        try context.containing_block_size.append(context.allocator, box_offsets.content_size);
                        try layout.computer.pushElement(.cosmetic);
                    } else {
                        layout.computer.advanceElement(.cosmetic);
                    }
                },
                .inline_box => |inline_box| {
                    const ifc = layout.box_tree.ifc(inline_box.ifc_id);
                    inlineBoxCosmeticLayout(layout, context, ifc, inline_box.index);

                    if (has_children) {
                        try context.mode.append(context.allocator, .InlineBox);
                        try layout.computer.pushElement(.cosmetic);
                    } else {
                        layout.computer.advanceElement(.cosmetic);
                    }
                },
            }
        } else {
            const mode = context.mode.pop();
            switch (mode) {
                .InitialContainingBlock => unreachable,
                .Flow => {
                    _ = context.containing_block_size.pop();
                },
                .InlineBox => {},
            }
            layout.computer.popElement(.cosmetic);
        }
    }

    assert(context.mode.pop() == .InitialContainingBlock);
    layout.computer.popElement(.cosmetic);
}

fn blockBoxCosmeticLayout(layout: *Layout, context: Context, block_box: BlockBox, comptime is_root: solve.IsRoot) !void {
    const specified = .{
        .box_style = layout.computer.getSpecifiedValue(.cosmetic, .box_style),
        .color = layout.computer.getSpecifiedValue(.cosmetic, .color),
        .border_colors = layout.computer.getSpecifiedValue(.cosmetic, .border_colors),
        .border_styles = layout.computer.getSpecifiedValue(.cosmetic, .border_styles),
        .background1 = layout.computer.getSpecifiedValue(.cosmetic, .background1),
        .background2 = layout.computer.getSpecifiedValue(.cosmetic, .background2),
        .insets = layout.computer.getSpecifiedValue(.cosmetic, .insets),
    };

    const subtree_slice = layout.box_tree.blocks.subtree(block_box.subtree).slice();

    const computed_box_style, _ = solve.boxStyle(specified.box_style, is_root);
    const current_color = solve.currentColor(specified.color.color);

    var computed_insets: aggregates.Insets = undefined;
    {
        const used_insets = &subtree_slice.items(.insets)[block_box.index];
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

    const box_offsets_ptr = &subtree_slice.items(.box_offsets)[block_box.index];
    const borders_ptr = &subtree_slice.items(.borders)[block_box.index];

    {
        const border_colors_ptr = &subtree_slice.items(.border_colors)[block_box.index];
        border_colors_ptr.* = solve.borderColors(specified.border_colors, current_color);
    }

    solve.borderStyles(specified.border_styles);

    {
        const background_ptr = &subtree_slice.items(.background)[block_box.index];
        try blockBoxBackgrounds(
            layout.box_tree,
            layout.inputs,
            box_offsets_ptr,
            borders_ptr,
            current_color,
            .{ .background1 = &specified.background1, .background2 = &specified.background2 },
            background_ptr,
        );
    }

    layout.computer.setComputedValue(.cosmetic, .box_style, computed_box_style);
    layout.computer.setComputedValue(.cosmetic, .insets, computed_insets);
    // TODO: Pretending that specified values are computed values...
    layout.computer.setComputedValue(.cosmetic, .color, specified.color);
    layout.computer.setComputedValue(.cosmetic, .border_colors, specified.border_colors);
    layout.computer.setComputedValue(.cosmetic, .border_styles, specified.border_styles);
    layout.computer.setComputedValue(.cosmetic, .background1, specified.background1);
    layout.computer.setComputedValue(.cosmetic, .background2, specified.background2);
}

fn solveInsetsStatic(
    specified: aggregates.Insets,
    computed: *aggregates.Insets,
    used: *used_values.Insets,
) void {
    switch (specified.left) {
        .px => |value| computed.left = .{ .px = value },
        .percentage => |value| computed.left = .{ .percentage = value },
        .auto => computed.left = .auto,
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
    switch (specified.right) {
        .px => |value| computed.right = .{ .px = value },
        .percentage => |value| computed.right = .{ .percentage = value },
        .auto => computed.right = .auto,
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
    switch (specified.top) {
        .px => |value| computed.top = .{ .px = value },
        .percentage => |value| computed.top = .{ .percentage = value },
        .auto => computed.top = .auto,
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
    switch (specified.bottom) {
        .px => |value| computed.bottom = .{ .px = value },
        .percentage => |value| computed.bottom = .{ .percentage = value },
        .auto => computed.bottom = .auto,
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
    used.* = .{ .x = 0, .y = 0 };
}

fn solveInsetsRelative(
    specified: aggregates.Insets,
    containing_block_size: ZssSize,
    computed: *aggregates.Insets,
    used: *used_values.Insets,
) void {
    var left: ?ZssUnit = undefined;
    var right: ?ZssUnit = undefined;
    var top: ?ZssUnit = undefined;
    var bottom: ?ZssUnit = undefined;

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
    box_tree: *BoxTree,
    inputs: Layout.Inputs,
    box_offsets: *const used_values.BoxOffsets,
    borders: *const used_values.Borders,
    current_color: used_values.Color,
    specified: struct {
        background1: *const aggregates.Background1,
        background2: *const aggregates.Background2,
    },
    background_ptr: *used_values.BlockBoxBackground,
) !void {
    background_ptr.color = solve.color(specified.background1.color, current_color);

    const images = switch (specified.background2.image) {
        .many => |storage_handle| inputs.storage.get(types.BackgroundImage, storage_handle),
        .image, .url => @as(*const [1]types.BackgroundImage, @ptrCast(&specified.background2.image)),
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

    const handle, const buffer = try box_tree.background_images.alloc(box_tree.allocator, @intCast(images.len));
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

fn anonymousBlockBoxCosmeticLayout(box_tree: *BoxTree, block_box: BlockBox) void {
    const subtree_slice = box_tree.blocks.subtree(block_box.subtree).slice();
    subtree_slice.items(.border_colors)[block_box.index] = .{};
    subtree_slice.items(.background)[block_box.index] = .{};
    subtree_slice.items(.insets)[block_box.index] = .{ .x = 0, .y = 0 };
}

fn inlineBoxCosmeticLayout(
    layout: *Layout,
    context: Context,
    ifc: *InlineFormattingContext,
    inline_box_index: InlineBoxIndex,
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

    const current_color = solve.currentColor(specified.color.color);

    const border_colors = solve.borderColors(specified.border_colors, current_color);
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
        background_ptr.* = solve.inlineBoxBackground(specified.background1.color, background_clip, current_color);
    }

    layout.computer.setComputedValue(.cosmetic, .box_style, computed_box_style);
    layout.computer.setComputedValue(.cosmetic, .insets, computed_insets);
    // TODO: Pretending that specified values are computed values...
    layout.computer.setComputedValue(.cosmetic, .color, specified.color);
    layout.computer.setComputedValue(.cosmetic, .border_colors, specified.border_colors);
    layout.computer.setComputedValue(.cosmetic, .border_styles, specified.border_styles);
    layout.computer.setComputedValue(.cosmetic, .background1, specified.background1);
    layout.computer.setComputedValue(.cosmetic, .background2, specified.background2);
}

fn rootInlineBoxCosmeticLayout(ifc: *InlineFormattingContext) void {
    const ifc_slice = ifc.slice();

    ifc_slice.items(.inline_start)[0].border_color = used_values.Color.transparent;
    ifc_slice.items(.inline_end)[0].border_color = used_values.Color.transparent;
    ifc_slice.items(.block_start)[0].border_color = used_values.Color.transparent;
    ifc_slice.items(.block_end)[0].border_color = used_values.Color.transparent;

    ifc_slice.items(.background)[0] = .{};
    ifc_slice.items(.insets)[0] = .{ .x = 0, .y = 0 };
}
