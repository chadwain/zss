const std = @import("std");
const Allocator = std.mem.Allocator;

const zss = @import("zss.zig");
const aggregates = zss.properties.aggregates;
const ElementTree = zss.ElementTree;
const Element = ElementTree.Element;
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

pub const Inputs = struct {
    viewport: ZssSize,
    root_element: Element,
    images: Images.Slice,
    storage: *const Storage,
};

pub const Error = error{
    OutOfMemory,
    OutOfRefs,
    TooManyBlocks,
    TooManyIfcs,
    TooManyInlineBoxes,
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
    storage: *const Storage,
) Error!BoxTree {
    var computer = StyleComputer{
        .element_tree_slice = element_tree_slice,
        .stage = undefined,
        .allocator = allocator,
    };
    defer computer.deinit();

    var box_tree = BoxTree{ .allocator = allocator };
    errdefer box_tree.deinit();

    const inputs = Inputs{
        .viewport = .{
            .w = @intCast(width * units_per_pixel),
            .h = @intCast(height * units_per_pixel),
        },
        .root_element = root_element,
        .images = images,
        .storage = storage,
    };

    try boxGeneration(&computer, &box_tree, allocator, inputs);
    try cosmeticLayout(&computer, &box_tree, allocator, inputs);

    return box_tree;
}

fn boxGeneration(computer: *StyleComputer, box_tree: *BoxTree, allocator: Allocator, inputs: Inputs) !void {
    computer.stage = .{ .box_gen = .{} };
    defer computer.deinitStage(.box_gen);

    var context = initial.InitialLayoutContext{ .allocator = allocator };

    var sc = StackingContexts{ .allocator = allocator };
    defer sc.deinit();

    try initial.run(&context, &sc, computer, box_tree, inputs);

    computer.assertEmptyStage(.box_gen);
}

fn cosmeticLayout(computer: *StyleComputer, box_tree: *BoxTree, allocator: Allocator, inputs: Inputs) !void {
    computer.stage = .{ .cosmetic = .{} };
    defer computer.deinitStage(.cosmetic);

    try cosmetic.run(computer, box_tree, allocator, inputs);

    computer.assertEmptyStage(.cosmetic);
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
