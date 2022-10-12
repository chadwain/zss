const std = @import("std");
const Allocator = std.mem.Allocator;

const zss = @import("../../zss.zig");
const ElementTree = zss.ElementTree;
const CascadedValueStore = zss.CascadedValueStore;

const normal = @import("./normal.zig");
const cosmetic = @import("./cosmetic.zig");
const StyleComputer = @import("./StyleComputer.zig");
const StackingContexts = @import("./StackingContexts.zig");

const used_values = @import("./used_values.zig");
const BoxTree = used_values.BoxTree;
const GeneratedBox = used_values.GeneratedBox;

pub const Error = error{
    InvalidValue,
    OutOfMemory,
    OutOfRefs,
    TooManyBlockSubtrees,
    TooManyBlocks,
    TooManyIfcs,
};

pub const ViewportSize = struct {
    width: u32,
    height: u32,
};

pub fn doLayout(
    element_tree: ElementTree,
    cascaded_value_store: CascadedValueStore,
    allocator: Allocator,
    /// The size of the viewport in pixels.
    // TODO: Make this ZssUnits instead of pixels
    viewport_size: ViewportSize,
) Error!BoxTree {
    var computer = StyleComputer{
        .element_tree_skips = element_tree.tree.list.items(.__skip),
        .element_tree_refs = element_tree.tree.list.items(.__ref),
        .cascaded_values = &cascaded_value_store,
        // TODO: Store viewport_size in a LayoutInputs struct instead of the StyleComputer
        .viewport_size = viewport_size,
        .stage = undefined,
        .allocator = allocator,
    };
    defer computer.deinit();

    const element_index_to_generated_box = try allocator.alloc(GeneratedBox, element_tree.size());
    var box_tree = BoxTree{
        .allocator = allocator,
        .element_index_to_generated_box = element_index_to_generated_box,
    };
    errdefer box_tree.deinit();

    try boxGeneration(&computer, &box_tree, allocator);
    try cosmeticLayout(&computer, &box_tree);

    return box_tree;
}

fn boxGeneration(computer: *StyleComputer, box_tree: *BoxTree, allocator: Allocator) !void {
    computer.stage = .{ .box_gen = .{} };
    defer computer.deinitStage(.box_gen);

    var layout = normal.BlockLayoutContext{ .allocator = allocator };
    defer layout.deinit();

    var sc = StackingContexts{ .allocator = allocator };
    defer sc.deinit();

    try normal.makeInitialContainingBlock(&layout, computer, box_tree);
    try normal.mainLoop(&layout, &sc, computer, box_tree);

    computer.assertEmptyStage(.box_gen);
}

fn cosmeticLayout(computer: *StyleComputer, box_tree: *BoxTree) !void {
    computer.stage = .{ .cosmetic = .{} };
    defer computer.deinitStage(.cosmetic);

    try cosmetic.run(computer, box_tree);

    computer.assertEmptyStage(.cosmetic);
}
