const std = @import("std");
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

pub const Error = error{
    OutOfMemory,
    OutOfRefs,
    TooManyBlocks,
    TooManyIfcs,
    TooManyInlineBoxes,
    ViewportTooLarge,
};

pub fn doLayout(
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
) Error!BoxTree {
    var box_tree = BoxTree{ .allocator = allocator };
    errdefer box_tree.deinit();

    var layout = try Layout.init(&box_tree, element_tree_slice, root_element, allocator, width, height, images, fonts, storage);
    defer layout.deinit();

    try boxGeneration(&layout);
    try cosmeticLayout(&layout);

    return box_tree;
}

pub const Layout = struct {
    box_tree: *BoxTree,
    computer: StyleComputer,
    sc: StackingContexts,
    inputs: Inputs,
    allocator: Allocator,

    pub const Inputs = struct {
        viewport: ZssSize,
        root_element: Element,
        images: Images.Slice,
        fonts: *const Fonts,
        storage: *const Storage,
    };

    fn init(
        box_tree: *BoxTree,
        element_tree_slice: ElementTree.Slice,
        root_element: Element,
        allocator: Allocator,
        width: u32,
        height: u32,
        images: Images.Slice,
        fonts: *const Fonts,
        storage: *const Storage,
    ) !Layout {
        const cast = used_values.pixelsToZssUnits;
        const width_units = cast(width) orelse return error.ViewportTooLarge;
        const height_units = cast(height) orelse return error.ViewportTooLarge;
        return .{
            .box_tree = box_tree,
            .computer = .{
                .element_tree_slice = element_tree_slice,
                .stage = undefined,
                .allocator = allocator,
            },
            .sc = .{ .allocator = allocator },
            .inputs = .{
                .viewport = .{
                    .w = width_units,
                    .h = height_units,
                },
                .root_element = root_element,
                .images = images,
                .fonts = fonts,
                .storage = storage,
            },
            .allocator = allocator,
        };
    }

    fn deinit(layout: *Layout) void {
        layout.computer.deinit();
        layout.sc.deinit();
    }
};

fn boxGeneration(layout: *Layout) !void {
    layout.computer.stage = .{ .box_gen = .{} };
    defer layout.computer.deinitStage(.box_gen);

    var context = initial.InitialLayoutContext{ .allocator = layout.allocator };
    try initial.run(layout, &context);

    layout.computer.assertEmptyStage(.box_gen);
}

fn cosmeticLayout(layout: *Layout) !void {
    layout.computer.stage = .{ .cosmetic = .{} };
    defer layout.computer.deinitStage(.cosmetic);

    try cosmetic.run(layout);

    layout.computer.assertEmptyStage(.cosmetic);
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
