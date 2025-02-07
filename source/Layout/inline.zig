const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

const zss = @import("../zss.zig");
const aggregates = zss.property.aggregates;
const BlockComputedSizes = zss.Layout.BlockComputedSizes;
const BlockUsedSizes = zss.Layout.BlockUsedSizes;
const BoxTreeManaged = Layout.BoxTreeManaged;
const ElementTree = zss.ElementTree;
const Element = ElementTree.Element;
const Fonts = zss.Fonts;
const Layout = zss.Layout;
const SctBuilder = Layout.StackingContextTreeBuilder;
const Stack = zss.Stack;
const Unit = zss.math.Unit;
const units_per_pixel = zss.math.units_per_pixel;

const flow = @import("./flow.zig");
const stf = @import("./shrink_to_fit.zig");
const solve = @import("./solve.zig");
const StyleComputer = @import("./StyleComputer.zig");

const BoxTree = zss.BoxTree;
const BlockRef = BoxTree.BlockRef;
const BoxStyle = BoxTree.BoxStyle;
const Ifc = BoxTree.InlineFormattingContext;
const GlyphIndex = Ifc.GlyphIndex;
const GeneratedBox = BoxTree.GeneratedBox;
const Subtree = BoxTree.Subtree;

const hb = @import("mach-harfbuzz").c;

pub const Result = struct {
    min_width: Unit,
};

pub fn beginMode(layout: *Layout, size_mode: Layout.SizeMode, containing_block_size: Layout.ContainingBlockSize) !void {
    assert(containing_block_size.width >= 0);
    if (containing_block_size.height) |h| assert(h >= 0);

    const ifc = try layout.pushIfc();
    try layout.inline_context.pushIfc(layout.allocator, ifc, size_mode, containing_block_size);

    try pushRootInlineBox(layout);
}

pub fn endMode(layout: *Layout) !Result {
    _ = try popInlineBox(layout);

    const ifc = layout.inline_context.ifc.top.?;
    const containing_block_width = ifc.containing_block_size.width;

    const subtree = layout.box_tree.ptr.getSubtree(layout.currentSubtree()).view();
    ifcSolveMetrics(ifc.ptr, subtree, layout.inputs.fonts);
    const line_split_result = try splitIntoLineBoxes(layout, subtree, ifc.ptr, containing_block_width);

    layout.inline_context.popIfc();
    layout.popIfc(ifc.ptr.id, containing_block_width, line_split_result.height);

    return .{
        .min_width = line_split_result.longest_line_box_length,
    };
}

pub const Context = struct {
    ifc: Stack(struct {
        ptr: *Ifc,
        depth: Ifc.Size,
        containing_block_size: Layout.ContainingBlockSize,
        percentage_base_unit: Unit,
        font_handle: ?Fonts.Handle,
    }) = .init(undefined),
    inline_box: Stack(InlineBox) = .init(undefined),

    const InlineBox = struct {
        index: Ifc.Size,
        skip: Ifc.Size,
    };

    pub fn deinit(ctx: *Context, allocator: Allocator) void {
        ctx.ifc.deinit(allocator);
        ctx.inline_box.deinit(allocator);
    }

    fn pushIfc(
        ctx: *Context,
        allocator: Allocator,
        ptr: *Ifc,
        size_mode: Layout.SizeMode,
        containing_block_size: Layout.ContainingBlockSize,
    ) !void {
        const percentage_base_unit: Unit = switch (size_mode) {
            .Normal => containing_block_size.width,
            .ShrinkToFit => 0,
        };
        try ctx.ifc.push(allocator, .{
            .ptr = ptr,
            .depth = 0,
            .containing_block_size = containing_block_size,
            .percentage_base_unit = percentage_base_unit,
            .font_handle = null,
        });
    }

    fn popIfc(ctx: *Context) void {
        const ifc = ctx.ifc.pop();
        assert(ifc.depth == 0);
    }

    fn pushInlineBox(ctx: *Context, allocator: Allocator, index: Ifc.Size) !void {
        try ctx.inline_box.push(allocator, .{ .index = index, .skip = 1 });
        ctx.ifc.top.?.depth += 1;
    }

    fn popInlineBox(ctx: *Context) InlineBox {
        const inline_box = ctx.inline_box.pop();
        ctx.ifc.top.?.depth -= 1;
        return inline_box;
    }

    fn accumulateSkip(ctx: *Context, skip: Ifc.Size) void {
        ctx.inline_box.top.?.skip += skip;
    }

    fn setFont(ctx: *Context, handle: Fonts.Handle) void {
        const ifc = &ctx.ifc.top.?;
        if (ifc.font_handle) |prev_handle| {
            if (handle != prev_handle) {
                std.debug.panic("TODO: Only one font allowed per IFC", .{});
            }
        } else {
            ifc.font_handle = handle;
            ifc.ptr.font = handle;
        }
    }
};

pub fn inlineElement(layout: *Layout, element: Element, inner_inline: BoxStyle.InnerInline, position: BoxStyle.Position) !void {
    const ctx = &layout.inline_context;
    const ifc = ctx.ifc.top.?;

    // TODO: Check position and float properties
    switch (inner_inline) {
        .text => {
            const generated_box = GeneratedBox{ .text = ifc.ptr.id };
            try layout.box_tree.setGeneratedBox(element, generated_box);

            // TODO: Do proper font matching.
            const font = layout.computer.getTextFont(.box_gen);
            const handle: Fonts.Handle = switch (font.font) {
                .default => layout.inputs.fonts.query(),
                .none => .invalid,
                .initial, .inherit, .unset, .undeclared => unreachable,
            };
            layout.inline_context.setFont(handle);
            if (layout.inputs.fonts.get(handle)) |hb_font| {
                const text = layout.computer.getText();
                try ifcAddText(layout.box_tree, ifc.ptr, text, hb_font.handle);
            }

            layout.advanceElement();
        },
        .@"inline" => {
            { // TODO: Grabbing useless data to satisfy inheritance...
                const data = .{
                    .content_width = layout.computer.getSpecifiedValue(.box_gen, .content_width),
                    .content_height = layout.computer.getSpecifiedValue(.box_gen, .content_height),
                    .z_index = layout.computer.getSpecifiedValue(.box_gen, .z_index),
                };
                layout.computer.setComputedValue(.box_gen, .content_width, data.content_width);
                layout.computer.setComputedValue(.box_gen, .content_height, data.content_height);
                layout.computer.setComputedValue(.box_gen, .z_index, data.z_index);

                layout.computer.commitElement(.box_gen);
            }

            const inline_box_index = try pushInlineBox(layout);
            const generated_box = GeneratedBox{ .inline_box = .{ .ifc_id = ifc.ptr.id, .index = inline_box_index } };
            try layout.box_tree.setGeneratedBox(element, generated_box);
            try layout.pushElement();
        },
        .block => |block_inner| switch (block_inner) {
            .flow => {
                const sizes = inlineBlockSolveSizes(&layout.computer, position, ifc.containing_block_size);
                const stacking_context = inlineBlockSolveStackingContext(&layout.computer, position);
                layout.computer.commitElement(.box_gen);

                if (sizes.get(.inline_size)) |_| {
                    const ref = try layout.pushFlowBlock(.Normal, sizes, {}, stacking_context);
                    try layout.box_tree.setGeneratedBox(element, .{ .block_ref = ref });
                    try ifcAddInlineBlock(layout.box_tree, ifc.ptr, ref.index);
                    try layout.pushElement();
                    return layout.pushFlowMode(.NonRoot);
                } else {
                    const available_width_unclamped = ifc.containing_block_size.width -
                        (sizes.margin_inline_start_untagged + sizes.margin_inline_end_untagged +
                        sizes.border_inline_start + sizes.border_inline_end +
                        sizes.padding_inline_start + sizes.padding_inline_end);
                    const available_width = solve.clampSize(available_width_unclamped, sizes.min_inline_size, sizes.max_inline_size);

                    const ref = try layout.pushFlowBlock(.ShrinkToFit, sizes, available_width, stacking_context);
                    try layout.box_tree.setGeneratedBox(element, .{ .block_ref = ref });
                    try ifcAddInlineBlock(layout.box_tree, ifc.ptr, ref.index);
                    try layout.pushElement();
                    return layout.pushStfMode(.flow, sizes);
                }
            },
        },
    }
}

pub fn blockElement(layout: *Layout) !void {
    if (layout.inline_context.ifc.top.?.depth == 1) {
        try layout.popInlineMode();
    } else {
        std.debug.panic("TODO: Block boxes within IFCs", .{});
    }
}

pub fn nullElement(layout: *Layout) !void {
    const ctx = &layout.inline_context;
    const ifc = ctx.ifc.top.?;
    if (ifc.depth == 1) return layout.popInlineMode();
    const skip = try popInlineBox(layout);
    layout.popElement();
    ctx.accumulateSkip(skip);
}

pub fn afterFlowMode(layout: *Layout) void {
    layout.popFlowBlock(.Normal, {});
    layout.popElement();
}

pub fn afterInlineMode() noreturn {
    unreachable;
}

pub fn afterStfMode(layout: *Layout, layout_result: stf.Result) void {
    layout.popFlowBlock(.ShrinkToFit, layout_result.auto_width);
    layout.popElement();
}

fn pushRootInlineBox(layout: *Layout) !void {
    const ctx = &layout.inline_context;
    const ifc = &ctx.ifc.top.?;
    const index = try layout.box_tree.appendInlineBox(ifc.ptr);
    setDataRootInlineBox(ifc.ptr, index);
    try ifcAddBoxStart(layout.box_tree, ifc.ptr, index);
    try ctx.pushInlineBox(layout.allocator, index);
}

fn pushInlineBox(layout: *Layout) !Ifc.Size {
    const ctx = &layout.inline_context;
    const ifc = &ctx.ifc.top.?;
    const index = try layout.box_tree.appendInlineBox(ifc.ptr);
    setDataInlineBox(&layout.computer, ifc.ptr.slice(), index, ifc.percentage_base_unit);
    try ifcAddBoxStart(layout.box_tree, ifc.ptr, index);
    try ctx.pushInlineBox(layout.allocator, index);
    return index;
}

fn popInlineBox(layout: *Layout) !Ifc.Size {
    const ctx = &layout.inline_context;
    const ifc = ctx.ifc.top.?;
    const inline_box = ctx.popInlineBox();
    ifc.ptr.slice().items(.skip)[inline_box.index] = inline_box.skip;
    try ifcAddBoxEnd(layout.box_tree, ifc.ptr, inline_box.index);
    return inline_box.skip;
}

fn ifcAddBoxStart(box_tree: BoxTreeManaged, ifc: *Ifc, inline_box_index: Ifc.Size) !void {
    try box_tree.appendSpecialGlyph(ifc, .BoxStart, inline_box_index);
}

fn ifcAddBoxEnd(box_tree: BoxTreeManaged, ifc: *Ifc, inline_box_index: Ifc.Size) !void {
    try box_tree.appendSpecialGlyph(ifc, .BoxEnd, inline_box_index);
}

fn ifcAddInlineBlock(box_tree: BoxTreeManaged, ifc: *Ifc, block_box_index: Subtree.Size) !void {
    try box_tree.appendSpecialGlyph(ifc, .InlineBlock, block_box_index);
}

fn ifcAddLineBreak(box_tree: BoxTreeManaged, ifc: *Ifc) !void {
    try box_tree.appendSpecialGlyph(ifc, .LineBreak, {});
}

fn ifcAddText(box_tree: BoxTreeManaged, ifc: *Ifc, text: zss.values.types.Text, font: *hb.hb_font_t) !void {
    const buffer = hb.hb_buffer_create() orelse unreachable;
    defer hb.hb_buffer_destroy(buffer);
    _ = hb.hb_buffer_pre_allocate(buffer, @intCast(text.len));
    // TODO direction, script, and language must be determined by examining the text itself
    hb.hb_buffer_set_direction(buffer, hb.HB_DIRECTION_LTR);
    hb.hb_buffer_set_script(buffer, hb.HB_SCRIPT_LATIN);
    hb.hb_buffer_set_language(buffer, hb.hb_language_from_string("en", -1));

    var run_begin: usize = 0;
    var run_end: usize = 0;
    while (run_end < text.len) : (run_end += 1) {
        const codepoint = text[run_end];
        switch (codepoint) {
            '\n' => {
                try ifcEndTextRun(box_tree, ifc, text, buffer, font, run_begin, run_end);
                try ifcAddLineBreak(box_tree, ifc);
                run_begin = run_end + 1;
            },
            '\r' => {
                try ifcEndTextRun(box_tree, ifc, text, buffer, font, run_begin, run_end);
                try ifcAddLineBreak(box_tree, ifc);
                run_end += @intFromBool(run_end + 1 < text.len and text[run_end + 1] == '\n');
                run_begin = run_end + 1;
            },
            '\t' => {
                try ifcEndTextRun(box_tree, ifc, text, buffer, font, run_begin, run_end);
                run_begin = run_end + 1;
                // TODO tab size should be determined by the 'tab-size' property
                const tab_size = 8;
                hb.hb_buffer_add_latin1(buffer, " " ** tab_size, tab_size, 0, tab_size);
                if (hb.hb_buffer_allocation_successful(buffer) == 0) return error.OutOfMemory;
                try ifcAddTextRun(box_tree, ifc, buffer, font);
                assert(hb.hb_buffer_set_length(buffer, 0) != 0);
            },
            else => {},
        }
    }

    try ifcEndTextRun(box_tree, ifc, text, buffer, font, run_begin, run_end);
}

fn ifcEndTextRun(box_tree: BoxTreeManaged, ifc: *Ifc, text: zss.values.types.Text, buffer: *hb.hb_buffer_t, font: *hb.hb_font_t, run_begin: usize, run_end: usize) !void {
    if (run_end > run_begin) {
        hb.hb_buffer_add_latin1(buffer, text.ptr, @intCast(text.len), @intCast(run_begin), @intCast(run_end - run_begin));
        if (hb.hb_buffer_allocation_successful(buffer) == 0) return error.OutOfMemory;
        try ifcAddTextRun(box_tree, ifc, buffer, font);
        assert(hb.hb_buffer_set_length(buffer, 0) != 0);
    }
}

fn ifcAddTextRun(box_tree: BoxTreeManaged, ifc: *Ifc, buffer: *hb.hb_buffer_t, font: *hb.hb_font_t) !void {
    hb.hb_shape(font, buffer, null, 0);
    const glyph_infos = blk: {
        var n: c_uint = 0;
        const p = hb.hb_buffer_get_glyph_infos(buffer, &n);
        break :blk p[0..n];
    };

    for (glyph_infos) |info| {
        const glyph_index: GlyphIndex = info.codepoint;
        if (glyph_index == 0) {
            try box_tree.appendSpecialGlyph(ifc, .ZeroGlyphIndex, {});
        } else {
            try box_tree.appendGlyph(ifc, glyph_index);
        }
    }
}

fn setDataRootInlineBox(ifc: *const Ifc, inline_box_index: Ifc.Size) void {
    const ifc_slice = ifc.slice();
    ifc_slice.items(.inline_start)[inline_box_index] = .{};
    ifc_slice.items(.inline_end)[inline_box_index] = .{};
    ifc_slice.items(.block_start)[inline_box_index] = .{};
    ifc_slice.items(.block_end)[inline_box_index] = .{};
    ifc_slice.items(.margins)[inline_box_index] = .{};
}

fn setDataInlineBox(computer: *StyleComputer, ifc: Ifc.Slice, inline_box_index: Ifc.Size, percentage_base_unit: Unit) void {
    // TODO: Also use the logical properties ('padding-inline-start', 'border-block-end', etc.).
    const specified = .{
        .horizontal_edges = computer.getSpecifiedValue(.box_gen, .horizontal_edges),
        .vertical_edges = computer.getSpecifiedValue(.box_gen, .vertical_edges),
        .border_styles = computer.getSpecifiedValue(.box_gen, .border_styles),
    };

    var computed: struct {
        horizontal_edges: aggregates.HorizontalEdges,
        vertical_edges: aggregates.VerticalEdges,
    } = undefined;

    var used: struct {
        margin_inline_start: Unit,
        border_inline_start: Unit,
        padding_inline_start: Unit,
        margin_inline_end: Unit,
        border_inline_end: Unit,
        padding_inline_end: Unit,
        border_block_start: Unit,
        padding_block_start: Unit,
        border_block_end: Unit,
        padding_block_end: Unit,
    } = undefined;

    switch (specified.horizontal_edges.margin_left) {
        .px => |value| {
            computed.horizontal_edges.margin_left = .{ .px = value };
            used.margin_inline_start = solve.length(.px, value);
        },
        .percentage => |value| {
            computed.horizontal_edges.margin_left = .{ .percentage = value };
            used.margin_inline_start = solve.percentage(value, percentage_base_unit);
        },
        .auto => {
            computed.horizontal_edges.margin_left = .auto;
            used.margin_inline_start = 0;
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
    {
        const multiplier = solve.borderWidthMultiplier(specified.border_styles.left);
        switch (specified.horizontal_edges.border_left) {
            .px => |value| {
                const width = value * multiplier;
                computed.horizontal_edges.border_left = .{ .px = width };
                used.border_inline_start = solve.positiveLength(.px, width);
            },
            inline .thin, .medium, .thick => |_, tag| {
                const width = solve.borderWidth(tag) * multiplier;
                computed.horizontal_edges.border_left = .{ .px = width };
                used.border_inline_start = solve.positiveLength(.px, width);
            },
            .initial, .inherit, .unset, .undeclared => unreachable,
        }
    }
    switch (specified.horizontal_edges.padding_left) {
        .px => |value| {
            computed.horizontal_edges.padding_left = .{ .px = value };
            used.padding_inline_start = solve.positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.horizontal_edges.padding_left = .{ .percentage = value };
            used.padding_inline_start = solve.positivePercentage(value, percentage_base_unit);
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
    switch (specified.horizontal_edges.margin_right) {
        .px => |value| {
            computed.horizontal_edges.margin_right = .{ .px = value };
            used.margin_inline_end = solve.length(.px, value);
        },
        .percentage => |value| {
            computed.horizontal_edges.margin_right = .{ .percentage = value };
            used.margin_inline_end = solve.percentage(value, percentage_base_unit);
        },
        .auto => {
            computed.horizontal_edges.margin_right = .auto;
            used.margin_inline_end = 0;
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
    {
        const multiplier = solve.borderWidthMultiplier(specified.border_styles.right);
        switch (specified.horizontal_edges.border_right) {
            .px => |value| {
                const width = value * multiplier;
                computed.horizontal_edges.border_right = .{ .px = width };
                used.border_inline_end = solve.positiveLength(.px, width);
            },
            inline .thin, .medium, .thick => |_, tag| {
                const width = solve.borderWidth(tag) * multiplier;
                computed.horizontal_edges.border_right = .{ .px = width };
                used.border_inline_end = solve.positiveLength(.px, width);
            },
            .initial, .inherit, .unset, .undeclared => unreachable,
        }
    }
    switch (specified.horizontal_edges.padding_right) {
        .px => |value| {
            computed.horizontal_edges.padding_right = .{ .px = value };
            used.padding_inline_end = solve.positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.horizontal_edges.padding_right = .{ .percentage = value };
            used.padding_inline_end = solve.positivePercentage(value, percentage_base_unit);
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }

    {
        const multiplier = solve.borderWidthMultiplier(specified.border_styles.top);
        switch (specified.vertical_edges.border_top) {
            .px => |value| {
                const width = value * multiplier;
                computed.vertical_edges.border_top = .{ .px = width };
                used.border_block_start = solve.positiveLength(.px, width);
            },
            inline .thin, .medium, .thick => |_, tag| {
                const width = solve.borderWidth(tag) * multiplier;
                computed.vertical_edges.border_top = .{ .px = width };
                used.border_block_start = solve.positiveLength(.px, width);
            },
            .initial, .inherit, .unset, .undeclared => unreachable,
        }
    }
    switch (specified.vertical_edges.padding_top) {
        .px => |value| {
            computed.vertical_edges.padding_top = .{ .px = value };
            used.padding_block_start = solve.positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.vertical_edges.padding_top = .{ .percentage = value };
            used.padding_block_start = solve.positivePercentage(value, percentage_base_unit);
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
    {
        const multiplier = solve.borderWidthMultiplier(specified.border_styles.bottom);
        switch (specified.vertical_edges.border_bottom) {
            .px => |value| {
                const width = value * multiplier;
                computed.vertical_edges.border_bottom = .{ .px = width };
                used.border_block_end = solve.positiveLength(.px, width);
            },
            inline .thin, .medium, .thick => |_, tag| {
                const width = solve.borderWidth(tag) * multiplier;
                computed.vertical_edges.border_bottom = .{ .px = width };
                used.border_block_end = solve.positiveLength(.px, width);
            },
            .initial, .inherit, .unset, .undeclared => unreachable,
        }
    }
    switch (specified.vertical_edges.padding_bottom) {
        .px => |value| {
            computed.vertical_edges.padding_bottom = .{ .px = value };
            used.padding_block_end = solve.positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.vertical_edges.padding_bottom = .{ .percentage = value };
            used.padding_block_end = solve.positivePercentage(value, percentage_base_unit);
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }

    computed.vertical_edges.margin_top = specified.vertical_edges.margin_top;
    computed.vertical_edges.margin_bottom = specified.vertical_edges.margin_bottom;

    computer.setComputedValue(.box_gen, .horizontal_edges, computed.horizontal_edges);
    computer.setComputedValue(.box_gen, .vertical_edges, computed.vertical_edges);
    computer.setComputedValue(.box_gen, .border_styles, specified.border_styles);

    ifc.items(.inline_start)[inline_box_index] = .{ .border = used.border_inline_start, .padding = used.padding_inline_start };
    ifc.items(.inline_end)[inline_box_index] = .{ .border = used.border_inline_end, .padding = used.padding_inline_end };
    ifc.items(.block_start)[inline_box_index] = .{ .border = used.border_block_start, .padding = used.padding_block_start };
    ifc.items(.block_end)[inline_box_index] = .{ .border = used.border_block_end, .padding = used.padding_block_end };
    ifc.items(.margins)[inline_box_index] = .{ .start = used.margin_inline_start, .end = used.margin_inline_end };
}

fn inlineBlockSolveSizes(
    computer: *StyleComputer,
    position: BoxTree.BoxStyle.Position,
    containing_block_size: Layout.ContainingBlockSize,
) BlockUsedSizes {
    const specified = BlockComputedSizes{
        .content_width = computer.getSpecifiedValue(.box_gen, .content_width),
        .horizontal_edges = computer.getSpecifiedValue(.box_gen, .horizontal_edges),
        .content_height = computer.getSpecifiedValue(.box_gen, .content_height),
        .vertical_edges = computer.getSpecifiedValue(.box_gen, .vertical_edges),
        .insets = computer.getSpecifiedValue(.box_gen, .insets),
    };
    const border_styles = computer.getSpecifiedValue(.box_gen, .border_styles);
    var computed: BlockComputedSizes = undefined;
    var used: BlockUsedSizes = undefined;

    // TODO: Also use the logical properties ('padding-inline-start', 'border-block-end', etc.).

    {
        const multiplier = solve.borderWidthMultiplier(border_styles.left);
        switch (specified.horizontal_edges.border_left) {
            .px => |value| {
                const width = value * multiplier;
                computed.horizontal_edges.border_left = .{ .px = width };
                used.border_inline_start = solve.positiveLength(.px, width);
            },
            inline .thin, .medium, .thick => |_, tag| {
                const width = solve.borderWidth(tag) * multiplier;
                computed.horizontal_edges.border_left = .{ .px = width };
                used.border_inline_start = solve.positiveLength(.px, width);
            },
            .initial, .inherit, .unset, .undeclared => unreachable,
        }
    }
    {
        const multiplier = solve.borderWidthMultiplier(border_styles.right);
        switch (specified.horizontal_edges.border_right) {
            .px => |value| {
                const width = value * multiplier;
                computed.horizontal_edges.border_right = .{ .px = width };
                used.border_inline_end = solve.positiveLength(.px, width);
            },
            inline .thin, .medium, .thick => |_, tag| {
                const width = solve.borderWidth(tag) * multiplier;
                computed.horizontal_edges.border_right = .{ .px = width };
                used.border_inline_end = solve.positiveLength(.px, width);
            },
            .initial, .inherit, .unset, .undeclared => unreachable,
        }
    }
    switch (specified.horizontal_edges.padding_left) {
        .px => |value| {
            computed.horizontal_edges.padding_left = .{ .px = value };
            used.padding_inline_start = solve.positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.horizontal_edges.padding_left = .{ .percentage = value };
            used.padding_inline_start = solve.positivePercentage(value, containing_block_size.width);
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
    switch (specified.horizontal_edges.padding_right) {
        .px => |value| {
            computed.horizontal_edges.padding_right = .{ .px = value };
            used.padding_inline_end = solve.positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.horizontal_edges.padding_right = .{ .percentage = value };
            used.padding_inline_end = solve.positivePercentage(value, containing_block_size.width);
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
    switch (specified.horizontal_edges.margin_left) {
        .px => |value| {
            computed.horizontal_edges.margin_left = .{ .px = value };
            used.setValue(.margin_inline_start, solve.length(.px, value));
        },
        .percentage => |value| {
            computed.horizontal_edges.margin_left = .{ .percentage = value };
            used.setValue(.margin_inline_start, solve.percentage(value, containing_block_size.width));
        },
        .auto => {
            computed.horizontal_edges.margin_left = .auto;
            used.setValue(.margin_inline_start, 0);
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
    switch (specified.horizontal_edges.margin_right) {
        .px => |value| {
            computed.horizontal_edges.margin_right = .{ .px = value };
            used.setValue(.margin_inline_end, solve.length(.px, value));
        },
        .percentage => |value| {
            computed.horizontal_edges.margin_right = .{ .percentage = value };
            used.setValue(.margin_inline_end, solve.percentage(value, containing_block_size.width));
        },
        .auto => {
            computed.horizontal_edges.margin_right = .auto;
            used.setValue(.margin_inline_end, 0);
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
    switch (specified.content_width.min_width) {
        .px => |value| {
            computed.content_width.min_width = .{ .px = value };
            used.min_inline_size = solve.positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.content_width.min_width = .{ .percentage = value };
            used.min_inline_size = solve.positivePercentage(value, containing_block_size.width);
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
    switch (specified.content_width.max_width) {
        .px => |value| {
            computed.content_width.max_width = .{ .px = value };
            used.max_inline_size = solve.positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.content_width.max_width = .{ .percentage = value };
            used.max_inline_size = solve.positivePercentage(value, containing_block_size.width);
        },
        .none => {
            computed.content_width.max_width = .none;
            used.max_inline_size = std.math.maxInt(Unit);
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }

    switch (specified.content_width.width) {
        .px => |value| {
            computed.content_width.width = .{ .px = value };
            used.setValue(.inline_size, solve.positiveLength(.px, value));
        },
        .percentage => |value| {
            computed.content_width.width = .{ .percentage = value };
            used.setValue(.inline_size, solve.positivePercentage(value, containing_block_size.width));
        },
        .auto => {
            computed.content_width.width = .auto;
            used.setAuto(.inline_size);
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }

    {
        const multiplier = solve.borderWidthMultiplier(border_styles.top);
        switch (specified.vertical_edges.border_top) {
            .px => |value| {
                const width = value * multiplier;
                computed.vertical_edges.border_top = .{ .px = width };
                used.border_block_start = solve.positiveLength(.px, width);
            },
            inline .thin, .medium, .thick => |_, tag| {
                const width = solve.borderWidth(tag) * multiplier;
                computed.vertical_edges.border_top = .{ .px = width };
                used.border_block_start = solve.positiveLength(.px, width);
            },
            .initial, .inherit, .unset, .undeclared => unreachable,
        }
    }
    {
        const multiplier = solve.borderWidthMultiplier(border_styles.bottom);
        switch (specified.vertical_edges.border_bottom) {
            .px => |value| {
                const width = value * multiplier;
                computed.vertical_edges.border_bottom = .{ .px = width };
                used.border_block_end = solve.positiveLength(.px, width);
            },
            inline .thin, .medium, .thick => |_, tag| {
                const width = solve.borderWidth(tag) * multiplier;
                computed.vertical_edges.border_bottom = .{ .px = width };
                used.border_block_end = solve.positiveLength(.px, width);
            },
            .initial, .inherit, .unset, .undeclared => unreachable,
        }
    }
    switch (specified.vertical_edges.padding_top) {
        .px => |value| {
            computed.vertical_edges.padding_top = .{ .px = value };
            used.padding_block_start = solve.positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.vertical_edges.padding_top = .{ .percentage = value };
            used.padding_block_start = solve.positivePercentage(value, containing_block_size.width);
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
    switch (specified.vertical_edges.padding_bottom) {
        .px => |value| {
            computed.vertical_edges.padding_bottom = .{ .px = value };
            used.padding_block_end = solve.positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.vertical_edges.padding_bottom = .{ .percentage = value };
            used.padding_block_end = solve.positivePercentage(value, containing_block_size.width);
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
    switch (specified.vertical_edges.margin_top) {
        .px => |value| {
            computed.vertical_edges.margin_top = .{ .px = value };
            used.margin_block_start = solve.length(.px, value);
        },
        .percentage => |value| {
            computed.vertical_edges.margin_top = .{ .percentage = value };
            used.margin_block_start = solve.percentage(value, containing_block_size.width);
        },
        .auto => {
            computed.vertical_edges.margin_top = .auto;
            used.margin_block_start = 0;
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
    switch (specified.vertical_edges.margin_bottom) {
        .px => |value| {
            computed.vertical_edges.margin_bottom = .{ .px = value };
            used.margin_block_end = solve.length(.px, value);
        },
        .percentage => |value| {
            computed.vertical_edges.margin_bottom = .{ .percentage = value };
            used.margin_block_end = solve.percentage(value, containing_block_size.width);
        },
        .auto => {
            computed.vertical_edges.margin_bottom = .auto;
            used.margin_block_end = 0;
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
    switch (specified.content_height.min_height) {
        .px => |value| {
            computed.content_height.min_height = .{ .px = value };
            used.min_block_size = solve.positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.content_height.min_height = .{ .percentage = value };
            used.min_block_size = if (containing_block_size.height) |h|
                solve.positivePercentage(value, h)
            else
                0;
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
    switch (specified.content_height.max_height) {
        .px => |value| {
            computed.content_height.max_height = .{ .px = value };
            used.max_block_size = solve.positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.content_height.max_height = .{ .percentage = value };
            used.max_block_size = if (containing_block_size.height) |h|
                solve.positivePercentage(value, h)
            else
                std.math.maxInt(Unit);
        },
        .none => {
            computed.content_height.max_height = .none;
            used.max_block_size = std.math.maxInt(Unit);
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
    switch (specified.content_height.height) {
        .px => |value| {
            computed.content_height.height = .{ .px = value };
            used.setValue(.block_size, solve.positiveLength(.px, value));
        },
        .percentage => |value| {
            computed.content_height.height = .{ .percentage = value };
            if (containing_block_size.height) |h|
                used.setValue(.block_size, solve.positivePercentage(value, h))
            else
                used.setAuto(.block_size);
        },
        .auto => {
            computed.content_height.height = .auto;
            used.setAuto(.block_size);
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }

    computed.insets = solve.insets(specified.insets);
    flow.solveInsets(computed.insets, position, &used);

    computer.setComputedValue(.box_gen, .content_width, computed.content_width);
    computer.setComputedValue(.box_gen, .horizontal_edges, computed.horizontal_edges);
    computer.setComputedValue(.box_gen, .content_height, computed.content_height);
    computer.setComputedValue(.box_gen, .vertical_edges, computed.vertical_edges);
    computer.setComputedValue(.box_gen, .insets, computed.insets);
    computer.setComputedValue(.box_gen, .border_styles, border_styles);

    return used;
}

fn inlineBlockSolveStackingContext(
    computer: *StyleComputer,
    position: BoxTree.BoxStyle.Position,
) SctBuilder.Type {
    const z_index = computer.getSpecifiedValue(.box_gen, .z_index);
    computer.setComputedValue(.box_gen, .z_index, z_index);

    switch (position) {
        .static => return .{ .non_parentable = 0 },
        // TODO: Position the block using the values of the 'inset' family of properties.
        .relative => switch (z_index.z_index) {
            .integer => |integer| return .{ .parentable = integer },
            .auto => return .{ .non_parentable = 0 },
            .initial, .inherit, .unset, .undeclared => unreachable,
        },
        .absolute => unreachable,
    }
}

fn ifcSolveMetrics(ifc: *Ifc, subtree: Subtree.View, fonts: *const Fonts) void {
    const font = fonts.get(ifc.font);
    const ifc_slice = ifc.slice();
    const glyphs_slice = ifc.glyphs.slice();

    var i: usize = 0;
    while (i < glyphs_slice.len) : (i += 1) {
        const glyph_index = glyphs_slice.items(.index)[i];
        const metrics = &glyphs_slice.items(.metrics)[i];

        if (glyph_index == 0) {
            i += 1;
            const special = Ifc.Special.decode(glyphs_slice.items(.index)[i]);
            const kind = @as(std.meta.Tag(BoxTreeManaged.SpecialGlyph), @enumFromInt(@intFromEnum(special.kind)));
            switch (kind) {
                .ZeroGlyphIndex => setMetricsGlyph(metrics, font.?.handle, 0),
                .BoxStart => {
                    const inline_box_index = @as(Ifc.Size, special.data);
                    setMetricsBoxStart(metrics, ifc_slice, inline_box_index);
                },
                .BoxEnd => {
                    const inline_box_index = @as(Ifc.Size, special.data);
                    setMetricsBoxEnd(metrics, ifc_slice, inline_box_index);
                },
                .InlineBlock => {
                    const block_box_index = @as(Subtree.Size, special.data);
                    setMetricsInlineBlock(metrics, subtree, block_box_index);
                },
                .LineBreak => setMetricsLineBreak(metrics),
            }
        } else {
            setMetricsGlyph(metrics, font.?.handle, glyph_index);
        }
    }
}

fn setMetricsGlyph(metrics: *Ifc.Metrics, font: *hb.hb_font_t, glyph_index: GlyphIndex) void {
    var extents: hb.hb_glyph_extents_t = undefined;
    const extents_result = hb.hb_font_get_glyph_extents(font, glyph_index, &extents);
    if (extents_result == 0) {
        extents.width = 0;
        extents.x_bearing = 0;
    }
    metrics.* = .{
        .offset = @divFloor(extents.x_bearing * units_per_pixel, 64),
        .advance = @divFloor(hb.hb_font_get_glyph_h_advance(font, glyph_index) * units_per_pixel, 64),
        .width = @divFloor(extents.width * units_per_pixel, 64),
    };
}

fn setMetricsBoxStart(metrics: *Ifc.Metrics, ifc_slice: Ifc.Slice, inline_box_index: Ifc.Size) void {
    const inline_start = ifc_slice.items(.inline_start)[inline_box_index];
    const margin = ifc_slice.items(.margins)[inline_box_index].start;
    const width = inline_start.border + inline_start.padding;
    const advance = width + margin;
    metrics.* = .{ .offset = margin, .advance = advance, .width = width };
}

fn setMetricsBoxEnd(metrics: *Ifc.Metrics, ifc_slice: Ifc.Slice, inline_box_index: Ifc.Size) void {
    const inline_end = ifc_slice.items(.inline_end)[inline_box_index];
    const margin = ifc_slice.items(.margins)[inline_box_index].end;
    const width = inline_end.border + inline_end.padding;
    const advance = width + margin;
    metrics.* = .{ .offset = 0, .advance = advance, .width = width };
}

fn setMetricsLineBreak(metrics: *Ifc.Metrics) void {
    metrics.* = .{ .offset = 0, .advance = 0, .width = 0 };
}

fn setMetricsInlineBlock(metrics: *Ifc.Metrics, subtree: Subtree.View, block_box_index: Subtree.Size) void {
    const box_offsets = subtree.items(.box_offsets)[block_box_index];
    const margins = subtree.items(.margins)[block_box_index];

    const width = box_offsets.border_size.w;
    const advance = width + margins.left + margins.right;
    metrics.* = .{ .offset = margins.left, .advance = advance, .width = width };
}

const IFCLineSplitState = struct {
    cursor: Unit,
    line_box: Ifc.LineBox,
    inline_blocks_in_this_line_box: ArrayListUnmanaged(InlineBlockInfo),
    top_height: Unit,
    max_top_height: Unit,
    bottom_height: Unit,
    longest_line_box_length: Unit,
    inline_box_stack: ArrayListUnmanaged(Ifc.Size) = .{},
    current_inline_box: Ifc.Size = undefined,

    const InlineBlockInfo = struct {
        offset: *zss.math.Vector,
        cursor: Unit,
        height: Unit,
    };

    fn init(top_height: Unit, bottom_height: Unit) IFCLineSplitState {
        return IFCLineSplitState{
            .cursor = 0,
            .line_box = .{ .baseline = 0, .elements = [2]usize{ 0, 0 }, .inline_box = undefined },
            .inline_blocks_in_this_line_box = .{},
            .top_height = top_height,
            .max_top_height = top_height,
            .bottom_height = bottom_height,
            .longest_line_box_length = 0,
        };
    }

    fn deinit(self: *IFCLineSplitState, allocator: Allocator) void {
        self.inline_blocks_in_this_line_box.deinit(allocator);
        self.inline_box_stack.deinit(allocator);
    }

    fn finishLineBox(self: *IFCLineSplitState) void {
        self.line_box.baseline += self.max_top_height;
        self.longest_line_box_length = @max(self.longest_line_box_length, self.cursor);

        for (self.inline_blocks_in_this_line_box.items) |info| {
            info.offset.* = .{
                .x = info.cursor,
                .y = self.line_box.baseline - info.height,
            };
        }
    }

    fn newLineBox(self: *IFCLineSplitState, skipped_glyphs: usize) void {
        self.cursor = 0;
        self.line_box = .{
            .baseline = self.line_box.baseline + self.bottom_height,
            .elements = [2]usize{ self.line_box.elements[1] + skipped_glyphs, self.line_box.elements[1] + skipped_glyphs },
            .inline_box = self.current_inline_box,
        };
        self.max_top_height = self.top_height;
        self.inline_blocks_in_this_line_box.clearRetainingCapacity();
    }

    fn pushInlineBox(self: *IFCLineSplitState, allocator: Allocator, index: Ifc.Size) !void {
        if (index != 0) {
            try self.inline_box_stack.append(allocator, self.current_inline_box);
        }
        self.current_inline_box = index;
    }

    fn popInlineBox(self: *IFCLineSplitState, index: Ifc.Size) void {
        assert(self.current_inline_box == index);
        if (index != 0) {
            self.current_inline_box = self.inline_box_stack.pop();
        } else {
            self.current_inline_box = undefined;
        }
    }
};

pub const IFCLineSplitResult = struct {
    height: Unit,
    longest_line_box_length: Unit,
};

pub fn splitIntoLineBoxes(
    layout: *Layout,
    subtree: Subtree.View,
    ifc: *Ifc,
    max_line_box_length: Unit,
) !IFCLineSplitResult {
    assert(max_line_box_length >= 0);

    var top_height: Unit = undefined;
    var bottom_height: Unit = undefined;
    if (layout.inputs.fonts.get(ifc.font)) |font| {
        // TODO assuming ltr direction
        var font_extents: hb.hb_font_extents_t = undefined;
        assert(hb.hb_font_get_h_extents(font.handle, &font_extents) != 0);
        ifc.ascender = @divFloor(font_extents.ascender * units_per_pixel, 64);
        ifc.descender = @divFloor(-font_extents.descender * units_per_pixel, 64);
        top_height = @divFloor((font_extents.ascender + @divFloor(font_extents.line_gap, 2) + @mod(font_extents.line_gap, 2)) * units_per_pixel, 64);
        bottom_height = @divFloor((-font_extents.descender + @divFloor(font_extents.line_gap, 2)) * units_per_pixel, 64);
    } else {
        ifc.ascender = 0;
        ifc.descender = 0;
        top_height = 0;
        bottom_height = 0;
    }

    var s = IFCLineSplitState.init(top_height, bottom_height);
    defer s.deinit(layout.allocator);

    const glyphs = ifc.glyphs.slice();

    {
        const gi = glyphs.items(.index)[0];
        assert(gi == 0);
        const special = Ifc.Special.decode(glyphs.items(.index)[1]);
        assert(special.kind == .BoxStart);
        assert(@as(Ifc.Size, special.data) == 0);
        s.pushInlineBox(layout.allocator, 0) catch unreachable;
        s.line_box.elements[1] = 2;
        s.line_box.inline_box = null;
    }

    var i: usize = 2;
    while (i < glyphs.len) : (i += 1) {
        const gi = glyphs.items(.index)[i];
        const metrics = glyphs.items(.metrics)[i];

        if (gi == 0) {
            i += 1;
            const special = Ifc.Special.decode(glyphs.items(.index)[i]);
            switch (@as(std.meta.Tag(BoxTreeManaged.SpecialGlyph), @enumFromInt(@intFromEnum(special.kind)))) {
                .BoxStart => try s.pushInlineBox(layout.allocator, @as(Ifc.Size, special.data)),
                .BoxEnd => s.popInlineBox(@as(Ifc.Size, special.data)),
                .LineBreak => {
                    s.finishLineBox();
                    try layout.box_tree.appendLineBox(ifc, s.line_box);
                    s.newLineBox(2);
                    continue;
                },
                else => {},
            }
        }

        // TODO: (Bug) A glyph with a width of zero but an advance that is non-zero may overflow the width of the containing block
        if (s.cursor > 0 and metrics.width > 0 and s.cursor + metrics.offset + metrics.width > max_line_box_length and s.line_box.elements[1] > s.line_box.elements[0]) {
            s.finishLineBox();
            try layout.box_tree.appendLineBox(ifc, s.line_box);
            s.newLineBox(0);
        }

        if (gi == 0) {
            const special = Ifc.Special.decode(glyphs.items(.index)[i]);
            switch (@as(std.meta.Tag(BoxTreeManaged.SpecialGlyph), @enumFromInt(@intFromEnum(special.kind)))) {
                .InlineBlock => {
                    const block_box_index = @as(Subtree.Size, special.data);
                    const offset = &subtree.items(.offset)[block_box_index];
                    const box_offsets = subtree.items(.box_offsets)[block_box_index];
                    const margins = subtree.items(.margins)[block_box_index];
                    const margin_box_height = box_offsets.border_size.h + margins.top + margins.bottom;
                    s.max_top_height = @max(s.max_top_height, margin_box_height);
                    try s.inline_blocks_in_this_line_box.append(
                        layout.allocator,
                        .{
                            .offset = offset,
                            .cursor = s.cursor,
                            // TODO: Why subtract `margins.top`?
                            .height = margin_box_height - margins.top,
                        },
                    );
                },
                .LineBreak => unreachable,
                else => {},
            }
            s.line_box.elements[1] += 2;
        } else {
            s.line_box.elements[1] += 1;
        }

        s.cursor += metrics.advance;
    }

    if (s.line_box.elements[1] > s.line_box.elements[0]) {
        s.finishLineBox();
        try layout.box_tree.appendLineBox(ifc, s.line_box);
    }

    return IFCLineSplitResult{
        .height = if (ifc.line_boxes.items.len > 0)
            ifc.line_boxes.items[ifc.line_boxes.items.len - 1].baseline + s.bottom_height
        else
            0, // TODO: This is never reached because the root inline box always creates at least 1 line box.
        .longest_line_box_length = s.longest_line_box_length,
    };
}
