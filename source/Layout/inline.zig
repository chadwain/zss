const std = @import("std");
const assert = std.debug.assert;
const panic = std.debug.panic;
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

const zss = @import("../zss.zig");
const aggregates = zss.properties.aggregates;
const BlockComputedSizes = zss.Layout.BlockComputedSizes;
const BlockUsedSizes = zss.Layout.BlockUsedSizes;
const BoxTreeManaged = Layout.BoxTreeManaged;
const ElementTree = zss.ElementTree;
const Element = ElementTree.Element;
const Fonts = zss.Fonts;
const Layout = zss.Layout;
const SctBuilder = Layout.StackingContextTreeBuilder;
const Unit = zss.math.Unit;
const units_per_pixel = zss.math.units_per_pixel;

const flow = @import("./flow.zig");
const stf = @import("./shrink_to_fit.zig");
const solve = @import("./solve.zig");
const StyleComputer = @import("./StyleComputer.zig");

const BoxTree = zss.BoxTree;
const StackingContextIndex = BoxTree.StackingContextIndex;
const StackingContextRef = BoxTree.StackingContextRef;
const InlineBoxIndex = BoxTree.InlineBoxIndex;
const InlineBoxSkip = BoxTree.InlineBoxSkip;
const InlineFormattingContext = BoxTree.InlineFormattingContext;
const InlineFormattingContextId = BoxTree.InlineFormattingContextId;
const GlyphIndex = InlineFormattingContext.GlyphIndex;
const GeneratedBox = BoxTree.GeneratedBox;
const Subtree = BoxTree.Subtree;

const hb = @import("mach-harfbuzz").c;

pub const Result = struct {
    min_width: Unit,
    height: Unit,
};

pub fn runInlineLayout(
    layout: *Layout,
    mode: enum { Normal, ShrinkToFit },
    containing_block_width: Unit,
    containing_block_height: ?Unit,
) zss.Layout.Error!Result {
    assert(containing_block_width >= 0);
    if (containing_block_height) |h| assert(h >= 0);

    const ifc_container = try layout.pushIfcContainerBlock();
    const ifc = try layout.newIfc(ifc_container);

    const percentage_base_unit: Unit = switch (mode) {
        .Normal => containing_block_width,
        .ShrinkToFit => 0,
    };

    var ctx = InlineLayoutContext{
        .allocator = layout.allocator,
        .containing_block_width = containing_block_width,
        .containing_block_height = containing_block_height,
        .percentage_base_unit = percentage_base_unit,
    };
    defer ctx.deinit();
    try analyzeElements(layout, &ctx, ifc);

    const subtree = layout.box_tree.ptr.blocks.subtree(ifc_container.subtree).view();
    const line_split_result = try splitIntoLineBoxes(layout, subtree, ifc, containing_block_width);
    layout.popIfcContainerBlock(ifc.id, containing_block_width, line_split_result.height);

    return .{
        .min_width = line_split_result.longest_line_box_length,
        .height = line_split_result.height,
    };
}

const InlineLayoutContext = struct {
    const Self = @This();

    allocator: Allocator,
    containing_block_width: Unit,
    containing_block_height: ?Unit,
    percentage_base_unit: Unit,

    inline_box_depth: InlineBoxIndex = 0,
    index: ArrayListUnmanaged(InlineBoxIndex) = .{},
    skip: ArrayListUnmanaged(InlineBoxSkip) = .{},
    total_inline_block_skip: Subtree.Size = 0,
    font_handle: ?Fonts.Handle = null,

    fn deinit(self: *Self) void {
        self.index.deinit(self.allocator);
        self.skip.deinit(self.allocator);
    }

    fn checkHandle(self: *Self, ifc: *InlineFormattingContext, handle: Fonts.Handle) void {
        if (self.font_handle) |prev_handle| {
            if (handle != prev_handle) {
                std.debug.panic("TODO: Only one font allowed per IFC", .{});
            }
        } else {
            self.font_handle = handle;
            ifc.font = handle;
        }
    }
};

fn analyzeElements(layout: *Layout, ctx: *InlineLayoutContext, ifc: *InlineFormattingContext) !void {
    try ifcPushRootInlineBox(ctx, layout.box_tree, ifc);
    while (!(try ifcRunOnce(layout, ctx, ifc))) {}
    try ifcPopRootInlineBox(ctx, layout.box_tree, ifc);

    try layout.box_tree.allocMetrics(ifc);
    const subtree = layout.box_tree.ptr.blocks.subtree(layout.currentSubtree()).view();
    ifcSolveMetrics(ifc, subtree, layout.inputs.fonts);
}

fn ifcPushRootInlineBox(ctx: *InlineLayoutContext, box_tree: BoxTreeManaged, ifc: *InlineFormattingContext) !void {
    assert(ctx.inline_box_depth == 0);
    const root_inline_box_index = try box_tree.appendInlineBox(ifc);
    rootInlineBoxSetData(ifc, root_inline_box_index);
    try ifcAddBoxStart(box_tree, ifc, root_inline_box_index);
    try ctx.index.append(ctx.allocator, root_inline_box_index);
    try ctx.skip.append(ctx.allocator, 1);
}

fn ifcPopRootInlineBox(ctx: *InlineLayoutContext, box_tree: BoxTreeManaged, ifc: *InlineFormattingContext) !void {
    assert(ctx.inline_box_depth == 0);
    const root_inline_box_index = ctx.index.pop();
    const skip = ctx.skip.pop();
    ifc.slice().items(.skip)[root_inline_box_index] = skip;
    try ifcAddBoxEnd(box_tree, ifc, root_inline_box_index);
}

/// A return value of true means that a terminating element was encountered.
fn ifcRunOnce(layout: *Layout, ctx: *InlineLayoutContext, ifc: *InlineFormattingContext) !bool {
    const element = layout.currentElement();
    if (element.eqlNull()) {
        if (ctx.inline_box_depth == 0) return true;
        try ifcPopInlineBox(ctx, layout.box_tree, ifc);
        layout.popElement();
        return false;
    }
    try layout.computer.setCurrentElement(.box_gen, element);

    const computed, const used_box_style = blk: {
        if (layout.computer.elementCategory(element) == .text) {
            break :blk .{ undefined, BoxTree.BoxStyle.text };
        }

        const specified_box_style = layout.computer.getSpecifiedValue(.box_gen, .box_style);
        const computed_box_style, const used_box_style = solve.boxStyle(specified_box_style, .NonRoot);
        layout.computer.setComputedValue(.box_gen, .box_style, computed_box_style);
        break :blk .{ computed_box_style, used_box_style };
    };

    // TODO: Check position and float properties
    switch (used_box_style.outer) {
        .@"inline" => |inner| switch (inner) {
            .text => {
                const generated_box = GeneratedBox{ .text = ifc.id };
                try layout.box_tree.setGeneratedBox(element, generated_box);

                // TODO: Do proper font matching.
                const font = layout.computer.getTextFont(.box_gen);
                const handle: Fonts.Handle = switch (font.font) {
                    .default => layout.inputs.fonts.query(),
                    .none => .invalid,
                    .initial, .inherit, .unset, .undeclared => unreachable,
                };
                ctx.checkHandle(ifc, handle);
                if (layout.inputs.fonts.get(handle)) |hb_font| {
                    const text = layout.computer.getText();
                    try ifcAddText(layout.box_tree, ifc, text, hb_font.handle);
                }

                layout.advanceElement();
            },
            .@"inline" => {
                const inline_box_index = try layout.box_tree.appendInlineBox(ifc);
                inlineBoxSetData(ctx, &layout.computer, ifc, inline_box_index);

                const generated_box = GeneratedBox{ .inline_box = .{ .ifc_id = ifc.id, .index = inline_box_index } };
                try layout.box_tree.setGeneratedBox(element, generated_box);

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

                try ifcAddBoxStart(layout.box_tree, ifc, inline_box_index);

                if (!layout.computer.element_tree_slice.firstChild(element).eqlNull()) {
                    ctx.inline_box_depth += 1;
                    try ctx.index.append(ctx.allocator, inline_box_index);
                    try ctx.skip.append(ctx.allocator, 1);
                    try layout.pushElement();
                } else {
                    // Optimized path for inline boxes with no children.
                    // It is a shorter version of ifcPopInlineBox.
                    try ifcAddBoxEnd(layout.box_tree, ifc, inline_box_index);
                    layout.advanceElement();
                }
            },
            .block => |block_inner| switch (block_inner) {
                .flow => {
                    const sizes = inlineBlockSolveSizes(&layout.computer, used_box_style.position, ctx.containing_block_width, ctx.containing_block_height);
                    const stacking_context = inlineBlockCreateStackingContext(&layout.computer, computed.position);
                    layout.computer.commitElement(.box_gen);

                    const index = blk: {
                        if (sizes.get(.inline_size)) |_| {
                            // TODO: Recursive call here
                            const ref = try layout.pushFlowBlock(used_box_style, sizes, stacking_context);
                            try layout.box_tree.setGeneratedBox(element, .{ .block_ref = ref });
                            try layout.pushElement();

                            const result = try flow.runFlowLayout(layout, sizes);
                            _ = layout.popFlowBlock(result.auto_height);
                            layout.popElement();

                            break :blk ref.index;
                        } else {
                            // TODO: Recursive call here
                            const ref = try layout.pushStfFlowMainBlock(used_box_style, sizes, stacking_context);
                            try layout.box_tree.setGeneratedBox(element, .{ .block_ref = ref });
                            try layout.pushElement();

                            const available_width_unclamped = ctx.containing_block_width -
                                (sizes.margin_inline_start_untagged + sizes.margin_inline_end_untagged +
                                sizes.border_inline_start + sizes.border_inline_end +
                                sizes.padding_inline_start + sizes.padding_inline_end);
                            const available_width = solve.clampSize(available_width_unclamped, sizes.min_inline_size, sizes.max_inline_size);

                            const result = try stf.runShrinkToFitLayout(layout, sizes, available_width);
                            _ = layout.popStfFlowMainBlock(result.auto_width, result.auto_height);
                            layout.popElement();

                            break :blk ref.index;
                        }
                    };

                    try ifcAddInlineBlock(layout.box_tree, ifc, index);
                },
            },
        },
        .block => {
            if (ctx.inline_box_depth == 0) {
                return true;
            } else {
                panic("TODO: Blocks within inline contexts", .{});
            }
        },
        .none => layout.advanceElement(),
        .absolute => panic("TODO: Absolute blocks within inline contexts", .{}),
    }

    return false;
}

fn ifcPopInlineBox(ctx: *InlineLayoutContext, box_tree: BoxTreeManaged, ifc: *InlineFormattingContext) !void {
    ctx.inline_box_depth -= 1;
    const inline_box_index = ctx.index.pop();
    const skip = ctx.skip.pop();
    ifc.slice().items(.skip)[inline_box_index] = skip;
    try ifcAddBoxEnd(box_tree, ifc, inline_box_index);
    ctx.skip.items[ctx.skip.items.len - 1] += skip;
}

fn ifcAddBoxStart(box_tree: BoxTreeManaged, ifc: *InlineFormattingContext, inline_box_index: InlineBoxIndex) !void {
    try box_tree.appendSpecialGlyph(ifc, .BoxStart, inline_box_index);
}

fn ifcAddBoxEnd(box_tree: BoxTreeManaged, ifc: *InlineFormattingContext, inline_box_index: InlineBoxIndex) !void {
    try box_tree.appendSpecialGlyph(ifc, .BoxEnd, inline_box_index);
}

fn ifcAddInlineBlock(box_tree: BoxTreeManaged, ifc: *InlineFormattingContext, block_box_index: Subtree.Size) !void {
    try box_tree.appendSpecialGlyph(ifc, .InlineBlock, block_box_index);
}

fn ifcAddLineBreak(box_tree: BoxTreeManaged, ifc: *InlineFormattingContext) !void {
    try box_tree.appendSpecialGlyph(ifc, .LineBreak, {});
}

fn ifcAddText(box_tree: BoxTreeManaged, ifc: *InlineFormattingContext, text: zss.values.types.Text, font: *hb.hb_font_t) !void {
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

fn ifcEndTextRun(box_tree: BoxTreeManaged, ifc: *InlineFormattingContext, text: zss.values.types.Text, buffer: *hb.hb_buffer_t, font: *hb.hb_font_t, run_begin: usize, run_end: usize) !void {
    if (run_end > run_begin) {
        hb.hb_buffer_add_latin1(buffer, text.ptr, @intCast(text.len), @intCast(run_begin), @intCast(run_end - run_begin));
        if (hb.hb_buffer_allocation_successful(buffer) == 0) return error.OutOfMemory;
        try ifcAddTextRun(box_tree, ifc, buffer, font);
        assert(hb.hb_buffer_set_length(buffer, 0) != 0);
    }
}

fn ifcAddTextRun(box_tree: BoxTreeManaged, ifc: *InlineFormattingContext, buffer: *hb.hb_buffer_t, font: *hb.hb_font_t) !void {
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

fn rootInlineBoxSetData(ifc: *const InlineFormattingContext, inline_box_index: InlineBoxIndex) void {
    const ifc_slice = ifc.slice();
    ifc_slice.items(.inline_start)[inline_box_index] = .{};
    ifc_slice.items(.inline_end)[inline_box_index] = .{};
    ifc_slice.items(.block_start)[inline_box_index] = .{};
    ifc_slice.items(.block_end)[inline_box_index] = .{};
    ifc_slice.items(.margins)[inline_box_index] = .{};
}

fn inlineBoxSetData(ctx: *InlineLayoutContext, computer: *StyleComputer, ifc: *InlineFormattingContext, inline_box_index: InlineBoxIndex) void {
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
            used.margin_inline_start = solve.percentage(value, ctx.percentage_base_unit);
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
            used.padding_inline_start = solve.positivePercentage(value, ctx.percentage_base_unit);
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
            used.margin_inline_end = solve.percentage(value, ctx.percentage_base_unit);
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
            used.padding_inline_end = solve.positivePercentage(value, ctx.percentage_base_unit);
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
            used.padding_block_start = solve.positivePercentage(value, ctx.percentage_base_unit);
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
            used.padding_block_end = solve.positivePercentage(value, ctx.percentage_base_unit);
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }

    computed.vertical_edges.margin_top = specified.vertical_edges.margin_top;
    computed.vertical_edges.margin_bottom = specified.vertical_edges.margin_bottom;

    computer.setComputedValue(.box_gen, .horizontal_edges, computed.horizontal_edges);
    computer.setComputedValue(.box_gen, .vertical_edges, computed.vertical_edges);
    computer.setComputedValue(.box_gen, .border_styles, specified.border_styles);

    const ifc_slice = ifc.slice();
    ifc_slice.items(.inline_start)[inline_box_index] = .{ .border = used.border_inline_start, .padding = used.padding_inline_start };
    ifc_slice.items(.inline_end)[inline_box_index] = .{ .border = used.border_inline_end, .padding = used.padding_inline_end };
    ifc_slice.items(.block_start)[inline_box_index] = .{ .border = used.border_block_start, .padding = used.padding_block_start };
    ifc_slice.items(.block_end)[inline_box_index] = .{ .border = used.border_block_end, .padding = used.padding_block_end };
    ifc_slice.items(.margins)[inline_box_index] = .{ .start = used.margin_inline_start, .end = used.margin_inline_end };
}

fn inlineBlockSolveSizes(
    computer: *StyleComputer,
    position: BoxTree.BoxStyle.Position,
    containing_block_width: Unit,
    containing_block_height: ?Unit,
) BlockUsedSizes {
    assert(containing_block_width >= 0);
    if (containing_block_height) |h| assert(h >= 0);

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
            used.padding_inline_start = solve.positivePercentage(value, containing_block_width);
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
            used.padding_inline_end = solve.positivePercentage(value, containing_block_width);
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
            used.setValue(.margin_inline_start, solve.percentage(value, containing_block_width));
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
            used.setValue(.margin_inline_end, solve.percentage(value, containing_block_width));
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
            used.min_inline_size = solve.positivePercentage(value, containing_block_width);
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
            used.max_inline_size = solve.positivePercentage(value, containing_block_width);
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
            used.setValue(.inline_size, solve.positivePercentage(value, containing_block_width));
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
            used.padding_block_start = solve.positivePercentage(value, containing_block_width);
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
            used.padding_block_end = solve.positivePercentage(value, containing_block_width);
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
            used.margin_block_start = solve.percentage(value, containing_block_width);
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
            used.margin_block_end = solve.percentage(value, containing_block_width);
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
            used.min_block_size = if (containing_block_height) |h|
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
            used.max_block_size = if (containing_block_height) |h|
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
            if (containing_block_height) |h|
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

fn inlineBlockCreateStackingContext(
    computer: *StyleComputer,
    position: zss.values.types.Position,
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
        .absolute, .fixed, .sticky => panic("TODO: {s} positioning", .{@tagName(position)}),
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
}

fn ifcSolveMetrics(ifc: *InlineFormattingContext, subtree: Subtree.View, fonts: *const Fonts) void {
    const font = fonts.get(ifc.font);
    const ifc_slice = ifc.slice();

    const num_glyphs = ifc.glyph_indeces.items.len;
    var i: usize = 0;
    while (i < num_glyphs) : (i += 1) {
        const glyph_index = ifc.glyph_indeces.items[i];
        const metrics = &ifc.metrics.items[i];

        if (glyph_index == 0) {
            i += 1;
            const special = InlineFormattingContext.Special.decode(ifc.glyph_indeces.items[i]);
            const kind = @as(std.meta.Tag(BoxTreeManaged.SpecialGlyph), @enumFromInt(@intFromEnum(special.kind)));
            switch (kind) {
                .Reserved => unreachable,
                .ZeroGlyphIndex => setMetricsGlyph(metrics, font.?.handle, 0),
                .BoxStart => {
                    const inline_box_index = @as(InlineBoxIndex, special.data);
                    setMetricsBoxStart(metrics, ifc_slice, inline_box_index);
                },
                .BoxEnd => {
                    const inline_box_index = @as(InlineBoxIndex, special.data);
                    setMetricsBoxEnd(metrics, ifc_slice, inline_box_index);
                },
                .InlineBlock => {
                    const block_box_index = @as(Subtree.Size, special.data);
                    setMetricsInlineBlock(metrics, subtree, block_box_index);
                },
                .LineBreak => setMetricsLineBreak(metrics),
                .ContinuationBlock => panic("TODO: Continuation block metrics", .{}),
            }
        } else {
            setMetricsGlyph(metrics, font.?.handle, glyph_index);
        }
    }
}

fn setMetricsGlyph(metrics: *InlineFormattingContext.Metrics, font: *hb.hb_font_t, glyph_index: GlyphIndex) void {
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

fn setMetricsBoxStart(metrics: *InlineFormattingContext.Metrics, ifc_slice: InlineFormattingContext.Slice, inline_box_index: InlineBoxIndex) void {
    const inline_start = ifc_slice.items(.inline_start)[inline_box_index];
    const margin = ifc_slice.items(.margins)[inline_box_index].start;
    const width = inline_start.border + inline_start.padding;
    const advance = width + margin;
    metrics.* = .{ .offset = margin, .advance = advance, .width = width };
}

fn setMetricsBoxEnd(metrics: *InlineFormattingContext.Metrics, ifc_slice: InlineFormattingContext.Slice, inline_box_index: InlineBoxIndex) void {
    const inline_end = ifc_slice.items(.inline_end)[inline_box_index];
    const margin = ifc_slice.items(.margins)[inline_box_index].end;
    const width = inline_end.border + inline_end.padding;
    const advance = width + margin;
    metrics.* = .{ .offset = 0, .advance = advance, .width = width };
}

fn setMetricsLineBreak(metrics: *InlineFormattingContext.Metrics) void {
    metrics.* = .{ .offset = 0, .advance = 0, .width = 0 };
}

fn setMetricsInlineBlock(metrics: *InlineFormattingContext.Metrics, subtree: Subtree.View, block_box_index: Subtree.Size) void {
    const box_offsets = subtree.items(.box_offsets)[block_box_index];
    const margins = subtree.items(.margins)[block_box_index];

    const width = box_offsets.border_size.w;
    const advance = width + margins.left + margins.right;
    metrics.* = .{ .offset = margins.left, .advance = advance, .width = width };
}

const IFCLineSplitState = struct {
    cursor: Unit,
    line_box: InlineFormattingContext.LineBox,
    inline_blocks_in_this_line_box: ArrayListUnmanaged(InlineBlockInfo),
    top_height: Unit,
    max_top_height: Unit,
    bottom_height: Unit,
    longest_line_box_length: Unit,
    inline_box_stack: ArrayListUnmanaged(InlineBoxIndex) = .{},
    current_inline_box: InlineBoxIndex = undefined,

    const InlineBlockInfo = struct {
        box_offsets: *BoxTree.BoxOffsets,
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
            const offset_x = info.cursor;
            const offset_y = self.line_box.baseline - info.height;
            info.box_offsets.border_pos.x += offset_x;
            info.box_offsets.border_pos.y += offset_y;
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

    fn pushInlineBox(self: *IFCLineSplitState, allocator: Allocator, index: InlineBoxIndex) !void {
        if (index != 0) {
            try self.inline_box_stack.append(allocator, self.current_inline_box);
        }
        self.current_inline_box = index;
    }

    fn popInlineBox(self: *IFCLineSplitState, index: InlineBoxIndex) void {
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
    ifc: *InlineFormattingContext,
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

    {
        const gi = ifc.glyph_indeces.items[0];
        assert(gi == 0);
        const special = InlineFormattingContext.Special.decode(ifc.glyph_indeces.items[1]);
        assert(special.kind == .BoxStart);
        assert(@as(InlineBoxIndex, special.data) == 0);
        s.pushInlineBox(layout.allocator, 0) catch unreachable;
        s.line_box.elements[1] = 2;
        s.line_box.inline_box = null;
    }

    var i: usize = 2;
    while (i < ifc.glyph_indeces.items.len) : (i += 1) {
        const gi = ifc.glyph_indeces.items[i];
        const metrics = ifc.metrics.items[i];

        if (gi == 0) {
            i += 1;
            const special = InlineFormattingContext.Special.decode(ifc.glyph_indeces.items[i]);
            switch (@as(std.meta.Tag(BoxTreeManaged.SpecialGlyph), @enumFromInt(@intFromEnum(special.kind)))) {
                .Reserved => unreachable,
                .BoxStart => try s.pushInlineBox(layout.allocator, @as(InlineBoxIndex, special.data)),
                .BoxEnd => s.popInlineBox(@as(InlineBoxIndex, special.data)),
                .LineBreak => {
                    s.finishLineBox();
                    try layout.box_tree.appendLineBox(ifc, s.line_box);
                    s.newLineBox(2);
                    continue;
                },
                .ContinuationBlock => panic("TODO: Continuation blocks", .{}),
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
            const special = InlineFormattingContext.Special.decode(ifc.glyph_indeces.items[i]);
            switch (@as(std.meta.Tag(BoxTreeManaged.SpecialGlyph), @enumFromInt(@intFromEnum(special.kind)))) {
                .Reserved => unreachable,
                .InlineBlock => {
                    const block_box_index = @as(Subtree.Size, special.data);
                    const box_offsets = &subtree.items(.box_offsets)[block_box_index];
                    const margins = subtree.items(.margins)[block_box_index];
                    const margin_box_height = box_offsets.border_size.h + margins.top + margins.bottom;
                    s.max_top_height = @max(s.max_top_height, margin_box_height);
                    try s.inline_blocks_in_this_line_box.append(
                        layout.allocator,
                        .{ .box_offsets = box_offsets, .cursor = s.cursor, .height = margin_box_height - margins.top },
                    );
                },
                .LineBreak => unreachable,
                .ContinuationBlock => panic("TODO: Continuation blocks", .{}),
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
