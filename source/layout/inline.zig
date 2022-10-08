const std = @import("std");
const assert = std.debug.assert;
const panic = std.debug.panic;
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

const zss = @import("../../zss.zig");
const StyleComputer = @import("./StyleComputer.zig");

const normal = @import("./normal.zig");
const FlowBlockComputedSizes = normal.FlowBlockComputedSizes;
const FlowBlockUsedSizes = normal.FlowBlockUsedSizes;

const stf = @import("./shrink_to_fit.zig");

const solve = @import("./solve.zig");
const StackingContexts = @import("./StackingContexts.zig");

const used_values = @import("./used_values.zig");
const ZssUnit = used_values.ZssUnit;
const ZssVector = used_values.ZssVector;
const units_per_pixel = used_values.units_per_pixel;
const BlockBoxIndex = used_values.BlockBoxIndex;
const BlockBox = used_values.BlockBox;
const BlockBoxSkip = used_values.BlockBoxSkip;
const BlockSubtree = BlockBoxTree.Subtree;
const BlockSubtreeIndex = used_values.SubtreeIndex;
const BlockBoxTree = used_values.BlockBoxTree;
const StackingContextIndex = used_values.StackingContextIndex;
const InlineBoxIndex = used_values.InlineBoxIndex;
const InlineFormattingContext = used_values.InlineFormattingContext;
const InlineFormattingContextIndex = used_values.InlineFormattingContextIndex;
const GlyphIndex = InlineFormattingContext.GlyphIndex;
const GeneratedBox = used_values.GeneratedBox;
const BoxTree = used_values.BoxTree;

const hb = @import("harfbuzz");

pub const InlineLayoutContext = struct {
    const Self = @This();

    allocator: Allocator,
    containing_block_width: ZssUnit,
    containing_block_height: ?ZssUnit,
    percentage_base_unit: ZssUnit,

    inline_box_depth: InlineBoxIndex = 0,
    index: ArrayListUnmanaged(InlineBoxIndex) = .{},
    mainLoop_frame: ?*@Frame(normal.mainLoop) = null,

    result: Result,

    pub const Result = struct {
        ifc_index: InlineFormattingContextIndex,
        subtree_root_skip: BlockBoxSkip = 1,
    };

    pub fn deinit(self: *Self) void {
        self.index.deinit(self.allocator);
        if (self.mainLoop_frame) |frame| {
            self.allocator.destroy(frame);
        }
    }

    fn getFrame(self: *Self) !*@Frame(normal.mainLoop) {
        if (self.mainLoop_frame == null) {
            self.mainLoop_frame = try self.allocator.create(@Frame(normal.mainLoop));
        }
        return self.mainLoop_frame.?;
    }
};

fn createInlineBox(box_tree: *BoxTree, ifc: *InlineFormattingContext) !InlineBoxIndex {
    const old_size = ifc.inline_start.items.len;
    _ = try ifc.inline_start.addOne(box_tree.allocator);
    _ = try ifc.inline_end.addOne(box_tree.allocator);
    _ = try ifc.block_start.addOne(box_tree.allocator);
    _ = try ifc.block_end.addOne(box_tree.allocator);
    _ = try ifc.margins.addOne(box_tree.allocator);
    return @intCast(InlineBoxIndex, old_size);
}

pub fn makeInlineFormattingContext(
    allocator: Allocator,
    sc: *StackingContexts,
    computer: *StyleComputer,
    box_tree: *BoxTree,
    mode: enum { Normal, ShrinkToFit },
    containing_block_width: ZssUnit,
    containing_block_height: ?ZssUnit,
) zss.layout.Error!InlineLayoutContext.Result {
    assert(containing_block_width >= 0);
    assert(if (containing_block_height) |h| h >= 0 else true);

    const subtree_index = std.math.cast(BlockSubtreeIndex, box_tree.blocks.subtrees.items.len) orelse return error.TooManyBlockSubtrees;
    const subtree = try box_tree.blocks.subtrees.addOne(box_tree.allocator);
    subtree.* = .{};
    const block = try normal.createBlock(box_tree, subtree);
    block.properties.* = .{ .contents = true };
    block.borders.* = .{};
    block.margins.* = .{};

    const ifc_index = std.math.cast(InlineFormattingContextIndex, box_tree.ifcs.items.len) orelse return error.TooManyIfcs;
    const ifc = ifc: {
        const result_ptr = try box_tree.ifcs.addOne(box_tree.allocator);
        errdefer _ = box_tree.ifcs.pop();
        const result = try box_tree.allocator.create(InlineFormattingContext);
        errdefer box_tree.allocator.destroy(result);
        result.* = .{ .parent_block = undefined, .origin = undefined, .subtree_index = subtree_index };
        errdefer result.deinit(box_tree.allocator);
        result_ptr.* = result;
        break :ifc result;
    };

    const sc_ifcs = &box_tree.stacking_contexts.multi_list.items(.ifcs)[sc.current];
    try sc_ifcs.append(box_tree.allocator, ifc_index);

    const percentage_base_unit: ZssUnit = switch (mode) {
        .Normal => containing_block_width,
        .ShrinkToFit => 0,
    };

    var inline_layout = InlineLayoutContext{
        .allocator = allocator,
        .containing_block_width = containing_block_width,
        .containing_block_height = containing_block_height,
        .percentage_base_unit = percentage_base_unit,
        .result = .{
            .ifc_index = ifc_index,
        },
    };
    defer inline_layout.deinit();

    try createInlineFormattingContext(&inline_layout, sc, computer, box_tree, ifc);
    box_tree.blocks.subtrees.items[subtree_index].skips.items[0] = inline_layout.result.subtree_root_skip;

    return inline_layout.result;
}

fn createInlineFormattingContext(
    layout: *InlineLayoutContext,
    sc: *StackingContexts,
    computer: *StyleComputer,
    box_tree: *BoxTree,
    ifc: *InlineFormattingContext,
) !void {
    ifc.font = computer.root_font.font;
    {
        const initial_interval = computer.intervals.items[computer.intervals.items.len - 1];
        ifc.ensureTotalCapacity(box_tree.allocator, initial_interval.end - initial_interval.begin + 1) catch {};
    }

    try ifcPushRootInlineBox(layout, box_tree, ifc);
    while (true) {
        const interval = &computer.intervals.items[computer.intervals.items.len - 1];
        if (layout.inline_box_depth == 0) {
            if (interval.begin != interval.end) {
                const should_terminate = try ifcRunOnce(layout, sc, computer, interval, box_tree, ifc);
                if (should_terminate) break;
            } else break;
        } else {
            if (interval.begin != interval.end) {
                const should_terminate = try ifcRunOnce(layout, sc, computer, interval, box_tree, ifc);
                assert(!should_terminate);
            } else {
                try ifcPopInlineBox(layout, computer, box_tree, ifc);
            }
        }
    }
    try ifcPopRootInlineBox(layout, box_tree, ifc);

    try ifc.metrics.resize(box_tree.allocator, ifc.glyph_indeces.items.len);
    const subtree = &box_tree.blocks.subtrees.items[ifc.subtree_index];
    ifcSolveMetrics(ifc, subtree);
}

fn ifcPushRootInlineBox(layout: *InlineLayoutContext, box_tree: *BoxTree, ifc: *InlineFormattingContext) !void {
    assert(layout.inline_box_depth == 0);
    const root_inline_box_index = try createInlineBox(box_tree, ifc);
    rootInlineBoxSetData(ifc, root_inline_box_index);
    try ifcAddBoxStart(box_tree, ifc, root_inline_box_index);
    try layout.index.append(layout.allocator, root_inline_box_index);
}

fn ifcPopRootInlineBox(layout: *InlineLayoutContext, box_tree: *BoxTree, ifc: *InlineFormattingContext) !void {
    assert(layout.inline_box_depth == 0);
    const root_inline_box_index = layout.index.pop();
    try ifcAddBoxEnd(box_tree, ifc, root_inline_box_index);
}

/// A return value of true means that a terminating element was encountered.
fn ifcRunOnce(
    layout: *InlineLayoutContext,
    sc: *StackingContexts,
    computer: *StyleComputer,
    interval: *StyleComputer.Interval,
    box_tree: *BoxTree,
    ifc: *InlineFormattingContext,
) !bool {
    const element = interval.begin;
    const skip = computer.element_tree_skips[element];

    computer.setElementDirectChild(.box_gen, element);
    const specified = computer.getSpecifiedValue(.box_gen, .box_style);
    const computed = solve.boxStyle(specified, .NonRoot);
    // TODO: Check position and float properties
    switch (computed.display) {
        .text => {
            assert(skip == 1);
            interval.begin += skip;
            box_tree.element_index_to_generated_box[element] = .text;
            const text = computer.getText();
            // TODO: Do proper font matching.
            if (ifc.font == hb.hb_font_get_empty()) panic("TODO: Found text, but no font was specified.", .{});
            try ifcAddText(box_tree, ifc, text, ifc.font);
        },
        .inline_ => {
            interval.begin += skip;
            const inline_box_index = try createInlineBox(box_tree, ifc);
            try inlineBoxSetData(layout, computer, ifc, inline_box_index);

            box_tree.element_index_to_generated_box[element] = .{ .inline_box = .{ .ifc_index = layout.result.ifc_index, .index = inline_box_index } };
            computer.setComputedValue(.box_gen, .box_style, computed);
            { // TODO: Grabbing useless data to satisfy inheritance...
                const data = .{
                    .content_width = computer.getSpecifiedValue(.box_gen, .content_width),
                    .content_height = computer.getSpecifiedValue(.box_gen, .content_height),
                    .z_index = computer.getSpecifiedValue(.box_gen, .z_index),
                    .font = computer.getSpecifiedValue(.box_gen, .font),
                };
                computer.setComputedValue(.box_gen, .content_width, data.content_width);
                computer.setComputedValue(.box_gen, .content_height, data.content_height);
                computer.setComputedValue(.box_gen, .z_index, data.z_index);
                computer.setComputedValue(.box_gen, .font, data.font);
            }

            try ifcAddBoxStart(box_tree, ifc, inline_box_index);

            if (skip != 1) {
                layout.inline_box_depth += 1;
                try layout.index.append(layout.allocator, inline_box_index);
                try computer.pushElement(.box_gen);
            } else {
                // Optimized path for inline boxes with no children.
                // It is a shorter version of ifcPopInlineBox.
                try ifcAddBoxEnd(box_tree, ifc, inline_box_index);
            }
        },
        .inline_block => {
            interval.begin += skip;
            computer.setComputedValue(.box_gen, .box_style, computed);
            const used_sizes = try inlineBlockSolveSizes(
                computer,
                layout.containing_block_width,
                layout.containing_block_height,
            );
            const subtree = &box_tree.blocks.subtrees.items[ifc.subtree_index];

            if (!used_sizes.isFieldAuto(.inline_size)) {
                const z_index = computer.getSpecifiedValue(.box_gen, .z_index);
                computer.setComputedValue(.box_gen, .z_index, z_index);
                // TODO: Grabbing useless data to satisfy inheritance...
                const font = computer.getSpecifiedValue(.box_gen, .font);
                computer.setComputedValue(.box_gen, .font, font);
                try computer.pushElement(.box_gen);

                const block = try normal.createBlock(box_tree, subtree);
                block.skip.* = undefined;
                block.properties.* = .{};
                normal.flowBlockSetData(used_sizes, block.box_offsets, block.borders, block.margins);

                const block_box = BlockBox{ .subtree = ifc.subtree_index, .index = block.index };

                const stacking_context_type: StackingContexts.Data = switch (computed.position) {
                    .static => StackingContexts.Data{ .is_non_parent = try sc.createStackingContext(box_tree, block_box, 0) },
                    // TODO: Position the block using the values of the 'inset' family of properties.
                    .relative => switch (z_index.z_index) {
                        .integer => |integer| StackingContexts.Data{ .is_parent = try sc.createStackingContext(box_tree, block_box, integer) },
                        .auto => StackingContexts.Data{ .is_non_parent = try sc.createStackingContext(box_tree, block_box, 0) },
                        .initial, .inherit, .unset, .undeclared => unreachable,
                    },
                    .absolute, .fixed, .sticky => panic("TODO: {s} positioning", .{@tagName(computed.position)}),
                    .initial, .inherit, .unset, .undeclared => unreachable,
                };
                try sc.pushStackingContext(stacking_context_type);

                var child_layout = normal.BlockLayoutContext{ .allocator = layout.allocator };
                defer child_layout.deinit();
                try normal.pushContainingBlock(&child_layout, layout.containing_block_width, layout.containing_block_height);
                try normal.pushFlowBlock(&child_layout, ifc.subtree_index, block.index, used_sizes);

                const frame = try layout.getFrame();
                nosuspend {
                    frame.* = async normal.mainLoop(&child_layout, sc, computer, box_tree);
                    try await frame.*;
                }

                box_tree.element_index_to_generated_box[element] = .{ .block_box = block_box };
            } else {
                // TODO: Create a stacking context
                { // TODO: Grabbing useless data to satisfy inheritance...
                    const specified_z_index = computer.getSpecifiedValue(.box_gen, .z_index);
                    computer.setComputedValue(.box_gen, .z_index, specified_z_index);
                    const specified_font = computer.getSpecifiedValue(.box_gen, .font);
                    computer.setComputedValue(.box_gen, .font, specified_font);
                }
                try computer.pushElement(.box_gen);

                // TODO: This value should be either clamped or maximized
                const available_width = layout.containing_block_width -
                    (used_sizes.margin_inline_start_untagged + used_sizes.margin_inline_end_untagged +
                    used_sizes.border_inline_start + used_sizes.border_inline_end +
                    used_sizes.padding_inline_start + used_sizes.padding_inline_end);
                var stf_layout = try stf.ShrinkToFitLayoutContext.initFlow(layout.allocator, computer, element, used_sizes, available_width);
                defer stf_layout.deinit();
                try stf.shrinkToFitLayout(&stf_layout, sc, computer, box_tree, ifc.subtree_index);
            }

            const generated_box = box_tree.element_index_to_generated_box[element];
            const block_box = generated_box.block_box;
            if (block_box.subtree == ifc.subtree_index) {
                layout.result.subtree_root_skip += box_tree.blocks.subtrees.items[block_box.subtree].skips.items[block_box.index];
            } else {
                panic("TODO: Inline block in a different subtree than parent IFC", .{});
            }
            try ifcAddInlineBlock(box_tree, ifc, block_box.index);
        },
        .block => {
            if (layout.inline_box_depth == 0) {
                return true;
            } else {
                panic("TODO: Blocks within inline contexts", .{});
                //try ifc.glyph_indeces.appendSlice(box_tree.allocator, &.{ 0, undefined });
            }
        },
        .none => {
            interval.begin += skip;
            std.mem.set(GeneratedBox, box_tree.element_index_to_generated_box[element .. element + skip], .none);
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }

    return false;
}

fn ifcPopInlineBox(layout: *InlineLayoutContext, computer: *StyleComputer, box_tree: *BoxTree, ifc: *InlineFormattingContext) !void {
    layout.inline_box_depth -= 1;
    const inline_box_index = layout.index.pop();
    try ifcAddBoxEnd(box_tree, ifc, inline_box_index);
    computer.popElement(.box_gen);
}

fn ifcAddBoxStart(box_tree: *BoxTree, ifc: *InlineFormattingContext, inline_box_index: InlineBoxIndex) !void {
    const glyphs = [2]GlyphIndex{ 0, InlineFormattingContext.Special.encodeBoxStart(inline_box_index) };
    try ifc.glyph_indeces.appendSlice(box_tree.allocator, &glyphs);
}

fn ifcAddBoxEnd(box_tree: *BoxTree, ifc: *InlineFormattingContext, inline_box_index: InlineBoxIndex) !void {
    const glyphs = [2]GlyphIndex{ 0, InlineFormattingContext.Special.encodeBoxEnd(inline_box_index) };
    try ifc.glyph_indeces.appendSlice(box_tree.allocator, &glyphs);
}

fn ifcAddInlineBlock(box_tree: *BoxTree, ifc: *InlineFormattingContext, block_box_index: BlockBoxIndex) !void {
    const glyphs = [2]GlyphIndex{ 0, InlineFormattingContext.Special.encodeInlineBlock(block_box_index) };
    try ifc.glyph_indeces.appendSlice(box_tree.allocator, &glyphs);
}

fn ifcAddLineBreak(box_tree: *BoxTree, ifc: *InlineFormattingContext) !void {
    const glyphs = [2]GlyphIndex{ 0, InlineFormattingContext.Special.encodeLineBreak() };
    try ifc.glyph_indeces.appendSlice(box_tree.allocator, &glyphs);
}

fn ifcAddText(box_tree: *BoxTree, ifc: *InlineFormattingContext, text: zss.values.Text, font: *hb.hb_font_t) !void {
    const buffer = hb.hb_buffer_create() orelse unreachable;
    defer hb.hb_buffer_destroy(buffer);
    _ = hb.hb_buffer_pre_allocate(buffer, @intCast(c_uint, text.len));
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
                run_end += @boolToInt(run_end + 1 < text.len and text[run_end + 1] == '\n');
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

fn ifcEndTextRun(box_tree: *BoxTree, ifc: *InlineFormattingContext, text: zss.values.Text, buffer: *hb.hb_buffer_t, font: *hb.hb_font_t, run_begin: usize, run_end: usize) !void {
    if (run_end > run_begin) {
        hb.hb_buffer_add_latin1(buffer, text.ptr, @intCast(c_int, text.len), @intCast(c_uint, run_begin), @intCast(c_int, run_end - run_begin));
        if (hb.hb_buffer_allocation_successful(buffer) == 0) return error.OutOfMemory;
        try ifcAddTextRun(box_tree, ifc, buffer, font);
        assert(hb.hb_buffer_set_length(buffer, 0) != 0);
    }
}

fn ifcAddTextRun(box_tree: *BoxTree, ifc: *InlineFormattingContext, buffer: *hb.hb_buffer_t, font: *hb.hb_font_t) !void {
    hb.hb_shape(font, buffer, null, 0);
    const glyph_infos = blk: {
        var n: c_uint = 0;
        const p = hb.hb_buffer_get_glyph_infos(buffer, &n);
        break :blk p[0..n];
    };

    // Allocate twice as much so that special glyph indeces always have space
    try ifc.glyph_indeces.ensureUnusedCapacity(box_tree.allocator, 2 * glyph_infos.len);

    for (glyph_infos) |info| {
        const glyph_index: GlyphIndex = info.codepoint;
        ifc.glyph_indeces.appendAssumeCapacity(glyph_index);
        if (glyph_index == 0) {
            ifc.glyph_indeces.appendAssumeCapacity(InlineFormattingContext.Special.encodeZeroGlyphIndex());
        }
    }
}

fn rootInlineBoxSetData(ifc: *InlineFormattingContext, inline_box_index: InlineBoxIndex) void {
    ifc.inline_start.items[inline_box_index] = .{ .border = 0, .padding = 0, .border_color_rgba = 0 };
    ifc.inline_end.items[inline_box_index] = .{ .border = 0, .padding = 0, .border_color_rgba = 0 };
    ifc.block_start.items[inline_box_index] = .{ .border = 0, .padding = 0, .border_color_rgba = 0 };
    ifc.block_end.items[inline_box_index] = .{ .border = 0, .padding = 0, .border_color_rgba = 0 };
    ifc.margins.items[inline_box_index] = .{ .start = 0, .end = 0 };
}

fn inlineBoxSetData(layout: *InlineLayoutContext, computer: *StyleComputer, ifc: *InlineFormattingContext, inline_box_index: InlineBoxIndex) !void {
    // TODO: Also use the logical properties ('padding-inline-start', 'border-block-end', etc.).
    const specified = .{
        .horizontal_edges = computer.getSpecifiedValue(.box_gen, .horizontal_edges),
        .vertical_edges = computer.getSpecifiedValue(.box_gen, .vertical_edges),
        .border_styles = computer.getSpecifiedValue(.box_gen, .border_styles),
    };

    var computed: struct {
        horizontal_edges: zss.properties.BoxEdges,
        vertical_edges: zss.properties.BoxEdges,
    } = undefined;

    var used: struct {
        margin_inline_start: ZssUnit,
        border_inline_start: ZssUnit,
        padding_inline_start: ZssUnit,
        margin_inline_end: ZssUnit,
        border_inline_end: ZssUnit,
        padding_inline_end: ZssUnit,
        border_block_start: ZssUnit,
        padding_block_start: ZssUnit,
        border_block_end: ZssUnit,
        padding_block_end: ZssUnit,
    } = undefined;

    switch (specified.horizontal_edges.margin_start) {
        .px => |value| {
            computed.horizontal_edges.margin_start = .{ .px = value };
            used.margin_inline_start = solve.length(.px, value);
        },
        .percentage => |value| {
            computed.horizontal_edges.margin_start = .{ .percentage = value };
            used.margin_inline_start = solve.percentage(value, layout.percentage_base_unit);
        },
        .auto => {
            computed.horizontal_edges.margin_start = .auto;
            used.margin_inline_start = 0;
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
    {
        const multiplier = solve.borderWidthMultiplier(specified.border_styles.left);
        switch (specified.horizontal_edges.border_start) {
            .px => |value| {
                const width = value * multiplier;
                computed.horizontal_edges.border_start = .{ .px = width };
                used.border_inline_start = try solve.positiveLength(.px, width);
            },
            .thin => {
                const width = solve.borderWidth(.thin) * multiplier;
                computed.horizontal_edges.border_start = .{ .px = width };
                used.border_inline_start = solve.positiveLength(.px, width) catch unreachable;
            },
            .medium => {
                const width = solve.borderWidth(.medium) * multiplier;
                computed.horizontal_edges.border_start = .{ .px = width };
                used.border_inline_start = solve.positiveLength(.px, width) catch unreachable;
            },
            .thick => {
                const width = solve.borderWidth(.thick) * multiplier;
                computed.horizontal_edges.border_start = .{ .px = width };
                used.border_inline_start = solve.positiveLength(.px, width) catch unreachable;
            },
            .initial, .inherit, .unset, .undeclared => unreachable,
        }
    }
    switch (specified.horizontal_edges.padding_start) {
        .px => |value| {
            computed.horizontal_edges.padding_start = .{ .px = value };
            used.padding_inline_start = try solve.positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.horizontal_edges.padding_start = .{ .percentage = value };
            used.padding_inline_start = try solve.positivePercentage(value, layout.percentage_base_unit);
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
    switch (specified.horizontal_edges.margin_end) {
        .px => |value| {
            computed.horizontal_edges.margin_end = .{ .px = value };
            used.margin_inline_end = solve.length(.px, value);
        },
        .percentage => |value| {
            computed.horizontal_edges.margin_end = .{ .percentage = value };
            used.margin_inline_end = solve.percentage(value, layout.percentage_base_unit);
        },
        .auto => {
            computed.horizontal_edges.margin_end = .auto;
            used.margin_inline_end = 0;
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
    {
        const multiplier = solve.borderWidthMultiplier(specified.border_styles.right);
        switch (specified.horizontal_edges.border_end) {
            .px => |value| {
                const width = value * multiplier;
                computed.horizontal_edges.border_end = .{ .px = width };
                used.border_inline_end = try solve.positiveLength(.px, width);
            },
            .thin => {
                const width = solve.borderWidth(.thin) * multiplier;
                computed.horizontal_edges.border_end = .{ .px = width };
                used.border_inline_end = solve.positiveLength(.px, width) catch unreachable;
            },
            .medium => {
                const width = solve.borderWidth(.medium) * multiplier;
                computed.horizontal_edges.border_end = .{ .px = width };
                used.border_inline_end = solve.positiveLength(.px, width) catch unreachable;
            },
            .thick => {
                const width = solve.borderWidth(.thick) * multiplier;
                computed.horizontal_edges.border_end = .{ .px = width };
                used.border_inline_end = solve.positiveLength(.px, width) catch unreachable;
            },
            .initial, .inherit, .unset, .undeclared => unreachable,
        }
    }
    switch (specified.horizontal_edges.padding_end) {
        .px => |value| {
            computed.horizontal_edges.padding_end = .{ .px = value };
            used.padding_inline_end = try solve.positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.horizontal_edges.padding_end = .{ .percentage = value };
            used.padding_inline_end = try solve.positivePercentage(value, layout.percentage_base_unit);
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }

    {
        const multiplier = solve.borderWidthMultiplier(specified.border_styles.top);
        switch (specified.vertical_edges.border_start) {
            .px => |value| {
                const width = value * multiplier;
                computed.vertical_edges.border_start = .{ .px = width };
                used.border_block_start = try solve.positiveLength(.px, width);
            },
            .thin => {
                const width = solve.borderWidth(.thin) * multiplier;
                computed.vertical_edges.border_start = .{ .px = width };
                used.border_block_start = solve.positiveLength(.px, width) catch unreachable;
            },
            .medium => {
                const width = solve.borderWidth(.medium) * multiplier;
                computed.vertical_edges.border_start = .{ .px = width };
                used.border_block_start = solve.positiveLength(.px, width) catch unreachable;
            },
            .thick => {
                const width = solve.borderWidth(.thick) * multiplier;
                computed.vertical_edges.border_start = .{ .px = width };
                used.border_block_start = solve.positiveLength(.px, width) catch unreachable;
            },
            .initial, .inherit, .unset, .undeclared => unreachable,
        }
    }
    switch (specified.vertical_edges.padding_start) {
        .px => |value| {
            computed.vertical_edges.padding_start = .{ .px = value };
            used.padding_block_start = try solve.positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.vertical_edges.padding_start = .{ .percentage = value };
            used.padding_block_start = try solve.positivePercentage(value, layout.percentage_base_unit);
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
    {
        const multiplier = solve.borderWidthMultiplier(specified.border_styles.bottom);
        switch (specified.vertical_edges.border_end) {
            .px => |value| {
                const width = value * multiplier;
                computed.vertical_edges.border_end = .{ .px = width };
                used.border_block_end = try solve.positiveLength(.px, width);
            },
            .thin => {
                const width = solve.borderWidth(.thin) * multiplier;
                computed.vertical_edges.border_end = .{ .px = width };
                used.border_block_end = solve.positiveLength(.px, width) catch unreachable;
            },
            .medium => {
                const width = solve.borderWidth(.medium) * multiplier;
                computed.vertical_edges.border_end = .{ .px = width };
                used.border_block_end = solve.positiveLength(.px, width) catch unreachable;
            },
            .thick => {
                const width = solve.borderWidth(.thick) * multiplier;
                computed.vertical_edges.border_end = .{ .px = width };
                used.border_block_end = solve.positiveLength(.px, width) catch unreachable;
            },
            .initial, .inherit, .unset, .undeclared => unreachable,
        }
    }
    switch (specified.vertical_edges.padding_end) {
        .px => |value| {
            computed.vertical_edges.padding_end = .{ .px = value };
            used.padding_block_end = try solve.positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.vertical_edges.padding_end = .{ .percentage = value };
            used.padding_block_end = try solve.positivePercentage(value, layout.percentage_base_unit);
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }

    computed.vertical_edges.margin_start = specified.vertical_edges.margin_start;
    computed.vertical_edges.margin_end = specified.vertical_edges.margin_end;

    computer.setComputedValue(.box_gen, .horizontal_edges, computed.horizontal_edges);
    computer.setComputedValue(.box_gen, .vertical_edges, computed.vertical_edges);
    computer.setComputedValue(.box_gen, .border_styles, specified.border_styles);

    ifc.inline_start.items[inline_box_index] = .{ .border = used.border_inline_start, .padding = used.padding_inline_start };
    ifc.inline_end.items[inline_box_index] = .{ .border = used.border_inline_end, .padding = used.padding_inline_end };
    ifc.block_start.items[inline_box_index] = .{ .border = used.border_block_start, .padding = used.padding_block_start };
    ifc.block_end.items[inline_box_index] = .{ .border = used.border_block_end, .padding = used.padding_block_end };
    ifc.margins.items[inline_box_index] = .{ .start = used.margin_inline_start, .end = used.margin_inline_end };
}

fn inlineBlockSolveSizes(
    computer: *StyleComputer,
    containing_block_width: ZssUnit,
    containing_block_height: ?ZssUnit,
) !FlowBlockUsedSizes {
    assert(containing_block_width >= 0);
    if (containing_block_height) |h| assert(h >= 0);

    const specified = FlowBlockComputedSizes{
        .content_width = computer.getSpecifiedValue(.box_gen, .content_width),
        .horizontal_edges = computer.getSpecifiedValue(.box_gen, .horizontal_edges),
        .content_height = computer.getSpecifiedValue(.box_gen, .content_height),
        .vertical_edges = computer.getSpecifiedValue(.box_gen, .vertical_edges),
    };
    const border_styles = computer.getSpecifiedValue(.box_gen, .border_styles);
    var computed: FlowBlockComputedSizes = undefined;
    var used: FlowBlockUsedSizes = undefined;

    // TODO: Also use the logical properties ('padding-inline-start', 'border-block-end', etc.).

    {
        const multiplier = solve.borderWidthMultiplier(border_styles.left);
        switch (specified.horizontal_edges.border_start) {
            .px => |value| {
                const width = value * multiplier;
                computed.horizontal_edges.border_start = .{ .px = width };
                used.border_inline_start = try solve.positiveLength(.px, width);
            },
            .thin => {
                const width = solve.borderWidth(.thin) * multiplier;
                computed.horizontal_edges.border_start = .{ .px = width };
                used.border_inline_start = solve.positiveLength(.px, width) catch unreachable;
            },
            .medium => {
                const width = solve.borderWidth(.medium) * multiplier;
                computed.horizontal_edges.border_start = .{ .px = width };
                used.border_inline_start = solve.positiveLength(.px, width) catch unreachable;
            },
            .thick => {
                const width = solve.borderWidth(.thick) * multiplier;
                computed.horizontal_edges.border_start = .{ .px = width };
                used.border_inline_start = solve.positiveLength(.px, width) catch unreachable;
            },
            .initial, .inherit, .unset, .undeclared => unreachable,
        }
    }
    {
        const multiplier = solve.borderWidthMultiplier(border_styles.right);
        switch (specified.horizontal_edges.border_end) {
            .px => |value| {
                const width = value * multiplier;
                computed.horizontal_edges.border_end = .{ .px = width };
                used.border_inline_end = try solve.positiveLength(.px, width);
            },
            .thin => {
                const width = solve.borderWidth(.thin) * multiplier;
                computed.horizontal_edges.border_end = .{ .px = width };
                used.border_inline_end = solve.positiveLength(.px, width) catch unreachable;
            },
            .medium => {
                const width = solve.borderWidth(.medium) * multiplier;
                computed.horizontal_edges.border_end = .{ .px = width };
                used.border_inline_end = solve.positiveLength(.px, width) catch unreachable;
            },
            .thick => {
                const width = solve.borderWidth(.thick) * multiplier;
                computed.horizontal_edges.border_end = .{ .px = width };
                used.border_inline_end = solve.positiveLength(.px, width) catch unreachable;
            },
            .initial, .inherit, .unset, .undeclared => unreachable,
        }
    }
    switch (specified.horizontal_edges.padding_start) {
        .px => |value| {
            computed.horizontal_edges.padding_start = .{ .px = value };
            used.padding_inline_start = try solve.positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.horizontal_edges.padding_start = .{ .percentage = value };
            used.padding_inline_start = try solve.positivePercentage(value, containing_block_width);
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
    switch (specified.horizontal_edges.padding_end) {
        .px => |value| {
            computed.horizontal_edges.padding_end = .{ .px = value };
            used.padding_inline_end = try solve.positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.horizontal_edges.padding_end = .{ .percentage = value };
            used.padding_inline_end = try solve.positivePercentage(value, containing_block_width);
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
    switch (specified.horizontal_edges.margin_start) {
        .px => |value| {
            computed.horizontal_edges.margin_start = .{ .px = value };
            used.set(.margin_inline_start, solve.length(.px, value));
        },
        .percentage => |value| {
            computed.horizontal_edges.margin_start = .{ .percentage = value };
            used.set(.margin_inline_start, solve.percentage(value, containing_block_width));
        },
        .auto => {
            computed.horizontal_edges.margin_start = .auto;
            used.set(.margin_inline_start, 0);
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
    switch (specified.horizontal_edges.margin_end) {
        .px => |value| {
            computed.horizontal_edges.margin_end = .{ .px = value };
            used.set(.margin_inline_end, solve.length(.px, value));
        },
        .percentage => |value| {
            computed.horizontal_edges.margin_end = .{ .percentage = value };
            used.set(.margin_inline_end, solve.percentage(value, containing_block_width));
        },
        .auto => {
            computed.horizontal_edges.margin_end = .auto;
            used.set(.margin_inline_end, 0);
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
    switch (specified.content_width.min_size) {
        .px => |value| {
            computed.content_width.min_size = .{ .px = value };
            used.min_inline_size = try solve.positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.content_width.min_size = .{ .percentage = value };
            used.min_inline_size = try solve.positivePercentage(value, containing_block_width);
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
    switch (specified.content_width.max_size) {
        .px => |value| {
            computed.content_width.max_size = .{ .px = value };
            used.max_inline_size = try solve.positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.content_width.max_size = .{ .percentage = value };
            used.max_inline_size = try solve.positivePercentage(value, containing_block_width);
        },
        .none => {
            computed.content_width.max_size = .none;
            used.max_inline_size = std.math.maxInt(ZssUnit);
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }

    switch (specified.content_width.size) {
        .px => |value| {
            computed.content_width.size = .{ .px = value };
            used.set(.inline_size, try solve.positiveLength(.px, value));
        },
        .percentage => |value| {
            computed.content_width.size = .{ .percentage = value };
            used.set(.inline_size, try solve.positivePercentage(value, containing_block_width));
        },
        .auto => {
            computed.content_width.size = .auto;
            used.set(.inline_size, null);
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }

    {
        const multiplier = solve.borderWidthMultiplier(border_styles.top);
        switch (specified.vertical_edges.border_start) {
            .px => |value| {
                const width = value * multiplier;
                computed.vertical_edges.border_start = .{ .px = width };
                used.border_block_start = try solve.positiveLength(.px, width);
            },
            .thin => {
                const width = solve.borderWidth(.thin) * multiplier;
                computed.vertical_edges.border_start = .{ .px = width };
                used.border_block_start = solve.positiveLength(.px, width) catch unreachable;
            },
            .medium => {
                const width = solve.borderWidth(.medium) * multiplier;
                computed.vertical_edges.border_start = .{ .px = width };
                used.border_block_start = solve.positiveLength(.px, width) catch unreachable;
            },
            .thick => {
                const width = solve.borderWidth(.thick) * multiplier;
                computed.vertical_edges.border_start = .{ .px = width };
                used.border_block_start = solve.positiveLength(.px, width) catch unreachable;
            },
            .initial, .inherit, .unset, .undeclared => unreachable,
        }
    }
    {
        const multiplier = solve.borderWidthMultiplier(border_styles.bottom);
        switch (specified.vertical_edges.border_end) {
            .px => |value| {
                const width = value * multiplier;
                computed.vertical_edges.border_end = .{ .px = width };
                used.border_block_end = try solve.positiveLength(.px, width);
            },
            .thin => {
                const width = solve.borderWidth(.thin) * multiplier;
                computed.vertical_edges.border_end = .{ .px = width };
                used.border_block_end = solve.positiveLength(.px, width) catch unreachable;
            },
            .medium => {
                const width = solve.borderWidth(.medium) * multiplier;
                computed.vertical_edges.border_end = .{ .px = width };
                used.border_block_end = solve.positiveLength(.px, width) catch unreachable;
            },
            .thick => {
                const width = solve.borderWidth(.thick) * multiplier;
                computed.vertical_edges.border_end = .{ .px = width };
                used.border_block_end = solve.positiveLength(.px, width) catch unreachable;
            },
            .initial, .inherit, .unset, .undeclared => unreachable,
        }
    }
    switch (specified.vertical_edges.padding_start) {
        .px => |value| {
            computed.vertical_edges.padding_start = .{ .px = value };
            used.padding_block_start = try solve.positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.vertical_edges.padding_start = .{ .percentage = value };
            used.padding_block_start = try solve.positivePercentage(value, containing_block_width);
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
    switch (specified.vertical_edges.padding_end) {
        .px => |value| {
            computed.vertical_edges.padding_end = .{ .px = value };
            used.padding_block_end = try solve.positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.vertical_edges.padding_end = .{ .percentage = value };
            used.padding_block_end = try solve.positivePercentage(value, containing_block_width);
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
    switch (specified.vertical_edges.margin_start) {
        .px => |value| {
            computed.vertical_edges.margin_start = .{ .px = value };
            used.margin_block_start = solve.length(.px, value);
        },
        .percentage => |value| {
            computed.vertical_edges.margin_start = .{ .percentage = value };
            used.margin_block_start = solve.percentage(value, containing_block_width);
        },
        .auto => {
            computed.vertical_edges.margin_start = .auto;
            used.margin_block_start = 0;
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
    switch (specified.vertical_edges.margin_end) {
        .px => |value| {
            computed.vertical_edges.margin_end = .{ .px = value };
            used.margin_block_end = solve.length(.px, value);
        },
        .percentage => |value| {
            computed.vertical_edges.margin_end = .{ .percentage = value };
            used.margin_block_end = solve.percentage(value, containing_block_width);
        },
        .auto => {
            computed.vertical_edges.margin_end = .auto;
            used.margin_block_end = 0;
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
    switch (specified.content_height.min_size) {
        .px => |value| {
            computed.content_height.min_size = .{ .px = value };
            used.min_block_size = try solve.positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.content_height.min_size = .{ .percentage = value };
            used.min_block_size = if (containing_block_height) |h|
                try solve.positivePercentage(value, h)
            else
                0;
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
    switch (specified.content_height.max_size) {
        .px => |value| {
            computed.content_height.max_size = .{ .px = value };
            used.max_block_size = try solve.positiveLength(.px, value);
        },
        .percentage => |value| {
            computed.content_height.max_size = .{ .percentage = value };
            used.max_block_size = if (containing_block_height) |h|
                try solve.positivePercentage(value, h)
            else
                std.math.maxInt(ZssUnit);
        },
        .none => {
            computed.content_height.max_size = .none;
            used.max_block_size = std.math.maxInt(ZssUnit);
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }
    switch (specified.content_height.size) {
        .px => |value| {
            computed.content_height.size = .{ .px = value };
            used.set(.block_size, try solve.positiveLength(.px, value));
        },
        .percentage => |value| {
            computed.content_height.size = .{ .percentage = value };
            used.set(.block_size, if (containing_block_height) |h|
                try solve.positivePercentage(value, h)
            else
                null);
        },
        .auto => {
            computed.content_height.size = .auto;
            used.set(.block_size, null);
        },
        .initial, .inherit, .unset, .undeclared => unreachable,
    }

    computer.setComputedValue(.box_gen, .content_width, computed.content_width);
    computer.setComputedValue(.box_gen, .horizontal_edges, computed.horizontal_edges);
    computer.setComputedValue(.box_gen, .content_height, computed.content_height);
    computer.setComputedValue(.box_gen, .vertical_edges, computed.vertical_edges);
    computer.setComputedValue(.box_gen, .border_styles, border_styles);

    return used;
}

fn ifcSolveMetrics(ifc: *InlineFormattingContext, subtree: *BlockSubtree) void {
    const num_glyphs = ifc.glyph_indeces.items.len;
    var i: usize = 0;
    while (i < num_glyphs) : (i += 1) {
        const glyph_index = ifc.glyph_indeces.items[i];
        const metrics = &ifc.metrics.items[i];

        if (glyph_index == 0) {
            i += 1;
            const special = InlineFormattingContext.Special.decode(ifc.glyph_indeces.items[i]);
            const kind = @intToEnum(InlineFormattingContext.Special.LayoutInternalKind, @enumToInt(special.kind));
            switch (kind) {
                .ZeroGlyphIndex => setMetricsGlyph(metrics, ifc.font, 0),
                .BoxStart => {
                    const inline_box_index = @as(InlineBoxIndex, special.data);
                    setMetricsBoxStart(metrics, ifc, inline_box_index);
                },
                .BoxEnd => {
                    const inline_box_index = @as(InlineBoxIndex, special.data);
                    setMetricsBoxEnd(metrics, ifc, inline_box_index);
                },
                .InlineBlock => {
                    const block_box_index = @as(BlockBoxIndex, special.data);
                    setMetricsInlineBlock(metrics, subtree, block_box_index);
                },
                .LineBreak => setMetricsLineBreak(metrics),
                .ContinuationBlock => panic("TODO: Continuation block metrics", .{}),
            }
        } else {
            setMetricsGlyph(metrics, ifc.font, glyph_index);
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

fn setMetricsBoxStart(metrics: *InlineFormattingContext.Metrics, ifc: *InlineFormattingContext, inline_box_index: InlineBoxIndex) void {
    const inline_start = ifc.inline_start.items[inline_box_index];
    const margin = ifc.margins.items[inline_box_index].start;
    const width = inline_start.border + inline_start.padding;
    const advance = width + margin;
    metrics.* = .{ .offset = margin, .advance = advance, .width = width };
}

fn setMetricsBoxEnd(metrics: *InlineFormattingContext.Metrics, ifc: *InlineFormattingContext, inline_box_index: InlineBoxIndex) void {
    const inline_end = ifc.inline_end.items[inline_box_index];
    const margin = ifc.margins.items[inline_box_index].end;
    const width = inline_end.border + inline_end.padding;
    const advance = width + margin;
    metrics.* = .{ .offset = 0, .advance = advance, .width = width };
}

fn setMetricsLineBreak(metrics: *InlineFormattingContext.Metrics) void {
    metrics.* = .{ .offset = 0, .advance = 0, .width = 0 };
}

fn setMetricsInlineBlock(metrics: *InlineFormattingContext.Metrics, subtree: *BlockSubtree, block_box_index: BlockBoxIndex) void {
    const box_offsets = subtree.box_offsets.items[block_box_index];
    const margins = subtree.margins.items[block_box_index];

    const width = box_offsets.border_size.w;
    const advance = width + margins.left + margins.right;
    metrics.* = .{ .offset = margins.left, .advance = advance, .width = width };
}

const IFCLineSplitState = struct {
    cursor: ZssUnit,
    line_box: InlineFormattingContext.LineBox,
    inline_blocks_in_this_line_box: ArrayListUnmanaged(InlineBlockInfo),
    top_height: ZssUnit,
    max_top_height: ZssUnit,
    bottom_height: ZssUnit,
    longest_line_box_length: ZssUnit,

    const InlineBlockInfo = struct {
        box_offsets: *used_values.BoxOffsets,
        cursor: ZssUnit,
        height: ZssUnit,
    };

    fn init(top_height: ZssUnit, bottom_height: ZssUnit) IFCLineSplitState {
        return IFCLineSplitState{
            .cursor = 0,
            .line_box = .{ .baseline = 0, .elements = [2]usize{ 0, 0 } },
            .inline_blocks_in_this_line_box = .{},
            .top_height = top_height,
            .max_top_height = top_height,
            .bottom_height = bottom_height,
            .longest_line_box_length = 0,
        };
    }

    fn deinit(self: *IFCLineSplitState, allocator: Allocator) void {
        self.inline_blocks_in_this_line_box.deinit(allocator);
    }

    fn finishLineBox(self: *IFCLineSplitState, origin: ZssVector) void {
        self.line_box.baseline += self.max_top_height;
        self.longest_line_box_length = std.math.max(self.longest_line_box_length, self.cursor);

        for (self.inline_blocks_in_this_line_box.items) |info| {
            const offset_x = origin.x + info.cursor;
            const offset_y = origin.y + self.line_box.baseline - info.height;
            info.box_offsets.border_pos.x += offset_x;
            info.box_offsets.border_pos.y += offset_y;
        }
    }

    fn newLineBox(self: *IFCLineSplitState, skipped_glyphs: usize) void {
        self.cursor = 0;
        self.line_box = .{
            .baseline = self.line_box.baseline + self.bottom_height,
            .elements = [2]usize{ self.line_box.elements[1] + skipped_glyphs, self.line_box.elements[1] + skipped_glyphs },
        };
        self.max_top_height = self.top_height;
        self.inline_blocks_in_this_line_box.clearRetainingCapacity();
    }
};

pub const IFCLineSplitResult = struct {
    height: ZssUnit,
    longest_line_box_length: ZssUnit,
};

pub fn splitIntoLineBoxes(
    allocator: Allocator,
    box_tree: *BoxTree,
    ifc: *InlineFormattingContext,
    max_line_box_length: ZssUnit,
) !IFCLineSplitResult {
    assert(max_line_box_length >= 0);

    const subtree = &box_tree.blocks.subtrees.items[ifc.subtree_index];

    var font_extents: hb.hb_font_extents_t = undefined;
    // TODO assuming ltr direction
    assert(hb.hb_font_get_h_extents(ifc.font, &font_extents) != 0);
    ifc.ascender = @divFloor(font_extents.ascender * units_per_pixel, 64);
    ifc.descender = @divFloor(font_extents.descender * units_per_pixel, 64);
    const top_height: ZssUnit = @divFloor((font_extents.ascender + @divFloor(font_extents.line_gap, 2) + @mod(font_extents.line_gap, 2)) * units_per_pixel, 64);
    const bottom_height: ZssUnit = @divFloor((-font_extents.descender + @divFloor(font_extents.line_gap, 2)) * units_per_pixel, 64);

    var s = IFCLineSplitState.init(top_height, bottom_height);
    defer s.deinit(allocator);

    var i: usize = 0;
    while (i < ifc.glyph_indeces.items.len) : (i += 1) {
        const gi = ifc.glyph_indeces.items[i];
        const metrics = ifc.metrics.items[i];

        if (gi == 0) {
            i += 1;
            const special = InlineFormattingContext.Special.decode(ifc.glyph_indeces.items[i]);
            switch (@intToEnum(InlineFormattingContext.Special.LayoutInternalKind, @enumToInt(special.kind))) {
                .LineBreak => {
                    s.finishLineBox(ifc.origin);
                    try ifc.line_boxes.append(box_tree.allocator, s.line_box);
                    s.newLineBox(2);
                    continue;
                },
                .ContinuationBlock => panic("TODO: Continuation blocks", .{}),
                else => {},
            }
        }

        // TODO: (Bug) A glyph with a width of zero but an advance that is non-zero may overflow the width of the containing block
        if (s.cursor > 0 and metrics.width > 0 and s.cursor + metrics.offset + metrics.width > max_line_box_length and s.line_box.elements[1] > s.line_box.elements[0]) {
            s.finishLineBox(ifc.origin);
            try ifc.line_boxes.append(box_tree.allocator, s.line_box);
            s.newLineBox(0);
        }

        if (gi == 0) {
            const special = InlineFormattingContext.Special.decode(ifc.glyph_indeces.items[i]);
            switch (@intToEnum(InlineFormattingContext.Special.LayoutInternalKind, @enumToInt(special.kind))) {
                .InlineBlock => {
                    const block_box_index = @as(BlockBoxIndex, special.data);
                    const box_offsets = &subtree.box_offsets.items[block_box_index];
                    const margins = subtree.margins.items[block_box_index];
                    const margin_box_height = box_offsets.border_size.h + margins.top + margins.bottom;
                    s.max_top_height = std.math.max(s.max_top_height, margin_box_height);
                    try s.inline_blocks_in_this_line_box.append(
                        allocator,
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
        s.finishLineBox(ifc.origin);
        try ifc.line_boxes.append(box_tree.allocator, s.line_box);
    }

    return IFCLineSplitResult{
        .height = if (ifc.line_boxes.items.len > 0)
            ifc.line_boxes.items[ifc.line_boxes.items.len - 1].baseline + s.bottom_height
        else
            0, // TODO: This is never reached because the root inline box always creates at least 1 line box.
        .longest_line_box_length = s.longest_line_box_length,
    };
}
