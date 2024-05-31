const std = @import("std");
const Allocator = std.mem.Allocator;

const zss = @import("zss.zig");
const ElementTree = zss.ElementTree;
const Element = ElementTree.Element;
const Images = zss.Images;
const Storage = zss.values.Storage;

const initial = @import("layout/initial.zig");
const cosmetic = @import("layout/cosmetic.zig");
const StyleComputer = @import("layout/StyleComputer.zig");
const StackingContexts = @import("layout/StackingContexts.zig");

const used_values = zss.used_values;
const units_per_pixel = used_values.units_per_pixel;
const BoxTree = used_values.BoxTree;
const ZssSize = used_values.ZssSize;

pub const Inputs = struct {
    viewport: ZssSize,
    images: Images.Slice,
    storage: *const Storage,
};

pub const Error = error{
    InvalidValue, // TODO: Remove this error. Layout should never fail for this reason.
    OutOfMemory,
    OutOfRefs,
    TooManyBlockSubtrees,
    TooManyBlocks,
    TooManyIfcs,
    TooManyInlineBoxes,
};

pub fn doLayout(
    element_tree_slice: ElementTree.Slice,
    root: Element,
    allocator: Allocator,
    /// The width of the viewport in pixels.
    width: u32,
    /// The height of the viewport in pixels.
    height: u32,
    images: Images.Slice,
    storage: *const Storage,
) Error!BoxTree {
    var computer = StyleComputer{
        .root_element = root,
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

pub const Block = struct {
    index: used_values.BlockBoxIndex,
    skip: *used_values.BlockBoxSkip,
    type: *used_values.BlockType,
    box_offsets: *used_values.BoxOffsets,
    borders: *used_values.Borders,
    margins: *used_values.Margins,
};

// TODO: Make this return only the index
pub fn createBlock(box_tree: *BoxTree, subtree: *used_values.BlockSubtree) !Block {
    const index = try subtree.appendBlock(box_tree.allocator);
    const slice = subtree.slice();
    return Block{
        .index = index,
        .skip = &slice.items(.skip)[index],
        .type = &slice.items(.type)[index],
        .box_offsets = &slice.items(.box_offsets)[index],
        .borders = &slice.items(.borders)[index],
        .margins = &slice.items(.margins)[index],
    };
}
