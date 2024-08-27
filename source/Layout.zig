const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const zss = @import("zss.zig");
const aggregates = zss.properties.aggregates;
const ElementTree = zss.ElementTree;
const Element = ElementTree.Element;
const Fonts = zss.Fonts;
const Images = zss.Images;
const Storage = zss.values.Storage;

const initial = @import("layout/initial.zig");
const cosmetic = @import("layout/cosmetic.zig");
const solve = @import("layout/solve.zig");
const StyleComputer = @import("layout/StyleComputer.zig");
const StackingContexts = @import("layout/StackingContexts.zig");

const used_values = zss.used_values;
const units_per_pixel = used_values.units_per_pixel;
const BoxTree = used_values.BoxTree;
const ZssUnit = used_values.ZssUnit;
const ZssSize = used_values.ZssSize;

const Layout = @This();

box_tree: *BoxTree,
computer: StyleComputer,
sc: StackingContexts,
viewport: ZssSize,
inputs: Inputs,
allocator: Allocator,
element_stack: zss.util.Stack(Element),

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
    TooManyBlocks,
    TooManyIfcs,
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
        .sc = .{ .allocator = allocator },
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
    };
}

pub fn deinit(layout: *Layout) void {
    layout.computer.deinit();
    layout.sc.deinit();
    layout.element_stack.deinit(layout.allocator);
}

pub fn run(layout: *Layout, allocator: Allocator) Error!BoxTree {
    const cast = used_values.pixelsToZssUnits;
    const width_units = cast(layout.inputs.width) orelse return error.ViewportTooLarge;
    const height_units = cast(layout.inputs.height) orelse return error.ViewportTooLarge;
    layout.viewport = .{
        .w = width_units,
        .h = height_units,
    };

    var box_tree = BoxTree{ .allocator = allocator };
    errdefer box_tree.deinit();
    layout.box_tree = &box_tree;

    try boxGeneration(layout);
    try cosmeticLayout(layout);

    return box_tree;
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

fn boxGeneration(layout: *Layout) !void {
    layout.computer.stage = .{ .box_gen = .{} };
    defer layout.computer.deinitStage(.box_gen);

    layout.element_stack.top = layout.inputs.root_element;

    var context = initial.InitialLayoutContext{ .allocator = layout.allocator };
    try initial.run(layout, &context);
}

fn cosmeticLayout(layout: *Layout) !void {
    layout.computer.stage = .{ .cosmetic = .{} };
    defer layout.computer.deinitStage(.cosmetic);

    layout.element_stack.top = layout.inputs.root_element;

    try cosmetic.run(layout);
}

pub const BlockComputedSizes = struct {
    content_width: aggregates.ContentWidth,
    horizontal_edges: aggregates.HorizontalEdges,
    content_height: aggregates.ContentHeight,
    vertical_edges: aggregates.VerticalEdges,
};

pub const BlockUsedSizes = struct {
    border_inline_start: ZssUnit,
    border_inline_end: ZssUnit,
    padding_inline_start: ZssUnit,
    padding_inline_end: ZssUnit,
    margin_inline_start_untagged: ZssUnit,
    margin_inline_end_untagged: ZssUnit,
    inline_size_untagged: ZssUnit,
    min_inline_size: ZssUnit,
    max_inline_size: ZssUnit,

    border_block_start: ZssUnit,
    border_block_end: ZssUnit,
    padding_block_start: ZssUnit,
    padding_block_end: ZssUnit,
    margin_block_start: ZssUnit,
    margin_block_end: ZssUnit,
    block_size_untagged: ZssUnit,
    min_block_size: ZssUnit,
    max_block_size: ZssUnit,

    auto_bitfield: u4,

    pub const PossiblyAutoField = enum(u4) {
        inline_size = 1,
        margin_inline_start = 2,
        margin_inline_end = 4,
        block_size = 8,
    };

    pub fn set(self: *BlockUsedSizes, comptime field: PossiblyAutoField, value: ZssUnit) void {
        self.auto_bitfield &= (~@intFromEnum(field));
        const clamped_value = switch (field) {
            .inline_size => solve.clampSize(value, self.min_inline_size, self.max_inline_size),
            .margin_inline_start, .margin_inline_end => value,
            .block_size => solve.clampSize(value, self.min_block_size, self.max_block_size),
        };
        @field(self, @tagName(field) ++ "_untagged") = clamped_value;
    }

    pub fn setOnly(self: *BlockUsedSizes, comptime field: PossiblyAutoField) void {
        self.auto_bitfield &= (~@intFromEnum(field));
    }

    pub fn setAuto(self: *BlockUsedSizes, comptime field: PossiblyAutoField) void {
        self.auto_bitfield |= @intFromEnum(field);
        @field(self, @tagName(field) ++ "_untagged") = 0;
    }

    pub fn get(self: BlockUsedSizes, comptime field: PossiblyAutoField) ?ZssUnit {
        return if (self.isFieldAuto(field)) null else @field(self, @tagName(field) ++ "_untagged");
    }

    pub fn inlineSizeAndMarginsAreAllNotAuto(self: BlockUsedSizes) bool {
        const mask = @intFromEnum(PossiblyAutoField.inline_size) |
            @intFromEnum(PossiblyAutoField.margin_inline_start) |
            @intFromEnum(PossiblyAutoField.margin_inline_end);
        return self.auto_bitfield & mask == 0;
    }

    pub fn isFieldAuto(self: BlockUsedSizes, comptime field: PossiblyAutoField) bool {
        return self.auto_bitfield & @intFromEnum(field) != 0;
    }
};
