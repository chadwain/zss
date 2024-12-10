const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const zss = @import("zss.zig");
const aggregates = zss.properties.aggregates;
const math = zss.math;
const ElementTree = zss.ElementTree;
const Element = ElementTree.Element;
const Fonts = zss.Fonts;
const Images = zss.Images;
const Storage = zss.values.Storage;

const cosmetic = @import("Layout/cosmetic.zig");
const flow = @import("Layout/flow.zig");
const initial = @import("Layout/initial.zig");
const @"inline" = @import("Layout/inline.zig");
const solve = @import("Layout/solve.zig");
const stf = @import("Layout/shrink_to_fit.zig");
pub const Absolute = @import("Layout/AbsoluteContainingBlocks.zig");
pub const StyleComputer = @import("Layout/StyleComputer.zig");
pub const StackingContextTreeBuilder = @import("Layout/StackingContextTreeBuilder.zig");

const BoxTree = zss.BoxTree;
const BackgroundImage = BoxTree.BackgroundImage;
const BackgroundImages = BoxTree.BackgroundImages;
const BlockRef = BoxTree.BlockRef;
const GeneratedBox = BoxTree.GeneratedBox;
const InlineFormattingContext = BoxTree.InlineFormattingContext;
const InlineFormattingContextId = BoxTree.InlineFormattingContextId;
const StackingContext = BoxTree.StackingContext;
const StackingContextTree = BoxTree.StackingContextTree;
const Subtree = BoxTree.Subtree;

const Layout = @This();

box_tree: BoxTreeManaged,
computer: StyleComputer,
sct_builder: StackingContextTreeBuilder,
absolute: Absolute,
viewport: math.Size,
inputs: Inputs,
allocator: Allocator,
element_stack: zss.Stack(Element),
subtrees: zss.Stack(struct {
    id: Subtree.Id,
    depth: Subtree.Size,
}),
blocks: zss.Stack(Block),

pub const Inputs = struct {
    root_element: Element,
    width: u32,
    height: u32,
    images: Images.Slice,
    fonts: *const Fonts,
    storage: *const Storage,
};

pub const Error = error{
    OutOfMemory,
    OutOfRefs,
    SizeLimitExceeded,
    TooManyInlineBoxes,
    ViewportTooLarge,
};

pub fn init(
    element_tree_slice: ElementTree.Slice,
    root_element: Element,
    allocator: Allocator,
    /// The width of the viewport in pixels.
    width: u32,
    /// The height of the viewport in pixels.
    height: u32,
    images: Images.Slice,
    fonts: *const Fonts,
    storage: *const Storage,
) Layout {
    if (!root_element.eqlNull()) {
        const parent = element_tree_slice.parent(root_element);
        assert(parent.eqlNull());
    }

    return .{
        .box_tree = undefined,
        .computer = StyleComputer.init(element_tree_slice, allocator),
        .sct_builder = .{},
        .absolute = .{},
        .viewport = undefined,
        .inputs = .{
            .root_element = root_element,
            .width = width,
            .height = height,
            .images = images,
            .fonts = fonts,
            .storage = storage,
        },
        .allocator = allocator,
        .element_stack = .{},
        .subtrees = .{},
        .blocks = .{},
    };
}

pub fn deinit(layout: *Layout) void {
    layout.computer.deinit();
    layout.sct_builder.deinit(layout.allocator);
    layout.absolute.deinit(layout.allocator);
    layout.element_stack.deinit(layout.allocator);
    layout.subtrees.deinit(layout.allocator);
    layout.blocks.deinit(layout.allocator);
}

pub const BoxTreeManaged = struct {
    ptr: *BoxTree,

    pub fn setGeneratedBox(box_tree: BoxTreeManaged, element: Element, generated_box: GeneratedBox) !void {
        try box_tree.ptr.element_to_generated_box.putNoClobber(box_tree.ptr.allocator, element, generated_box);
    }

    fn newSubtree(box_tree: BoxTreeManaged) !*Subtree {
        const all_subtrees = &box_tree.ptr.blocks.subtrees;
        const id_int = std.math.cast(std.meta.Tag(Subtree.Id), all_subtrees.items.len) orelse return error.SizeLimitExceeded;

        try all_subtrees.ensureUnusedCapacity(box_tree.ptr.allocator, 1);
        const subtree = try box_tree.ptr.allocator.create(Subtree);
        all_subtrees.appendAssumeCapacity(subtree);
        subtree.* = .{ .id = @enumFromInt(id_int), .parent = null };
        return subtree;
    }

    fn appendBlockBox(box_tree: BoxTreeManaged, subtree: *Subtree) !Subtree.Size {
        const new_len = std.math.add(Subtree.Size, @intCast(subtree.blocks.len), 1) catch return error.SizeLimitExceeded;
        try subtree.blocks.resize(box_tree.ptr.allocator, new_len);
        return new_len - 1;
    }

    pub fn newIfc(box_tree: BoxTreeManaged, parent_block: BlockRef) !*InlineFormattingContext {
        const all_ifcs = &box_tree.ptr.ifcs;
        const id_int = std.math.cast(std.meta.Tag(InlineFormattingContextId), all_ifcs.items.len) orelse return error.SizeLimitExceeded;

        try all_ifcs.ensureUnusedCapacity(box_tree.ptr.allocator, 1);
        const ifc = try box_tree.ptr.allocator.create(InlineFormattingContext);
        all_ifcs.appendAssumeCapacity(ifc);
        ifc.* = .{ .id = @enumFromInt(id_int), .parent_block = parent_block };
        return ifc;
    }

    pub fn appendInlineBox(box_tree: BoxTreeManaged, ifc: *InlineFormattingContext) !BoxTree.InlineBoxIndex {
        const new_len = std.math.add(BoxTree.InlineBoxIndex, @intCast(ifc.inline_boxes.len), 1) catch return error.SizeLimitExceeded;
        try ifc.inline_boxes.resize(box_tree.ptr.allocator, new_len);
        return new_len - 1;
    }

    pub fn appendGlyph(box_tree: BoxTreeManaged, ifc: *InlineFormattingContext, glyph: InlineFormattingContext.GlyphIndex) !void {
        try ifc.glyph_indeces.append(box_tree.ptr.allocator, glyph);
    }

    /// This enum is derived from `InlineFormattingContext.Special.Kind`
    pub const SpecialGlyph = union(enum(u16)) {
        Reserved,
        ZeroGlyphIndex,
        BoxStart: BoxTree.InlineBoxIndex,
        BoxEnd: BoxTree.InlineBoxIndex,
        InlineBlock: Subtree.Size,
        /// Represents a mandatory line break in the text.
        /// data has no meaning.
        LineBreak,
        /// Represents a continuation block.
        /// A "continuation block" is a block box that is the child of an inline box.
        /// It causes the inline formatting context to be split around this block,
        /// and creates anonymous block boxes, as per CSS2§9.2.1.1.
        /// data is the used id of the block box.
        ContinuationBlock,
    };

    pub fn appendSpecialGlyph(
        box_tree: BoxTreeManaged,
        ifc: *InlineFormattingContext,
        comptime tag: std.meta.Tag(SpecialGlyph),
        data: @TypeOf(@field(@as(SpecialGlyph, undefined), @tagName(tag))),
    ) !void {
        const special: InlineFormattingContext.Special = .{
            .kind = blk: {
                comptime zss.debug.ensureCompatibleEnums(InlineFormattingContext.Special.Kind, std.meta.Tag(SpecialGlyph));
                @setRuntimeSafety(false);
                break :blk @enumFromInt(@intFromEnum(tag));
            },
            .data = switch (tag) {
                .Reserved, .ContinuationBlock => comptime unreachable,
                .ZeroGlyphIndex, .LineBreak => undefined,
                .BoxStart, .BoxEnd, .InlineBlock => data,
            },
        };
        try ifc.glyph_indeces.appendSlice(box_tree.ptr.allocator, &[2]InlineFormattingContext.GlyphIndex{ 0, @bitCast(special) });
    }

    pub fn allocMetrics(box_tree: BoxTreeManaged, ifc: *InlineFormattingContext) !void {
        try ifc.metrics.resize(box_tree.ptr.allocator, ifc.glyph_indeces.items.len);
    }

    pub fn appendLineBox(box_tree: BoxTreeManaged, ifc: *InlineFormattingContext, line_box: InlineFormattingContext.LineBox) !void {
        try ifc.line_boxes.append(box_tree.ptr.allocator, line_box);
    }

    pub fn allocBackgroundImages(box_tree: BoxTreeManaged, count: BackgroundImages.Size) !struct { BackgroundImages.Handle, []BackgroundImage } {
        const bi = &box_tree.ptr.background_images;
        const handle_int = std.math.add(std.meta.Tag(BackgroundImages.Handle), @intCast(bi.slices.items.len), 1) catch return error.SizeLimitExceeded;
        const begin: BackgroundImages.Size = @intCast(bi.images.items.len);
        const end = std.math.add(BackgroundImages.Size, begin, count) catch return error.SizeLimitExceeded;

        try bi.slices.ensureUnusedCapacity(box_tree.ptr.allocator, 1);
        const images = try bi.images.addManyAsSlice(box_tree.ptr.allocator, count);
        bi.slices.appendAssumeCapacity(.{ .begin = begin, .end = end });

        return .{ @enumFromInt(handle_int), images };
    }
};

pub fn run(layout: *Layout, allocator: Allocator) Error!BoxTree {
    const cast = math.pixelsToUnits;
    const width_units = cast(layout.inputs.width) orelse return error.ViewportTooLarge;
    const height_units = cast(layout.inputs.height) orelse return error.ViewportTooLarge;
    layout.viewport = .{
        .w = width_units,
        .h = height_units,
    };

    var box_tree = BoxTree{ .allocator = allocator };
    errdefer box_tree.deinit();
    layout.box_tree = .{ .ptr = &box_tree };

    try boxGeneration(layout);
    try cosmeticLayout(layout);

    return box_tree;
}

fn boxGeneration(layout: *Layout) !void {
    layout.computer.stage = .{ .box_gen = .{} };
    defer layout.computer.deinitStage(.box_gen);

    layout.element_stack.top = layout.inputs.root_element;

    try initial.run(layout);
    layout.sct_builder.endFrame();
}

fn cosmeticLayout(layout: *Layout) !void {
    layout.computer.stage = .{ .cosmetic = .{} };
    defer layout.computer.deinitStage(.cosmetic);

    layout.element_stack.top = layout.inputs.root_element;

    try cosmetic.run(layout);
}

pub fn currentElement(layout: Layout) Element {
    return layout.element_stack.top.?;
}

pub fn pushElement(layout: *Layout) !void {
    const element = &layout.element_stack.top.?;
    const child = layout.computer.element_tree_slice.firstChild(element.*);
    element.* = layout.computer.element_tree_slice.nextSibling(element.*);
    try layout.element_stack.push(layout.allocator, child);
}

pub fn popElement(layout: *Layout) void {
    _ = layout.element_stack.pop();
}

pub fn advanceElement(layout: *Layout) void {
    const element = &layout.element_stack.top.?;
    element.* = layout.computer.element_tree_slice.nextSibling(element.*);
}

pub fn currentSubtree(layout: *Layout) Subtree.Id {
    return layout.subtrees.top.?.id;
}

pub fn pushInitialSubtree(layout: *Layout) !void {
    const subtree = try layout.box_tree.newSubtree();
    layout.subtrees.top = .{ .id = subtree.id, .depth = 0 };
}

pub fn pushSubtree(layout: *Layout) !void {
    const subtree = try layout.box_tree.newSubtree();
    try layout.subtrees.push(layout.allocator, .{ .id = subtree.id, .depth = 0 });
}

pub fn popSubtree(layout: *Layout) void {
    const item = layout.subtrees.pop();
    assert(item.depth == 0);
}

pub const Block = struct {
    index: Subtree.Size,
    skip: Subtree.Size,
    sizes: BlockUsedSizes,
    stacking_context_id: ?StackingContextTree.Id,
    absolute_containing_block_id: ?Absolute.ContainingBlock.Id,
};

fn newBlock(layout: *Layout) !BlockRef {
    const subtree = layout.box_tree.ptr.blocks.subtree(layout.subtrees.top.?.id);
    const index = try layout.box_tree.appendBlockBox(subtree);
    return .{ .subtree = subtree.id, .index = index };
}

fn addSkip(layout: *Layout, skip: Subtree.Size) void {
    if (layout.subtrees.top.?.depth > 0) {
        layout.blocks.top.?.skip += skip;
    }
}

pub fn pushInitialContainingBlock(layout: *Layout, size: math.Size) !BlockRef {
    const ref = try layout.newBlock();
    const stacking_context_id = try layout.sct_builder.pushInitial(layout.box_tree.ptr, ref);
    const absolute_containing_block_id = try layout.absolute.pushInitialContainingBlock(layout.allocator, ref);
    layout.blocks.top = .{
        .index = ref.index,
        .skip = 1,
        .sizes = BlockUsedSizes.icb(size),
        .stacking_context_id = stacking_context_id,
        .absolute_containing_block_id = absolute_containing_block_id,
    };
    assert(layout.subtrees.top.?.depth == 0);
    layout.subtrees.top.?.depth += 1;

    return ref;
}

pub fn popInitialContainingBlock(layout: *Layout) void {
    layout.sct_builder.popInitial();
    layout.popAbsoluteContainingBlock();
    const block = layout.blocks.pop();
    layout.subtrees.top.?.depth -= 1;
    assert(layout.subtrees.top.?.depth == 0);

    const subtree = layout.box_tree.ptr.blocks.subtree(layout.subtrees.top.?.id).view();
    const index = block.index;
    const width = block.sizes.get(.inline_size).?;
    const height = block.sizes.get(.block_size).?;
    subtree.items(.skip)[index] = block.skip;
    subtree.items(.type)[index] = .block;
    subtree.items(.stacking_context)[index] = block.stacking_context_id;
    subtree.items(.box_offsets)[index] = .{
        .border_pos = .{ .x = 0, .y = 0 },
        .content_pos = .{ .x = 0, .y = 0 },
        .content_size = .{ .w = width, .h = height },
        .border_size = .{ .w = width, .h = height },
    };
    subtree.items(.borders)[index] = .{};
    subtree.items(.margins)[index] = .{};
}

pub fn pushFlowBlock(
    layout: *Layout,
    box_style: BoxTree.BoxStyle,
    sizes: BlockUsedSizes,
    stacking_context: StackingContextTreeBuilder.Type,
) !BlockRef {
    const ref = try layout.newBlock();
    const stacking_context_id = try layout.sct_builder.push(layout.allocator, stacking_context, layout.box_tree.ptr, ref);
    const absolute_containing_block_id = try layout.pushAbsoluteContainingBlock(box_style, ref);
    try layout.blocks.push(layout.allocator, .{
        .index = ref.index,
        .skip = 1,
        .sizes = sizes,
        .stacking_context_id = stacking_context_id,
        .absolute_containing_block_id = absolute_containing_block_id,
    });
    layout.subtrees.top.?.depth += 1;

    return ref;
}

pub fn popFlowBlock(layout: *Layout, auto_height: math.Unit) BlockRef {
    layout.sct_builder.pop(layout.box_tree.ptr);
    layout.popAbsoluteContainingBlock();
    const block = layout.blocks.pop();
    layout.subtrees.top.?.depth -= 1;
    layout.addSkip(block.skip);

    const subtree_id = layout.subtrees.top.?.id;
    const subtree = layout.box_tree.ptr.blocks.subtree(subtree_id).view();
    const width = flow.solveUsedWidth(block.sizes.get(.inline_size).?, block.sizes.min_inline_size, block.sizes.max_inline_size);
    const height = flow.solveUsedHeight(block.sizes.get(.block_size), block.sizes.min_block_size, block.sizes.max_block_size, auto_height);
    setDataBlock(subtree, block.index, block.sizes, block.skip, width, height, block.stacking_context_id);

    return .{ .subtree = subtree_id, .index = block.index };
}

pub fn pushIfcContainerBlock(layout: *Layout) !BlockRef {
    const ref = try layout.newBlock();
    try layout.blocks.push(layout.allocator, .{
        .index = ref.index,
        .skip = 1,
        .sizes = undefined,
        .stacking_context_id = undefined,
        .absolute_containing_block_id = undefined,
    });
    layout.subtrees.top.?.depth += 1;
    return ref;
}

pub fn popIfcContainerBlock(
    layout: *Layout,
    ifc: BoxTree.InlineFormattingContextId,
    containing_block_width: math.Unit,
    height: math.Unit,
) void {
    const block = layout.blocks.pop();
    layout.subtrees.top.?.depth -= 1;
    layout.addSkip(block.skip);

    const subtree = layout.box_tree.ptr.blocks.subtree(layout.subtrees.top.?.id).view();
    setDataIfcContainer(subtree, ifc, block.index, block.skip, containing_block_width, height);
}

pub fn pushStfFlowMainBlock(
    layout: *Layout,
    box_style: BoxTree.BoxStyle,
    sizes: BlockUsedSizes,
    stacking_context: StackingContextTreeBuilder.Type,
) !BlockRef {
    const ref = try layout.newBlock();
    const stacking_context_id = try layout.sct_builder.push(layout.allocator, stacking_context, layout.box_tree.ptr, ref);
    const absolute_containing_block_id = try layout.pushAbsoluteContainingBlock(box_style, ref);
    try layout.blocks.push(layout.allocator, .{
        .index = ref.index,
        .skip = 1,
        .sizes = sizes,
        .stacking_context_id = stacking_context_id,
        .absolute_containing_block_id = absolute_containing_block_id,
    });
    layout.subtrees.top.?.depth += 1;
    return ref;
}

pub fn popStfFlowMainBlock(
    layout: *Layout,
    auto_width: math.Unit,
    auto_height: math.Unit,
) void {
    layout.sct_builder.pop(layout.box_tree.ptr);
    layout.popAbsoluteContainingBlock();
    const block = layout.blocks.pop();
    layout.subtrees.top.?.depth -= 1;
    layout.addSkip(block.skip);

    const subtree = layout.box_tree.ptr.blocks.subtree(layout.subtrees.top.?.id).view();
    const width = flow.solveUsedWidth(auto_width, block.sizes.min_inline_size, block.sizes.max_inline_size); // TODO This is probably redundant
    const height = flow.solveUsedHeight(block.sizes.get(.block_size), block.sizes.min_block_size, block.sizes.max_block_size, auto_height);
    setDataBlock(subtree, block.index, block.sizes, block.skip, width, height, block.stacking_context_id);
}

pub fn pushStfFlowBlock(
    layout: *Layout,
    box_style: BoxTree.BoxStyle,
    sizes: BlockUsedSizes,
    stacking_context: StackingContextTreeBuilder.Type,
) !void {
    const stacking_context_id = try layout.sct_builder.pushWithoutBlock(layout.allocator, stacking_context, layout.box_tree.ptr);
    const absolute_containing_block_id = try layout.pushAbsoluteContainingBlock(box_style, undefined);
    try layout.blocks.push(layout.allocator, .{
        .index = undefined,
        .skip = 1,
        .sizes = sizes,
        .stacking_context_id = stacking_context_id,
        .absolute_containing_block_id = absolute_containing_block_id,
    });
    layout.subtrees.top.?.depth += 1;
}

pub fn popStfFlowBlock(layout: *Layout) Block {
    layout.sct_builder.pop(layout.box_tree.ptr);
    layout.popAbsoluteContainingBlock();
    const block = layout.blocks.pop();
    layout.subtrees.top.?.depth -= 1;
    return block;
}

pub fn pushStfFlowBlock2(
    layout: *Layout,
    sizes: BlockUsedSizes,
    stacking_context_id: ?StackingContextTree.Id,
    absolute_containing_block_id: ?Absolute.ContainingBlock.Id,
) !BlockRef {
    const ref = try layout.newBlock();
    try layout.blocks.push(layout.allocator, .{
        .index = ref.index,
        .skip = 1,
        .sizes = sizes,
        .stacking_context_id = stacking_context_id,
        .absolute_containing_block_id = absolute_containing_block_id,
    });
    layout.subtrees.top.?.depth += 1;
    return ref;
}

pub fn popStfFlowBlock2(
    layout: *Layout,
    auto_width: math.Unit,
    auto_height: math.Unit,
) BlockRef {
    const block = layout.blocks.pop();
    layout.subtrees.top.?.depth -= 1;
    layout.addSkip(block.skip);

    const subtree_id = layout.subtrees.top.?.id;
    const subtree = layout.box_tree.ptr.blocks.subtree(subtree_id).view();
    const width = flow.solveUsedWidth(auto_width, block.sizes.min_inline_size, block.sizes.max_inline_size); // TODO This is probably redundant
    const height = flow.solveUsedHeight(block.sizes.get(.block_size), block.sizes.min_block_size, block.sizes.max_block_size, auto_height);
    setDataBlock(subtree, block.index, block.sizes, block.skip, width, height, block.stacking_context_id);

    const ref: BlockRef = .{ .subtree = subtree_id, .index = block.index };
    if (block.stacking_context_id) |id| layout.sct_builder.setBlock(id, layout.box_tree.ptr, ref);
    if (block.absolute_containing_block_id) |id| layout.fixupAbsoluteContainingBlock(id, ref);

    return ref;
}

pub fn addSubtreeProxy(layout: *Layout, id: Subtree.Id) !BlockRef {
    layout.addSkip(1);

    const ref = try layout.newBlock();
    const parent_subtree = layout.box_tree.ptr.blocks.subtree(layout.subtrees.top.?.id);
    const child_subtree = layout.box_tree.ptr.blocks.subtree(id);
    setDataSubtreeProxy(parent_subtree.view(), ref.index, child_subtree);
    child_subtree.parent = ref;
    return ref;
}

pub fn newIfc(layout: *Layout, ifc_container: BlockRef) !*InlineFormattingContext {
    const ifc = try layout.box_tree.newIfc(ifc_container);
    try layout.sct_builder.addIfc(layout.box_tree.ptr, ifc.id);
    return ifc;
}

pub fn pushAbsoluteContainingBlock(
    layout: *Layout,
    box_style: BoxTree.BoxStyle,
    ref: BlockRef,
) !?Absolute.ContainingBlock.Id {
    return layout.absolute.pushContainingBlock(layout.allocator, box_style, ref);
}

pub fn pushInitialAbsoluteContainingBlock(layout: *Layout, ref: BlockRef) !?Absolute.ContainingBlock.Id {
    return try layout.absolute.pushInitialContainingBlock(layout.allocator, ref);
}

pub fn popAbsoluteContainingBlock(layout: *Layout) void {
    return layout.absolute.popContainingBlock();
}

pub fn fixupAbsoluteContainingBlock(layout: *Layout, id: Absolute.ContainingBlock.Id, ref: BlockRef) void {
    return layout.absolute.fixupContainingBlock(id, ref);
}

pub fn addAbsoluteBlock(layout: *Layout, element: Element, inner_box_style: BoxTree.BoxStyle.InnerBlock) !void {
    return layout.absolute.addBlock(layout.allocator, element, inner_box_style);
}

pub const BlockComputedSizes = struct {
    content_width: aggregates.ContentWidth,
    horizontal_edges: aggregates.HorizontalEdges,
    content_height: aggregates.ContentHeight,
    vertical_edges: aggregates.VerticalEdges,
    insets: aggregates.Insets,
};

// TODO: The field names of this struct are misleading.
//       zss currently does not support logical properties.
pub const BlockUsedSizes = struct {
    border_inline_start: math.Unit,
    border_inline_end: math.Unit,
    padding_inline_start: math.Unit,
    padding_inline_end: math.Unit,
    margin_inline_start_untagged: math.Unit,
    margin_inline_end_untagged: math.Unit,
    inline_size_untagged: math.Unit,
    min_inline_size: math.Unit,
    max_inline_size: math.Unit,

    border_block_start: math.Unit,
    border_block_end: math.Unit,
    padding_block_start: math.Unit,
    padding_block_end: math.Unit,
    margin_block_start: math.Unit,
    margin_block_end: math.Unit,
    block_size_untagged: math.Unit,
    min_block_size: math.Unit,
    max_block_size: math.Unit,

    inset_inline_start_untagged: math.Unit,
    inset_inline_end_untagged: math.Unit,
    inset_block_start_untagged: math.Unit,
    inset_block_end_untagged: math.Unit,

    flags: Flags,

    pub const Flags = packed struct {
        inline_size: IsAutoTag,
        margin_inline_start: IsAutoTag,
        margin_inline_end: IsAutoTag,
        block_size: IsAutoTag,
        inset_inline_start: IsAutoOrPercentageTag,
        inset_inline_end: IsAutoOrPercentageTag,
        inset_block_start: IsAutoOrPercentageTag,
        inset_block_end: IsAutoOrPercentageTag,

        const Field = std.meta.FieldEnum(Flags);
    };

    pub const IsAutoTag = enum(u1) { value, auto };
    pub const IsAuto = union(IsAutoTag) {
        value: math.Unit,
        auto,
    };

    pub const IsAutoOrPercentageTag = enum(u2) { value, auto, percentage };
    pub const IsAutoOrPercentage = union(IsAutoOrPercentageTag) {
        value: math.Unit,
        auto,
        percentage: f32,
    };

    pub fn setValue(self: *BlockUsedSizes, comptime field: Flags.Field, value: math.Unit) void {
        @field(self.flags, @tagName(field)) = .value;
        const clamped_value = switch (field) {
            .inline_size => solve.clampSize(value, self.min_inline_size, self.max_inline_size),
            .margin_inline_start, .margin_inline_end => value,
            .block_size => solve.clampSize(value, self.min_block_size, self.max_block_size),
            .inset_inline_start, .inset_inline_end, .inset_block_start, .inset_block_end => value,
        };
        @field(self, @tagName(field) ++ "_untagged") = clamped_value;
    }

    pub fn setValueFlagOnly(self: *BlockUsedSizes, comptime field: Flags.Field) void {
        @field(self.flags, @tagName(field)) = .value;
    }

    pub fn setAuto(self: *BlockUsedSizes, comptime field: Flags.Field) void {
        @field(self.flags, @tagName(field)) = .auto;
        @field(self, @tagName(field) ++ "_untagged") = 0;
    }

    pub fn setPercentage(self: *BlockUsedSizes, comptime field: Flags.Field, value: f32) void {
        @field(self.flags, @tagName(field)) = .percentage;
        @field(self, @tagName(field) ++ "_untagged") = @bitCast(value);
    }

    pub fn GetReturnType(comptime field: Flags.Field) type {
        return switch (std.meta.FieldType(Flags, field)) {
            IsAutoTag => ?math.Unit,
            IsAutoOrPercentageTag => IsAutoOrPercentage,
            else => comptime unreachable,
        };
    }

    pub fn get(self: BlockUsedSizes, comptime field: Flags.Field) GetReturnType(field) {
        const flag = @field(self.flags, @tagName(field));
        const value = @field(self, @tagName(field) ++ "_untagged");
        return switch (std.meta.FieldType(Flags, field)) {
            IsAutoTag => switch (flag) {
                .value => value,
                .auto => null,
            },
            IsAutoOrPercentageTag => switch (flag) {
                .value => .{ .value = value },
                .auto => .auto,
                .percentage => .{ .percentage = @bitCast(value) },
            },
            else => comptime unreachable,
        };
    }

    pub fn isAuto(self: BlockUsedSizes, comptime field: Flags.Field) bool {
        return @field(self.flags, @tagName(field)) == .auto;
    }

    fn icb(size: math.Size) BlockUsedSizes {
        return .{
            .border_inline_start = 0,
            .border_inline_end = 0,
            .padding_inline_start = 0,
            .padding_inline_end = 0,
            .margin_inline_start_untagged = 0,
            .margin_inline_end_untagged = 0,
            .inline_size_untagged = size.w,
            .min_inline_size = size.w,
            .max_inline_size = size.w,

            .border_block_start = 0,
            .border_block_end = 0,
            .padding_block_start = 0,
            .padding_block_end = 0,
            .margin_block_start = 0,
            .margin_block_end = 0,
            .block_size_untagged = size.h,
            .min_block_size = size.h,
            .max_block_size = size.h,

            .inset_inline_start_untagged = 0,
            .inset_inline_end_untagged = 0,
            .inset_block_start_untagged = 0,
            .inset_block_end_untagged = 0,

            .flags = .{
                .inline_size = .value,
                .margin_inline_start = .value,
                .margin_inline_end = .value,
                .block_size = .value,
                .inset_inline_start = .value,
                .inset_inline_end = .value,
                .inset_block_start = .value,
                .inset_block_end = .value,
            },
        };
    }
};

/// Writes all of a block's data to the BoxTree.
fn setDataBlock(
    subtree: Subtree.View,
    index: Subtree.Size,
    used: BlockUsedSizes,
    skip: Subtree.Size,
    width: math.Unit,
    height: math.Unit,
    stacking_context: ?StackingContextTree.Id,
) void {
    subtree.items(.skip)[index] = skip;
    subtree.items(.type)[index] = .block;
    subtree.items(.stacking_context)[index] = stacking_context;

    const box_offsets = &subtree.items(.box_offsets)[index];
    const borders = &subtree.items(.borders)[index];
    const margins = &subtree.items(.margins)[index];

    // Horizontal sizes
    box_offsets.border_pos.x = used.get(.margin_inline_start).?;
    box_offsets.content_pos.x = used.border_inline_start + used.padding_inline_start;
    box_offsets.content_size.w = width;
    box_offsets.border_size.w = box_offsets.content_pos.x + box_offsets.content_size.w + used.padding_inline_end + used.border_inline_end;

    borders.left = used.border_inline_start;
    borders.right = used.border_inline_end;

    margins.left = used.get(.margin_inline_start).?;
    margins.right = used.get(.margin_inline_end).?;

    // Vertical sizes
    box_offsets.border_pos.y = used.margin_block_start;
    box_offsets.content_pos.y = used.border_block_start + used.padding_block_start;
    box_offsets.content_size.h = height;
    box_offsets.border_size.h = box_offsets.content_pos.y + box_offsets.content_size.h + used.padding_block_end + used.border_block_end;

    borders.top = used.border_block_start;
    borders.bottom = used.border_block_end;

    margins.top = used.margin_block_start;
    margins.bottom = used.margin_block_end;
}

fn setDataIfcContainer(
    subtree: Subtree.View,
    ifc: BoxTree.InlineFormattingContextId,
    index: Subtree.Size,
    skip: Subtree.Size,
    width: math.Unit,
    height: math.Unit,
) void {
    subtree.items(.skip)[index] = skip;
    subtree.items(.type)[index] = .{ .ifc_container = ifc };
    subtree.items(.stacking_context)[index] = null;
    subtree.items(.box_offsets)[index] = .{
        .border_pos = .{ .x = 0, .y = 0 },
        .border_size = .{ .w = width, .h = height },
        .content_pos = .{ .x = 0, .y = 0 },
        .content_size = .{ .w = width, .h = height },
    };
    subtree.items(.borders)[index] = .{};
    subtree.items(.margins)[index] = .{};
}

fn setDataSubtreeProxy(
    subtree: Subtree.View,
    index: Subtree.Size,
    proxied_subtree: *Subtree,
) void {
    const border_size, const margin_top, const margin_bottom = blk: {
        const view = proxied_subtree.view();
        var border_size = view.items(.box_offsets)[0].border_size;
        const margins = view.items(.margins)[0];
        border_size.w += margins.left + margins.right;
        break :blk .{ border_size, margins.top, margins.bottom };
    };

    subtree.items(.skip)[index] = 1;
    subtree.items(.type)[index] = .{ .subtree_proxy = proxied_subtree.id };
    subtree.items(.stacking_context)[index] = null;
    subtree.items(.box_offsets)[index] = .{
        .border_pos = .{ .x = 0, .y = margin_top },
        .border_size = border_size,
        .content_pos = .{ .x = 0, .y = 0 },
        .content_size = border_size,
    };
    subtree.items(.borders)[index] = .{};
    subtree.items(.margins)[index] = .{ .top = margin_top, .bottom = margin_bottom };
}
