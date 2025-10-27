const Layout = @This();

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const zss = @import("zss.zig");
const math = zss.math;
const BoxTree = zss.BoxTree;
const Environment = zss.Environment;
const Fonts = zss.Fonts;
const Images = zss.Images;
const NodeId = Environment.NodeId;

const cosmetic = @import("Layout/cosmetic.zig");
pub const BoxGen = @import("Layout/BoxGen.zig");
pub const BoxTreeManaged = @import("Layout/BoxTreeManaged.zig");
pub const StyleComputer = @import("Layout/StyleComputer.zig");

box_tree: BoxTreeManaged,
computer: StyleComputer,
viewport: math.Size,
inputs: Inputs,
allocator: Allocator,
node_stack: zss.Stack(?NodeId),
box_gen: BoxGen,

pub const Inputs = struct {
    width: u32,
    height: u32,
    env: *const Environment,
    images: *const Images,
    fonts: *const Fonts,
};

pub const Error = error{
    OutOfMemory,
    SizeLimitExceeded,
    ViewportTooLarge,
};

const Mode = enum {
    flow,
    stf,
    @"inline",
};

pub const IsRoot = enum {
    root,
    not_root,
};

pub fn init(
    env: *const Environment,
    allocator: Allocator,
    /// The width of the viewport in pixels.
    width: u32,
    /// The height of the viewport in pixels.
    height: u32,
    images: *const Images,
    fonts: *const Fonts,
) Layout {
    return .{
        .box_tree = undefined,
        .computer = StyleComputer.init(env, allocator),
        .viewport = undefined,
        .inputs = .{
            .width = width,
            .height = height,
            .env = env,
            .images = images,
            .fonts = fonts,
        },
        .allocator = allocator,
        .node_stack = .{},
        .box_gen = .{},
    };
}

pub fn deinit(layout: *Layout) void {
    layout.computer.deinit();
    layout.node_stack.deinit(layout.allocator);
    layout.box_gen.deinit();
}

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

    {
        layout.node_stack.top = layout.inputs.env.root_node;
        layout.computer.stage = .{ .box_gen = .{} };
        defer layout.computer.deinitStage(.box_gen);
        try layout.box_gen.run();
    }

    try cosmeticLayout(layout);

    return box_tree;
}

fn cosmeticLayout(layout: *Layout) !void {
    layout.computer.stage = .{ .cosmetic = .{} };
    defer layout.computer.deinitStage(.cosmetic);

    layout.node_stack.top = layout.inputs.env.root_node;

    try cosmetic.run(layout);
}

pub fn currentNode(layout: Layout) ?NodeId {
    return layout.node_stack.top.?;
}

pub fn pushNode(layout: *Layout) !void {
    const node = &layout.node_stack.top.?;
    const child = node.*.?.firstChild(layout.inputs.env);
    node.* = node.*.?.nextSibling(layout.inputs.env);
    try layout.node_stack.push(layout.allocator, child);
}

pub fn popNode(layout: *Layout) void {
    _ = layout.node_stack.pop();
}

pub fn advanceNode(layout: *Layout) void {
    const node = &layout.node_stack.top.?;
    node.* = node.*.?.nextSibling(layout.inputs.env);
}
